defmodule Wiregrid.Transport.Protocol.JSON do
  @moduledoc """
  UTF-8 JSON websocket protocol for browser clients.

  Frames are JSON objects. Cowboy should accept text frames when this module
  is selected. Topics use the same text form as the foreign gateway, so a
  browser subscribed to `general` is on `{:channel, "general"}`.
  """

  @behaviour Wiregrid.Transport.Protocol

  alias Wiregrid.Foreign.JSON
  alias Wiregrid.Foreign.Topic

  @impl true
  def decode(binary) when is_binary(binary) do
    with {:ok, message} when is_map(message) <- JSON.decode(binary),
         {:ok, command} <- command(message),
         {:ok, request_id} <- request_id(message) do
      if request_id, do: {:ok, {:request, request_id, command}}, else: {:ok, command}
    else
      {:ok, _} -> {:error, :invalid_json_command}
      {:error, _} = error -> error
    end
  end

  def decode(_), do: {:error, :invalid_json_command}

  @impl true
  def encode(term) do
    with {:ok, normalized} <- normalize(term) do
      JSON.encode(normalized)
    end
  end

  defp command(%{"op" => "subscribe", "topic" => topic}) do
    with {:ok, topic} <- Topic.parse(topic), do: {:ok, {:subscribe, topic}}
  end

  defp command(%{"op" => "unsubscribe", "topic" => topic}) do
    with {:ok, topic} <- Topic.parse(topic), do: {:ok, {:unsubscribe, topic}}
  end

  defp command(%{"op" => "publish", "topic" => topic, "event" => event} = message)
       when is_map(event) do
    with {:ok, topic} <- Topic.parse(topic),
         {:ok, opts} <- publish_opts(message) do
      {:ok, {:publish, topic, JSON.atomize_event(event), opts}}
    end
  end

  defp command(%{"op" => "ack", "delivery_id" => delivery_id}) when is_binary(delivery_id) do
    {:ok, {:ack, delivery_id}}
  end

  defp command(%{"op" => "presence", "status" => status}) when is_binary(status) do
    {:ok, {:presence, presence(status)}}
  end

  defp command(%{"op" => "join_room", "room" => room}) when is_binary(room) do
    {:ok, {:join_room, room}}
  end

  defp command(%{"op" => "leave_room", "room" => room}) when is_binary(room) do
    {:ok, {:leave_room, room}}
  end

  defp command(%{"op" => "history", "topic" => topic} = message) do
    with {:ok, topic} <- Topic.parse(topic),
         {:ok, limit} <- history_limit(Map.get(message, "limit", 50)),
         {:ok, cursor} <- history_cursor(Map.get(message, "cursor")) do
      {:ok, {:history, topic, [cursor: cursor, limit: limit]}}
    end
  end

  defp command(%{"op" => "ping", "nonce" => nonce}) when is_binary(nonce) or is_integer(nonce) do
    {:ok, {:ping, nonce}}
  end

  defp command(%{"op" => _op}), do: {:error, :unknown_command}
  defp command(_), do: {:error, :invalid_json_command}

  defp publish_opts(message) do
    class = Map.get(message, "class", "durable")
    persist = Map.get(message, "persist", class != "ephemeral")

    cond do
      class not in ["durable", "ephemeral"] ->
        {:error, :invalid_event_class}

      not is_boolean(persist) ->
        {:error, :invalid_persist_option}

      true ->
        {:ok, [class: if(class == "ephemeral", do: :ephemeral, else: :durable), persist: persist]}
    end
  end

  defp history_limit(limit) when is_integer(limit) and limit in 1..100, do: {:ok, limit}
  defp history_limit(_), do: {:error, :invalid_limit}

  defp history_cursor(nil), do: {:ok, nil}
  defp history_cursor(cursor) when is_binary(cursor), do: {:ok, cursor}
  defp history_cursor(_), do: {:error, :invalid_cursor}

  defp presence("online"), do: :online
  defp presence("idle"), do: :idle
  defp presence("dnd"), do: :dnd
  defp presence("invisible"), do: :invisible
  defp presence("offline"), do: :offline
  defp presence(value), do: {:custom, binary_part(value, 0, min(byte_size(value), 128))}

  defp request_id(%{"id" => id}) when is_integer(id) and id in 0..4_294_967_295, do: {:ok, id}
  defp request_id(%{"id" => nil}), do: {:ok, nil}
  defp request_id(%{"id" => _}), do: {:error, :invalid_request_id}
  defp request_id(_), do: {:ok, nil}

  defp normalize({:ready, map}) do
    {:ok,
     %{
       "type" => "ready",
       "session_id" => map.session_id,
       "resume_token" => map.resume_token,
       "restored" => map.restored
     }}
  end

  defp normalize({:event, envelope}) do
    {:ok,
     %{
       "type" => "event",
       "topic" => Topic.format(envelope.topic),
       "delivery_id" => envelope.delivery_id,
       "class" => Atom.to_string(envelope.class),
       "event" => Map.get(envelope, :event) || Map.get(envelope, :payload)
     }}
  end

  defp normalize({:response, id, :ok}) do
    {:ok, %{"type" => "response", "id" => id, "ok" => true}}
  end

  defp normalize({:response, id, {:ok, rows, cursor}})
       when is_list(rows) and (is_nil(cursor) or is_binary(cursor)) do
    {:ok, %{"type" => "response", "id" => id, "ok" => true, "events" => rows, "cursor" => cursor}}
  end

  defp normalize({:response, id, {:ok, value}}) do
    {:ok, %{"type" => "response", "id" => id, "ok" => true, "value" => value}}
  end

  defp normalize({:response, id, {:error, reason}}) do
    {:ok, %{"type" => "response", "id" => id, "ok" => false, "error" => reason_text(reason)}}
  end

  defp normalize({:response, id, {:pong, nonce}}) do
    {:ok, %{"type" => "response", "id" => id, "ok" => true, "pong" => nonce}}
  end

  defp normalize({:response, id, other}) do
    {:ok,
     %{
       "type" => "response",
       "id" => id,
       "ok" => true,
       "value" => inspect(other, limit: 8, printable_limit: 200)
     }}
  end

  defp normalize({:error, id, reason}) do
    {:ok, %{"type" => "error", "id" => id, "error" => reason_text(reason)}}
  end

  defp normalize(_), do: {:error, :invalid_protocol_term}

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason, limit: 6, printable_limit: 120)
end
