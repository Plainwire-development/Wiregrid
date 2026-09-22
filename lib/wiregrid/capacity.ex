defmodule Wiregrid.Capacity do
  @moduledoc false

  def reserve(counter_table, key, limit) when is_integer(limit) and limit > 0 do
    case :wiregrid_hot.counter_add(counter_table, key, 1) do
      {:ok, value} when value <= limit ->
        :ok

      {:ok, _value} ->
        _ = :wiregrid_hot.counter_add(counter_table, key, -1)
        {:error, :capacity}

      {:error, _} = error ->
        error
    end
  end

  def release(counter_table, key) do
    case :wiregrid_hot.counter_add_clamped(counter_table, key, -1) do
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  def release_many(counter_table, key, count) when is_integer(count) and count > 0 do
    case :wiregrid_hot.counter_add_clamped(counter_table, key, -count) do
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  def release_many(counter_table, key, _count), do: {:ok, get(counter_table, key)}

  def get(counter_table, key), do: :wiregrid_hot.counter_get(counter_table, key)
end
