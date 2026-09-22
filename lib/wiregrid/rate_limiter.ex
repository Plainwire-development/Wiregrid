defmodule Wiregrid.RateLimiter do
  @moduledoc """
  Bounded per-instance rate limiting backed by ETS.

  Two policies are available:

    * `:fixed_window` - minimal bookkeeping for coarse operation budgets.
    * `:token_bucket` - burst-capable smoothing with integer-only refill math.

  Each logical bucket has an authoritative generation-tagged ownership record.
  Expiry jobs carry that generation, so a delayed timer from an older bucket can
  never remove newly recreated state. Capacity is released only by deleting the
  matching owner generation.

  Token-bucket hits update one ETS row with compare-and-swap and do not schedule
  a timer per request. The idle-expiry callback rechecks `last_seen` and only
  reschedules the remaining idle interval when the bucket is still active.
  """

  @max_retries 8
  @policy_keys [:policy, :burst, :idle_ttl_ms]

  @type policy :: :fixed_window | :token_bucket

  @spec check(term(), term(), term(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def check(instance, bucket, key, limit, window_ms),
    do: check(instance, bucket, key, limit, window_ms, [])

  @spec check(term(), term(), term(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def check(instance, bucket, key, limit, window_ms, opts)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 and
             is_list(opts) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        with true <- window_ms <= cfg.max_ttl_ms,
             :ok <- Wiregrid.Validation.keyword_opts(opts, @policy_keys),
             :ok <- validate_key({bucket, key}, cfg.max_rate_limit_key_bytes),
             {:ok, policy} <- policy(opts) do
          case policy do
            :fixed_window -> fixed_window(instance, t, cfg, bucket, key, limit, window_ms)
            :token_bucket -> token_bucket(instance, t, cfg, bucket, key, limit, window_ms, opts)
          end
        else
          false -> {:error, :rate_limit_window_too_large}
          {:error, _} = error -> error
        end

      _ ->
        {:error, :instance_unavailable}
    end
  rescue
    ArgumentError -> {:error, :invalid_rate_limit}
  end

  def check(_, _, _, _, _, _), do: {:error, :invalid_rate_limit}

  @doc false
  def expire(instance, {composite, generation}) when is_reference(generation) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} -> expire_owned(instance, t, composite, generation)
      _ -> :ok
    end
  end

  # Compatibility with an expiry record created before generation-tagged
  # limiter ownership was introduced. Resolve the current generation rather
  # than deleting by key alone.
  def expire(instance, composite) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        case :ets.lookup(t.rate_limit_keys, composite) do
          [{^composite, generation}] when is_reference(generation) ->
            expire_owned(instance, t, composite, generation)

          [{^composite, true}] ->
            # Upgrade cleanup for the pre-generation limiter representation.
            :ets.delete(t.rate_limits, composite)

            case :ets.take(t.rate_limit_keys, composite) do
              [{^composite, true}] ->
                _ = Wiregrid.Capacity.release(t.capacity, :rate_limit_buckets)

              _ ->
                :ok
            end

            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # -- fixed window ---------------------------------------------------------

  defp fixed_window(instance, t, cfg, bucket, key, limit, window_ms) do
    do_fixed_window(instance, t, cfg, bucket, key, limit, window_ms, 0)
  end

  defp do_fixed_window(_instance, _t, _cfg, _bucket, _key, _limit, _window_ms, attempts)
       when attempts >= @max_retries,
       do: {:error, :rate_limit_contention}

  defp do_fixed_window(instance, t, cfg, bucket, key, limit, window_ms, attempts) do
    now = System.monotonic_time(:millisecond)
    window = floor_div(now, window_ms)
    composite = {:fixed_window, bucket, key, window}

    case ensure_fixed_bucket(instance, t, cfg, composite, window_ms, now) do
      {:ok, generation} ->
        case increment_fixed_owned(t, composite, generation) do
          {:ok, count} when count <= limit -> {:ok, limit - count}
          {:ok, _count} -> rejected(instance)
          :retry -> do_fixed_window(instance, t, cfg, bucket, key, limit, window_ms, attempts + 1)
        end

      :retry ->
        do_fixed_window(instance, t, cfg, bucket, key, limit, window_ms, attempts + 1)

      {:error, _} = error ->
        error
    end
  end

  defp ensure_fixed_bucket(instance, t, cfg, composite, window_ms, now) do
    case claim_bucket(instance, t, cfg, composite) do
      {:existing, generation} ->
        case :ets.lookup(t.rate_limits, composite) do
          [{^composite, :fixed_window, _count, ^generation}] -> {:ok, generation}
          _ -> :retry
        end

      {:new, generation} ->
        # No current owner existed when this generation was claimed, so any row
        # left behind here is stale crash residue and cannot be authoritative.
        :ets.delete(t.rate_limits, composite)
        window_end = (floor_div(now, window_ms) + 1) * window_ms
        ttl = min(max(window_end - now + 1_000, 1_000), cfg.max_ttl_ms)

        case Wiregrid.Expiry.schedule(instance, :rate_limit, {composite, generation}, ttl) do
          :ok ->
            if :ets.insert_new(t.rate_limits, {composite, :fixed_window, 0, generation}) do
              {:ok, generation}
            else
              release_generation(t, composite, generation)
              :retry
            end

          {:error, _} = error ->
            release_generation(t, composite, generation)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp increment_fixed_owned(t, composite, generation) do
    try do
      count = :ets.update_counter(t.rate_limits, composite, {3, 1})

      if owner?(t, composite, generation) do
        {:ok, count}
      else
        :retry
      end
    rescue
      ArgumentError -> :retry
    end
  end

  # -- token bucket ---------------------------------------------------------

  defp token_bucket(instance, t, cfg, bucket, key, limit, window_ms, opts) do
    with {:ok, burst} <- burst(opts, limit),
         {:ok, idle_ttl_ms} <- idle_ttl(opts, window_ms, cfg.max_ttl_ms),
         :ok <- token_math_bounds(limit, burst, window_ms) do
      composite = {:token_bucket, bucket, key, limit, window_ms, burst}
      do_token_bucket(instance, t, cfg, composite, limit, window_ms, burst, idle_ttl_ms, 0)
    end
  end

  defp do_token_bucket(
         _instance,
         _t,
         _cfg,
         _composite,
         _limit,
         _window_ms,
         _burst,
         _idle_ttl,
         attempts
       )
       when attempts >= @max_retries,
       do: {:error, :rate_limit_contention}

  defp do_token_bucket(
         instance,
         t,
         cfg,
         composite,
         limit,
         window_ms,
         burst,
         idle_ttl_ms,
         attempts
       ) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(t.rate_limits, composite) do
      [{^composite, :token_bucket, tokens, last_ms, ^idle_ttl_ms, generation}] ->
        capacity = burst * window_ms
        elapsed = max(now - last_ms, 0)
        available = min(capacity, tokens + elapsed * limit)
        allowed? = available >= window_ms
        next_tokens = if allowed?, do: available - window_ms, else: available
        old = {composite, :token_bucket, tokens, last_ms, idle_ttl_ms, generation}
        new = {composite, :token_bucket, next_tokens, now, idle_ttl_ms, generation}

        if replace_exact(t.rate_limits, old, new) and owner?(t, composite, generation) do
          if allowed?, do: {:ok, div(next_tokens, window_ms)}, else: rejected(instance)
        else
          do_token_bucket(
            instance,
            t,
            cfg,
            composite,
            limit,
            window_ms,
            burst,
            idle_ttl_ms,
            attempts + 1
          )
        end

      [] ->
        create_token_bucket(
          instance,
          t,
          cfg,
          composite,
          limit,
          window_ms,
          burst,
          idle_ttl_ms,
          now,
          attempts
        )

      [_other] ->
        {:error, :rate_limit_state_conflict}
    end
  end

  defp create_token_bucket(
         instance,
         t,
         cfg,
         composite,
         limit,
         window_ms,
         burst,
         idle_ttl_ms,
         now,
         attempts
       ) do
    case claim_bucket(instance, t, cfg, composite) do
      {:existing, _generation} ->
        do_token_bucket(
          instance,
          t,
          cfg,
          composite,
          limit,
          window_ms,
          burst,
          idle_ttl_ms,
          attempts + 1
        )

      {:new, generation} ->
        :ets.delete(t.rate_limits, composite)

        case Wiregrid.Expiry.schedule(instance, :rate_limit, {composite, generation}, idle_ttl_ms) do
          :ok ->
            capacity = burst * window_ms
            initial_tokens = capacity - window_ms
            row = {composite, :token_bucket, initial_tokens, now, idle_ttl_ms, generation}

            if :ets.insert_new(t.rate_limits, row) do
              {:ok, div(initial_tokens, window_ms)}
            else
              release_generation(t, composite, generation)

              do_token_bucket(
                instance,
                t,
                cfg,
                composite,
                limit,
                window_ms,
                burst,
                idle_ttl_ms,
                attempts + 1
              )
            end

          {:error, _} = error ->
            release_generation(t, composite, generation)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  # -- expiry / ownership ---------------------------------------------------

  defp expire_owned(
         instance,
         t,
         {:token_bucket, _bucket, _key, _limit, _window_ms, _burst} = composite,
         generation
       ) do
    expire_token_bucket(instance, t, composite, generation, 0)
  end

  defp expire_owned(_instance, t, composite, generation) do
    release_generation(t, composite, generation)
    :ok
  end

  defp expire_token_bucket(_instance, _t, _composite, _generation, attempts)
       when attempts >= @max_retries,
       do: :ok

  defp expire_token_bucket(instance, t, composite, generation, _attempts) do
    if owner?(t, composite, generation) do
      case :ets.lookup(t.rate_limits, composite) do
        [{^composite, :token_bucket, _tokens, last_ms, idle_ttl_ms, ^generation} = row] ->
          now = System.monotonic_time(:millisecond)
          remaining = idle_ttl_ms - max(now - last_ms, 0)

          cond do
            remaining > 0 ->
              Wiregrid.Expiry.schedule(instance, :rate_limit, {composite, generation}, remaining)

            mark_expiring(t, composite, generation) ->
              case :ets.lookup(t.rate_limits, composite) do
                [^row] ->
                  finalize_expiring(t, composite, generation)
                  :ok

                [{^composite, :token_bucket, _new_tokens, new_last_ms, ^idle_ttl_ms, ^generation}] ->
                  # A hit won the race before ownership was marked expiring.
                  # Restore ownership and schedule from the refreshed clock;
                  # the successful request therefore cannot reset its bucket.
                  if restore_owner(t, composite, generation) do
                    refreshed =
                      idle_ttl_ms - max(System.monotonic_time(:millisecond) - new_last_ms, 0)

                    Wiregrid.Expiry.schedule(
                      instance,
                      :rate_limit,
                      {composite, generation},
                      max(refreshed, 1)
                    )
                  else
                    :ok
                  end

                _ ->
                  finalize_expiring(t, composite, generation)
                  :ok
              end

            true ->
              :ok
          end

        _ ->
          release_generation(t, composite, generation)
          :ok
      end
    else
      :ok
    end
  end

  defp claim_bucket(instance, t, cfg, composite) do
    case :ets.lookup(t.rate_limit_keys, composite) do
      [{^composite, generation}] when is_reference(generation) ->
        {:existing, generation}

      [{^composite, {:expiring, _generation}}] ->
        {:error, :rate_limit_contention}

      [] ->
        case Wiregrid.Capacity.reserve(
               t.capacity,
               :rate_limit_buckets,
               cfg.max_rate_limit_buckets
             ) do
          :ok ->
            generation = make_ref()

            if :ets.insert_new(t.rate_limit_keys, {composite, generation}) do
              {:new, generation}
            else
              _ = Wiregrid.Capacity.release(t.capacity, :rate_limit_buckets)

              case :ets.lookup(t.rate_limit_keys, composite) do
                [{^composite, winner}] when is_reference(winner) -> {:existing, winner}
                _ -> {:error, :rate_limit_contention}
              end
            end

          {:error, :capacity} ->
            case :ets.lookup(t.rate_limit_keys, composite) do
              [{^composite, generation}] when is_reference(generation) ->
                {:existing, generation}

              _ ->
                _ = Wiregrid.Metrics.increment(instance, :admission_rejections)
                {:error, :rate_limit_capacity}
            end

          {:error, _} = error ->
            error
        end
    end
  end

  defp owner?(t, composite, generation) do
    :ets.lookup(t.rate_limit_keys, composite) == [{composite, generation}]
  end

  defp mark_expiring(t, composite, generation) do
    replace_exact(
      t.rate_limit_keys,
      {composite, generation},
      {composite, {:expiring, generation}}
    )
  end

  defp restore_owner(t, composite, generation) do
    replace_exact(
      t.rate_limit_keys,
      {composite, {:expiring, generation}},
      {composite, generation}
    )
  end

  defp finalize_expiring(t, composite, generation) do
    expiring = {composite, {:expiring, generation}}

    if :ets.select_delete(t.rate_limit_keys, [{expiring, [], [true]}]) == 1 do
      _ = Wiregrid.Capacity.release(t.capacity, :rate_limit_buckets)
      delete_generation_state(t.rate_limits, composite, generation)
      :released
    else
      :stale
    end
  end

  defp release_generation(t, composite, generation) do
    owner = {composite, generation}

    if :ets.select_delete(t.rate_limit_keys, [{owner, [], [true]}]) == 1 do
      _ = Wiregrid.Capacity.release(t.capacity, :rate_limit_buckets)
      delete_generation_state(t.rate_limits, composite, generation)
      :released
    else
      :stale
    end
  end

  defp delete_generation_state(table, composite, generation) do
    spec = [
      {{composite, :fixed_window, :"$1", generation}, [], [true]},
      {{composite, :token_bucket, :"$1", :"$2", :"$3", generation}, [], [true]}
    ]

    _ = :ets.select_delete(table, spec)
    :ok
  end

  # -- validation -----------------------------------------------------------

  defp policy(opts) do
    case Keyword.get(opts, :policy, :fixed_window) do
      policy when policy in [:fixed_window, :token_bucket] -> {:ok, policy}
      _ -> {:error, :invalid_rate_limit_policy}
    end
  end

  defp burst(opts, limit) do
    value = Keyword.get(opts, :burst, limit)

    if is_integer(value) and value > 0 and value <= 1_000_000 do
      {:ok, value}
    else
      {:error, :invalid_rate_limit_burst}
    end
  end

  defp idle_ttl(opts, window_ms, max_ttl_ms) do
    default = min(max(window_ms * 2, 1_000), max_ttl_ms)

    case Keyword.get(opts, :idle_ttl_ms, default) do
      value when is_integer(value) and value > 0 and value <= max_ttl_ms -> {:ok, value}
      _ -> {:error, :invalid_rate_limit_idle_ttl}
    end
  end

  defp token_math_bounds(limit, burst, window_ms) do
    max = 9_000_000_000_000_000_000

    if burst * window_ms <= max and limit * window_ms <= max do
      :ok
    else
      {:error, :rate_limit_values_too_large}
    end
  end

  defp rejected(instance) do
    _ = Wiregrid.Metrics.increment(instance, :rate_limit_rejections)
    {:error, :rate_limited}
  end

  defp floor_div(value, divisor) do
    quotient = div(value, divisor)
    if rem(value, divisor) < 0, do: quotient - 1, else: quotient
  end

  defp validate_key(term, max_bytes) do
    case Wiregrid.Validation.safe_size(term) do
      {:ok, size} when size <= max_bytes -> :ok
      _ -> {:error, :rate_limit_key_too_large}
    end
  end

  defp replace_exact(table, old, replacement) do
    :ets.select_replace(table, [{old, [], [{:const, replacement}]}]) == 1
  end
end
