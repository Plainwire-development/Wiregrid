defmodule Wiregrid.Activity do
  @moduledoc false

  @option_keys [:ttl_ms, :broadcast]
  @claim_retries 8

  def put(instance, session_id, topic, kind, value, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @option_keys),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         :ok <- valid_kind(kind),
         :ok <- Wiregrid.Validation.event(value, cfg.max_metadata_bytes),
         [{^session_id, session}] <- :ets.lookup(t.sessions, session_id),
         :ok <- Wiregrid.Authorizer.check(instance, cfg, :activity, session, topic, %{kind: kind}),
         {:ok, ttl_ms} <-
           Wiregrid.Validation.ttl(
             Keyword.get(opts, :ttl_ms, cfg.activity_ttl_ms),
             cfg.max_ttl_ms
           ),
         :ok <- store(instance, t, cfg, session, topic, kind, value, ttl_ms) do
      if Keyword.get(opts, :broadcast, false) do
        event = %{type: :activity, kind: kind, user_id: session.user_id, value: value}

        _ =
          Wiregrid.publish(instance, topic, event,
            class: :ephemeral,
            session_id: session_id,
            exclude_sessions: [session_id],
            cluster: true
          )
      end

      :ok
    else
      [] -> {:error, :unknown_session}
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  def list(instance, topic, kind, limit \\ 100)

  def list(instance, topic, kind, limit) when is_integer(limit) and limit in 1..1_000 do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        key = {topic, kind}
        spec = [{{key, :"$1"}, [], [:"$1"]}]

        case :ets.select(t.activities_by_topic, spec, limit) do
          :"$end_of_table" ->
            []

          {activity_keys, _continuation} ->
            Enum.flat_map(activity_keys, fn activity_key ->
              case :ets.lookup(t.activities, activity_key) do
                [{^activity_key, value}] -> [value]
                [] -> []
              end
            end)
        end

      _ ->
        []
    end
  end

  def list(_instance, _topic, _kind, _limit), do: []

  def expire(instance, key, deadline) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        case :ets.lookup(t.activities, key) do
          [{^key, %{expires_at_ms: ^deadline} = record}] ->
            remove_record(instance, t, key, record)

          [{^key, %{expires_at_ms: current_deadline} = record}]
          when is_integer(current_deadline) ->
            repair_mismatched_expiry(instance, t, key, record, current_deadline)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  def cleanup_session(instance, session_id) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        keys = for {^session_id, key} <- :ets.lookup(t.activities_by_session, session_id), do: key
        Enum.each(keys, &remove(instance, t, &1))
        :ets.delete(t.activities_by_session, session_id)
        :ok

      _ ->
        :ok
    end
  end

  defp store(instance, t, cfg, session, topic, kind, value, ttl_ms) do
    store_retry(instance, t, cfg, session, topic, kind, value, ttl_ms, 0)
  end

  defp store_retry(_instance, _t, _cfg, _session, _topic, _kind, _value, _ttl_ms, attempts)
       when attempts >= @claim_retries,
       do: {:error, :activity_contention}

  defp store_retry(instance, t, cfg, session, topic, kind, value, ttl_ms, attempts) do
    key = {session.id, topic, kind}
    expires = System.monotonic_time(:millisecond) + ttl_ms

    with {:ok, owner_token, ownership} <- claim_owner(t, session.id, key, cfg, attempts) do
      record = %{
        session_id: session.id,
        user_id: session.user_id,
        topic: topic,
        kind: kind,
        value: value,
        owner_token: owner_token,
        expires_at_ms: expires
      }

      case install_record(t, key, record, ownership) do
        :ok ->
          true = :ets.insert(t.activities_by_topic, {{topic, kind}, key})
          true = :ets.insert(t.activities_by_session, {session.id, key})

          result =
            with :ok <- Wiregrid.Expiry.schedule_at(instance, :activity, key, expires),
                 [{^key, ^owner_token}] <- :ets.lookup(t.activity_keys, key),
                 [{_, live}] when live.monitor == session.monitor <-
                   :ets.lookup(t.sessions, session.id) do
              :ok
            else
              [] -> {:error, :unknown_session}
              {:error, _} = error -> error
              _ -> {:error, :activity_failed}
            end

          if result != :ok, do: rollback_record(instance, t, key, record)
          result

        :retry ->
          if ownership == :new, do: abandon_new_owner(t, session.id, key, owner_token)
          store_retry(instance, t, cfg, session, topic, kind, value, ttl_ms, attempts + 1)
      end
    end
  end

  defp claim_owner(_t, _sid, _key, _cfg, attempts) when attempts >= @claim_retries,
    do: {:error, :activity_contention}

  defp claim_owner(t, sid, key, cfg, attempts) do
    case :ets.lookup(t.activity_keys, key) do
      [{^key, token}] ->
        {:ok, token, :existing}

      [] ->
        case Wiregrid.Capacity.reserve(t.capacity, :activity_entries, cfg.max_activity_entries) do
          :ok -> claim_new_owner(t, sid, key, cfg, attempts)
          {:error, :capacity} -> {:error, :activity_capacity}
          {:error, _} = error -> error
        end
    end
  end

  defp claim_new_owner(t, sid, key, cfg, attempts) do
    case :wiregrid_hot.session_counter_add(t.session_counters, sid, 3, 1) do
      {:ok, count} when count <= cfg.max_activities_per_session ->
        token = System.unique_integer([:positive, :monotonic])

        if :ets.insert_new(t.activity_keys, {key, token}) do
          {:ok, token, :new}
        else
          _ = :wiregrid_hot.session_counter_add(t.session_counters, sid, 3, -1)
          _ = Wiregrid.Capacity.release(t.capacity, :activity_entries)
          claim_owner(t, sid, key, cfg, attempts + 1)
        end

      {:ok, _count} ->
        _ = :wiregrid_hot.session_counter_add(t.session_counters, sid, 3, -1)
        _ = Wiregrid.Capacity.release(t.capacity, :activity_entries)
        {:error, :activity_capacity}

      {:error, _} ->
        _ = Wiregrid.Capacity.release(t.capacity, :activity_entries)
        {:error, :unknown_session}
    end
  end

  defp install_record(t, key, record, :new) do
    if :ets.insert_new(t.activities, {key, record}), do: :ok, else: :retry
  end

  defp install_record(t, key, %{owner_token: token} = record, :existing) do
    case :ets.lookup(t.activities, key) do
      [{^key, %{owner_token: ^token} = previous}] ->
        if replace_exact(t.activities, {key, previous}, {key, record}), do: :ok, else: :retry

      _ ->
        :retry
    end
  end

  defp abandon_new_owner(t, session_id, key, token) do
    if :ets.select_delete(t.activity_keys, [{{key, token}, [], [true]}]) == 1 do
      _ = :wiregrid_hot.session_counter_add(t.session_counters, session_id, 3, -1)
      _ = Wiregrid.Capacity.release(t.capacity, :activity_entries)
    end

    :ok
  end

  defp rollback_record(instance, t, key, record) do
    if delete_record_exact(t.activities, key, record) do
      release_generation(instance, t, key, record)
    end

    :ok
  end

  defp remove(instance, t, key) do
    case :ets.lookup(t.activities, key) do
      [{^key, record}] -> remove_record(instance, t, key, record)
      [] -> :ok
    end
  end

  defp remove_record(instance, t, key, record) do
    if delete_record_exact(t.activities, key, record) do
      release_generation(instance, t, key, record)
    end

    :ok
  end

  defp release_generation(instance, t, key, record) do
    token = record.owner_token

    # Delete secondary indexes while the generation still owns the primary edge.
    # A new generation cannot claim this key until the exact owner row is removed.
    :ets.delete_object(t.activities_by_topic, {{record.topic, record.kind}, key})
    :ets.delete_object(t.activities_by_session, {record.session_id, key})

    owner_spec = [{{key, token}, [], [true]}]

    # Cancel while the old owner row still blocks a new generation. Once the
    # owner is removed a new writer may schedule the same logical key, so a
    # later cancel would be an ABA race against the fresh timer.
    _ = Wiregrid.Expiry.cancel(instance, :activity, key)

    if :ets.select_delete(t.activity_keys, owner_spec) == 1 do
      _ = :wiregrid_hot.session_counter_add(t.session_counters, record.session_id, 3, -1)
      _ = Wiregrid.Capacity.release(t.capacity, :activity_entries)
    end

    :ok
  end

  defp delete_record_exact(table, key, record) do
    :ets.select_delete(table, [{{key, record}, [], [true]}]) == 1
  end

  defp replace_exact(table, old, replacement) do
    :ets.select_replace(table, [{old, [], [{:const, replacement}]}]) == 1
  end

  defp repair_mismatched_expiry(instance, t, key, record, current_deadline) do
    if current_deadline <= System.monotonic_time(:millisecond) do
      remove_record(instance, t, key, record)
    else
      _ = Wiregrid.Expiry.schedule_at(instance, :activity, key, current_deadline)
      :ok
    end
  end

  defp accepting(instance), do: Wiregrid.Runtime.accepting(instance)

  defp valid_kind(kind) when is_atom(kind), do: :ok
  defp valid_kind(kind) when is_binary(kind) and byte_size(kind) in 1..64, do: :ok
  defp valid_kind(_), do: {:error, :invalid_activity_kind}
end
