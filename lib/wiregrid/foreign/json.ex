defmodule Wiregrid.Foreign.JSON do
  @moduledoc false

  @max_depth 16
  @max_nodes 8_192
  @js_max 9_007_199_254_740_991

  @event_keys %{
    "type" => :type,
    "body" => :body,
    "attachments" => :attachments,
    "mentions" => :mentions,
    "metadata" => :metadata,
    "nonce" => :nonce,
    "reply_to" => :reply_to,
    "message_id" => :message_id,
    "reason" => :reason,
    "reaction" => :reaction,
    "active" => :active
  }

  @event_types %{
    "message" => :message,
    "message_edit" => :message_edit,
    "message_delete" => :message_delete,
    "reaction_add" => :reaction_add,
    "reaction_remove" => :reaction_remove,
    "read" => :read,
    "typing" => :typing,
    "foreign" => :foreign
  }

  def encode(term, max_bytes \\ 1_048_576) when is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, iodata, _nodes} <- encode_value(term, 0, @max_nodes) do
      binary = IO.iodata_to_binary(iodata)
      if byte_size(binary) <= max_bytes, do: {:ok, binary}, else: {:error, :json_too_large}
    end
  end

  def decode(binary, max_bytes \\ 1_048_576)

  def decode(binary, max_bytes)
      when is_binary(binary) and is_integer(max_bytes) and byte_size(binary) <= max_bytes do
    with true <- String.valid?(binary),
         {:ok, pos} <- skip_ws(binary, 0),
         {:ok, value, pos, _nodes} <- parse_value(binary, pos, 0, @max_nodes),
         {:ok, pos} <- skip_ws(binary, pos),
         true <- pos == byte_size(binary) do
      {:ok, value}
    else
      false -> {:error, :invalid_json}
      {:error, _} = error -> error
    end
  end

  def decode(binary, max_bytes) when is_binary(binary) and byte_size(binary) > max_bytes,
    do: {:error, :json_too_large}

  def decode(_, _), do: {:error, :invalid_json}

  def decode_event(binary) when is_binary(binary) do
    case decode(binary) do
      {:ok, map} when is_map(map) -> {:ok, atomize_event(map)}
      {:ok, _} -> {:error, :invalid_json_event}
      {:error, _} = error -> error
    end
  end

  def atomize_event(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      case Map.fetch(@event_keys, key) do
        {:ok, :type} -> {:type, Map.get(@event_types, value, value)}
        {:ok, atom} -> {atom, value}
        :error -> {key, value}
      end
    end)
  end

  defp encode_value(_value, depth, nodes) when depth > @max_depth or nodes <= 0,
    do: {:error, :json_too_complex}

  defp encode_value(nil, _depth, nodes), do: {:ok, "null", nodes - 1}
  defp encode_value(false, _depth, nodes), do: {:ok, "false", nodes - 1}
  defp encode_value(true, _depth, nodes), do: {:ok, "true", nodes - 1}

  defp encode_value(value, _depth, nodes) when is_integer(value) do
    if value >= -@js_max and value <= @js_max do
      {:ok, Integer.to_string(value), nodes - 1}
    else
      {:error, :json_number_out_of_range}
    end
  end

  defp encode_value(value, _depth, nodes) when is_float(value) do
    if finite_float?(value) do
      {:ok, :erlang.float_to_binary(value, [:short]), nodes - 1}
    else
      {:error, :json_number_out_of_range}
    end
  end

  defp encode_value(value, _depth, nodes) when is_atom(value),
    do: encode_string(Atom.to_string(value), nodes)

  defp encode_value(value, _depth, nodes) when is_binary(value), do: encode_string(value, nodes)

  defp encode_value(value, depth, nodes) when is_list(value) do
    encode_list(value, depth + 1, nodes - 1, [])
  end

  defp encode_value(value, depth, nodes) when is_map(value) do
    with {:ok, pairs} <- map_pairs(value) do
      encode_object(Enum.sort_by(pairs, &elem(&1, 0)), depth + 1, nodes - 1, [])
    end
  end

  defp encode_value(_, _, _), do: {:error, :json_unsupported}

  defp encode_list([], _depth, nodes, acc),
    do: {:ok, ["[", Enum.intersperse(Enum.reverse(acc), ","), "]"], nodes}

  defp encode_list([head | tail], depth, nodes, acc) do
    with {:ok, encoded, nodes} <- encode_value(head, depth, nodes) do
      encode_list(tail, depth, nodes, [encoded | acc])
    end
  end

  defp encode_object([], _depth, nodes, acc),
    do: {:ok, ["{", Enum.intersperse(Enum.reverse(acc), ","), "}"], nodes}

  defp encode_object([{key, value} | tail], depth, nodes, acc) do
    with {:ok, encoded_key, nodes} <- encode_string(key, nodes),
         {:ok, encoded_value, nodes} <- encode_value(value, depth, nodes) do
      encode_object(tail, depth, nodes, [[encoded_key, ":", encoded_value] | acc])
    end
  end

  defp map_pairs(map) do
    Enum.reduce_while(map, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case key_string(key) do
        {:ok, string} -> {:cont, {:ok, [{string, value} | acc]}}
        :error -> {:halt, {:error, :json_unsupported}}
      end
    end)
  end

  defp key_string(key) when is_binary(key), do: {:ok, key}
  defp key_string(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp key_string(_key), do: :error

  defp encode_string(value, nodes) do
    if String.valid?(value) do
      {:ok, [?", escape(value), ?"], nodes - 1}
    else
      {:error, :invalid_utf8}
    end
  end

  defp escape(value) do
    escape(value, [])
  end

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])

  defp escape(<<byte, rest::binary>>, acc) when byte < 32,
    do: escape(rest, [escape_unicode(byte) | acc])

  defp escape(<<char::utf8, rest::binary>>, acc), do: escape(rest, [<<char::utf8>> | acc])

  defp escape_unicode(byte) do
    hex = byte |> Integer.to_string(16) |> String.pad_leading(4, "0")
    "\\u" <> hex
  end

  defp finite_float?(value) do
    value == value and value < 1.0e308 and value > -1.0e308
  end

  defp parse_value(_bin, _pos, depth, nodes) when depth > @max_depth or nodes <= 0,
    do: {:error, :json_too_complex}

  defp parse_value(bin, pos, depth, nodes) do
    case bin do
      <<_head::binary-size(^pos), "null", _rest::binary>> ->
        {:ok, nil, pos + 4, nodes - 1}

      <<_head::binary-size(^pos), "true", _rest::binary>> ->
        {:ok, true, pos + 4, nodes - 1}

      <<_head::binary-size(^pos), "false", _rest::binary>> ->
        {:ok, false, pos + 5, nodes - 1}

      <<_head::binary-size(^pos), "\"", _rest::binary>> ->
        parse_string(bin, pos + 1, nodes - 1, [])

      <<_head::binary-size(^pos), "[", _rest::binary>> ->
        parse_array(bin, pos + 1, depth + 1, nodes - 1, [])

      <<_head::binary-size(^pos), "{", _rest::binary>> ->
        parse_object(bin, pos + 1, depth + 1, nodes - 1, %{})

      <<_head::binary-size(^pos), byte, _rest::binary>> when byte == ?- or byte in ?0..?9 ->
        parse_number(bin, pos, nodes - 1)

      _ ->
        {:error, :invalid_json}
    end
  end

  defp parse_array(bin, pos, depth, nodes, acc) do
    with {:ok, pos} <- skip_ws(bin, pos) do
      cond do
        match?(<<_head::binary-size(^pos), "]", _rest::binary>>, bin) ->
          {:ok, Enum.reverse(acc), pos + 1, nodes}

        acc != [] ->
          case bin do
            <<_head::binary-size(^pos), ",", rest_pos::binary>> ->
              _ = rest_pos

              with {:ok, pos} <- skip_ws(bin, pos + 1),
                   {:ok, value, pos, nodes} <- parse_value(bin, pos, depth, nodes) do
                parse_array(bin, pos, depth, nodes, [value | acc])
              end

            _ ->
              {:error, :invalid_json}
          end

        true ->
          with {:ok, value, pos, nodes} <- parse_value(bin, pos, depth, nodes) do
            parse_array(bin, pos, depth, nodes, [value | acc])
          end
      end
    end
  end

  defp parse_object(bin, pos, depth, nodes, acc) do
    with {:ok, pos} <- skip_ws(bin, pos) do
      cond do
        match?(<<_head::binary-size(^pos), "}", _rest::binary>>, bin) ->
          {:ok, acc, pos + 1, nodes}

        map_size(acc) > 0 ->
          if match?(<<_head::binary-size(^pos), ",", _rest::binary>>, bin) do
            parse_object_entry(bin, pos + 1, depth, nodes, acc)
          else
            {:error, :invalid_json}
          end

        true ->
          parse_object_entry(bin, pos, depth, nodes, acc)
      end
    end
  end

  defp parse_object_entry(bin, pos, depth, nodes, acc) do
    with {:ok, pos} <- skip_ws(bin, pos),
         {:ok, key, pos, nodes} <- parse_value(bin, pos, depth, nodes),
         true <- is_binary(key),
         false <- Map.has_key?(acc, key),
         {:ok, pos} <- skip_ws(bin, pos),
         true <- match?(<<_head::binary-size(^pos), ":", _rest::binary>>, bin),
         {:ok, pos} <- skip_ws(bin, pos + 1),
         {:ok, value, pos, nodes} <- parse_value(bin, pos, depth, nodes) do
      parse_object(bin, pos, depth, nodes, Map.put(acc, key, value))
    else
      false -> {:error, :invalid_json}
      true -> {:error, :duplicate_json_key}
      {:error, _} = error -> error
    end
  end

  defp parse_string(bin, pos, nodes, acc) do
    case :binary.match(bin, ["\\", "\""], scope: {pos, byte_size(bin) - pos}) do
      :nomatch ->
        {:error, :invalid_json}

      {index, 1} ->
        chunk = binary_part(bin, pos, index - pos)

        cond do
          not String.valid?(chunk) or has_control?(chunk) ->
            {:error, :invalid_json}

          binary_part(bin, index, 1) == "\"" ->
            {:ok, IO.iodata_to_binary([Enum.reverse(acc), chunk]), index + 1, nodes}

          true ->
            parse_escape(bin, index + 1, nodes, [chunk | acc])
        end
    end
  end

  defp parse_escape(bin, pos, nodes, acc) do
    case bin do
      <<_head::binary-size(^pos), "\"", _rest::binary>> ->
        parse_string(bin, pos + 1, nodes, ["\"" | acc])

      <<_head::binary-size(^pos), "\\", _rest::binary>> ->
        parse_string(bin, pos + 1, nodes, ["\\" | acc])

      <<_head::binary-size(^pos), "/", _rest::binary>> ->
        parse_string(bin, pos + 1, nodes, ["/" | acc])

      <<_head::binary-size(^pos), "b", _rest::binary>> ->
        parse_string(bin, pos + 1, nodes, ["\b" | acc])

      <<_head::binary-size(^pos), "f", _rest::binary>> ->
        parse_string(bin, pos + 1, nodes, ["\f" | acc])

      <<_head::binary-size(^pos), "n", _rest::binary>> ->
        parse_string(bin, pos + 1, nodes, ["\n" | acc])

      <<_head::binary-size(^pos), "r", _rest::binary>> ->
        parse_string(bin, pos + 1, nodes, ["\r" | acc])

      <<_head::binary-size(^pos), "t", _rest::binary>> ->
        parse_string(bin, pos + 1, nodes, ["\t" | acc])

      <<_head::binary-size(^pos), "u", hex::binary-size(4), _rest::binary>> ->
        parse_unicode(bin, pos + 5, nodes, acc, hex)

      _ ->
        {:error, :invalid_json}
    end
  end

  defp parse_unicode(bin, pos, nodes, acc, hex) do
    case hex_codepoint(hex) do
      {:ok, high} when high in 0xD800..0xDBFF ->
        case bin do
          <<_head::binary-size(^pos), "\\u", low_hex::binary-size(4), _rest::binary>> ->
            with {:ok, low} when low in 0xDC00..0xDFFF <- hex_codepoint(low_hex) do
              codepoint = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
              parse_string(bin, pos + 6, nodes, [<<codepoint::utf8>> | acc])
            else
              _ -> {:error, :invalid_json}
            end

          _ ->
            {:error, :invalid_json}
        end

      {:ok, code} when code in 0xDC00..0xDFFF ->
        {:error, :invalid_json}

      {:ok, code} ->
        parse_string(bin, pos, nodes, [<<code::utf8>> | acc])

      :error ->
        {:error, :invalid_json}
    end
  end

  defp hex_codepoint(hex) do
    case Integer.parse(hex, 16) do
      {code, ""} when byte_size(hex) == 4 -> {:ok, code}
      _ -> :error
    end
  end

  defp parse_number(bin, pos, nodes) do
    start = pos
    size = byte_size(bin)

    {pos, negative?} =
      if pos < size and :binary.at(bin, pos) == ?-, do: {pos + 1, true}, else: {pos, false}

    {pos, digits} = take_digits(bin, pos)

    cond do
      digits == 0 ->
        {:error, :invalid_json}

      digits > 1 and :binary.at(bin, start + if(negative?, do: 1, else: 0)) == ?0 ->
        {:error, :invalid_json}

      true ->
        {pos, float?} = take_fraction_and_exponent(bin, pos)

        token = binary_part(bin, start, pos - start)

        parsed =
          if float? do
            case Float.parse(token) do
              {number, ""} -> if finite_float?(number), do: {:ok, number}, else: :error
              _ -> :error
            end
          else
            case Integer.parse(token) do
              {number, ""} when number >= -@js_max and number <= @js_max -> {:ok, number}
              _ -> :error
            end
          end

        case parsed do
          {:ok, number} -> {:ok, number, pos, nodes}
          :error -> {:error, :invalid_json}
        end
    end
  end

  defp take_fraction_and_exponent(bin, pos) do
    size = byte_size(bin)

    {pos, float?} =
      if pos < size and :binary.at(bin, pos) == ?. do
        {next, digits} = take_digits(bin, pos + 1)
        if digits > 0, do: {next, true}, else: {pos, false}
      else
        {pos, false}
      end

    if pos < size and :binary.at(bin, pos) in [?e, ?E] do
      pos = pos + 1
      pos = if pos < size and :binary.at(bin, pos) in [?+, ?-], do: pos + 1, else: pos
      {next, digits} = take_digits(bin, pos)
      if digits > 0, do: {next, true}, else: {pos, float?}
    else
      {pos, float?}
    end
  end

  defp take_digits(bin, pos) do
    size = byte_size(bin)
    take_digits(bin, pos, size, 0)
  end

  defp take_digits(bin, pos, size, count) when pos < size do
    if :binary.at(bin, pos) in ?0..?9,
      do: take_digits(bin, pos + 1, size, count + 1),
      else: {pos, count}
  end

  defp take_digits(_bin, pos, _size, count), do: {pos, count}

  defp skip_ws(bin, pos) when pos >= byte_size(bin), do: {:ok, pos}

  defp skip_ws(bin, pos) do
    case :binary.at(bin, pos) do
      byte when byte in [?\s, ?\n, ?\r, ?\t] -> skip_ws(bin, pos + 1)
      _ -> {:ok, pos}
    end
  end

  defp has_control?(<<>>), do: false
  defp has_control?(<<byte, _rest::binary>>) when byte < 32, do: true
  defp has_control?(<<_byte, rest::binary>>), do: has_control?(rest)
end
