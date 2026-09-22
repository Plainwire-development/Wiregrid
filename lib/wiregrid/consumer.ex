defmodule Wiregrid.Consumer do
  @moduledoc """
  Safe helpers for in-process Wiregrid delivery consumers.

  `consume/3` invokes the application handler and acknowledges a delivery only
  after the handler reports success. Handler exceptions deliberately propagate:
  a crashing consumer must not release backpressure for work it did not finish.
  """

  @type envelope :: map()

  @spec event(term(), envelope()) :: {:ok, term()} | {:error, term()}
  def event(instance, envelope) when is_map(envelope) do
    case Map.fetch(envelope, :event) do
      {:ok, event} ->
        {:ok, event}

      :error ->
        case Map.fetch(envelope, :payload) do
          {:ok, payload} when is_binary(payload) -> Wiregrid.decode_payload(instance, payload)
          _ -> {:error, :missing_delivery_payload}
        end
    end
  end

  def event(_instance, _envelope), do: {:error, :invalid_delivery}

  @spec ack(term(), envelope()) :: {:ok, non_neg_integer()} | {:error, term()}
  def ack(instance, envelope) when is_map(envelope) do
    with {:ok, session_id} <- Map.fetch(envelope, :session_id),
         {:ok, delivery_id} <- Map.fetch(envelope, :delivery_id) do
      Wiregrid.ack(instance, session_id, delivery_id)
    else
      :error -> {:error, :invalid_delivery}
    end
  end

  def ack(_instance, _envelope), do: {:error, :invalid_delivery}

  @spec consume(term(), envelope(), (term(), envelope() -> term())) :: term()
  def consume(instance, envelope, handler) when is_function(handler, 2) do
    with {:ok, value} <- event(instance, envelope) do
      case handler.(value, envelope) do
        :ok -> ack(instance, envelope)
        {:ok, _} -> ack(instance, envelope)
        other -> other
      end
    end
  end

  def consume(_instance, _envelope, _handler), do: {:error, :invalid_handler}

  @doc """
  Consumes a bounded batch of delivery envelopes and acknowledges successes in
  one grouped operation per session.

  The handler is called as `handler.(event, envelope)`. `:ok` and `{:ok, _}`
  mean the delivery was durably handled and may be acknowledged. Any other
  return value leaves the reservation outstanding and is reported as a failed
  item. Handler exceptions intentionally propagate so a crashing consumer never
  releases backpressure for work it did not finish.
  """
  @spec consume_many(term(), [envelope()], (term(), envelope() -> term())) ::
          {:ok, map()} | {:error, term()}
  def consume_many(instance, envelopes, handler)
      when is_list(envelopes) and is_function(handler, 2) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.bounded_list(envelopes, cfg.max_batch_items),
         true <- envelopes != [] do
      {handled, failures, grouped} =
        envelopes
        |> Enum.with_index()
        |> Enum.reduce({0, [], %{}}, fn {envelope, index}, {handled, failures, grouped} ->
          case event(instance, envelope) do
            {:ok, value} ->
              case handler.(value, envelope) do
                :ok ->
                  collect_success(envelope, index, handled, failures, grouped)

                {:ok, _} ->
                  collect_success(envelope, index, handled, failures, grouped)

                other ->
                  {handled, [%{index: index, reason: {:handler_result, other}} | failures],
                   grouped}
              end

            {:error, reason} ->
              {handled, [%{index: index, reason: reason} | failures], grouped}
          end
        end)

      {acked, unknown, ack_errors} = ack_groups(instance, grouped)

      {:ok,
       %{
         handled: handled,
         failed: length(failures),
         acked: acked,
         unknown_acks: unknown,
         ack_errors: Enum.reverse(ack_errors),
         failures: Enum.reverse(failures)
       }}
    else
      false -> {:error, :empty_batch}
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def consume_many(_instance, _envelopes, _handler), do: {:error, :invalid_batch_consumer}

  @doc """
  Consumes a bounded batch in order and stops at the first failed item.

  Successful prefix deliveries are acknowledged in grouped per-session calls.
  The failed delivery and untouched suffix remain reserved so an application can
  retry or recover without falsely releasing backpressure. Handler exceptions
  intentionally propagate for the same reason as `consume/3` and
  `consume_many/3`.
  """
  @spec consume_ordered(term(), [envelope()], (term(), envelope() -> term())) ::
          {:ok, map()} | {:error, map() | term()}
  def consume_ordered(instance, envelopes, handler)
      when is_list(envelopes) and is_function(handler, 2) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.bounded_list(envelopes, cfg.max_batch_items),
         true <- envelopes != [] do
      consume_ordered_loop(instance, envelopes, handler, [], 0)
    else
      false -> {:error, :empty_batch}
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def consume_ordered(_instance, _envelopes, _handler),
    do: {:error, :invalid_batch_consumer}

  defp consume_ordered_loop(instance, [], _handler, successful, handled) do
    with {:ok, acks} <- ack_groups_result(instance, successful) do
      {:ok, %{handled: handled, remaining: 0, acks: acks}}
    end
  end

  defp consume_ordered_loop(instance, [envelope | rest], handler, successful, handled) do
    result =
      with {:ok, event} <- event(instance, envelope),
           {:ok, _session_id, _delivery_id} <- ack_identity(envelope) do
        case handler.(event, envelope) do
          :ok -> :ok
          {:ok, _value} -> :ok
          other -> {:error, {:handler_result, other}}
        end
      end

    case result do
      :ok ->
        consume_ordered_loop(instance, rest, handler, [envelope | successful], handled + 1)

      {:error, reason} ->
        case ack_groups_result(instance, successful) do
          {:ok, acks} ->
            {:error,
             %{
               handled: handled,
               remaining: length(rest) + 1,
               failure: reason,
               acks: acks
             }}

          {:error, ack_reason} ->
            {:error,
             %{
               handled: handled,
               remaining: length(rest) + 1,
               failure: reason,
               ack_error: ack_reason
             }}
        end
    end
  end

  defp ack_groups_result(_instance, []),
    do: {:ok, %{acked: 0, unknown: 0, ack_errors: []}}

  defp ack_groups_result(instance, successful) do
    with {:ok, grouped} <- group_ack_identities(successful) do
      {acked, unknown, errors} = ack_groups(instance, grouped)

      if errors == [] do
        {:ok, %{acked: acked, unknown: unknown, ack_errors: []}}
      else
        {:error, %{acked: acked, unknown: unknown, ack_errors: Enum.reverse(errors)}}
      end
    end
  end

  defp group_ack_identities(envelopes) do
    Enum.reduce_while(envelopes, {:ok, %{}}, fn envelope, {:ok, grouped} ->
      case ack_identity(envelope) do
        {:ok, session_id, delivery_id} ->
          {:cont, {:ok, Map.update(grouped, session_id, [delivery_id], &[delivery_id | &1])}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_success(envelope, index, handled, failures, grouped) do
    case ack_identity(envelope) do
      {:ok, session_id, delivery_id} ->
        next = Map.update(grouped, session_id, [delivery_id], &[delivery_id | &1])
        {handled + 1, failures, next}

      {:error, reason} ->
        {handled, [%{index: index, reason: reason} | failures], grouped}
    end
  end

  defp ack_identity(envelope) when is_map(envelope) do
    with {:ok, session_id} <- Map.fetch(envelope, :session_id),
         {:ok, delivery_id} <- Map.fetch(envelope, :delivery_id) do
      {:ok, session_id, delivery_id}
    else
      :error -> {:error, :invalid_delivery}
    end
  end

  defp ack_identity(_), do: {:error, :invalid_delivery}

  defp ack_groups(instance, grouped) do
    Enum.reduce(grouped, {0, 0, []}, fn {session_id, delivery_ids}, {acked, unknown, errors} ->
      case Wiregrid.ack_many(instance, session_id, Enum.reverse(delivery_ids)) do
        {:ok, result} ->
          {acked + result.acked, unknown + length(result.unknown), errors}

        {:error, reason} ->
          {acked, unknown, [%{session_id: session_id, reason: reason} | errors]}
      end
    end)
  end

  @doc """
  Folds a bounded delivery batch into application state, commits once, then ACKs.

  This is the safe primitive for materialized views and stateful projections.
  The reducer receives `(event, envelope, accumulator)` and must return one of:

    * `{:ok, new_accumulator}`
    * `:drop` to consume without changing the accumulator
    * `{:drop, new_accumulator}`
    * `{:error, reason}` to abort the whole projection batch

  `commit.(accumulator, summary)` runs only after every delivery in the batch
  has decoded/reduced successfully. Delivery reservations are released only
  after commit returns `:ok` or `{:ok, value}`. If reduce/decode/commit fails,
  no delivery in the batch is acknowledged.

  A commit that succeeds followed by an ACK failure is reported with
  `phase: :ack`. Commit callbacks should therefore be idempotent (or use their
  own transaction/idempotency key) because retries may observe at-least-once
  delivery semantics.
  """
  @spec project(term(), [envelope()], term(), (term(), envelope(), term() -> term()), (term(),
                                                                                       map() ->
                                                                                         term())) ::
          {:ok, map()} | {:error, map() | term()}
  def project(instance, envelopes, accumulator, reducer, commit)
      when is_list(envelopes) and is_function(reducer, 3) and is_function(commit, 2) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.bounded_list(envelopes, cfg.max_batch_items),
         true <- envelopes != [] do
      case project_fold(instance, envelopes, reducer, accumulator, [], 0, 0) do
        {:ok, next, successful, handled, dropped} ->
          summary = %{handled: handled, dropped: dropped, deliveries: length(successful)}

          case commit.(next, summary) do
            :ok ->
              project_ack(instance, successful, next, summary, :ok)

            {:ok, value} ->
              project_ack(instance, successful, next, summary, value)

            {:error, reason} ->
              {:error, %{phase: :commit, reason: reason, value: next, summary: summary}}

            other ->
              {:error,
               %{
                 phase: :commit,
                 reason: {:invalid_commit_result, other},
                 value: next,
                 summary: summary
               }}
          end

        {:error, details} ->
          {:error, details}
      end
    else
      false -> {:error, :empty_batch}
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def project(_instance, _envelopes, _accumulator, _reducer, _commit),
    do: {:error, :invalid_projection}

  defp project_fold(_instance, [], _reducer, accumulator, successful, handled, dropped),
    do: {:ok, accumulator, Enum.reverse(successful), handled, dropped}

  defp project_fold(
         instance,
         [envelope | rest],
         reducer,
         accumulator,
         successful,
         handled,
         dropped
       ) do
    case event(instance, envelope) do
      {:ok, value} ->
        case reducer.(value, envelope, accumulator) do
          {:ok, next} ->
            project_fold(
              instance,
              rest,
              reducer,
              next,
              [envelope | successful],
              handled + 1,
              dropped
            )

          :drop ->
            project_fold(
              instance,
              rest,
              reducer,
              accumulator,
              [envelope | successful],
              handled,
              dropped + 1
            )

          {:drop, next} ->
            project_fold(
              instance,
              rest,
              reducer,
              next,
              [envelope | successful],
              handled,
              dropped + 1
            )

          {:error, reason} ->
            {:error,
             %{
               phase: :reduce,
               reason: reason,
               handled: handled,
               dropped: dropped,
               remaining: length(rest) + 1
             }}

          other ->
            {:error,
             %{
               phase: :reduce,
               reason: {:invalid_reducer_result, other},
               handled: handled,
               dropped: dropped,
               remaining: length(rest) + 1
             }}
        end

      {:error, reason} ->
        {:error,
         %{
           phase: :decode,
           reason: reason,
           handled: handled,
           dropped: dropped,
           remaining: length(rest) + 1
         }}
    end
  end

  defp project_ack(instance, successful, accumulator, summary, commit_value) do
    case ack_groups_result(instance, successful) do
      {:ok, acks} ->
        {:ok, %{value: accumulator, commit: commit_value, summary: summary, acks: acks}}

      {:error, reason} ->
        {:error, %{phase: :ack, reason: reason, value: accumulator, summary: summary}}
    end
  end
end
