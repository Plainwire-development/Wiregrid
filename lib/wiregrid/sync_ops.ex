defmodule Wiregrid.SyncOps do
  @moduledoc false

  @doc false
  def reconcile(
        instance,
        cfg,
        sid,
        desired_items,
        limit,
        validate_item,
        add_fun,
        remove_fun,
        current_fun
      )
      when is_function(validate_item, 1) and is_function(add_fun, 1) and
             is_function(remove_fun, 1) and is_function(current_fun, 1) do
    with :ok <- Wiregrid.Validation.session_id(sid, cfg.max_session_id_bytes),
         :ok <- Wiregrid.Validation.bounded_list(desired_items, min(cfg.max_batch_items, limit)),
         {:ok, desired} <- validate_distinct(desired_items, validate_item),
         %{tables: tables} <- Wiregrid.Tables.get(instance),
         [{^sid, _session}] <- :ets.lookup(tables.sessions, sid) do
      current = current_fun.(tables) |> MapSet.new()
      additions = MapSet.difference(desired, current) |> MapSet.to_list()
      removals = MapSet.difference(current, desired) |> MapSet.to_list()

      case apply_with_rollback(additions, add_fun, remove_fun) do
        {:ok, added} ->
          {removed, removal_failures} = remove_all(removals, remove_fun)
          _ = Wiregrid.Metrics.increment(instance, :topology_syncs)

          if removal_failures != [],
            do: Wiregrid.Metrics.increment(instance, :topology_sync_failures)

          {:ok,
           %{
             added: added,
             removed: removed,
             unchanged: MapSet.intersection(current, desired) |> MapSet.size(),
             desired: MapSet.size(desired),
             failed_removals: Enum.reverse(removal_failures),
             partial: removal_failures != []
           }}

        {:error, item, reason, rolled_back} ->
          _ = Wiregrid.Metrics.increment(instance, :topology_sync_failures)

          {:error,
           {:sync_failed, %{phase: :add, item: item, reason: reason, rolled_back: rolled_back}}}
      end
    else
      [] -> {:error, :unknown_session}
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  def reconcile(_instance, _cfg, _sid, _desired, _limit, _validate, _add, _remove, _current),
    do: {:error, :invalid_sync}

  # Validate and deduplicate in one bounded traversal. The outer bounded-list
  # guard has already capped traversal length, so the set cannot grow beyond
  # the configured edge budget for this operation.
  defp validate_distinct(items, validate_item) when is_list(items) do
    Enum.reduce_while(items, {:ok, MapSet.new()}, fn item, {:ok, seen} ->
      cond do
        MapSet.member?(seen, item) ->
          {:halt, {:error, :duplicate_batch_items}}

        true ->
          case validate_item.(item) do
            :ok -> {:cont, {:ok, MapSet.put(seen, item)}}
            {:error, _} = error -> {:halt, error}
            _ -> {:halt, {:error, :invalid_item}}
          end
      end
    end)
  end

  defp apply_with_rollback(items, add_fun, remove_fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, added} ->
      case add_fun.(item) do
        :ok ->
          {:cont, {:ok, [item | added]}}

        {:error, reason} ->
          {:halt, {:error, item, reason, rollback(added, remove_fun)}}

        other ->
          {:halt, {:error, item, {:unexpected_result, other}, rollback(added, remove_fun)}}
      end
    end)
    |> case do
      {:ok, added} -> {:ok, length(added)}
      error -> error
    end
  end

  defp rollback(items, remove_fun) do
    Enum.count(items, fn prior -> remove_fun.(prior) == :ok end)
  end

  defp remove_all(items, remove_fun) do
    Enum.reduce(items, {0, []}, fn item, {count, failures} ->
      case remove_fun.(item) do
        :ok -> {count + 1, failures}
        {:error, reason} -> {count, [%{item: item, reason: reason} | failures]}
        other -> {count, [%{item: item, reason: {:unexpected_result, other}} | failures]}
      end
    end)
  end
end
