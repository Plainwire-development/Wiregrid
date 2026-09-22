defmodule Wiregrid.Storage.Scylla do
  @moduledoc "Partition-bounded ScyllaDB/Cassandra storage using time-bucketed streams."
  @behaviour Wiregrid.Storage

  @default_bucket_ms 86_400_000
  @bucket_page 64
  @max_blob_bytes 16_777_216

  @impl true
  def bootstrap(opts) do
    with {:ok, client, conn} <- client(opts),
         {:ok, keyspace} <- keyspace(opts),
         {:ok, replication_factor} <- replication_factor(opts) do
      migration_statements(keyspace, replication_factor)
      |> Enum.reduce_while(:ok, fn statement, :ok ->
        case execute_simple(client, conn, statement) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @impl true
  def append(opts, stream, id, event, meta, inserted_at_ms) do
    with {:ok, bucket_ms} <- bucket_ms(opts),
         {:ok, client, conn} <- client(opts),
         {:ok, keyspace} <- keyspace(opts),
         {:ok, event_bin} <- Wiregrid.SafeTerm.encode(event, @max_blob_bytes),
         {:ok, meta_bin} <- Wiregrid.SafeTerm.encode(meta, @max_blob_bytes),
         bucket <- div(inserted_at_ms, bucket_ms),
         {:ok, p_claim} <- prepare(client, conn, insert_lookup_sql(keyspace)),
         {:ok, _claim_result} <-
           execute_prepared(client, conn, p_claim, [
             stream,
             id,
             bucket,
             inserted_at_ms,
             event_bin,
             meta_bin
           ]),
         {:ok, canonical} <- canonical_lookup(client, conn, keyspace, stream, id),
         :ok <- ensure_event(client, conn, keyspace, stream, id, canonical),
         :ok <- ensure_bucket(client, conn, keyspace, stream, canonical.bucket) do
      :ok
    end
  end

  @impl true
  def get(opts, stream, id) do
    with {:ok, client, conn} <- client(opts),
         {:ok, keyspace} <- keyspace(opts) do
      case canonical_lookup(client, conn, keyspace, stream, id) do
        {:ok, lookup} ->
          with {:ok, p_event} <- prepare(client, conn, get_event_sql(keyspace)),
               {:ok, result} <-
                 execute_prepared(client, conn, p_event, [
                   stream,
                   lookup.bucket,
                   lookup.inserted_at_ms,
                   id
                 ]),
               {:ok, rows} <- result_rows(result) do
            case rows do
              [] ->
                # The lookup row is the canonical idempotency record. If a writer
                # crashed after claiming the ID but before materializing the
                # time-bucket row, a read repairs that secondary state and can
                # still return the canonical event immediately.
                with :ok <- ensure_event(client, conn, keyspace, stream, id, lookup),
                     :ok <- ensure_bucket(client, conn, keyspace, stream, lookup.bucket),
                     {:ok, decoded} <- decode_lookup(id, lookup) do
                  {:ok, decoded}
                end

              [event_row | _] ->
                decode_event_row(event_row)
            end
          end

        :not_found ->
          :not_found

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def page(opts, stream, cursor, limit) do
    max_id = Keyword.get(opts, :max_storage_id_bytes, 256)

    with {:ok, bucket_ms} <- bucket_ms(opts),
         {:ok, decoded} <- Wiregrid.Storage.Cursor.decode(cursor, max_id),
         {:ok, client, conn} <- client(opts),
         {:ok, keyspace} <- keyspace(opts) do
      start_bucket =
        case decoded do
          nil -> -1
          {ts, _id} -> div(ts, bucket_ms)
        end

      collect_pages(
        client,
        conn,
        keyspace,
        stream,
        decoded,
        start_bucket,
        bucket_ms,
        limit,
        [],
        0
      )
    end
  end

  @impl true
  def delete(opts, stream, id) do
    with {:ok, client, conn} <- client(opts),
         {:ok, keyspace} <- keyspace(opts) do
      case canonical_lookup(client, conn, keyspace, stream, id) do
        :not_found ->
          :ok

        {:ok, lookup} ->
          with {:ok, p_event} <- prepare(client, conn, delete_event_sql(keyspace)),
               {:ok, _} <-
                 execute_prepared(client, conn, p_event, [
                   stream,
                   lookup.bucket,
                   lookup.inserted_at_ms,
                   id
                 ]),
               {:ok, p_lookup} <- prepare(client, conn, delete_lookup_sql(keyspace)),
               {:ok, _} <- execute_prepared(client, conn, p_lookup, [stream, id]) do
            :ok
          end

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def prune(opts, stream, before_ms, limit) do
    prune_loop(opts, stream, before_ms, limit, 0)
  end

  @impl true
  def health(opts) do
    with {:ok, client, conn} <- client(opts) do
      execute_simple(client, conn, "SELECT now() FROM system.local")
    end
  end

  def migration_statements(keyspace), do: migration_statements(keyspace, 3)

  def migration_statements(keyspace, replication_factor)
      when is_integer(replication_factor) and replication_factor in 1..16 do
    [
      "CREATE KEYSPACE IF NOT EXISTS #{keyspace} WITH replication = {'class': 'NetworkTopologyStrategy', 'replication_factor': #{replication_factor}}",
      """
      CREATE TABLE IF NOT EXISTS #{keyspace}.wiregrid_events (
        stream blob,
        bucket bigint,
        inserted_at_ms bigint,
        id blob,
        event blob,
        meta blob,
        PRIMARY KEY ((stream, bucket), inserted_at_ms, id)
      ) WITH CLUSTERING ORDER BY (inserted_at_ms ASC, id ASC)
      """,
      """
      CREATE TABLE IF NOT EXISTS #{keyspace}.wiregrid_event_lookup (
        stream blob,
        id blob,
        bucket bigint,
        inserted_at_ms bigint,
        event blob,
        meta blob,
        PRIMARY KEY ((stream, id))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{keyspace}.wiregrid_stream_buckets (
        stream blob,
        bucket bigint,
        PRIMARY KEY ((stream), bucket)
      ) WITH CLUSTERING ORDER BY (bucket ASC)
      """
    ]
  end

  defp prune_loop(_opts, _stream, _before_ms, limit, deleted) when deleted >= limit,
    do: {:ok, deleted}

  defp prune_loop(opts, stream, before_ms, limit, deleted) do
    page_size = min(limit - deleted, 1_000)

    case page(opts, stream, nil, page_size) do
      {:ok, [], _} ->
        {:ok, deleted}

      {:ok, rows, _next} ->
        doomed = Enum.take_while(rows, &(&1.inserted_at_ms < before_ms))

        cond do
          doomed == [] ->
            {:ok, deleted}

          true ->
            case delete_rows(opts, stream, doomed) do
              :ok -> prune_loop(opts, stream, before_ms, limit, deleted + length(doomed))
              {:error, _} = error -> error
            end
        end

      {:error, _} = error ->
        error
    end
  end

  defp delete_rows(opts, stream, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case delete(opts, stream, row.id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp canonical_lookup(client, conn, keyspace, stream, id) do
    with {:ok, p_lookup} <- prepare(client, conn, get_lookup_sql(keyspace)),
         {:ok, lookup_result} <- execute_prepared(client, conn, p_lookup, [stream, id]),
         {:ok, lookup_rows} <- result_rows(lookup_result) do
      case lookup_rows do
        [] ->
          :not_found

        [row | _] ->
          bucket = fetch(row, :bucket)
          inserted_at_ms = fetch(row, :inserted_at_ms)
          event = fetch(row, :event)
          meta = fetch(row, :meta)

          if is_integer(bucket) and is_integer(inserted_at_ms) and is_binary(event) and
               is_binary(meta) do
            {:ok, %{bucket: bucket, inserted_at_ms: inserted_at_ms, event: event, meta: meta}}
          else
            {:error, :unexpected_scylla_lookup_row}
          end
      end
    end
  end

  defp ensure_event(client, conn, keyspace, stream, id, lookup) do
    with {:ok, prepared} <- prepare(client, conn, insert_event_sql(keyspace)),
         {:ok, _} <-
           execute_prepared(client, conn, prepared, [
             stream,
             lookup.bucket,
             lookup.inserted_at_ms,
             id,
             lookup.event,
             lookup.meta
           ]) do
      :ok
    end
  end

  defp ensure_bucket(client, conn, keyspace, stream, bucket) do
    with {:ok, prepared} <- prepare(client, conn, insert_bucket_sql(keyspace)),
         {:ok, _} <- execute_prepared(client, conn, prepared, [stream, bucket]) do
      :ok
    end
  end

  defp collect_pages(
         client,
         conn,
         keyspace,
         stream,
         cursor,
         bucket_cursor,
         bucket_ms,
         limit,
         acc,
         count
       ) do
    target = limit + 1

    if count >= target do
      finish_page_reversed(acc, count, limit)
    else
      with {:ok, p_buckets} <- prepare(client, conn, buckets_sql(keyspace)),
           {:ok, bucket_result} <-
             execute_prepared(client, conn, p_buckets, [stream, bucket_cursor, @bucket_page]),
           {:ok, bucket_rows} <- result_rows(bucket_result) do
        buckets = Enum.map(bucket_rows, &fetch(&1, :bucket)) |> Enum.filter(&is_integer/1)

        case collect_buckets(
               client,
               conn,
               keyspace,
               stream,
               buckets,
               cursor,
               bucket_ms,
               target - count,
               acc,
               count
             ) do
          {:ok, next_acc, next_count} when next_count >= target ->
            finish_page_reversed(next_acc, next_count, limit)

          {:ok, next_acc, next_count} ->
            if length(buckets) < @bucket_page do
              finish_page_reversed(next_acc, next_count, limit)
            else
              collect_pages(
                client,
                conn,
                keyspace,
                stream,
                cursor,
                List.last(buckets) + 1,
                bucket_ms,
                limit,
                next_acc,
                next_count
              )
            end

          {:error, _} = error ->
            error
        end
      end
    end
  end

  defp collect_buckets(
         _client,
         _conn,
         _keyspace,
         _stream,
         [],
         _cursor,
         _bucket_ms,
         _needed,
         acc,
         count
       ),
       do: {:ok, acc, count}

  defp collect_buckets(
         _client,
         _conn,
         _keyspace,
         _stream,
         _buckets,
         _cursor,
         _bucket_ms,
         needed,
         acc,
         count
       )
       when needed <= 0,
       do: {:ok, acc, count}

  defp collect_buckets(
         client,
         conn,
         keyspace,
         stream,
         [bucket | rest],
         cursor,
         bucket_ms,
         needed,
         acc,
         count
       ) do
    cursor_in_bucket =
      case cursor do
        {ts, id} when div(ts, bucket_ms) == bucket -> {ts, id}
        _ -> nil
      end

    {sql, params} =
      case cursor_in_bucket do
        {ts, id} -> {events_after_sql(keyspace), [stream, bucket, ts, id, needed]}
        nil -> {events_sql(keyspace), [stream, bucket, needed]}
      end

    with {:ok, prepared} <- prepare(client, conn, sql),
         {:ok, result} <- execute_prepared(client, conn, prepared, params),
         {:ok, rows} <- result_rows(result),
         {:ok, decoded} <- decode_rows(rows) do
      decoded_count = length(decoded)
      next_acc = Enum.reduce(decoded, acc, fn row, rows_acc -> [row | rows_acc] end)

      collect_buckets(
        client,
        conn,
        keyspace,
        stream,
        rest,
        cursor,
        bucket_ms,
        needed - decoded_count,
        next_acc,
        count + decoded_count
      )
    end
  end

  defp finish_page_reversed(acc, count, limit) do
    rows = Enum.reverse(acc)
    page = Enum.take(rows, limit)
    next_cursor = if count > limit, do: cursor_for(List.last(page)), else: nil
    {:ok, page, next_cursor}
  end

  defp client(opts) do
    client = Keyword.get(opts, :client_module, Module.concat(["Xandra"]))
    conn = Keyword.get(opts, :conn)
    if is_nil(conn), do: {:error, :scylla_connection_required}, else: {:ok, client, conn}
  end

  defp keyspace(opts) do
    value = Keyword.get(opts, :keyspace, "wiregrid")
    if valid_identifier?(value), do: {:ok, value}, else: {:error, :invalid_keyspace}
  end

  defp bucket_ms(opts) do
    case Keyword.get(opts, :bucket_ms, @default_bucket_ms) do
      value when is_integer(value) and value > 0 and value <= 31 * @default_bucket_ms ->
        {:ok, value}

      _ ->
        {:error, :invalid_bucket_ms}
    end
  end

  defp replication_factor(opts) do
    case Keyword.get(opts, :replication_factor, 3) do
      value when is_integer(value) and value in 1..16 -> {:ok, value}
      _ -> {:error, :invalid_replication_factor}
    end
  end

  defp valid_identifier?(value) when is_binary(value) and byte_size(value) in 1..48 do
    chars = :binary.bin_to_list(value)
    first = hd(chars)
    valid_first = first in ?a..?z or first in ?A..?Z or first == ?_

    valid_rest =
      Enum.all?(chars, fn ch -> ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9 or ch == ?_ end)

    valid_first and valid_rest
  end

  defp valid_identifier?(_), do: false

  defp prepare(client, conn, statement) do
    case apply(client, :prepare, [conn, statement]) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_scylla_prepare_result, other}}
    end
  rescue
    _ -> {:error, :scylla_prepare_failed}
  end

  defp execute_prepared(client, conn, prepared, params) do
    case apply(client, :execute, [conn, prepared, params, []]) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_scylla_result, other}}
    end
  rescue
    _ -> {:error, :scylla_execute_failed}
  end

  defp execute_simple(client, conn, statement) do
    case apply(client, :execute, [conn, statement, [], []]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_scylla_result, other}}
    end
  rescue
    _ -> {:error, :scylla_execute_failed}
  end

  defp result_rows(result) do
    cond do
      is_map(result) and Map.has_key?(result, :content) -> {:ok, Enum.to_list(result.content)}
      Enumerable.impl_for(result) != nil -> {:ok, Enum.to_list(result)}
      true -> {:error, :unexpected_scylla_result}
    end
  rescue
    _ -> {:error, :unexpected_scylla_result}
  end

  defp decode_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case decode_event_row(row) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp decode_event_row(row) do
    id = fetch(row, :id)
    inserted_at_ms = fetch(row, :inserted_at_ms)

    with true <- is_binary(id) and is_integer(inserted_at_ms),
         {:ok, event} <- Wiregrid.SafeTerm.decode(fetch(row, :event), @max_blob_bytes),
         {:ok, meta} <- Wiregrid.SafeTerm.decode(fetch(row, :meta), @max_blob_bytes) do
      {:ok, %{id: id, event: event, meta: meta, inserted_at_ms: inserted_at_ms}}
    else
      _ -> {:error, :decode_failed}
    end
  end

  defp decode_lookup(id, lookup) when is_binary(id) do
    with true <- is_integer(lookup.inserted_at_ms),
         {:ok, event} <- Wiregrid.SafeTerm.decode(lookup.event, @max_blob_bytes),
         {:ok, meta} <- Wiregrid.SafeTerm.decode(lookup.meta, @max_blob_bytes) do
      {:ok, %{id: id, event: event, meta: meta, inserted_at_ms: lookup.inserted_at_ms}}
    else
      _ -> {:error, :decode_failed}
    end
  end

  defp fetch(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp insert_bucket_sql(keyspace),
    do: "INSERT INTO #{keyspace}.wiregrid_stream_buckets (stream,bucket) VALUES (?,?)"

  defp insert_event_sql(keyspace),
    do:
      "INSERT INTO #{keyspace}.wiregrid_events (stream,bucket,inserted_at_ms,id,event,meta) VALUES (?,?,?,?,?,?)"

  defp insert_lookup_sql(keyspace),
    do:
      "INSERT INTO #{keyspace}.wiregrid_event_lookup (stream,id,bucket,inserted_at_ms,event,meta) VALUES (?,?,?,?,?,?) IF NOT EXISTS"

  defp get_lookup_sql(keyspace),
    do:
      "SELECT bucket,inserted_at_ms,event,meta FROM #{keyspace}.wiregrid_event_lookup WHERE stream=? AND id=?"

  defp get_event_sql(keyspace),
    do:
      "SELECT id,event,meta,inserted_at_ms FROM #{keyspace}.wiregrid_events WHERE stream=? AND bucket=? AND inserted_at_ms=? AND id=?"

  defp delete_event_sql(keyspace),
    do:
      "DELETE FROM #{keyspace}.wiregrid_events WHERE stream=? AND bucket=? AND inserted_at_ms=? AND id=?"

  defp delete_lookup_sql(keyspace),
    do: "DELETE FROM #{keyspace}.wiregrid_event_lookup WHERE stream=? AND id=?"

  defp buckets_sql(keyspace),
    do:
      "SELECT bucket FROM #{keyspace}.wiregrid_stream_buckets WHERE stream=? AND bucket>=? LIMIT ?"

  defp events_sql(keyspace),
    do:
      "SELECT id,event,meta,inserted_at_ms FROM #{keyspace}.wiregrid_events WHERE stream=? AND bucket=? LIMIT ?"

  defp events_after_sql(keyspace),
    do:
      "SELECT id,event,meta,inserted_at_ms FROM #{keyspace}.wiregrid_events WHERE stream=? AND bucket=? AND (inserted_at_ms,id)>(?,?) LIMIT ?"

  defp cursor_for(nil), do: nil
  defp cursor_for(%{inserted_at_ms: ts, id: id}), do: Wiregrid.Storage.Cursor.encode(ts, id)
end
