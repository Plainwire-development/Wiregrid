defmodule Wiregrid.Receipts do
  @moduledoc false

  @option_keys [:ttl_ms, :persist]
  @claim_retries 8

  def put(instance, session_id, receipt, opts \\ [])

  def put(instance, session_id, receipt, opts) when is_map(receipt) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         :ok <- accepting(instance),
         :ok <- Wiregrid.Validation.keyword_opts(opts, @option_keys),
         :ok <- Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes),
         [{^session_id, session}] <- :ets.lookup(t.sessions, session_id),
         {:ok, receipt_id} <- receipt_id(receipt, cfg.max_storage_id_bytes),
         :ok <- Wiregrid.Validation.event(receipt, cfg.max_metadata_bytes),
         :ok <- Wiregrid.Authorizer.check(instance, cfg, :receipt, session, receipt_id, receipt),
         {:ok, ttl_ms} <-
           Wiregrid.Validation.ttl(Keyword.get(opts, :ttl_ms, cfg.receipt_ttl_ms), cfg.max_ttl_ms),
         :ok <-
           maybe_persist(
             instance,
             session.user_id,
             receipt_id,
             receipt,
             Keyword.get(opts, :persist, false)
           ),
         :ok <- store(instance, t, cfg, session, receipt_id, receipt, ttl_ms) do
      :ok
    else
      [] -> {:error, :unknown_session}
      {:error, _} = error -> error
      :undefined -> {:error, :instance_unavailable}
    end
  end

  def put(_instance, _session_id, _receipt, _opts), do: {:error, :invalid_receipt}

  def get(instance, session_id, receipt_id) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        key = {session_id, receipt_id}

        case :ets.lookup(t.receipts, key) do
          [{^key, value}] -> {:ok, value.receipt}
          [] -> :miss
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def expire(instance, key, deadline) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        case :ets.lookup(t.receipts, key) do
          [{^key, %{expires_at_ms: ^deadline} = record}] ->
            remove_record(instance, t, key, record)

          [{^key, %{expires_at_ms: current_deadline} = record}]
          when is_integer(current_deadline) ->
            repair_mismatched_expiry(instance, t, key, record, current_deadline)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  def cleanup_session(instance, session_id) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        keys = for {^session_id, key} <- :ets.lookup(t.receipts_by_session, session_id), do: key
        Enum.each(keys, &remove(instance, t, &1))
        :ets.delete(t.receipts_by_session, session_id)
        :ok

      _ ->
        :ok
    end
  end

  defp store(instance, t, cfg, session, receipt_id, receipt, ttl_ms) do
    store_retry(instance, t, cfg, session, receipt_id, receipt, ttl_ms, 0)
  end

  defp store_retry(_instance, _t, _cfg, _session, _receipt_id, _receipt, _ttl_ms, attempts)
       when attempts >= @claim_retries,
       do: {:error, :receipt_contention}

  defp store_retry(instance, t, cfg, session, receipt_id, receipt, ttl_ms, attempts) do
    key = {session.id, receipt_id}
    expires = System.monotonic_time(:millisecond) + ttl_ms

    with {:ok, owner_token, ownership} <- claim_owner(t, session.id, key, cfg, attempts) do
      record = %{
        session_id: session.id,
        receipt: receipt,
        owner_token: owner_token,
        expires_at_ms: expires
      }

      case install_record(t, key, record, ownership) do
        :ok ->
          true = :ets.insert(t.receipts_by_session, {session.id, key})

          result =
            with :ok <- Wiregrid.Expiry.schedule_at(instance, :receipt, key, expires),
                 [{^key, ^owner_token}] <- :ets.lookup(t.receipt_keys, key),
                 [{_, live}] when live.monitor == session.monitor <-
                   :ets.lookup(t.sessions, session.id) do
              :ok
            else
              [] -> {:error, :unknown_session}
              {:error, _} = error -> error
              _ -> {:error, :receipt_failed}
            end

          if result != :ok, do: rollback_record(instance, t, key, record)
          result

        :retry ->
          if ownership == :new, do: abandon_new_owner(t, session.id, key, owner_token)
          store_retry(instance, t, cfg, session, receipt_id, receipt, ttl_ms, attempts + 1)
      end
    end
  end

  defp claim_owner(_t, _sid, _key, _cfg, attempts) when attempts >= @claim_retries,
    do: {:error, :receipt_contention}

  defp claim_owner(t, sid, key, cfg, attempts) do
    case :ets.lookup(t.receipt_keys, key) do
      [{^key, token}] ->
        {:ok, token, :existing}

      [] ->
        case Wiregrid.Capacity.reserve(t.capacity, :receipt_entries, cfg.max_receipt_entries) do
          :ok -> claim_new_owner(t, sid, key, cfg, attempts)
          {:error, :capacity} -> {:error, :receipt_capacity}
          {:error, _} = error -> error
        end
    end
  end

  defp claim_new_owner(t, sid, key, cfg, attempts) do
    case :wiregrid_hot.session_counter_add(t.session_counters, sid, 4, 1) do
      {:ok, count} when count <= cfg.max_receipts_per_session ->
        token = System.unique_integer([:positive, :monotonic])

        if :ets.insert_new(t.receipt_keys, {key, token}) do
          {:ok, token, :new}
        else
          _ = :wiregrid_hot.session_counter_add(t.session_counters, sid, 4, -1)
          _ = Wiregrid.Capacity.release(t.capacity, :receipt_entries)
          claim_owner(t, sid, key, cfg, attempts + 1)
        end

      {:ok, _count} ->
        _ = :wiregrid_hot.session_counter_add(t.session_counters, sid, 4, -1)
        _ = Wiregrid.Capacity.release(t.capacity, :receipt_entries)
        {:error, :receipt_capacity}

      {:error, _} ->
        _ = Wiregrid.Capacity.release(t.capacity, :receipt_entries)
        {:error, :unknown_session}
    end
  end

  defp install_record(t, key, record, :new) do
    if :ets.insert_new(t.receipts, {key, record}), do: :ok, else: :retry
  end

  defp install_record(t, key, %{owner_token: token} = record, :existing) do
    case :ets.lookup(t.receipts, key) do
      [{^key, %{owner_token: ^token} = previous}] ->
        if replace_exact(t.receipts, {key, previous}, {key, record}), do: :ok, else: :retry

      _ ->
        :retry
    end
  end

  defp abandon_new_owner(t, session_id, key, token) do
    if :ets.select_delete(t.receipt_keys, [{{key, token}, [], [true]}]) == 1 do
      _ = :wiregrid_hot.session_counter_add(t.session_counters, session_id, 4, -1)
      _ = Wiregrid.Capacity.release(t.capacity, :receipt_entries)
    end

    :ok
  end

  defp rollback_record(instance, t, key, record) do
    if delete_record_exact(t.receipts, key, record) do
      release_generation(instance, t, key, record)
    end

    :ok
  end

  defp remove(instance, t, key) do
    case :ets.lookup(t.receipts, key) do
      [{^key, record}] -> remove_record(instance, t, key, record)
      [] -> :ok
    end
  end

  defp remove_record(instance, t, key, record) do
    if delete_record_exact(t.receipts, key, record) do
      release_generation(instance, t, key, record)
    end

    :ok
  end

  defp release_generation(instance, t, key, record) do
    token = record.owner_token
    :ets.delete_object(t.receipts_by_session, {record.session_id, key})
    owner_spec = [{{key, token}, [], [true]}]

    _ = Wiregrid.Expiry.cancel(instance, :receipt, key)

    if :ets.select_delete(t.receipt_keys, owner_spec) == 1 do
      _ = :wiregrid_hot.session_counter_add(t.session_counters, record.session_id, 4, -1)
      _ = Wiregrid.Capacity.release(t.capacity, :receipt_entries)
    end

    :ok
  end

  defp delete_record_exact(table, key, record) do
    :ets.select_delete(table, [{{key, record}, [], [true]}]) == 1
  end

  defp replace_exact(table, old, replacement) do
    :ets.select_replace(table, [{old, [], [{:const, replacement}]}]) == 1
  end

  defp repair_mismatched_expiry(instance, t, key, record, current_deadline) do
    if current_deadline <= System.monotonic_time(:millisecond) do
      remove_record(instance, t, key, record)
    else
      _ = Wiregrid.Expiry.schedule_at(instance, :receipt, key, current_deadline)
      :ok
    end
  end

  defp accepting(instance), do: Wiregrid.Runtime.accepting(instance)

  defp receipt_id(receipt, max_bytes) do
    value = Map.get(receipt, :id, Map.get(receipt, "id"))

    case Wiregrid.Validation.binary_id(value, max_bytes) do
      :ok -> {:ok, value}
      error -> error
    end
  end

  defp maybe_persist(_instance, _user_id, _id, _receipt, false), do: :ok

  defp maybe_persist(instance, user_id, id, receipt, true) do
    case Wiregrid.Storage.append(instance, {:receipt, user_id}, id, receipt, %{kind: :receipt}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:persistence_failed, reason}}
    end
  end

  defp maybe_persist(_instance, _user_id, _id, _receipt, _), do: {:error, :invalid_persist_option}
end
