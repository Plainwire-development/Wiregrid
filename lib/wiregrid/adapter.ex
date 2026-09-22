defmodule Wiregrid.Adapter do
  @moduledoc false

  @doc "Runs a storage/cache adapter call inline or in a bounded supervised task."
  def invoke(instance, cfg, module, function, args, error_prefix) do
    _ = Wiregrid.Metrics.increment(instance, :adapter_calls_total)

    case cfg.adapter_mode do
      :inline -> safe_apply(instance, module, function, args, error_prefix)
      :isolated -> isolated(instance, cfg, module, function, args, error_prefix)
      _ -> {:error, :invalid_adapter_mode}
    end
  end

  defp isolated(instance, cfg, module, function, args, error_prefix) do
    case Wiregrid.Tables.get(instance) do
      %{tables: tables} ->
        case Wiregrid.Capacity.reserve(tables.capacity, :adapter_pending, cfg.max_adapter_pending) do
          :ok ->
            try do
              task =
                Task.Supervisor.async_nolink(Wiregrid.TaskSupervisor, fn ->
                  safe_apply(instance, module, function, args, error_prefix)
                end)

              case Task.yield(task, cfg.adapter_timeout_ms) do
                {:ok, result} ->
                  result

                {:exit, _} ->
                  failed(instance, error_prefix, module, function)

                nil ->
                  _ = Task.shutdown(task, :brutal_kill)
                  _ = Wiregrid.Metrics.increment(instance, :adapter_timeouts)
                  {:error, :adapter_timeout}
              end
            catch
              :exit, _ -> failed(instance, error_prefix, module, function)
            after
              _ = Wiregrid.Capacity.release(tables.capacity, :adapter_pending)
            end

          {:error, :capacity} ->
            _ = Wiregrid.Metrics.increment(instance, :adapter_rejections)
            {:error, :adapter_overloaded}

          {:error, _} ->
            failed(instance, error_prefix, module, function)
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  defp safe_apply(instance, module, function, args, error_prefix) do
    if function_exported?(module, function, length(args)) do
      try do
        apply(module, function, args)
      rescue
        _ -> failed(instance, error_prefix, module, function)
      catch
        _, _ -> failed(instance, error_prefix, module, function)
      end
    else
      {:error, {missing_callback_error(error_prefix), module, function, length(args)}}
    end
  end

  defp failed(instance, error_prefix, module, function) do
    _ = Wiregrid.Metrics.increment(instance, :adapter_failures)
    {:error, {failure_error(error_prefix), module, function}}
  end

  defp missing_callback_error(:storage_adapter), do: :storage_adapter_missing_callback
  defp missing_callback_error(:cache_adapter), do: :cache_adapter_missing_callback
  defp missing_callback_error(_), do: :adapter_missing_callback

  defp failure_error(:storage_adapter), do: :storage_adapter_failure
  defp failure_error(:cache_adapter), do: :cache_adapter_failure
  defp failure_error(_), do: :adapter_failure
end
