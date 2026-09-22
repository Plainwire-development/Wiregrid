defmodule Wiregrid.Expiry do
  @moduledoc false
  use GenServer

  @max_schedule_retries 32

  def start_link({instance, config}) do
    GenServer.start_link(__MODULE__, {instance, config}, name: via(instance))
  end

  def via(instance), do: {:via, Registry, {Wiregrid.ProcessRegistry, {:expiry, instance}}}

  def schedule(instance, kind, key, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    schedule_at(instance, kind, key, System.monotonic_time(:millisecond) + ttl_ms)
  end

  def schedule(_instance, _kind, _key, _ttl), do: {:error, :invalid_ttl}

  def schedule_at(instance, kind, key, deadline) when is_integer(deadline) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t, config: cfg} ->
        schedule_retry(t, {kind, key}, deadline, 0, cfg.max_expiry_entries)

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def schedule_at(_instance, _kind, _key, _deadline), do: {:error, :invalid_deadline}

  def cancel(instance, kind, key) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        index_key = {kind, key}

        case :ets.take(t.expiry_index, index_key) do
          [{^index_key, deadline, token}] ->
            :ets.delete(t.expiry, {deadline, token})
            _ = Wiregrid.Capacity.release(t.capacity, :expiry_entries)
            :ok

          [] ->
            :ok
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  @impl true
  def init({instance, config}) do
    Process.send_after(self(), :tick, config.expiry_tick_ms)
    {:ok, %{instance: instance, config: config}}
  end

  @impl true
  def handle_info(:tick, state) do
    expire_due(state.instance, state.config.expiry_batch_size)
    Process.send_after(self(), :tick, state.config.expiry_tick_ms)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp schedule_retry(_t, _index_key, _deadline, attempts, _limit)
       when attempts >= @max_schedule_retries,
       do: {:error, :expiry_contention}

  defp schedule_retry(t, index_key, deadline, attempts, limit) do
    token = unique_token(t)
    ordered_key = {deadline, token}
    true = :ets.insert(t.expiry, {ordered_key, index_key})

    case :ets.lookup(t.expiry_index, index_key) do
      [] ->
        case Wiregrid.Capacity.reserve(t.capacity, :expiry_entries, limit) do
          :ok ->
            if :ets.insert_new(t.expiry_index, {index_key, deadline, token}) do
              :ok
            else
              :ets.delete(t.expiry, ordered_key)
              _ = Wiregrid.Capacity.release(t.capacity, :expiry_entries)
              schedule_retry(t, index_key, deadline, attempts + 1, limit)
            end

          {:error, :capacity} ->
            :ets.delete(t.expiry, ordered_key)
            {:error, :expiry_capacity}

          {:error, _} = error ->
            :ets.delete(t.expiry, ordered_key)
            error
        end

      [{^index_key, old_deadline, old_token}] ->
        old_index = {index_key, old_deadline, old_token}
        new_index = {index_key, deadline, token}

        if replace_exact(t.expiry_index, old_index, new_index) do
          :ets.delete(t.expiry, {old_deadline, old_token})
          :ok
        else
          :ets.delete(t.expiry, ordered_key)
          schedule_retry(t, index_key, deadline, attempts + 1, limit)
        end
    end
  end

  defp expire_due(instance, max_items) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        expire_loop(
          instance,
          t,
          :ets.first(t.expiry),
          max_items,
          System.monotonic_time(:millisecond)
        )

      _ ->
        :ok
    end
  end

  defp expire_loop(_instance, _tables, _key, 0, _now), do: :ok
  defp expire_loop(_instance, _tables, :"$end_of_table", _remaining, _now), do: :ok

  defp expire_loop(instance, tables, {deadline, token} = ordered_key, remaining, now) do
    if deadline <= now do
      next = :ets.next(tables.expiry, ordered_key)

      case :ets.take(tables.expiry, ordered_key) do
        [{^ordered_key, {kind, key}}] ->
          index_key = {kind, key}

          case :ets.lookup(tables.expiry_index, index_key) do
            [{^index_key, ^deadline, ^token}] ->
              :ets.delete(tables.expiry_index, index_key)
              _ = Wiregrid.Capacity.release(tables.capacity, :expiry_entries)
              dispatch(instance, kind, key, deadline)

            _ ->
              :ok
          end

        [] ->
          :ok
      end

      expire_loop(instance, tables, next, remaining - 1, now)
    else
      :ok
    end
  end

  defp dispatch(instance, :resume_snapshot, key, _deadline),
    do: Wiregrid.Runtime.expire_resume(instance, key)

  defp dispatch(instance, :room_grace, key, _deadline),
    do: Wiregrid.Runtime.expire_room_grace(instance, key)

  defp dispatch(instance, :room, key, deadline),
    do: Wiregrid.Runtime.expire_room_at(instance, key, deadline)

  defp dispatch(instance, :activity, key, deadline),
    do: Wiregrid.Activity.expire(instance, key, deadline)

  defp dispatch(instance, :receipt, key, deadline),
    do: Wiregrid.Receipts.expire(instance, key, deadline)

  defp dispatch(instance, :rate_limit, key, _deadline),
    do: Wiregrid.RateLimiter.expire(instance, key)

  defp dispatch(instance, :memory_cache, key, deadline),
    do: Wiregrid.Cache.Memory.expire(instance, key, deadline)

  defp dispatch(instance, :cluster_seen, key, _deadline),
    do: Wiregrid.Cluster.expire_seen(instance, key)

  defp dispatch(_instance, _kind, _key, _deadline), do: :ok

  defp unique_token(tables) do
    case :wiregrid_hot.counter_add(tables.capacity, :expiry_sequence, 1) do
      {:ok, value} -> value
      _ -> System.unique_integer([:positive, :monotonic])
    end
  end

  defp replace_exact(table, old, replacement) do
    :ets.select_replace(table, [{old, [], [{:const, replacement}]}]) == 1
  end
end
