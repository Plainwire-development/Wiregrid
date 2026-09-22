defmodule Wiregrid.Cluster do
  @moduledoc false

  def child_specs(_instance, %{cluster: false}), do: []

  def child_specs(instance, config) do
    shards =
      for shard <- 0..(config.cluster_shards - 1) do
        %{
          id: {Wiregrid.Cluster.Shard, instance, shard},
          start: {Wiregrid.Cluster.Shard, :start_link, [{instance, config, shard}]},
          restart: :permanent,
          type: :worker
        }
      end

    shards ++
      [
        %{
          id: {Wiregrid.Cluster.Topology, instance},
          start: {Wiregrid.Cluster.Topology, :start_link, [{instance, config}]},
          restart: :permanent,
          type: :worker
        }
      ]
  end

  def topic(instance, topic, event_id, payload, class, opts) do
    dispatch(
      instance,
      topic,
      {:topic,
       %{
         topic: topic,
         event_id: event_id,
         payload: payload,
         class: class,
         opts: cluster_opts(opts)
       }}
    )
  end

  def room_event(instance, room, event_id, payload, class, opts) do
    dispatch(
      instance,
      room,
      {:room_event,
       %{room: room, event_id: event_id, payload: payload, class: class, opts: cluster_opts(opts)}}
    )
  end

  def user_event(instance, user_id, event_id, payload, class) do
    dispatch(
      instance,
      {:user, user_id},
      {:user_event, %{user_id: user_id, event_id: event_id, payload: payload, class: class}}
    )
  end

  def presence(instance, user_id, aggregate),
    do:
      dispatch(instance, {:user, user_id}, {:presence, %{user_id: user_id, aggregate: aggregate}})

  def room_join(instance, room, sid, user_id),
    do: dispatch(instance, room, {:room_join, %{room: room, session_id: sid, user_id: user_id}})

  def room_leave(instance, room, sid, user_id),
    do: dispatch(instance, room, {:room_leave, %{room: room, session_id: sid, user_id: user_id}})

  def room_state(instance, room, state) do
    ttl =
      case Map.get(state, :expires_at_ms, :infinity) do
        :infinity ->
          :infinity

        deadline when is_integer(deadline) ->
          max(deadline - System.monotonic_time(:millisecond), 1)
      end

    dispatch(
      instance,
      room,
      {:room_state, %{room: room, metadata: Map.get(state, :metadata, %{}), ttl_ms: ttl}}
    )
  end

  def room_expired(instance, room), do: dispatch(instance, room, {:room_expired, %{room: room}})

  def expire_seen(instance, key) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        case :ets.take(t.seen_cluster, key) do
          [{^key, true}] -> Wiregrid.Capacity.release(t.capacity, :cluster_dedupe)
          [] -> :ok
        end

      _ ->
        :ok
    end
  end

  def resync_to(instance, target_node) when is_atom(target_node) do
    case Wiregrid.Tables.get(instance) do
      %{config: %{cluster: true}, tables: t} ->
        :ets.foldl(
          fn {user_id, true}, :ok ->
            aggregate = Wiregrid.Presence.local_aggregate(instance, user_id)

            _ =
              targeted(
                instance,
                {:user, user_id},
                target_node,
                {:presence, %{user_id: user_id, aggregate: aggregate}}
              )

            :ok
          end,
          :ok,
          t.user_index
        )

        :ets.foldl(
          fn {{room, sid}, member}, :ok ->
            _ =
              targeted(
                instance,
                room,
                target_node,
                {:room_join, %{room: room, session_id: sid, user_id: member.user_id}}
              )

            :ok
          end,
          :ok,
          t.room_edges
        )

        :ets.foldl(
          fn {room, state}, :ok ->
            ttl =
              case Map.get(state, :expires_at_ms, :infinity) do
                :infinity -> :infinity
                deadline -> max(deadline - System.monotonic_time(:millisecond), 1)
              end

            _ =
              targeted(
                instance,
                room,
                target_node,
                {:room_state,
                 %{room: room, metadata: Map.get(state, :metadata, %{}), ttl_ms: ttl}}
              )

            :ok
          end,
          :ok,
          t.room_state
        )

        _ = Wiregrid.Metrics.increment(instance, :cluster_resyncs)
        :ok

      _ ->
        :ok
    end
  end

  def remove_node(instance, origin_node) do
    Wiregrid.Presence.remove_remote_node(instance, origin_node)
    Wiregrid.Rooms.remove_remote_node(instance, origin_node)
  end

  def pending(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        Enum.reduce(0..(cfg.cluster_shards - 1), 0, fn shard, acc ->
          acc + :wiregrid_hot.counter_get(t.capacity, {:cluster_pending, shard})
        end)

      _ ->
        0
    end
  end

  defp dispatch(instance, routing_key, message),
    do: dispatch(instance, routing_key, message, :all)

  defp targeted(instance, routing_key, target, message),
    do: dispatch(instance, routing_key, message, {:node, target})

  defp dispatch(instance, routing_key, message, target) do
    case Wiregrid.Tables.get(instance) do
      %{config: %{cluster: false}} ->
        :ok

      %{config: cfg, tables: t} ->
        shard = :erlang.phash2(routing_key, cfg.cluster_shards)
        counter_key = {:cluster_pending, shard}

        with :ok <-
               Wiregrid.Capacity.reserve(t.capacity, counter_key, cfg.cluster_pending_per_shard),
             [{pid, _}] <-
               Registry.lookup(Wiregrid.ProcessRegistry, {:cluster_shard, instance, shard}) do
          GenServer.cast(pid, {:outbound, target, message})
          :ok
        else
          [] ->
            _ = Wiregrid.Capacity.release(t.capacity, counter_key)
            {:error, :cluster_unavailable}

          {:error, :capacity} ->
            _ = Wiregrid.Metrics.increment(instance, :cluster_messages_dropped)
            {:error, :cluster_overloaded}
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  defp cluster_opts(opts) do
    %{
      exclude_users: opts |> Keyword.get(:exclude_users, []) |> Enum.take(256)
    }
  end
end
