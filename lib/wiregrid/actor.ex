defmodule Wiregrid.Actor do
  @moduledoc """
  Session-bound Elixir API for authenticated realtime application code.

  An actor is a lightweight value containing only an instance identifier and a
  live Wiregrid session identifier. It does **not** cache permissions or runtime
  state. Every operation still crosses the canonical Wiregrid API and therefore
  re-checks authorization, drain state, limits and backpressure.

  The main benefit is safety and ergonomics: operations which normally accept a
  `:session_id` option bind it automatically and reject attempts to override the
  actor identity.

      {:ok, actor} = Wiregrid.connect_actor(:chat, user_id, self())
      :ok = Wiregrid.Actor.subscribe(actor, {:channel, "general"})
      {:ok, _} = Wiregrid.Actor.publish(actor, {:channel, "general"}, %{body: "hi"})

  `Wiregrid.Actor` is intentionally Elixir-specific. Erlang, Gleam and LFE use
  the stable plain-term `wiregrid_api` façade directly.
  """

  @enforce_keys [:instance, :session_id]
  defstruct [:instance, :session_id, :user_id]

  @opaque t :: %__MODULE__{
            instance: term(),
            session_id: binary(),
            user_id: term() | nil
          }

  @type result(value) :: {:ok, value} | {:error, term()}

  @doc "Builds an actor for an existing live session after validating it."
  @spec new(term(), binary()) :: result(t())
  def new(instance, session_id) do
    with {:ok, session} <- Wiregrid.session(instance, session_id) do
      {:ok, %__MODULE__{instance: instance, session_id: session_id, user_id: session.user_id}}
    end
  end

  @doc "Returns the actor's Wiregrid instance identifier."
  @spec instance(t()) :: term()
  def instance(%__MODULE__{instance: instance}), do: instance

  @doc "Returns the actor's session identifier."
  @spec session_id(t()) :: binary()
  def session_id(%__MODULE__{session_id: session_id}), do: session_id

  @doc "Returns the user identifier captured when the actor was constructed."
  @spec user_id(t()) :: term() | nil
  def user_id(%__MODULE__{user_id: user_id}), do: user_id

  @doc "Returns the current sanitized session view."
  @spec session(t()) :: result(map())
  def session(%__MODULE__{} = actor), do: Wiregrid.session(actor.instance, actor.session_id)

  @doc "Disconnects the actor's session."
  @spec disconnect(t(), term()) :: :ok | {:error, term()}
  def disconnect(%__MODULE__{} = actor, reason \\ :normal),
    do: Wiregrid.disconnect(actor.instance, actor.session_id, reason)

  @doc "Returns this actor's current outstanding delivery reservations."
  @spec pending(t()) :: non_neg_integer()
  def pending(%__MODULE__{} = actor), do: Wiregrid.pending(actor.instance, actor.session_id)

  @doc "Acknowledges one delivery owned by the actor session."
  @spec ack(t(), binary()) :: result(non_neg_integer())
  def ack(%__MODULE__{} = actor, delivery_id),
    do: Wiregrid.ack(actor.instance, actor.session_id, delivery_id)

  @doc "Acknowledges a bounded set of deliveries owned by the actor session."
  @spec ack_many(t(), [binary()]) :: result(map())
  def ack_many(%__MODULE__{} = actor, delivery_ids),
    do: Wiregrid.ack_many(actor.instance, actor.session_id, delivery_ids)

  @doc "Updates the actor session metadata."
  @spec set_metadata(t(), map()) :: :ok | {:error, term()}
  def set_metadata(%__MODULE__{} = actor, metadata),
    do: Wiregrid.set_session_metadata(actor.instance, actor.session_id, metadata)

  # Subscription topology ----------------------------------------------------

  @spec subscribe(t(), term(), map()) :: :ok | {:error, term()}
  def subscribe(%__MODULE__{} = actor, topic, context \\ %{}),
    do: Wiregrid.subscribe(actor.instance, actor.session_id, topic, context)

  @spec unsubscribe(t(), term()) :: :ok | {:error, term()}
  def unsubscribe(%__MODULE__{} = actor, topic),
    do: Wiregrid.unsubscribe(actor.instance, actor.session_id, topic)

  @spec subscribe_many(t(), list(), map()) :: result(map())
  def subscribe_many(%__MODULE__{} = actor, topics, context \\ %{}),
    do: Wiregrid.subscribe_many(actor.instance, actor.session_id, topics, context)

  @spec unsubscribe_many(t(), list()) :: result(map())
  def unsubscribe_many(%__MODULE__{} = actor, topics),
    do: Wiregrid.unsubscribe_many(actor.instance, actor.session_id, topics)

  @spec sync_subscriptions(t(), list(), map()) :: result(map())
  def sync_subscriptions(%__MODULE__{} = actor, topics, context \\ %{}),
    do: Wiregrid.sync_subscriptions(actor.instance, actor.session_id, topics, context)

  @doc "Reconciles selected session topology domains in one serialized lifecycle turn."
  @spec sync_topology(t(), map(), keyword()) :: result(map())
  def sync_topology(%__MODULE__{} = actor, topology, opts \\ []),
    do: Wiregrid.sync_topology(actor.instance, actor.session_id, topology, opts)

  @doc "Returns a bounded sanitized snapshot of this session and its local topology."
  @spec state(t(), pos_integer() | nil) :: result(map())
  def state(%__MODULE__{} = actor, limit \\ nil),
    do: Wiregrid.session_state(actor.instance, actor.session_id, limit)

  @doc "Returns this actor's bounded subscription list."
  @spec subscriptions(t(), pos_integer() | nil) :: result(list())
  def subscriptions(%__MODULE__{} = actor, limit \\ nil),
    do: Wiregrid.subscriptions(actor.instance, actor.session_id, limit)

  @doc "Returns this actor's bounded room membership list."
  @spec rooms(t(), pos_integer() | nil) :: result(list())
  def rooms(%__MODULE__{} = actor, limit \\ nil),
    do: Wiregrid.session_rooms(actor.instance, actor.session_id, limit)

  @doc "Returns this actor's bounded presence-watch list."
  @spec presence_watches(t(), pos_integer() | nil) :: result(list())
  def presence_watches(%__MODULE__{} = actor, limit \\ nil),
    do: Wiregrid.presence_watches(actor.instance, actor.session_id, limit)

  # Presence -----------------------------------------------------------------

  @spec set_presence(t(), term(), map()) :: :ok | {:error, term()}
  def set_presence(%__MODULE__{} = actor, status, metadata \\ %{}),
    do: Wiregrid.set_presence(actor.instance, actor.session_id, status, metadata)

  @spec watch_presence(t(), term(), map()) :: :ok | {:error, term()}
  def watch_presence(%__MODULE__{} = actor, user_id, context \\ %{}),
    do: Wiregrid.watch_presence(actor.instance, actor.session_id, user_id, context)

  @spec unwatch_presence(t(), term()) :: :ok | {:error, term()}
  def unwatch_presence(%__MODULE__{} = actor, user_id),
    do: Wiregrid.unwatch_presence(actor.instance, actor.session_id, user_id)

  @spec watch_presence_many(t(), list(), map()) :: result(map())
  def watch_presence_many(%__MODULE__{} = actor, user_ids, context \\ %{}),
    do: Wiregrid.watch_presence_many(actor.instance, actor.session_id, user_ids, context)

  @spec unwatch_presence_many(t(), list()) :: result(map())
  def unwatch_presence_many(%__MODULE__{} = actor, user_ids),
    do: Wiregrid.unwatch_presence_many(actor.instance, actor.session_id, user_ids)

  @spec sync_presence_watches(t(), list(), map()) :: result(map())
  def sync_presence_watches(%__MODULE__{} = actor, user_ids, context \\ %{}),
    do: Wiregrid.sync_presence_watches(actor.instance, actor.session_id, user_ids, context)

  # Rooms --------------------------------------------------------------------

  @spec join_room(t(), term(), keyword()) :: :ok | {:error, term()}
  def join_room(%__MODULE__{} = actor, room, opts \\ []),
    do: Wiregrid.join_room(actor.instance, room, actor.session_id, opts)

  @spec leave_room(t(), term()) :: :ok | {:error, term()}
  def leave_room(%__MODULE__{} = actor, room),
    do: Wiregrid.leave_room(actor.instance, room, actor.session_id)

  @spec join_rooms(t(), list(), keyword()) :: result(map())
  def join_rooms(%__MODULE__{} = actor, rooms, opts \\ []),
    do: Wiregrid.join_rooms(actor.instance, rooms, actor.session_id, opts)

  @spec leave_rooms(t(), list()) :: result(map())
  def leave_rooms(%__MODULE__{} = actor, rooms),
    do: Wiregrid.leave_rooms(actor.instance, rooms, actor.session_id)

  @spec sync_rooms(t(), list(), keyword()) :: result(map())
  def sync_rooms(%__MODULE__{} = actor, rooms, opts \\ []),
    do: Wiregrid.sync_rooms(actor.instance, actor.session_id, rooms, opts)

  @spec set_room_metadata(t(), term(), map(), keyword()) :: :ok | {:error, term()}
  def set_room_metadata(%__MODULE__{} = actor, room, metadata, opts \\ []),
    do: Wiregrid.set_room_metadata(actor.instance, room, actor.session_id, metadata, opts)

  @spec set_room_ttl(t(), term(), non_neg_integer() | nil) :: :ok | {:error, term()}
  def set_room_ttl(%__MODULE__{} = actor, room, ttl_ms),
    do: Wiregrid.set_room_ttl(actor.instance, room, actor.session_id, ttl_ms)

  # Ephemeral state ----------------------------------------------------------

  @spec activity(t(), term(), term(), term(), keyword()) :: :ok | {:error, term()}
  def activity(%__MODULE__{} = actor, topic, kind, value, opts \\ []),
    do: Wiregrid.activity(actor.instance, actor.session_id, topic, kind, value, opts)

  @spec typing(t(), term(), keyword()) :: :ok | {:error, term()}
  def typing(%__MODULE__{} = actor, topic, opts \\ []),
    do: Wiregrid.typing(actor.instance, actor.session_id, topic, opts)

  @spec receipt(t(), map(), keyword()) :: :ok | {:error, term()}
  def receipt(%__MODULE__{} = actor, receipt, opts \\ []),
    do: Wiregrid.receipt(actor.instance, actor.session_id, receipt, opts)

  @doc "Replays a bounded durable stream page to this actor through normal backpressure."
  @spec replay(t(), term(), keyword()) :: result(map())
  def replay(%__MODULE__{} = actor, stream, opts \\ []),
    do: Wiregrid.replay_session(actor.instance, actor.session_id, stream, opts)

  @doc "Checks a rate-limit bucket using this actor session as the limiter key."
  @spec rate_limit(t(), term(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def rate_limit(%__MODULE__{} = actor, bucket, limit, window_ms, opts \\ []),
    do: Wiregrid.rate_limit(actor.instance, bucket, actor.session_id, limit, window_ms, opts)

  # Signaling/request-reply --------------------------------------------------

  @spec signal(t(), term(), term(), term(), keyword()) :: result(map())
  def signal(%__MODULE__{} = actor, room, kind, payload, opts \\ []),
    do: Wiregrid.signal(actor.instance, room, actor.session_id, kind, payload, opts)

  @spec request_session(t(), binary(), term(), keyword()) :: result(map())
  def request_session(%__MODULE__{} = actor, target_session, event, opts \\ []),
    do: Wiregrid.request_session(actor.instance, actor.session_id, target_session, event, opts)

  @spec reply(t(), map(), term(), keyword()) :: result(map())
  def reply(%__MODULE__{} = actor, request_envelope, event, opts \\ []),
    do: Wiregrid.reply(actor.instance, actor.session_id, request_envelope, event, opts)

  # Authenticated publish/direct delivery -----------------------------------

  @spec publish(t(), term(), term(), keyword()) :: result(map())
  def publish(%__MODULE__{} = actor, topic, event, opts \\ []),
    do: authenticated(actor, opts, &Wiregrid.publish(actor.instance, topic, event, &1))

  @spec publish_prepared(t(), term(), term(), keyword()) :: result(map())
  def publish_prepared(%__MODULE__{} = actor, topic, prepared, opts \\ []),
    do:
      authenticated(actor, opts, &Wiregrid.publish_prepared(actor.instance, topic, prepared, &1))

  @spec publish_topics(t(), list(), term(), keyword()) :: result(map())
  def publish_topics(%__MODULE__{} = actor, topics, event, opts \\ []),
    do: authenticated(actor, opts, &Wiregrid.publish_topics(actor.instance, topics, event, &1))

  @spec publish_topics_prepared(t(), list(), term(), keyword()) :: result(map())
  def publish_topics_prepared(%__MODULE__{} = actor, topics, prepared, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.publish_topics_prepared(actor.instance, topics, prepared, &1)
      )

  @spec publish_room(t(), term(), term(), keyword()) :: result(map())
  def publish_room(%__MODULE__{} = actor, room, event, opts \\ []),
    do: authenticated(actor, opts, &Wiregrid.publish_room(actor.instance, room, event, &1))

  @spec publish_room_prepared(t(), term(), term(), keyword()) :: result(map())
  def publish_room_prepared(%__MODULE__{} = actor, room, prepared, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.publish_room_prepared(actor.instance, room, prepared, &1)
      )

  @spec publish_rooms(t(), list(), term(), keyword()) :: result(map())
  def publish_rooms(%__MODULE__{} = actor, rooms, event, opts \\ []),
    do: authenticated(actor, opts, &Wiregrid.publish_rooms(actor.instance, rooms, event, &1))

  @spec publish_rooms_prepared(t(), list(), term(), keyword()) :: result(map())
  def publish_rooms_prepared(%__MODULE__{} = actor, rooms, prepared, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.publish_rooms_prepared(actor.instance, rooms, prepared, &1)
      )

  @spec send_user(t(), term(), term(), keyword()) :: result(map())
  def send_user(%__MODULE__{} = actor, user_id, event, opts \\ []),
    do: authenticated(actor, opts, &Wiregrid.send_user(actor.instance, user_id, event, &1))

  @spec send_user_prepared(t(), term(), term(), keyword()) :: result(map())
  def send_user_prepared(%__MODULE__{} = actor, user_id, prepared, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.send_user_prepared(actor.instance, user_id, prepared, &1)
      )

  @spec send_users(t(), list(), term(), keyword()) :: result(map())
  def send_users(%__MODULE__{} = actor, user_ids, event, opts \\ []),
    do: authenticated(actor, opts, &Wiregrid.send_users(actor.instance, user_ids, event, &1))

  @spec send_users_prepared(t(), list(), term(), keyword()) :: result(map())
  def send_users_prepared(%__MODULE__{} = actor, user_ids, prepared, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.send_users_prepared(actor.instance, user_ids, prepared, &1)
      )

  @spec send_session(t(), binary(), term(), keyword()) :: result(term())
  def send_session(%__MODULE__{} = actor, target_session, event, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.send_session(actor.instance, target_session, event, &1)
      )

  @spec send_session_prepared(t(), binary(), term(), keyword()) :: result(term())
  def send_session_prepared(%__MODULE__{} = actor, target_session, prepared, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.send_session_prepared(actor.instance, target_session, prepared, &1)
      )

  @spec send_sessions(t(), list(), term(), keyword()) :: result(map())
  def send_sessions(%__MODULE__{} = actor, target_sessions, event, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.send_sessions(actor.instance, target_sessions, event, &1)
      )

  @spec send_sessions_prepared(t(), list(), term(), keyword()) :: result(map())
  def send_sessions_prepared(%__MODULE__{} = actor, target_sessions, prepared, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.send_sessions_prepared(actor.instance, target_sessions, prepared, &1)
      )

  @doc "Compiles a validated reusable dispatch topology bound to this actor's instance."
  @spec compile_dispatch(t(), list()) :: result(Wiregrid.DispatchPlan.t())
  def compile_dispatch(%__MODULE__{} = actor, targets),
    do: Wiregrid.compile_dispatch(actor.instance, targets)

  @spec dispatch(t(), list(), term(), keyword()) :: result(map())
  def dispatch(%__MODULE__{} = actor, targets, event, opts \\ []),
    do: authenticated(actor, opts, &Wiregrid.dispatch(actor.instance, targets, event, &1))

  @spec dispatch_prepared(t(), list(), term(), keyword()) :: result(map())
  def dispatch_prepared(%__MODULE__{} = actor, targets, prepared, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.dispatch_prepared(actor.instance, targets, prepared, &1)
      )

  @spec dispatch_plan(t(), Wiregrid.DispatchPlan.t(), term(), keyword()) :: result(map())
  def dispatch_plan(%__MODULE__{} = actor, plan, event, opts \\ []),
    do: authenticated(actor, opts, &Wiregrid.dispatch_plan(actor.instance, plan, event, &1))

  @spec dispatch_plan_prepared(t(), Wiregrid.DispatchPlan.t(), term(), keyword()) :: result(map())
  def dispatch_plan_prepared(%__MODULE__{} = actor, plan, prepared, opts \\ []),
    do:
      authenticated(
        actor,
        opts,
        &Wiregrid.dispatch_plan_prepared(actor.instance, plan, prepared, &1)
      )

  defp authenticated(%__MODULE__{session_id: session_id}, opts, fun) when is_function(fun, 1) do
    with {:ok, bound} <- bind_session(opts, session_id) do
      fun.(bound)
    end
  end

  defp bind_session(opts, session_id) when is_list(opts) do
    cond do
      Wiregrid.Validation.bounded_list(opts, 64) != :ok -> {:error, :invalid_options}
      not Keyword.keyword?(opts) -> {:error, :invalid_options}
      Keyword.has_key?(opts, :session_id) -> {:error, :actor_session_override}
      true -> {:ok, Keyword.put(opts, :session_id, session_id)}
    end
  end

  defp bind_session(_opts, _session_id), do: {:error, :invalid_options}
end
