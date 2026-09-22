defmodule Wiregrid.Storage.Postgres do
  @moduledoc "PostgreSQL adapter using a caller-supplied Postgrex-compatible pool or connection."
  @behaviour Wiregrid.Storage

  @lock_key 7_319_441_002

  @impl true
  def bootstrap(opts) do
    with {:ok, client, conn} <- client(opts) do
      transaction(client, conn, fn tx ->
        with {:ok, _} <- query(client, tx, "SELECT pg_advisory_xact_lock($1)", [@lock_key]),
             :ok <- run_statements(client, tx, migration_statements()) do
          :ok
        end
      end)
    end
  end

  @impl true
  def append(opts, stream, id, event, meta, inserted_at_ms) do
    with {:ok, client, conn} <- client(opts),
         {:ok, event_bin} <- encode(event),
         {:ok, meta_bin} <- encode(meta),
         {:ok, _} <-
           query(client, conn, insert_sql(), [stream, id, event_bin, meta_bin, inserted_at_ms]) do
      :ok
    end
  end

  @impl true
  def get(opts, stream, id) do
    with {:ok, client, conn} <- client(opts),
         {:ok, result} <- query(client, conn, get_sql(), [stream, id]) do
      case rows(result) do
        [[^id, event_bin, meta_bin, inserted_at_ms]] ->
          decode_row(id, event_bin, meta_bin, inserted_at_ms)

        [] ->
          :not_found

        _ ->
          {:error, :unexpected_row_shape}
      end
    end
  end

  @impl true
  def page(opts, stream, cursor, limit) do
    max_id = Keyword.get(opts, :max_storage_id_bytes, 256)

    with {:ok, client, conn} <- client(opts),
         {:ok, decoded} <- Wiregrid.Storage.Cursor.decode(cursor, max_id),
         {ts, id} <- decoded || {-1, ""},
         {:ok, result} <- query(client, conn, page_sql(), [stream, ts, id, limit + 1]),
         {:ok, decoded_rows} <- decode_rows(rows(result)) do
      page = Enum.take(decoded_rows, limit)
      next_cursor = if length(decoded_rows) > limit, do: cursor_for(List.last(page)), else: nil
      {:ok, page, next_cursor}
    end
  end

  @impl true
  def delete(opts, stream, id) do
    with {:ok, client, conn} <- client(opts),
         {:ok, _} <- query(client, conn, delete_sql(), [stream, id]),
         do: :ok
  end

  @impl true
  def prune(opts, stream, before_ms, limit) do
    with {:ok, client, conn} <- client(opts),
         {:ok, result} <- query(client, conn, prune_sql(), [stream, before_ms, limit]) do
      {:ok, Map.get(result, :num_rows, 0)}
    end
  end

  @impl true
  def health(opts) do
    with {:ok, client, conn} <- client(opts),
         {:ok, _} <- query(client, conn, "SELECT 1", []),
         do: :ok
  end

  def migration_statements do
    [
      """
      CREATE TABLE IF NOT EXISTS wiregrid_events (
        stream BYTEA NOT NULL,
        id BYTEA NOT NULL,
        event BYTEA NOT NULL,
        meta BYTEA NOT NULL,
        inserted_at_ms BIGINT NOT NULL,
        PRIMARY KEY (stream, inserted_at_ms, id),
        UNIQUE (stream, id)
      )
      """,
      "CREATE INDEX IF NOT EXISTS wiregrid_events_retention_idx ON wiregrid_events (stream, inserted_at_ms)"
    ]
  end

  defp insert_sql do
    "INSERT INTO wiregrid_events(stream,id,event,meta,inserted_at_ms) VALUES($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING"
  end

  defp get_sql,
    do: "SELECT id,event,meta,inserted_at_ms FROM wiregrid_events WHERE stream=$1 AND id=$2"

  defp page_sql do
    "SELECT id,event,meta,inserted_at_ms FROM wiregrid_events WHERE stream=$1 AND (inserted_at_ms,id) > ($2,$3) ORDER BY inserted_at_ms ASC,id ASC LIMIT $4"
  end

  defp delete_sql, do: "DELETE FROM wiregrid_events WHERE stream=$1 AND id=$2"

  defp prune_sql do
    "WITH doomed AS (SELECT ctid FROM wiregrid_events WHERE stream=$1 AND inserted_at_ms < $2 ORDER BY inserted_at_ms ASC LIMIT $3) DELETE FROM wiregrid_events WHERE ctid IN (SELECT ctid FROM doomed)"
  end

  defp client(opts) do
    module = Keyword.get(opts, :client_module, Module.concat(["Postgrex"]))
    conn = Keyword.get(opts, :conn)
    if is_nil(conn), do: {:error, :postgres_connection_required}, else: {:ok, module, conn}
  end

  defp query(client, conn, sql, params) do
    case apply(client, :query, [conn, sql, params]) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_postgres_result, other}}
    end
  rescue
    _ -> {:error, :postgres_call_failed}
  end

  defp transaction(client, conn, fun) do
    if function_exported?(client, :transaction, 2) do
      case apply(client, :transaction, [conn, fun]) do
        {:ok, :ok} -> :ok
        {:ok, other} -> other
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_transaction_result, other}}
      end
    else
      {:error, :postgres_transaction_required}
    end
  end

  defp run_statements(client, conn, statements) do
    Enum.reduce_while(statements, :ok, fn sql, :ok ->
      case query(client, conn, sql, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp rows(%{rows: rows}) when is_list(rows), do: rows
  defp rows(_), do: []

  defp encode(term), do: Wiregrid.SafeTerm.encode(term, 16_777_216)

  defp decode_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [id, event_bin, meta_bin, inserted_at_ms], {:ok, acc} ->
        case decode_row(id, event_bin, meta_bin, inserted_at_ms) do
          {:ok, row} -> {:cont, {:ok, [row | acc]}}
          {:error, _} = error -> {:halt, error}
        end

      _, _ ->
        {:halt, {:error, :unexpected_row_shape}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp decode_row(id, event_bin, meta_bin, inserted_at_ms) do
    with {:ok, event} <- Wiregrid.SafeTerm.decode(event_bin, 16_777_216),
         {:ok, meta} <- Wiregrid.SafeTerm.decode(meta_bin, 16_777_216) do
      {:ok, %{id: id, event: event, meta: meta, inserted_at_ms: inserted_at_ms}}
    end
  end

  defp cursor_for(nil), do: nil
  defp cursor_for(%{inserted_at_ms: ts, id: id}), do: Wiregrid.Storage.Cursor.encode(ts, id)
end
