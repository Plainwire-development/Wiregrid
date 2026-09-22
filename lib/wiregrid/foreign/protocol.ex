defmodule Wiregrid.Foreign.Protocol do
  @moduledoc false

  @version 1
  @max_fields 32
  @max_field_bytes 1_048_576
  @max_frame_bytes 2_097_152

  @kind_request 0
  @kind_response 1
  @kind_event 2

  @ops %{
    hello: 1,
    subscribe: 2,
    unsubscribe: 3,
    publish: 4,
    ack: 5,
    presence: 6,
    join_room: 7,
    leave_room: 8,
    ping: 9,
    history: 10,
    event: 64
  }

  @fields %{
    instance: 1,
    user_id: 2,
    topic: 3,
    payload: 4,
    content_type: 5,
    delivery_id: 6,
    status: 7,
    room: 8,
    event_id: 9,
    error: 10,
    class: 11,
    server_version: 12,
    session_id: 13,
    auth_token: 14,
    cursor: 15,
    limit: 16
  }

  def version, do: @version
  def max_frame_bytes, do: @max_frame_bytes
  def op(name), do: Map.fetch!(@ops, name)
  def field(name), do: Map.fetch!(@fields, name)

  def encode(kind, op, request_id, fields)
      when kind in [@kind_request, @kind_response, @kind_event] and is_integer(op) and
             op in 0..255 and is_integer(request_id) and request_id in 0..4_294_967_295 and
             is_list(fields) do
    with true <- length(fields) <= @max_fields,
         {:ok, body} <- encode_fields(fields, <<>>, MapSet.new()),
         frame <- <<@version, kind, op, request_id::unsigned-big-32, body::binary>>,
         true <- byte_size(frame) <= @max_frame_bytes do
      {:ok, frame}
    else
      false -> {:error, :frame_too_large}
      {:error, _} = error -> error
    end
  end

  def encode(_, _, _, _), do: {:error, :invalid_frame}

  def decode(frame) when is_binary(frame) and byte_size(frame) <= @max_frame_bytes do
    case frame do
      <<@version, kind, op, request_id::unsigned-big-32, rest::binary>>
      when kind in [@kind_request, @kind_response, @kind_event] ->
        with {:ok, fields} <- decode_fields(rest, %{}, 0) do
          {:ok, %{version: @version, kind: kind, op: op, request_id: request_id, fields: fields}}
        end

      <<version, _::binary>> when version != @version ->
        {:error, {:unsupported_protocol, version}}

      _ ->
        {:error, :invalid_frame}
    end
  end

  def decode(_), do: {:error, :frame_too_large}

  defp encode_fields([], acc, _seen), do: {:ok, acc}

  defp encode_fields([{tag, value} | rest], acc, seen)
       when is_integer(tag) and tag in 1..255 and is_binary(value) and
              byte_size(value) <= @max_field_bytes do
    if MapSet.member?(seen, tag) do
      {:error, {:duplicate_field, tag}}
    else
      encoded = <<tag, byte_size(value)::unsigned-big-32, value::binary>>
      encode_fields(rest, <<acc::binary, encoded::binary>>, MapSet.put(seen, tag))
    end
  end

  defp encode_fields(_, _, _), do: {:error, :invalid_field}

  defp decode_fields(<<>>, acc, _count), do: {:ok, acc}
  defp decode_fields(_rest, _acc, count) when count >= @max_fields, do: {:error, :too_many_fields}

  defp decode_fields(<<tag, len::unsigned-big-32, rest::binary>>, acc, count)
       when len <= @max_field_bytes and byte_size(rest) >= len do
    if Map.has_key?(acc, tag) do
      {:error, {:duplicate_field, tag}}
    else
      <<value::binary-size(^len), tail::binary>> = rest
      decode_fields(tail, Map.put(acc, tag, value), count + 1)
    end
  end

  defp decode_fields(_, _, _), do: {:error, :invalid_tlv}
end
