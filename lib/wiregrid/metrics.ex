defmodule Wiregrid.Metrics do
  @moduledoc false

  @gauges [
    :sessions,
    :subscriptions,
    :presence_watches,
    :room_memberships,
    :delivery_reservations
  ]

  @known [
    :connections_total,
    :disconnects_total,
    :sessions,
    :subscriptions,
    :presence_watches,
    :room_memberships,
    :deliveries_total,
    :delivery_reservations,
    :dropped_ephemeral,
    :slow_consumers,
    :admission_rejections,
    :control_rejections,
    :rate_limit_rejections,
    :callback_rejections,
    :adapter_calls_total,
    :adapter_failures,
    :adapter_timeouts,
    :adapter_rejections,
    :cluster_messages_sent,
    :cluster_messages_received,
    :cluster_messages_dropped,
    :cluster_resyncs,
    :webhook_enqueued,
    :webhook_delivered,
    :webhook_retries,
    :webhook_failures,
    :topology_syncs,
    :topology_sync_failures,
    :dispatch_plans_compiled,
    :dispatch_plan_executions,
    :dispatch_plan_failures
  ]

  def increment(instance, key, delta \\ 1)

  def increment(instance, key, delta) when key in @known and is_integer(delta) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: %{metrics: table}} ->
        result = :wiregrid_hot.counter_add(table, key, delta)

        if cfg.telemetry_metric_events do
          Wiregrid.Telemetry.emit([:metric], %{delta: delta}, %{instance: instance, metric: key})
        end

        result

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def increment(_instance, _key, _delta), do: {:error, :unknown_metric}

  def set_gauge(instance, key, value) when key in @gauges and is_integer(value) and value >= 0 do
    case Wiregrid.Tables.get(instance) do
      %{tables: %{metrics: table}} ->
        true = :ets.insert(table, {key, value})
        {:ok, value}

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def set_gauge(_instance, _key, _value), do: {:error, :invalid_gauge}

  def get(instance, key) do
    case Wiregrid.Tables.get(instance) do
      %{tables: %{metrics: table}} -> :wiregrid_hot.counter_get(table, key)
      _ -> 0
    end
  end

  def snapshot(instance) do
    Map.new(@known, fn key -> {key, get(instance, key)} end)
  end
end
