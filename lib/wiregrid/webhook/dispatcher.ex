defmodule Wiregrid.Webhook.Dispatcher do
  @moduledoc false
  use GenServer

  @defaults [
    enabled: false,
    allowlist: [],
    max_pending: 1_000,
    max_concurrency: 16,
    max_body_bytes: 1_048_576,
    max_response_bytes: 65_536,
    max_header_bytes: 32_768,
    max_retries: 5,
    base_backoff_ms: 500,
    max_backoff_ms: 30_000,
    connect_timeout_ms: 5_000,
    request_timeout_ms: 10_000
  ]

  @job_options [:secret, :headers]

  def start_link({instance, config}) do
    GenServer.start_link(__MODULE__, {instance, config}, name: via(instance))
  end

  def via(instance),
    do: {:via, Registry, {Wiregrid.ProcessRegistry, {:webhook_dispatcher, instance}}}

  def enqueue(instance, url, body, opts) do
    GenServer.call(via(instance), {:enqueue, url, body, opts}, 15_000)
  catch
    :exit, _ -> {:error, :instance_unavailable}
  end

  @impl true
  def init({instance, config}) do
    webhook_cfg = Keyword.merge(@defaults, config.webhooks)
    rebuild_due(instance)
    Process.send_after(self(), :tick, 100)
    {:ok, %{instance: instance, config: webhook_cfg, active: %{}}}
  end

  @impl true
  def handle_call({:enqueue, _url, _body, _opts}, _from, %{config: %{enabled: false}} = state) do
    {:reply, {:error, :webhooks_disabled}, state}
  end

  def handle_call({:enqueue, url, body, opts}, _from, state) do
    reply = do_enqueue(state, url, body, opts)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state2 = launch_due(state)
    Process.send_after(self(), :tick, 100)
    {:noreply, state2}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.active, ref) do
      {nil, _} ->
        {:noreply, state}

      {job_id, active} ->
        Process.demonitor(ref, [:flush])
        finish_job(state.instance, state.config, job_id, result)
        {:noreply, %{state | active: active}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.active, ref) do
      {nil, _} ->
        {:noreply, state}

      {job_id, active} ->
        finish_job(state.instance, state.config, job_id, {:error, {:worker_down, reason}, true})
        {:noreply, %{state | active: active}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp do_enqueue(state, url, body, opts) do
    cfg = state.config

    with :ok <- accepting(state.instance),
         :ok <- body(body, cfg.max_body_bytes),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @job_options),
         {:ok, secret} <- secret(Keyword.get(opts, :secret)),
         {:ok, headers} <- headers(Keyword.get(opts, :headers, %{}), cfg.max_header_bytes),
         :ok <- Wiregrid.Webhook.Client.validate_destination(url, cfg.allowlist),
         %{tables: t} <- Wiregrid.Tables.get(state.instance),
         true <- (:ets.info(t.webhook_jobs, :size) || 0) < cfg.max_pending do
      id = Wiregrid.ID.generate()
      now = System.system_time(:millisecond)

      job = %{
        id: id,
        url: url,
        body: body,
        secret: secret,
        headers: headers,
        attempt: 0,
        next_at_ms: now
      }

      true = :ets.insert(t.webhook_jobs, {id, job})
      true = :ets.insert(t.webhook_due, {{now, id}, true})
      _ = Wiregrid.Metrics.increment(state.instance, :webhook_enqueued)
      {:ok, id}
    else
      false -> {:error, :webhook_queue_full}
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  defp accepting(instance), do: Wiregrid.Runtime.accepting(instance)

  defp body(value, max_bytes) when is_binary(value) and byte_size(value) <= max_bytes, do: :ok
  defp body(value, _max_bytes) when not is_binary(value), do: {:error, :invalid_webhook_body}
  defp body(_value, _max_bytes), do: {:error, :webhook_body_too_large}

  defp launch_due(state) when map_size(state.active) >= state.config.max_concurrency, do: state

  defp launch_due(state) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} ->
        now = System.system_time(:millisecond)

        case :ets.first(t.webhook_due) do
          :"$end_of_table" ->
            state

          {due, id} = due_key when due <= now ->
            :ets.delete(t.webhook_due, due_key)

            case :ets.lookup(t.webhook_jobs, id) do
              [{^id, job}] ->
                task =
                  Task.Supervisor.async_nolink(Wiregrid.TaskSupervisor, fn ->
                    Wiregrid.Webhook.Client.post(job, state.config)
                  end)

                next = %{state | active: Map.put(state.active, task.ref, id)}
                launch_due(next)

              [] ->
                launch_due(state)
            end

          _future ->
            state
        end

      _ ->
        state
    end
  end

  defp finish_job(instance, cfg, job_id, result) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        case :ets.lookup(t.webhook_jobs, job_id) do
          [{^job_id, job}] ->
            case classify(result) do
              :success ->
                :ets.delete(t.webhook_jobs, job_id)
                _ = Wiregrid.Metrics.increment(instance, :webhook_delivered)

              {:retry, reason} when job.attempt < cfg.max_retries ->
                attempt = job.attempt + 1
                delay = backoff(cfg, attempt)
                next_at = System.system_time(:millisecond) + delay
                updated = %{job | attempt: attempt, next_at_ms: next_at}
                true = :ets.insert(t.webhook_jobs, {job_id, updated})
                true = :ets.insert(t.webhook_due, {{next_at, job_id}, true})
                _ = reason
                _ = Wiregrid.Metrics.increment(instance, :webhook_retries)

              _permanent ->
                :ets.delete(t.webhook_jobs, job_id)
                _ = Wiregrid.Metrics.increment(instance, :webhook_failures)
            end

          [] ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp classify({:ok, status}) when status in 200..299, do: :success

  defp classify({:ok, status}) when status in [408, 425, 429] or status >= 500,
    do: {:retry, {:http_status, status}}

  defp classify({:ok, status}), do: {:permanent, {:http_status, status}}
  defp classify({:error, reason, true}), do: {:retry, reason}
  defp classify({:error, reason, false}), do: {:permanent, reason}
  defp classify(other), do: {:retry, {:unexpected_result, other}}

  defp backoff(cfg, attempt) do
    base = min(cfg.base_backoff_ms * trunc(:math.pow(2, attempt - 1)), cfg.max_backoff_ms)
    jitter = if base > 1, do: :rand.uniform(max(div(base, 4), 1)) - 1, else: 0
    min(base + jitter, cfg.max_backoff_ms)
  end

  defp rebuild_due(instance) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        :ets.delete_all_objects(t.webhook_due)
        now = System.system_time(:millisecond)

        :ets.foldl(
          fn {id, job}, :ok ->
            due = max(Map.get(job, :next_at_ms, now), now)
            true = :ets.insert(t.webhook_due, {{due, id}, true})
            :ok
          end,
          :ok,
          t.webhook_jobs
        )

      _ ->
        :ok
    end
  end

  defp secret(value) when is_binary(value) and byte_size(value) >= 32 and byte_size(value) <= 256,
    do: {:ok, value}

  defp secret(_), do: {:error, :invalid_webhook_secret}

  defp headers(map, max_bytes) when is_map(map) and map_size(map) <= 32 do
    validate_headers(Map.to_list(map), max_bytes)
  end

  defp headers(list, max_bytes) when is_list(list) do
    case Wiregrid.Validation.bounded_list(list, 32) do
      :ok -> validate_headers(list, max_bytes)
      _ -> {:error, :invalid_webhook_headers}
    end
  end

  defp headers(_, _), do: {:error, :invalid_webhook_headers}

  defp validate_headers(list, max_bytes) do
    cond do
      header_bytes(list) > max_bytes ->
        {:error, :invalid_webhook_headers}

      not Enum.all?(list, &safe_header?/1) ->
        {:error, :invalid_webhook_headers}

      true ->
        names = Enum.map(list, fn {name, _value} -> ascii_downcase(name) end)

        if MapSet.size(MapSet.new(names)) == length(names) do
          {:ok, list}
        else
          {:error, :invalid_webhook_headers}
        end
    end
  end

  defp safe_header?({name, value}) when is_binary(name) and is_binary(value) do
    byte_size(name) in 1..128 and byte_size(value) <= 4_096 and
      valid_header_name?(name) and not contains_control?(value) and
      ascii_downcase(name) not in protected_headers()
  end

  defp safe_header?(_), do: false

  defp valid_header_name?(name) do
    Enum.all?(:binary.bin_to_list(name), &http_token_byte?/1)
  end

  defp http_token_byte?(byte) when byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z, do: true
  defp http_token_byte?(byte) when byte in ~c"!#$%&'*+-.^_`|~", do: true
  defp http_token_byte?(_byte), do: false

  defp header_bytes(headers) do
    Enum.reduce(headers, 0, fn
      {k, v}, acc when is_binary(k) and is_binary(v) -> acc + byte_size(k) + byte_size(v) + 4
      _other, acc -> acc + 1_000_000_000
    end)
  end

  defp contains_control?(binary),
    do: Enum.any?(:binary.bin_to_list(binary), fn byte -> byte < 32 or byte == 127 end)

  defp ascii_downcase(binary) when is_binary(binary) do
    for <<byte <- binary>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end

  defp protected_headers,
    do: [
      "host",
      "content-type",
      "content-length",
      "connection",
      "transfer-encoding",
      "te",
      "trailer",
      "upgrade",
      "authorization",
      "proxy-authorization",
      "proxy-connection",
      "x-wiregrid-id",
      "x-wiregrid-timestamp",
      "x-wiregrid-nonce",
      "x-wiregrid-signature"
    ]
end
