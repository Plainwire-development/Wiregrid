defmodule Wiregrid.LoadHarness do
  def run do
    cfg = %{
      users: env_int("USERS", 1_000, 1),
      sessions_per_user: env_int("SESSIONS_PER_USER", 1, 1),
      topics: env_int("TOPICS", 100, 1),
      subscriptions_per_session: env_int("SUBSCRIPTIONS_PER_SESSION", 1, 1),
      messages: env_int("MESSAGES", 10_000, 1),
      messages_per_sec: env_int("MESSAGES_PER_SEC", 0, 0),
      duration_s: env_int("DURATION_S", 0, 0),
      ack_delay_ms: env_int("ACK_DELAY_MS", 0, 0),
      slow_percent: env_int("SLOW_PERCENT", 0, 0, 100),
      reconnect_percent: env_int("RECONNECT_PERCENT", 0, 0, 100),
      room_churn_percent: env_int("ROOM_CHURN_PERCENT", 5, 0, 100)
    }

    messages =
      if cfg.duration_s > 0 and cfg.messages_per_sec > 0,
        do: cfg.duration_s * cfg.messages_per_sec,
        else: cfg.messages

    {:ok, _} = Application.ensure_all_started(:wiregrid)
    instance = {:wiregrid_load, System.unique_integer([:positive])}

    {:ok, _} =
      Wiregrid.start_instance(instance,
        profile: profile(cfg.users * cfg.sessions_per_user),
        cluster: false,
        soft_queue: 2_000,
        hard_queue: 8_000
      )

    latency = :ets.new(:wiregrid_load_latency, [:set, :public, write_concurrency: true])
    errors = :ets.new(:wiregrid_load_errors, [:set, :public, write_concurrency: true])
    parent = self()

    sessions = create_sessions(instance, cfg, latency, errors, parent)
    sessions = reconnect_subset(instance, sessions, cfg.reconnect_percent, errors)
    room_churn(instance, sessions, cfg.room_churn_percent)

    publish_start = System.monotonic_time(:microsecond)
    publish_loop(instance, cfg.topics, messages, cfg.messages_per_sec, errors)
    publish_elapsed = max(System.monotonic_time(:microsecond) - publish_start, 1)

    case Wiregrid.await_idle(instance, 60_000) do
      :ok -> :ok
      other -> record_error(errors, {:await_idle, other})
    end

    latencies = :ets.tab2list(latency) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    stats = Wiregrid.stats(instance)

    IO.puts("Wiregrid load result")
    IO.puts("users=#{cfg.users} sessions=#{length(sessions)} topics=#{cfg.topics} subscriptions_per_session=#{cfg.subscriptions_per_session}")
    IO.puts("messages=#{messages} publish_ms=#{div(publish_elapsed, 1_000)} publish_msg_per_s=#{Float.round(messages * 1_000_000 / publish_elapsed, 1)}")
    IO.puts("deliveries=#{length(latencies)} p50_us=#{percentile(latencies, 50)} p95_us=#{percentile(latencies, 95)} p99_us=#{percentile(latencies, 99)}")
    IO.puts("errors=#{:ets.info(errors, :size) || 0} memory_words=#{Map.get(stats, :memory_words, 0)} reservations=#{Map.get(stats, :delivery_reservations, 0)}")

    Enum.each(sessions, fn session -> send(session.pid, :stop) end)
    _ = Wiregrid.stop_instance(instance)

    if (:ets.info(errors, :size) || 0) > 0 do
      :ets.tab2list(errors) |> Enum.take(20) |> Enum.each(&IO.inspect(&1, label: "load_error"))
      System.halt(2)
    end
  end

  defp create_sessions(instance, cfg, latency, errors, parent) do
    total = cfg.users * cfg.sessions_per_user

    0..(total - 1)
    |> Task.async_stream(
      fn index ->
        user_index = div(index, cfg.sessions_per_user)
        user_id = "load-user-#{user_index}"
        slow? = rem(index, 100) < cfg.slow_percent
        delay = if slow?, do: cfg.ack_delay_ms, else: 0
        pid = spawn_link(fn -> consumer(instance, latency, errors, delay, parent) end)
        {:ok, sid, token} = Wiregrid.connect_resumable(instance, user_id, pid)

        topics =
          0..(cfg.subscriptions_per_session - 1)
          |> Enum.map(fn offset -> {:channel, rem(index + offset, cfg.topics)} end)

        Enum.each(topics, fn topic -> :ok = Wiregrid.subscribe(instance, sid, topic) end)
        if rem(index, 10) == 0, do: :ok = Wiregrid.set_presence(instance, sid, :idle, %{load: true})
        %{index: index, user_id: user_id, pid: pid, sid: sid, token: token, topics: topics}
      end,
      max_concurrency: max(System.schedulers_online() * 8, 8),
      timeout: 30_000,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, session} -> session
      {:exit, reason} -> raise "session setup failed: #{inspect(reason)}"
    end)
  end

  defp reconnect_subset(instance, sessions, percent, errors) do
    Enum.map(sessions, fn session ->
      if rem(session.index, 100) < percent do
        with :ok <- Wiregrid.disconnect(instance, session.sid, :load_reconnect),
             {:ok, resumed} <- Wiregrid.resume_session(instance, session.user_id, session.pid, session.token) do
          %{session | sid: resumed.session_id, token: resumed.resume_token}
        else
          other ->
            record_error(errors, {:reconnect, session.index, other})
            session
        end
      else
        session
      end
    end)
  end

  defp room_churn(instance, sessions, percent) do
    selected = Enum.filter(sessions, &(rem(&1.index, 100) < percent))

    Enum.each(selected, fn session ->
      room = {:room, rem(session.index, 16)}
      _ = Wiregrid.join_room(instance, room, session.sid)
      _ = Wiregrid.leave_room(instance, room, session.sid)
    end)
  end

  defp publish_loop(instance, topics, messages, messages_per_sec, errors) do
    interval_us = if messages_per_sec > 0, do: div(1_000_000, messages_per_sec), else: 0
    origin = System.monotonic_time(:microsecond)

    Enum.each(1..messages, fn n ->
      if interval_us > 0 do
        target = origin + (n - 1) * interval_us
        sleep_until(target)
      end

      event = %{type: :load_message, n: n, sent_us: System.monotonic_time(:microsecond)}

      case Wiregrid.publish(instance, {:channel, rem(n, topics)}, event, class: :durable) do
        {:ok, _} -> :ok
        other -> record_error(errors, {:publish, n, other})
      end

      if rem(n, 100) == 0 do
        _ = Wiregrid.publish(instance, {:channel, rem(n, topics)}, %{type: :load_ephemeral, n: n}, class: :ephemeral)
      end
    end)
  end

  defp consumer(instance, latency, errors, delay, parent) do
    receive do
      {:"$wiregrid", %{delivery_id: id, session_id: sid, event: event} = _envelope} ->
        if delay > 0, do: Process.sleep(delay)
        received = System.monotonic_time(:microsecond)

        case Wiregrid.ack(instance, sid, id) do
          {:ok, _} -> :ok
          other -> record_error(errors, {:ack, sid, other})
        end

        case event do
          %{sent_us: sent} when is_integer(sent) ->
            :ets.insert(latency, {:erlang.unique_integer([:positive, :monotonic]), max(received - sent, 0)})

          _ ->
            :ok
        end

        consumer(instance, latency, errors, delay, parent)

      :stop ->
        send(parent, {:consumer_stopped, self()})
        :ok

      _other ->
        consumer(instance, latency, errors, delay, parent)
    end
  end

  defp sleep_until(target) do
    remaining = target - System.monotonic_time(:microsecond)
    if remaining > 1_000, do: Process.sleep(div(remaining, 1_000))
  end

  defp percentile([], _p), do: 0

  defp percentile(values, p) do
    index = max(ceil(length(values) * p / 100) - 1, 0)
    Enum.at(values, min(index, length(values) - 1))
  end

  defp record_error(table, value) do
    :ets.insert(table, {:erlang.unique_integer([:positive, :monotonic]), value})
    :ok
  end

  defp profile(total) when total <= 10_000, do: :small
  defp profile(total) when total <= 100_000, do: :balanced
  defp profile(_total), do: :large

  defp env_int(name, default, minimum, maximum \\ 10_000_000) do
    case System.get_env(name) do
      nil -> default
      value ->
        case Integer.parse(value) do
          {number, ""} when number >= minimum and number <= maximum -> number
          _ -> raise "#{name} must be an integer in #{minimum}..#{maximum}"
        end
    end
  end
end

Wiregrid.LoadHarness.run()
