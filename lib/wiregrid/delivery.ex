defmodule Wiregrid.Delivery do
  @moduledoc false
  require Logger

  @type class :: :durable | :ephemeral

  def send_session(instance, session_id, topic, payload, event, class, opts \\ [])

  def send_session(instance, session_id, topic, payload, event, class, opts)
      when class in [:durable, :ephemeral] and is_binary(payload) and is_list(opts) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        with {:ok, context} <- delivery_context(opts, cfg),
             {:ok, exclusions} <- exclusion_sets(opts) do
          send_session_prevalidated(
            instance,
            t,
            cfg,
            session_id,
            topic,
            payload,
            event,
            class,
            context,
            exclusions
          )
        else
          {:error, _} -> :gone
        end

      _ ->
        :gone
    end
  end

  def send_session(_instance, _session_id, _topic, _payload, _event, _class, _opts), do: :gone

  @doc false
  def send_session_prevalidated(
        instance,
        t,
        cfg,
        session_id,
        topic,
        payload,
        event,
        class,
        context,
        {excluded_sessions, excluded_users}
      )
      when class in [:durable, :ephemeral] and is_binary(payload) and is_map(context) do
    case :ets.lookup(t.sessions, session_id) do
      [{^session_id, session}] ->
        if excluded?(session, excluded_sessions, excluded_users) do
          :excluded
        else
          reserve_delivery_slot(instance, t, cfg, session, topic, payload, event, class, context)
        end

      [] ->
        :gone
    end
  end

  def send_session_prevalidated(
        _instance,
        _t,
        _cfg,
        _session_id,
        _topic,
        _payload,
        _event,
        _class,
        _context,
        _exclusions
      ),
      do: :gone

  def ack(instance, session_id, delivery_id) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        key = {session_id, delivery_id}

        case :ets.take(t.delivery_reservations, key) do
          [{^key, true}] ->
            release_accounting(instance, t, session_id)
            {:ok, pending(instance, session_id)}

          [] ->
            {:error, :unknown_delivery}
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  @doc false
  def ack_many(instance, session_id, delivery_ids) when is_list(delivery_ids) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        {acked, unknown} =
          Enum.reduce(delivery_ids, {0, []}, fn delivery_id, {count, missing} ->
            key = {session_id, delivery_id}

            case :ets.take(t.delivery_reservations, key) do
              [{^key, true}] ->
                release_accounting(instance, t, session_id)
                {count + 1, missing}

              [] ->
                {count, [delivery_id | missing]}
            end
          end)

        {:ok,
         %{acked: acked, unknown: Enum.reverse(unknown), pending: pending(instance, session_id)}}

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def ack_many(_instance, _session_id, _delivery_ids), do: {:error, :invalid_delivery_ids}

  # Compatibility convenience for in-process consumers: acknowledge one of
  # the session's reservations. Protocol adapters should use ack/3.
  def ack(instance, session_id) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        case first_delivery_id(t.delivery_reservations, session_id) do
          {:ok, delivery_id} -> ack(instance, session_id, delivery_id)
          :none -> {:ok, 0}
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def pending(instance, session_id) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} -> :wiregrid_hot.session_counter_get(t.session_counters, session_id, 2)
      _ -> 0
    end
  end

  @doc false
  def release_session(instance, session_id) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        release_session_loop(
          instance,
          t,
          session_id,
          :ets.next(t.delivery_reservations, {session_id, 0})
        )

      _ ->
        :ok
    end
  end

  defp reserve_delivery_slot(instance, t, cfg, session, topic, payload, event, class, context) do
    case Wiregrid.Capacity.reserve(
           t.capacity,
           :delivery_reservations,
           cfg.max_delivery_reservations
         ) do
      :ok ->
        case :wiregrid_hot.session_counter_add(t.session_counters, session.id, 2, 1) do
          {:ok, pending} ->
            apply_pressure(
              instance,
              t,
              cfg,
              session,
              topic,
              payload,
              event,
              class,
              context,
              pending
            )

          {:error, _} ->
            _ = Wiregrid.Capacity.release(t.capacity, :delivery_reservations)
            :gone
        end

      {:error, :capacity} ->
        if class == :ephemeral do
          _ = Wiregrid.Metrics.increment(instance, :dropped_ephemeral)
          :dropped
        else
          _ = Wiregrid.Metrics.increment(instance, :admission_rejections)
          :overloaded
        end
    end
  end

  defp apply_pressure(instance, t, cfg, session, topic, payload, event, class, context, pending) do
    cond do
      pending > cfg.hard_queue ->
        rollback_count(t, session.id)
        _ = Wiregrid.Capacity.release(t.capacity, :delivery_reservations)
        maybe_isolate_slow(instance, session, pending, cfg)
        :evicted

      pending > cfg.soft_queue and class == :ephemeral ->
        rollback_count(t, session.id)
        _ = Wiregrid.Capacity.release(t.capacity, :delivery_reservations)
        _ = Wiregrid.Metrics.increment(instance, :dropped_ephemeral)
        :dropped

      true ->
        reserve_and_send(instance, t, session, topic, payload, event, class, context)
    end
  end

  defp reserve_and_send(instance, t, session, topic, payload, event, class, context) do
    delivery_id = Wiregrid.ID.generate()
    key = {session.id, delivery_id}

    if :ets.insert_new(t.delivery_reservations, {key, true}) do
      case :ets.lookup(t.sessions, session.id) do
        [{_, live}] when live.pid == session.pid and live.monitor == session.monitor ->
          base = %{
            instance: instance,
            session_id: session.id,
            delivery_id: delivery_id,
            topic: topic,
            class: class
          }

          base = if map_size(context) == 0, do: base, else: Map.put(base, :context, context)
          envelope = delivery_envelope(session.delivery_format, base, payload, event)

          Kernel.send(session.pid, {:"$wiregrid", envelope})
          _ = Wiregrid.Metrics.increment(instance, :deliveries_total)
          _ = Wiregrid.Metrics.increment(instance, :delivery_reservations)
          :sent

        _ ->
          release_reservation(instance, t, session.id, delivery_id)
          :gone
      end
    else
      rollback_count(t, session.id)
      _ = Wiregrid.Capacity.release(t.capacity, :delivery_reservations)
      :gone
    end
  end

  defp release_reservation(instance, t, session_id, delivery_id) do
    key = {session_id, delivery_id}

    case :ets.take(t.delivery_reservations, key) do
      [{^key, true}] -> release_accounting(instance, t, session_id)
      [] -> :ok
    end
  end

  defp release_accounting(instance, t, session_id) do
    rollback_count(t, session_id)
    _ = Wiregrid.Capacity.release(t.capacity, :delivery_reservations)
    _ = Wiregrid.Metrics.increment(instance, :delivery_reservations, -1)
    :ok
  end

  defp release_session_loop(_instance, _t, _session_id, :"$end_of_table"), do: :ok

  defp release_session_loop(instance, t, session_id, {session_id, _delivery_id} = key) do
    next_key = :ets.next(t.delivery_reservations, key)

    case :ets.take(t.delivery_reservations, key) do
      [{^key, true}] -> release_accounting(instance, t, session_id)
      [] -> :ok
    end

    release_session_loop(instance, t, session_id, next_key)
  end

  defp release_session_loop(_instance, _t, _session_id, _other_key), do: :ok

  defp first_delivery_id(table, session_id) do
    case :ets.next(table, {session_id, 0}) do
      {^session_id, delivery_id} -> {:ok, delivery_id}
      _ -> :none
    end
  end

  defp rollback_count(t, session_id) do
    _ = :wiregrid_hot.session_counter_add(t.session_counters, session_id, 2, -1)
    :ok
  end

  defp delivery_envelope(:encoded, base, payload, _event), do: Map.put(base, :payload, payload)
  defp delivery_envelope(:term, base, _payload, event), do: Map.put(base, :event, event)

  defp delivery_envelope(:both, base, payload, event) do
    base |> Map.put(:payload, payload) |> Map.put(:event, event)
  end

  defp delivery_context(opts, cfg) do
    case Keyword.get(opts, :delivery_context, %{}) do
      context when is_map(context) ->
        case Wiregrid.Validation.metadata(context, cfg.max_metadata_bytes) do
          :ok -> {:ok, context}
          {:error, _} -> {:error, :invalid_delivery_context}
        end

      _ ->
        {:error, :invalid_delivery_context}
    end
  end

  defp exclusion_sets(opts) do
    sessions = Keyword.get(opts, :exclude_sessions, MapSet.new())
    users = Keyword.get(opts, :exclude_users, MapSet.new())

    if match?(%MapSet{}, sessions) and match?(%MapSet{}, users) do
      {:ok, {sessions, users}}
    else
      {:error, :invalid_exclusions}
    end
  end

  defp excluded?(session, excluded_sessions, excluded_users) do
    MapSet.member?(excluded_sessions, session.id) or
      MapSet.member?(excluded_users, session.user_id)
  end

  defp maybe_isolate_slow(instance, session, pending, cfg) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        if :ets.insert_new(t.slow_evicting, {session.id, true}) do
          _ = Wiregrid.Metrics.increment(instance, :slow_consumers)

          Logger.warning(
            "wiregrid slow consumer instance=#{inspect(instance)} pending=#{pending}"
          )

          case cfg.slow_consumer_action do
            :exit_owner ->
              Process.exit(session.pid, {:shutdown, :wiregrid_slow_consumer})

            :disconnect ->
              Task.Supervisor.start_child(Wiregrid.TaskSupervisor, fn ->
                _ = Wiregrid.disconnect(instance, session.id, :slow_consumer)
              end)
          end
        end

      _ ->
        :ok
    end
  end
end
