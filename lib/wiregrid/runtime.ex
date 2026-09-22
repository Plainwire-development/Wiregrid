defmodule Wiregrid.Runtime do
  @moduledoc false
  use GenServer

  @session_option_keys [:metadata, :status, :presence_metadata, :ack_mode, :delivery_format]
  @room_option_keys [:metadata]
  @topology_keys [:subscriptions, :presence_watches, :rooms]
  @topology_option_keys [:subscription_context, :presence_context, :room_opts]

  def start_link({instance, config}) do
    GenServer.start_link(__MODULE__, {instance, config}, name: via(instance))
  end

  def via(instance), do: {:via, Registry, {Wiregrid.ProcessRegistry, {:runtime, instance}}}

  def connect(instance, user_id, pid, opts \\ []),
    do: call(instance, {:connect, user_id, pid, opts, false})

  def connect_resumable(instance, user_id, pid, opts \\ []),
    do: call(instance, {:connect, user_id, pid, opts, true})

  def resume_session(instance, user_id, pid, token, opts \\ []),
    do: call(instance, {:resume, user_id, pid, token, opts})

  def disconnect(instance, session_id, reason \\ :normal),
    do: call(instance, {:disconnect, session_id, reason})

  def disconnect_user(instance, user_id, reason \\ :normal),
    do: call(instance, {:disconnect_user, user_id, reason})

  def set_session_metadata(instance, session_id, metadata),
    do: call(instance, {:session_metadata, session_id, metadata})

  def subscribe(instance, session_id, topic, context \\ %{}),
    do: call(instance, {:subscribe, session_id, topic, context})

  def subscribe_many(instance, session_id, topics, context \\ %{}),
    do: call(instance, {:subscribe_many, session_id, topics, context})

  def unsubscribe(instance, session_id, topic),
    do: call(instance, {:unsubscribe, session_id, topic})

  def unsubscribe_many(instance, session_id, topics),
    do: call(instance, {:unsubscribe_many, session_id, topics})

  def sync_subscriptions(instance, session_id, topics, context \\ %{}),
    do: call(instance, {:sync_subscriptions, session_id, topics, context})

  def watch_presence(instance, session_id, user_id, context \\ %{}),
    do: call(instance, {:watch_presence, session_id, user_id, context})

  def watch_presence_many(instance, session_id, user_ids, context \\ %{}),
    do: call(instance, {:watch_presence_many, session_id, user_ids, context})

  def unwatch_presence(instance, session_id, user_id),
    do: call(instance, {:unwatch_presence, session_id, user_id})

  def unwatch_presence_many(instance, session_id, user_ids),
    do: call(instance, {:unwatch_presence_many, session_id, user_ids})

  def sync_presence_watches(instance, session_id, user_ids, context \\ %{}),
    do: call(instance, {:sync_presence_watches, session_id, user_ids, context})

  def join_room(instance, room, session_id, opts \\ []),
    do: call(instance, {:join_room, room, session_id, opts})

  def join_rooms(instance, rooms, session_id, opts \\ []),
    do: call(instance, {:join_rooms, rooms, session_id, opts})

  def leave_room(instance, room, session_id), do: call(instance, {:leave_room, room, session_id})

  def leave_rooms(instance, rooms, session_id),
    do: call(instance, {:leave_rooms, rooms, session_id})

  def sync_rooms(instance, session_id, rooms, opts \\ []),
    do: call(instance, {:sync_rooms, session_id, rooms, opts})

  def sync_topology(instance, session_id, topology, opts \\ []),
    do: call(instance, {:sync_topology, session_id, topology, opts})

  def resume_room(instance, room, old_session_id, new_session_id),
    do: call(instance, {:resume_room, room, old_session_id, new_session_id})

  def set_room_metadata(instance, room, session_id, metadata, opts \\ []),
    do: call(instance, {:room_metadata, room, session_id, metadata, opts})

  def set_room_ttl(instance, room, session_id, ttl_ms),
    do: call(instance, {:room_ttl, room, session_id, ttl_ms})

  def set_presence(instance, session_id, status, metadata \\ %{}),
    do: call(instance, {:presence, session_id, status, metadata})

  def drain(instance), do: call(instance, :drain)
  def undrain(instance), do: call(instance, :undrain)
  def draining?(instance), do: flag(instance, :draining, true)

  def accepting(instance) do
    case Wiregrid.Tables.get(instance) do
      %{tables: %{runtime_flags: flags}} ->
        draining = match?([{:draining, true}], :ets.lookup(flags, :draining))

        runtime_pid =
          case :ets.lookup(flags, :control_ready) do
            [{:control_ready, pid}] when is_pid(pid) -> pid
            _ -> nil
          end

        cond do
          draining -> {:error, :draining}
          not is_pid(runtime_pid) -> {:error, :reindexing}
          not Process.alive?(runtime_pid) -> {:error, :reindexing}
          true -> :ok
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def expire_resume(instance, key), do: cast(instance, {:expire_resume, key})
  def expire_room_grace(instance, key), do: cast(instance, {:expire_room_grace, key})
  def expire_room(instance, room), do: cast(instance, {:expire_room, room, :force})
  def expire_room_at(instance, room, deadline), do: cast(instance, {:expire_room, room, deadline})

  @impl true
  def init({instance, config}) do
    _ = set_flag(instance, :control_ready, false)
    generation = next_control_generation(instance)
    state = %{instance: instance, config: config, monitors: %{}, control_generation: generation}

    case Wiregrid.Recovery.reconcile(instance) do
      {:ok, _cfg} ->
        rebuilt = rebuild_monitors(state)
        _ = set_flag(instance, :control_ready, self())
        {:ok, rebuilt}

      {:error, reason} ->
        {:stop, {:recovery_failed, reason}}
    end
  end

  @impl true
  def handle_call({:wiregrid_admitted_call, generation, message}, from, state) do
    release_control_slot(state.instance, generation)
    handle_call(message, from, state)
  end

  @impl true
  def handle_call({:connect, user_id, pid, opts, resumable}, _from, state) do
    if state_draining(state) do
      {:reply, {:error, :draining}, state}
    else
      case create_session(state, user_id, pid, opts, resumable) do
        {:ok, session, resume_token, state2} ->
          result = if resumable, do: {:ok, session.id, resume_token}, else: {:ok, session.id}
          {:reply, result, state2}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:resume, user_id, pid, token, opts}, _from, state) do
    if state_draining(state) do
      {:reply, {:error, :draining}, state}
    else
      case do_resume(state, user_id, pid, token, opts) do
        {:ok, reply, state2} -> {:reply, {:ok, reply}, state2}
        {:error, _} = error -> {:reply, error, state}
      end
    end
  end

  def handle_call({:disconnect, session_id, reason}, _from, state) do
    with :ok <- Wiregrid.Validation.session_id(session_id, state.config.max_session_id_bytes),
         :ok <- Wiregrid.Validation.disconnect_reason(reason) do
      {reply, state2} = cleanup_session(state, session_id, reason, true)
      {:reply, reply, state2}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:disconnect_user, user_id, reason}, _from, state) do
    reply =
      with {:ok, _} <- Wiregrid.Validation.id(user_id, state.config.max_user_id_bytes),
           :ok <- Wiregrid.Validation.disconnect_reason(reason),
           %{tables: t} <- Wiregrid.Tables.get(state.instance) do
        sessions = :ets.lookup(t.user_sessions, user_id)

        {count, state2} =
          Enum.reduce(sessions, {0, state}, fn {^user_id, sid}, {count, acc} ->
            case cleanup_session(acc, sid, reason, true) do
              {:ok, next} -> {count + 1, next}
              {{:error, :unknown_session}, next} -> {count, next}
              {_other, next} -> {count, next}
            end
          end)

        {:ok, %{disconnected: count}, state2}
      else
        :undefined -> {:error, :instance_unavailable}
        {:error, _} = error -> error
      end

    case reply do
      {:ok, result, state2} -> {:reply, {:ok, result}, state2}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:session_metadata, sid, metadata}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: do_session_metadata(state, sid, metadata)

    {:reply, reply, state}
  end

  def handle_call({:subscribe, sid, topic, context}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: Wiregrid.EdgeOps.subscribe(state.instance, state.config, sid, topic, context)

    {:reply, reply, state}
  end

  def handle_call({:subscribe_many, sid, topics, context}, _from, state) do
    reply =
      if state_draining(state) do
        {:error, :draining}
      else
        with :ok <-
               batch_size(
                 topics,
                 min(state.config.max_batch_items, state.config.max_subscriptions_per_session)
               ) do
          do_batch(
            topics,
            &Wiregrid.EdgeOps.subscribe(state.instance, state.config, sid, &1, context)
          )
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:unsubscribe, sid, topic}, _from, state) do
    {:reply, Wiregrid.EdgeOps.unsubscribe(state.instance, state.config, sid, topic), state}
  end

  def handle_call({:unsubscribe_many, sid, topics}, _from, state) do
    reply =
      with :ok <-
             batch_size(
               topics,
               min(state.config.max_batch_items, state.config.max_subscriptions_per_session)
             ),
           do:
             do_batch(
               topics,
               &Wiregrid.EdgeOps.unsubscribe(state.instance, state.config, sid, &1)
             )

    {:reply, reply, state}
  end

  def handle_call({:sync_subscriptions, sid, topics, context}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: sync_subscriptions_result(state, sid, topics, context)

    {:reply, reply, state}
  end

  def handle_call({:watch_presence, sid, user_id, context}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: Wiregrid.EdgeOps.watch_presence(state.instance, state.config, sid, user_id, context)

    {:reply, reply, state}
  end

  def handle_call({:watch_presence_many, sid, user_ids, context}, _from, state) do
    reply =
      if state_draining(state) do
        {:error, :draining}
      else
        with :ok <-
               batch_size(
                 user_ids,
                 min(state.config.max_batch_items, state.config.max_presence_watches_per_session)
               ) do
          do_batch(
            user_ids,
            &Wiregrid.EdgeOps.watch_presence(state.instance, state.config, sid, &1, context)
          )
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:unwatch_presence, sid, user_id}, _from, state) do
    {:reply, Wiregrid.EdgeOps.unwatch_presence(state.instance, state.config, sid, user_id), state}
  end

  def handle_call({:unwatch_presence_many, sid, user_ids}, _from, state) do
    reply =
      with :ok <-
             batch_size(
               user_ids,
               min(state.config.max_batch_items, state.config.max_presence_watches_per_session)
             ),
           do:
             do_batch(
               user_ids,
               &Wiregrid.EdgeOps.unwatch_presence(state.instance, state.config, sid, &1)
             )

    {:reply, reply, state}
  end

  def handle_call({:sync_presence_watches, sid, user_ids, context}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: sync_presence_watches_result(state, sid, user_ids, context)

    {:reply, reply, state}
  end

  def handle_call({:join_room, room, sid, opts}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: do_join_room(state, room, sid, opts)

    {:reply, reply, state}
  end

  def handle_call({:join_rooms, rooms, sid, opts}, _from, state) do
    reply =
      if state_draining(state) do
        {:error, :draining}
      else
        with :ok <-
               batch_size(
                 rooms,
                 min(state.config.max_batch_items, state.config.max_rooms_per_session)
               ) do
          do_batch(rooms, &do_join_room(state, &1, sid, opts))
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:leave_room, room, sid}, _from, state) do
    {:reply, do_leave_room(state, room, sid, true), state}
  end

  def handle_call({:leave_rooms, rooms, sid}, _from, state) do
    reply =
      with :ok <-
             batch_size(
               rooms,
               min(state.config.max_batch_items, state.config.max_rooms_per_session)
             ),
           do: do_batch(rooms, &do_leave_room(state, &1, sid, true))

    {:reply, reply, state}
  end

  def handle_call({:sync_rooms, sid, rooms, opts}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: sync_rooms_result(state, sid, rooms, opts)

    {:reply, reply, state}
  end

  def handle_call({:sync_topology, sid, topology, opts}, _from, state) do
    reply =
      cond do
        state_draining(state) -> {:error, :draining}
        true -> sync_topology_result(state, sid, topology, opts)
      end

    {:reply, reply, state}
  end

  def handle_call({:resume_room, room, old_sid, new_sid}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: do_resume_room(state, room, old_sid, new_sid)

    {:reply, reply, state}
  end

  def handle_call({:room_metadata, room, sid, metadata, opts}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: do_room_metadata(state, room, sid, metadata, opts)

    {:reply, reply, state}
  end

  def handle_call({:room_ttl, room, sid, ttl_ms}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: do_room_ttl(state, room, sid, ttl_ms)

    {:reply, reply, state}
  end

  def handle_call({:presence, sid, status, metadata}, _from, state) do
    reply =
      if state_draining(state),
        do: {:error, :draining},
        else: do_presence(state, sid, status, metadata)

    {:reply, reply, state}
  end

  def handle_call(:drain, _from, state) do
    set_flag(state.instance, :draining, true)
    Wiregrid.Telemetry.emit([:instance, :drain], %{value: 1}, %{instance: state.instance})
    {:reply, :ok, state}
  end

  def handle_call(:undrain, _from, state) do
    set_flag(state.instance, :draining, false)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:wiregrid_admitted_cast, generation, message}, state) do
    release_control_slot(state.instance, generation)
    handle_cast(message, state)
  end

  def handle_cast({:expire_resume, hash}, state) do
    release_resume_snapshot(state.instance, hash)
    {:noreply, state}
  end

  def handle_cast({:expire_room_grace, key}, state) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} -> release_room_grace(t, key)
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:expire_room, room, :force}, state) do
    expire_room_now(state, room)
    {:noreply, state}
  end

  def handle_cast({:expire_room, room, deadline}, state) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} ->
        case :ets.lookup(t.room_state, room) do
          [{^room, %{expires_at_ms: ^deadline}}] ->
            expire_room_now(state, room)

          [{^room, %{expires_at_ms: current_deadline}}]
          when is_integer(current_deadline) ->
            if current_deadline <= System.monotonic_time(:millisecond) do
              expire_room_now(state, room)
            else
              _ = Wiregrid.Expiry.schedule_at(state.instance, :room, room, current_deadline)
              :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {session_id, monitors} ->
        {_reply, state2} =
          cleanup_session(%{state | monitors: monitors}, session_id, {:down, reason}, false)

        {:noreply, state2}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp sync_subscriptions_result(state, sid, topics, context) do
    with :ok <- Wiregrid.Validation.metadata(context, state.config.max_metadata_bytes) do
      Wiregrid.SyncOps.reconcile(
        state.instance,
        state.config,
        sid,
        topics,
        state.config.max_subscriptions_per_session,
        &Wiregrid.Validation.topic(
          &1,
          state.config.max_topic_bytes,
          state.config.max_topic_depth
        ),
        fn topic ->
          Wiregrid.EdgeOps.subscribe(state.instance, state.config, sid, topic, context)
        end,
        fn topic -> Wiregrid.EdgeOps.unsubscribe(state.instance, state.config, sid, topic) end,
        fn t -> for {^sid, topic} <- :ets.lookup(t.session_topics, sid), do: topic end
      )
    end
  end

  defp sync_presence_watches_result(state, sid, user_ids, context) do
    with :ok <- Wiregrid.Validation.metadata(context, state.config.max_metadata_bytes) do
      Wiregrid.SyncOps.reconcile(
        state.instance,
        state.config,
        sid,
        user_ids,
        state.config.max_presence_watches_per_session,
        fn user_id ->
          case Wiregrid.Validation.id(user_id, state.config.max_user_id_bytes) do
            {:ok, _} -> :ok
            {:error, _} = error -> error
          end
        end,
        fn user_id ->
          Wiregrid.EdgeOps.watch_presence(state.instance, state.config, sid, user_id, context)
        end,
        fn user_id ->
          Wiregrid.EdgeOps.unwatch_presence(state.instance, state.config, sid, user_id)
        end,
        fn t -> for {^sid, user_id} <- :ets.lookup(t.session_watches, sid), do: user_id end
      )
    end
  end

  defp sync_rooms_result(state, sid, rooms, opts) do
    with :ok <- Wiregrid.Validation.keyword_opts(opts, @room_option_keys) do
      Wiregrid.SyncOps.reconcile(
        state.instance,
        state.config,
        sid,
        rooms,
        state.config.max_rooms_per_session,
        &Wiregrid.Validation.topic(
          &1,
          state.config.max_topic_bytes,
          state.config.max_topic_depth
        ),
        fn room -> do_join_room(state, room, sid, opts) end,
        fn room -> do_leave_room(state, room, sid, true) end,
        fn t -> for {^sid, room} <- :ets.lookup(t.session_rooms, sid), do: room end
      )
    end
  end

  # Reconcile multiple lifecycle domains under one Runtime mailbox turn. Domains
  # are deliberately reported independently rather than pretending the three
  # edge sets form one distributed transaction. Each domain still preserves
  # SyncOps' add-before-remove/rollback behavior, and no other lifecycle call
  # can interleave while the snapshot is being applied.
  defp sync_topology_result(state, sid, topology, opts) when is_map(topology) do
    with :ok <- Wiregrid.Validation.session_id(sid, state.config.max_session_id_bytes),
         true <- map_size(topology) > 0,
         true <- Enum.all?(Map.keys(topology), &(&1 in @topology_keys)),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @topology_option_keys),
         subscription_context <- Keyword.get(opts, :subscription_context, %{}),
         presence_context <- Keyword.get(opts, :presence_context, %{}),
         room_opts <- Keyword.get(opts, :room_opts, []),
         :ok <-
           Wiregrid.Validation.metadata(subscription_context, state.config.max_metadata_bytes),
         :ok <- Wiregrid.Validation.metadata(presence_context, state.config.max_metadata_bytes),
         :ok <- Wiregrid.Validation.keyword_opts(room_opts, @room_option_keys) do
      domains =
        @topology_keys
        |> Enum.reduce(%{}, fn domain, acc ->
          if Map.has_key?(topology, domain) do
            result =
              case domain do
                :subscriptions ->
                  sync_subscriptions_result(
                    state,
                    sid,
                    Map.fetch!(topology, domain),
                    subscription_context
                  )

                :presence_watches ->
                  sync_presence_watches_result(
                    state,
                    sid,
                    Map.fetch!(topology, domain),
                    presence_context
                  )

                :rooms ->
                  sync_rooms_result(state, sid, Map.fetch!(topology, domain), room_opts)
              end

            Map.put(acc, domain, topology_domain_result(result))
          else
            acc
          end
        end)

      failed = Enum.count(domains, fn {_domain, result} -> result.status == :error end)

      {:ok,
       %{
         domains: domains,
         requested_domains: map_size(domains),
         failed_domains: failed,
         partial: failed > 0
       }}
    else
      false -> {:error, :invalid_topology}
      {:error, _} = error -> error
    end
  end

  defp sync_topology_result(_state, _sid, _topology, _opts), do: {:error, :invalid_topology}

  defp topology_domain_result({:ok, result}), do: %{status: :ok, result: result}
  defp topology_domain_result({:error, reason}), do: %{status: :error, reason: reason}

  defp create_session(state, user_id, pid, opts, resumable) when is_pid(pid) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.keyword_opts(opts, @session_option_keys),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         {:ok, metadata} <- normalize_metadata(Keyword.get(opts, :metadata), cfg),
         {:ok, presence_metadata} <-
           normalize_metadata(Keyword.get(opts, :presence_metadata), cfg),
         {:ok, status} <- Wiregrid.Presence.normalize_status(Keyword.get(opts, :status, :online)),
         {:ok, ack_mode} <- normalize_ack_mode(Keyword.get(opts, :ack_mode, :manual)),
         {:ok, delivery_format} <-
           normalize_delivery_format(Keyword.get(opts, :delivery_format, :term)),
         :ok <- enforce_session_capacity(state.instance, user_id, pid, cfg),
         true <- Process.alive?(pid) do
      session_id = Wiregrid.ID.generate()
      monitor = Process.monitor(pid)
      now = System.monotonic_time(:millisecond)
      presence_at = System.system_time(:millisecond)
      {resume_token, resume_hash} = if resumable, do: resume_credentials(), else: {nil, nil}

      session = %{
        id: session_id,
        user_id: user_id,
        pid: pid,
        monitor: monitor,
        metadata: metadata,
        presence_metadata: presence_metadata,
        status: status,
        ack_mode: ack_mode,
        delivery_format: delivery_format,
        connected_at_ms: now,
        presence_updated_ms: presence_at,
        resume_hash: resume_hash
      }

      %{tables: t} = Wiregrid.Tables.get(state.instance)
      true = :ets.insert(t.sessions, {session_id, session})
      true = :ets.insert(t.user_sessions, {user_id, session_id})
      true = :ets.insert(t.user_index, {user_id, true})
      {:ok, _} = :wiregrid_hot.counter_add(t.user_session_counts, user_id, 1)
      true = :ets.insert(t.owner_sessions, {pid, session_id})
      {:ok, _} = :wiregrid_hot.counter_add(t.owner_session_counts, pid, 1)
      true = :ets.insert(t.session_counters, {session_id, 0, 0, 0, 0, 0, 0})
      _ = Wiregrid.Metrics.increment(state.instance, :connections_total)
      _ = Wiregrid.Metrics.increment(state.instance, :sessions)
      state2 = put_in(state.monitors[monitor], session_id)
      Wiregrid.Presence.local_changed(state.instance, user_id)
      {:ok, session, resume_token, state2}
    else
      false -> {:error, :dead_pid}
      {:error, _} = error -> error
    end
  end

  defp create_session(_state, _user_id, _pid, _opts, _resumable), do: {:error, :invalid_pid}

  defp do_resume(state, user_id, pid, token, opts)
       when is_binary(token) and byte_size(token) <= 512 and is_pid(pid) do
    cfg = state.config
    hash = resume_hash(token)

    with :ok <- Wiregrid.Validation.keyword_opts(opts, @session_option_keys),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         true <- Process.alive?(pid),
         %{tables: t} <- Wiregrid.Tables.get(state.instance),
         [{^hash, snapshot}] <- :ets.lookup(t.resume_snapshots, hash),
         true <- snapshot.user_id == user_id,
         true <- snapshot.expires_at_ms >= System.monotonic_time(:millisecond),
         [{^hash, ^snapshot}] <- :ets.take(t.resume_snapshots, hash),
         :ok <- Wiregrid.Expiry.cancel(state.instance, :resume_snapshot, hash) do
      case create_session(state, user_id, pid, resume_opts(snapshot, opts), true) do
        {:ok, session, new_token, state2} ->
          _ = Wiregrid.Capacity.release(t.capacity, :resume_snapshots)
          restored = restore_snapshot(state2, snapshot, session.id)
          {:ok, %{session_id: session.id, resume_token: new_token, restored: restored}, state2}

        {:error, _} = error ->
          restore_resume_snapshot(state.instance, t, hash, snapshot)
          error
      end
    else
      [] -> {:error, :invalid_resume_token}
      false -> {:error, :resume_not_allowed}
      {:error, _} = error -> error
      _ -> {:error, :resume_failed}
    end
  end

  defp do_resume(_state, _user_id, _pid, _token, _opts), do: {:error, :invalid_resume_request}

  defp cleanup_session(state, session_id, reason, demonitor?) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} ->
        case :ets.take(t.sessions, session_id) do
          [{^session_id, session}] ->
            if demonitor?, do: Process.demonitor(session.monitor, [:flush])
            maybe_store_resume_snapshot(state, session)
            cleanup_delivery_reservations(state.instance, session_id)
            Wiregrid.EdgeOps.cleanup_subscriptions(state.instance, state.config, session_id)
            Wiregrid.EdgeOps.cleanup_watches(state.instance, state.config, session_id)
            cleanup_rooms(state, session, reason)
            Wiregrid.Activity.cleanup_session(state.instance, session_id)
            Wiregrid.Receipts.cleanup_session(state.instance, session_id)
            :ets.delete_object(t.user_sessions, {session.user_id, session_id})
            _ = :wiregrid_hot.counter_add_clamped(t.user_session_counts, session.user_id, -1)
            maybe_delete_zero_counter(t.user_session_counts, session.user_id)
            maybe_delete_user_index(t, session.user_id)
            :ets.delete_object(t.owner_sessions, {session.pid, session_id})
            _ = :wiregrid_hot.counter_add_clamped(t.owner_session_counts, session.pid, -1)
            maybe_delete_zero_counter(t.owner_session_counts, session.pid)
            :ets.delete(t.session_counters, session_id)
            :ets.delete(t.slow_evicting, session_id)
            _ = Wiregrid.Metrics.increment(state.instance, :sessions, -1)
            _ = Wiregrid.Metrics.increment(state.instance, :disconnects_total)
            Wiregrid.Presence.local_changed(state.instance, session.user_id)
            {:ok, %{state | monitors: Map.delete(state.monitors, session.monitor)}}

          [] ->
            {{:error, :unknown_session}, state}
        end

      _ ->
        {{:error, :instance_unavailable}, state}
    end
  end

  defp do_session_metadata(state, sid, metadata) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.metadata(metadata, cfg.max_metadata_bytes),
         %{tables: t} <- Wiregrid.Tables.get(state.instance),
         [{^sid, session}] <- :ets.lookup(t.sessions, sid),
         :ok <-
           Wiregrid.Authorizer.check(
             state.instance,
             cfg,
             :session_metadata,
             session,
             session.user_id,
             %{metadata: metadata}
           ) do
      true = :ets.insert(t.sessions, {sid, %{session | metadata: metadata}})
      :ok
    else
      [] -> {:error, :unknown_session}
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  defp do_join_room(state, room, sid, opts) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.keyword_opts(opts, @room_option_keys),
         :ok <- validate_join_metadata(opts, cfg),
         :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         %{tables: t} <- Wiregrid.Tables.get(state.instance),
         [{^sid, session}] <- :ets.lookup(t.sessions, sid),
         :ok <-
           Wiregrid.Authorizer.check(
             state.instance,
             cfg,
             :join_room,
             session,
             room,
             Map.new(opts)
           ),
         false <- :ets.member(t.room_edges, {room, sid}),
         session_count <- :wiregrid_hot.session_counter_get(t.session_counters, sid, 7),
         true <- session_count < cfg.max_rooms_per_session,
         room_count <- :wiregrid_hot.counter_get(t.room_counts, room),
         true <- room_count < cfg.max_room_members,
         :ok <- reserve_edge(t, :room_edges, cfg.max_room_edges),
         true <-
           :ets.insert_new(
             t.room_edges,
             {{room, sid},
              %{user_id: session.user_id, joined_at_ms: System.monotonic_time(:millisecond)}}
           ) do
      :ok = Wiregrid.FanoutIndex.add(t, :room, room, sid, cfg.fanout_buckets)
      true = :ets.insert(t.session_rooms, {sid, room})
      {:ok, _} = :wiregrid_hot.session_counter_add(t.session_counters, sid, 7, 1)
      {:ok, _} = :wiregrid_hot.counter_add(t.room_counts, room, 1)
      _ = Wiregrid.Metrics.increment(state.instance, :room_memberships)

      case maybe_initialize_room_metadata(state, room, Keyword.get(opts, :metadata)) do
        :ok ->
          Wiregrid.Cluster.room_join(state.instance, room, sid, session.user_id)
          :ok

        {:error, _} = error ->
          _ = do_leave_room(state, room, sid, false)
          error
      end
    else
      true -> :ok
      [] -> {:error, :unknown_session}
      false -> {:error, :room_capacity}
      {:error, :capacity} -> reject(state.instance, :room_capacity)
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  defp do_leave_room(state, room, sid, replicate?) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         %{tables: t} <- Wiregrid.Tables.get(state.instance) do
      key = {room, sid}

      case :ets.take(t.room_edges, key) do
        [{^key, member}] ->
          :ok = Wiregrid.FanoutIndex.delete(t, :room, room, sid, cfg.fanout_buckets)
          :ets.delete_object(t.session_rooms, {sid, room})
          _ = :wiregrid_hot.session_counter_add(t.session_counters, sid, 7, -1)
          _ = :wiregrid_hot.counter_add_clamped(t.room_counts, room, -1)
          maybe_delete_zero_counter(t.room_counts, room)
          _ = Wiregrid.Capacity.release(t.capacity, :room_edges)
          _ = Wiregrid.Metrics.increment(state.instance, :room_memberships, -1)

          if replicate?,
            do: Wiregrid.Cluster.room_leave(state.instance, room, sid, member.user_id)

          :ok

        [] ->
          :ok
      end
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  defp do_resume_room(state, room, old_sid, new_sid) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- Wiregrid.Validation.session_id(old_sid, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.session_id(new_sid, cfg.max_session_id_bytes) do
      case Wiregrid.Tables.get(state.instance) do
        %{tables: t} ->
          key = {room, old_sid}
          now = System.monotonic_time(:millisecond)

          with [{^key, %{user_id: user_id, expires_at_ms: expires}}] when expires >= now <-
                 :ets.lookup(t.room_grace, key),
               [{^new_sid, %{user_id: ^user_id}}] <- :ets.lookup(t.sessions, new_sid),
               :ok <- do_join_room(state, room, new_sid, []) do
            # Runtime serializes room lifecycle mutations, so consume the grace
            # credential only after the new membership has been accepted. A
            # transient capacity/authorization failure therefore does not burn
            # an otherwise valid reconnect opportunity.
            case :ets.take(t.room_grace, key) do
              [{^key, _}] ->
                _ = Wiregrid.Capacity.release(t.capacity, :room_grace)
                _ = Wiregrid.Expiry.cancel(state.instance, :room_grace, key)
                :ok

              [] ->
                # The only normal remover is expiry, also serialized through this
                # Runtime. Roll back defensively if ownership vanished.
                _ = do_leave_room(state, room, new_sid, true)
                {:error, :resume_not_allowed}
            end
          else
            _ -> {:error, :resume_not_allowed}
          end

        _ ->
          {:error, :instance_unavailable}
      end
    else
      {:error, _} = error -> error
    end
  end

  defp do_room_metadata(state, room, sid, metadata, opts) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.keyword_opts(opts, [:ttl_ms]),
         :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         :ok <- Wiregrid.Validation.metadata(metadata, cfg.max_metadata_bytes),
         %{tables: t} <- Wiregrid.Tables.get(state.instance),
         [{^sid, session}] <- :ets.lookup(t.sessions, sid),
         true <- :ets.member(t.room_edges, {room, sid}),
         :ok <-
           Wiregrid.Authorizer.check(state.instance, cfg, :room_metadata, session, room, %{
             metadata: metadata
           }),
         {:ok, expires_at} <- optional_expiry(Keyword.get(opts, :ttl_ms), cfg) do
      state_value = %{metadata: metadata, expires_at_ms: expires_at}

      with :ok <- Wiregrid.RoomState.put(t, cfg, room, state_value),
           :ok <- schedule_room_if_needed(state.instance, room, expires_at) do
        Wiregrid.Cluster.room_state(state.instance, room, state_value)
        :ok
      end
    else
      false -> {:error, :not_room_member}
      [] -> {:error, :unknown_session}
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  defp do_room_ttl(state, room, sid, ttl_ms) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth),
         %{tables: t} <- Wiregrid.Tables.get(state.instance),
         [{^sid, session}] <- :ets.lookup(t.sessions, sid),
         true <- :ets.member(t.room_edges, {room, sid}),
         :ok <-
           Wiregrid.Authorizer.check(state.instance, cfg, :room_ttl, session, room, %{
             ttl_ms: ttl_ms
           }),
         {:ok, ttl} <- Wiregrid.Validation.ttl(ttl_ms, cfg.max_ttl_ms) do
      current =
        case :ets.lookup(t.room_state, room) do
          [{^room, value}] -> value
          [] -> %{metadata: %{}}
        end

      expires_at =
        if ttl == :infinity, do: :infinity, else: System.monotonic_time(:millisecond) + ttl

      value = Map.put(current, :expires_at_ms, expires_at)

      with :ok <- Wiregrid.RoomState.put(t, cfg, room, value),
           :ok <- schedule_room_if_needed(state.instance, room, expires_at) do
        Wiregrid.Cluster.room_state(state.instance, room, value)
        :ok
      end
    else
      false -> {:error, :not_room_member}
      [] -> {:error, :unknown_session}
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  defp do_presence(state, sid, status, metadata) do
    cfg = state.config

    with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         {:ok, normalized_status} <- Wiregrid.Presence.normalize_status(status),
         :ok <- Wiregrid.Validation.metadata(metadata, cfg.max_metadata_bytes),
         %{tables: t} <- Wiregrid.Tables.get(state.instance),
         [{^sid, session}] <- :ets.lookup(t.sessions, sid),
         :ok <-
           Wiregrid.Authorizer.check(
             state.instance,
             cfg,
             :set_presence,
             session,
             session.user_id,
             %{status: normalized_status}
           ),
         now <- System.system_time(:millisecond) do
      updated = %{
        session
        | status: normalized_status,
          presence_metadata: metadata,
          presence_updated_ms: now
      }

      true = :ets.insert(t.sessions, {sid, updated})
      Wiregrid.Presence.local_changed(state.instance, session.user_id)
      :ok
    else
      [] -> {:error, :unknown_session}
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  defp maybe_store_resume_snapshot(_state, %{resume_hash: nil}), do: :ok

  defp maybe_store_resume_snapshot(state, session) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} ->
        cfg = state.config

        case Wiregrid.Capacity.reserve(t.capacity, :resume_snapshots, cfg.max_resume_snapshots) do
          :ok ->
            sid = session.id

            snapshot = %{
              user_id: session.user_id,
              old_session_id: sid,
              metadata: session.metadata,
              presence_metadata: session.presence_metadata,
              status: session.status,
              ack_mode: session.ack_mode,
              delivery_format: session.delivery_format,
              subscriptions: for({^sid, topic} <- :ets.lookup(t.session_topics, sid), do: topic),
              watches: for({^sid, user_id} <- :ets.lookup(t.session_watches, sid), do: user_id),
              rooms: for({^sid, room} <- :ets.lookup(t.session_rooms, sid), do: room),
              expires_at_ms: System.monotonic_time(:millisecond) + cfg.resume_ttl_ms
            }

            true = :ets.insert(t.resume_snapshots, {session.resume_hash, snapshot})

            case Wiregrid.Expiry.schedule(
                   state.instance,
                   :resume_snapshot,
                   session.resume_hash,
                   cfg.resume_ttl_ms
                 ) do
              :ok ->
                :ok

              {:error, _} ->
                :ets.delete(t.resume_snapshots, session.resume_hash)
                _ = Wiregrid.Capacity.release(t.capacity, :resume_snapshots)
                :ok
            end

          {:error, :capacity} ->
            _ = Wiregrid.Metrics.increment(state.instance, :admission_rejections)
            :ok
        end

      _ ->
        :ok
    end
  end

  defp restore_snapshot(state, snapshot, new_sid) do
    subs =
      restore_many(snapshot.subscriptions, fn topic ->
        Wiregrid.EdgeOps.subscribe(state.instance, state.config, new_sid, topic, %{resumed: true})
      end)

    watches =
      restore_many(snapshot.watches, fn user ->
        Wiregrid.EdgeOps.watch_presence(state.instance, state.config, new_sid, user, %{
          resumed: true
        })
      end)

    rooms =
      restore_many(snapshot.rooms, fn room ->
        do_resume_room(state, room, snapshot.old_session_id, new_sid)
      end)

    %{subscriptions: subs, presence_watches: watches, rooms: rooms}
  end

  defp restore_many(items, fun) do
    Enum.reduce(items, %{restored: 0, failed: 0}, fn item, acc ->
      case fun.(item) do
        :ok -> %{acc | restored: acc.restored + 1}
        _ -> %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp cleanup_delivery_reservations(instance, sid) do
    Wiregrid.Delivery.release_session(instance, sid)
  end

  defp cleanup_rooms(state, session, reason) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} ->
        sid = session.id
        rooms = for {^sid, room} <- :ets.lookup(t.session_rooms, sid), do: room

        Enum.each(rooms, fn room ->
          :ok = do_leave_room(state, room, session.id, true)
          maybe_store_room_grace(state, room, session, reason)
        end)

        :ets.delete(t.session_rooms, session.id)

      _ ->
        :ok
    end
  end

  defp maybe_store_room_grace(_state, _room, _session, :slow_consumer), do: :ok

  defp maybe_store_room_grace(state, room, session, _reason) do
    %{tables: t} = Wiregrid.Tables.get(state.instance)
    key = {room, session.id}

    case Wiregrid.Capacity.reserve(t.capacity, :room_grace, state.config.max_room_grace) do
      :ok ->
        expires = System.monotonic_time(:millisecond) + state.config.reconnect_grace_ms

        if :ets.insert_new(
             t.room_grace,
             {key, %{user_id: session.user_id, expires_at_ms: expires}}
           ) do
          case Wiregrid.Expiry.schedule_at(state.instance, :room_grace, key, expires) do
            :ok ->
              :ok

            {:error, _} ->
              case :ets.take(t.room_grace, key) do
                [{^key, _}] -> _ = Wiregrid.Capacity.release(t.capacity, :room_grace)
                [] -> :ok
              end

              :ok
          end
        else
          _ = Wiregrid.Capacity.release(t.capacity, :room_grace)
          :ok
        end

      {:error, :capacity} ->
        _ = Wiregrid.Metrics.increment(state.instance, :admission_rejections)
        :ok
    end
  end

  defp expire_room_now(state, room) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} ->
        _ =
          Wiregrid.FanoutIndex.reduce(t, :room, room, :ok, fn sid, :ok ->
            _ = do_leave_room(state, room, sid, true)
            :ok
          end)

        _ = Wiregrid.RoomState.delete_local(t, room)
        delete_room_grace(t, room)
        Wiregrid.Cluster.room_expired(state.instance, room)
        :ok

      _ ->
        :ok
    end
  end

  defp delete_room_grace(t, room) do
    spec = [{{{room, :"$1"}, :"$2"}, [], [true]}]
    deleted = :ets.select_delete(t.room_grace, spec)
    _ = Wiregrid.Capacity.release_many(t.capacity, :room_grace, deleted)
    :ok
  end

  defp release_room_grace(t, key) do
    case :ets.take(t.room_grace, key) do
      [{^key, _}] -> Wiregrid.Capacity.release(t.capacity, :room_grace)
      [] -> :ok
    end
  end

  defp restore_resume_snapshot(instance, t, hash, snapshot) do
    remaining = snapshot.expires_at_ms - System.monotonic_time(:millisecond)

    if remaining > 0 and :ets.insert_new(t.resume_snapshots, {hash, snapshot}) do
      case Wiregrid.Expiry.schedule(instance, :resume_snapshot, hash, remaining) do
        :ok ->
          :ok

        {:error, _} ->
          :ets.delete(t.resume_snapshots, hash)
          _ = Wiregrid.Capacity.release(t.capacity, :resume_snapshots)
          :ok
      end
    else
      _ = Wiregrid.Capacity.release(t.capacity, :resume_snapshots)
      :ok
    end
  end

  defp release_resume_snapshot(instance, hash) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        case :ets.take(t.resume_snapshots, hash) do
          [{^hash, _}] -> Wiregrid.Capacity.release(t.capacity, :resume_snapshots)
          [] -> :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_initialize_room_metadata(_state, _room, nil), do: :ok

  defp maybe_initialize_room_metadata(state, room, metadata) do
    cfg = state.config
    %{tables: t} = Wiregrid.Tables.get(state.instance)

    if :ets.member(t.room_state, room) do
      :ok
    else
      Wiregrid.RoomState.put(t, cfg, room, %{metadata: metadata, expires_at_ms: :infinity})
    end
  end

  defp validate_join_metadata(opts, cfg) do
    case Keyword.fetch(opts, :metadata) do
      :error -> :ok
      {:ok, metadata} -> Wiregrid.Validation.metadata(metadata, cfg.max_metadata_bytes)
    end
  end

  defp optional_expiry(nil, _cfg), do: {:ok, :infinity}

  defp optional_expiry(ttl, cfg) do
    case Wiregrid.Validation.ttl(ttl, cfg.max_ttl_ms) do
      {:ok, :infinity} -> {:ok, :infinity}
      {:ok, ms} -> {:ok, System.monotonic_time(:millisecond) + ms}
      error -> error
    end
  end

  defp schedule_room_if_needed(instance, room, :infinity),
    do: Wiregrid.Expiry.cancel(instance, :room, room)

  defp schedule_room_if_needed(instance, room, expires_at) do
    Wiregrid.Expiry.schedule_at(instance, :room, room, expires_at)
  end

  defp reserve_edge(t, key, limit) do
    Wiregrid.Capacity.reserve(t.capacity, key, limit)
  end

  defp reject(instance, reason) do
    _ = Wiregrid.Metrics.increment(instance, :admission_rejections)
    {:error, reason}
  end

  defp enforce_session_capacity(instance, user_id, owner_pid, cfg) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        total = :ets.info(t.sessions, :size) || 0
        per_user = :wiregrid_hot.counter_get(t.user_session_counts, user_id)
        per_owner = :wiregrid_hot.counter_get(t.owner_session_counts, owner_pid)

        cond do
          total >= cfg.max_sessions -> reject(instance, :session_capacity)
          per_user >= cfg.max_sessions_per_user -> reject(instance, :user_session_capacity)
          per_owner >= cfg.max_sessions_per_owner -> reject(instance, :owner_session_capacity)
          true -> :ok
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  defp normalize_metadata(nil, _cfg), do: {:ok, %{}}

  defp normalize_metadata(metadata, cfg) when is_map(metadata) do
    case Wiregrid.Validation.metadata(metadata, cfg.max_metadata_bytes) do
      :ok -> {:ok, metadata}
      error -> error
    end
  end

  defp normalize_metadata(_, _cfg), do: {:error, :invalid_metadata}

  defp normalize_ack_mode(mode) when mode in [:manual, :transport], do: {:ok, mode}
  defp normalize_ack_mode(_), do: {:error, :invalid_ack_mode}

  defp normalize_delivery_format(format) when format in [:term, :encoded, :both],
    do: {:ok, format}

  defp normalize_delivery_format(_), do: {:error, :invalid_delivery_format}

  defp resume_credentials do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {token, resume_hash(token)}
  end

  defp resume_hash(token), do: :crypto.hash(:sha256, token)

  defp resume_opts(snapshot, opts) do
    defaults = [
      metadata: snapshot.metadata,
      status: snapshot.status,
      presence_metadata: snapshot.presence_metadata,
      ack_mode: snapshot.ack_mode,
      delivery_format: snapshot.delivery_format
    ]

    Keyword.merge(defaults, opts)
  end

  defp maybe_delete_user_index(t, user_id) do
    if :ets.lookup(t.user_sessions, user_id) == [], do: :ets.delete(t.user_index, user_id)
  end

  defp rebuild_monitors(state) do
    case Wiregrid.Tables.get(state.instance) do
      %{tables: t} ->
        monitors =
          :ets.foldl(
            fn {sid, session}, acc ->
              ref = Process.monitor(session.pid)
              updated = %{session | monitor: ref}
              true = :ets.insert(t.sessions, {sid, updated})
              Map.put(acc, ref, sid)
            end,
            %{},
            t.sessions
          )

        %{state | monitors: monitors}

      _ ->
        state
    end
  end

  defp batch_size(items, limit) do
    case Wiregrid.Validation.bounded_list(items, limit) do
      :ok -> if(items == [], do: {:error, :empty_batch}, else: :ok)
      {:error, :list_too_large} -> {:error, :batch_too_large}
      {:error, _} -> {:error, :invalid_batch}
    end
  end

  defp do_batch(items, fun) when is_list(items) and is_function(fun, 1) do
    {completed, errors} =
      Enum.reduce(items, {0, []}, fn item, {count, failures} ->
        case fun.(item) do
          :ok -> {count + 1, failures}
          {:error, reason} -> {count, [{item, reason} | failures]}
          other -> {count, [{item, {:unexpected_result, other}} | failures]}
        end
      end)

    {:ok, %{completed: completed, failed: length(errors), errors: Enum.reverse(errors)}}
  end

  defp do_batch(_items, _fun), do: {:error, :invalid_batch}

  defp maybe_delete_zero_counter(table, key) do
    case :ets.lookup(table, key) do
      [{^key, 0}] -> :ets.delete(table, key)
      _ -> :ok
    end
  end

  defp state_draining(state), do: flag(state.instance, :draining, false)

  defp flag(instance, key, default) do
    case Wiregrid.Tables.get(instance) do
      %{tables: %{runtime_flags: table}} ->
        case :ets.lookup(table, key) do
          [{^key, value}] -> value
          [] -> default
        end

      _ ->
        default
    end
  end

  defp set_flag(instance, key, value) do
    case Wiregrid.Tables.get(instance) do
      %{tables: %{runtime_flags: table}} -> :ets.insert(table, {key, value})
      _ -> false
    end
  end

  defp call(instance, message) do
    case reserve_control_slot(instance) do
      {:ok, generation, timeout_ms} ->
        try do
          GenServer.call(
            via(instance),
            {:wiregrid_admitted_call, generation, message},
            timeout_ms
          )
        catch
          :exit, {:timeout, _} ->
            # The request may still be queued. The Runtime releases the slot when
            # it eventually starts processing it; a Runtime restart resets all
            # pending control slots during recovery.
            {:error, :control_timeout}

          :exit, _ ->
            release_control_slot(instance, generation)
            {:error, :instance_unavailable}
        end

      {:error, :capacity} ->
        _ = Wiregrid.Metrics.increment(instance, :control_rejections)
        {:error, :control_overloaded}

      {:error, _} = error ->
        error
    end
  end

  defp cast(instance, message) do
    case reserve_control_slot(instance) do
      {:ok, generation, _timeout_ms} ->
        try do
          GenServer.cast(via(instance), {:wiregrid_admitted_cast, generation, message})
          :ok
        catch
          :exit, _ ->
            release_control_slot(instance, generation)
            :ok
        end

      {:error, :capacity} ->
        _ = Wiregrid.Metrics.increment(instance, :control_rejections)
        {:error, :control_overloaded}

      {:error, _} ->
        :ok
    end
  end

  def control_pending(instance) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        generation = control_generation(t)
        Wiregrid.Capacity.get(t.capacity, {:control_pending, generation})

      _ ->
        0
    end
  end

  defp reserve_control_slot(instance) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t, config: cfg} ->
        generation = control_generation(t)

        case Wiregrid.Capacity.reserve(
               t.capacity,
               {:control_pending, generation},
               cfg.max_control_pending
             ) do
          :ok -> {:ok, generation, cfg.control_call_timeout_ms}
          {:error, _} = error -> error
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  defp release_control_slot(instance, generation) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} -> Wiregrid.Capacity.release(t.capacity, {:control_pending, generation})
      _ -> {:ok, 0}
    end
  end

  defp next_control_generation(instance) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        generation = System.unique_integer([:positive, :monotonic])
        true = :ets.insert(t.runtime_flags, {:control_generation, generation})
        generation

      _ ->
        System.unique_integer([:positive, :monotonic])
    end
  end

  defp control_generation(tables) do
    case :ets.lookup(tables.runtime_flags, :control_generation) do
      [{:control_generation, generation}] -> generation
      [] -> 0
    end
  end
end
