defmodule Wiregrid.Chat do
  @moduledoc """
  Opinionated façade for production chat/collaboration applications on Wiregrid.

  It adds conventional channel, direct-message, typing, reaction, edit/delete
  event and read-receipt vocabulary while retaining Wiregrid's bounded realtime
  runtime. The event helpers are event-oriented on purpose: applications remain
  free to project edits, deletes and reactions into whichever durable model
  they prefer.
  """

  @type channel :: binary() | atom() | integer()
  @type room :: binary() | atom() | integer()

  @message_event_options [:attachments, :mentions, :metadata, :nonce, :reply_to]
  @publish_options [:event_id, :meta, :cluster, :exclude_sessions, :exclude_users]
  @direct_options [:event_id, :meta, :cluster]

  defmacro __using__(opts) do
    instance = Keyword.fetch!(opts, :instance)
    wiregrid_options = Keyword.get(opts, :options, [])
    chat_config = opts |> Keyword.get(:chat, []) |> Wiregrid.Chat.Config.build!()

    quote do
      @wiregrid_chat_instance unquote(instance)
      @wiregrid_chat_options unquote(wiregrid_options)
      @wiregrid_chat_config unquote(Macro.escape(chat_config))

      def child_spec(_arg),
        do:
          Wiregrid.Instance.child_spec(
            instance: @wiregrid_chat_instance,
            options: @wiregrid_chat_options
          )

      def instance, do: @wiregrid_chat_instance
      def wiregrid_options, do: @wiregrid_chat_options
      def chat_config, do: @wiregrid_chat_config

      def connect(user_id, pid \\ self(), opts \\ []),
        do: Wiregrid.connect(@wiregrid_chat_instance, user_id, pid, opts)

      def connect_resumable(user_id, pid \\ self(), opts \\ []),
        do: Wiregrid.connect_resumable(@wiregrid_chat_instance, user_id, pid, opts)

      def resume(user_id, pid, token, opts \\ []),
        do: Wiregrid.resume_session(@wiregrid_chat_instance, user_id, pid, token, opts)

      def disconnect(session_id, reason \\ :normal),
        do: Wiregrid.disconnect(@wiregrid_chat_instance, session_id, reason)

      def join(session_id, channel, context \\ %{}),
        do: Wiregrid.Chat.join(@wiregrid_chat_instance, session_id, channel, context)

      def leave(session_id, channel),
        do: Wiregrid.Chat.leave(@wiregrid_chat_instance, session_id, channel)

      def say(session_id, channel, body, opts \\ []),
        do:
          Wiregrid.Chat.say(
            @wiregrid_chat_instance,
            session_id,
            channel,
            body,
            opts,
            @wiregrid_chat_config
          )

      def whisper(session_id, user_id, body, opts \\ []),
        do:
          Wiregrid.Chat.whisper(
            @wiregrid_chat_instance,
            session_id,
            user_id,
            body,
            opts,
            @wiregrid_chat_config
          )

      def edit(session_id, channel, message_id, body),
        do:
          Wiregrid.Chat.edit(
            @wiregrid_chat_instance,
            session_id,
            channel,
            message_id,
            body,
            @wiregrid_chat_config
          )

      def delete(session_id, channel, message_id, reason \\ nil),
        do:
          Wiregrid.Chat.delete(
            @wiregrid_chat_instance,
            session_id,
            channel,
            message_id,
            reason,
            @wiregrid_chat_config
          )

      def react(session_id, channel, message_id, reaction),
        do:
          Wiregrid.Chat.react(
            @wiregrid_chat_instance,
            session_id,
            channel,
            message_id,
            reaction,
            true,
            @wiregrid_chat_config
          )

      def unreact(session_id, channel, message_id, reaction),
        do:
          Wiregrid.Chat.react(
            @wiregrid_chat_instance,
            session_id,
            channel,
            message_id,
            reaction,
            false,
            @wiregrid_chat_config
          )

      def mark_read(session_id, channel, message_id),
        do: Wiregrid.Chat.mark_read(@wiregrid_chat_instance, session_id, channel, message_id)

      def typing(session_id, channel, active? \\ true),
        do:
          Wiregrid.Chat.typing(
            @wiregrid_chat_instance,
            session_id,
            channel,
            active?,
            @wiregrid_chat_config
          )

      def set_presence(session_id, status, metadata \\ %{}),
        do: Wiregrid.set_presence(@wiregrid_chat_instance, session_id, status, metadata)

      def ack(envelope), do: Wiregrid.Chat.ack(@wiregrid_chat_instance, envelope)

      def history(channel, cursor \\ nil, limit \\ 100),
        do: Wiregrid.Chat.history(@wiregrid_chat_instance, channel, cursor, limit)

      def inbox_history(user_id, cursor \\ nil, limit \\ 100),
        do: Wiregrid.Chat.inbox_history(@wiregrid_chat_instance, user_id, cursor, limit)

      def gateway_child_spec(opts \\ []),
        do:
          Wiregrid.Foreign.Gateway.child_spec(
            Keyword.put(opts, :instance, @wiregrid_chat_instance)
          )

      defoverridable child_spec: 1
    end
  end

  def join(instance, session_id, channel, context \\ %{}),
    do: Wiregrid.subscribe(instance, session_id, channel_topic(channel), context)

  def leave(instance, session_id, channel),
    do: Wiregrid.unsubscribe(instance, session_id, channel_topic(channel))

  def say(instance, session_id, channel, body, opts \\ [], cfg \\ Wiregrid.Chat.Config.build!([])) do
    with :ok <- validate_chat_opts(opts),
         :ok <- admit(instance, :message, session_id, cfg),
         {:ok, event} <-
           Wiregrid.Chat.Event.message(body, Keyword.take(opts, @message_event_options), cfg) do
      publish_durable(instance, session_id, channel, event, Keyword.take(opts, @publish_options))
    end
  end

  def whisper(
        instance,
        session_id,
        user_id,
        body,
        opts \\ [],
        cfg \\ Wiregrid.Chat.Config.build!([])
      ) do
    with :ok <- validate_chat_opts(opts),
         :ok <- admit(instance, :message, session_id, cfg),
         {:ok, event} <-
           Wiregrid.Chat.Event.message(body, Keyword.take(opts, @message_event_options), cfg) do
      publish_opts =
        opts
        |> Keyword.take(@direct_options)
        |> put_sender(session_id)
        |> Keyword.put_new(:class, :durable)
        |> Keyword.put_new(:persist, true)

      Wiregrid.send_user(instance, user_id, event, publish_opts)
    end
  end

  def edit(
        instance,
        session_id,
        channel,
        message_id,
        body,
        cfg \\ Wiregrid.Chat.Config.build!([])
      ) do
    with :ok <- admit(instance, :message, session_id, cfg),
         {:ok, event} <- Wiregrid.Chat.Event.edit(message_id, body, cfg) do
      publish_durable(instance, session_id, channel, event, [])
    end
  end

  def delete(
        instance,
        session_id,
        channel,
        message_id,
        reason \\ nil,
        cfg \\ Wiregrid.Chat.Config.build!([])
      ) do
    with :ok <- admit(instance, :message, session_id, cfg),
         {:ok, event} <- Wiregrid.Chat.Event.delete(message_id, reason) do
      publish_durable(instance, session_id, channel, event, [])
    end
  end

  def react(
        instance,
        session_id,
        channel,
        message_id,
        reaction,
        add? \\ true,
        cfg \\ Wiregrid.Chat.Config.build!([])
      ) do
    with :ok <- admit(instance, :activity, session_id, cfg),
         {:ok, event} <- Wiregrid.Chat.Event.reaction(message_id, reaction, add?, cfg) do
      publish_durable(instance, session_id, channel, event, [])
    end
  end

  def mark_read(instance, session_id, channel, message_id) do
    with {:ok, event} <- Wiregrid.Chat.Event.read(message_id) do
      Wiregrid.publish(instance, channel_topic(channel), event,
        class: :ephemeral,
        persist: false,
        session_id: session_id,
        exclude_sessions: [session_id]
      )
    end
  end

  def typing(
        instance,
        session_id,
        channel,
        active? \\ true,
        cfg \\ Wiregrid.Chat.Config.build!([])
      )

  def typing(instance, session_id, channel, active?, cfg) when is_boolean(active?) do
    with :ok <- admit(instance, :activity, session_id, cfg) do
      Wiregrid.publish(instance, channel_topic(channel), Wiregrid.Chat.Event.typing(active?),
        class: :ephemeral,
        persist: false,
        session_id: session_id,
        exclude_sessions: [session_id]
      )
    end
  end

  def typing(_instance, _session_id, _channel, _active?, _cfg),
    do: {:error, :invalid_typing_state}

  def history(instance, channel, cursor \\ nil, limit \\ 100),
    do: Wiregrid.Storage.page(instance, channel_topic(channel), cursor, limit)

  def inbox_history(instance, user_id, cursor \\ nil, limit \\ 100),
    do: Wiregrid.Storage.page(instance, {:user, user_id}, cursor, limit)

  def ack(instance, %{session_id: session_id, delivery_id: delivery_id}),
    do: Wiregrid.ack(instance, session_id, delivery_id)

  def ack(_instance, _envelope), do: {:error, :invalid_delivery_envelope}

  def channel_topic(channel), do: {:channel, channel}
  def room_topic(room), do: {:room, room}

  defp admit(_instance, _kind, _session_id, %{message_rate_limit: nil, activity_rate_limit: nil}),
    do: :ok

  defp admit(instance, :message, session_id, %{message_rate_limit: rate}),
    do: check_rate(instance, :chat_message, session_id, rate)

  defp admit(instance, :activity, session_id, %{activity_rate_limit: rate}),
    do: check_rate(instance, :chat_activity, session_id, rate)

  defp check_rate(_instance, _bucket, _session_id, nil), do: :ok

  defp check_rate(instance, bucket, session_id, {limit, window}) do
    case Wiregrid.RateLimiter.check(instance, bucket, session_id, limit, window,
           policy: :token_bucket,
           burst: limit
         ) do
      {:ok, _remaining} -> :ok
      {:error, _} = error -> error
    end
  end

  defp publish_durable(instance, session_id, channel, event, opts) do
    publish_opts =
      opts
      |> Keyword.take(@publish_options)
      |> put_sender(session_id)
      |> Keyword.put_new(:class, :durable)
      |> Keyword.put_new(:persist, true)

    Wiregrid.publish(instance, channel_topic(channel), event, publish_opts)
  end

  defp validate_chat_opts(opts) when is_list(opts) do
    allowed = @message_event_options ++ @publish_options

    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- allowed,
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      :ok
    else
      _ -> {:error, :invalid_chat_options}
    end
  end

  defp validate_chat_opts(_), do: {:error, :invalid_chat_options}

  defp put_sender(opts, session_id) when is_list(opts),
    do: Keyword.put_new(opts, :session_id, session_id)
end
