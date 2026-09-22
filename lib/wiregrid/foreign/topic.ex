defmodule Wiregrid.Foreign.Topic do
  @moduledoc false

  @kinds [:channel, :thread, :room, :user, :game, :document]
  @kind_names %{
    "channel" => :channel,
    "thread" => :thread,
    "room" => :room,
    "user" => :user,
    "game" => :game,
    "document" => :document
  }

  def parse(value) when is_binary(value) and byte_size(value) in 1..512 do
    cond do
      value == "beam-only" ->
        {:error, :unsupported_topic}

      String.starts_with?(value, "custom:") ->
        parse_custom(value)

      true ->
        case split_kind(value) do
          {:ok, kind, "i:" <> rest} -> parse_integer(kind, rest)
          {:ok, _kind, "a:" <> _rest} -> {:error, :unsupported_topic}
          {:ok, kind, id} -> text_topic(kind, id)
          :bare -> text_topic(:channel, value)
        end
    end
  end

  def parse(_), do: {:error, :invalid_topic}

  def format({:custom, namespace, id}) when is_binary(namespace) and is_binary(id) do
    "custom:" <> namespace <> ":" <> id
  end

  def format({kind, id}) when kind in @kinds and is_binary(id) do
    name = Atom.to_string(kind)

    if kind == :channel and not explicit?(id) do
      id
    else
      name <> ":" <> id
    end
  end

  def format({kind, id})
      when kind in @kinds and is_integer(id) and id >= 0 and id <= 999_999_999_999_999_999 do
    Atom.to_string(kind) <> ":i:" <> Integer.to_string(id)
  end

  def format({kind, id}) when kind in @kinds and is_atom(id) do
    Atom.to_string(kind) <> ":a:" <> Atom.to_string(id)
  end

  def format(_topic), do: "beam-only"

  defp split_kind(value) do
    case :binary.split(value, ":") do
      [name, rest] ->
        case Map.fetch(@kind_names, name) do
          {:ok, kind} -> {:ok, kind, rest}
          :error -> :bare
        end

      _ ->
        :bare
    end
  end

  defp parse_custom("custom:" <> rest) do
    case :binary.split(rest, ":") do
      [namespace, id] ->
        if namespace?(namespace) and text?(id),
          do: {:ok, {:custom, namespace, id}},
          else: {:error, :invalid_topic}

      _ ->
        {:error, :invalid_topic}
    end
  end

  defp parse_integer(kind, rest) do
    cond do
      byte_size(rest) not in 1..18 ->
        {:error, :invalid_topic}

      byte_size(rest) > 1 and :binary.first(rest) == ?0 ->
        {:error, :invalid_topic}

      true ->
        case Integer.parse(rest) do
          {number, ""} when number >= 0 -> {:ok, {kind, number}}
          _ -> {:error, :invalid_topic}
        end
    end
  end

  defp text_topic(kind, id) do
    if text?(id), do: {:ok, {kind, id}}, else: {:error, :invalid_topic}
  end

  defp explicit?(id) do
    id == "beam-only" or
      String.starts_with?(id, [
        "channel:",
        "thread:",
        "room:",
        "user:",
        "game:",
        "document:",
        "custom:"
      ])
  end

  defp namespace?(value) do
    byte_size(value) in 1..64 and
      Enum.all?(:binary.bin_to_list(value), fn
        char when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in ~c"_.-" -> true
        _ -> false
      end)
  end

  defp text?(value) when is_binary(value) and byte_size(value) in 1..256 do
    String.valid?(value) and control_free?(value)
  end

  defp text?(_), do: false

  defp control_free?(<<>>), do: true
  defp control_free?(<<byte, _rest::binary>>) when byte < 32 or byte == 127, do: false
  defp control_free?(<<_byte, rest::binary>>), do: control_free?(rest)
end
