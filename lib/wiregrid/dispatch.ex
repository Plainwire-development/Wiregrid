defmodule Wiregrid.Dispatch do
  @moduledoc """
  Bounded heterogeneous event dispatch.

  A dispatch accepts ordinary Wiregrid targets:

      {:topic, topic}
      {:room, room}
      {:user, user_id}
      {:session, session_id}

  The event is prepared once and reused across every target group. Targets are
  validated and deduplicated before the first side effect. Group execution is
  intentionally not transactional: each group reports its own result so a
  caller can decide whether and how to retry a partial dispatch.
  """

  @direct_keys [:class, :session_id]
  @user_keys [:class, :session_id, :cluster]
  @publish_keys [
    :event_id,
    :persist,
    :meta,
    :class,
    :session_id,
    :cluster,
    :exclude_sessions,
    :exclude_users
  ]

  @type target ::
          {:topic, term()}
          | {:room, term()}
          | {:user, term()}
          | {:session, binary()}

  @spec dispatch(term(), [target()], term(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch(instance, targets, event, opts \\ []) do
    with {:ok, prepared} <- Wiregrid.prepare(instance, event) do
      dispatch_prepared(instance, targets, prepared, opts)
    end
  end

  @spec dispatch_prepared(term(), [target()], term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_prepared(instance, targets, prepared, opts \\ []) do
    with %{config: cfg} <- Wiregrid.Tables.get(instance),
         {:ok, grouped} <- normalize_targets(targets, cfg) do
      execute_groups(instance, grouped, prepared, opts)
    else
      :undefined -> {:error, :instance_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Executes a reusable integrity-bound dispatch plan."
  @spec dispatch_plan(term(), Wiregrid.DispatchPlan.t(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_plan(instance, plan, event, opts \\ []) do
    with {:ok, prepared} <- Wiregrid.prepare(instance, event) do
      dispatch_plan_prepared(instance, plan, prepared, opts)
    end
  end

  @doc "Executes a reusable dispatch plan with an already prepared event."
  @spec dispatch_plan_prepared(term(), Wiregrid.DispatchPlan.t(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_plan_prepared(instance, plan, prepared, opts \\ []) do
    result =
      with {:ok, grouped} <- Wiregrid.DispatchPlan.unpack(instance, plan) do
        execute_groups(instance, grouped, prepared, opts)
      end

    case result do
      {:ok, _} -> _ = Wiregrid.Metrics.increment(instance, :dispatch_plan_executions)
      {:error, _} -> _ = Wiregrid.Metrics.increment(instance, :dispatch_plan_failures)
    end

    result
  end

  @doc false
  def normalize_targets(targets, cfg) do
    with :ok <- Wiregrid.Validation.bounded_list(targets, cfg.max_batch_targets),
         true <- targets != [] do
      targets
      |> Enum.reduce_while({:ok, empty_groups()}, fn target, {:ok, groups} ->
        case normalize_target(target, cfg) do
          {:ok, kind, value} -> {:cont, {:ok, put_target(groups, kind, value)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> finalize_groups()
    else
      false -> {:error, :empty_targets}
      {:error, _} = error -> error
    end
  end

  defp execute_groups(instance, grouped, prepared, opts) do
    with :ok <- Wiregrid.Validation.keyword_opts(opts, @publish_keys),
         {:ok, _event, _payload} <- Wiregrid.Prepared.unpack(instance, prepared) do
      event_id = Keyword.get(opts, :event_id, Wiregrid.ID.generate())
      publish_opts = Keyword.put(opts, :event_id, event_id)
      direct_opts = Keyword.take(opts, @direct_keys)
      user_opts = Keyword.take(opts, @user_keys)

      results = %{
        topics:
          run_group(
            grouped.topics,
            &Wiregrid.publish_topics_prepared(instance, &1, prepared, publish_opts)
          ),
        rooms:
          run_group(
            grouped.rooms,
            &Wiregrid.publish_rooms_prepared(instance, &1, prepared, publish_opts)
          ),
        users:
          run_group(
            grouped.users,
            &Wiregrid.send_users_prepared(instance, &1, prepared, user_opts)
          ),
        sessions:
          run_group(
            grouped.sessions,
            &Wiregrid.send_sessions_prepared(instance, &1, prepared, direct_opts)
          )
      }

      failed_groups = Enum.count(results, fn {_kind, result} -> match?({:error, _}, result) end)

      {:ok,
       %{
         event_id: event_id,
         target_count: grouped.count,
         failed_groups: failed_groups,
         partial: failed_groups > 0,
         groups: results
       }}
    end
  end

  defp normalize_target({:topic, topic}, cfg) do
    case Wiregrid.Validation.topic(topic, cfg.max_topic_bytes, cfg.max_topic_depth) do
      :ok -> {:ok, :topics, topic}
      {:error, _} = error -> error
    end
  end

  defp normalize_target({:room, room}, cfg) do
    case Wiregrid.Validation.topic(room, cfg.max_topic_bytes, cfg.max_topic_depth) do
      :ok -> {:ok, :rooms, room}
      {:error, _} = error -> error
    end
  end

  defp normalize_target({:user, user_id}, cfg) do
    case Wiregrid.Validation.id(user_id, cfg.max_user_id_bytes) do
      {:ok, _} -> {:ok, :users, user_id}
      {:error, _} = error -> error
    end
  end

  defp normalize_target({:session, session_id}, cfg) do
    case Wiregrid.Validation.session_id(session_id, cfg.max_session_id_bytes) do
      :ok -> {:ok, :sessions, session_id}
      {:error, _} = error -> error
    end
  end

  defp normalize_target(_, _cfg), do: {:error, :invalid_dispatch_target}

  defp empty_groups do
    %{
      topics: MapSet.new(),
      rooms: MapSet.new(),
      users: MapSet.new(),
      sessions: MapSet.new(),
      count: 0
    }
  end

  defp put_target(groups, kind, value) do
    set = Map.fetch!(groups, kind)

    if MapSet.member?(set, value) do
      groups
    else
      groups |> Map.put(kind, MapSet.put(set, value)) |> Map.update!(:count, &(&1 + 1))
    end
  end

  defp finalize_groups({:ok, groups}) do
    {:ok,
     %{
       topics: MapSet.to_list(groups.topics),
       rooms: MapSet.to_list(groups.rooms),
       users: MapSet.to_list(groups.users),
       sessions: MapSet.to_list(groups.sessions),
       count: groups.count
     }}
  end

  defp finalize_groups(error), do: error

  defp run_group([], _fun), do: :skipped
  defp run_group(items, fun), do: fun.(items)
end
