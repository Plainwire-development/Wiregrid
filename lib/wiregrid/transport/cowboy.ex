defmodule Wiregrid.Transport.Cowboy do
  @moduledoc "Optional Cowboy WebSocket handler. Cowboy is supplied by the embedding application."

  @option_keys [
    :instance,
    :auth,
    :auth_fun,
    :protocol,
    :origin_allowlist,
    :max_frame_size,
    :idle_timeout,
    :ack_strategy,
    :connect_opts,
    :auth_rate_limit,
    :auth_window_ms,
    :auth_rate_policy,
    :auth_rate_burst,
    :frame_rate_limit,
    :frame_window_ms,
    :frame_rate_policy,
    :frame_rate_burst,
    :allow_permissive_authorizer,
    :command_handler
  ]

  def init(req, opts) when is_list(opts) do
    with :ok <- Wiregrid.Validation.keyword_opts(opts, @option_keys),
         instance when not is_nil(instance) <- Keyword.get(opts, :instance),
         %{config: cfg} <- Wiregrid.Tables.get(instance),
         :ok <- transport_authorization(cfg, opts),
         {:ok, protocol} <-
           protocol(Keyword.get(opts, :protocol, Wiregrid.Transport.Protocol.Term)),
         {:ok, frame_limit} <-
           frame_limit(Keyword.get(opts, :max_frame_size, cfg.max_websocket_frame_bytes), cfg),
         {:ok, idle_timeout} <- positive_timeout(Keyword.get(opts, :idle_timeout, 60_000)),
         {:ok, ack_strategy} <- ack_strategy(Keyword.get(opts, :ack_strategy, :client)),
         {:ok, command_handler} <-
           Wiregrid.Transport.Command.validate_extension(Keyword.get(opts, :command_handler)),
         {:ok, frame_rate_limit} <-
           bounded_rate(
             Keyword.get(opts, :frame_rate_limit, 240),
             1,
             100_000,
             :invalid_frame_rate_limit
           ),
         {:ok, frame_window_ms} <-
           bounded_rate(
             Keyword.get(opts, :frame_window_ms, 60_000),
             100,
             3_600_000,
             :invalid_frame_window
           ),
         {:ok, frame_rate_opts} <- rate_policy_opts(opts, :frame, frame_rate_limit),
         {:ok, request_info} <- request_info(req),
         :ok <- origin_allowed(request_info.origin, Keyword.get(opts, :origin_allowlist, [])),
         :ok <- preauth_rate_limit(instance, request_info.peer, opts),
         {:ok, user_id} <- authenticate(request_info, opts, instance),
         {:ok, connect_opts} <- connect_opts(Keyword.get(opts, :connect_opts, [])) do
      state = %{
        instance: instance,
        user_id: user_id,
        protocol: protocol,
        max_frame_size: frame_limit,
        ack_strategy: ack_strategy,
        command_handler: command_handler,
        connect_opts:
          connect_opts
          |> Keyword.put(:ack_mode, if(ack_strategy == :client, do: :manual, else: :transport))
          |> Keyword.put(
            :delivery_format,
            if(protocol == Wiregrid.Transport.Protocol.JSON, do: :term, else: :encoded)
          ),
        text_frames: protocol == Wiregrid.Transport.Protocol.JSON,
        resume_token: request_info.resume_token,
        session_id: nil,
        next_resume_token: nil,
        frame_rate_limit: frame_rate_limit,
        frame_window_ms: frame_window_ms,
        frame_rate_opts: frame_rate_opts
      }

      {:cowboy_websocket, req, state, %{max_frame_size: frame_limit, idle_timeout: idle_timeout}}
    else
      _ -> reject(req, 401)
    end
  rescue
    _ -> reject(req, 400)
  end

  def init(req, _opts), do: reject(req, 400)

  def websocket_init(state) do
    result =
      case state.resume_token do
        nil ->
          case Wiregrid.connect_resumable(
                 state.instance,
                 state.user_id,
                 self(),
                 state.connect_opts
               ) do
            {:ok, sid, token} ->
              empty = %{
                subscriptions: %{restored: 0, failed: 0},
                presence_watches: %{restored: 0, failed: 0},
                rooms: %{restored: 0, failed: 0}
              }

              {:ok, sid, token, empty}

            error ->
              error
          end

        token ->
          case Wiregrid.resume_session(
                 state.instance,
                 state.user_id,
                 self(),
                 token,
                 state.connect_opts
               ) do
            {:ok, %{session_id: sid, resume_token: next, restored: restored}} ->
              {:ok, sid, next, restored}

            error ->
              error
          end
      end

    case result do
      {:ok, sid, token, restored} ->
        next = %{state | session_id: sid, next_resume_token: token}
        reply(next, {:ready, %{session_id: sid, resume_token: token, restored: restored}})

      {:error, reason} ->
        stop_with(state, {:connect_failed, reason})
    end
  end

  def websocket_handle({:binary, data}, state) when byte_size(data) <= state.max_frame_size do
    case frame_admission(state) do
      :ok ->
        case safe_decode(state.protocol, data) do
          {:ok, {:request, request_id, command}} -> command_reply(state, request_id, command)
          {:ok, command} -> command_reply(state, nil, command)
          {:error, reason} -> reply(state, {:error, nil, reason})
        end

      {:error, :rate_limited} ->
        reply(state, {:error, nil, :rate_limited})

      {:error, _} ->
        stop_with(state, :rate_limit_unavailable)
    end
  end

  def websocket_handle({:text, data}, %{text_frames: true} = state),
    do: websocket_handle({:binary, data}, state)

  def websocket_handle({:binary, _data}, state), do: stop_with(state, :frame_too_large)
  def websocket_handle({:ping, data}, state), do: {:reply, {:pong, data}, state}
  def websocket_handle(:ping, state), do: {:reply, :pong, state}

  def websocket_handle({:text, _}, state),
    do: reply(state, {:error, nil, :binary_frames_required})

  def websocket_handle(_frame, state), do: {:ok, state}

  def websocket_info({:"$wiregrid", envelope}, state) when is_map(envelope) do
    case safe_encode(state.protocol, {:event, envelope}, state.max_frame_size) do
      {:ok, binary} ->
        if state.ack_strategy == :transport do
          _ = Wiregrid.ack(state.instance, envelope.session_id, envelope.delivery_id)
        end

        {:reply, {:binary, binary}, state}

      {:error, _} ->
        stop_with(state, :outbound_encode_failed)
    end
  end

  def websocket_info(_info, state), do: {:ok, state}

  def terminate(_reason, _req, %{session_id: sid, instance: instance}) when is_binary(sid) do
    _ = Wiregrid.disconnect(instance, sid, :transport_closed)
    :ok
  end

  def terminate(_reason, _req, _state), do: :ok

  defp command_reply(state, request_id, command) do
    result = dispatch_command(state, command)
    reply(state, {:response, request_id, result})
  end

  defp dispatch_command(state, command) do
    Wiregrid.Transport.Command.dispatch(
      state.instance,
      state.session_id,
      state.user_id,
      command,
      state.command_handler
    )
  end

  defp frame_admission(%{session_id: sid} = state) when is_binary(sid) do
    case Wiregrid.rate_limit(
           state.instance,
           :websocket_frame,
           sid,
           state.frame_rate_limit,
           state.frame_window_ms,
           Map.get(state, :frame_rate_opts, [])
         ) do
      {:ok, _remaining} -> :ok
      {:error, :rate_limited} = error -> error
      {:error, _} = error -> error
    end
  end

  defp frame_admission(_state), do: {:error, :session_unavailable}

  defp reply(state, term) do
    case safe_encode(state.protocol, term, state.max_frame_size) do
      {:ok, binary} -> {:reply, {:binary, binary}, state}
      {:error, _} -> stop_with(state, :encode_failed)
    end
  end

  defp stop_with(state, reason) do
    case safe_encode(state.protocol, {:error, nil, reason}, state.max_frame_size) do
      {:ok, binary} ->
        {:reply, [{:binary, binary}, {:close, 1008, "wiregrid protocol error"}], state}

      _ ->
        {:stop, state}
    end
  end

  defp safe_decode(protocol, data) do
    try do
      case protocol.decode(data) do
        {:ok, value} -> {:ok, value}
        {:error, _} = error -> error
        _ -> {:error, :invalid_protocol_result}
      end
    rescue
      _ -> {:error, :protocol_failed}
    end
  end

  defp safe_encode(protocol, term, max_bytes) do
    try do
      case protocol.encode(term) do
        {:ok, binary} when is_binary(binary) and byte_size(binary) <= max_bytes -> {:ok, binary}
        {:ok, binary} when is_binary(binary) -> {:error, :frame_too_large}
        {:error, _} = error -> error
        _ -> {:error, :invalid_protocol_result}
      end
    rescue
      _ -> {:error, :protocol_failed}
    end
  end

  defp request_info(req) do
    authorization = header(req, "authorization", 4_096)
    resume = header(req, "x-wiregrid-resume", 512)
    origin = header(req, "origin", 2_048)
    path = req_call(:path, [req], <<>>)
    peer = req_call(:peer, [req], {{0, 0, 0, 0}, 0})

    if is_binary(path) and byte_size(path) <= 2_048 do
      {:ok,
       %{
         authorization: authorization,
         resume_token: resume,
         origin: origin,
         path: path,
         peer: peer
       }}
    else
      {:error, :invalid_path}
    end
  end

  defp header(req, name, max_bytes) do
    value = req_call(:header, [name, req], :undefined)

    cond do
      value in [:undefined, nil] -> nil
      is_binary(value) and byte_size(value) <= max_bytes -> value
      true -> :oversized
    end
  end

  defp authenticate(info, opts, instance) do
    cond do
      info.authorization == :oversized -> {:error, :authorization_header_too_large}
      info.resume_token == :oversized -> {:error, :resume_token_too_large}
      fun = Keyword.get(opts, :auth_fun) -> authenticate_fun(fun, info)
      auth = Keyword.get(opts, :auth) -> authenticate_hmac(auth, info.authorization, instance)
      true -> {:error, :authentication_required}
    end
  end

  defp authenticate_fun(fun, info) when is_function(fun, 1) do
    try do
      case fun.(info) do
        {:ok, user_id} -> {:ok, user_id}
        _ -> {:error, :authentication_failed}
      end
    rescue
      _ -> {:error, :authentication_failed}
    end
  end

  defp authenticate_fun(_, _), do: {:error, :invalid_auth_fun}

  defp authenticate_hmac({:hmac, keys, auth_opts}, authorization, instance)
       when is_binary(authorization) and is_list(auth_opts) do
    with :ok <- Wiregrid.Validation.bounded_list(auth_opts, 32),
         true <- Keyword.keyword?(auth_opts),
         verify_opts <-
           Keyword.put_new(
             auth_opts,
             :audience,
             Wiregrid.Transport.Auth.instance_audience(instance)
           ) do
      case authorization do
        "Bearer " <> token ->
          case Wiregrid.Transport.Auth.verify(token, keys, verify_opts) do
            {:ok, %{subject: user_id}} -> {:ok, user_id}
            _ -> {:error, :authentication_failed}
          end

        _ ->
          {:error, :authentication_failed}
      end
    else
      _ -> {:error, :authentication_failed}
    end
  end

  defp authenticate_hmac(_, _, _), do: {:error, :authentication_failed}

  defp origin_allowed(nil, _allowlist), do: :ok
  defp origin_allowed(:oversized, _allowlist), do: {:error, :origin_too_large}
  defp origin_allowed(_origin, []), do: {:error, :origin_not_allowed}

  defp origin_allowed(origin, allowlist) when is_list(allowlist) do
    with :ok <- Wiregrid.Validation.bounded_list(allowlist, 128),
         true <- Enum.any?(allowlist, &origin_match?(origin, &1)) do
      :ok
    else
      {:error, _} -> {:error, :invalid_origin_allowlist}
      false -> {:error, :origin_not_allowed}
    end
  end

  defp origin_allowed(_, _), do: {:error, :invalid_origin_allowlist}

  defp origin_match?(origin, allowed) when is_binary(allowed), do: origin == allowed
  defp origin_match?(_origin, _allowed), do: false

  defp preauth_rate_limit(instance, peer, opts) do
    limit = Keyword.get(opts, :auth_rate_limit, 30)
    window = Keyword.get(opts, :auth_window_ms, 60_000)

    key =
      case peer do
        {ip, _port} -> ip
        other -> other
      end

    with {:ok, limit} <- bounded_rate(limit, 1, 100_000, :invalid_auth_rate_limit),
         {:ok, window} <- bounded_rate(window, 100, 3_600_000, :invalid_auth_window),
         {:ok, policy_opts} <- rate_policy_opts(opts, :auth, limit) do
      case Wiregrid.rate_limit(instance, :websocket_auth, key, limit, window, policy_opts) do
        {:ok, _} -> :ok
        {:error, :rate_limited} -> {:error, :rate_limited}
        {:error, _} = error -> error
      end
    end
  end

  defp transport_authorization(%{authorizer: Wiregrid.Authorizer.AllowAll}, opts) do
    case Keyword.get(opts, :allow_permissive_authorizer, false) do
      true -> :ok
      false -> {:error, :permissive_authorizer_not_allowed}
      _ -> {:error, :invalid_permissive_authorizer_option}
    end
  end

  defp transport_authorization(%{authorizer: module}, _opts) when is_atom(module), do: :ok
  defp transport_authorization(_cfg, _opts), do: {:error, :invalid_authorizer}

  defp protocol(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :decode, 1) and
         function_exported?(module, :encode, 1),
       do: {:ok, module},
       else: {:error, :invalid_protocol}
  end

  defp protocol(_), do: {:error, :invalid_protocol}

  defp frame_limit(value, cfg) when is_integer(value) and value > 0,
    do: {:ok, min(value, cfg.max_websocket_frame_bytes)}

  defp frame_limit(_, _), do: {:error, :invalid_frame_limit}

  defp positive_timeout(value) when is_integer(value) and value in 1_000..3_600_000,
    do: {:ok, value}

  defp positive_timeout(_), do: {:error, :invalid_idle_timeout}

  defp bounded_rate(value, min, max, _error)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp bounded_rate(_value, _min, _max, error), do: {:error, error}

  defp rate_policy_opts(opts, prefix, limit) do
    policy_key = if prefix == :auth, do: :auth_rate_policy, else: :frame_rate_policy
    burst_key = if prefix == :auth, do: :auth_rate_burst, else: :frame_rate_burst
    default_policy = if prefix == :frame, do: :token_bucket, else: :fixed_window

    case Keyword.get(opts, policy_key, default_policy) do
      :fixed_window ->
        {:ok, [policy: :fixed_window]}

      :token_bucket ->
        burst = Keyword.get(opts, burst_key, limit)

        if is_integer(burst) and burst > 0 and burst <= 1_000_000,
          do: {:ok, [policy: :token_bucket, burst: burst]},
          else: {:error, :invalid_rate_burst}

      _ ->
        {:error, :invalid_rate_policy}
    end
  end

  defp ack_strategy(value) when value in [:transport, :client], do: {:ok, value}
  defp ack_strategy(_), do: {:error, :invalid_ack_strategy}

  defp connect_opts(opts) do
    allowed = [:metadata, :status, :presence_metadata]

    case Wiregrid.Validation.keyword_opts(opts, allowed) do
      :ok -> {:ok, opts}
      error -> error
    end
  end

  defp req_call(function, args, default) do
    apply(:cowboy_req, function, args)
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  defp reject(req, status) do
    updated =
      req_call(
        :reply,
        [status, %{"content-type" => "text/plain"}, "wiregrid websocket rejected", req],
        req
      )

    {:ok, updated, %{}}
  end
end
