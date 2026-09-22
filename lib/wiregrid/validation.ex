defmodule Wiregrid.Validation do
  @moduledoc false

  @topic_roots [:user, :channel, :thread, :room, :game, :document, :custom]
  @max_keyword_options 64
  @max_topic_tuple_parts 4
  @max_event_depth 16
  @max_event_nodes 65_536

  def instance(value) do
    with :ok <- portable_term(value, 0, 3, 16),
         {:ok, size} <- safe_size(value),
         true <- size in 1..256 do
      :ok
    else
      _ -> {:error, :invalid_instance}
    end
  end

  def id(value, max_bytes) when is_integer(value) and value >= 0 do
    case safe_size(value) do
      {:ok, size} when size <= max_bytes -> {:ok, value}
      _ -> {:error, :invalid_id}
    end
  end

  def id(value, max_bytes) when is_binary(value) do
    if byte_size(value) in 1..max_bytes, do: {:ok, value}, else: {:error, :invalid_id}
  end

  def id(_, _), do: {:error, :invalid_id}

  def binary_id(value, max_bytes)
      when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes,
      do: :ok

  def binary_id(_, _), do: {:error, :invalid_id}

  def session_id(value, max_bytes), do: binary_id(value, max_bytes)

  def topic(topic, max_bytes, max_depth \\ 4) do
    with :ok <- portable_topic(topic, 0, max_depth),
         {:ok, bytes} <- safe_size(topic),
         true <- bytes > 0 and bytes <= max_bytes do
      :ok
    else
      _ -> {:error, :invalid_topic}
    end
  end

  def metadata(map, max_bytes) when is_map(map) do
    with :ok <- portable_term(map, 0, 8, 2_048),
         :ok <- bounded_term(map, max_bytes, :invalid_metadata) do
      :ok
    end
  end

  def metadata(_, _), do: {:error, :invalid_metadata}

  def event(event, max_bytes) do
    with :ok <- portable_term(event, 0, @max_event_depth, @max_event_nodes),
         :ok <- bounded_term(event, max_bytes, :event_too_large) do
      :ok
    else
      {:error, :term_too_complex} -> {:error, :event_too_complex}
      {:error, :unsupported_term} -> {:error, :invalid_event}
      {:error, _} = error -> error
    end
  end

  def disconnect_reason(reason) do
    with :ok <- portable_term(reason, 0, 4, 64),
         {:ok, size} <- safe_size(reason),
         true <- size <= 4_096 do
      :ok
    else
      _ -> {:error, :invalid_disconnect_reason}
    end
  end

  def bounded_binary(value, max_bytes, error) when is_binary(value) do
    if byte_size(value) <= max_bytes, do: :ok, else: {:error, error}
  end

  def bounded_binary(_, _, error), do: {:error, error}

  def ttl(:infinity, _max_ms), do: {:ok, :infinity}
  def ttl(ms, max_ms) when is_integer(ms) and ms > 0 and ms <= max_ms, do: {:ok, ms}
  def ttl(_, _), do: {:error, :invalid_ttl}

  def keyword_opts(opts, allowed) when is_list(opts) and is_list(allowed) do
    with :ok <- bounded_list(opts, @max_keyword_options),
         true <- Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      duplicates = keys |> Enum.frequencies() |> Enum.any?(fn {_key, count} -> count > 1 end)
      unknown = keys -- allowed

      cond do
        duplicates -> {:error, :duplicate_options}
        unknown != [] -> {:error, {:unknown_options, Enum.uniq(unknown)}}
        true -> :ok
      end
    else
      {:error, :list_too_large} -> {:error, :too_many_options}
      _ -> {:error, :invalid_options}
    end
  end

  def keyword_opts(_, _), do: {:error, :invalid_options}

  def bounded_list(value, limit) when is_list(value) and is_integer(limit) and limit >= 0 do
    if length_bounded?(value, limit), do: :ok, else: {:error, :list_too_large}
  end

  def bounded_list(_, _), do: {:error, :invalid_list}

  def safe_size(term) do
    try do
      {:ok, :erlang.external_size(term)}
    rescue
      _ -> {:error, :not_serializable}
    catch
      _, _ -> {:error, :not_serializable}
    end
  end

  @doc false
  def portable_term(term, depth, max_depth, remaining)
      when is_integer(depth) and is_integer(max_depth) and is_integer(remaining) do
    case portable_walk(term, depth, max_depth, remaining) do
      {:ok, _remaining} -> :ok
      {:error, _} = error -> error
    end
  end

  def portable_term(_, _, _, _), do: {:error, :term_too_complex}

  # Thread the node budget through siblings. The previous implementation gave
  # every sibling the same remaining budget, which bounded depth/collection
  # width but not the total amount of work performed by a nested term.
  defp portable_walk(_term, depth, max_depth, remaining)
       when remaining <= 0 or depth > max_depth,
       do: {:error, :term_too_complex}

  defp portable_walk(term, _depth, _max_depth, remaining)
       when is_binary(term) or is_integer(term) or is_float(term) or is_atom(term),
       do: {:ok, remaining - 1}

  defp portable_walk(term, depth, max_depth, remaining) when is_tuple(term) do
    size = tuple_size(term)

    if size <= 32 do
      term
      |> Tuple.to_list()
      |> portable_walk_list(depth + 1, max_depth, remaining - 1)
    else
      {:error, :term_too_complex}
    end
  end

  defp portable_walk(term, depth, max_depth, remaining) when is_list(term) do
    if length_bounded?(term, 256) do
      portable_walk_list(term, depth + 1, max_depth, remaining - 1)
    else
      {:error, :term_too_complex}
    end
  end

  defp portable_walk(term, depth, max_depth, remaining) when is_map(term) do
    if map_size(term) <= 256 do
      Enum.reduce_while(term, {:ok, remaining - 1}, fn {key, value}, {:ok, budget} ->
        with {:ok, after_key} <- portable_walk(key, depth + 1, max_depth, budget),
             {:ok, after_value} <- portable_walk(value, depth + 1, max_depth, after_key) do
          {:cont, {:ok, after_value}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {:error, :term_too_complex}
    end
  end

  defp portable_walk(_, _, _, _), do: {:error, :unsupported_term}

  defp portable_walk_list([], _depth, _max_depth, remaining), do: {:ok, remaining}

  defp portable_walk_list([head | tail], depth, max_depth, remaining) do
    with {:ok, next} <- portable_walk(head, depth, max_depth, remaining) do
      portable_walk_list(tail, depth, max_depth, next)
    end
  end

  defp portable_topic(topic, _depth, _max_depth)
       when is_binary(topic) or is_integer(topic) or is_atom(topic), do: :ok

  defp portable_topic(topic, depth, max_depth) when is_tuple(topic) and depth < max_depth do
    size = tuple_size(topic)

    if size in 2..@max_topic_tuple_parts and elem(topic, 0) in @topic_roots do
      portable_topic_tuple_parts(topic, 1, size, depth + 1, max_depth)
    else
      {:error, :invalid_topic_shape}
    end
  end

  defp portable_topic(_, _, _), do: {:error, :invalid_topic_shape}

  defp portable_topic_part(value, _depth, _max_depth)
       when is_binary(value) or is_integer(value) or is_atom(value), do: :ok

  defp portable_topic_part(value, depth, max_depth) when is_tuple(value) and depth < max_depth do
    size = tuple_size(value)

    if size in 1..@max_topic_tuple_parts do
      portable_topic_tuple_parts(value, 0, size, depth + 1, max_depth)
    else
      {:error, :invalid_topic_part}
    end
  end

  defp portable_topic_part(_, _, _), do: {:error, :invalid_topic_part}

  defp portable_topic_tuple_parts(_tuple, index, size, _depth, _max_depth) when index >= size,
    do: :ok

  defp portable_topic_tuple_parts(tuple, index, size, depth, max_depth) do
    case portable_topic_part(elem(tuple, index), depth, max_depth) do
      :ok -> portable_topic_tuple_parts(tuple, index + 1, size, depth, max_depth)
      error -> error
    end
  end

  defp length_bounded?(list, limit), do: length_bounded?(list, limit, 0)
  defp length_bounded?([], _limit, _count), do: true
  defp length_bounded?(_list, limit, count) when count >= limit, do: false
  defp length_bounded?([_ | tail], limit, count), do: length_bounded?(tail, limit, count + 1)
  defp length_bounded?(_, _limit, _count), do: false

  defp bounded_term(term, max_bytes, error) do
    case safe_size(term) do
      {:ok, bytes} when bytes <= max_bytes -> :ok
      _ -> {:error, error}
    end
  end
end
