defmodule Wiregrid.Cache.Redis do
  @moduledoc "Redis cache adapter using a caller-supplied Redix-compatible connection."
  @behaviour Wiregrid.Cache
  @prefix "wg1:"

  @incr_script """
  local vkey = KEYS[1]
  local ckey = KEYS[2]
  if redis.call('EXISTS', vkey) == 1 then
    return {err='WRONGTYPE wiregrid value key is not a counter'}
  end
  local value = redis.call('INCRBY', ckey, ARGV[1])
  local ttl = tonumber(ARGV[2])
  if ttl > 0 then redis.call('PEXPIRE', ckey, ttl) end
  return value
  """

  @put_script """
  redis.call('DEL', KEYS[2])
  local ttl = tonumber(ARGV[2])
  if ttl > 0 then
    redis.call('PSETEX', KEYS[1], ttl, ARGV[1])
  else
    redis.call('SET', KEYS[1], ARGV[1])
  end
  return 1
  """

  @impl true
  def get(opts, key) do
    with {:ok, client, conn} <- client(opts),
         {:ok, prefix} <- prefix(opts),
         {:ok, value} <- command(client, conn, ["GET", value_key(prefix, key)]) do
      case value do
        nil ->
          case command(client, conn, ["GET", counter_key(prefix, key)]) do
            {:ok, nil} -> :miss
            {:ok, raw} -> parse_integer(raw)
            {:error, _} = error -> error
          end

        encoded ->
          Wiregrid.SafeTerm.decode(encoded, 16_777_216)
      end
    end
  end

  @impl true
  def put(opts, key, value, ttl) do
    with {:ok, client, conn} <- client(opts),
         {:ok, prefix} <- prefix(opts),
         {:ok, encoded} <- Wiregrid.SafeTerm.encode(value, 16_777_216),
         {:ok, ttl_arg} <- ttl_arg(ttl),
         {:ok, _} <-
           command(client, conn, [
             "EVAL",
             @put_script,
             "2",
             value_key(prefix, key),
             counter_key(prefix, key),
             encoded,
             ttl_arg
           ]) do
      :ok
    end
  end

  @impl true
  def delete(opts, key) do
    with {:ok, client, conn} <- client(opts),
         {:ok, prefix} <- prefix(opts),
         {:ok, _} <-
           command(client, conn, ["DEL", value_key(prefix, key), counter_key(prefix, key)]) do
      :ok
    end
  end

  @impl true
  def incr(opts, key, delta, ttl) when is_integer(delta) do
    with {:ok, client, conn} <- client(opts),
         {:ok, prefix} <- prefix(opts),
         {:ok, ttl_arg} <- ttl_arg(ttl),
         {:ok, result} <-
           command(client, conn, [
             "EVAL",
             @incr_script,
             "2",
             value_key(prefix, key),
             counter_key(prefix, key),
             Integer.to_string(delta),
             ttl_arg
           ]) do
      parse_integer(result)
    else
      {:error, %{} = error} -> {:error, {:redis_error, error}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def health(opts) do
    with {:ok, client, conn} <- client(opts), {:ok, result} <- command(client, conn, ["PING"]) do
      if result in ["PONG", :PONG], do: :ok, else: {:error, :redis_unhealthy}
    end
  end

  defp client(opts) do
    client = Keyword.get(opts, :client_module, Module.concat(["Redix"]))
    conn = Keyword.get(opts, :conn)
    if is_nil(conn), do: {:error, :redis_connection_required}, else: {:ok, client, conn}
  end

  defp command(client, conn, command) do
    case apply(client, :command, [conn, command]) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_redis_result, other}}
    end
  rescue
    _ -> {:error, :redis_call_failed}
  end

  defp prefix(opts) do
    value = Keyword.get(opts, :prefix, @prefix)
    namespace = Keyword.get(opts, :namespace, Keyword.get(opts, :instance))

    with true <- is_binary(value) and byte_size(value) in 1..128,
         false <- String.contains?(value, ["\r", "\n", "\0"]),
         :ok <- Wiregrid.Validation.instance(namespace),
         {:ok, encoded} <- Wiregrid.SafeTerm.encode(namespace, 512) do
      token =
        :crypto.hash(:sha256, encoded) |> Base.url_encode64(padding: false) |> binary_part(0, 22)

      {:ok, value <> "i:" <> token <> ":"}
    else
      _ -> {:error, :invalid_redis_prefix}
    end
  end

  defp value_key(prefix, key), do: prefix <> "v:" <> key
  defp counter_key(prefix, key), do: prefix <> "c:" <> key

  defp ttl_arg(:infinity), do: {:ok, "0"}
  defp ttl_arg(ms) when is_integer(ms) and ms > 0, do: {:ok, Integer.to_string(ms)}
  defp ttl_arg(_), do: {:error, :invalid_ttl}

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_counter_value}
    end
  end

  defp parse_integer(_), do: {:error, :invalid_counter_value}
end
