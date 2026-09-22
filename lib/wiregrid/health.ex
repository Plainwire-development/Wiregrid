defmodule Wiregrid.Health do
  @moduledoc false

  def health(instance) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        storage = Wiregrid.Storage.health(instance)
        cache = Wiregrid.Cache.health(instance)
        runtime = process_status(Wiregrid.Runtime.via(instance))
        expiry = process_status(Wiregrid.Expiry.via(instance))
        webhook = optional_webhook_status(instance, t)
        cluster = optional_cluster_status(instance)

        status =
          if Enum.all?([storage, cache, runtime, expiry, webhook, cluster], &healthy_status?/1),
            do: :ok,
            else: :degraded

        %{
          status: status,
          runtime: runtime,
          expiry: expiry,
          storage: storage,
          cache: cache,
          webhook: webhook,
          cluster: cluster,
          draining: Wiregrid.Runtime.draining?(instance),
          sessions: :ets.info(t.sessions, :size) || 0
        }

      _ ->
        %{status: :down}
    end
  end

  def readiness(instance) do
    case readiness_report(instance) do
      %{status: :ready} -> :ready
      _ -> :not_ready
    end
  end

  def readiness_report(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg} ->
        health = health(instance)

        cond do
          health.status != :ok ->
            %{status: :not_ready, reason: :unhealthy, health: health.status}

          health.draining ->
            %{status: :not_ready, reason: :draining}

          true ->
            case pressure(instance) do
              {:ok, resources} ->
                saturated = saturated_resources(resources, cfg.readiness_pressure_threshold)

                if saturated == [] do
                  %{status: :ready}
                else
                  %{status: :not_ready, reason: :resource_pressure, resources: saturated}
                end

              {:error, reason} ->
                %{status: :not_ready, reason: reason}
            end
        end

      _ ->
        %{status: :not_ready, reason: :instance_unavailable}
    end
  end

  def ready?(instance), do: readiness(instance) == :ready

  def liveness(instance) do
    case Wiregrid.Tables.get(instance) do
      %{tables: _} ->
        if process_status(Wiregrid.Runtime.via(instance)) == :ok, do: :alive, else: :down

      _ ->
        :down
    end
  end

  @doc """
  Returns bounded resource usage against the instance admission limits.

  This is deliberately metadata-only: no user IDs, topics, payloads, secrets or
  ETS identifiers are exposed. `ratio` is in the range `0.0..1.0` for resources
  still within their configured admission budget; a value above `1.0` indicates
  state that should be investigated (for example after manual table mutation).
  """
  def pressure(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        webhook_limit = Keyword.get(cfg.webhooks, :max_pending, 1_000)

        {:ok,
         %{
           sessions: resource(table_size(t.sessions), cfg.max_sessions),
           subscriptions: resource(table_size(t.subscription_edges), cfg.max_subscription_edges),
           presence_watches:
             resource(table_size(t.presence_watch_edges), cfg.max_presence_watch_edges),
           room_memberships: resource(table_size(t.room_edges), cfg.max_room_edges),
           room_grace: resource(table_size(t.room_grace), cfg.max_room_grace),
           room_states: resource(table_size(t.room_state), cfg.max_room_states),
           activities: resource(table_size(t.activity_keys), cfg.max_activity_entries),
           receipts: resource(table_size(t.receipt_keys), cfg.max_receipt_entries),
           rate_limit_buckets:
             resource(table_size(t.rate_limit_keys), cfg.max_rate_limit_buckets),
           cache_entries: resource(table_size(t.memory_cache_keys), cfg.max_cache_entries),
           resume_snapshots: resource(table_size(t.resume_snapshots), cfg.max_resume_snapshots),
           delivery_reservations:
             resource(
               Wiregrid.Capacity.get(t.capacity, :delivery_reservations),
               cfg.max_delivery_reservations
             ),
           cluster_dedupe: resource(table_size(t.seen_cluster), cfg.max_cluster_dedupe),
           remote_presence: resource(table_size(t.remote_presence), cfg.max_remote_presence),
           remote_room_memberships:
             resource(table_size(t.remote_room_edges), cfg.max_remote_room_edges),
           memory_events: resource(table_size(t.memory_event_ids), cfg.max_memory_events),
           expiry_entries: resource(table_size(t.expiry_index), cfg.max_expiry_entries),
           control_pending:
             resource(Wiregrid.Runtime.control_pending(instance), cfg.max_control_pending),
           callback_pending:
             resource(
               Wiregrid.Capacity.get(t.capacity, :callback_pending),
               cfg.max_callback_pending
             ),
           adapter_pending:
             resource(
               Wiregrid.Capacity.get(t.capacity, :adapter_pending),
               cfg.max_adapter_pending
             ),
           webhook_jobs: resource(table_size(t.webhook_jobs), webhook_limit)
         }}

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def stats(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        Map.merge(Wiregrid.Metrics.snapshot(instance), %{
          sessions: :ets.info(t.sessions, :size) || 0,
          users: :ets.info(t.user_index, :size) || 0,
          owner_processes: :ets.info(t.owner_session_counts, :size) || 0,
          subscriptions: :ets.info(t.subscription_edges, :size) || 0,
          topics: :ets.info(t.topic_counts, :size) || 0,
          rooms: :ets.info(t.room_counts, :size) || 0,
          room_memberships: :ets.info(t.room_edges, :size) || 0,
          room_states: :ets.info(t.room_state, :size) || 0,
          presence_watches: :ets.info(t.presence_watch_edges, :size) || 0,
          activities: :ets.info(t.activity_keys, :size) || 0,
          receipts: :ets.info(t.receipt_keys, :size) || 0,
          rate_limit_buckets: :ets.info(t.rate_limit_keys, :size) || 0,
          cache_entries: :ets.info(t.memory_cache_keys, :size) || 0,
          expiry_entries: :ets.info(t.expiry_index, :size) || 0,
          delivery_reservations: Wiregrid.Capacity.get(t.capacity, :delivery_reservations),
          control_pending: Wiregrid.Runtime.control_pending(instance),
          callback_pending: Wiregrid.Capacity.get(t.capacity, :callback_pending),
          adapter_pending: Wiregrid.Capacity.get(t.capacity, :adapter_pending),
          remote_presence: :ets.info(t.remote_presence, :size) || 0,
          remote_room_memberships: :ets.info(t.remote_room_edges, :size) || 0,
          webhook_jobs: :ets.info(t.webhook_jobs, :size) || 0,
          cluster_pending: if(cfg.cluster, do: Wiregrid.Cluster.pending(instance), else: 0),
          cluster_nodes: if(cfg.cluster, do: table_size(t.cluster_nodes), else: 0),
          memory_words: total_ets_memory(t)
        })

      _ ->
        %{}
    end
  end

  def idle?(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        deliveries = Wiregrid.Capacity.get(t.capacity, :delivery_reservations)
        webhooks = :ets.info(t.webhook_jobs, :size) || 0
        cluster = if cfg.cluster, do: Wiregrid.Cluster.pending(instance), else: 0
        deliveries == 0 and webhooks == 0 and cluster == 0

      _ ->
        true
    end
  end

  defp healthy_status?(:ok), do: true
  defp healthy_status?(:disabled), do: true
  defp healthy_status?(_), do: false

  defp optional_webhook_status(instance, _tables) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg} ->
        if Keyword.get(cfg.webhooks, :enabled, false) do
          process_status(Wiregrid.Webhook.Dispatcher.via(instance))
        else
          :disabled
        end

      _ ->
        :disabled
    end
  end

  defp optional_cluster_status(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: %{cluster: true, cluster_shards: shard_count}} ->
        topology = process_status(Wiregrid.Cluster.Topology.via(instance))

        shards_ok =
          Enum.all?(0..(shard_count - 1), fn shard ->
            process_status(Wiregrid.Cluster.Shard.via(instance, shard)) == :ok
          end)

        if topology == :ok and shards_ok, do: :ok, else: {:error, :not_running}

      _ ->
        :disabled
    end
  end

  defp process_status(via) do
    case GenServer.whereis(via) do
      pid when is_pid(pid) -> :ok
      _ -> {:error, :not_running}
    end
  rescue
    ArgumentError -> {:error, :not_running}
  end

  defp total_ets_memory(tables) do
    tables
    |> Map.values()
    |> Enum.reduce(0, fn table, acc -> acc + (:ets.info(table, :memory) || 0) end)
  end

  defp saturated_resources(resources, threshold) do
    resources
    |> Enum.reduce([], fn {name, %{ratio: ratio} = value}, acc ->
      if ratio >= threshold, do: [{name, value} | acc], else: acc
    end)
    |> Enum.reverse()
  end

  defp resource(used, limit) when is_integer(used) and is_integer(limit) and limit > 0 do
    %{
      used: used,
      limit: limit,
      headroom: max(limit - used, 0),
      ratio: used / limit
    }
  end

  defp table_size(table), do: :ets.info(table, :size) || 0
end
