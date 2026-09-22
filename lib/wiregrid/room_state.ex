defmodule Wiregrid.RoomState do
  @moduledoc false

  # `room_state` owns the value. `room_state_keys` owns the admission slot so
  # concurrent local/cluster writers cannot overshoot the configured budget.
  def put(instance, room, state) when is_map(state) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} -> put(t, cfg, room, state)
      _ -> {:error, :instance_unavailable}
    end
  end

  def put(_instance, _room, _state), do: {:error, :invalid_room_state}

  def put(t, cfg, room, state) when is_map(state) do
    if :ets.member(t.room_state_keys, room) do
      true = :ets.insert(t.room_state, {room, state})
      :ok
    else
      with :ok <- Wiregrid.Capacity.reserve(t.capacity, :room_states, cfg.max_room_states) do
        if :ets.insert_new(t.room_state_keys, {room, true}) do
          true = :ets.insert(t.room_state, {room, state})
          :ok
        else
          _ = Wiregrid.Capacity.release(t.capacity, :room_states)
          true = :ets.insert(t.room_state, {room, state})
          :ok
        end
      else
        {:error, :capacity} -> {:error, :room_state_capacity}
      end
    end
  end

  def delete(instance, room) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} -> delete_local(t, room)
      _ -> :ok
    end
  end

  def delete_local(t, room) do
    :ets.delete(t.room_state, room)

    case :ets.take(t.room_state_keys, room) do
      [{^room, true}] -> Wiregrid.Capacity.release(t.capacity, :room_states)
      [] -> :ok
    end
  end
end
