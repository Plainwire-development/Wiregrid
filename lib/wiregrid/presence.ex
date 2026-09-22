defmodule Wiregrid.Presence do
  @moduledoc false

  @builtins [:online, :idle, :dnd, :invisible, :offline]

  def normalize_status(status) when status in @builtins, do: {:ok, status}

  def normalize_status({:custom, value}) when is_binary(value) and byte_size(value) in 1..64,
    do: {:ok, {:custom, value}}

  def normalize_status(_), do: {:error, :invalid_presence_status}

  def get(instance, user_id) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        local = local_entries(t, user_id)
        remote = remote_entries(t, user_id)
        aggregate(local ++ remote, cfg)

      _ ->
        %{status: :offline, sessions: 0, metadata: %{}, updated_at_ms: 0}
    end
  end

  def local_aggregate(instance, user_id) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} -> aggregate(local_entries(t, user_id), cfg)
      _ -> %{status: :offline, sessions: 0, metadata: %{}, updated_at_ms: 0}
    end
  end

  def local_changed(instance, user_id) do
    aggregate = local_aggregate(instance, user_id)
    notify_watchers(instance, user_id)
    Wiregrid.Cluster.presence(instance, user_id, aggregate)
    :ok
  end

  def remote_changed(instance, origin_node, user_id, aggregate) when is_map(aggregate) do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        key = {origin_node, user_id}

        if :ets.member(t.remote_presence, key) do
          true = :ets.insert(t.remote_presence, {key, aggregate})
          notify_watchers(instance, user_id)
          :ok
        else
          with :ok <-
                 Wiregrid.Capacity.reserve(t.capacity, :remote_presence, cfg.max_remote_presence),
               true <- :ets.insert_new(t.remote_presence, {key, aggregate}) do
            true = :ets.insert(t.remote_presence_by_user, {user_id, origin_node})
            true = :ets.insert(t.remote_presence_by_node, {origin_node, user_id})
            notify_watchers(instance, user_id)
            :ok
          else
            false ->
              _ = Wiregrid.Capacity.release(t.capacity, :remote_presence)
              :ok

            {:error, :capacity} ->
              {:error, :remote_presence_capacity}
          end
        end

      _ ->
        {:error, :instance_unavailable}
    end
  end

  def remove_remote_node(instance, origin_node) do
    case Wiregrid.Tables.get(instance) do
      %{tables: t} ->
        :ets.safe_fixtable(t.remote_presence_by_node, true)

        try do
          spec = [{{origin_node, :"$1"}, [], [:"$1"]}]

          remove_remote_presence_batches(
            instance,
            t,
            origin_node,
            :ets.select(t.remote_presence_by_node, spec, 512)
          )
        after
          :ets.safe_fixtable(t.remote_presence_by_node, false)
        end

        :ets.delete(t.remote_presence_by_node, origin_node)
        :ok

      _ ->
        :ok
    end
  end

  defp remove_remote_presence_batches(_instance, _t, _origin_node, :"$end_of_table"), do: :ok

  defp remove_remote_presence_batches(instance, t, origin_node, {users, continuation}) do
    Enum.each(users, fn user_id ->
      key = {origin_node, user_id}

      case :ets.take(t.remote_presence, key) do
        [{^key, _}] ->
          :ets.delete_object(t.remote_presence_by_user, {user_id, origin_node})
          :ets.delete_object(t.remote_presence_by_node, {origin_node, user_id})
          _ = Wiregrid.Capacity.release(t.capacity, :remote_presence)
          notify_watchers(instance, user_id)

        [] ->
          :ok
      end
    end)

    remove_remote_presence_batches(instance, t, origin_node, :ets.select(continuation))
  end

  def notify_watchers(instance, user_id) do
    presence = get(instance, user_id)
    event = %{type: :presence, user_id: user_id, presence: presence}

    case Wiregrid.Tables.get(instance) do
      %{config: cfg} ->
        with {:ok, payload} <- Wiregrid.Codec.encode(cfg, event) do
          _ = Wiregrid.Fanout.presence_watchers(instance, user_id, payload, event)
          :ok
        end

      _ ->
        :ok
    end
  end

  defp local_entries(t, user_id) do
    for {^user_id, sid} <- :ets.lookup(t.user_sessions, user_id),
        [{^sid, session}] <- [:ets.lookup(t.sessions, sid)],
        do: %{
          status: session.status,
          metadata: session.presence_metadata,
          updated_at_ms: session.presence_updated_ms,
          sessions: 1,
          source: {:local, sid}
        }
  end

  defp remote_entries(t, user_id) do
    for {^user_id, origin_node} <- :ets.lookup(t.remote_presence_by_user, user_id),
        [{{^origin_node, ^user_id}, value}] <- [
          :ets.lookup(t.remote_presence, {origin_node, user_id})
        ],
        do: Map.put(value, :source, {:remote, origin_node})
  end

  defp aggregate(entries, cfg) do
    visible = Enum.reject(entries, fn entry -> entry.status in [:offline, :invisible] end)

    session_count =
      Enum.reduce(visible, 0, fn entry, acc -> acc + Map.get(entry, :sessions, 1) end)

    case select_entry(visible, cfg) do
      nil ->
        %{status: :offline, sessions: 0, metadata: %{}, updated_at_ms: 0}

      entry ->
        %{
          status: entry.status,
          sessions: session_count,
          metadata: Map.get(entry, :metadata, %{}),
          updated_at_ms: Map.get(entry, :updated_at_ms, 0)
        }
    end
  end

  defp select_entry([], _cfg), do: nil

  defp select_entry(entries, %{presence_aggregation: :latest}) do
    Enum.max_by(entries, fn entry ->
      {Map.get(entry, :updated_at_ms, 0), Map.get(entry, :source)}
    end)
  end

  defp select_entry(entries, cfg) do
    rank = Map.get(cfg, :presence_rank, %{})
    fallback = map_size(rank) + 1

    Enum.min_by(entries, fn entry ->
      {Map.get(rank, entry.status, fallback), -Map.get(entry, :updated_at_ms, 0),
       Map.get(entry, :source)}
    end)
  end
end
