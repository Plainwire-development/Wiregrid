defmodule Wiregrid.Cluster.Shard do
  @moduledoc false
  use GenServer

  def start_link({instance, config, shard}) do
    GenServer.start_link(__MODULE__, {instance, config, shard}, name: via(instance, shard))
  end

  def via(instance, shard),
    do: {:via, Registry, {Wiregrid.ProcessRegistry, {:cluster_shard, instance, shard}}}

  @impl true
  def init({instance, config, shard}) do
    Process.flag(:message_queue_data, :off_heap)
    group = {:wiregrid, config.cluster_namespace, shard}
    reset_pending(instance, shard)
    :ok = :pg.join(group, self())
    {:ok, %{instance: instance, config: config, shard: shard, group: group}}
  end

  @impl true
  def handle_cast({:outbound, target, message}, state) do
    release_pending(state)

    members = :pg.get_members(state.group)
    recipients = Enum.filter(members, fn pid -> pid != self() and target?(pid, target) end)

    Enum.each(recipients, fn pid ->
      Kernel.send(pid, {:wiregrid_cluster, state.config.cluster_namespace, node(), message})
    end)

    if recipients != [] do
      _ = Wiregrid.Metrics.increment(state.instance, :cluster_messages_sent, length(recipients))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:wiregrid_cluster, namespace, origin_node, message}, state) do
    if namespace == state.config.cluster_namespace and origin_node != node() and
         connected?(state, origin_node) do
      _ = Wiregrid.Metrics.increment(state.instance, :cluster_messages_received)
      handle_remote(state, origin_node, message)
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp handle_remote(
         state,
         _origin,
         {:topic, %{topic: topic, event_id: event_id, payload: payload, class: class} = body}
       ) do
    with :ok <- validate_remote_event(state, topic, event_id, payload, class),
         {:ok, event} <- decode_remote_event(state, payload),
         {:ok, opts} <- remote_event_opts(Map.get(body, :opts, %{})),
         true <- mark_seen(state, {:topic, topic, event_id}) do
      _ = Wiregrid.Fanout.topic(state.instance, topic, payload, event, class, opts)
    end
  end

  defp handle_remote(
         state,
         _origin,
         {:user_event, %{user_id: user_id, event_id: event_id, payload: payload, class: class}}
       ) do
    cfg = state.config

    with {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         true <- class in [:durable, :ephemeral],
         true <- is_binary(payload) and byte_size(payload) <= cfg.max_encoded_event_bytes,
         :ok <- Wiregrid.Validation.binary_id(event_id, cfg.max_storage_id_bytes),
         {:ok, event} <- decode_remote_event(state, payload),
         true <- mark_seen(state, {:user_event, user_id, event_id}) do
      _ = Wiregrid.Fanout.user(state.instance, user_id, payload, event, class)
    else
      _ -> :ok
    end
  end

  defp handle_remote(
         state,
         _origin,
         {:room_event, %{room: room, event_id: event_id, payload: payload, class: class} = body}
       ) do
    with :ok <- validate_remote_event(state, room, event_id, payload, class),
         {:ok, event} <- decode_remote_event(state, payload),
         {:ok, opts} <- remote_event_opts(Map.get(body, :opts, %{})),
         true <- mark_seen(state, {:room_event, room, event_id}) do
      _ = Wiregrid.Fanout.room(state.instance, room, payload, event, class, opts)
    end
  end

  defp handle_remote(state, origin, {:presence, %{user_id: user_id, aggregate: aggregate}}) do
    cfg = state.config

    with {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         true <- valid_presence_aggregate?(aggregate, cfg) do
      Wiregrid.Presence.remote_changed(state.instance, origin, user_id, aggregate)
    else
      _ -> :ok
    end
  end

  defp handle_remote(
         state,
         origin,
         {:room_join, %{room: room, session_id: sid, user_id: user_id}}
       ) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes) do
      Wiregrid.Rooms.remote_join(state.instance, origin, room, sid, user_id)
    end
  end

  defp handle_remote(state, origin, {:room_leave, %{room: room, session_id: sid}}) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes) do
      Wiregrid.Rooms.remote_leave(state.instance, origin, room, sid)
    else
      _ -> :ok
    end
  end

  defp handle_remote(
         state,
         _origin,
         {:room_state, %{room: room, metadata: metadata, ttl_ms: ttl}}
       ) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- Wiregrid.Validation.metadata(metadata, cfg.max_metadata_bytes),
         {:ok, normalized_ttl} <- Wiregrid.Validation.ttl(ttl, cfg.max_ttl_ms) do
      expires_at =
        if normalized_ttl == :infinity,
          do: :infinity,
          else: System.monotonic_time(:millisecond) + normalized_ttl

      case Wiregrid.Rooms.remote_state(state.instance, room, %{
             metadata: metadata,
             expires_at_ms: expires_at
           }) do
        :ok ->
          if normalized_ttl == :infinity do
            Wiregrid.Expiry.cancel(state.instance, :room, room)
          else
            Wiregrid.Expiry.schedule_at(state.instance, :room, room, expires_at)
          end

        {:error, :room_state_capacity} = error ->
          _ = Wiregrid.Metrics.increment(state.instance, :admission_rejections)
          error

        {:error, _} = error ->
          error
      end
    end
  end

  defp handle_remote(state, _origin, {:room_expired, %{room: room}}) do
    cfg = state.config

    if Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth) == :ok do
      Wiregrid.Runtime.expire_room(state.instance, room)
    end
  end

  defp handle_remote(_state, _origin, _message), do: :ok

  defp validate_remote_event(state, topic, event_id, payload, class) do
    cfg = state.config

    with true <- class in [:durable, :ephemeral],
         true <- is_binary(payload) and byte_size(payload) <= cfg.max_encoded_event_bytes,
         :ok <- Wiregrid.Validation.binary_id(event_id, cfg.max_storage_id_bytes),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth) do
      :ok
    else
      _ -> {:error, :invalid_cluster_event}
    end
  end

  defp decode_remote_event(state, payload) do
    with {:ok, event} <- Wiregrid.Codec.decode(state.config, payload),
         :ok <- Wiregrid.Validation.event(event, state.config.max_event_bytes) do
      {:ok, event}
    else
      _ -> {:error, :invalid_cluster_event}
    end
  end

  defp remote_event_opts(opts) when is_map(opts) do
    users = Map.get(opts, :exclude_users, [])

    case Wiregrid.Validation.bounded_list(users, 256) do
      :ok -> {:ok, [exclude_users: users]}
      {:error, _} -> {:error, :invalid_cluster_options}
    end
  end

  defp remote_event_opts(_), do: {:error, :invalid_cluster_options}

  defp mark_seen(state, key) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} ->
        if :ets.member(t.seen_cluster, key) do
          false
        else
          case Wiregrid.Capacity.reserve(
                 t.capacity,
                 :cluster_dedupe,
                 state.config.max_cluster_dedupe
               ) do
            :ok ->
              if :ets.insert_new(t.seen_cluster, {key, true}) do
                case Wiregrid.Expiry.schedule(
                       state.instance,
                       :cluster_seen,
                       key,
                       state.config.cluster_dedupe_ttl_ms
                     ) do
                  :ok ->
                    true

                  {:error, _} ->
                    :ets.delete(t.seen_cluster, key)
                    _ = Wiregrid.Capacity.release(t.capacity, :cluster_dedupe)
                    false
                end
              else
                _ = Wiregrid.Capacity.release(t.capacity, :cluster_dedupe)
                false
              end

            {:error, :capacity} ->
              false
          end
        end

      _ ->
        false
    end
  end

  defp valid_presence_aggregate?(aggregate, cfg) when is_map(aggregate) do
    status = Map.get(aggregate, :status)
    sessions = Map.get(aggregate, :sessions)
    metadata = Map.get(aggregate, :metadata)
    updated = Map.get(aggregate, :updated_at_ms)

    match?({:ok, _}, Wiregrid.Presence.normalize_status(status)) and
      is_integer(sessions) and sessions >= 0 and sessions <= cfg.max_sessions and
      Wiregrid.Validation.metadata(metadata, cfg.max_metadata_bytes) == :ok and
      is_integer(updated)
  end

  defp valid_presence_aggregate?(_, _cfg), do: false

  defp reset_pending(instance, shard) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} -> :ets.insert(t.capacity, {{:cluster_pending, shard}, 0})
      _ -> :ok
    end
  end

  defp release_pending(state) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} -> Wiregrid.Capacity.release(t.capacity, {:cluster_pending, state.shard})
      _ -> :ok
    end
  end

  defp target?(_pid, :all), do: true
  defp target?(pid, {:node, target_node}), do: node(pid) == target_node

  defp connected?(state, origin_node) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} -> :ets.member(t.cluster_nodes, origin_node)
      _ -> false
    end
  end
end
