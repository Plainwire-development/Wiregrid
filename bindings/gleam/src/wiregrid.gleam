import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/list

pub type Topic {
  User(String)
  Channel(String)
  Thread(String)
  Room(String)
  Game(String)
  Document(String)
  Custom(String, String)
}

pub type Presence {
  Online
  Idle
  Dnd
  Invisible
  Offline
  CustomPresence(String)
}

pub type Signal {
  Ring
  Accept
  Decline
  Cancel
  Offer
  Answer
  IceCandidate
  Leave
  Reconnect
  Membership
}


/// Deterministic aggregate presence for one user. Arbitrary metadata remains
/// Dynamic because its schema belongs to the embedding application.
pub type PresenceSnapshot {
  PresenceSnapshot(
    status: Presence,
    sessions: Int,
    metadata: Dynamic,
    updated_at_ms: Int,
  )
}

/// Bounded durable replay progress. Cursors and stop reasons are intentionally
/// opaque: applications persist/pass them back to Wiregrid rather than decode
/// adapter-specific representations.
pub type ReplayStats {
  ReplayStats(
    delivered: Int,
    dropped: Int,
    complete_page: Bool,
    resume_cursor: Dynamic,
    next_cursor: Dynamic,
    stopped: Dynamic,
  )
}

pub type DeliveryClass {
  Durable
  Ephemeral
}

/// Resource sizing presets. Individual advanced limits remain available through
/// the plain Erlang ABI for applications that need custom tuning.
pub type Profile {
  Small
  Balanced
  Large
}

/// Stable counters returned by publish/fanout operations.
pub type FanoutStats {
  FanoutStats(
    sent: Int,
    dropped: Int,
    evicted: Int,
    gone: Int,
    excluded: Int,
    overloaded: Int,
  )
}

/// Summary returned by grouped/manual acknowledgement operations.
pub type AckStats {
  AckStats(acked: Int, unknown: Int, pending: Int)
}

/// A heterogeneous destination for `dispatch`/`dispatch_prepared`.
pub type Target {
  TopicTarget(Topic)
  RoomTarget(String)
  UserTarget(String)
  SessionTarget(String)
}

pub type Prepared {
  Prepared(Dynamic)
}

/// Integrity-bound reusable heterogeneous dispatch topology.
pub type DispatchPlan {
  DispatchPlan(Dynamic)
}

/// Session-bound identity for authenticated Gleam application code.
///
/// The value does not cache permissions. Actor operations still cross the
/// canonical Wiregrid runtime; identity-bearing publish/send helpers inject the
/// actor session in a closed Erlang FFI so it cannot be accidentally omitted.
pub type Actor {
  Actor(instance: Dynamic, session_id: String, user_id: String)
}

@external(erlang, "wiregrid_gleam_ffi", "normalize_result")
fn normalize_result(p0: Dynamic) -> Result(Dynamic, Dynamic)

@external(erlang, "wiregrid_gleam_ffi", "atom")
fn atom(p0: String) -> Dynamic

