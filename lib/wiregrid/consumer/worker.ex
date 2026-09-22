defmodule Wiregrid.Consumer.Worker do
  @moduledoc """
  Supervised, bounded consumer for Wiregrid delivery mailboxes.

  The worker is deliberately application-side. It does not bypass the Wiregrid
  runtime: deliveries still use normal reservation accounting and are
  acknowledged only after `Wiregrid.Consumer.consume_many/3` reports successful
  handling.

  A worker is most useful when its PID is the owner PID supplied to
  `Wiregrid.connect/4`. The mailbox is configured with `:off_heap` message data
  so large encoded delivery bursts put less pressure on the process heap.

  Options:

    * `:instance` - required Wiregrid instance.
    * `:handler` - required `(event, envelope -> result)` function.
    * `:batch_size` - bounded burst size, defaults to `64` and may not exceed
      the instance's `max_batch_items` or 4096.
    * `:mode` - `:fifo` (default) or `:durable_first`. Priority ordering applies
      only to the already-removed bounded burst; it never scans an unbounded
      mailbox.
    * `:collect_wait_ms` - optional bounded `0..50` ms delay used only after the
      first delivery in a burst. This can coalesce micro-batches under load
      without creating an application queue; defaults to `0`.
    * `:failure_policy` - `:crash` (default) or `:continue`. Handler exceptions
      always crash. With `:crash`, non-success handler results also terminate the
      worker so a supervisor/application can recover visibly.
    * `:name` - optional ordinary GenServer name.
    * `:id` - optional supervisor child ID; useful when supervising several
      workers for one instance.

  `:continue` deliberately leaves failed delivery reservations outstanding. It
  should only be used when the application has an explicit replay/recovery
  strategy; otherwise the outstanding reservations will eventually provide
  backpressure, which is safer than acknowledging work that was not processed.
  """

  use GenServer

  @type mode :: :fifo | :durable_first
  @type failure_policy :: :crash | :continue

  @max_batch_size 4_096
  @default_batch_size 64

  @doc "Starts a supervised consumer worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  def child_spec(opts) when is_list(opts) do
    instance = Keyword.get(opts, :instance, :undefined)

    %{
      id: Keyword.get(opts, :id, {__MODULE__, instance}),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc "Returns bounded operational counters for the worker."
  @spec stats(GenServer.server(), timeout()) :: map() | {:error, term()}
  def stats(server, timeout \\ 5_000) do
    GenServer.call(server, :stats, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc "Requests an orderly worker stop."
  @spec stop(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def stop(server, timeout \\ 5_000) do
    GenServer.stop(server, :normal, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @impl true
  def init(opts) do
    Process.flag(:message_queue_data, :off_heap)

    with :ok <- validate_option_keys(opts),
         {:ok, instance} <- fetch_required(opts, :instance),
         {:ok, handler} <- fetch_handler(opts),
         {:ok, cfg} <- instance_config(instance),
         {:ok, batch_size} <- batch_size(opts, cfg),
         {:ok, collect_wait_ms} <- collect_wait_ms(opts),
         {:ok, mode} <- mode(opts),
         {:ok, failure_policy} <- failure_policy(opts) do
      {:ok,
       %{
         instance: instance,
         handler: handler,
         batch_size: batch_size,
         collect_wait_ms: collect_wait_ms,
         mode: mode,
         failure_policy: failure_policy,
         batches: 0,
         handled: 0,
         failed: 0,
         acked: 0,
         unknown_acks: 0,
         ack_errors: 0,
         last_error: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, public_stats(state), state}
  end

  @impl true
  def handle_info({:"$wiregrid", envelope}, state) when is_map(envelope) do
    batch = collect_deliveries([envelope], state.batch_size - 1, state.collect_wait_ms)
    ordered = order_batch(batch, state.mode)

    case Wiregrid.Consumer.consume_many(state.instance, ordered, state.handler) do
      {:ok, result} ->
        next = merge_result(state, result)

        if state.failure_policy == :crash and result.failed > 0 do
          {:stop, {:wiregrid_consumer_failed, result}, next}
        else
          {:noreply, next}
        end

      {:error, reason} ->
        next = merge_error(state, reason, length(ordered))

        if state.failure_policy == :crash do
          {:stop, {:wiregrid_consumer_failed, reason}, next}
        else
          {:noreply, next}
        end
    end
  end

  def handle_info({:"$wiregrid", _invalid}, state) do
    next = merge_error(state, :invalid_delivery, 1)

    if state.failure_policy == :crash do
      {:stop, {:wiregrid_consumer_failed, :invalid_delivery}, next}
    else
      {:noreply, next}
    end
  end

  # A dedicated consumer should not accumulate unrelated application messages.
  # They are discarded deliberately; control belongs on GenServer.call/cast or
  # another process, not in the delivery mailbox.
  def handle_info(_message, state), do: {:noreply, state}

  defp collect_deliveries(acc, 0, _wait_ms), do: Enum.reverse(acc)

  defp collect_deliveries(acc, remaining, wait_ms) when remaining > 0 do
    receive do
      {:"$wiregrid", envelope} -> collect_deliveries([envelope | acc], remaining - 1, 0)
    after
      wait_ms -> Enum.reverse(acc)
    end
  end

  defp order_batch(batch, :fifo), do: batch

  defp order_batch(batch, :durable_first) do
    {durable, other} = Enum.split_with(batch, &(Map.get(&1, :class, :durable) == :durable))
    durable ++ other
  end

  defp merge_result(state, result) do
    %{
      state
      | batches: state.batches + 1,
        handled: state.handled + Map.get(result, :handled, 0),
        failed: state.failed + Map.get(result, :failed, 0),
        acked: state.acked + Map.get(result, :acked, 0),
        unknown_acks: state.unknown_acks + Map.get(result, :unknown_acks, 0),
        ack_errors: state.ack_errors + length(Map.get(result, :ack_errors, [])),
        last_error: if(Map.get(result, :failed, 0) > 0, do: result, else: state.last_error)
    }
  end

  defp merge_error(state, reason, batch_count) do
    %{
      state
      | batches: state.batches + 1,
        failed: state.failed + max(batch_count, 1),
        last_error: reason
    }
  end

  defp public_stats(state) do
    Map.take(state, [
      :batch_size,
      :collect_wait_ms,
      :mode,
      :failure_policy,
      :batches,
      :handled,
      :failed,
      :acked,
      :unknown_acks,
      :ack_errors,
      :last_error
    ])
  end

  defp validate_option_keys(opts) do
    allowed = [
      :instance,
      :handler,
      :batch_size,
      :collect_wait_ms,
      :mode,
      :failure_policy,
      :name,
      :id
    ]

    case Wiregrid.Validation.keyword_opts(opts, allowed) do
      :ok -> :ok
      _ -> {:error, :invalid_options}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_handler(opts) do
    case Keyword.fetch(opts, :handler) do
      {:ok, handler} when is_function(handler, 2) -> {:ok, handler}
      {:ok, _} -> {:error, :invalid_handler}
      :error -> {:error, {:missing_option, :handler}}
    end
  end

  defp instance_config(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg} -> {:ok, cfg}
      _ -> {:error, :instance_unavailable}
    end
  end

  defp batch_size(opts, cfg) do
    value = Keyword.get(opts, :batch_size, @default_batch_size)
    upper = min(cfg.max_batch_items, @max_batch_size)

    if is_integer(value) and value > 0 and value <= upper do
      {:ok, value}
    else
      {:error, :invalid_batch_size}
    end
  end

  defp collect_wait_ms(opts) do
    case Keyword.get(opts, :collect_wait_ms, 0) do
      value when is_integer(value) and value >= 0 and value <= 50 -> {:ok, value}
      _ -> {:error, :invalid_collect_wait}
    end
  end

  defp mode(opts) do
    case Keyword.get(opts, :mode, :fifo) do
      value when value in [:fifo, :durable_first] -> {:ok, value}
      _ -> {:error, :invalid_mode}
    end
  end

  defp failure_policy(opts) do
    case Keyword.get(opts, :failure_policy, :crash) do
      value when value in [:crash, :continue] -> {:ok, value}
      _ -> {:error, :invalid_failure_policy}
    end
  end
end
