defmodule Wiregrid.Recovery do
  @moduledoc false

  @lifecycle_capacity_keys [
    subscription_edges: :subscription_edges,
    presence_watch_edges: :presence_watch_edges,
    room_edges: :room_edges
  ]

  @doc """
  Rebuilds lifecycle-derived indexes after a Runtime-process restart.

  ETS is owned by `Wiregrid.Tables`, so the control-plane process may restart
  while session/edge state survives. The set-style edge tables are the
  authoritative membership records; reverse indexes, fanout indexes, gauges
  and lifecycle counter slots are deliberately rebuildable.
  """
  def reconcile(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        clear_derived(t)
        rebuild_sessions(t)
        rebuild_subscriptions(t)
        rebuild_presence_watches(t)
        rebuild_rooms(t)
        rebuild_room_states(t)
        repair_capacity(t)
        repair_metrics(instance, t)
        Wiregrid.FanoutIndex.rebuild(instance)
        prune_empty_room_counters(t)
        {:ok, cfg}

      _ ->
        {:error, :instance_unavailable}
    end
  end

  defp clear_derived(t) do
    Enum.each(
      [
        t.user_sessions,
        t.user_index,
        t.user_session_counts,
        t.owner_sessions,
        t.owner_session_counts,
        t.slow_evicting,
        t.session_topics,
        t.session_watches,
        t.session_rooms,
        t.topic_counts,
        t.presence_watcher_counts,
        t.room_counts,
        t.room_state_keys
      ],
      &:ets.delete_all_objects/1
    )

    :ok
  end

  defp rebuild_sessions(t) do
    # Positions 5..7 are lifecycle-derived counts. Positions 2..4 belong to
    # delivery/activity/receipt hot paths and must survive a Runtime restart.
    :ets.foldl(
      fn {session_id, session}, :ok ->
        true = :ets.insert(t.user_sessions, {session.user_id, session_id})
        true = :ets.insert(t.user_index, {session.user_id, true})
        _ = :wiregrid_hot.counter_add(t.user_session_counts, session.user_id, 1)
        true = :ets.insert(t.owner_sessions, {session.pid, session_id})
        _ = :wiregrid_hot.counter_add(t.owner_session_counts, session.pid, 1)
        ensure_counter_row(t.session_counters, session_id)
        true = :ets.update_element(t.session_counters, session_id, [{5, 0}, {6, 0}, {7, 0}])
        :ok
      end,
      :ok,
      t.sessions
    )

    # Counter rows for sessions that no longer exist cannot be owned by any
    # live lifecycle edge and are safe to drop.
    :ets.foldl(
      fn tuple, :ok ->
        session_id = elem(tuple, 0)

        unless :ets.member(t.sessions, session_id),
          do: :ets.delete(t.session_counters, session_id)

        :ok
      end,
      :ok,
      t.session_counters
    )

    :ok
  end

  defp rebuild_subscriptions(t) do
    :ets.foldl(
      fn {{session_id, topic} = key, true}, :ok ->
        if :ets.member(t.sessions, session_id) do
          true = :ets.insert(t.session_topics, {session_id, topic})
          _ = :wiregrid_hot.session_counter_add(t.session_counters, session_id, 5, 1)
          _ = :wiregrid_hot.counter_add(t.topic_counts, topic, 1)
        else
          :ets.delete(t.subscription_edges, key)
        end

        :ok
      end,
      :ok,
      t.subscription_edges
    )
  end

  defp rebuild_presence_watches(t) do
    :ets.foldl(
      fn {{session_id, user_id} = key, true}, :ok ->
        if :ets.member(t.sessions, session_id) do
          true = :ets.insert(t.session_watches, {session_id, user_id})
          _ = :wiregrid_hot.session_counter_add(t.session_counters, session_id, 6, 1)
          _ = :wiregrid_hot.counter_add(t.presence_watcher_counts, user_id, 1)
        else
          :ets.delete(t.presence_watch_edges, key)
        end

        :ok
      end,
      :ok,
      t.presence_watch_edges
    )
  end

  defp rebuild_rooms(t) do
    :ets.foldl(
      fn {{room, session_id} = key, member}, :ok ->
        case :ets.lookup(t.sessions, session_id) do
          [{^session_id, session}] ->
            if Map.get(member, :user_id) == session.user_id do
              true = :ets.insert(t.session_rooms, {session_id, room})
              _ = :wiregrid_hot.session_counter_add(t.session_counters, session_id, 7, 1)
              _ = :wiregrid_hot.counter_add(t.room_counts, room, 1)
            else
              :ets.delete(t.room_edges, key)
            end

          _ ->
            :ets.delete(t.room_edges, key)
        end

        :ok
      end,
      :ok,
      t.room_edges
    )
  end

  defp rebuild_room_states(t) do
    :ets.foldl(
      fn {room, _state}, :ok ->
        true = :ets.insert(t.room_state_keys, {room, true})
        :ok
      end,
      :ok,
      t.room_state
    )
  end

  defp repair_capacity(t) do
    Enum.each(@lifecycle_capacity_keys, fn {table_key, counter_key} ->
      count = :ets.info(Map.fetch!(t, table_key), :size) || 0
      true = :ets.insert(t.capacity, {counter_key, count})
    end)

    true = :ets.insert(t.capacity, {:room_states, :ets.info(t.room_state, :size) || 0})
    :ok
  end

  defp repair_metrics(instance, t) do
    _ = Wiregrid.Metrics.set_gauge(instance, :sessions, :ets.info(t.sessions, :size) || 0)

    _ =
      Wiregrid.Metrics.set_gauge(
        instance,
        :subscriptions,
        :ets.info(t.subscription_edges, :size) || 0
      )

    _ =
      Wiregrid.Metrics.set_gauge(
        instance,
        :presence_watches,
        :ets.info(t.presence_watch_edges, :size) || 0
      )

    _ =
      Wiregrid.Metrics.set_gauge(instance, :room_memberships, :ets.info(t.room_edges, :size) || 0)

    :ok
  end

  defp prune_empty_room_counters(t) do
    prune_zeroes(t.topic_counts)
    prune_zeroes(t.presence_watcher_counts)
    prune_zeroes(t.room_counts)
  end

  defp prune_zeroes(table) do
    :ets.foldl(
      fn
        {key, 0}, :ok ->
          :ets.delete(table, key)
          :ok

        _object, :ok ->
          :ok
      end,
      :ok,
      table
    )
  end

  defp ensure_counter_row(table, session_id) do
    case :ets.lookup(table, session_id) do
      [] -> true = :ets.insert_new(table, {session_id, 0, 0, 0, 0, 0, 0})
      [_] -> :ok
    end
  end
end
