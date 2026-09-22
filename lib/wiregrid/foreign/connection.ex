defmodule Wiregrid.Foreign.Connection do
  @moduledoc false

  alias Wiregrid.Foreign.JSON
  alias Wiregrid.Foreign.Protocol, as: P
  alias Wiregrid.Foreign.Topic

  @kind_request 0
  @kind_response 1
  @kind_event 2

  def run(socket, instance, parent, opts) do
    Process.flag(:trap_exit, true)

    state = %{
      socket: socket,
      instance: instance,
      session_id: nil,
      user_id: nil,
      authenticate: opts.authenticate,
      idle_timeout_ms: opts.idle_timeout_ms,
      protocol_errors: 0,
      max_protocol_errors: opts.max_protocol_errors
    }

    try do
      {_result, final_state} = loop(state)

      if final_state.session_id,
        do: Wiregrid.disconnect(instance, final_state.session_id, :foreign_closed)

      :ok
    after
      :gen_tcp.close(socket)
      send(parent, {:connection_closed, self()})
    end
  end

  defp loop(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> receive_loop(state)
      {:error, _reason} -> {:ok, state}
    end
  end

  defp receive_loop(state) do
    receive do
      {:tcp, socket, frame} when socket == state.socket ->
        case P.decode(frame) do
          {:ok, %{kind: @kind_request} = request} ->
            case handle_request(request, state) do
              {:ok, next} -> loop(next)
              {:close, next} -> {:ok, next}
            end

          {:ok, _} ->
            protocol_error(state, 0, 0, "unexpected_frame_kind")

          {:error, reason} ->
            protocol_error(state, 0, 0, error_text(reason))
        end

      {:tcp_closed, socket} when socket == state.socket ->
        {:ok, state}

      {:tcp_error, socket, _reason} when socket == state.socket ->
        {:ok, state}

      {:"$wiregrid", envelope} ->
        case send_event(state.socket, envelope) do
          :ok -> loop(state)
          :error -> {:ok, state}
        end

      _ ->
        loop(state)
    after
      state.idle_timeout_ms -> {:ok, state}
    end
  end

  defp protocol_error(state, id, op, reason) do
    _ = send_error(state.socket, id, op, reason)
    next = %{state | protocol_errors: state.protocol_errors + 1}

    if next.protocol_errors >= state.max_protocol_errors do
      {:ok, next}
    else
      loop(next)
    end
  end

  defp handle_request(%{op: op, request_id: id, fields: fields}, state) do
    cond do
      op == P.op(:hello) ->
        hello(id, fields, state)

      is_nil(state.session_id) ->
        reply_error(id, op, "hello_required", state)

      op == P.op(:subscribe) ->
        subscribe(id, fields, state)

      op == P.op(:unsubscribe) ->
        unsubscribe(id, fields, state)

      op == P.op(:publish) ->
        publish(id, fields, state)

      op == P.op(:ack) ->
        ack(id, fields, state)

      op == P.op(:presence) ->
        presence(id, fields, state)

      op == P.op(:join_room) ->
        join_room(id, fields, state)

      op == P.op(:leave_room) ->
        leave_room(id, fields, state)

      op == P.op(:ping) ->
        reply_ok(id, op, [{P.field(:server_version), Wiregrid.version()}], state)

      op == P.op(:history) ->
        history(id, fields, state)

      true ->
        reply_error(id, op, "unknown_operation", state)
    end
  rescue
    _ -> reply_error(id, op, "invalid_request", state)
  catch
    _, _ -> reply_error(id, op, "request_failed", state)
  end

  defp hello(id, fields, %{session_id: nil} = state) do
    with {:ok, user_id} <- fetch_field(fields, P.field(:user_id)),
         :ok <- authenticate(state.authenticate, user_id, Map.get(fields, P.field(:auth_token))),
         {:ok, session_id} <- Wiregrid.connect(state.instance, user_id, self()) do
      next = %{state | session_id: session_id, user_id: user_id}

      reply_ok(
        id,
        P.op(:hello),
        [
          {P.field(:session_id), session_id},
          {P.field(:server_version), Wiregrid.version()}
        ],
        next
      )
    else
      {:error, reason} -> reply_error(id, P.op(:hello), error_text(reason), state)
    end
  end

  defp hello(id, _fields, state), do: reply_error(id, P.op(:hello), "already_connected", state)

  defp subscribe(id, fields, state) do
    with {:ok, topic} <- topic_field(fields, P.field(:topic)) do
      simple(
        id,
        P.op(:subscribe),
        Wiregrid.subscribe(state.instance, state.session_id, topic),
        state
      )
    else
      {:error, reason} -> reply_error(id, P.op(:subscribe), error_text(reason), state)
    end
  end

  defp unsubscribe(id, fields, state) do
    with {:ok, topic} <- topic_field(fields, P.field(:topic)) do
      simple(
        id,
        P.op(:unsubscribe),
        Wiregrid.unsubscribe(state.instance, state.session_id, topic),
        state
      )
    else
      {:error, reason} -> reply_error(id, P.op(:unsubscribe), error_text(reason), state)
    end
  end

  defp publish(id, fields, state) do
    with {:ok, topic} <- topic_field(fields, P.field(:topic)),
         {:ok, payload} <- fetch_field(fields, P.field(:payload)),
         {:ok, content_type} <-
           content_type(Map.get(fields, P.field(:content_type), "application/octet-stream")),
         {:ok, event} <- inbound_event(payload, content_type) do
      class = parse_class(Map.get(fields, P.field(:class), "durable"))

      case Wiregrid.publish(state.instance, topic, event,
             session_id: state.session_id,
             class: class,
             persist: class == :durable
           ) do
        {:ok, result} ->
          event_id = result |> Map.get(:event_id, "") |> to_string()
          reply_ok(id, P.op(:publish), [{P.field(:event_id), event_id}], state)

        {:error, reason} ->
          reply_error(id, P.op(:publish), error_text(reason), state)
      end
    else
      {:error, reason} -> reply_error(id, P.op(:publish), error_text(reason), state)
    end
  end

  defp ack(id, fields, state) do
    with {:ok, delivery_id} <- fetch_field(fields, P.field(:delivery_id)) do
      simple(id, P.op(:ack), Wiregrid.ack(state.instance, state.session_id, delivery_id), state)
    else
      {:error, reason} -> reply_error(id, P.op(:ack), error_text(reason), state)
    end
  end

  defp presence(id, fields, state) do
    with {:ok, status} <- fetch_field(fields, P.field(:status)) do
      simple(
        id,
        P.op(:presence),
        Wiregrid.set_presence(state.instance, state.session_id, parse_presence(status), %{}),
        state
      )
    else
      {:error, reason} -> reply_error(id, P.op(:presence), error_text(reason), state)
    end
  end

  defp join_room(id, fields, state) do
    with {:ok, room} <- room_field(fields) do
      simple(
        id,
        P.op(:join_room),
        Wiregrid.join_room(state.instance, room, state.session_id),
        state
      )
    else
      {:error, reason} -> reply_error(id, P.op(:join_room), error_text(reason), state)
    end
  end

  defp leave_room(id, fields, state) do
    with {:ok, room} <- room_field(fields) do
      simple(
        id,
        P.op(:leave_room),
        Wiregrid.leave_room(state.instance, room, state.session_id),
        state
      )
    else
      {:error, reason} -> reply_error(id, P.op(:leave_room), error_text(reason), state)
    end
  end

  defp history(id, fields, state) do
    with {:ok, topic} <- topic_field(fields, P.field(:topic)),
         {:ok, limit} <- limit_field(Map.get(fields, P.field(:limit))),
         {:ok, rows, next} <-
           Wiregrid.read_history(
             state.instance,
             state.session_id,
             topic,
             cursor_field(fields),
             limit
           ),
         {:ok, body} <- JSON.encode(%{"events" => rows}) do
      reply_ok(
        id,
        P.op(:history),
        [
          {P.field(:payload), body},
          {P.field(:cursor), next || ""},
          {P.field(:content_type), "application/json"}
        ],
        state
      )
    else
      {:error, reason} -> reply_error(id, P.op(:history), error_text(reason), state)
    end
  end

  defp simple(id, op, result, state) do
    case result do
      :ok -> reply_ok(id, op, [], state)
      {:ok, _} -> reply_ok(id, op, [], state)
      {:error, reason} -> reply_error(id, op, error_text(reason), state)
      _ -> reply_error(id, op, "unexpected_result", state)
    end
  end

  defp reply_ok(id, op, fields, state) do
    case send_frame(state.socket, @kind_response, op, id, [{P.field(:status), "ok"} | fields]) do
      :ok -> {:ok, state}
      :error -> {:close, state}
    end
  end

  defp reply_error(id, op, reason, state) do
    case send_error(state.socket, id, op, reason) do
      :ok -> {:ok, state}
      :error -> {:close, state}
    end
  end

  defp send_error(socket, id, op, reason) do
    send_frame(socket, @kind_response, op, id, [
      {P.field(:status), "error"},
      {P.field(:error), reason}
    ])
  end

  defp send_event(socket, envelope) do
    {payload, content_type} = outbound_event(Map.get(envelope, :event))

    fields = [
      {P.field(:topic), Topic.format(Map.get(envelope, :topic))},
      {P.field(:payload), payload},
      {P.field(:delivery_id), to_string(Map.get(envelope, :delivery_id, ""))},
      {P.field(:event_id), to_string(Map.get(envelope, :event_id, ""))},
      {P.field(:content_type), content_type}
    ]

    send_frame(socket, @kind_event, P.op(:event), 0, fields)
  end

  defp send_frame(socket, kind, op, id, fields) do
    case P.encode(kind, op, id, fields) do
      {:ok, frame} ->
        case :gen_tcp.send(socket, frame) do
          :ok -> :ok
          {:error, _} -> :error
        end

      _ ->
        :error
    end
  end

  defp inbound_event(payload, content_type) do
    if json?(content_type) do
      case JSON.decode_event(payload) do
        {:ok, event} -> {:ok, event}
        {:error, _reason} -> {:error, :invalid_event}
      end
    else
      {:ok, %{type: :foreign, payload: payload, content_type: content_type}}
    end
  end

  defp outbound_event(%{type: :foreign, payload: payload, content_type: content_type})
       when is_binary(payload) and is_binary(content_type) do
    {payload, content_type}
  end

  defp outbound_event(event) do
    case JSON.encode(event) do
      {:ok, json} -> {json, "application/json"}
      _ -> {~s({"type":"unsupported"}), "application/json"}
    end
  end

  defp authenticate(fun, user_id, token) do
    case fun.(user_id, token) do
      :ok -> :ok
      true -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :authentication_failed}
    end
  rescue
    _ -> {:error, :authentication_failed}
  catch
    _, _ -> {:error, :authentication_failed}
  end

  defp fetch_field(fields, tag) do
    case Map.fetch(fields, tag) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, :missing_field}
    end
  end

  defp topic_field(fields, tag) do
    with {:ok, text} <- fetch_field(fields, tag) do
      Topic.parse(text)
    end
  end

  defp room_field(fields) do
    with {:ok, room} <- fetch_field(fields, P.field(:room)) do
      if byte_size(room) in 1..256 and String.valid?(room) and control_free?(room) do
        {:ok, room}
      else
        {:error, :invalid_room}
      end
    end
  end

  defp content_type(value) when is_binary(value) and byte_size(value) in 1..128 do
    if String.valid?(value) and control_free?(value),
      do: {:ok, value},
      else: {:error, :invalid_content_type}
  end

  defp content_type(_), do: {:error, :invalid_content_type}

  defp json?(value) do
    down = String.downcase(value)
    down == "application/json" or String.starts_with?(down, "application/json;")
  end

  defp cursor_field(fields) do
    case Map.get(fields, P.field(:cursor)) do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> value
    end
  end

  defp limit_field(nil), do: {:ok, 50}

  defp limit_field(value) when is_binary(value) and byte_size(value) in 1..3 do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..100 -> {:ok, limit}
      _ -> {:error, :invalid_limit}
    end
  end

  defp limit_field(_), do: {:error, :invalid_limit}

  defp control_free?(<<>>), do: true
  defp control_free?(<<byte, _rest::binary>>) when byte < 32 or byte == 127, do: false
  defp control_free?(<<_byte, rest::binary>>), do: control_free?(rest)

  defp parse_class("ephemeral"), do: :ephemeral
  defp parse_class(_), do: :durable
  defp parse_presence("online"), do: :online
  defp parse_presence("idle"), do: :idle
  defp parse_presence("dnd"), do: :dnd
  defp parse_presence("invisible"), do: :invisible
  defp parse_presence("offline"), do: :offline
  defp parse_presence(value), do: {:custom, binary_part(value, 0, min(byte_size(value), 128))}
  defp error_text(value) when is_atom(value), do: Atom.to_string(value)

  defp error_text(value) when is_binary(value),
    do: binary_part(value, 0, min(byte_size(value), 256))

  defp error_text(value), do: inspect(value, limit: 8, printable_limit: 256)
end
