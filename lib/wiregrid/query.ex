defmodule Wiregrid.Query do
  @moduledoc """
  Bounded read-only inspection of Wiregrid runtime state.

  This module intentionally returns sanitized public data and never exposes
  session owner PIDs, monitor references, resume-token hashes, or ETS table
  identifiers. All list-returning operations are bounded by the instance
  `:max_query_results` configuration.
  """

  @safe_limit_keys [
    :profile,
    :max_sessions,
    :max_sessions_per_user,
    :max_sessions_per_owner,
    :max_subscription_edges,
    :max_subscriptions_per_session,
    :max_presence_watch_edges,
    :max_presence_watches_per_session,
    :max_watchers_per_user,
    :max_room_edges,
    :max_rooms_per_session,
    :max_room_members,
    :max_room_states,
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
    :max_event_bytes,
    :max_encoded_event_bytes,
    :max_websocket_frame_bytes,
    :max_batch_items,
    :max_batch_targets,
    :max_query_results,
    :soft_queue,
    :hard_queue,
    :fanout_buckets,
    :cluster_shards,
    :cluster_pending_per_shard
  ]

  def session(instance, session_id) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes) do
      case :ets.lookup(t.sessions, session_id) do
        [{^session_id, session}] -> {:ok, public_session(instance, session)}
        [] -> {:error, :unknown_session}
      end
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def user_sessions(instance, user_id, limit \\ nil) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         {:ok, limit} <- query_limit(limit, cfg) do
      sessions =
        t.user_sessions
        |> :ets.lookup(user_id)
        |> Enum.take(limit)
        |> Enum.flat_map(fn {^user_id, sid} ->
          case :ets.lookup(t.sessions, sid) do
            [{^sid, session}] -> [public_session(instance, session)]
            [] -> []
          end
        end)

      {:ok, sessions}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def subscriptions(instance, session_id, limit \\ nil),
    do: session_edges(instance, session_id, :session_topics, limit)

  def rooms(instance, session_id, limit \\ nil),
    do: session_edges(instance, session_id, :session_rooms, limit)

  def presence_watches(instance, session_id, limit \\ nil),
    do: session_edges(instance, session_id, :session_watches, limit)

  def topic_sessions(instance, topic, limit \\ nil) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth),
         {:ok, limit} <- query_limit(limit, cfg) do
      {:ok, Wiregrid.FanoutIndex.take(t, :topic, topic, limit)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Returns one bounded, sanitized snapshot of a session and its local edges."
  def session_state(instance, session_id, limit \\ nil) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         {:ok, limit} <- query_limit(limit, cfg),
         {:ok, session} <- session(instance, session_id),
         {:ok, subscriptions} <- subscriptions(instance, session_id, limit),
         {:ok, rooms} <- rooms(instance, session_id, limit),
         {:ok, watches} <- presence_watches(instance, session_id, limit) do
      {:ok,
       %{session: session, subscriptions: subscriptions, rooms: rooms, presence_watches: watches}}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Returns a bounded topic summary without scanning unrelated subscriptions."
  def topic_info(instance, topic, limit \\ nil) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth),
         {:ok, limit} <- query_limit(limit, cfg),
         {:ok, count} <- topic_subscriber_count(instance, topic),
         {:ok, sessions} <- topic_sessions(instance, topic, limit) do
      {:ok,
       %{
         topic: topic,
         subscriber_count: count,
         sessions: sessions,
         truncated: count > length(sessions)
       }}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Returns bounded local/remote room members plus the current room state."
  def room_info(instance, room, limit \\ nil) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         {:ok, limit} <- query_limit(limit, cfg),
         {:ok, local_count} <- room_member_count(instance, room) do
      members = Wiregrid.Rooms.members(instance, room, limit)

      state =
        case Wiregrid.Rooms.metadata(instance, room) do
          {:ok, value} -> value
          :not_found -> nil
          {:error, _} -> nil
        end

      {:ok,
       %{
         room: room,
         local_member_count: local_count,
         members: members,
         state: state,
         sample_limit_reached: length(members) == limit
       }}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Returns one user's aggregate presence and a bounded session sample."
  def user_info(instance, user_id, limit \\ nil) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         {:ok, limit} <- query_limit(limit, cfg),
         {:ok, count} <- user_session_count(instance, user_id),
         {:ok, sessions} <- user_sessions(instance, user_id, limit) do
      {:ok,
       %{
         user_id: user_id,
         presence: Wiregrid.presence(instance, user_id),
         session_count: count,
         sessions: sessions,
         truncated: count > length(sessions)
       }}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def limits(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg} -> {:ok, Map.take(cfg, @safe_limit_keys)}
      _ -> {:error, :instance_unavailable}
    end
  end

  @doc "Returns the current local subscriber count for one topic in O(1)."
  def topic_subscriber_count(instance, topic) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth) do
      {:ok, :wiregrid_hot.counter_get(t.topic_counts, topic)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Returns the current local member count for one room in O(1)."
  def room_member_count(instance, room) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth) do
      {:ok, :wiregrid_hot.counter_get(t.room_counts, room)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Returns the current local watcher count for one user in O(1)."
  def presence_watcher_count(instance, user_id) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes) do
      {:ok, :wiregrid_hot.counter_get(t.presence_watcher_counts, user_id)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Returns the current session count for one user in O(1)."
  def user_session_count(instance, user_id) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes) do
      {:ok, :wiregrid_hot.counter_get(t.user_session_counts, user_id)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def room_member?(instance, room, session_id) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes) do
      :ets.member(t.room_edges, {room, session_id})
    else
      _ -> false
    end
  end

  def subscribed?(instance, session_id, topic) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth) do
      :ets.member(t.subscription_edges, {session_id, topic})
    else
      _ -> false
    end
  end

  defp session_edges(instance, session_id, table_key, limit) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         {:ok, limit} <- query_limit(limit, cfg),
         true <- :ets.member(t.sessions, session_id) do
      values =
        t
        |> Map.fetch!(table_key)
        |> :ets.lookup(session_id)
        |> Enum.take(limit)
        |> Enum.map(fn {^session_id, value} -> value end)

      {:ok, values}
    else
      :undefined -> {:error, :instance_unavailable}
      false -> {:error, :unknown_session}
      {:error, _} = error -> error
    end
  end

  defp query_limit(nil, cfg), do: {:ok, cfg.max_query_results}

  defp query_limit(limit, cfg)
       when is_integer(limit) and limit > 0 and limit <= cfg.max_query_results,
       do: {:ok, limit}

  defp query_limit(_, _), do: {:error, :invalid_limit}

  defp public_session(instance, session) do
    %{
      id: session.id,
      user_id: session.user_id,
      metadata: session.metadata,
      presence_metadata: session.presence_metadata,
      status: session.status,
      ack_mode: session.ack_mode,
      delivery_format: session.delivery_format,
      connected_at_ms: session.connected_at_ms,
      presence_updated_ms: session.presence_updated_ms,
      pending_deliveries: Wiregrid.Delivery.pending(instance, session.id)
    }
  end
end