@external(erlang, "wiregrid_gleam_ffi", "fanout_stats")
fn fanout_stats_raw(p0: Dynamic) -> Result(#(Int, Int, Int, Int, Int, Int), Dynamic)

/// Decode a Wiregrid fanout result into a typed operational summary.
pub fn fanout_stats(value: Dynamic) -> Result(FanoutStats, Dynamic) {
  case fanout_stats_raw(value) {
    Ok(#(sent, dropped, evicted, gone, excluded, overloaded)) ->
      Ok(FanoutStats(sent, dropped, evicted, gone, excluded, overloaded))
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "wiregrid_gleam_ffi", "ack_stats")
fn ack_stats_raw(p0: Dynamic) -> Result(#(Int, Int, Int), Dynamic)

/// Decode `ack_many`/grouped ACK output without handling raw Erlang maps.
pub fn ack_stats(value: Dynamic) -> Result(AckStats, Dynamic) {
  case ack_stats_raw(value) {
    Ok(#(acked, unknown, pending)) -> Ok(AckStats(acked, unknown, pending))
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "wiregrid_api", "topic_user") fn topic_user(p0: String) -> Dynamic
@external(erlang, "wiregrid_api", "topic_channel") fn topic_channel(p0: String) -> Dynamic
@external(erlang, "wiregrid_api", "topic_thread") fn topic_thread(p0: String) -> Dynamic
@external(erlang, "wiregrid_api", "topic_room") fn topic_room(p0: String) -> Dynamic
@external(erlang, "wiregrid_api", "topic_game") fn topic_game(p0: String) -> Dynamic
@external(erlang, "wiregrid_api", "topic_document") fn topic_document(p0: String) -> Dynamic
@external(erlang, "wiregrid_api", "topic_custom") fn topic_custom(p0: String, p1: String) -> Dynamic

fn topic_term(topic: Topic) -> Dynamic {
  case topic {
    User(id) -> topic_user(id)
    Channel(id) -> topic_channel(id)
    Thread(id) -> topic_thread(id)
    Room(id) -> topic_room(id)
    Game(id) -> topic_game(id)
    Document(id) -> topic_document(id)
    Custom(namespace, value) -> topic_custom(namespace, value)
  }
}

@external(erlang, "wiregrid_api", "target_topic") fn target_topic_raw(p0: Dynamic) -> Dynamic
@external(erlang, "wiregrid_api", "target_room") fn target_room_raw(p0: String) -> Dynamic
@external(erlang, "wiregrid_api", "target_user") fn target_user_raw(p0: String) -> Dynamic
@external(erlang, "wiregrid_api", "target_session") fn target_session_raw(p0: String) -> Dynamic

fn target_term(target: Target) -> Dynamic {
  case target {
    TopicTarget(topic) -> target_topic_raw(topic_term(topic))
    RoomTarget(room) -> target_room_raw(room)
    UserTarget(user) -> target_user_raw(user)
    SessionTarget(session) -> target_session_raw(session)
  }
}

@external(erlang, "wiregrid_api", "presence_status") fn presence_status(p0: Dynamic) -> Dynamic
@external(erlang, "wiregrid_api", "presence_custom") fn presence_custom(p0: String) -> Dynamic

fn presence_term(status: Presence) -> Dynamic {
  case status {
    Online -> presence_status(atom("online"))
    Idle -> presence_status(atom("idle"))
    Dnd -> presence_status(atom("dnd"))
    Invisible -> presence_status(atom("invisible"))
    Offline -> presence_status(atom("offline"))
    CustomPresence(value) -> presence_custom(value)
  }
}

fn presence_from_name(name: String, custom: String) -> Result(Presence, Dynamic) {
  case name {
    "online" -> Ok(Online)
    "idle" -> Ok(Idle)
    "dnd" -> Ok(Dnd)
    "invisible" -> Ok(Invisible)
    "offline" -> Ok(Offline)
    "custom" -> Ok(CustomPresence(custom))
    _ -> Error(dynamic.string(name))
  }
}

fn signal_term(kind: Signal) -> Dynamic {
  case kind {
    Ring -> atom("ring")
    Accept -> atom("accept")
    Decline -> atom("decline")
    Cancel -> atom("cancel")
    Offer -> atom("offer")
    Answer -> atom("answer")
    IceCandidate -> atom("ice_candidate")
    Leave -> atom("leave")
    Reconnect -> atom("reconnect")
    Membership -> atom("membership")
  }
}

fn class_name(class: DeliveryClass) -> String {
  case class {
    Durable -> "durable"
    Ephemeral -> "ephemeral"
  }
}

fn profile_name(profile: Profile) -> String {
  case profile {
    Small -> "small"
    Balanced -> "balanced"
    Large -> "large"
  }
}

@external(erlang, "wiregrid_api", "version") fn version_raw() -> String
pub fn version() -> String { version_raw() }

@external(erlang, "wiregrid_api", "protocol_version") fn protocol_version_raw() -> Int
pub fn protocol_version() -> Int { protocol_version_raw() }

@external(erlang, "wiregrid_api", "foreign_protocol_version") fn foreign_protocol_version_raw() -> Int
pub fn foreign_protocol_version() -> Int { foreign_protocol_version_raw() }

@external(erlang, "wiregrid_api", "c_abi_major") fn c_abi_major_raw() -> Int
pub fn c_abi_major() -> Int { c_abi_major_raw() }

@external(erlang, "wiregrid_api", "capabilities") fn capabilities_raw(p0: Dynamic) -> Dynamic
pub fn capabilities(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(capabilities_raw(name)) }

@external(erlang, "wiregrid_api", "describe") fn describe_raw(p0: Dynamic) -> Dynamic
pub fn describe(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(describe_raw(name)) }

@external(erlang, "wiregrid_api", "instance_child_spec") fn instance_child_spec_raw(p0: Dynamic) -> Dynamic
/// Returns an OTP child spec for embedding an instance under an application supervisor.
pub fn instance_child_spec(name: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(instance_child_spec_raw(name))
}

@external(erlang, "wiregrid_api", "start_instance") fn start_instance_raw(p0: Dynamic) -> Dynamic
pub fn start_instance(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(start_instance_raw(name)) }
@external(erlang, "wiregrid_gleam_ffi", "start_profile") fn start_profile_raw(p0: Dynamic, p1: String) -> Dynamic
/// Starts an instance with one of Wiregrid's validated resource profiles.
pub fn start_profile(name: Dynamic, profile: Profile) -> Result(Dynamic, Dynamic) {
  normalize_result(start_profile_raw(name, profile_name(profile)))
}

@external(erlang, "wiregrid_gleam_ffi", "instance_child_spec_profile") fn instance_child_spec_profile_raw(p0: Dynamic, p1: String) -> Dynamic
/// OTP child spec with a typed Wiregrid resource profile.
pub fn instance_child_spec_profile(name: Dynamic, profile: Profile) -> Result(Dynamic, Dynamic) {
  normalize_result(instance_child_spec_profile_raw(name, profile_name(profile)))
}
@external(erlang, "wiregrid_api", "stop_instance") fn stop_instance_raw(p0: Dynamic) -> Dynamic
pub fn stop_instance(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(stop_instance_raw(name)) }

@external(erlang, "wiregrid_api", "connect") fn connect_raw(p0: Dynamic, p1: String, p2: process.Pid) -> Dynamic
pub fn connect(name: Dynamic, user_id: String, owner: process.Pid) -> Result(Dynamic, Dynamic) {
  normalize_result(connect_raw(name, user_id, owner))
}

@external(erlang, "wiregrid_gleam_ffi", "connect_encoded") fn connect_encoded_raw(p0: Dynamic, p1: String, p2: process.Pid) -> Dynamic
pub fn connect_encoded(name: Dynamic, user_id: String, owner: process.Pid) -> Result(Dynamic, Dynamic) {
  normalize_result(connect_encoded_raw(name, user_id, owner))
}

@external(erlang, "wiregrid_api", "connect_resumable") fn connect_resumable_raw(p0: Dynamic, p1: String, p2: process.Pid) -> Dynamic
pub fn connect_resumable(name: Dynamic, user_id: String, owner: process.Pid) -> Result(Dynamic, Dynamic) {
  normalize_result(connect_resumable_raw(name, user_id, owner))
}

@external(erlang, "wiregrid_gleam_ffi", "connect_resumable_encoded") fn connect_resumable_encoded_raw(p0: Dynamic, p1: String, p2: process.Pid) -> Dynamic
pub fn connect_resumable_encoded(name: Dynamic, user_id: String, owner: process.Pid) -> Result(Dynamic, Dynamic) {
  normalize_result(connect_resumable_encoded_raw(name, user_id, owner))
}

@external(erlang, "wiregrid_api", "resume_session") fn resume_session_raw(p0: Dynamic, p1: String, p2: process.Pid, p3: String) -> Dynamic
pub fn resume_session(name: Dynamic, user_id: String, owner: process.Pid, token: String) -> Result(Dynamic, Dynamic) {
  normalize_result(resume_session_raw(name, user_id, owner, token))
}

@external(erlang, "wiregrid_api", "disconnect") fn disconnect_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn disconnect(name: Dynamic, session_id: String) -> Result(Dynamic, Dynamic) { normalize_result(disconnect_raw(name, session_id)) }
@external(erlang, "wiregrid_api", "disconnect") fn disconnect_with_reason_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn disconnect_with_reason(name: Dynamic, session_id: String, reason: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(disconnect_with_reason_raw(name, session_id, reason))
}
@external(erlang, "wiregrid_api", "disconnect_user") fn disconnect_user_raw(p0: Dynamic, p1: Dynamic) -> Dynamic
/// Disconnect every live session for one user.
pub fn disconnect_user(name: Dynamic, user_id: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(disconnect_user_raw(name, user_id)) }
@external(erlang, "wiregrid_api", "disconnect_user") fn disconnect_user_with_reason_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic) -> Dynamic
pub fn disconnect_user_with_reason(name: Dynamic, user_id: Dynamic, reason: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(disconnect_user_with_reason_raw(name, user_id, reason))
}

@external(erlang, "wiregrid_gleam_ffi", "connect_actor")
fn connect_actor_raw(p0: Dynamic, p1: String, p2: process.Pid) -> Result(#(Dynamic, String, String), Dynamic)

/// Connects and returns a session-bound actor.
pub fn connect_actor(name: Dynamic, user_id: String, owner: process.Pid) -> Result(Actor, Dynamic) {
  case connect_actor_raw(name, user_id, owner) {
    Ok(#(instance, session_id, actor_user)) -> Ok(Actor(instance, session_id, actor_user))
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "wiregrid_gleam_ffi", "connect_resumable_actor")
fn connect_resumable_actor_raw(p0: Dynamic, p1: String, p2: process.Pid) -> Result(#(Dynamic, String, String, String), Dynamic)

pub fn connect_resumable_actor(name: Dynamic, user_id: String, owner: process.Pid) -> Result(#(Actor, String), Dynamic) {
  case connect_resumable_actor_raw(name, user_id, owner) {
    Ok(#(instance, session_id, actor_user, token)) -> Ok(#(Actor(instance, session_id, actor_user), token))
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "wiregrid_gleam_ffi", "resume_actor")
fn resume_actor_raw(p0: Dynamic, p1: String, p2: process.Pid, p3: String) -> Result(#(Dynamic, String, String, String, Dynamic), Dynamic)

pub fn resume_actor(name: Dynamic, user_id: String, owner: process.Pid, token: String) -> Result(#(Actor, String, Dynamic), Dynamic) {
  case resume_actor_raw(name, user_id, owner, token) {
    Ok(#(instance, session_id, actor_user, next_token, restored)) ->
      Ok(#(Actor(instance, session_id, actor_user), next_token, restored))
    Error(reason) -> Error(reason)
  }
}

pub fn actor_instance(actor: Actor) -> Dynamic {
  let Actor(instance, _, _) = actor
  instance
}

pub fn actor_session_id(actor: Actor) -> String {
  let Actor(_, session_id, _) = actor
  session_id
}

pub fn actor_user_id(actor: Actor) -> String {
  let Actor(_, _, user_id) = actor
  user_id
}

pub fn actor_disconnect(actor: Actor) -> Result(Dynamic, Dynamic) {
  disconnect(actor_instance(actor), actor_session_id(actor))
}

@external(erlang, "wiregrid_api", "set_session_metadata") fn set_session_metadata_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn set_session_metadata(name: Dynamic, session_id: String, metadata: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(set_session_metadata_raw(name, session_id, metadata))
}

@external(erlang, "wiregrid_api", "subscribe") fn subscribe_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn subscribe(name: Dynamic, session_id: String, topic: Topic) -> Result(Dynamic, Dynamic) {
  normalize_result(subscribe_raw(name, session_id, topic_term(topic)))
}

@external(erlang, "wiregrid_api", "unsubscribe") fn unsubscribe_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn unsubscribe(name: Dynamic, session_id: String, topic: Topic) -> Result(Dynamic, Dynamic) {
  normalize_result(unsubscribe_raw(name, session_id, topic_term(topic)))
}

@external(erlang, "wiregrid_api", "subscribe_many") fn subscribe_many_raw(p0: Dynamic, p1: String, p2: List(Dynamic)) -> Dynamic
pub fn subscribe_many(name: Dynamic, session_id: String, topics: List(Topic)) -> Result(Dynamic, Dynamic) {
  normalize_result(subscribe_many_raw(name, session_id, topics |> list.map(topic_term)))
}

@external(erlang, "wiregrid_api", "unsubscribe_many") fn unsubscribe_many_raw(p0: Dynamic, p1: String, p2: List(Dynamic)) -> Dynamic
pub fn unsubscribe_many(name: Dynamic, session_id: String, topics: List(Topic)) -> Result(Dynamic, Dynamic) {
  normalize_result(unsubscribe_many_raw(name, session_id, topics |> list.map(topic_term)))
}

@external(erlang, "wiregrid_api", "sync_subscriptions") fn sync_subscriptions_raw(p0: Dynamic, p1: String, p2: List(Dynamic)) -> Dynamic
pub fn sync_subscriptions(name: Dynamic, session_id: String, topics: List(Topic)) -> Result(Dynamic, Dynamic) {
  normalize_result(sync_subscriptions_raw(name, session_id, topics |> list.map(topic_term)))
}

@external(erlang, "wiregrid_gleam_ffi", "topology")
fn topology_raw(p0: List(Dynamic), p1: List(String), p2: List(String)) -> Dynamic

@external(erlang, "wiregrid_api", "sync_topology")
fn sync_topology_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic

/// Reconciles subscriptions, presence watches and room membership under one
/// serialized Wiregrid lifecycle turn. Each domain still reports independently
/// because several edge sets are not represented as one fake transaction.
pub fn sync_topology(name: Dynamic, session_id: String, subscriptions: List(Topic), presence_watches: List(String), rooms: List(String)) -> Result(Dynamic, Dynamic) {
  let topology = topology_raw(subscriptions |> list.map(topic_term), presence_watches, rooms)
  normalize_result(sync_topology_raw(name, session_id, topology))
}

@external(erlang, "wiregrid_api", "prepare") fn prepare_raw(p0: Dynamic, p1: Dynamic) -> Dynamic
pub fn prepare(name: Dynamic, event: Dynamic) -> Result(Prepared, Dynamic) {
  case normalize_result(prepare_raw(name, event)) {
    Ok(value) -> Ok(Prepared(value))
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "wiregrid_api", "publish_prepared") fn publish_prepared_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic) -> Dynamic
pub fn publish_prepared(name: Dynamic, topic: Topic, prepared: Prepared) -> Result(Dynamic, Dynamic) {
  let Prepared(value) = prepared
  normalize_result(publish_prepared_raw(name, topic_term(topic), value))
}

@external(erlang, "wiregrid_api", "publish") fn publish_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic) -> Dynamic
pub fn publish(name: Dynamic, topic: Topic, event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(publish_raw(name, topic_term(topic), event))
}

@external(erlang, "wiregrid_gleam_ffi", "publish_class") fn publish_class_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic, p3: String) -> Dynamic
pub fn publish_class(name: Dynamic, topic: Topic, event: Dynamic, class: DeliveryClass) -> Result(Dynamic, Dynamic) {
  normalize_result(publish_class_raw(name, topic_term(topic), event, class_name(class)))
}

@external(erlang, "wiregrid_api", "publish_batch") fn publish_batch_raw(p0: Dynamic, p1: Dynamic, p2: List(Dynamic)) -> Dynamic
pub fn publish_batch(name: Dynamic, topic: Topic, events: List(Dynamic)) -> Result(Dynamic, Dynamic) {
  normalize_result(publish_batch_raw(name, topic_term(topic), events))
}

@external(erlang, "wiregrid_api", "publish_topics") fn publish_topics_raw(p0: Dynamic, p1: List(Dynamic), p2: Dynamic) -> Dynamic
pub fn publish_topics(name: Dynamic, topics: List(Topic), event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(publish_topics_raw(name, topics |> list.map(topic_term), event))
}

@external(erlang, "wiregrid_api", "publish_topics_prepared") fn publish_topics_prepared_raw(p0: Dynamic, p1: List(Dynamic), p2: Dynamic) -> Dynamic
pub fn publish_topics_prepared(name: Dynamic, topics: List(Topic), prepared: Prepared) -> Result(Dynamic, Dynamic) {
  let Prepared(value) = prepared
  normalize_result(publish_topics_prepared_raw(name, topics |> list.map(topic_term), value))
}

@external(erlang, "wiregrid_api", "publish_room") fn publish_room_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn publish_room(name: Dynamic, room: String, event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(publish_room_raw(name, room, event))
}

@external(erlang, "wiregrid_api", "publish_room_prepared") fn publish_room_prepared_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn publish_room_prepared(name: Dynamic, room: String, prepared: Prepared) -> Result(Dynamic, Dynamic) {
  let Prepared(value) = prepared
  normalize_result(publish_room_prepared_raw(name, room, value))
}

@external(erlang, "wiregrid_api", "publish_rooms") fn publish_rooms_raw(p0: Dynamic, p1: List(String), p2: Dynamic) -> Dynamic
pub fn publish_rooms(name: Dynamic, rooms: List(String), event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(publish_rooms_raw(name, rooms, event))
}

@external(erlang, "wiregrid_api", "publish_rooms_prepared") fn publish_rooms_prepared_raw(p0: Dynamic, p1: List(String), p2: Dynamic) -> Dynamic
pub fn publish_rooms_prepared(name: Dynamic, rooms: List(String), prepared: Prepared) -> Result(Dynamic, Dynamic) {
  let Prepared(value) = prepared
  normalize_result(publish_rooms_prepared_raw(name, rooms, value))
}

@external(erlang, "wiregrid_gleam_ffi", "publish_room_class") fn publish_room_class_raw(p0: Dynamic, p1: String, p2: Dynamic, p3: String) -> Dynamic
pub fn publish_room_class(name: Dynamic, room: String, event: Dynamic, class: DeliveryClass) -> Result(Dynamic, Dynamic) {
  normalize_result(publish_room_class_raw(name, room, event, class_name(class)))
}

@external(erlang, "wiregrid_api", "send_user") fn send_user_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn send_user(name: Dynamic, user_id: String, event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(send_user_raw(name, user_id, event))
}

@external(erlang, "wiregrid_gleam_ffi", "send_user_class") fn send_user_class_raw(p0: Dynamic, p1: String, p2: Dynamic, p3: String) -> Dynamic
pub fn send_user_class(name: Dynamic, user_id: String, event: Dynamic, class: DeliveryClass) -> Result(Dynamic, Dynamic) {
  normalize_result(send_user_class_raw(name, user_id, event, class_name(class)))
}

@external(erlang, "wiregrid_api", "send_session") fn send_session_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn send_session(name: Dynamic, session_id: String, event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(send_session_raw(name, session_id, event))
}

@external(erlang, "wiregrid_gleam_ffi", "send_session_class") fn send_session_class_raw(p0: Dynamic, p1: String, p2: Dynamic, p3: String) -> Dynamic
pub fn send_session_class(name: Dynamic, session_id: String, event: Dynamic, class: DeliveryClass) -> Result(Dynamic, Dynamic) {
  normalize_result(send_session_class_raw(name, session_id, event, class_name(class)))
}

@external(erlang, "wiregrid_api", "send_sessions") fn send_sessions_raw(p0: Dynamic, p1: List(String), p2: Dynamic) -> Dynamic
pub fn send_sessions(name: Dynamic, session_ids: List(String), event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(send_sessions_raw(name, session_ids, event))
}

@external(erlang, "wiregrid_api", "send_users") fn send_users_raw(p0: Dynamic, p1: List(String), p2: Dynamic) -> Dynamic
pub fn send_users(name: Dynamic, user_ids: List(String), event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(send_users_raw(name, user_ids, event))
}

@external(erlang, "wiregrid_gleam_ffi", "send_sessions_class") fn send_sessions_class_raw(p0: Dynamic, p1: List(String), p2: Dynamic, p3: String) -> Dynamic
pub fn send_sessions_class(name: Dynamic, session_ids: List(String), event: Dynamic, class: DeliveryClass) -> Result(Dynamic, Dynamic) {
  normalize_result(send_sessions_class_raw(name, session_ids, event, class_name(class)))
}

@external(erlang, "wiregrid_gleam_ffi", "send_users_class") fn send_users_class_raw(p0: Dynamic, p1: List(String), p2: Dynamic, p3: String) -> Dynamic
pub fn send_users_class(name: Dynamic, user_ids: List(String), event: Dynamic, class: DeliveryClass) -> Result(Dynamic, Dynamic) {
  normalize_result(send_users_class_raw(name, user_ids, event, class_name(class)))
}

@external(erlang, "wiregrid_api", "send_session_prepared") fn send_session_prepared_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn send_session_prepared(name: Dynamic, session_id: String, prepared: Prepared) -> Result(Dynamic, Dynamic) {
  let Prepared(value) = prepared
  normalize_result(send_session_prepared_raw(name, session_id, value))
}

@external(erlang, "wiregrid_api", "send_user_prepared") fn send_user_prepared_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn send_user_prepared(name: Dynamic, user_id: String, prepared: Prepared) -> Result(Dynamic, Dynamic) {
  let Prepared(value) = prepared
  normalize_result(send_user_prepared_raw(name, user_id, value))
}

@external(erlang, "wiregrid_api", "send_sessions_prepared") fn send_sessions_prepared_raw(p0: Dynamic, p1: List(String), p2: Dynamic) -> Dynamic
pub fn send_sessions_prepared(name: Dynamic, session_ids: List(String), prepared: Prepared) -> Result(Dynamic, Dynamic) {
  let Prepared(value) = prepared
  normalize_result(send_sessions_prepared_raw(name, session_ids, value))
}

@external(erlang, "wiregrid_api", "send_users_prepared") fn send_users_prepared_raw(p0: Dynamic, p1: List(String), p2: Dynamic) -> Dynamic
pub fn send_users_prepared(name: Dynamic, user_ids: List(String), prepared: Prepared) -> Result(Dynamic, Dynamic) {
  let Prepared(value) = prepared
  normalize_result(send_users_prepared_raw(name, user_ids, value))
}

@external(erlang, "wiregrid_api", "dispatch") fn dispatch_raw(p0: Dynamic, p1: List(Dynamic), p2: Dynamic) -> Dynamic
pub fn dispatch(name: Dynamic, targets: List(Target), event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(dispatch_raw(name, targets |> list.map(target_term), event))
}

@external(erlang, "wiregrid_api", "dispatch_prepared") fn dispatch_prepared_raw(p0: Dynamic, p1: List(Dynamic), p2: Dynamic) -> Dynamic
pub fn dispatch_prepared(name: Dynamic, targets: List(Target), prepared: Prepared) -> Result(Dynamic, Dynamic) {
  let Prepared(value) = prepared
  normalize_result(dispatch_prepared_raw(name, targets |> list.map(target_term), value))
}

@external(erlang, "wiregrid_api", "compile_dispatch") fn compile_dispatch_raw(p0: Dynamic, p1: List(Dynamic)) -> Dynamic
pub fn compile_dispatch(name: Dynamic, targets: List(Target)) -> Result(DispatchPlan, Dynamic) {
  case normalize_result(compile_dispatch_raw(name, targets |> list.map(target_term))) {
    Ok(value) -> Ok(DispatchPlan(value))
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "wiregrid_api", "dispatch_plan") fn dispatch_plan_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic) -> Dynamic
pub fn dispatch_plan(name: Dynamic, plan: DispatchPlan, event: Dynamic) -> Result(Dynamic, Dynamic) {
  let DispatchPlan(value) = plan
  normalize_result(dispatch_plan_raw(name, value, event))
}

@external(erlang, "wiregrid_api", "dispatch_plan_prepared") fn dispatch_plan_prepared_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic) -> Dynamic
pub fn dispatch_plan_prepared(name: Dynamic, plan: DispatchPlan, prepared: Prepared) -> Result(Dynamic, Dynamic) {
  let DispatchPlan(plan_value) = plan
  let Prepared(prepared_value) = prepared
  normalize_result(dispatch_plan_prepared_raw(name, plan_value, prepared_value))
}

@external(erlang, "wiregrid_gleam_ffi", "dispatch_class") fn dispatch_class_raw(p0: Dynamic, p1: List(Dynamic), p2: Dynamic, p3: String) -> Dynamic
pub fn dispatch_class(name: Dynamic, targets: List(Target), event: Dynamic, class: DeliveryClass) -> Result(Dynamic, Dynamic) {
  normalize_result(dispatch_class_raw(name, targets |> list.map(target_term), event, class_name(class)))
}

@external(erlang, "wiregrid_gleam_ffi", "actor_publish")
fn actor_publish_raw(p0: Dynamic, p1: String, p2: Dynamic, p3: Dynamic) -> Dynamic
pub fn actor_publish(actor: Actor, topic: Topic, event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(actor_publish_raw(actor_instance(actor), actor_session_id(actor), topic_term(topic), event))
}

@external(erlang, "wiregrid_gleam_ffi", "actor_publish_room")
fn actor_publish_room_raw(p0: Dynamic, p1: String, p2: String, p3: Dynamic) -> Dynamic
pub fn actor_publish_room(actor: Actor, room: String, event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(actor_publish_room_raw(actor_instance(actor), actor_session_id(actor), room, event))
}

@external(erlang, "wiregrid_gleam_ffi", "actor_send_user")
fn actor_send_user_raw(p0: Dynamic, p1: String, p2: String, p3: Dynamic) -> Dynamic
pub fn actor_send_user(actor: Actor, user_id: String, event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(actor_send_user_raw(actor_instance(actor), actor_session_id(actor), user_id, event))
}

@external(erlang, "wiregrid_gleam_ffi", "actor_send_session")
fn actor_send_session_raw(p0: Dynamic, p1: String, p2: String, p3: Dynamic) -> Dynamic
pub fn actor_send_session(actor: Actor, target_session: String, event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(actor_send_session_raw(actor_instance(actor), actor_session_id(actor), target_session, event))
}

@external(erlang, "wiregrid_gleam_ffi", "actor_dispatch")
fn actor_dispatch_raw(p0: Dynamic, p1: String, p2: List(Dynamic), p3: Dynamic) -> Dynamic
pub fn actor_dispatch(actor: Actor, targets: List(Target), event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(actor_dispatch_raw(
    actor_instance(actor),
    actor_session_id(actor),
    targets |> list.map(target_term),
    event,
  ))
}

pub fn actor_subscribe(actor: Actor, topic: Topic) -> Result(Dynamic, Dynamic) {
  subscribe(actor_instance(actor), actor_session_id(actor), topic)
}

pub fn actor_unsubscribe(actor: Actor, topic: Topic) -> Result(Dynamic, Dynamic) {
  unsubscribe(actor_instance(actor), actor_session_id(actor), topic)
}

pub fn actor_set_presence(actor: Actor, status: Presence) -> Result(Dynamic, Dynamic) {
  set_presence(actor_instance(actor), actor_session_id(actor), status)
}

pub fn actor_join_room(actor: Actor, room: String) -> Result(Dynamic, Dynamic) {
  join_room(actor_instance(actor), room, actor_session_id(actor))
}

pub fn actor_leave_room(actor: Actor, room: String) -> Result(Dynamic, Dynamic) {
  leave_room(actor_instance(actor), room, actor_session_id(actor))
}

pub fn actor_ack(actor: Actor, delivery_id: String) -> Result(Dynamic, Dynamic) {
  ack(actor_instance(actor), actor_session_id(actor), delivery_id)
}

pub fn actor_pending(actor: Actor) -> Int {
  pending(actor_instance(actor), actor_session_id(actor))
}

@external(erlang, "wiregrid_api", "ack") fn ack_raw(p0: Dynamic, p1: String, p2: String) -> Dynamic
pub fn ack(name: Dynamic, session_id: String, delivery_id: String) -> Result(Dynamic, Dynamic) {
  normalize_result(ack_raw(name, session_id, delivery_id))
}
@external(erlang, "wiregrid_api", "ack_many") fn ack_many_raw(p0: Dynamic, p1: String, p2: List(String)) -> Dynamic
pub fn ack_many(name: Dynamic, session_id: String, delivery_ids: List(String)) -> Result(Dynamic, Dynamic) {
  normalize_result(ack_many_raw(name, session_id, delivery_ids))
}

@external(erlang, "wiregrid_api", "delivery_event") fn delivery_event_raw(p0: Dynamic, p1: Dynamic) -> Dynamic
/// Validates one delivery envelope and decodes its event body through the instance codec.
pub fn delivery_event(name: Dynamic, envelope: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(delivery_event_raw(name, envelope))
}

@external(erlang, "wiregrid_api", "consume_delivery")
fn consume_delivery_raw(p0: Dynamic, p1: Dynamic, p2: fn(Dynamic, Dynamic) -> Dynamic) -> Dynamic
/// Handles one delivery and releases its reservation only after handler success.
pub fn consume_delivery(name: Dynamic, envelope: Dynamic, handler: fn(Dynamic, Dynamic) -> Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(consume_delivery_raw(name, envelope, handler))
}

@external(erlang, "wiregrid_api", "consume_many_deliveries")
fn consume_many_deliveries_raw(p0: Dynamic, p1: List(Dynamic), p2: fn(Dynamic, Dynamic) -> Dynamic) -> Dynamic

/// Handle a bounded batch and release delivery reservations only after each
/// handler invocation reports success. ACKs are grouped by session in the
/// canonical Wiregrid runtime.
pub fn consume_many_deliveries(name: Dynamic, envelopes: List(Dynamic), handler: fn(Dynamic, Dynamic) -> Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(consume_many_deliveries_raw(name, envelopes, handler))
}

@external(erlang, "wiregrid_api", "consume_ordered_deliveries")
fn consume_ordered_deliveries_raw(p0: Dynamic, p1: List(Dynamic), p2: fn(Dynamic, Dynamic) -> Dynamic) -> Dynamic

/// Process in order, stop on the first failure, and ACK only the successful prefix.
pub fn consume_ordered_deliveries(name: Dynamic, envelopes: List(Dynamic), handler: fn(Dynamic, Dynamic) -> Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(consume_ordered_deliveries_raw(name, envelopes, handler))
}

@external(erlang, "wiregrid_api", "consume_projection")
fn consume_projection_raw(p0: Dynamic, p1: List(Dynamic), p2: Dynamic, p3: fn(Dynamic, Dynamic, Dynamic) -> Dynamic, p4: fn(Dynamic, Dynamic) -> Dynamic) -> Dynamic

/// Fold a bounded batch into state, commit once, then release delivery reservations.
pub fn consume_projection(name: Dynamic, envelopes: List(Dynamic), accumulator: Dynamic, reducer: fn(Dynamic, Dynamic, Dynamic) -> Dynamic, commit: fn(Dynamic, Dynamic) -> Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(consume_projection_raw(name, envelopes, accumulator, reducer, commit))
}

@external(erlang, "wiregrid_api", "request_session")
fn request_session_raw(p0: Dynamic, p1: String, p2: String, p3: Dynamic) -> Dynamic
pub fn request_session(name: Dynamic, requester: String, target: String, event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(request_session_raw(name, requester, target, event))
}

@external(erlang, "wiregrid_api", "reply")
fn reply_raw(p0: Dynamic, p1: String, p2: Dynamic, p3: Dynamic) -> Dynamic
pub fn reply(name: Dynamic, replier: String, request_envelope: Dynamic, event: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(reply_raw(name, replier, request_envelope, event))
}

@external(erlang, "wiregrid_api", "request_context")
fn request_context_raw(p0: Dynamic) -> Dynamic
pub fn request_context(envelope: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(request_context_raw(envelope)) }

@external(erlang, "wiregrid_api", "transport_audience")
pub fn transport_audience(instance: Dynamic) -> String
@external(erlang, "wiregrid_api", "issue_transport_token")
fn issue_transport_token_raw(p0: String, p1: Dynamic) -> Dynamic
/// Issues a versioned HMAC token using an Erlang key-ring map supplied by the application.
pub fn issue_transport_token(subject: String, keys: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(issue_transport_token_raw(subject, keys))
}
@external(erlang, "wiregrid_api", "verify_transport_token")
fn verify_transport_token_raw(p0: String, p1: Dynamic) -> Dynamic
pub fn verify_transport_token(token: String, keys: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(verify_transport_token_raw(token, keys))
}

@external(erlang, "wiregrid_api", "pending") pub fn pending(name: Dynamic, session_id: String) -> Int

@external(erlang, "wiregrid_api", "set_presence") fn set_presence_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn set_presence(name: Dynamic, session_id: String, status: Presence) -> Result(Dynamic, Dynamic) {
  normalize_result(set_presence_raw(name, session_id, presence_term(status)))
}
@external(erlang, "wiregrid_api", "presence") fn presence_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn presence(name: Dynamic, user_id: String) -> Result(Dynamic, Dynamic) { normalize_result(presence_raw(name, user_id)) }

@external(erlang, "wiregrid_gleam_ffi", "presence_snapshot")
fn presence_snapshot_raw(p0: Dynamic, p1: String) -> Result(#(String, String, Int, Dynamic, Int), Dynamic)

/// Typed aggregate presence. Prefer this over `presence` unless the raw map is
/// specifically needed for interop.
pub fn presence_snapshot(name: Dynamic, user_id: String) -> Result(PresenceSnapshot, Dynamic) {
  case presence_snapshot_raw(name, user_id) {
    Ok(#(status_name, custom, sessions, metadata, updated_at_ms)) ->
      case presence_from_name(status_name, custom) {
        Ok(status) -> Ok(PresenceSnapshot(status, sessions, metadata, updated_at_ms))
        Error(reason) -> Error(reason)
      }
    Error(reason) -> Error(reason)
  }
}
@external(erlang, "wiregrid_api", "watch_presence") fn watch_presence_raw(p0: Dynamic, p1: String, p2: String) -> Dynamic
pub fn watch_presence(name: Dynamic, session_id: String, user_id: String) -> Result(Dynamic, Dynamic) { normalize_result(watch_presence_raw(name, session_id, user_id)) }
@external(erlang, "wiregrid_api", "unwatch_presence") fn unwatch_presence_raw(p0: Dynamic, p1: String, p2: String) -> Dynamic
pub fn unwatch_presence(name: Dynamic, session_id: String, user_id: String) -> Result(Dynamic, Dynamic) { normalize_result(unwatch_presence_raw(name, session_id, user_id)) }
@external(erlang, "wiregrid_api", "watch_presence_many") fn watch_presence_many_raw(p0: Dynamic, p1: String, p2: List(String)) -> Dynamic
pub fn watch_presence_many(name: Dynamic, session_id: String, users: List(String)) -> Result(Dynamic, Dynamic) { normalize_result(watch_presence_many_raw(name, session_id, users)) }
@external(erlang, "wiregrid_api", "unwatch_presence_many") fn unwatch_presence_many_raw(p0: Dynamic, p1: String, p2: List(String)) -> Dynamic
pub fn unwatch_presence_many(name: Dynamic, session_id: String, users: List(String)) -> Result(Dynamic, Dynamic) { normalize_result(unwatch_presence_many_raw(name, session_id, users)) }
@external(erlang, "wiregrid_api", "sync_presence_watches") fn sync_presence_watches_raw(p0: Dynamic, p1: String, p2: List(String)) -> Dynamic
pub fn sync_presence_watches(name: Dynamic, session_id: String, users: List(String)) -> Result(Dynamic, Dynamic) { normalize_result(sync_presence_watches_raw(name, session_id, users)) }

@external(erlang, "wiregrid_api", "join_room") fn join_room_raw(p0: Dynamic, p1: String, p2: String) -> Dynamic
pub fn join_room(name: Dynamic, room: String, session_id: String) -> Result(Dynamic, Dynamic) { normalize_result(join_room_raw(name, room, session_id)) }
@external(erlang, "wiregrid_api", "leave_room") fn leave_room_raw(p0: Dynamic, p1: String, p2: String) -> Dynamic
pub fn leave_room(name: Dynamic, room: String, session_id: String) -> Result(Dynamic, Dynamic) { normalize_result(leave_room_raw(name, room, session_id)) }
@external(erlang, "wiregrid_api", "join_rooms") fn join_rooms_raw(p0: Dynamic, p1: List(String), p2: String) -> Dynamic
pub fn join_rooms(name: Dynamic, rooms: List(String), session_id: String) -> Result(Dynamic, Dynamic) { normalize_result(join_rooms_raw(name, rooms, session_id)) }
@external(erlang, "wiregrid_api", "leave_rooms") fn leave_rooms_raw(p0: Dynamic, p1: List(String), p2: String) -> Dynamic
pub fn leave_rooms(name: Dynamic, rooms: List(String), session_id: String) -> Result(Dynamic, Dynamic) { normalize_result(leave_rooms_raw(name, rooms, session_id)) }
@external(erlang, "wiregrid_api", "sync_rooms") fn sync_rooms_raw(p0: Dynamic, p1: String, p2: List(String)) -> Dynamic
pub fn sync_rooms(name: Dynamic, session_id: String, rooms: List(String)) -> Result(Dynamic, Dynamic) { normalize_result(sync_rooms_raw(name, session_id, rooms)) }
@external(erlang, "wiregrid_api", "resume_room") fn resume_room_raw(p0: Dynamic, p1: String, p2: String, p3: String) -> Dynamic
pub fn resume_room(name: Dynamic, room: String, old_session_id: String, new_session_id: String) -> Result(Dynamic, Dynamic) {
  normalize_result(resume_room_raw(name, room, old_session_id, new_session_id))
}
@external(erlang, "wiregrid_api", "room_members") fn room_members_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn room_members(name: Dynamic, room: String) -> Result(Dynamic, Dynamic) { normalize_result(room_members_raw(name, room)) }
@external(erlang, "wiregrid_api", "room_metadata") fn room_metadata_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn room_metadata(name: Dynamic, room: String) -> Result(Dynamic, Dynamic) { normalize_result(room_metadata_raw(name, room)) }
@external(erlang, "wiregrid_api", "set_room_metadata") fn set_room_metadata_raw(p0: Dynamic, p1: String, p2: String, p3: Dynamic) -> Dynamic
pub fn set_room_metadata(name: Dynamic, room: String, session_id: String, metadata: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(set_room_metadata_raw(name, room, session_id, metadata)) }
@external(erlang, "wiregrid_api", "set_room_ttl") fn set_room_ttl_raw(p0: Dynamic, p1: String, p2: String, p3: Int) -> Dynamic
pub fn set_room_ttl(name: Dynamic, room: String, session_id: String, ttl_ms: Int) -> Result(Dynamic, Dynamic) { normalize_result(set_room_ttl_raw(name, room, session_id, ttl_ms)) }

@external(erlang, "wiregrid_api", "activity") fn activity_raw(p0: Dynamic, p1: String, p2: Dynamic, p3: Dynamic, p4: Dynamic) -> Dynamic
pub fn activity(name: Dynamic, session_id: String, topic: Topic, kind: Dynamic, value: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(activity_raw(name, session_id, topic_term(topic), kind, value))
}
@external(erlang, "wiregrid_api", "activities") fn activities_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic) -> Dynamic
pub fn activities(name: Dynamic, topic: Topic, kind: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(activities_raw(name, topic_term(topic), kind))
}
@external(erlang, "wiregrid_api", "typing") fn typing_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn typing(name: Dynamic, session_id: String, topic: Topic) -> Result(Dynamic, Dynamic) { normalize_result(typing_raw(name, session_id, topic_term(topic))) }
@external(erlang, "wiregrid_api", "receipt") fn receipt_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
pub fn receipt(name: Dynamic, session_id: String, value: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(receipt_raw(name, session_id, value)) }
@external(erlang, "wiregrid_api", "get_receipt") fn get_receipt_raw(p0: Dynamic, p1: String, p2: String) -> Dynamic
pub fn get_receipt(name: Dynamic, session_id: String, receipt_id: String) -> Result(Dynamic, Dynamic) {
  normalize_result(get_receipt_raw(name, session_id, receipt_id))
}
@external(erlang, "wiregrid_api", "signal") fn signal_raw(p0: Dynamic, p1: String, p2: String, p3: Dynamic, p4: Dynamic) -> Dynamic
pub fn signal(name: Dynamic, room: String, session_id: String, kind: Signal, payload: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(signal_raw(name, room, session_id, signal_term(kind), payload))
}

@external(erlang, "wiregrid_api", "session") fn session_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn session(name: Dynamic, session_id: String) -> Result(Dynamic, Dynamic) { normalize_result(session_raw(name, session_id)) }
@external(erlang, "wiregrid_api", "user_sessions") fn user_sessions_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn user_sessions(name: Dynamic, user_id: String) -> Result(Dynamic, Dynamic) { normalize_result(user_sessions_raw(name, user_id)) }
@external(erlang, "wiregrid_api", "session_state") fn session_state_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn session_state(name: Dynamic, session_id: String) -> Result(Dynamic, Dynamic) { normalize_result(session_state_raw(name, session_id)) }
@external(erlang, "wiregrid_api", "topic_info") fn topic_info_raw(p0: Dynamic, p1: Dynamic) -> Dynamic
pub fn topic_info(name: Dynamic, topic: Topic) -> Result(Dynamic, Dynamic) { normalize_result(topic_info_raw(name, topic_term(topic))) }
@external(erlang, "wiregrid_api", "room_info") fn room_info_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn room_info(name: Dynamic, room: String) -> Result(Dynamic, Dynamic) { normalize_result(room_info_raw(name, room)) }
@external(erlang, "wiregrid_api", "user_info") fn user_info_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn user_info(name: Dynamic, user_id: String) -> Result(Dynamic, Dynamic) { normalize_result(user_info_raw(name, user_id)) }
@external(erlang, "wiregrid_api", "subscriptions") fn subscriptions_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn subscriptions(name: Dynamic, session_id: String) -> Result(Dynamic, Dynamic) { normalize_result(subscriptions_raw(name, session_id)) }
@external(erlang, "wiregrid_api", "topic_sessions") fn topic_sessions_raw(p0: Dynamic, p1: Dynamic) -> Dynamic
pub fn topic_sessions(name: Dynamic, topic: Topic) -> Result(Dynamic, Dynamic) { normalize_result(topic_sessions_raw(name, topic_term(topic))) }
@external(erlang, "wiregrid_api", "session_rooms") fn session_rooms_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn session_rooms(name: Dynamic, session_id: String) -> Result(Dynamic, Dynamic) { normalize_result(session_rooms_raw(name, session_id)) }
@external(erlang, "wiregrid_api", "presence_watches") fn presence_watches_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn presence_watches(name: Dynamic, session_id: String) -> Result(Dynamic, Dynamic) { normalize_result(presence_watches_raw(name, session_id)) }
@external(erlang, "wiregrid_api", "limits") fn limits_raw(p0: Dynamic) -> Dynamic
pub fn limits(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(limits_raw(name)) }
@external(erlang, "wiregrid_api", "topic_subscriber_count") fn topic_subscriber_count_raw(p0: Dynamic, p1: Dynamic) -> Dynamic
pub fn topic_subscriber_count(name: Dynamic, topic: Topic) -> Result(Dynamic, Dynamic) { normalize_result(topic_subscriber_count_raw(name, topic_term(topic))) }
@external(erlang, "wiregrid_api", "room_member_count") fn room_member_count_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn room_member_count(name: Dynamic, room: String) -> Result(Dynamic, Dynamic) { normalize_result(room_member_count_raw(name, room)) }
@external(erlang, "wiregrid_api", "presence_watcher_count") fn presence_watcher_count_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn presence_watcher_count(name: Dynamic, user: String) -> Result(Dynamic, Dynamic) { normalize_result(presence_watcher_count_raw(name, user)) }
@external(erlang, "wiregrid_api", "user_session_count") fn user_session_count_raw(p0: Dynamic, p1: String) -> Dynamic
pub fn user_session_count(name: Dynamic, user: String) -> Result(Dynamic, Dynamic) { normalize_result(user_session_count_raw(name, user)) }
@external(erlang, "wiregrid_api", "room_member") pub fn room_member(name: Dynamic, room: String, session_id: String) -> Bool
@external(erlang, "wiregrid_api", "subscribed") fn subscribed_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Bool
pub fn subscribed(name: Dynamic, session_id: String, topic: Topic) -> Bool { subscribed_raw(name, session_id, topic_term(topic)) }
@external(erlang, "wiregrid_api", "decode_payload") fn decode_payload_raw(p0: Dynamic, p1: BitArray) -> Dynamic
pub fn decode_payload(name: Dynamic, payload: BitArray) -> Result(Dynamic, Dynamic) { normalize_result(decode_payload_raw(name, payload)) }

@external(erlang, "wiregrid_api", "rate_limit") fn rate_limit_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic, p3: Int, p4: Int) -> Dynamic
@external(erlang, "wiregrid_api", "rate_limit") fn rate_limit_with_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic, p3: Int, p4: Int, p5: Dynamic) -> Dynamic
pub fn rate_limit(name: Dynamic, bucket: Dynamic, key: Dynamic, limit: Int, window_ms: Int) -> Result(Dynamic, Dynamic) {
  normalize_result(rate_limit_raw(name, bucket, key, limit, window_ms))
}

/// Advanced rate-limit call accepting an Erlang option proplist.
/// Prefer `rate_limit` or `rate_limit_token_bucket` for typed common cases.
pub fn rate_limit_with_options(name: Dynamic, bucket: Dynamic, key: Dynamic, limit: Int, window_ms: Int, options: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(rate_limit_with_raw(name, bucket, key, limit, window_ms, options))
}

@external(erlang, "wiregrid_gleam_ffi", "rate_limit_token_bucket")
fn rate_limit_token_bucket_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic, p3: Int, p4: Int, p5: Int, p6: Int) -> Dynamic

/// Burst-capable token-bucket limiting with bounded idle state.
///
/// `burst` is the bucket capacity in whole requests. `idle_ttl_ms` controls
/// when an unused bucket releases its admission slot.
pub fn rate_limit_token_bucket(name: Dynamic, bucket: Dynamic, key: Dynamic, limit: Int, window_ms: Int, burst: Int, idle_ttl_ms: Int) -> Result(Dynamic, Dynamic) {
  normalize_result(rate_limit_token_bucket_raw(name, bucket, key, limit, window_ms, burst, idle_ttl_ms))
}

@external(erlang, "wiregrid_api", "webhook") fn webhook_raw(p0: Dynamic, p1: String, p2: BitArray) -> Dynamic
pub fn webhook(name: Dynamic, url: String, body: BitArray) -> Result(Dynamic, Dynamic) {
  normalize_result(webhook_raw(name, url, body))
}

@external(erlang, "wiregrid_api", "replay_session") fn replay_session_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Dynamic
@external(erlang, "wiregrid_api", "replay_session") fn replay_session_with_raw(p0: Dynamic, p1: String, p2: Dynamic, p3: Dynamic) -> Dynamic

/// Replays one bounded durable storage page through normal session backpressure.
pub fn replay_session(name: Dynamic, session_id: String, stream: Topic) -> Result(Dynamic, Dynamic) {
  normalize_result(replay_session_raw(name, session_id, topic_term(stream)))
}

/// Advanced replay variant for cursor/limit/class/topic overrides.
pub fn replay_session_with_options(name: Dynamic, session_id: String, stream: Topic, options: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(replay_session_with_raw(name, session_id, topic_term(stream), options))
}

@external(erlang, "wiregrid_gleam_ffi", "replay_session_typed")
fn replay_session_typed_raw(p0: Dynamic, p1: String, p2: Dynamic) -> Result(#(Int, Int, Bool, Dynamic, Dynamic, Dynamic), Dynamic)
@external(erlang, "wiregrid_gleam_ffi", "replay_session_typed")
fn replay_session_typed_with_raw(p0: Dynamic, p1: String, p2: Dynamic, p3: Dynamic) -> Result(#(Int, Int, Bool, Dynamic, Dynamic, Dynamic), Dynamic)

fn replay_stats_from_tuple(value: #(Int, Int, Bool, Dynamic, Dynamic, Dynamic)) -> ReplayStats {
  let #(delivered, dropped, complete_page, resume_cursor, next_cursor, stopped) = value
  ReplayStats(delivered, dropped, complete_page, resume_cursor, next_cursor, stopped)
}

/// Typed bounded durable catch-up for one live session.
pub fn replay_session_typed(name: Dynamic, session_id: String, stream: Topic) -> Result(ReplayStats, Dynamic) {
  case replay_session_typed_raw(name, session_id, topic_term(stream)) {
    Ok(value) -> Ok(replay_stats_from_tuple(value))
    Error(reason) -> Error(reason)
  }
}

/// Typed replay with the same opaque option map accepted by the plain ABI.
pub fn replay_session_typed_with_options(name: Dynamic, session_id: String, stream: Topic, options: Dynamic) -> Result(ReplayStats, Dynamic) {
  case replay_session_typed_with_raw(name, session_id, topic_term(stream), options) {
    Ok(value) -> Ok(replay_stats_from_tuple(value))
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "wiregrid_api", "storage_bootstrap") fn storage_bootstrap_raw(p0: Dynamic) -> Dynamic
pub fn storage_bootstrap(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(storage_bootstrap_raw(name)) }
@external(erlang, "wiregrid_api", "storage_health") fn storage_health_raw(p0: Dynamic) -> Dynamic
pub fn storage_health(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(storage_health_raw(name)) }
@external(erlang, "wiregrid_api", "storage_append") fn storage_append_raw(p0: Dynamic, p1: Dynamic, p2: String, p3: Dynamic, p4: Dynamic) -> Dynamic
pub fn storage_append(name: Dynamic, stream: Dynamic, id: String, event: Dynamic, metadata: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(storage_append_raw(name, stream, id, event, metadata))
}
@external(erlang, "wiregrid_api", "storage_get") fn storage_get_raw(p0: Dynamic, p1: Dynamic, p2: String) -> Dynamic
pub fn storage_get(name: Dynamic, stream: Dynamic, id: String) -> Result(Dynamic, Dynamic) { normalize_result(storage_get_raw(name, stream, id)) }
@external(erlang, "wiregrid_api", "storage_page") fn storage_page_raw(p0: Dynamic, p1: Dynamic) -> Dynamic
pub fn storage_page(name: Dynamic, stream: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(storage_page_raw(name, stream)) }

@external(erlang, "wiregrid_api", "read_history")
fn read_history_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic, p3: Dynamic, p4: Dynamic) -> Dynamic

/// Durable history for one live session. The session is checked with the
/// instance authorizer before the storage page is read.
pub fn read_history(name: Dynamic, session_id: Dynamic, stream: Dynamic, cursor: Dynamic, limit: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(read_history_raw(name, session_id, stream, cursor, limit))
}
@external(erlang, "wiregrid_api", "storage_delete") fn storage_delete_raw(p0: Dynamic, p1: Dynamic, p2: String) -> Dynamic
pub fn storage_delete(name: Dynamic, stream: Dynamic, id: String) -> Result(Dynamic, Dynamic) { normalize_result(storage_delete_raw(name, stream, id)) }
@external(erlang, "wiregrid_api", "storage_prune") fn storage_prune_raw(p0: Dynamic, p1: Dynamic, p2: Int) -> Dynamic
pub fn storage_prune(name: Dynamic, stream: Dynamic, before_ms: Int) -> Result(Dynamic, Dynamic) { normalize_result(storage_prune_raw(name, stream, before_ms)) }

@external(erlang, "wiregrid_api", "cache_get") fn cache_get_raw(p0: Dynamic, p1: Dynamic) -> Dynamic
pub fn cache_get(name: Dynamic, key: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(cache_get_raw(name, key)) }
@external(erlang, "wiregrid_api", "cache_put") fn cache_put_raw(p0: Dynamic, p1: Dynamic, p2: Dynamic) -> Dynamic
pub fn cache_put(name: Dynamic, key: Dynamic, value: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(cache_put_raw(name, key, value)) }
@external(erlang, "wiregrid_api", "cache_delete") fn cache_delete_raw(p0: Dynamic, p1: Dynamic) -> Dynamic
pub fn cache_delete(name: Dynamic, key: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(cache_delete_raw(name, key)) }
@external(erlang, "wiregrid_api", "cache_incr") fn cache_incr_raw(p0: Dynamic, p1: Dynamic, p2: Int) -> Dynamic
pub fn cache_incr(name: Dynamic, key: Dynamic, delta: Int) -> Result(Dynamic, Dynamic) { normalize_result(cache_incr_raw(name, key, delta)) }
@external(erlang, "wiregrid_api", "cache_health") fn cache_health_raw(p0: Dynamic) -> Dynamic
pub fn cache_health(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(cache_health_raw(name)) }

@external(erlang, "wiregrid_api", "health") fn health_raw(p0: Dynamic) -> Dynamic
pub fn health(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(health_raw(name)) }
@external(erlang, "wiregrid_api", "readiness") fn readiness_raw(p0: Dynamic) -> Dynamic
pub fn readiness(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(readiness_raw(name)) }
@external(erlang, "wiregrid_api", "readiness_report") fn readiness_report_raw(p0: Dynamic) -> Dynamic
/// Structured readiness state with pressure/drain/unhealthy reasons.
pub fn readiness_report(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(readiness_report_raw(name)) }
@external(erlang, "wiregrid_api", "deployment_report") fn deployment_report_raw(p0: Dynamic) -> Dynamic
/// Sanitized deployment-hardening report; never includes secrets or payloads.
pub fn deployment_report(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(deployment_report_raw(name)) }
@external(erlang, "wiregrid_api", "ready") pub fn ready(name: Dynamic) -> Bool
@external(erlang, "wiregrid_api", "liveness") fn liveness_raw(p0: Dynamic) -> Dynamic
pub fn liveness(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(liveness_raw(name)) }
@external(erlang, "wiregrid_api", "stats") fn stats_raw(p0: Dynamic) -> Dynamic
@external(erlang, "wiregrid_api", "pressure") fn pressure_raw(p0: Dynamic) -> Dynamic
/// Admission-budget utilization without user content or internal table IDs.
pub fn pressure(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(pressure_raw(name)) }

@external(erlang, "wiregrid_api", "prometheus_metrics") fn prometheus_metrics_raw(p0: Dynamic) -> Dynamic
/// Fixed-cardinality aggregate Prometheus exposition; contains no user/message labels.
pub fn prometheus_metrics(name: Dynamic) -> Result(Dynamic, Dynamic) {
  normalize_result(prometheus_metrics_raw(name))
}

pub fn stats(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(stats_raw(name)) }
@external(erlang, "wiregrid_api", "drain") fn drain_raw(p0: Dynamic) -> Dynamic
pub fn drain(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(drain_raw(name)) }
@external(erlang, "wiregrid_api", "undrain") fn undrain_raw(p0: Dynamic) -> Dynamic
pub fn undrain(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(undrain_raw(name)) }
@external(erlang, "wiregrid_api", "await_idle") fn await_idle_raw(p0: Dynamic) -> Dynamic
pub fn await_idle(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(await_idle_raw(name)) }
@external(erlang, "wiregrid_api", "graceful_shutdown") fn graceful_shutdown_raw(p0: Dynamic) -> Dynamic
pub fn graceful_shutdown(name: Dynamic) -> Result(Dynamic, Dynamic) { normalize_result(graceful_shutdown_raw(name)) }
