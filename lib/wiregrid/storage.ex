defmodule Wiregrid.Storage do
  @moduledoc "Generic durable event-stream storage behaviour and instance façade."

  @callback bootstrap(keyword()) :: :ok | {:error, term()}
  @callback append(keyword(), binary(), binary(), term(), map(), non_neg_integer()) ::
              :ok | {:error, term()}
  @callback get(keyword(), binary(), binary()) :: {:ok, map()} | :not_found | {:error, term()}
  @callback page(keyword(), binary(), nil | binary(), pos_integer()) ::
              {:ok, [map()], nil | binary()} | {:error, term()}
  @callback delete(keyword(), binary(), binary()) :: :ok | {:error, term()}
  @callback prune(keyword(), binary(), non_neg_integer(), pos_integer()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback health(keyword()) :: :ok | {:error, term()}

  def bootstrap(instance), do: invoke(instance, :bootstrap, [])

  def append(instance, stream, id, event, meta \\ %{}) do
    with {:ok, cfg, module, opts} <- adapter(instance),
         {:ok, stream_id} <- stream_id(instance, stream, cfg),
         :ok <- Wiregrid.Validation.binary_id(id, cfg.max_storage_id_bytes),
         :ok <- Wiregrid.Validation.event(event, cfg.max_event_bytes),
         :ok <- Wiregrid.Validation.metadata(meta, cfg.max_metadata_bytes),
         inserted_at_ms <- System.system_time(:millisecond) do
      Wiregrid.Adapter.invoke(
        instance,
        cfg,
        module,
        :append,
        [opts, stream_id, id, event, meta, inserted_at_ms],
        :storage_adapter
      )
    end
  end

  def get(instance, stream, id) do
    with {:ok, cfg, module, opts} <- adapter(instance),
         {:ok, stream_id} <- stream_id(instance, stream, cfg),
         :ok <- Wiregrid.Validation.binary_id(id, cfg.max_storage_id_bytes) do
      Wiregrid.Adapter.invoke(
        instance,
        cfg,
        module,
        :get,
        [opts, stream_id, id],
        :storage_adapter
      )
    end
  end

  def page(instance, stream, cursor \\ nil, limit \\ 100) do
    with {:ok, cfg, module, opts} <- adapter(instance),
         {:ok, stream_id} <- stream_id(instance, stream, cfg),
         true <- is_integer(limit) and limit in 1..1_000,
         {:ok, _decoded} <- Wiregrid.Storage.Cursor.decode(cursor, cfg.max_storage_id_bytes) do
      Wiregrid.Adapter.invoke(
        instance,
        cfg,
        module,
        :page,
        [opts, stream_id, cursor, limit],
        :storage_adapter
      )
    else
      false -> {:error, :invalid_limit}
      {:error, _} = error -> error
    end
  end

  def delete(instance, stream, id) do
    with {:ok, cfg, module, opts} <- adapter(instance),
         {:ok, stream_id} <- stream_id(instance, stream, cfg),
         :ok <- Wiregrid.Validation.binary_id(id, cfg.max_storage_id_bytes) do
      Wiregrid.Adapter.invoke(
        instance,
        cfg,
        module,
        :delete,
        [opts, stream_id, id],
        :storage_adapter
      )
    end
  end

  def prune(instance, stream, before_ms, limit \\ 1_000) do
    with {:ok, cfg, module, opts} <- adapter(instance),
         {:ok, stream_id} <- stream_id(instance, stream, cfg),
         true <- is_integer(before_ms) and before_ms >= 0,
         true <- is_integer(limit) and limit in 1..10_000 do
      Wiregrid.Adapter.invoke(
        instance,
        cfg,
        module,
        :prune,
        [opts, stream_id, before_ms, limit],
        :storage_adapter
      )
    else
      false -> {:error, :invalid_prune_request}
      {:error, _} = error -> error
    end
  end

  def health(instance), do: invoke(instance, :health, [])

  defp invoke(instance, function, args) do
    with {:ok, cfg, module, opts} <- adapter(instance) do
      Wiregrid.Adapter.invoke(instance, cfg, module, function, [opts | args], :storage_adapter)
    end
  end

  defp adapter(instance) do
    case Wiregrid.Tables.get(instance) do
      %{config: %{storage: {module, opts}} = cfg} ->
        {:ok, cfg, module, Keyword.put_new(opts, :instance, instance)}

      _ ->
        {:error, :instance_unavailable}
    end
  end

  defp stream_id(instance, stream, cfg) do
    with :ok <- Wiregrid.Validation.instance(instance),
         :ok <- Wiregrid.Validation.topic(stream, cfg.max_topic_bytes, cfg.max_topic_depth),
         {:ok, encoded} <-
           Wiregrid.SafeTerm.encode(
             {:wiregrid_stream, 1, instance, stream},
             cfg.max_topic_bytes + 512
           ) do
      {:ok, encoded}
    end
  end
end
