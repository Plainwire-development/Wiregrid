defmodule Wiregrid.Cache do
  @moduledoc "Bounded cache behaviour and per-instance façade."

  @callback get(keyword(), binary()) :: {:ok, term()} | :miss | {:error, term()}
  @callback put(keyword(), binary(), term(), pos_integer() | :infinity) :: :ok | {:error, term()}
  @callback delete(keyword(), binary()) :: :ok | {:error, term()}
  @callback incr(keyword(), binary(), integer(), pos_integer() | :infinity) ::
              {:ok, integer()} | {:error, term()}
  @callback health(keyword()) :: :ok | {:error, term()}

  def get(instance, key) do
    with {:ok, cfg, module, opts} <- adapter(instance),
         :ok <- key(key, cfg) do
      Wiregrid.Adapter.invoke(instance, cfg, module, :get, [opts, key], :cache_adapter)
    end
  end

  def put(instance, key, value, ttl \\ :infinity) do
    with {:ok, cfg, module, opts} <- adapter(instance),
         :ok <- key(key, cfg),
         :ok <- value(value, cfg),
         {:ok, normalized_ttl} <- Wiregrid.Validation.ttl(ttl, cfg.max_ttl_ms) do
      Wiregrid.Adapter.invoke(
        instance,
        cfg,
        module,
        :put,
        [opts, key, value, normalized_ttl],
        :cache_adapter
      )
    end
  end

  def delete(instance, key) do
    with {:ok, cfg, module, opts} <- adapter(instance),
         :ok <- key(key, cfg) do
      Wiregrid.Adapter.invoke(instance, cfg, module, :delete, [opts, key], :cache_adapter)
    end
  end

  def incr(instance, key, delta \\ 1, ttl \\ :infinity) do
    with {:ok, cfg, module, opts} <- adapter(instance),
         :ok <- key(key, cfg),
         true <- is_integer(delta),
         {:ok, normalized_ttl} <- Wiregrid.Validation.ttl(ttl, cfg.max_ttl_ms) do
      Wiregrid.Adapter.invoke(
        instance,
        cfg,
        module,
        :incr,
        [opts, key, delta, normalized_ttl],
        :cache_adapter
      )
    else
      false -> {:error, :invalid_delta}
      {:error, _} = error -> error
    end
  end

  def health(instance) do
    with {:ok, cfg, module, opts} <- adapter(instance) do
      Wiregrid.Adapter.invoke(instance, cfg, module, :health, [opts], :cache_adapter)
    end
  end

  defp adapter(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: %{cache: {module, opts}} = cfg} ->
        {:ok, cfg, module, Keyword.put_new(opts, :instance, instance)}

      _ ->
        {:error, :instance_unavailable}
    end
  end

  defp key(key, cfg) when is_binary(key) do
    if byte_size(key) in 1..cfg.max_cache_key_bytes, do: :ok, else: {:error, :invalid_cache_key}
  end

  defp key(_, _), do: {:error, :invalid_cache_key}

  defp value(value, cfg) do
    case Wiregrid.Validation.safe_size(value) do
      {:ok, size} when size <= cfg.max_cache_value_bytes -> :ok
      _ -> {:error, :cache_value_too_large}
    end
  end
end
