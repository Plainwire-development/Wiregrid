defmodule Wiregrid.DispatchPlan do
  @moduledoc """
  Integrity-bound reusable dispatch target plans.

  A plan validates and deduplicates a heterogeneous target set once, then can
  be reused with ordinary or prepared events. Plans are bound to one running
  Wiregrid instance through an HMAC derived from the instance's private
  runtime key; stopping and recreating the instance intentionally invalidates
  old plans.

  Plans cache *routing shape only*. Authorization, drain state, event IDs,
  persistence decisions and delivery backpressure are evaluated on every
  execution, so a plan cannot preserve permissions that were later revoked.
  """

  @tag :wiregrid_dispatch_plan_v1
  @type t :: {:wiregrid_dispatch_plan_v1, map(), binary()}

  @spec compile(term(), list()) :: {:ok, t()} | {:error, term()}
  def compile(instance, targets) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         {:ok, groups} <- Wiregrid.Dispatch.normalize_targets(targets, cfg) do
      _ = Wiregrid.Metrics.increment(instance, :dispatch_plans_compiled)
      {:ok, {@tag, groups, sign(cfg, groups)}}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec unpack(term(), term()) :: {:ok, map()} | {:error, term()}
  def unpack(instance, {@tag, groups, mac}) when is_map(groups) and is_binary(mac) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         true <- byte_size(mac) == 32,
         true <- valid_shape?(groups, cfg),
         expected <- sign(cfg, groups),
         true <- :crypto.hash_equals(expected, mac) do
      {:ok, groups}
    else
      :undefined -> {:error, :instance_unavailable}
      false -> {:error, :invalid_dispatch_plan}
    end
  end

  def unpack(_instance, _plan), do: {:error, :invalid_dispatch_plan}

  defp sign(%{prepared_mac_key: key}, groups) when is_binary(key) and byte_size(key) == 32 do
    encoded = :erlang.term_to_binary({@tag, groups}, [:deterministic])
    :crypto.mac(:hmac, :sha256, key, encoded)
  end

  # HMAC is authoritative for integrity. This cheap structural check keeps a
  # malformed caller-supplied tuple from reaching group execution and keeps a
  # future refactor from accidentally accepting an oversized legacy plan.
  defp valid_shape?(
         %{topics: topics, rooms: rooms, users: users, sessions: sessions, count: count},
         cfg
       )
       when is_list(topics) and is_list(rooms) and is_list(users) and is_list(sessions) and
              is_integer(count) and count > 0 and count <= cfg.max_batch_targets do
    case bounded_group_count([topics, rooms, users, sessions], cfg.max_batch_targets, 0) do
      {:ok, actual} -> actual == count
      :too_large -> false
    end
  end

  defp valid_shape?(_, _cfg), do: false

  # Caller-supplied plans are untrusted until their HMAC is verified. Do not
  # traverse an attacker-sized fake target list just to discover the MAC is bad.
  defp bounded_group_count([], _limit, total), do: {:ok, total}

  defp bounded_group_count([group | rest], limit, total) do
    case bounded_list_count(group, limit - total, 0) do
      {:ok, count} -> bounded_group_count(rest, limit, total + count)
      :too_large -> :too_large
    end
  end

  defp bounded_list_count([], _remaining, count), do: {:ok, count}
  defp bounded_list_count(_list, remaining, _count) when remaining <= 0, do: :too_large

  defp bounded_list_count([_ | rest], remaining, count),
    do: bounded_list_count(rest, remaining - 1, count + 1)
end
