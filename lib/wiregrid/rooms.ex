defmodule Wiregrid.Rooms do
  @moduledoc false

  def members(instance, room, limit \\ 10_000)

  def members(instance, room, limit) when is_integer(limit) and limit in 1..100_000 do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        local = local_members(t, room, limit)
        remaining = max(limit - length(local), 0)
        local ++ remote_members(t, room, remaining)

      _ ->
        []
    end
  end

  def members(_instance, _room, _limit), do: []

  def metadata(instance, room) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        case :ets.lookup(t.room_state, room) do
          [{^room, state}] -> {:ok, state}
          [] -> :not_found
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def local_member?(instance, room, session_id) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} -> :ets.member(t.room_edges, {room, session_id})
      _ -> false
    end
  end

  def remote_join(instance, origin_node, room, session_id, user_id) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        key = {origin_node, room, session_id}

        if :ets.member(t.remote_room_edges, key) do
          :ok
        else
          with :ok <-
                 Wiregrid.Capacity.reserve(
                   t.capacity,
                   :remote_room_edges,
                   cfg.max_remote_room_edges
                 ) do
            if :ets.insert_new(t.remote_room_edges, {key, %{user_id: user_id}}) do
              true = :ets.insert(t.remote_rooms, {{room, origin_node, session_id}, true})
              true = :ets.insert(t.remote_rooms_by_node, {origin_node, {room, session_id}})
              :ok
            else
              _ = Wiregrid.Capacity.release(t.capacity, :remote_room_edges)
              :ok
            end
          else
            {:error, :capacity} -> {:error, :remote_room_capacity}
          end
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def remote_leave(instance, origin_node, room, session_id) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} -> remove_remote_edge(t, origin_node, room, session_id)
      _ -> :ok
    end
  end

  def remote_state(instance, room, state) when is_map(state) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        # Room metadata is not merged across nodes; the latest trusted cluster
        # update is a cache of shared room state. Applications that need a
        # consensus data model should use durable storage instead.
        Wiregrid.RoomState.put(t, cfg, room, state)

      _ ->
        :ok
    end
  end

  def remove_remote_node(instance, origin_node) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        :ets.safe_fixtable(t.remote_rooms_by_node, true)

        try do
          spec = [{{origin_node, :"$1"}, [], [:"$1"]}]

          remove_remote_room_batches(
            t,
            origin_node,
            :ets.select(t.remote_rooms_by_node, spec, 512)
          )
        after
          :ets.safe_fixtable(t.remote_rooms_by_node, false)
        end

        :ets.delete(t.remote_rooms_by_node, origin_node)
        :ok

      _ ->
        :ok
    end
  end

  defp remove_remote_room_batches(_t, _origin_node, :"$end_of_table"), do: :ok

  defp remove_remote_room_batches(t, origin_node, {entries, continuation}) do
    Enum.each(entries, fn {room, sid} -> remove_remote_edge(t, origin_node, room, sid) end)
    remove_remote_room_batches(t, origin_node, :ets.select(continuation))
  end

  defp local_members(t, room, limit) do
    t
    |> Wiregrid.FanoutIndex.take(:room, room, limit)
    |> Enum.flat_map(fn sid ->
      key = {room, sid}

      case :ets.lookup(t.room_edges, key) do
        [{^key, member}] -> [Map.merge(member, %{session_id: sid, node: node()})]
        [] -> []
      end
    end)
  end

  defp remote_members(_t, _room, 0), do: []

  defp remote_members(t, room, limit) do
    walk_remote_room(t, room, :ets.next(t.remote_rooms, {room, 0, 0}), limit, [])
    |> Enum.reverse()
  end

  defp walk_remote_room(_t, _room, _key, 0, acc), do: acc
  defp walk_remote_room(_t, _room, :"$end_of_table", _remaining, acc), do: acc

  defp walk_remote_room(t, room, {room, origin_node, sid} = index_key, remaining, acc) do
    next_key = :ets.next(t.remote_rooms, index_key)
    edge_key = {origin_node, room, sid}

    case :ets.lookup(t.remote_room_edges, edge_key) do
      [{^edge_key, member}] ->
        item = Map.merge(member, %{session_id: sid, node: origin_node})
        walk_remote_room(t, room, next_key, remaining - 1, [item | acc])

      [] ->
        # Secondary indexes are rebuildable/cache-like. Skip a stale pointer
        # without charging it against the caller's result budget.
        walk_remote_room(t, room, next_key, remaining, acc)
    end
  end

  defp walk_remote_room(_t, _room, _other_key, _remaining, acc), do: acc

  defp remove_remote_edge(t, origin_node, room, session_id) do
    key = {origin_node, room, session_id}

    case :ets.take(t.remote_room_edges, key) do
      [{^key, _member}] ->
        :ets.delete(t.remote_rooms, {room, origin_node, session_id})
        :ets.delete_object(t.remote_rooms_by_node, {origin_node, {room, session_id}})
        _ = Wiregrid.Capacity.release(t.capacity, :remote_room_edges)
        :ok

      [] ->
        :ok
    end
  end
end
