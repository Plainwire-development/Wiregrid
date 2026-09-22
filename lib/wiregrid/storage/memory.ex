defmodule Wiregrid.Storage.Memory do
  @moduledoc "Bounded in-VM event storage with stable composite cursors."
  @behaviour Wiregrid.Storage

  @impl true
  def bootstrap(_opts), do: :ok

  @impl true
  def append(opts, stream, id, event, meta, inserted_at_ms) do
    with {:ok, t, cfg} <- tables(opts) do
      id_key = {stream, id}
      event_key = {stream, inserted_at_ms, id}
      owner = {id_key, event_key, event, meta}

      case :ets.lookup(t.memory_event_ids, id_key) do
        [{^id_key, _existing_key, _existing_event, _existing_meta}] ->
          repair_secondary(t, id_key)
          :ok

        [] ->
          append_new(t, cfg, id_key, owner)
      end
    end
  end

  defp append_new(t, cfg, id_key, owner) do
    case Wiregrid.Capacity.reserve(t.capacity, :memory_events, cfg.max_memory_events) do
      :ok ->
        if :ets.insert_new(t.memory_event_ids, owner) do
          {^id_key, event_key, _event, _meta} = owner
          true = :ets.insert(t.memory_events, {event_key, id_key})
          :ok
        else
          _ = Wiregrid.Capacity.release(t.capacity, :memory_events)
          repair_secondary(t, id_key)
          :ok
        end

      {:error, :capacity} = error ->
        # Idempotent retries for an already-owned ID must remain successful even
        # when the store is otherwise full. Recheck after the failed reservation
        # because another writer may have claimed this ID concurrently.
        case :ets.lookup(t.memory_event_ids, id_key) do
          [{^id_key, _existing_key, _existing_event, _existing_meta}] ->
            repair_secondary(t, id_key)
            :ok

          [] ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def get(opts, stream, id) do
    with {:ok, t, _cfg} <- tables(opts) do
      case :ets.lookup(t.memory_event_ids, {stream, id}) do
        [{{^stream, ^id}, event_key, event, meta}] -> {:ok, row(event_key, event, meta)}
        [] -> :not_found
      end
    end
  end

  @impl true
  def page(opts, stream, cursor, limit) do
    with {:ok, t, cfg} <- tables(opts),
         {:ok, decoded} <- Wiregrid.Storage.Cursor.decode(cursor, cfg.max_storage_id_bytes) do
      start_key =
        case decoded do
          nil -> {stream, -1, <<>>}
          {ts, id} -> {stream, ts, id}
        end

      next = :ets.next(t.memory_events, start_key)
      {rows, more?} = collect(t, stream, next, limit + 1, [])
      page = Enum.take(rows, limit)
      next_cursor = if more? or length(rows) > limit, do: cursor_for(List.last(page)), else: nil
      {:ok, page, next_cursor}
    end
  end

  @impl true
  def delete(opts, stream, id) do
    with {:ok, t, _cfg} <- tables(opts) do
      id_key = {stream, id}

      case :ets.take(t.memory_event_ids, id_key) do
        [{^id_key, event_key, _event, _meta}] ->
          :ets.delete(t.memory_events, event_key)
          _ = Wiregrid.Capacity.release(t.capacity, :memory_events)
          :ok

        [] ->
          :ok
      end
    end
  end

  @impl true
  def prune(opts, stream, before_ms, limit) do
    with {:ok, t, _cfg} <- tables(opts) do
      first = :ets.next(t.memory_events, {stream, -1, <<>>})
      {count, _next} = prune_loop(t, stream, first, before_ms, limit, 0)
      {:ok, count}
    end
  end

  @impl true
  def health(opts) do
    case tables(opts) do
      {:ok, _t, _cfg} -> :ok
      {:error, _} = error -> error
    end
  end

  defp tables(opts) do
    instance = Keyword.get(opts, :instance)

    case Wiregrid.Tables.get(instance) do
      %{tables: t, config: cfg} -> {:ok, t, cfg}
      _ -> {:error, :instance_unavailable}
    end
  end

  defp collect(_t, _stream, :"$end_of_table", _remaining, acc), do: {Enum.reverse(acc), false}
  defp collect(_t, _stream, _key, 0, acc), do: {Enum.reverse(acc), true}

  defp collect(t, stream, {stream, _ts, _id} = event_key, remaining, acc) do
    next = :ets.next(t.memory_events, event_key)

    case :ets.lookup(t.memory_events, event_key) do
      [{^event_key, id_key}] ->
        case :ets.lookup(t.memory_event_ids, id_key) do
          [{^id_key, ^event_key, event, meta}] ->
            collect(t, stream, next, remaining - 1, [row(event_key, event, meta) | acc])

          _ ->
            :ets.delete(t.memory_events, event_key)
            collect(t, stream, next, remaining, acc)
        end

      [] ->
        collect(t, stream, next, remaining, acc)
    end
  end

  defp collect(_t, _stream, _other_key, _remaining, acc), do: {Enum.reverse(acc), false}

  defp prune_loop(_t, _stream, :"$end_of_table", _before, _limit, count), do: {count, :done}
  defp prune_loop(_t, _stream, key, _before, limit, count) when count >= limit, do: {count, key}

  defp prune_loop(t, stream, {stream, ts, _id} = event_key, before, limit, count)
       when ts < before do
    next = :ets.next(t.memory_events, event_key)

    case :ets.take(t.memory_events, event_key) do
      [{^event_key, id_key}] ->
        case :ets.take(t.memory_event_ids, id_key) do
          [{^id_key, ^event_key, _event, _meta}] ->
            _ = Wiregrid.Capacity.release(t.capacity, :memory_events)
            prune_loop(t, stream, next, before, limit, count + 1)

          _ ->
            prune_loop(t, stream, next, before, limit, count)
        end

      [] ->
        prune_loop(t, stream, next, before, limit, count)
    end
  end

  defp prune_loop(_t, _stream, key, _before, _limit, count), do: {count, key}

  defp repair_secondary(t, id_key) do
    case :ets.lookup(t.memory_event_ids, id_key) do
      [{^id_key, event_key, _event, _meta}] -> :ets.insert(t.memory_events, {event_key, id_key})
      [] -> false
    end
  end

  defp row({_stream, inserted_at_ms, id}, event, meta),
    do: %{id: id, event: event, meta: meta, inserted_at_ms: inserted_at_ms}

  defp cursor_for(nil), do: nil
  defp cursor_for(%{inserted_at_ms: ts, id: id}), do: Wiregrid.Storage.Cursor.encode(ts, id)
end
