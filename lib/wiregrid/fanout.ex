defmodule Wiregrid.Fanout do
  @moduledoc false

  def topic(instance, topic, payload, event, class, opts \\ []) do
    stream(instance, :topic, topic, topic, payload, event, class, opts)
  end

  def room(instance, room, payload, event, class, opts \\ []) do
    stream(instance, :room, room, room, payload, event, class, opts)
  end

  def presence_watchers(instance, user_id, payload, event) do
    stream(instance, :presence, user_id, {:user, user_id}, payload, event, :ephemeral, [])
  end

  def user(instance, user_id, payload, event, class) when class in [:durable, :ephemeral] do
    case Wiregrid.Tables.get(instance) do
      %{config: cfg, tables: t} ->
        initial = empty_counts()
        context = %{}
        exclusions = {MapSet.new(), MapSet.new()}

        counts =
          Enum.reduce(:ets.lookup(t.user_sessions, user_id), initial, fn {^user_id, session_id},
                                                                         acc ->
            result =
              Wiregrid.Delivery.send_session_prevalidated(
                instance,
                t,
                cfg,
                session_id,
                {:user, user_id},
                payload,
                event,
                class,
                context,
                exclusions
              )

            bump(acc, result)
          end)

        {:ok, counts}

      _ ->
        {:error, :instance_unavailable}
    end
  end

  defp stream(instance, kind, subject, delivery_topic, payload, event, class, opts) do
    with %{config: cfg, tables: t} <- Wiregrid.Tables.get(instance),
         {:ok, exclusions} <- exclusions(opts),
         {:ok, context} <- delivery_context(opts, cfg) do
      counts =
        Wiregrid.FanoutIndex.reduce(t, kind, subject, empty_counts(), fn session_id, acc ->
          result =
            Wiregrid.Delivery.send_session_prevalidated(
              instance,
              t,
              cfg,
              session_id,
              delivery_topic,
              payload,
              event,
              class,
              context,
              exclusions
            )

          bump(acc, result)
        end)

      {:ok, counts}
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  defp empty_counts,
    do: %{sent: 0, dropped: 0, evicted: 0, gone: 0, excluded: 0, overloaded: 0}

  defp delivery_context(opts, cfg) do
    case Keyword.get(opts, :delivery_context, %{}) do
      context when is_map(context) ->
        case Wiregrid.Validation.metadata(context, cfg.max_metadata_bytes) do
          :ok -> {:ok, context}
          {:error, _} -> {:error, :invalid_delivery_context}
        end

      _ ->
        {:error, :invalid_delivery_context}
    end
  end

  defp bump(counts, :sent), do: Map.update!(counts, :sent, &(&1 + 1))
  defp bump(counts, :dropped), do: Map.update!(counts, :dropped, &(&1 + 1))
  defp bump(counts, :evicted), do: Map.update!(counts, :evicted, &(&1 + 1))
  defp bump(counts, :excluded), do: Map.update!(counts, :excluded, &(&1 + 1))
  defp bump(counts, :overloaded), do: Map.update!(counts, :overloaded, &(&1 + 1))
  defp bump(counts, _), do: Map.update!(counts, :gone, &(&1 + 1))

  defp exclusions(opts) when is_list(opts) do
    with :ok <- Wiregrid.Validation.keyword_opts(opts, [:exclude_sessions, :exclude_users]),
         {:ok, sessions} <- exclusion_set(Keyword.get(opts, :exclude_sessions, [])),
         {:ok, users} <- exclusion_set(Keyword.get(opts, :exclude_users, [])) do
      {:ok, {sessions, users}}
    end
  end

  defp exclusions(_), do: {:error, :invalid_options}

  defp exclusion_set(%MapSet{} = set) do
    if MapSet.size(set) <= 256, do: {:ok, set}, else: {:error, :too_many_exclusions}
  end

  defp exclusion_set(list) when is_list(list) do
    case Wiregrid.Validation.bounded_list(list, 256) do
      :ok -> {:ok, MapSet.new(list)}
      {:error, _} -> {:error, :too_many_exclusions}
    end
  end

  defp exclusion_set(_), do: {:error, :invalid_exclusions}
end
