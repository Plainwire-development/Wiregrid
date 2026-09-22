defmodule Wiregrid.Transport.Command do
  @moduledoc """
  Transport-neutral authenticated command router.

  Cowboy and custom transports can share one bounded command surface instead of
  reimplementing session binding and operation dispatch. Built-in Wiregrid
  commands are handled first. An optional extension handler receives only
  unknown commands and a sanitized context containing `:instance`, `:session_id`
  and `:user_id`; authentication headers, resume credentials and transport
  internals are never exposed.

  Extension handlers may be a two-argument function or a module exporting
  `handle_command/2`. Exceptions and invalid extension configuration fail
  closed. The command term itself is bounded/portable before either built-in or
  extension logic runs.
  """

  @type extension :: nil | (term(), map() -> term()) | module()

  @spec validate_extension(term()) :: {:ok, extension()} | {:error, term()}
  def validate_extension(nil), do: {:ok, nil}
  def validate_extension(fun) when is_function(fun, 2), do: {:ok, fun}

  def validate_extension(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :handle_command, 2) do
      {:ok, module}
    else
      {:error, :invalid_command_handler}
    end
  end

  def validate_extension(_), do: {:error, :invalid_command_handler}

  @spec dispatch(term(), binary(), term(), term(), extension()) :: term()
  def dispatch(instance, session_id, user_id, command, extension \\ nil) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         {:ok, _} <- Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes),
         :ok <- bounded_command(command, cfg),
         {:ok, extension} <- validate_extension(extension) do
      context = %{instance: instance, session_id: session_id, user_id: user_id}
      dispatch_builtin(context, command, extension)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  defp bounded_command(command, cfg) do
    with :ok <- Wiregrid.Validation.portable_term(command, 0, 12, 4_096),
         {:ok, bytes} <- Wiregrid.Validation.safe_size(command),
         true <- bytes <= cfg.max_websocket_frame_bytes do
      :ok
    else
      false -> {:error, :command_too_large}
      {:error, _} -> {:error, :invalid_command}
    end
  end

  defp dispatch_builtin(ctx, {:subscribe, topic}, _extension),
    do: Wiregrid.subscribe(ctx.instance, ctx.session_id, topic)

  defp dispatch_builtin(ctx, {:subscribe, topic, context}, _extension) when is_map(context),
    do: Wiregrid.subscribe(ctx.instance, ctx.session_id, topic, context)

  defp dispatch_builtin(ctx, {:unsubscribe, topic}, _extension),
    do: Wiregrid.unsubscribe(ctx.instance, ctx.session_id, topic)

  defp dispatch_builtin(ctx, {:publish, topic, event, opts}, _extension) when is_list(opts) do
    with {:ok, bound} <- actor_opts(opts, ctx.session_id),
         do: Wiregrid.publish(ctx.instance, topic, event, bound)
  end

  defp dispatch_builtin(ctx, {:publish_room, room, event, opts}, _extension) when is_list(opts) do
    with {:ok, bound} <- actor_opts(opts, ctx.session_id),
         do: Wiregrid.publish_room(ctx.instance, room, event, bound)
  end

  defp dispatch_builtin(ctx, {:dispatch, targets, event, opts}, _extension) when is_list(opts) do
    with {:ok, bound} <- actor_opts(opts, ctx.session_id),
         do: Wiregrid.dispatch(ctx.instance, targets, event, bound)
  end

  defp dispatch_builtin(ctx, {:send_user, user_id, event, opts}, _extension) when is_list(opts) do
    with {:ok, bound} <- actor_opts(opts, ctx.session_id),
         do: Wiregrid.send_user(ctx.instance, user_id, event, bound)
  end

  defp dispatch_builtin(ctx, {:send_session, target_session, event, opts}, _extension)
       when is_list(opts) do
    with {:ok, bound} <- actor_opts(opts, ctx.session_id),
         do: Wiregrid.send_session(ctx.instance, target_session, event, bound)
  end

  defp dispatch_builtin(ctx, {:presence, status}, _extension),
    do: Wiregrid.set_presence(ctx.instance, ctx.session_id, status, %{})

  defp dispatch_builtin(ctx, {:presence, status, metadata}, _extension) when is_map(metadata),
    do: Wiregrid.set_presence(ctx.instance, ctx.session_id, status, metadata)

  defp dispatch_builtin(ctx, {:watch_presence, user_id}, _extension),
    do: Wiregrid.watch_presence(ctx.instance, ctx.session_id, user_id)

  defp dispatch_builtin(ctx, {:unwatch_presence, user_id}, _extension),
    do: Wiregrid.unwatch_presence(ctx.instance, ctx.session_id, user_id)

  defp dispatch_builtin(ctx, {:join_room, room}, _extension),
    do: Wiregrid.join_room(ctx.instance, room, ctx.session_id)

  defp dispatch_builtin(ctx, {:join_room, room, opts}, _extension) when is_list(opts),
    do: Wiregrid.join_room(ctx.instance, room, ctx.session_id, opts)

  defp dispatch_builtin(ctx, {:leave_room, room}, _extension),
    do: Wiregrid.leave_room(ctx.instance, room, ctx.session_id)

  defp dispatch_builtin(ctx, {:room_metadata, room, metadata, opts}, _extension)
       when is_map(metadata) and is_list(opts),
       do: Wiregrid.set_room_metadata(ctx.instance, room, ctx.session_id, metadata, opts)

  defp dispatch_builtin(ctx, {:room_ttl, room, ttl}, _extension),
    do: Wiregrid.set_room_ttl(ctx.instance, room, ctx.session_id, ttl)

  defp dispatch_builtin(ctx, {:typing, topic, opts}, _extension) when is_list(opts),
    do: Wiregrid.typing(ctx.instance, ctx.session_id, topic, opts)

  defp dispatch_builtin(ctx, {:activity, topic, kind, value, opts}, _extension)
       when is_list(opts),
       do: Wiregrid.activity(ctx.instance, ctx.session_id, topic, kind, value, opts)

  defp dispatch_builtin(ctx, {:receipt, receipt, opts}, _extension)
       when is_map(receipt) and is_list(opts),
       do: Wiregrid.receipt(ctx.instance, ctx.session_id, receipt, opts)

  defp dispatch_builtin(ctx, {:signal, room, kind, payload, opts}, _extension) when is_list(opts),
    do: Wiregrid.signal(ctx.instance, room, ctx.session_id, kind, payload, opts)

  defp dispatch_builtin(ctx, {:sync_topology, topology, opts}, _extension)
       when is_map(topology) and is_list(opts),
       do: Wiregrid.sync_topology(ctx.instance, ctx.session_id, topology, opts)

  defp dispatch_builtin(ctx, {:request_session, target_session, event, opts}, _extension)
       when is_list(opts),
       do: Wiregrid.request_session(ctx.instance, ctx.session_id, target_session, event, opts)

  defp dispatch_builtin(ctx, {:reply, request_envelope, event, opts}, _extension)
       when is_map(request_envelope) and is_list(opts),
       do: Wiregrid.reply(ctx.instance, ctx.session_id, request_envelope, event, opts)

  defp dispatch_builtin(ctx, {:replay, stream, opts}, _extension) when is_list(opts),
    do: Wiregrid.replay_session(ctx.instance, ctx.session_id, stream, opts)

  defp dispatch_builtin(ctx, {:history, topic, opts}, _extension) when is_list(opts) do
    Wiregrid.read_history(
      ctx.instance,
      ctx.session_id,
      topic,
      Keyword.get(opts, :cursor),
      Keyword.get(opts, :limit, 50)
    )
  end

  defp dispatch_builtin(ctx, {:ack, delivery_id}, _extension),
    do: Wiregrid.ack(ctx.instance, ctx.session_id, delivery_id)

  defp dispatch_builtin(ctx, {:ack_many, delivery_ids}, _extension),
    do: Wiregrid.ack_many(ctx.instance, ctx.session_id, delivery_ids)

  defp dispatch_builtin(_ctx, {:ping, nonce}, _extension), do: {:pong, nonce}
  defp dispatch_builtin(ctx, command, extension), do: dispatch_extension(extension, command, ctx)

  defp dispatch_extension(nil, _command, _ctx), do: {:error, :unknown_command}

  defp dispatch_extension(fun, command, ctx) when is_function(fun, 2) do
    safe_extension(fn -> fun.(command, ctx) end)
  end

  defp dispatch_extension(module, command, ctx) when is_atom(module) do
    safe_extension(fn -> module.handle_command(command, ctx) end)
  end

  defp safe_extension(fun) do
    try do
      fun.()
    rescue
      _ -> {:error, :command_handler_failed}
    catch
      _, _ -> {:error, :command_handler_failed}
    end
  end

  defp actor_opts(opts, sid) when is_list(opts) do
    cond do
      Wiregrid.Validation.bounded_list(opts, 64) != :ok -> {:error, :invalid_options}
      not Keyword.keyword?(opts) -> {:error, :invalid_options}
      Keyword.has_key?(opts, :session_id) -> {:error, :transport_session_override}
      true -> {:ok, Keyword.put(opts, :session_id, sid)}
    end
  end
end
