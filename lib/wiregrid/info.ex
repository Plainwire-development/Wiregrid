defmodule Wiregrid.Info do
  @moduledoc """
  Stable, sanitized runtime discovery for Wiregrid applications and bindings.

  This module intentionally exposes capabilities and operational metadata, not
  secrets, adapter credentials, ETS identifiers or application payloads.
  """

  @protocol_version 1
  @features [
    :sessions,
    :session_resume,
    :session_bound_actors,
    :supervised_consumers,
    :subscriptions,
    :prepared_events,
    :heterogeneous_dispatch,
    :dispatch_plans,
    :topology_sync,
    :session_topology_reconciliation,
    :delivery_backpressure,
    :manual_ack,
    :presence,
    :presence_watch,
    :rooms,
    :room_broadcast,
    :room_metadata,
    :room_ttl,
    :signaling,
    :activity,
    :receipts,
    :request_reply,
    :transport_command_router,
    :rate_limits,
    :fixed_window_rate_limits,
    :token_bucket_rate_limits,
    :storage,
    :history_api,
    :bounded_replay,
    :cache,
    :health,
    :drain,
    :query,
    :foreign_gateway,
    :c_client_abi,
    :foreign_history,
    :json_events,
    :json_websocket,
    :isolated_adapters
  ]

  @spec version() :: binary()
  def version do
    case Application.spec(:wiregrid, :vsn) do
      nil -> "1.0.0"
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      vsn -> to_string(vsn)
    end
  end

  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @spec capabilities(term()) :: {:ok, map()} | {:error, :instance_unavailable}
  def capabilities(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg} ->
        optional = %{
          cluster: cfg.cluster,
          webhooks: Keyword.get(cfg.webhooks, :enabled, false),
          external_storage: not memory_storage?(cfg.storage),
          external_cache: not memory_cache?(cfg.cache),
          telemetry_metric_events: cfg.telemetry_metric_events,
          isolated_adapters: cfg.adapter_mode == :isolated
        }

        {:ok,
         %{
           wiregrid_version: version(),
           protocol_version: @protocol_version,
           features: @features,
           optional: optional,
           codec: module_name(cfg.codec),
           storage: module_name(elem(cfg.storage, 0)),
           cache: module_name(elem(cfg.cache, 0)),
           profile: cfg.profile,
           security: %{
             mode: cfg.security_mode,
             authorizer: module_name(cfg.authorizer),
             permissive_authorizer: cfg.authorizer == Wiregrid.Authorizer.AllowAll
           },
           bindings: [:elixir, :erlang, :gleam, :lfe, :c],
           binding_features: %{
             elixir: [:actor, :supervised_consumer, :prepared_dispatch],
             erlang: [:plain_term_abi],
             gleam: [:typed_topics, :typed_actor, :typed_protocol],
             lfe: [
               :actor,
               :compiled_hotpaths,
               :compiled_authorizers,
               :decode_late_kernels,
               :bounded_workers,
               :microbatch_workers,
               :folds,
               :commit_before_ack_projections,
               :compiled_command_handlers,
               :compiled_dispatch_policies,
               :keyed_parallel_lanes,
               :ephemeral_coalescing,
               :pipelines
             ],
             c: [:socket_client, :opaque_payloads, :bounded_event_queue]
           }
         }}

      _ ->
        {:error, :instance_unavailable}
    end
  end

  @spec deployment_report(term()) :: {:ok, map()} | {:error, :instance_unavailable}
  def deployment_report(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg} ->
        findings =
          []
          |> finding(
            cfg.security_mode != :strict,
            :warning,
            :trusted_security_mode,
            "strict security mode is not enabled"
          )
          |> finding(
            cfg.authorizer == Wiregrid.Authorizer.AllowAll,
            :warning,
            :permissive_authorizer,
            "the default allow-all authorizer is configured"
          )
          |> finding(
            cfg.authorizer_mode == :inline and cfg.security_mode == :strict,
            :notice,
            :inline_authorizer,
            "strict mode uses inline authorizer execution; choose :isolated if policy code may block"
          )
          |> finding(
            memory_storage?(cfg.storage),
            :warning,
            :volatile_storage,
            "memory storage is process-local and not durable across instance-table loss"
          )
          |> finding(
            cfg.profile == :large and not cfg.cluster,
            :notice,
            :large_single_node_profile,
            "the large profile is enabled without Wiregrid clustering"
          )
          |> finding(
            cfg.readiness_pressure_threshold >= 1.0,
            :notice,
            :full_capacity_readiness,
            "readiness remains true until a bounded resource reaches full admission capacity"
          )

        readiness = Wiregrid.Health.readiness_report(instance)

        {:ok,
         %{
           status:
             if(Enum.any?(findings, &(&1.severity == :warning)), do: :review, else: :hardened),
           readiness: readiness,
           findings: Enum.reverse(findings),
           profile: cfg.profile,
           security_mode: cfg.security_mode,
           cluster: cfg.cluster,
           durable_storage: not memory_storage?(cfg.storage),
           external_cache: not memory_cache?(cfg.cache),
           webhooks: Keyword.get(cfg.webhooks, :enabled, false)
         }}

      _ ->
        {:error, :instance_unavailable}
    end
  end

  @spec describe(term()) :: {:ok, map()} | {:error, :instance_unavailable}
  def describe(instance) do
    with {:ok, capabilities} <- capabilities(instance),
         {:ok, limits} <- Wiregrid.Query.limits(instance),
         {:ok, pressure} <- Wiregrid.Health.pressure(instance) do
      {:ok,
       %{
         capabilities: capabilities,
         limits: limits,
         health: Wiregrid.Health.health(instance),
         pressure: pressure,
         stats: Wiregrid.Health.stats(instance)
       }}
    end
  end

  defp finding(findings, true, severity, code, message),
    do: [%{severity: severity, code: code, message: message} | findings]

  defp finding(findings, false, _severity, _code, _message), do: findings

  defp memory_storage?({Wiregrid.Storage.Memory, _}), do: true
  defp memory_storage?(_), do: false
  defp memory_cache?({Wiregrid.Cache.Memory, _}), do: true
  defp memory_cache?(_), do: false
  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
end
