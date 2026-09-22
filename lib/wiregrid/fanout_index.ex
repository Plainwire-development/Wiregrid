defmodule Wiregrid.FanoutIndex do
  @moduledoc false
  import Bitwise

  @type kind :: :topic | :room | :presence

  # Secondary fanout indexes are deliberately rebuildable. The authoritative
  # lifecycle edges live in subscription_edges/room_edges/presence_watch_edges.
  # A stale active-bit can only cause an empty bucket probe; it can never grant
  # membership or resurrect an edge.
  def rebuild(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        Enum.each(
          [
            t.topic_sessions,
            t.room_sessions,
            t.presence_watchers,
            t.topic_bucket_masks,
            t.room_bucket_masks,
            t.presence_watcher_bucket_masks
          ],
          &:ets.delete_all_objects/1
        )

        :ets.foldl(
          fn {{session_id, topic}, true}, :ok ->
            add(t, :topic, topic, session_id, cfg.fanout_buckets)
            :ok
          end,
          :ok,
          t.subscription_edges
        )

        :ets.foldl(
          fn {{room, session_id}, _member}, :ok ->
            add(t, :room, room, session_id, cfg.fanout_buckets)
            :ok
          end,
          :ok,
          t.room_edges
        )

        :ets.foldl(
          fn {{session_id, user_id}, true}, :ok ->
            add(t, :presence, user_id, session_id, cfg.fanout_buckets)
            :ok
          end,
          :ok,
          t.presence_watch_edges
        )

        :ok

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def add(tables, kind, subject, session_id, bucket_count)
      when is_binary(session_id) and is_integer(bucket_count) and bucket_count > 0 do
    {edge_table, mask_table} = tables_for(tables, kind)
    bucket = :erlang.phash2(session_id, bucket_count)

    # Activate first. A crash between this write and the edge write leaves at
    # worst a harmless empty bucket, never a missing live edge after recovery.
    activate(mask_table, subject, bucket)
    true = :ets.insert(edge_table, {{subject, bucket, session_id}, true})
    :ok
  end

  def delete(tables, kind, subject, session_id, bucket_count)
      when is_binary(session_id) and is_integer(bucket_count) and bucket_count > 0 do
    {edge_table, mask_table} = tables_for(tables, kind)
    bucket = :erlang.phash2(session_id, bucket_count)
    :ets.delete(edge_table, {subject, bucket, session_id})

    unless bucket_has_members?(edge_table, subject, bucket) do
      deactivate(mask_table, subject, bucket)
    end

    :ok
  end

  def reduce(tables, kind, subject, acc, fun) when is_function(fun, 2) do
    {edge_table, mask_table} = tables_for(tables, kind)

    case :ets.lookup(mask_table, subject) do
      [{^subject, mask}] when is_integer(mask) and mask > 0 ->
        reduce_buckets(edge_table, subject, mask, 0, acc, fun)

      _ ->
        acc
    end
  end

  def take(tables, kind, subject, limit) when is_integer(limit) and limit >= 0 do
    reduce(tables, kind, subject, {[], 0}, fn session_id, {items, count} ->
      if count >= limit do
        {:halt, {items, count}}
      else
        {:cont, {[session_id | items], count + 1}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  def active_bucket_count(tables, kind, subject) do
    {_edge_table, mask_table} = tables_for(tables, kind)

    case :ets.lookup(mask_table, subject) do
      [{^subject, mask}] -> popcount(mask, 0)
      _ -> 0
    end
  end

  defp reduce_buckets(_table, _subject, 0, _bucket, acc, _fun), do: acc

  defp reduce_buckets(table, subject, mask, bucket, acc, fun) do
    if (mask &&& 1) == 1 do
      case reduce_bucket(table, subject, bucket, acc, fun) do
        {:halt, halted} -> halted
        {:cont, next} -> reduce_buckets(table, subject, mask >>> 1, bucket + 1, next, fun)
      end
    else
      reduce_buckets(table, subject, mask >>> 1, bucket + 1, acc, fun)
    end
  end

  defp reduce_bucket(table, subject, bucket, acc, fun) do
    # Session IDs are non-empty binaries. Integer 0 sorts before binaries in
    # Erlang term ordering, giving us a stable lower-bound key without an
    # allocated recipient list.
    walk_bucket(table, subject, bucket, :ets.next(table, {subject, bucket, 0}), acc, fun)
  end

  defp walk_bucket(_table, _subject, _bucket, :"$end_of_table", acc, _fun), do: {:cont, acc}

  defp walk_bucket(table, subject, bucket, {subject, bucket, session_id} = key, acc, fun) do
    # Capture the successor before invoking the callback so lifecycle callbacks
    # may safely delete the current edge while a bucket is being traversed.
    next_key = :ets.next(table, key)

    case fun.(session_id, acc) do
      {:halt, next} -> {:halt, next}
      {:cont, next} -> walk_bucket(table, subject, bucket, next_key, next, fun)
      next -> walk_bucket(table, subject, bucket, next_key, next, fun)
    end
  end

  defp walk_bucket(_table, _subject, _bucket, _other_key, acc, _fun), do: {:cont, acc}

  defp bucket_has_members?(table, subject, bucket) do
    case :ets.next(table, {subject, bucket, 0}) do
      {^subject, ^bucket, _session_id} -> true
      _ -> false
    end
  end

  defp activate(mask_table, subject, bucket) do
    bit = 1 <<< bucket

    case :ets.lookup(mask_table, subject) do
      [{^subject, mask}] ->
        if (mask &&& bit) == 0, do: true = :ets.insert(mask_table, {subject, mask ||| bit})

      [] ->
        true = :ets.insert(mask_table, {subject, bit})
    end

    :ok
  end

  defp deactivate(mask_table, subject, bucket) do
    bit = 1 <<< bucket

    case :ets.lookup(mask_table, subject) do
      [{^subject, mask}] ->
        next = mask &&& bnot(bit)

        if next == 0,
          do: :ets.delete(mask_table, subject),
          else: true = :ets.insert(mask_table, {subject, next})

      [] ->
        :ok
    end

    :ok
  end

  defp popcount(0, count), do: count
  defp popcount(value, count), do: popcount(value &&& value - 1, count + 1)

  defp tables_for(t, :topic), do: {t.topic_sessions, t.topic_bucket_masks}
  defp tables_for(t, :room), do: {t.room_sessions, t.room_bucket_masks}
  defp tables_for(t, :presence), do: {t.presence_watchers, t.presence_watcher_bucket_masks}
end
