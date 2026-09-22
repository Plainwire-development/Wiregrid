defmodule Wiregrid.Callback do
  @moduledoc false

  @doc "Runs a configured extension callback inline or in a bounded supervised task."
  def run(_instance, %{authorizer_mode: :inline}, fun) when is_function(fun, 0) do
    safe(fun)
  end

  def run(instance, %{authorizer_mode: :isolated} = cfg, fun) when is_function(fun, 0) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        case Wiregrid.Capacity.reserve(t.capacity, :callback_pending, cfg.max_callback_pending) do
          :ok ->
            try do
              task = Task.Supervisor.async_nolink(Wiregrid.TaskSupervisor, fn -> safe(fun) end)

              case Task.yield(task, cfg.callback_timeout_ms) do
                {:ok, result} ->
                  result

                {:exit, _reason} ->
                  {:error, :callback_failed}

                nil ->
                  _ = Task.shutdown(task, :brutal_kill)
                  {:error, :callback_timeout}
              end
            catch
              :exit, _ -> {:error, :callback_failed}
            after
              _ = Wiregrid.Capacity.release(t.capacity, :callback_pending)
            end

          {:error, :capacity} ->
            _ = Wiregrid.Metrics.increment(instance, :callback_rejections)
            {:error, :callback_overloaded}

          {:error, _} ->
            {:error, :callback_failed}
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def run(_instance, _cfg, _fun), do: {:error, :callback_failed}

  defp safe(fun) do
    try do
      {:ok, fun.()}
    rescue
      _ -> {:error, :callback_failed}
    catch
      _, _ -> {:error, :callback_failed}
    end
  end
end
