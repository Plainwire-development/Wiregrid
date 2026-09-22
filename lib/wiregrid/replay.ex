defmodule Wiregrid.Replay do
  @moduledoc """
  Bounded durable catch-up delivery from a configured Wiregrid storage adapter.

  Replay is deliberately session-scoped. It pages a durable stream, re-encodes
  each stored application event with the configured codec, and feeds it through
  the normal delivery reservation/backpressure path. It never bypasses
  authorization, drain state, event limits, or manual acknowledgement.

  Results include a `:resume_cursor` that advances only after a row has been
  accepted by the delivery path (or intentionally shed as ephemeral). If replay
  stops on pressure, disconnect, or encoding failure, callers can resume from
  that cursor without skipping the unaccepted row.
  """

  @options [:cursor, :limit, :class, :topic]

  @spec to_session(term(), binary(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def to_session(instance, session_id, stream, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @options),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.topic(stream, cfg.max_topic_bytes, cfg.max_topic_depth),
         {:ok, limit} <- replay_limit(Keyword.get(opts, :limit, cfg.max_batch_items), cfg),
         {:ok, class} <- delivery_class(Keyword.get(opts, :class, :durable)),
         topic <- Keyword.get(opts, :topic, stream),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth),
         [{^session_id, session}] <- :ets.lookup(t.sessions, session_id),
         :ok <-
           Wiregrid.Authorizer.check(instance, cfg, :replay, session, stream, %{limit: limit}),
         cursor <- Keyword.get(opts, :cursor),
         {:ok, rows, next_cursor} <- Wiregrid.Storage.page(instance, stream, cursor, limit) do
      deliver_rows(instance, cfg, session_id, topic, rows, class, cursor, next_cursor)
    else
      [] -> {:error, :unknown_session}
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  defp deliver_rows(instance, cfg, session_id, topic, rows, class, initial_cursor, page_cursor) do
    initial = %{delivered: 0, dropped: 0, resume_cursor: initial_cursor, stopped: nil}

    {state, completed?} =
      Enum.reduce_while(rows, {initial, true}, fn row, {state, _} ->
        case deliver_row(instance, cfg, session_id, topic, row, class) do
          :sent ->
            {:cont,
             {%{state | delivered: state.delivered + 1, resume_cursor: row_cursor(row)}, true}}

          :dropped ->
            {:cont, {%{state | dropped: state.dropped + 1, resume_cursor: row_cursor(row)}, true}}

          :excluded ->
            {:cont, {%{state | resume_cursor: row_cursor(row)}, true}}

          reason when reason in [:overloaded, :evicted, :gone] ->
            {:halt, {%{state | stopped: reason}, false}}

          {:error, reason} ->
            {:halt, {%{state | stopped: reason}, false}}
        end
      end)

    {:ok,
     state
     |> Map.put(:next_cursor, if(completed?, do: page_cursor, else: state.resume_cursor))
     |> Map.put(:complete_page, completed?)}
  end

  defp deliver_row(instance, cfg, session_id, topic, row, class)
       when is_map(row) do
    with id when is_binary(id) <- Map.get(row, :id),
         inserted_at when is_integer(inserted_at) and inserted_at >= 0 <-
           Map.get(row, :inserted_at_ms),
         true <- Map.has_key?(row, :event),
         event <- Map.fetch!(row, :event),
         :ok <- Wiregrid.Validation.binary_id(id, cfg.max_storage_id_bytes),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event) do
      context = %{kind: :replay, storage_id: id, inserted_at_ms: inserted_at}

      Wiregrid.Delivery.send_session(instance, session_id, topic, payload, event, class,
        delivery_context: context
      )
    else
      false -> {:error, :invalid_storage_row}
      nil -> {:error, :invalid_storage_row}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_storage_row}
    end
  end

  defp deliver_row(_instance, _cfg, _session_id, _topic, _row, _class),
    do: {:error, :invalid_storage_row}

  defp row_cursor(%{inserted_at_ms: ts, id: id}) when is_integer(ts) and is_binary(id),
    do: Wiregrid.Storage.Cursor.encode(ts, id)

  defp replay_limit(limit, cfg)
       when is_integer(limit) and limit > 0 and limit <= 1_000 and limit <= cfg.max_batch_items,
       do: {:ok, limit}

  defp replay_limit(_limit, _cfg), do: {:error, :invalid_limit}

  defp delivery_class(class) when class in [:durable, :ephemeral], do: {:ok, class}
  defp delivery_class(_), do: {:error, :invalid_event_class}

  defp accepting(instance), do: Wiregrid.Runtime.accepting(instance)
end
