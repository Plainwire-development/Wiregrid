defmodule Wiregrid.Cache.Memory do
  @moduledoc "Bounded in-VM ETS cache with generation-safe concurrent ownership."
  @behaviour Wiregrid.Cache

  @max_retries 32

  @impl true
  def get(opts, key) do
    with {:ok, instance, t, _cfg} <- tables(opts) do
      read(instance, t, key)
    end
  end

  @impl true
  def put(opts, key, value, ttl) do
    with {:ok, instance, t, cfg} <- tables(opts),
         {:ok, expires} <- expiry(ttl) do
      put_retry(instance, t, cfg, key, value, ttl, expires, 0)
    end
  end

  @impl true
  def delete(opts, key) do
    with {:ok, instance, t, _cfg} <- tables(opts) do
      delete_owned(instance, t, key)
      :ok
    end
  end

  @impl true
  def incr(opts, key, delta, ttl) when is_integer(delta) do
    with {:ok, instance, t, cfg} <- tables(opts),
         {:ok, expires} <- expiry(ttl) do
      incr_retry(instance, t, cfg, key, delta, ttl, expires, 0)
    end
  end

  def incr(_opts, _key, _delta, _ttl), do: {:error, :invalid_delta}

  @impl true
  def health(opts) do
    case tables(opts) do
      {:ok, _instance, _t, _cfg} -> :ok
      {:error, _} = error -> error
    end
  end

  def expire(instance, {key, token}, deadline) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        case :ets.lookup(t.memory_cache, key) do
          [{^key, ^token, _type, _value, ^deadline} = stale] ->
            expire_exact(instance, t, key, token, stale)

          [{^key, ^token, _type, _value, current_deadline} = current]
          when is_integer(current_deadline) ->
            if current_deadline <= System.monotonic_time(:millisecond) do
              expire_exact(instance, t, key, token, current)
            else
              _ =
                Wiregrid.Expiry.schedule_at(
                  instance,
                  :memory_cache,
                  {key, token},
                  current_deadline
                )

              :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  def expire(_instance, _generation, _deadline), do: :ok

  defp read(instance, t, key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(t.memory_cache, key) do
      [{^key, token, type, value, :infinity}] ->
        if owner?(t, key, token),
          do: decode_type(type, value),
          else: cleanup_orphan(t, key, token)

      [{^key, token, type, value, expires}] when expires > now ->
        if owner?(t, key, token),
          do: decode_type(type, value),
          else: cleanup_orphan(t, key, token)

      [{^key, token, _type, _value, _expires} = stale] ->
        expire_exact(instance, t, key, token, stale)
        :miss

      [] ->
        :miss
    end
  end

  defp put_retry(_instance, _t, _cfg, _key, _value, _ttl, _expires, attempts)
       when attempts >= @max_retries,
       do: {:error, :cache_contention}

  defp put_retry(instance, t, cfg, key, value, ttl, expires, attempts) do
    case acquire_owner(t, cfg, key, attempts) do
      {:ok, token} ->
        record = {key, token, :value, value, expires}
        true = :ets.insert(t.memory_cache, record)

        if owner?(t, key, token) do
          case schedule(instance, key, token, ttl, expires) do
            :ok ->
              if owner?(t, key, token) do
                :ok
              else
                _ = delete_record(t.memory_cache, record)
                put_retry(instance, t, cfg, key, value, ttl, expires, attempts + 1)
              end

            {:error, _} = error ->
              delete_owned(instance, t, key)
              error
          end
        else
          _ = delete_record(t.memory_cache, record)
          put_retry(instance, t, cfg, key, value, ttl, expires, attempts + 1)
        end

      {:retry, next} ->
        put_retry(instance, t, cfg, key, value, ttl, expires, next)

      {:error, _} = error ->
        error
    end
  end

  defp incr_retry(_instance, _t, _cfg, _key, _delta, _ttl, _expires, attempts)
       when attempts >= @max_retries,
       do: {:error, :cache_contention}

  defp incr_retry(instance, t, cfg, key, delta, ttl, expires, attempts) do
    case acquire_owner(t, cfg, key, attempts) do
      {:ok, token} ->
        now = System.monotonic_time(:millisecond)

        case :ets.lookup(t.memory_cache, key) do
          [] ->
            record = {key, token, :counter, delta, expires}

            # insert_new fails when another writer already stored this key.
            # The losing tuple can be identical (same token, delta, and
            # millisecond deadline), so a failed insert must not delete the
            # winner's row.
            if :ets.insert_new(t.memory_cache, record) do
              if owner?(t, key, token) do
                case schedule(instance, key, token, ttl, expires) do
                  :ok ->
                    if owner?(t, key, token) do
                      {:ok, delta}
                    else
                      _ = delete_record(t.memory_cache, record)
                      incr_retry(instance, t, cfg, key, delta, ttl, expires, attempts + 1)
                    end

                  {:error, _} = error ->
                    delete_owned(instance, t, key)
                    error
                end
              else
                _ = delete_record(t.memory_cache, record)
                incr_retry(instance, t, cfg, key, delta, ttl, expires, attempts + 1)
              end
            else
              incr_retry(instance, t, cfg, key, delta, ttl, expires, attempts + 1)
            end

          [{^key, ^token, :counter, value, old_expiry} = old]
          when old_expiry == :infinity or old_expiry > now ->
            next = value + delta
            replacement = {key, token, :counter, next, expires}

            if replace_exact(t.memory_cache, old, replacement) and owner?(t, key, token) do
              case schedule(instance, key, token, ttl, expires) do
                :ok ->
                  if owner?(t, key, token) do
                    {:ok, next}
                  else
                    incr_retry(instance, t, cfg, key, delta, ttl, expires, attempts + 1)
                  end

                {:error, _} = error ->
                  delete_owned(instance, t, key)
                  error
              end
            else
              incr_retry(instance, t, cfg, key, delta, ttl, expires, attempts + 1)
            end

          [{^key, ^token, :value, _value, old_expiry}]
          when old_expiry == :infinity or old_expiry > now ->
            {:error, :not_a_counter}

          [{^key, ^token, _type, _value, _old_expiry} = stale] ->
            expire_exact(instance, t, key, token, stale)
            incr_retry(instance, t, cfg, key, delta, ttl, expires, attempts + 1)

          [{^key, other_token, _type, _value, _expiry}] when other_token != token ->
            incr_retry(instance, t, cfg, key, delta, ttl, expires, attempts + 1)
        end

      {:retry, next} ->
        incr_retry(instance, t, cfg, key, delta, ttl, expires, next)

      {:error, _} = error ->
        error
    end
  end

  defp acquire_owner(_t, _cfg, _key, attempts) when attempts >= @max_retries,
    do: {:error, :cache_contention}

  defp acquire_owner(t, cfg, key, attempts) do
    case :ets.lookup(t.memory_cache_keys, key) do
      [{^key, token, :ready}] ->
        {:ok, token}

      [{^key, _token, :deleting}] ->
        {:retry, attempts + 1}

      [] ->
        case Wiregrid.Capacity.reserve(t.capacity, :cache_entries, cfg.max_cache_entries) do
          :ok ->
            token = :erlang.unique_integer([:positive, :monotonic])
            owner = {key, token, :ready}

            if :ets.insert_new(t.memory_cache_keys, owner) do
              {:ok, token}
            else
              _ = Wiregrid.Capacity.release(t.capacity, :cache_entries)
              {:retry, attempts + 1}
            end

          {:error, :capacity} ->
            {:error, :cache_capacity}
        end
    end
  end

  defp delete_owned(instance, t, key) do
    case :ets.lookup(t.memory_cache_keys, key) do
      [{^key, token, :ready} = owner] ->
        deleting = {key, token, :deleting}

        if replace_exact(t.memory_cache_keys, owner, deleting) do
          delete_value_generation(t, key, token)
          _ = Wiregrid.Expiry.cancel(instance, :memory_cache, {key, token})
          _ = delete_record(t.memory_cache_keys, deleting)
          _ = Wiregrid.Capacity.release(t.capacity, :cache_entries)
        end

      [{^key, _token, :deleting}] ->
        :ok

      [] ->
        :ok
    end
  end

  defp expire_exact(instance, t, key, token, {_key, _token, _type, _value, deadline}) do
    owner = {key, token, :ready}
    deleting = {key, token, :deleting}

    if replace_exact(t.memory_cache_keys, owner, deleting) do
      spec = [{{key, token, :"$1", :"$2", deadline}, [], [true]}]

      if :ets.select_delete(t.memory_cache, spec) == 1 do
        # A writer that observed the old owner before the transition may still
        # be in flight. Removing the entire generation makes its subsequent
        # owner check fail and its retry harmless.
        delete_value_generation(t, key, token)
        _ = Wiregrid.Expiry.cancel(instance, :memory_cache, {key, token})
        _ = delete_record(t.memory_cache_keys, deleting)
        _ = Wiregrid.Capacity.release(t.capacity, :cache_entries)
      else
        # The exact stale value was refreshed before we obtained deletion
        # ownership. Put the generation back in service; the refreshing writer
        # will either have scheduled its current deadline or will retry.
        _ = replace_exact(t.memory_cache_keys, deleting, owner)
      end
    end

    :ok
  end

  defp owner?(t, key, token), do: :ets.lookup(t.memory_cache_keys, key) == [{key, token, :ready}]

  defp cleanup_orphan(t, key, token) do
    delete_value_generation(t, key, token)
    :miss
  end

  defp delete_value_generation(t, key, token) do
    spec = [{{key, token, :"$1", :"$2", :"$3"}, [], [true]}]
    _ = :ets.select_delete(t.memory_cache, spec)
    :ok
  end

  defp replace_exact(table, old, replacement) do
    :ets.select_replace(table, [{old, [], [{:const, replacement}]}]) == 1
  end

  defp delete_record(table, record) do
    :ets.select_delete(table, [{record, [], [true]}]) == 1
  end

  defp decode_type(:value, value), do: {:ok, value}
  defp decode_type(:counter, value), do: {:ok, value}

  defp schedule(_instance, _key, _token, :infinity, :infinity), do: :ok

  defp schedule(instance, key, token, _ttl, expires),
    do: Wiregrid.Expiry.schedule_at(instance, :memory_cache, {key, token}, expires)

  defp expiry(:infinity), do: {:ok, :infinity}

  defp expiry(ms) when is_integer(ms) and ms > 0,
    do: {:ok, System.monotonic_time(:millisecond) + ms}

  defp expiry(_), do: {:error, :invalid_ttl}

  defp tables(opts) do
    instance = Keyword.get(opts, :instance)

    case Wiregrid.Tables.get(instance) do
      %{tables: t, config: cfg} -> {:ok, instance, t, cfg}
      _ -> {:error, :instance_unavailable}
    end
  end
end
