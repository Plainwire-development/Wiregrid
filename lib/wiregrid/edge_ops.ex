defmodule Wiregrid.EdgeOps do
  @moduledoc false

  # Subscription and presence-watch lifecycle mutations execute from the
  # per-instance Runtime serializer. Keeping the mutation code here makes the
  # invariants independently auditable without introducing another process or
  # mailbox hop.

  def subscribe(instance, cfg, sid, topic, context) when is_map(context) do
    with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.metadata(context, cfg.max_metadata_bytes),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth),
         %{tables: t} <- Wiregrid.Tables.get(instance),
         [{^sid, session}] <- :ets.lookup(t.sessions, sid),
         :ok <- Wiregrid.Authorizer.check(instance, cfg, :subscribe, session, topic, context),
         false <- :ets.member(t.subscription_edges, {sid, topic}),
         current <- :wiregrid_hot.session_counter_get(t.session_counters, sid, 5),
         true <- current < cfg.max_subscriptions_per_session,
         :ok <-
           Wiregrid.Capacity.reserve(t.capacity, :subscription_edges, cfg.max_subscription_edges),
         true <- :ets.insert_new(t.subscription_edges, {{sid, topic}, true}) do
      :ok = Wiregrid.FanoutIndex.add(t, :topic, topic, sid, cfg.fanout_buckets)
      true = :ets.insert(t.session_topics, {sid, topic})
      {:ok, _} = :wiregrid_hot.session_counter_add(t.session_counters, sid, 5, 1)
      {:ok, _} = :wiregrid_hot.counter_add(t.topic_counts, topic, 1)
      _ = Wiregrid.Metrics.increment(instance, :subscriptions)
      :ok
    else
      true -> :ok
      [] -> {:error, :unknown_session}
      false -> {:error, :subscription_capacity}
      {:error, :capacity} -> reject(instance, :subscription_capacity)
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  def subscribe(_instance, _cfg, _sid, _topic, _context), do: {:error, :invalid_context}

  def unsubscribe(instance, cfg, sid, topic) do
    with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth),
         %{tables: t} <- Wiregrid.Tables.get(instance) do
      key = {sid, topic}

      case :ets.take(t.subscription_edges, key) do
        [{^key, true}] ->
          :ok = Wiregrid.FanoutIndex.delete(t, :topic, topic, sid, cfg.fanout_buckets)
          :ets.delete_object(t.session_topics, {sid, topic})
          _ = :wiregrid_hot.session_counter_add(t.session_counters, sid, 5, -1)
          _ = :wiregrid_hot.counter_add_clamped(t.topic_counts, topic, -1)
          maybe_delete_zero_counter(t.topic_counts, topic)
          _ = Wiregrid.Capacity.release(t.capacity, :subscription_edges)
          _ = Wiregrid.Metrics.increment(instance, :subscriptions, -1)
          :ok

        [] ->
          :ok
      end
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def watch_presence(instance, cfg, sid, user_id, context) when is_map(context) do
    with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.metadata(context, cfg.max_metadata_bytes),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         %{tables: t} <- Wiregrid.Tables.get(instance),
         [{^sid, session}] <- :ets.lookup(t.sessions, sid),
         :ok <-
           Wiregrid.Authorizer.check(instance, cfg, :watch_presence, session, user_id, context),
         false <- :ets.member(t.presence_watch_edges, {sid, user_id}),
         session_count <- :wiregrid_hot.session_counter_get(t.session_counters, sid, 6),
         true <- session_count < cfg.max_presence_watches_per_session,
         user_count <- :wiregrid_hot.counter_get(t.presence_watcher_counts, user_id),
         true <- user_count < cfg.max_watchers_per_user,
         :ok <-
           Wiregrid.Capacity.reserve(
             t.capacity,
             :presence_watch_edges,
             cfg.max_presence_watch_edges
           ),
         true <- :ets.insert_new(t.presence_watch_edges, {{sid, user_id}, true}) do
      :ok = Wiregrid.FanoutIndex.add(t, :presence, user_id, sid, cfg.fanout_buckets)
      true = :ets.insert(t.session_watches, {sid, user_id})
      {:ok, _} = :wiregrid_hot.session_counter_add(t.session_counters, sid, 6, 1)
      {:ok, _} = :wiregrid_hot.counter_add(t.presence_watcher_counts, user_id, 1)
      _ = Wiregrid.Metrics.increment(instance, :presence_watches)
      :ok
    else
      true -> :ok
      [] -> {:error, :unknown_session}
      false -> {:error, :presence_watch_capacity}
      {:error, :capacity} -> reject(instance, :presence_watch_capacity)
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  def watch_presence(_instance, _cfg, _sid, _user_id, _context), do: {:error, :invalid_context}

  def unwatch_presence(instance, cfg, sid, user_id) do
    with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         %{tables: t} <- Wiregrid.Tables.get(instance) do
      key = {sid, user_id}

      case :ets.take(t.presence_watch_edges, key) do
        [{^key, true}] ->
          :ok = Wiregrid.FanoutIndex.delete(t, :presence, user_id, sid, cfg.fanout_buckets)
          :ets.delete_object(t.session_watches, {sid, user_id})
          _ = :wiregrid_hot.session_counter_add(t.session_counters, sid, 6, -1)
          _ = :wiregrid_hot.counter_add_clamped(t.presence_watcher_counts, user_id, -1)
          maybe_delete_zero_counter(t.presence_watcher_counts, user_id)
          _ = Wiregrid.Capacity.release(t.capacity, :presence_watch_edges)
          _ = Wiregrid.Metrics.increment(instance, :presence_watches, -1)
          :ok

        [] ->
          :ok
      end
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def cleanup_subscriptions(instance, cfg, sid) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        Enum.each(:ets.lookup(t.session_topics, sid), fn {^sid, topic} ->
          unsubscribe(instance, cfg, sid, topic)
        end)

        :ets.delete(t.session_topics, sid)
        :ok

      _ ->
        :ok
    end
  end

  def cleanup_watches(instance, cfg, sid) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        Enum.each(:ets.lookup(t.session_watches, sid), fn {^sid, user_id} ->
          unwatch_presence(instance, cfg, sid, user_id)
        end)

        :ets.delete(t.session_watches, sid)
        :ok

      _ ->
        :ok
    end
  end

  defp reject(instance, reason) do
    _ = Wiregrid.Metrics.increment(instance, :admission_rejections)
    {:error, reason}
  end

  defp maybe_delete_zero_counter(table, key) do
    case :ets.lookup(table, key) do
      [{^key, 0}] -> :ets.delete(table, key)
      _ -> :ok
    end
  end
end
