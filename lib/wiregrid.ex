defmodule Wiregrid do
  @moduledoc """
  Stable Elixir API for the Wiregrid realtime runtime.

  Wiregrid owns generic realtime infrastructure: sessions, subscriptions,
  bounded delivery, presence, rooms, signaling, activity, receipts, storage,
  caches and optional clustering/transports. Product semantics remain in the
  embedding application.
  """

  @type instance :: term()
  @type user_id :: term()
  @type session_id :: binary()
  @type topic ::
          {:user, term()}
          | {:channel, term()}
          | {:thread, term()}
          | {:room, term()}
          | {:game, term()}
          | {:document, term()}
          | {:custom, term(), term()}
  @type target ::
          {:topic, topic()} | {:room, topic()} | {:user, user_id()} | {:session, session_id()}
  @type delivery_class :: :durable | :ephemeral
  @type presence_status :: :online | :idle | :dnd | :invisible | :offline | {:custom, binary()}
  @type result(value) :: {:ok, value} | {:error, term()}

  @publish_options [
    :event_id,
    :persist,
    :meta,
    :class,
    :session_id,
    :cluster,
    :exclude_sessions,
    :exclude_users
  ]
  @batch_publish_options [
    :persist,
    :meta,
    :class,
    :session_id,
    :cluster,
    :exclude_sessions,
    :exclude_users
  ]
  @direct_options [:class, :session_id]
  @user_direct_options [:class, :session_id, :cluster, :event_id, :persist, :meta]
  @user_batch_options [:class, :session_id, :cluster]

  @doc "Returns the Wiregrid library version as a binary."
  def version(), do: Wiregrid.Info.version()

  @doc "Returns the stable plain-term protocol/ABI generation."
  def protocol_version(), do: Wiregrid.Info.protocol_version()

  @doc "Returns the foreign gateway protocol generation."
  def foreign_protocol_version(), do: Wiregrid.Foreign.Protocol.version()

  @doc "Returns the native C ABI major generation."
  def c_abi_major(), do: Wiregrid.Foreign.Gateway.c_abi_major()

  @doc "Returns sanitized feature discovery for a running instance."
  def capabilities(instance), do: Wiregrid.Info.capabilities(instance)
  def deployment_report(instance), do: Wiregrid.Info.deployment_report(instance)

  @doc "Returns capabilities, public limits, health and bounded statistics."
  def describe(instance), do: Wiregrid.Info.describe(instance)

  def start_instance(instance, opts \\ []) do
    with :ok <- Wiregrid.Validation.instance(instance),
         {:ok, cfg} <- Wiregrid.Config.build(opts) do
      spec = %{
        id: {Wiregrid.InstanceSupervisor, instance},
        start: {Wiregrid.InstanceSupervisor, :start_link, [{instance, cfg}]},
        restart: :permanent,
        type: :supervisor
      }

      case DynamicSupervisor.start_child(Wiregrid.InstanceSupervisor, spec) do
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end
    end
  end

  @doc "Returns a supervisor child spec for embedding an instance in an OTP tree."
  def instance_child_spec(instance, opts \\ []),
    do: Wiregrid.Instance.child_spec(instance: instance, options: opts)

  def stop_instance(instance) do
    case Registry.lookup(Wiregrid.ProcessRegistry, {:instance_supervisor, instance}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Wiregrid.InstanceSupervisor, pid)
      [] -> {:error, :not_found}
    end
  end

  def connect(instance, user_id, pid, opts \\ []),
    do: Wiregrid.Runtime.connect(instance, user_id, pid, opts)

  def connect_resumable(instance, user_id, pid, opts \\ []),
    do: Wiregrid.Runtime.connect_resumable(instance, user_id, pid, opts)

  def resume_session(instance, user_id, pid, token, opts \\ []),
    do: Wiregrid.Runtime.resume_session(instance, user_id, pid, token, opts)

  @doc "Returns a session-bound Elixir actor for an existing live session."
  @spec actor(term(), binary()) :: {:ok, Wiregrid.Actor.t()} | {:error, term()}
  def actor(instance, session_id), do: Wiregrid.Actor.new(instance, session_id)

  @doc "Connects a session and returns a session-bound Elixir actor."
  @spec connect_actor(term(), term(), pid(), keyword()) ::
          {:ok, Wiregrid.Actor.t()} | {:error, term()}
  def connect_actor(instance, user_id, pid, opts \\ []) do
    with {:ok, session_id} <- connect(instance, user_id, pid, opts) do
      {:ok, %Wiregrid.Actor{instance: instance, session_id: session_id, user_id: user_id}}
    end
  end

  @doc "Connects a resumable session and returns the actor plus its one-time resume token."
  @spec connect_resumable_actor(term(), term(), pid(), keyword()) ::
          {:ok, Wiregrid.Actor.t(), binary()} | {:error, term()}
  def connect_resumable_actor(instance, user_id, pid, opts \\ []) do
    with {:ok, session_id, token} <- connect_resumable(instance, user_id, pid, opts) do
      {:ok, %Wiregrid.Actor{instance: instance, session_id: session_id, user_id: user_id}, token}
    end
  end

  @doc "Resumes a session and returns a new actor, rotated resume token and restoration report."
  @spec resume_actor(term(), term(), pid(), binary(), keyword()) ::
          {:ok, Wiregrid.Actor.t(), binary(), map()} | {:error, term()}
  def resume_actor(instance, user_id, pid, token, opts \\ []) do
    with {:ok, %{session_id: session_id, resume_token: next, restored: restored}} <-
           resume_session(instance, user_id, pid, token, opts) do
      {:ok, %Wiregrid.Actor{instance: instance, session_id: session_id, user_id: user_id}, next,
       restored}
    end
  end

  def disconnect(instance, session_id, reason \\ :normal),
    do: Wiregrid.Runtime.disconnect(instance, session_id, reason)

  def disconnect_user(instance, user_id, reason \\ :normal),
    do: Wiregrid.Runtime.disconnect_user(instance, user_id, reason)

  def set_session_metadata(instance, session_id, metadata),
    do: Wiregrid.Runtime.set_session_metadata(instance, session_id, metadata)

  def subscribe(instance, session_id, topic, context \\ %{}),
    do: Wiregrid.Runtime.subscribe(instance, session_id, topic, context)

  def unsubscribe(instance, session_id, topic),
    do: Wiregrid.Runtime.unsubscribe(instance, session_id, topic)

  def subscribe_many(instance, session_id, topics, context \\ %{}),
    do: Wiregrid.Runtime.subscribe_many(instance, session_id, topics, context)

  def unsubscribe_many(instance, session_id, topics),
    do: Wiregrid.Runtime.unsubscribe_many(instance, session_id, topics)

  @doc "Reconciles a session's subscriptions to exactly the desired bounded set."
  def sync_subscriptions(instance, session_id, topics, context \\ %{}),
    do: Wiregrid.Runtime.sync_subscriptions(instance, session_id, topics, context)

  @doc """
  Reconciles selected session topology domains in one serialized lifecycle turn.

  The `topology` map may contain `:subscriptions`, `:presence_watches`, and
  `:rooms`. Omitted domains are left untouched. Each requested domain reports
  success/failure independently; Wiregrid does not misrepresent several edge
  sets as one atomic distributed transaction.
  """
  def sync_topology(instance, session_id, topology, opts \\ []),
    do: Wiregrid.Runtime.sync_topology(instance, session_id, topology, opts)

  @doc "Validates and encodes an event once for repeated publish/send operations."
  def prepare(instance, event), do: Wiregrid.Prepared.prepare(instance, event)

  def publish(instance, topic, event, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @publish_options),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, normalized} <- normalize_publish_opts(opts, cfg),
         :ok <- authorize_actor(instance, cfg, t, :publish, topic, normalized),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event),
         :ok <-
           maybe_persist(
             instance,
             topic,
             normalized.event_id,
             event,
             normalized.meta,
             normalized.persist
           ),
         {:ok, counts} <-
           Wiregrid.Fanout.topic(
             instance,
             topic,
             payload,
             event,
             normalized.class,
             fanout_opts(normalized)
           ) do
      cluster =
        cluster_status(normalized.cluster, fn ->
          Wiregrid.Cluster.topic(
            instance,
            topic,
            normalized.event_id,
            payload,
            normalized.class,
            fanout_opts(normalized)
          )
        end)

      {:ok, counts |> Map.put(:event_id, normalized.event_id) |> Map.put(:cluster, cluster)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Publishes an already prepared event without running the codec again."
  def publish_prepared(instance, topic, prepared, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @publish_options),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth),
         {:ok, event, payload} <- Wiregrid.Prepared.unpack(instance, prepared),
         {:ok, normalized} <- normalize_publish_opts(opts, cfg),
         :ok <- authorize_actor(instance, cfg, t, :publish, topic, normalized),
         :ok <-
           maybe_persist(
             instance,
             topic,
             normalized.event_id,
             event,
             normalized.meta,
             normalized.persist
           ),
         {:ok, counts} <-
           Wiregrid.Fanout.topic(
             instance,
             topic,
             payload,
             event,
             normalized.class,
             fanout_opts(normalized)
           ) do
      cluster =
        cluster_status(normalized.cluster, fn ->
          Wiregrid.Cluster.topic(
            instance,
            topic,
            normalized.event_id,
            payload,
            normalized.class,
            fanout_opts(normalized)
          )
        end)

      {:ok, counts |> Map.put(:event_id, normalized.event_id) |> Map.put(:cluster, cluster)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc """
  Publishes a bounded batch to one topic with one authorization decision.

  Every event is validated before the first side effect. Encoding, persistence
  and fanout are reported per event because those operations can fail
  independently; Wiregrid does not pretend a distributed batch is atomic.
  """
  def publish_batch(instance, topic, events, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @batch_publish_options),
         :ok <- Wiregrid.Validation.bounded_list(events, cfg.max_batch_items),
         true <- events != [],
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- validate_events(events, cfg),
         {:ok, normalized} <- normalize_batch_publish_opts(opts, cfg),
         :ok <- authorize_actor(instance, cfg, t, :publish, topic, normalized) do
      results =
        events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} ->
          case publish_batch_event(instance, cfg, topic, event, normalized) do
            {:ok, result} -> {:ok, Map.put(result, :index, index)}
            {:error, reason} -> {:error, %{index: index, reason: reason}}
          end
        end)

      completed = Enum.count(results, &match?({:ok, _}, &1))
      {:ok, %{completed: completed, failed: length(results) - completed, results: results}}
    else
      false -> {:error, :empty_batch}
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc """
  Publishes one event to a bounded set of topics with a single encoding pass.

  All topics and authorization decisions are checked before the first
  persistence/fanout side effect. The result is intentionally per-topic: a
  multi-topic publish is not a distributed transaction.
  """
  def publish_topics(instance, topics, event, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @publish_options),
         :ok <- Wiregrid.Validation.bounded_list(topics, cfg.max_batch_items),
         {:ok, topics} <- normalize_topics(topics, cfg),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, normalized} <- normalize_publish_opts(opts, cfg),
         :ok <- authorize_topics(instance, cfg, t, topics, normalized),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event) do
      results =
        Enum.map(topics, fn topic ->
          case publish_encoded_topic(instance, topic, event, payload, normalized) do
            {:ok, result} -> {:ok, Map.put(result, :topic, topic)}
            {:error, reason} -> {:error, %{topic: topic, reason: reason}}
          end
        end)

      completed = Enum.count(results, &match?({:ok, _}, &1))

      {:ok,
       %{
         event_id: normalized.event_id,
         completed: completed,
         failed: length(results) - completed,
         results: results
       }}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def publish_room(instance, room, event, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @publish_options),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, normalized} <- normalize_publish_opts(opts, cfg),
         :ok <- authorize_actor(instance, cfg, t, :publish_room, room, normalized),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event),
         :ok <-
           maybe_persist(
             instance,
             room,
             normalized.event_id,
             event,
             normalized.meta,
             normalized.persist
           ),
         {:ok, counts} <-
           Wiregrid.Fanout.room(
             instance,
             room,
             payload,
             event,
             normalized.class,
             fanout_opts(normalized)
           ) do
      cluster =
        cluster_status(normalized.cluster, fn ->
          Wiregrid.Cluster.room_event(
            instance,
            room,
            normalized.event_id,
            payload,
            normalized.class,
            fanout_opts(normalized)
          )
        end)

      {:ok, counts |> Map.put(:event_id, normalized.event_id) |> Map.put(:cluster, cluster)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def send_user(instance, user_id, event, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @user_direct_options),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, class} <- event_class(Keyword.get(opts, :class, :durable)),
         {:ok, event_id} <- event_id(Keyword.get(opts, :event_id), cfg),
         {:ok, persist} <-
           boolean_opt(Keyword.get(opts, :persist, false), :invalid_persist_option),
         {:ok, meta} <- metadata_opt(Keyword.get(opts, :meta, %{}), cfg),
         {:ok, cluster} <- boolean_opt(Keyword.get(opts, :cluster, true), :invalid_cluster_option),
         :ok <- authorize_direct(instance, cfg, t, :send_user, user_id, opts),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event),
         :ok <- maybe_persist(instance, {:user, user_id}, event_id, event, meta, persist),
         {:ok, local} <- Wiregrid.Fanout.user(instance, user_id, payload, event, class) do
      remote =
        cluster_status(cluster and cfg.cluster, fn ->
          Wiregrid.Cluster.user_event(instance, user_id, event_id, payload, class)
        end)

      {:ok, local |> Map.put(:event_id, event_id) |> Map.put(:cluster, remote)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def send_session(instance, target_session_id, event, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @direct_options),
         :ok <- Wiregrid.Validation.session_id(target_session_id, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, class} <- event_class(Keyword.get(opts, :class, :durable)),
         :ok <- authorize_direct(instance, cfg, t, :send_session, target_session_id, opts),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event) do
      case Wiregrid.Delivery.send_session(
             instance,
             target_session_id,
             {:custom, :session, target_session_id},
             payload,
             event,
             class
           ) do
        :sent -> {:ok, :sent}
        other -> {:error, other}
      end
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Delivers one encoded event to a bounded set of sessions."
  def send_sessions(instance, session_ids, event, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @direct_options),
         {:ok, targets} <- normalize_session_targets(session_ids, cfg),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, class} <- event_class(Keyword.get(opts, :class, :durable)),
         :ok <- authorize_direct(instance, cfg, t, :send_sessions, targets, opts),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event) do
      {:ok, direct_fanout(instance, targets, {:custom, :sessions}, payload, event, class)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Delivers one encoded event to every current session of bounded users."
  def send_users(instance, user_ids, event, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @user_batch_options),
         {:ok, users} <- normalize_user_targets(user_ids, cfg),
         {:ok, targets} <- sessions_for_users(t, users, cfg.max_batch_targets),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, class} <- event_class(Keyword.get(opts, :class, :durable)),
         {:ok, cluster} <- boolean_opt(Keyword.get(opts, :cluster, true), :invalid_cluster_option),
         :ok <- authorize_direct(instance, cfg, t, :send_users, users, opts),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event) do
      event_id = Wiregrid.ID.generate()
      local = direct_fanout(instance, targets, {:custom, :users}, payload, event, class)

      remote =
        cluster_user_batch(instance, users, event_id, payload, class, cluster and cfg.cluster)

      {:ok, local |> Map.put(:event_id, event_id) |> Map.put(:cluster, remote)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Publishes one prepared event to a bounded set of topics with one decode-free payload reuse."
  def publish_topics_prepared(instance, topics, prepared, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @publish_options),
         :ok <- Wiregrid.Validation.bounded_list(topics, cfg.max_batch_items),
         {:ok, topics} <- normalize_topics(topics, cfg),
         {:ok, event, payload} <- Wiregrid.Prepared.unpack(instance, prepared),
         {:ok, normalized} <- normalize_publish_opts(opts, cfg),
         :ok <- authorize_topics(instance, cfg, t, topics, normalized) do
      results =
        Enum.map(topics, fn topic ->
          case publish_encoded_topic(instance, topic, event, payload, normalized) do
            {:ok, result} -> {:ok, Map.put(result, :topic, topic)}
            {:error, reason} -> {:error, %{topic: topic, reason: reason}}
          end
        end)

      completed = Enum.count(results, &match?({:ok, _}, &1))

      {:ok,
       %{
         event_id: normalized.event_id,
         completed: completed,
         failed: length(results) - completed,
         results: results
       }}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Publishes one event to a bounded set of rooms with a single encoding pass."
  def publish_rooms(instance, rooms, event, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @publish_options),
         :ok <- Wiregrid.Validation.bounded_list(rooms, cfg.max_batch_items),
         {:ok, rooms} <- normalize_topics(rooms, cfg),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         {:ok, normalized} <- normalize_publish_opts(opts, cfg),
         :ok <- authorize_rooms(instance, cfg, t, rooms, normalized),
         {:ok, payload} <- Wiregrid.Codec.encode(cfg, event) do
      publish_rooms_encoded(instance, rooms, event, payload, normalized)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Publishes one prepared event to a bounded set of rooms without re-encoding."
  def publish_rooms_prepared(instance, rooms, prepared, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @publish_options),
         :ok <- Wiregrid.Validation.bounded_list(rooms, cfg.max_batch_items),
         {:ok, rooms} <- normalize_topics(rooms, cfg),
         {:ok, event, payload} <- Wiregrid.Prepared.unpack(instance, prepared),
         {:ok, normalized} <- normalize_publish_opts(opts, cfg),
         :ok <- authorize_rooms(instance, cfg, t, rooms, normalized) do
      publish_rooms_encoded(instance, rooms, event, payload, normalized)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Publishes one prepared event to one room without running the codec again."
  def publish_room_prepared(instance, room, prepared, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @publish_options),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         {:ok, event, payload} <- Wiregrid.Prepared.unpack(instance, prepared),
         {:ok, normalized} <- normalize_publish_opts(opts, cfg),
         :ok <- authorize_actor(instance, cfg, t, :publish_room, room, normalized) do
      publish_encoded_room(instance, room, event, payload, normalized)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Sends a prepared event to one session without encoding it again."
  def send_session_prepared(instance, target_session_id, prepared, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @direct_options),
         :ok <- Wiregrid.Validation.session_id(target_session_id, cfg.max_session_id_bytes),
         {:ok, event, payload} <- Wiregrid.Prepared.unpack(instance, prepared),
         {:ok, class} <- event_class(Keyword.get(opts, :class, :durable)),
         :ok <- authorize_direct(instance, cfg, t, :send_session, target_session_id, opts) do
      case Wiregrid.Delivery.send_session(
             instance,
             target_session_id,
             {:custom, :session, target_session_id},
             payload,
             event,
             class
           ) do
        :sent -> {:ok, :sent}
        other -> {:error, other}
      end
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Sends a prepared event to every current session of one user."
  def send_user_prepared(instance, user_id, prepared, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @user_direct_options),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         {:ok, event, payload} <- Wiregrid.Prepared.unpack(instance, prepared),
         {:ok, class} <- event_class(Keyword.get(opts, :class, :durable)),
         {:ok, event_id} <- event_id(Keyword.get(opts, :event_id), cfg),
         {:ok, persist} <-
           boolean_opt(Keyword.get(opts, :persist, false), :invalid_persist_option),
         {:ok, meta} <- metadata_opt(Keyword.get(opts, :meta, %{}), cfg),
         {:ok, cluster} <- boolean_opt(Keyword.get(opts, :cluster, true), :invalid_cluster_option),
         :ok <- authorize_direct(instance, cfg, t, :send_user, user_id, opts),
         :ok <- maybe_persist(instance, {:user, user_id}, event_id, event, meta, persist),
         {:ok, local} <- Wiregrid.Fanout.user(instance, user_id, payload, event, class) do
      remote =
        cluster_status(cluster and cfg.cluster, fn ->
          Wiregrid.Cluster.user_event(instance, user_id, event_id, payload, class)
        end)

      {:ok, local |> Map.put(:event_id, event_id) |> Map.put(:cluster, remote)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Sends one prepared event to a bounded set of sessions without re-encoding."
  def send_sessions_prepared(instance, session_ids, prepared, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @direct_options),
         {:ok, targets} <- normalize_session_targets(session_ids, cfg),
         {:ok, event, payload} <- Wiregrid.Prepared.unpack(instance, prepared),
         {:ok, class} <- event_class(Keyword.get(opts, :class, :durable)),
         :ok <- authorize_direct(instance, cfg, t, :send_sessions, targets, opts) do
      {:ok, direct_fanout(instance, targets, {:custom, :sessions}, payload, event, class)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Sends one prepared event to every current session of bounded users without re-encoding."
  def send_users_prepared(instance, user_ids, prepared, opts \\ []) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- ensure_accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @user_batch_options),
         {:ok, users} <- normalize_user_targets(user_ids, cfg),
         {:ok, targets} <- sessions_for_users(t, users, cfg.max_batch_targets),
         {:ok, event, payload} <- Wiregrid.Prepared.unpack(instance, prepared),
         {:ok, class} <- event_class(Keyword.get(opts, :class, :durable)),
         {:ok, cluster} <- boolean_opt(Keyword.get(opts, :cluster, true), :invalid_cluster_option),
         :ok <- authorize_direct(instance, cfg, t, :send_users, users, opts) do
      event_id = Wiregrid.ID.generate()
      local = direct_fanout(instance, targets, {:custom, :users}, payload, event, class)

      remote =
        cluster_user_batch(instance, users, event_id, payload, class, cluster and cfg.cluster)

      {:ok, local |> Map.put(:event_id, event_id) |> Map.put(:cluster, remote)}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Dispatches one event to a bounded heterogeneous target set using one prepared encoding."
  def dispatch(instance, targets, event, opts \\ []),
    do: Wiregrid.Dispatch.dispatch(instance, targets, event, opts)

  @doc "Dispatches an already prepared event to topics, rooms, users and sessions."
  def dispatch_prepared(instance, targets, prepared, opts \\ []),
    do: Wiregrid.Dispatch.dispatch_prepared(instance, targets, prepared, opts)

  @doc "Compiles and integrity-binds a reusable heterogeneous dispatch target set."
  def compile_dispatch(instance, targets), do: Wiregrid.DispatchPlan.compile(instance, targets)

  @doc "Executes a reusable dispatch plan with a normal event."
  def dispatch_plan(instance, plan, event, opts \\ []),
    do: Wiregrid.Dispatch.dispatch_plan(instance, plan, event, opts)

  @doc "Executes a reusable dispatch plan with a prepared event."
  def dispatch_plan_prepared(instance, plan, prepared, opts \\ []),
    do: Wiregrid.Dispatch.dispatch_plan_prepared(instance, plan, prepared, opts)

  @doc "Consumes one delivery and acknowledges it only after successful handling."
  def consume_delivery(instance, envelope, handler),
    do: Wiregrid.Consumer.consume(instance, envelope, handler)

  @doc "Consumes a bounded delivery batch and groups acknowledgements by session."
  def consume_many_deliveries(instance, envelopes, handler),
    do: Wiregrid.Consumer.consume_many(instance, envelopes, handler)

  @doc "Consumes a bounded delivery batch in order, ACKing only the successful prefix."
  def consume_ordered_deliveries(instance, envelopes, handler),
    do: Wiregrid.Consumer.consume_ordered(instance, envelopes, handler)

  @doc "Folds a bounded delivery batch, commits once, then ACKs the committed batch."
  def consume_projection(instance, envelopes, accumulator, reducer, commit),
    do: Wiregrid.Consumer.project(instance, envelopes, accumulator, reducer, commit)

  @doc "Sends a correlated request to one session using ordinary Wiregrid delivery semantics."
  def request_session(instance, requester_session, target_session, event, opts \\ []),
    do:
      Wiregrid.RequestReply.request_session(
        instance,
        requester_session,
        target_session,
        event,
        opts
      )

  @doc "Replies to a Wiregrid request envelope without changing the application event schema."
  def reply(instance, replier_session, request_envelope, event, opts \\ []),
    do: Wiregrid.RequestReply.reply(instance, replier_session, request_envelope, event, opts)

  def request_context(envelope), do: Wiregrid.RequestReply.context(envelope)

  @doc "Returns the deterministic transport-token audience for an instance identity."
  def transport_audience(instance), do: Wiregrid.Transport.Auth.instance_audience(instance)

  @doc "Issues a bounded versioned HMAC transport token."
  def issue_transport_token(subject, keys, opts \\ []),
    do: Wiregrid.Transport.Auth.issue(subject, keys, opts)

  @doc "Verifies a Wiregrid transport token against a key ring."
  def verify_transport_token(token, keys, opts \\ []),
    do: Wiregrid.Transport.Auth.verify(token, keys, opts)

  def ack(instance, session_id, delivery_id) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.binary_id(delivery_id, cfg.max_storage_id_bytes) do
      Wiregrid.Delivery.ack(instance, session_id, delivery_id)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Acknowledges a bounded set of delivery IDs for one session."
  def ack_many(instance, session_id, delivery_ids) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.bounded_list(delivery_ids, cfg.max_batch_items),
         true <- delivery_ids != [],
         {:ok, ids} <- normalize_delivery_ids(delivery_ids, cfg) do
      Wiregrid.Delivery.ack_many(instance, session_id, ids)
    else
      false -> {:error, :empty_batch}
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def ack(instance, session_id) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes) do
      Wiregrid.Delivery.ack(instance, session_id)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def pending(instance, session_id) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg} ->
        case Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes) do
          :ok -> Wiregrid.Delivery.pending(instance, session_id)
          {:error, _} -> 0
        end

      _ ->
        0
    end
  end

  def set_presence(instance, session_id, status, metadata \\ %{}),
    do: Wiregrid.Runtime.set_presence(instance, session_id, status, metadata)

  def set_status(instance, session_id, status),
    do: set_presence(instance, session_id, status, %{})

  def presence(instance, user_id) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes) do
      Wiregrid.Presence.get(instance, user_id)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def watch_presence(instance, session_id, user_id, context \\ %{}),
    do: Wiregrid.Runtime.watch_presence(instance, session_id, user_id, context)

  def unwatch_presence(instance, session_id, user_id),
    do: Wiregrid.Runtime.unwatch_presence(instance, session_id, user_id)

  def watch_presence_many(instance, session_id, user_ids, context \\ %{}),
    do: Wiregrid.Runtime.watch_presence_many(instance, session_id, user_ids, context)

  def unwatch_presence_many(instance, session_id, user_ids),
    do: Wiregrid.Runtime.unwatch_presence_many(instance, session_id, user_ids)

  @doc "Reconciles a session's presence watches to exactly the desired bounded set."
  def sync_presence_watches(instance, session_id, user_ids, context \\ %{}),
    do: Wiregrid.Runtime.sync_presence_watches(instance, session_id, user_ids, context)

  def join_room(instance, room, session_id, opts \\ []),
    do: Wiregrid.Runtime.join_room(instance, room, session_id, opts)

  def leave_room(instance, room, session_id),
    do: Wiregrid.Runtime.leave_room(instance, room, session_id)

  def join_rooms(instance, rooms, session_id, opts \\ []),
    do: Wiregrid.Runtime.join_rooms(instance, rooms, session_id, opts)

  def leave_rooms(instance, rooms, session_id),
    do: Wiregrid.Runtime.leave_rooms(instance, rooms, session_id)

  @doc "Reconciles a session's room membership to exactly the desired bounded set."
  def sync_rooms(instance, session_id, rooms, opts \\ []),
    do: Wiregrid.Runtime.sync_rooms(instance, session_id, rooms, opts)

  def resume_room(instance, room, old_session_id, new_session_id),
    do: Wiregrid.Runtime.resume_room(instance, room, old_session_id, new_session_id)

  def room_members(instance, room, limit \\ 10_000) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth) do
      Wiregrid.Rooms.members(instance, room, limit)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def room_metadata(instance, room) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth) do
      Wiregrid.Rooms.metadata(instance, room)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def set_room_metadata(instance, room, session_id, metadata, opts \\ []),
    do: Wiregrid.Runtime.set_room_metadata(instance, room, session_id, metadata, opts)

  def set_room_ttl(instance, room, session_id, ttl_ms),
    do: Wiregrid.Runtime.set_room_ttl(instance, room, session_id, ttl_ms)

  def activity(instance, session_id, topic, kind, value, opts \\ []),
    do: Wiregrid.Activity.put(instance, session_id, topic, kind, value, opts)

  def activities(instance, topic, kind, limit \\ 100) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- activity_kind(kind) do
      Wiregrid.Activity.list(instance, topic, kind, limit)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def typing(instance, session_id, topic, opts \\ []) do
    if is_list(opts) do
      Wiregrid.Activity.put(
        instance,
        session_id,
        topic,
        :typing,
        true,
        Keyword.put_new(opts, :broadcast, true)
      )
    else
      {:error, :invalid_options}
    end
  end

  def receipt(instance, session_id, receipt, opts \\ []),
    do: Wiregrid.Receipts.put(instance, session_id, receipt, opts)

  def get_receipt(instance, session_id, receipt_id) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.binary_id(receipt_id, cfg.max_storage_id_bytes) do
      Wiregrid.Receipts.get(instance, session_id, receipt_id)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def signal(instance, room, session_id, kind, payload, opts \\ []),
    do: Wiregrid.Signaling.send(instance, room, session_id, kind, payload, opts)

  @doc "Checks a bounded local rate-limit bucket using the fixed-window policy."
  def rate_limit(instance, bucket, key, limit, window_ms),
    do: Wiregrid.RateLimiter.check(instance, bucket, key, limit, window_ms)

  @doc """
  Checks a bounded local rate-limit bucket with an explicit policy.

  `:policy` may be `:fixed_window` (default) or `:token_bucket`. Token buckets
  also accept `:burst` and `:idle_ttl_ms`; refill math is integer-only and state
  remains subject to the instance's `max_rate_limit_buckets` admission budget.
  """
  def rate_limit(instance, bucket, key, limit, window_ms, opts),
    do: Wiregrid.RateLimiter.check(instance, bucket, key, limit, window_ms, opts)

  def webhook(instance, url, body, opts \\ []),
    do: Wiregrid.Webhook.enqueue(instance, url, body, opts)

  @doc "Replays a bounded durable storage page to one live session through normal backpressure."
  def replay_session(instance, session_id, stream, opts \\ []),
    do: Wiregrid.Replay.to_session(instance, session_id, stream, opts)

  @doc "Bootstraps the configured durable storage adapter."
  def storage_bootstrap(instance), do: Wiregrid.Storage.bootstrap(instance)

  @doc "Checks the configured storage adapter without exposing credentials."
  def storage_health(instance), do: Wiregrid.Storage.health(instance)

  @doc "Reads a value from the configured bounded cache."
  def cache_get(instance, key), do: Wiregrid.Cache.get(instance, key)

  @doc "Writes a bounded cache value with an optional TTL."
  def cache_put(instance, key, value, ttl \\ :infinity),
    do: Wiregrid.Cache.put(instance, key, value, ttl)

  @doc "Deletes a cache key."
  def cache_delete(instance, key), do: Wiregrid.Cache.delete(instance, key)

  @doc "Atomically increments a cache counter with an optional TTL."
  def cache_incr(instance, key, delta \\ 1, ttl \\ :infinity),
    do: Wiregrid.Cache.incr(instance, key, delta, ttl)

  @doc "Checks the configured cache adapter without exposing credentials."
  def cache_health(instance), do: Wiregrid.Cache.health(instance)

  @doc "Appends an application event to a generic durable stream without fanout."
  def append_event(instance, stream, id, event, meta \\ %{}),
    do: Wiregrid.Storage.append(instance, stream, id, event, meta)

  @doc "Gets one application event from the configured durable stream adapter."
  def get_event(instance, stream, id), do: Wiregrid.Storage.get(instance, stream, id)

  @doc "Pages a durable application stream using Wiregrid's stable composite cursor."
  def page_events(instance, stream, cursor \\ nil, limit \\ 100),
    do: Wiregrid.Storage.page(instance, stream, cursor, limit)

  @doc """
  Pages a durable stream for one live session after a `:read` authorization check.

  In-process code that already made its own permission decision can keep using
  `page_events/4`. Browser and foreign clients use this function so a connected
  session cannot read an arbitrary stream just because it has a socket.
  """
  def read_history(instance, session_id, stream, cursor \\ nil, limit \\ 50) do
    with %{config: cfg, tables: tables} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.topic(stream, cfg.max_topic_bytes, cfg.max_topic_depth),
         true <- is_integer(limit) and limit in 1..100,
         [{^session_id, session}] <- :ets.lookup(tables.sessions, session_id),
         :ok <- Wiregrid.Authorizer.check(instance, cfg, :read, session, stream, %{limit: limit}) do
      Wiregrid.Storage.page(instance, stream, cursor, limit)
    else
      [] -> {:error, :unknown_session}
      false -> {:error, :invalid_limit}
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Deletes one durable application event where the configured adapter supports deletion."
  def delete_event(instance, stream, id), do: Wiregrid.Storage.delete(instance, stream, id)

  @doc "Prunes a bounded number of durable events older than `before_ms`."
  def prune_events(instance, stream, before_ms, limit \\ 1_000),
    do: Wiregrid.Storage.prune(instance, stream, before_ms, limit)

  def session(instance, session_id), do: Wiregrid.Query.session(instance, session_id)

  def user_sessions(instance, user_id, limit \\ nil),
    do: Wiregrid.Query.user_sessions(instance, user_id, limit)

  def subscriptions(instance, session_id, limit \\ nil),
    do: Wiregrid.Query.subscriptions(instance, session_id, limit)

  def topic_sessions(instance, topic, limit \\ nil),
    do: Wiregrid.Query.topic_sessions(instance, topic, limit)

  def session_rooms(instance, session_id, limit \\ nil),
    do: Wiregrid.Query.rooms(instance, session_id, limit)

  def presence_watches(instance, session_id, limit \\ nil),
    do: Wiregrid.Query.presence_watches(instance, session_id, limit)

  def session_state(instance, session_id, limit \\ nil),
    do: Wiregrid.Query.session_state(instance, session_id, limit)

  def topic_info(instance, topic, limit \\ nil),
    do: Wiregrid.Query.topic_info(instance, topic, limit)

  def room_info(instance, room, limit \\ nil), do: Wiregrid.Query.room_info(instance, room, limit)

  def user_info(instance, user_id, limit \\ nil),
    do: Wiregrid.Query.user_info(instance, user_id, limit)

  def limits(instance), do: Wiregrid.Query.limits(instance)

  def topic_subscriber_count(instance, topic),
    do: Wiregrid.Query.topic_subscriber_count(instance, topic)

  def room_member_count(instance, room), do: Wiregrid.Query.room_member_count(instance, room)

  def presence_watcher_count(instance, user_id),
    do: Wiregrid.Query.presence_watcher_count(instance, user_id)

  def user_session_count(instance, user_id),
    do: Wiregrid.Query.user_session_count(instance, user_id)

  def room_member?(instance, room, session_id),
    do: Wiregrid.Query.room_member?(instance, room, session_id)

  def subscribed?(instance, session_id, topic),
    do: Wiregrid.Query.subscribed?(instance, session_id, topic)

  def decode_payload(instance, payload) when is_binary(payload) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg} -> Wiregrid.Codec.decode(cfg, payload)
      _ -> {:error, :instance_unavailable}
    end
  end

  def decode_payload(_instance, _payload), do: {:error, :invalid_payload}

  def health(instance), do: Wiregrid.Health.health(instance)
  def readiness(instance), do: Wiregrid.Health.readiness(instance)
  def readiness_report(instance), do: Wiregrid.Health.readiness_report(instance)
  def ready?(instance), do: Wiregrid.Health.ready?(instance)
  def liveness(instance), do: Wiregrid.Health.liveness(instance)
  def stats(instance), do: Wiregrid.Health.stats(instance)
  def pressure(instance), do: Wiregrid.Health.pressure(instance)

  @doc "Returns fixed-cardinality aggregate metrics in Prometheus text format."
  def prometheus_metrics(instance), do: Wiregrid.Observability.prometheus(instance)

  def drain(instance), do: Wiregrid.Runtime.drain(instance)
  def undrain(instance), do: Wiregrid.Runtime.undrain(instance)

  def await_idle(instance, timeout_ms \\ 10_000)

  def await_idle(instance, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_idle_loop(instance, deadline)
  end

  def await_idle(_instance, _timeout), do: {:error, :invalid_timeout}

  def graceful_shutdown(instance, timeout_ms \\ 10_000) do
    with :ok <- drain(instance),
         :ok <- await_idle(instance, timeout_ms) do
      stop_instance(instance)
    end
  end

  defp await_idle_loop(instance, deadline) do
    cond do
      Wiregrid.Health.idle?(instance) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(10)
        await_idle_loop(instance, deadline)
    end
  end

  defp normalize_publish_opts(opts, cfg) do
    with {:ok, class} <- event_class(Keyword.get(opts, :class, :durable)),
         {:ok, event_id} <- event_id(Keyword.get(opts, :event_id), cfg),
         {:ok, persist} <-
           boolean_opt(Keyword.get(opts, :persist, false), :invalid_persist_option),
         {:ok, cluster} <- boolean_opt(Keyword.get(opts, :cluster, true), :invalid_cluster_option),
         {:ok, meta} <- metadata_opt(Keyword.get(opts, :meta, %{}), cfg),
         {:ok, exclude_sessions} <- bounded_list(Keyword.get(opts, :exclude_sessions, []), 256),
         {:ok, exclude_users} <- bounded_list(Keyword.get(opts, :exclude_users, []), 256) do
      {:ok,
       %{
         class: class,
         event_id: event_id,
         persist: persist,
         cluster: cluster and cfg.cluster,
         meta: meta,
         session_id: Keyword.get(opts, :session_id),
         exclude_sessions: exclude_sessions,
         exclude_users: exclude_users
       }}
    end
  end

  defp authorize_actor(_instance, _cfg, _t, _action, _resource, %{session_id: nil}), do: :ok

  defp authorize_actor(instance, cfg, t, action, resource, normalized) do
    sid = normalized.session_id

    with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         [{^sid, session}] <- :ets.lookup(t.sessions, sid) do
      Wiregrid.Authorizer.check(
        instance,
        cfg,
        action,
        session,
        resource,
        Map.drop(normalized, [:session_id])
      )
    else
      [] -> {:error, :unknown_session}
      {:error, _} = error -> error
    end
  end

  defp authorize_direct(_instance, _cfg, _t, _action, _resource, opts) when opts == [], do: :ok

  defp authorize_direct(instance, cfg, t, action, resource, opts) do
    case Keyword.get(opts, :session_id) do
      nil ->
        :ok

      sid ->
        with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
             [{^sid, session}] <- :ets.lookup(t.sessions, sid) do
          Wiregrid.Authorizer.check(instance, cfg, action, session, resource, %{})
        else
          [] -> {:error, :unknown_session}
          {:error, _} = error -> error
        end
    end
  end

  defp maybe_persist(_instance, _stream, _id, _event, _meta, false), do: :ok

  defp maybe_persist(instance, stream, id, event, meta, true) do
    case Wiregrid.Storage.append(instance, stream, id, event, meta) do
      :ok -> :ok
      {:error, reason} -> {:error, {:persistence_failed, reason}}
    end
  end

  defp event_class(class) when class in [:durable, :ephemeral], do: {:ok, class}
  defp event_class(_), do: {:error, :invalid_event_class}

  defp event_id(nil, _cfg), do: {:ok, Wiregrid.ID.generate()}

  defp event_id(value, cfg) do
    case Wiregrid.Validation.binary_id(value, cfg.max_storage_id_bytes) do
      :ok -> {:ok, value}
      error -> error
    end
  end

  defp boolean_opt(value, _error) when is_boolean(value), do: {:ok, value}
  defp boolean_opt(_value, error), do: {:error, error}

  defp metadata_opt(value, cfg) when is_map(value) do
    case Wiregrid.Validation.metadata(value, cfg.max_metadata_bytes) do
      :ok -> {:ok, value}
      error -> error
    end
  end

  defp metadata_opt(_, _cfg), do: {:error, :invalid_metadata}

  defp bounded_list(value, limit) when is_list(value) do
    case Wiregrid.Validation.bounded_list(value, limit) do
      :ok -> {:ok, value}
      {:error, :list_too_large} -> {:error, :too_many_exclusions}
      _ -> {:error, :invalid_exclusions}
    end
  end

  defp bounded_list(%MapSet{} = value, limit) do
    if MapSet.size(value) <= limit,
      do: {:ok, MapSet.to_list(value)},
      else: {:error, :too_many_exclusions}
  end

  defp bounded_list(_, _limit), do: {:error, :invalid_exclusions}

  defp fanout_opts(normalized),
    do: [exclude_sessions: normalized.exclude_sessions, exclude_users: normalized.exclude_users]

  defp direct_fanout(instance, session_ids, topic, payload, event, class) do
    Enum.reduce(session_ids, %{sent: 0, dropped: 0, evicted: 0, gone: 0, overloaded: 0}, fn sid,
                                                                                            acc ->
      case Wiregrid.Delivery.send_session(instance, sid, topic, payload, event, class) do
        :sent -> Map.update!(acc, :sent, &(&1 + 1))
        :dropped -> Map.update!(acc, :dropped, &(&1 + 1))
        :evicted -> Map.update!(acc, :evicted, &(&1 + 1))
        :overloaded -> Map.update!(acc, :overloaded, &(&1 + 1))
        _ -> Map.update!(acc, :gone, &(&1 + 1))
      end
    end)
  end

  defp normalize_batch_publish_opts(opts, cfg) do
    with {:ok, class} <- event_class(Keyword.get(opts, :class, :durable)),
         {:ok, persist} <-
           boolean_opt(Keyword.get(opts, :persist, false), :invalid_persist_option),
         {:ok, cluster} <- boolean_opt(Keyword.get(opts, :cluster, true), :invalid_cluster_option),
         {:ok, meta} <- metadata_opt(Keyword.get(opts, :meta, %{}), cfg),
         {:ok, exclude_sessions} <- bounded_list(Keyword.get(opts, :exclude_sessions, []), 256),
         {:ok, exclude_users} <- bounded_list(Keyword.get(opts, :exclude_users, []), 256) do
      {:ok,
       %{
         class: class,
         persist: persist,
         cluster: cluster and cfg.cluster,
         meta: meta,
         session_id: Keyword.get(opts, :session_id),
         exclude_sessions: exclude_sessions,
         exclude_users: exclude_users
       }}
    end
  end

  defp publish_batch_event(instance, cfg, topic, event, normalized) do
    event_id = Wiregrid.ID.generate()

    with {:ok, payload} <- Wiregrid.Codec.encode(cfg, event),
         :ok <-
           maybe_persist(instance, topic, event_id, event, normalized.meta, normalized.persist),
         {:ok, counts} <-
           Wiregrid.Fanout.topic(
             instance,
             topic,
             payload,
             event,
             normalized.class,
             fanout_opts(normalized)
           ) do
      cluster =
        cluster_status(normalized.cluster, fn ->
          Wiregrid.Cluster.topic(
            instance,
            topic,
            event_id,
            payload,
            normalized.class,
            fanout_opts(normalized)
          )
        end)

      {:ok, counts |> Map.put(:event_id, event_id) |> Map.put(:cluster, cluster)}
    end
  end

  defp publish_encoded_topic(instance, topic, event, payload, normalized) do
    with :ok <-
           maybe_persist(
             instance,
             topic,
             normalized.event_id,
             event,
             normalized.meta,
             normalized.persist
           ),
         {:ok, counts} <-
           Wiregrid.Fanout.topic(
             instance,
             topic,
             payload,
             event,
             normalized.class,
             fanout_opts(normalized)
           ) do
      cluster =
        cluster_status(normalized.cluster, fn ->
          Wiregrid.Cluster.topic(
            instance,
            topic,
            normalized.event_id,
            payload,
            normalized.class,
            fanout_opts(normalized)
          )
        end)

      {:ok, counts |> Map.put(:event_id, normalized.event_id) |> Map.put(:cluster, cluster)}
    end
  end

  defp publish_rooms_encoded(instance, rooms, event, payload, normalized) do
    results =
      Enum.map(rooms, fn room ->
        case publish_encoded_room(instance, room, event, payload, normalized) do
          {:ok, result} -> {:ok, Map.put(result, :room, room)}
          {:error, reason} -> {:error, %{room: room, reason: reason}}
        end
      end)

    completed = Enum.count(results, &match?({:ok, _}, &1))

    {:ok,
     %{
       event_id: normalized.event_id,
       completed: completed,
       failed: length(results) - completed,
       results: results
     }}
  end

  defp publish_encoded_room(instance, room, event, payload, normalized) do
    with :ok <-
           maybe_persist(
             instance,
             room,
             normalized.event_id,
             event,
             normalized.meta,
             normalized.persist
           ),
         {:ok, counts} <-
           Wiregrid.Fanout.room(
             instance,
             room,
             payload,
             event,
             normalized.class,
             fanout_opts(normalized)
           ) do
      cluster =
        cluster_status(normalized.cluster, fn ->
          Wiregrid.Cluster.room_event(
            instance,
            room,
            normalized.event_id,
            payload,
            normalized.class,
            fanout_opts(normalized)
          )
        end)

      {:ok, counts |> Map.put(:event_id, normalized.event_id) |> Map.put(:cluster, cluster)}
    end
  end

  defp authorize_rooms(instance, cfg, t, rooms, normalized) do
    Enum.reduce_while(rooms, :ok, fn room, :ok ->
      case authorize_actor(instance, cfg, t, :publish_room, room, normalized) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_events(events, cfg) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Wiregrid.Validation.event(event, cfg.max_event_bytes) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_topics(topics, cfg) do
    Enum.reduce_while(topics, {:ok, {MapSet.new(), []}}, fn topic, {:ok, {seen, acc}} ->
      case Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth) do
        :ok ->
          if MapSet.member?(seen, topic) do
            {:cont, {:ok, {seen, acc}}}
          else
            {:cont, {:ok, {MapSet.put(seen, topic), [topic | acc]}}}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, {_seen, []}} -> {:error, :empty_topics}
      {:ok, {_seen, acc}} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp authorize_topics(instance, cfg, t, topics, normalized) do
    Enum.reduce_while(topics, :ok, fn topic, :ok ->
      case authorize_actor(instance, cfg, t, :publish, topic, normalized) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp cluster_status(false, _fun), do: :disabled

  defp cluster_status(true, fun) do
    case fun.() do
      :ok -> :queued
      {:error, reason} -> {:error, reason}
    end
  end

  defp cluster_user_batch(_instance, _users, _event_id, _payload, _class, false), do: :disabled

  defp cluster_user_batch(instance, users, event_id, payload, class, true) do
    {queued, failed} =
      Enum.reduce(users, {0, []}, fn user_id, {queued, failed} ->
        case Wiregrid.Cluster.user_event(instance, user_id, event_id, payload, class) do
          :ok -> {queued + 1, failed}
          {:error, reason} -> {queued, [%{user_id: user_id, reason: reason} | failed]}
        end
      end)

    %{queued: queued, failed: Enum.reverse(failed)}
  end

  defp normalize_session_targets(session_ids, cfg) do
    with :ok <- Wiregrid.Validation.bounded_list(session_ids, cfg.max_batch_targets) do
      Enum.reduce_while(session_ids, {:ok, MapSet.new()}, fn sid, {:ok, acc} ->
        case Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes) do
          :ok -> {:cont, {:ok, MapSet.put(acc, sid)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> nonempty_set(:empty_targets)
    end
  end

  defp normalize_user_targets(user_ids, cfg) do
    with :ok <- Wiregrid.Validation.bounded_list(user_ids, cfg.max_batch_items) do
      Enum.reduce_while(user_ids, {:ok, MapSet.new()}, fn user_id, {:ok, acc} ->
        case Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes) do
          {:ok, _} -> {:cont, {:ok, MapSet.put(acc, user_id)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> nonempty_set(:empty_targets)
    end
  end

  defp normalize_delivery_ids(ids, cfg) do
    Enum.reduce_while(ids, {:ok, MapSet.new()}, fn id, {:ok, acc} ->
      case Wiregrid.Validation.binary_id(id, cfg.max_storage_id_bytes) do
        :ok -> {:cont, {:ok, MapSet.put(acc, id)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, set} -> {:ok, MapSet.to_list(set)}
      error -> error
    end
  end

  defp nonempty_set({:ok, set}, error) do
    if MapSet.size(set) == 0, do: {:error, error}, else: {:ok, MapSet.to_list(set)}
  end

  defp nonempty_set(error, _), do: error

  defp sessions_for_users(t, users, limit) do
    Enum.reduce_while(users, {:ok, MapSet.new()}, fn user_id, {:ok, acc} ->
      next =
        Enum.reduce(:ets.lookup(t.user_sessions, user_id), acc, fn {^user_id, sid}, set ->
          MapSet.put(set, sid)
        end)

      if MapSet.size(next) <= limit,
        do: {:cont, {:ok, next}},
        else: {:halt, {:error, :too_many_targets}}
    end)
    |> case do
      {:ok, set} -> {:ok, MapSet.to_list(set)}
      error -> error
    end
  end

  defp ensure_accepting(instance), do: Wiregrid.Runtime.accepting(instance)

  defp activity_kind(kind) when is_atom(kind), do: :ok
  defp activity_kind(kind) when is_binary(kind) and byte_size(kind) in 1..64, do: :ok
  defp activity_kind(_), do: {:error, :invalid_activity_kind}
end
