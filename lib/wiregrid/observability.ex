defmodule Wiregrid.Observability do
  @moduledoc """
  Privacy-preserving operational metric export.

  Wiregrid deliberately does not run an HTTP exporter or send telemetry
  anywhere. `prometheus/1` produces a fixed-schema Prometheus text payload that
  the embedding application may expose through its existing metrics endpoint.

  The schema contains aggregate counters/gauges only. It never creates labels
  from users, sessions, topics, rooms, URLs, database names, or message data, so
  metric cardinality remains bounded and application identifiers do not leak
  through this interface.
  """

  @metric_types %{
    connections_total: :counter,
    disconnects_total: :counter,
    deliveries_total: :counter,
    dropped_ephemeral: :counter,
    slow_consumers: :counter,
    admission_rejections: :counter,
    control_rejections: :counter,
    callback_rejections: :counter,
    adapter_calls_total: :counter,
    adapter_failures: :counter,
    adapter_timeouts: :counter,
    adapter_rejections: :counter,
    rate_limit_rejections: :counter,
    cluster_messages_sent: :counter,
    cluster_messages_received: :counter,
    cluster_messages_dropped: :counter,
    cluster_resyncs: :counter,
    webhook_enqueued: :counter,
    webhook_delivered: :counter,
    webhook_retries: :counter,
    webhook_failures: :counter,
    topology_syncs: :counter,
    topology_sync_failures: :counter,
    dispatch_plans_compiled: :counter,
    dispatch_plan_executions: :counter,
    dispatch_plan_failures: :counter,
    sessions: :gauge,
    users: :gauge,
    owner_processes: :gauge,
    subscriptions: :gauge,
    topics: :gauge,
    rooms: :gauge,
    room_memberships: :gauge,
    room_states: :gauge,
    presence_watches: :gauge,
    activities: :gauge,
    receipts: :gauge,
    rate_limit_buckets: :gauge,
    cache_entries: :gauge,
    expiry_entries: :gauge,
    delivery_reservations: :gauge,
    control_pending: :gauge,
    callback_pending: :gauge,
    adapter_pending: :gauge,
    remote_presence: :gauge,
    remote_room_memberships: :gauge,
    webhook_jobs: :gauge,
    cluster_pending: :gauge,
    cluster_nodes: :gauge,
    memory_words: :gauge
  }

  @doc "Returns aggregate Wiregrid metrics in Prometheus text exposition format."
  @spec prometheus(term()) :: {:ok, binary()} | {:error, :instance_unavailable}
  def prometheus(instance) do
    case Wiregrid.Tables.get(instance) do
      %{tables: _} -> {:ok, encode(Wiregrid.Health.stats(instance))}
      _ -> {:error, :instance_unavailable}
    end
  end

  @doc "Returns the fixed exported metric names and their Prometheus types."
  @spec schema() :: %{atom() => :counter | :gauge}
  def schema, do: @metric_types

  defp encode(stats) do
    @metric_types
    |> Enum.sort_by(fn {name, _type} -> Atom.to_string(name) end)
    |> Enum.map_join("", fn {name, type} ->
      value = numeric(Map.get(stats, name, 0))
      metric = "wiregrid_" <> Atom.to_string(name)
      "# TYPE #{metric} #{type}\n#{metric} #{value}\n"
    end)
  end

  defp numeric(value) when is_integer(value) or is_float(value), do: value
  defp numeric(_), do: 0
end
