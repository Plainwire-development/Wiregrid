defmodule Wiregrid.Edge do
  @moduledoc false

  def claim(table, object, counter_table, counter_key, limit) do
    with :ok <- Wiregrid.Capacity.reserve(counter_table, counter_key, limit) do
      if :ets.insert_new(table, object) do
        :new
      else
        _ = Wiregrid.Capacity.release(counter_table, counter_key)
        :existing
      end
    end
  end

  def release(table, key, counter_table, counter_key) do
    case :ets.take(table, key) do
      [] ->
        :missing

      [_object] ->
        _ = Wiregrid.Capacity.release(counter_table, counter_key)
        :released
    end
  end
end
