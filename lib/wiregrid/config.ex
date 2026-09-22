defmodule Wiregrid.Config do
  @moduledoc false

  @small %{
    max_sessions: 10_000,
    max_sessions_per_owner: 32,
    max_subscription_edges: 100_000,
    max_room_edges: 50_000,
    max_room_grace: 50_000,
    max_room_states: 50_000,
    max_presence_watch_edges: 50_000,
    max_activity_entries: 50_000,
    max_receipt_entries: 100_000,
    max_rate_limit_buckets: 100_000,
    max_cache_entries: 25_000,
    max_resume_snapshots: 10_000,
    max_delivery_reservations: 100_000,
    max_cluster_dedupe: 100_000,
    max_remote_presence: 100_000,
    max_remote_room_edges: 100_000,
    max_memory_events: 250_000,
    max_expiry_entries: 250_000,
    max_control_pending: 2_000,
    max_callback_pending: 256,
    max_adapter_pending: 128,
    fanout_buckets: 32
  }

  @balanced %{
    max_sessions: 100_000,
    max_sessions_per_owner: 128,
    max_subscription_edges: 2_000_000,
    max_room_edges: 1_000_000,
    max_room_grace: 1_000_000,
    max_room_states: 1_000_000,
    max_presence_watch_edges: 1_000_000,
    max_activity_entries: 500_000,
    max_receipt_entries: 1_000_000,
    max_rate_limit_buckets: 1_000_000,
    max_cache_entries: 250_000,
    max_resume_snapshots: 100_000,
    max_delivery_reservations: 2_000_000,
    max_cluster_dedupe: 500_000,
    max_remote_presence: 500_000,
    max_remote_room_edges: 2_000_000,
    max_memory_events: 1_000_000,
    max_expiry_entries: 2_000_000,
    max_control_pending: 20_000,
    max_callback_pending: 2_048,
    max_adapter_pending: 1_024,
    fanout_buckets: 64
  }

  @large %{
    max_sessions: 1_000_000,
    max_sessions_per_owner: 1_024,
    max_subscription_edges: 20_000_000,
    max_room_edges: 10_000_000,
    max_room_grace: 10_000_000,
    max_room_states: 10_000_000,
    max_presence_watch_edges: 10_000_000,
    max_activity_entries: 5_000_000,
    max_receipt_entries: 10_000_000,
    max_rate_limit_buckets: 5_000_000,
    max_cache_entries: 2_000_000,
    max_resume_snapshots: 1_000_000,
    max_delivery_reservations: 20_000_000,
    max_cluster_dedupe: 2_000_000,
    max_remote_presence: 2_000_000,
    max_remote_room_edges: 20_000_000,
    max_memory_events: 5_000_000,
    max_expiry_entries: 20_000_000,
    max_control_pending: 100_000,
    max_callback_pending: 8_192,
    max_adapter_pending: 4_096,
    fanout_buckets: 256
  }

  @base %{
    profile: :balanced,
    security_mode: :trusted,
    telemetry_metric_events: false,
    readiness_pressure_threshold: 1.0,
    control_call_timeout_ms: 15_000,
    authorizer_mode: :inline,
    callback_timeout_ms: 100,
    adapter_mode: :inline,
    adapter_timeout_ms: 5_000,
    max_sessions_per_user: 32,
    max_sessions_per_owner: 128,
    max_subscriptions_per_session: 2_048,
    max_presence_watches_per_session: 1_024,
    max_watchers_per_user: 100_000,
    max_rooms_per_session: 256,
    max_room_members: 100_000,
    max_activities_per_session: 512,
    max_receipts_per_session: 2_048,
    max_topic_bytes: 512,
    max_topic_depth: 4,
    max_user_id_bytes: 512,
    max_session_id_bytes: 96,
    max_storage_id_bytes: 256,
    max_metadata_bytes: 16_384,
    max_event_bytes: 1_048_576,
    max_encoded_event_bytes: 1_572_864,
    max_cache_key_bytes: 1_024,
    max_cache_value_bytes: 1_048_576,
    max_rate_limit_key_bytes: 1_024,
    max_websocket_frame_bytes: 1_048_576,
    max_batch_items: 512,
    max_batch_targets: 4_096,
    max_query_results: 10_000,
    soft_queue: 500,
    hard_queue: 2_000,
    fanout_buckets: 64,
    reconnect_grace_ms: 15_000,
    resume_ttl_ms: 120_000,
    activity_ttl_ms: 5_000,
    receipt_ttl_ms: 86_400_000,
    max_ttl_ms: 604_800_000,
    expiry_tick_ms: 100,
    expiry_batch_size: 2_048,
    slow_consumer_action: :disconnect,
    presence_aggregation: :priority,
    presence_priority: [:online, :dnd, :idle, :offline],
    cluster: false,
    cluster_shards: 16,
    cluster_namespace: :instance,
    cluster_dedupe_ttl_ms: 60_000,
    cluster_pending_per_shard: 10_000,
    authorizer: Wiregrid.Authorizer.AllowAll,
    codec: Wiregrid.Codec.Term,
    storage: {Wiregrid.Storage.Memory, []},
    cache: {Wiregrid.Cache.Memory, []},
    webhooks: [enabled: false]
  }

  @profile_limits Map.keys(@balanced)
  @known_keys Map.keys(@base) ++ @profile_limits

  def build(opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- reject_unknown(opts),
         profile <- Keyword.get(opts, :profile, :balanced),
         {:ok, profile_limits} <- profile(profile),
         merged <- @base |> Map.merge(profile_limits) |> Map.merge(Map.new(opts)),
         merged <- normalize_cluster_namespace(merged),
         {:ok, normalized} <- normalize_adapters(merged),
         :ok <- validate(normalized) do
      {:ok, Map.put(normalized, :presence_rank, presence_rank(normalized.presence_priority))}
    end
  end

  def build(_), do: {:error, :invalid_options}

  defp profile(:small), do: {:ok, @small}
  defp profile(:balanced), do: {:ok, @balanced}
  defp profile(:large), do: {:ok, @large}
  defp profile(other), do: {:error, {:invalid_profile, other}}

  defp validate_keyword(opts) do
    with :ok <- Wiregrid.Validation.bounded_list(opts, 128),
         true <- Keyword.keyword?(opts),
         [] <- duplicate_keys(opts) do
      :ok
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp duplicate_keys(opts) do
    opts
    |> Keyword.keys()
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp reject_unknown(opts) do
    unknown = Keyword.keys(opts) -- @known_keys
    if unknown == [], do: :ok, else: {:error, {:unknown_options, Enum.uniq(unknown)}}
  end

  defp normalize_cluster_namespace(%{cluster_namespace: :instance} = cfg), do: cfg
  defp normalize_cluster_namespace(cfg), do: cfg

  defp normalize_adapters(cfg) do
    with {:ok, storage = {storage_module, _}} <- adapter(cfg.storage),
         {:ok, cache = {cache_module, _}} <- adapter(cfg.cache),
         :ok <-
           callbacks(
             storage_module,
             [
               {:bootstrap, 1},
               {:append, 6},
               {:get, 3},
               {:page, 4},
               {:delete, 3},
               {:prune, 4},
               {:health, 1}
             ],
             :storage
           ),
         :ok <-
           callbacks(
             cache_module,
             [{:get, 2}, {:put, 4}, {:delete, 2}, {:incr, 4}, {:health, 1}],
             :cache
           ),
         :ok <- module_contract(cfg.authorizer, :authorize, 4, :authorizer),
         :ok <- module_contract(cfg.codec, :encode, 1, :codec),
         :ok <- module_contract(cfg.codec, :decode, 1, :codec) do
      {:ok, %{cfg | storage: storage, cache: cache}}
    end
  end

  defp adapter(module) when is_atom(module), do: adapter({module, []})

  defp adapter({module, opts}) when is_atom(module) and is_list(opts) do
    with :ok <- Wiregrid.Validation.bounded_list(opts, 64),
         true <- Keyword.keyword?(opts) do
      {:ok, {module, opts}}
    else
      _ -> {:error, :invalid_adapter_options}
    end
  end

  defp adapter(_), do: {:error, :invalid_adapter}

  defp callbacks(module, callbacks, label) do
    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {function, arity} ->
           function_exported?(module, function, arity)
         end) do
      :ok
    else
      {:error, {:invalid_module, label, module}}
    end
  end

  defp module_contract(module, function, arity, label) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      :ok
    else
      {:error, {:invalid_module, label, module}}
    end
  end

  defp validate(cfg) do
    positive = [
      :max_sessions,
      :max_sessions_per_user,
      :max_sessions_per_owner,
      :max_subscription_edges,
      :max_subscriptions_per_session,
      :max_presence_watch_edges,
      :max_presence_watches_per_session,
      :max_watchers_per_user,
      :max_room_edges,
      :max_room_grace,
      :max_room_states,
      :max_rooms_per_session,
      :max_room_members,
      :max_activity_entries,
      :max_activities_per_session,
      :max_receipt_entries,
      :max_receipts_per_session,
      :max_rate_limit_buckets,
      :max_cache_entries,
      :max_resume_snapshots,
      :max_delivery_reservations,
      :max_cluster_dedupe,
      :max_remote_presence,
      :max_remote_room_edges,
      :max_memory_events,
      :max_expiry_entries,
      :max_control_pending,
      :max_callback_pending,
      :max_adapter_pending,
      :max_topic_bytes,
      :max_topic_depth,
      :max_user_id_bytes,
      :max_session_id_bytes,
      :max_storage_id_bytes,
      :max_metadata_bytes,
      :max_event_bytes,
      :max_encoded_event_bytes,
      :max_cache_key_bytes,
      :max_cache_value_bytes,
      :max_rate_limit_key_bytes,
      :max_websocket_frame_bytes,
      :max_batch_items,
      :max_batch_targets,
      :max_query_results,
      :soft_queue,
      :hard_queue,
      :fanout_buckets,
      :reconnect_grace_ms,
      :resume_ttl_ms,
      :activity_ttl_ms,
      :receipt_ttl_ms,
      :max_ttl_ms,
      :expiry_tick_ms,
      :expiry_batch_size,
      :cluster_shards,
      :cluster_dedupe_ttl_ms,
      :cluster_pending_per_shard,
      :control_call_timeout_ms,
      :callback_timeout_ms,
      :adapter_timeout_ms
    ]

    cond do
      Enum.any?(positive, fn key -> not positive_integer?(Map.fetch!(cfg, key)) end) ->
        {:error, :invalid_limits}

      cfg.fanout_buckets > 1_024 ->
        {:error, :fanout_buckets_too_large}

      cfg.soft_queue >= cfg.hard_queue ->
        {:error, :soft_queue_must_be_below_hard_queue}

      cfg.max_encoded_event_bytes < cfg.max_event_bytes ->
        {:error, :encoded_event_limit_too_small}

      cfg.activity_ttl_ms > cfg.max_ttl_ms or cfg.receipt_ttl_ms > cfg.max_ttl_ms ->
        {:error, :default_ttl_exceeds_maximum}

      cfg.slow_consumer_action not in [:disconnect, :exit_owner] ->
        {:error, :invalid_slow_consumer_action}

      not is_boolean(cfg.telemetry_metric_events) ->
        {:error, :invalid_telemetry_metric_events}

      not valid_ratio?(cfg.readiness_pressure_threshold) ->
        {:error, :invalid_readiness_pressure_threshold}

      cfg.security_mode not in [:trusted, :strict] ->
        {:error, :invalid_security_mode}

      cfg.authorizer_mode not in [:inline, :isolated] ->
        {:error, :invalid_authorizer_mode}

      cfg.adapter_mode not in [:inline, :isolated] ->
        {:error, :invalid_adapter_mode}

      cfg.security_mode == :strict and cfg.authorizer == Wiregrid.Authorizer.AllowAll ->
        {:error, :strict_security_requires_authorizer}

      cfg.presence_aggregation not in [:priority, :latest] ->
        {:error, :invalid_presence_aggregation}

      not valid_priority?(cfg.presence_priority) ->
        {:error, :invalid_presence_priority}

      not is_boolean(cfg.cluster) ->
        {:error, :invalid_cluster_flag}

      cfg.cluster_shards > 256 ->
        {:error, :too_many_cluster_shards}

      not valid_namespace?(cfg.cluster_namespace) ->
        {:error, :invalid_cluster_namespace}

      webhook_config(cfg.webhooks) != :ok ->
        webhook_config(cfg.webhooks)

      true ->
        :ok
    end
  end

  @webhook_keys [
    :enabled,
    :allowlist,
    :max_pending,
    :max_concurrency,
    :max_body_bytes,
    :max_response_bytes,
    :max_header_bytes,
    :max_retries,
    :base_backoff_ms,
    :max_backoff_ms,
    :connect_timeout_ms,
    :request_timeout_ms
  ]

  defp webhook_config(opts) when is_list(opts) do
    with :ok <- Wiregrid.Validation.keyword_opts(opts, @webhook_keys) do
      enabled = Keyword.get(opts, :enabled, false)
      allowlist = Keyword.get(opts, :allowlist, [])

      numeric = [
        :max_pending,
        :max_concurrency,
        :max_body_bytes,
        :max_response_bytes,
        :max_header_bytes,
        :base_backoff_ms,
        :max_backoff_ms,
        :connect_timeout_ms,
        :request_timeout_ms
      ]

      base = Keyword.get(opts, :base_backoff_ms)
      max_backoff = Keyword.get(opts, :max_backoff_ms)
      retries = Keyword.get(opts, :max_retries)

      cond do
        not is_boolean(enabled) ->
          {:error, :invalid_webhook_config}

        Wiregrid.Validation.bounded_list(allowlist, 128) != :ok ->
          {:error, :invalid_webhook_allowlist}

        not Enum.all?(allowlist, &(is_binary(&1) and byte_size(&1) in 1..253)) ->
          {:error, :invalid_webhook_allowlist}

        enabled and allowlist == [] ->
          {:error, :webhook_allowlist_required}

        Enum.any?(numeric, fn key ->
          value = Keyword.get(opts, key)
          not is_nil(value) and not positive_integer?(value)
        end) ->
          {:error, :invalid_webhook_limits}

        exceeds_webhook_hard_limit?(opts) ->
          {:error, :invalid_webhook_limits}

        not is_nil(retries) and (not is_integer(retries) or retries < 0 or retries > 20) ->
          {:error, :invalid_webhook_limits}

        is_integer(base) and is_integer(max_backoff) and base > max_backoff ->
          {:error, :invalid_webhook_limits}

        true ->
          :ok
      end
    else
      _ -> {:error, :invalid_webhook_config}
    end
  end

  defp webhook_config(_), do: {:error, :invalid_webhook_config}

  defp exceeds_webhook_hard_limit?(opts) do
    hard_limits = [
      max_pending: 1_000_000,
      max_concurrency: 1_024,
      max_body_bytes: 16_777_216,
      max_response_bytes: 16_777_216,
      max_header_bytes: 131_072,
      base_backoff_ms: 86_400_000,
      max_backoff_ms: 86_400_000,
      connect_timeout_ms: 300_000,
      request_timeout_ms: 300_000
    ]

    Enum.any?(hard_limits, fn {key, hard_max} ->
      case Keyword.get(opts, key) do
        nil -> false
        value -> value > hard_max
      end
    end)
  end

  defp presence_rank(priority) do
    priority
    |> Enum.with_index()
    |> Map.new()
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp valid_ratio?(value), do: is_number(value) and value > 0 and value <= 1

  defp valid_priority?(list) when is_list(list) do
    Wiregrid.Validation.bounded_list(list, 32) == :ok and list != [] and
      MapSet.size(MapSet.new(list)) == length(list) and Enum.all?(list, &valid_presence_state?/1)
  end

  defp valid_priority?(_), do: false

  defp valid_presence_state?(state) when state in [:online, :dnd, :idle, :offline], do: true

  defp valid_presence_state?({:custom, value}) when is_binary(value),
    do: byte_size(value) in 1..64

  defp valid_presence_state?(_), do: false

  defp valid_namespace?(value) when is_atom(value), do: true
  defp valid_namespace?(value) when is_integer(value) and value >= 0, do: true
  defp valid_namespace?(value) when is_binary(value), do: byte_size(value) in 1..128

  defp valid_namespace?(value) when is_tuple(value) and tuple_size(value) in 1..4 do
    value
    |> Tuple.to_list()
    |> Enum.all?(&valid_namespace_part?/1)
  end

  defp valid_namespace?(_), do: false

  defp valid_namespace_part?(value) when is_atom(value), do: true
  defp valid_namespace_part?(value) when is_integer(value) and value >= 0, do: true
  defp valid_namespace_part?(value) when is_binary(value), do: byte_size(value) in 1..128
  defp valid_namespace_part?(_), do: false
end
