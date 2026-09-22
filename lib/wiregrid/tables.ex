defmodule Wiregrid.Tables do
  @moduledoc false
  use GenServer

  @table_specs [
    sessions: [:set, read_concurrency: true, write_concurrency: true],
    user_sessions: [:bag, read_concurrency: true, write_concurrency: true],
    user_index: [:set, read_concurrency: true, write_concurrency: true],
    user_session_counts: [:set, read_concurrency: true, write_concurrency: true],
    owner_sessions: [:bag, read_concurrency: true, write_concurrency: true],
    owner_session_counts: [:set, read_concurrency: true, write_concurrency: true],
    session_counters: [:set, read_concurrency: true, write_concurrency: true],
    subscription_edges: [:set, read_concurrency: true, write_concurrency: true],
    topic_sessions: [:ordered_set, read_concurrency: true, write_concurrency: true],
    topic_bucket_masks: [:set, read_concurrency: true, write_concurrency: true],
    topic_counts: [:set, read_concurrency: true, write_concurrency: true],
    session_topics: [:bag, read_concurrency: true, write_concurrency: true],
    presence_watch_edges: [:set, read_concurrency: true, write_concurrency: true],
    presence_watchers: [:ordered_set, read_concurrency: true, write_concurrency: true],
    presence_watcher_bucket_masks: [:set, read_concurrency: true, write_concurrency: true],
    session_watches: [:bag, read_concurrency: true, write_concurrency: true],
    presence_watcher_counts: [:set, read_concurrency: true, write_concurrency: true],
    room_edges: [:set, read_concurrency: true, write_concurrency: true],
    room_sessions: [:ordered_set, read_concurrency: true, write_concurrency: true],
    room_bucket_masks: [:set, read_concurrency: true, write_concurrency: true],
    session_rooms: [:bag, read_concurrency: true, write_concurrency: true],
    room_counts: [:set, read_concurrency: true, write_concurrency: true],
    room_grace: [:set, read_concurrency: true, write_concurrency: true],
    room_state: [:set, read_concurrency: true, write_concurrency: true],
    room_state_keys: [:set, read_concurrency: true, write_concurrency: true],
    resume_snapshots: [:set, read_concurrency: true, write_concurrency: true],
    delivery_reservations: [:ordered_set, read_concurrency: true, write_concurrency: true],
    slow_evicting: [:set, read_concurrency: true, write_concurrency: true],
    activity_keys: [:set, read_concurrency: true, write_concurrency: true],
    activities: [:set, read_concurrency: true, write_concurrency: true],
    activities_by_topic: [:bag, read_concurrency: true, write_concurrency: true],
    activities_by_session: [:bag, read_concurrency: true, write_concurrency: true],
    receipt_keys: [:set, read_concurrency: true, write_concurrency: true],
    receipts: [:set, read_concurrency: true, write_concurrency: true],
    receipts_by_session: [:bag, read_concurrency: true, write_concurrency: true],
    rate_limit_keys: [:set, read_concurrency: true, write_concurrency: true],
    rate_limits: [:set, read_concurrency: true, write_concurrency: true],
    capacity: [:set, read_concurrency: true, write_concurrency: true],
    metrics: [:set, read_concurrency: true, write_concurrency: true],
    runtime_flags: [:set, read_concurrency: true, write_concurrency: true],
    expiry: [:ordered_set, read_concurrency: true, write_concurrency: true],
    expiry_index: [:set, read_concurrency: true, write_concurrency: true],
    seen_cluster: [:set, read_concurrency: true, write_concurrency: true],
    cluster_nodes: [:set, read_concurrency: true, write_concurrency: true],
    remote_presence: [:set, read_concurrency: true, write_concurrency: true],
    remote_presence_by_user: [:bag, read_concurrency: true, write_concurrency: true],
    remote_presence_by_node: [:bag, read_concurrency: true, write_concurrency: true],
    remote_room_edges: [:set, read_concurrency: true, write_concurrency: true],
    remote_rooms: [:ordered_set, read_concurrency: true, write_concurrency: true],
    remote_rooms_by_node: [:bag, read_concurrency: true, write_concurrency: true],
    memory_event_ids: [:set, read_concurrency: true, write_concurrency: true],
    memory_events: [:ordered_set, read_concurrency: true, write_concurrency: true],
    memory_cache_keys: [:set, read_concurrency: true, write_concurrency: true],
    memory_cache: [:set, read_concurrency: true, write_concurrency: true],
    webhook_jobs: [:set, read_concurrency: true, write_concurrency: true],
    webhook_due: [:ordered_set, read_concurrency: true, write_concurrency: true]
  ]

  def start_link({instance, config}) do
    GenServer.start_link(__MODULE__, {instance, config}, name: via(instance))
  end

  def via(instance), do: {:via, Registry, {Wiregrid.ProcessRegistry, {:tables, instance}}}

  def get(instance), do: :persistent_term.get({__MODULE__, instance}, :undefined)

  @impl true
  def init({instance, config}) do
    tables =
      Map.new(@table_specs, fn {name, options} ->
        tid = :ets.new(name, [:public | options])
        {name, tid}
      end)

    true = :ets.insert(tables.runtime_flags, {:draining, false})
    true = :ets.insert(tables.runtime_flags, {:control_ready, false})
    state = %{instance: instance, config: config, tables: tables}
    :persistent_term.put({__MODULE__, instance}, state)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, %{instance: instance}) do
    :persistent_term.erase({__MODULE__, instance})
    :ok
  end
end
