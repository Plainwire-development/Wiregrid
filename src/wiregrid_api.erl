%% Stable plain-term Erlang facade for Wiregrid.
%% No Elixir structs, macros, or keyword defaults are required by callers.
-module(wiregrid_api).

-export([
    version/0, protocol_version/0, foreign_protocol_version/0, c_abi_major/0, capabilities/1, describe/1,
    start_instance/1, start_instance/2, stop_instance/1, instance_child_spec/1, instance_child_spec/2,
    connect/3, connect/4, connect_resumable/3, connect_resumable/4,
    resume_session/4, resume_session/5, disconnect/2, disconnect/3, disconnect_user/2, disconnect_user/3, set_session_metadata/3,
    subscribe/3, subscribe/4, unsubscribe/3,
    subscribe_many/3, subscribe_many/4, unsubscribe_many/3, sync_subscriptions/3, sync_subscriptions/4,
    sync_topology/3, sync_topology/4,
    prepare/2, publish/3, publish/4, publish_prepared/3, publish_prepared/4, publish_batch/3, publish_batch/4,
    publish_topics/3, publish_topics/4, publish_topics_prepared/3, publish_topics_prepared/4,
    publish_room/3, publish_room/4, publish_room_prepared/3, publish_room_prepared/4,
    publish_rooms/3, publish_rooms/4, publish_rooms_prepared/3, publish_rooms_prepared/4,
    send_user/3, send_user/4, send_user_prepared/3, send_user_prepared/4, send_session/3, send_session/4, send_session_prepared/3, send_session_prepared/4,
    send_sessions/3, send_sessions/4, send_sessions_prepared/3, send_sessions_prepared/4,
    send_users/3, send_users/4, send_users_prepared/3, send_users_prepared/4,
    dispatch/3, dispatch/4, dispatch_prepared/3, dispatch_prepared/4,
    compile_dispatch/2, dispatch_plan/3, dispatch_plan/4, dispatch_plan_prepared/3, dispatch_plan_prepared/4,
    ack/2, ack/3, ack_many/3, pending/2,
    set_presence/3, set_presence/4, presence/2,
    watch_presence/3, watch_presence/4, unwatch_presence/3, watch_presence_many/3, watch_presence_many/4, unwatch_presence_many/3,
    sync_presence_watches/3, sync_presence_watches/4,
    join_room/3, join_room/4, leave_room/3, join_rooms/3, join_rooms/4, leave_rooms/3, sync_rooms/3, sync_rooms/4, resume_room/4,
    room_members/2, room_members/3, room_metadata/2,
    set_room_metadata/4, set_room_metadata/5, set_room_ttl/4,
    activity/5, activity/6, activities/3, activities/4, typing/3, typing/4,
    receipt/3, receipt/4, get_receipt/3,
    signal/5, signal/6,
    rate_limit/5, rate_limit/6, webhook/3, webhook/4, replay_session/3, replay_session/4,
    storage_bootstrap/1, storage_health/1, storage_append/4, storage_append/5,
    storage_get/3, storage_page/2, storage_page/4,
    read_history/3, read_history/4, read_history/5,
    storage_delete/3, storage_prune/3, storage_prune/4,
    cache_get/2, cache_put/3, cache_put/4, cache_delete/2,
    cache_incr/2, cache_incr/3, cache_incr/4, cache_health/1,
    session/2, user_sessions/2, user_sessions/3,
    session_state/2, session_state/3, topic_info/2, topic_info/3,
    room_info/2, room_info/3, user_info/2, user_info/3,
    subscriptions/2, subscriptions/3,
    topic_sessions/2, topic_sessions/3, session_rooms/2, session_rooms/3,
    presence_watches/2, presence_watches/3, limits/1, topic_subscriber_count/2, room_member_count/2, presence_watcher_count/2, user_session_count/2, room_member/3, subscribed/3,
    decode_payload/2, delivery_event/2, consume_delivery/3, consume_many_deliveries/3, consume_ordered_deliveries/3, consume_projection/5, request_session/4, request_session/5, reply/4, reply/5, request_context/1,
    transport_audience/1, issue_transport_token/2, issue_transport_token/3, verify_transport_token/2, verify_transport_token/3,
    health/1, readiness/1, readiness_report/1, deployment_report/1, ready/1, liveness/1, stats/1, pressure/1, prometheus_metrics/1,
    drain/1, undrain/1, await_idle/1, await_idle/2,
    graceful_shutdown/1, graceful_shutdown/2,
    topic_user/1, topic_channel/1, topic_thread/1, topic_room/1,
    topic_game/1, topic_document/1, topic_custom/2,
    presence_status/1, presence_custom/1, signal_kind/1,
    target_topic/1, target_room/1, target_user/1, target_session/1
]).

version() -> 'Elixir.Wiregrid':version().
protocol_version() -> 'Elixir.Wiregrid':protocol_version().
foreign_protocol_version() -> 'Elixir.Wiregrid':foreign_protocol_version().
c_abi_major() -> 'Elixir.Wiregrid':c_abi_major().
capabilities(Name) -> 'Elixir.Wiregrid':capabilities(Name).
describe(Name) -> 'Elixir.Wiregrid':describe(Name).

start_instance(Name) -> 'Elixir.Wiregrid':start_instance(Name).
start_instance(Name, Opts) -> 'Elixir.Wiregrid':start_instance(Name, Opts).
stop_instance(Name) -> 'Elixir.Wiregrid':stop_instance(Name).
instance_child_spec(Name) -> 'Elixir.Wiregrid':instance_child_spec(Name).
instance_child_spec(Name, Opts) -> 'Elixir.Wiregrid':instance_child_spec(Name, Opts).

connect(Name, User, Pid) -> 'Elixir.Wiregrid':connect(Name, User, Pid).
connect(Name, User, Pid, Opts) -> 'Elixir.Wiregrid':connect(Name, User, Pid, Opts).
connect_resumable(Name, User, Pid) -> 'Elixir.Wiregrid':connect_resumable(Name, User, Pid).
connect_resumable(Name, User, Pid, Opts) -> 'Elixir.Wiregrid':connect_resumable(Name, User, Pid, Opts).
resume_session(Name, User, Pid, Token) -> 'Elixir.Wiregrid':resume_session(Name, User, Pid, Token).
resume_session(Name, User, Pid, Token, Opts) -> 'Elixir.Wiregrid':resume_session(Name, User, Pid, Token, Opts).
disconnect(Name, Session) -> 'Elixir.Wiregrid':disconnect(Name, Session).
disconnect(Name, Session, Reason) -> 'Elixir.Wiregrid':disconnect(Name, Session, Reason).
disconnect_user(Name, User) -> 'Elixir.Wiregrid':disconnect_user(Name, User).
disconnect_user(Name, User, Reason) -> 'Elixir.Wiregrid':disconnect_user(Name, User, Reason).
set_session_metadata(Name, Session, Metadata) -> 'Elixir.Wiregrid':set_session_metadata(Name, Session, Metadata).

subscribe(Name, Session, Topic) -> 'Elixir.Wiregrid':subscribe(Name, Session, Topic).
subscribe(Name, Session, Topic, Context) -> 'Elixir.Wiregrid':subscribe(Name, Session, Topic, Context).
unsubscribe(Name, Session, Topic) -> 'Elixir.Wiregrid':unsubscribe(Name, Session, Topic).
subscribe_many(Name, Session, Topics) -> 'Elixir.Wiregrid':subscribe_many(Name, Session, Topics).
subscribe_many(Name, Session, Topics, Context) -> 'Elixir.Wiregrid':subscribe_many(Name, Session, Topics, Context).
unsubscribe_many(Name, Session, Topics) -> 'Elixir.Wiregrid':unsubscribe_many(Name, Session, Topics).
sync_subscriptions(Name, Session, Topics) -> 'Elixir.Wiregrid':sync_subscriptions(Name, Session, Topics).
sync_subscriptions(Name, Session, Topics, Context) -> 'Elixir.Wiregrid':sync_subscriptions(Name, Session, Topics, Context).
sync_topology(Name, Session, Topology) -> 'Elixir.Wiregrid':sync_topology(Name, Session, Topology).
sync_topology(Name, Session, Topology, Opts) -> 'Elixir.Wiregrid':sync_topology(Name, Session, Topology, Opts).

prepare(Name, Event) -> 'Elixir.Wiregrid':prepare(Name, Event).

publish(Name, Topic, Event) -> 'Elixir.Wiregrid':publish(Name, Topic, Event).
publish(Name, Topic, Event, Opts) -> 'Elixir.Wiregrid':publish(Name, Topic, Event, Opts).
publish_prepared(Name, Topic, Prepared) -> 'Elixir.Wiregrid':publish_prepared(Name, Topic, Prepared).
publish_prepared(Name, Topic, Prepared, Opts) -> 'Elixir.Wiregrid':publish_prepared(Name, Topic, Prepared, Opts).
publish_batch(Name, Topic, Events) -> 'Elixir.Wiregrid':publish_batch(Name, Topic, Events).
publish_batch(Name, Topic, Events, Opts) -> 'Elixir.Wiregrid':publish_batch(Name, Topic, Events, Opts).
publish_topics(Name, Topics, Event) -> 'Elixir.Wiregrid':publish_topics(Name, Topics, Event).
publish_topics(Name, Topics, Event, Opts) -> 'Elixir.Wiregrid':publish_topics(Name, Topics, Event, Opts).
publish_topics_prepared(Name, Topics, Prepared) -> 'Elixir.Wiregrid':publish_topics_prepared(Name, Topics, Prepared).
publish_topics_prepared(Name, Topics, Prepared, Opts) -> 'Elixir.Wiregrid':publish_topics_prepared(Name, Topics, Prepared, Opts).
publish_room(Name, Room, Event) -> 'Elixir.Wiregrid':publish_room(Name, Room, Event).
publish_room(Name, Room, Event, Opts) -> 'Elixir.Wiregrid':publish_room(Name, Room, Event, Opts).
publish_room_prepared(Name, Room, Prepared) -> 'Elixir.Wiregrid':publish_room_prepared(Name, Room, Prepared).
publish_room_prepared(Name, Room, Prepared, Opts) -> 'Elixir.Wiregrid':publish_room_prepared(Name, Room, Prepared, Opts).
publish_rooms(Name, Rooms, Event) -> 'Elixir.Wiregrid':publish_rooms(Name, Rooms, Event).
publish_rooms(Name, Rooms, Event, Opts) -> 'Elixir.Wiregrid':publish_rooms(Name, Rooms, Event, Opts).
publish_rooms_prepared(Name, Rooms, Prepared) -> 'Elixir.Wiregrid':publish_rooms_prepared(Name, Rooms, Prepared).
publish_rooms_prepared(Name, Rooms, Prepared, Opts) -> 'Elixir.Wiregrid':publish_rooms_prepared(Name, Rooms, Prepared, Opts).
send_user(Name, User, Event) -> 'Elixir.Wiregrid':send_user(Name, User, Event).
send_user(Name, User, Event, Opts) -> 'Elixir.Wiregrid':send_user(Name, User, Event, Opts).
send_user_prepared(Name, User, Prepared) -> 'Elixir.Wiregrid':send_user_prepared(Name, User, Prepared).
send_user_prepared(Name, User, Prepared, Opts) -> 'Elixir.Wiregrid':send_user_prepared(Name, User, Prepared, Opts).
send_session(Name, Session, Event) -> 'Elixir.Wiregrid':send_session(Name, Session, Event).
send_session(Name, Session, Event, Opts) -> 'Elixir.Wiregrid':send_session(Name, Session, Event, Opts).
send_session_prepared(Name, Session, Prepared) -> 'Elixir.Wiregrid':send_session_prepared(Name, Session, Prepared).
send_session_prepared(Name, Session, Prepared, Opts) -> 'Elixir.Wiregrid':send_session_prepared(Name, Session, Prepared, Opts).
send_sessions(Name, Sessions, Event) -> 'Elixir.Wiregrid':send_sessions(Name, Sessions, Event).
send_sessions(Name, Sessions, Event, Opts) -> 'Elixir.Wiregrid':send_sessions(Name, Sessions, Event, Opts).
send_sessions_prepared(Name, Sessions, Prepared) -> 'Elixir.Wiregrid':send_sessions_prepared(Name, Sessions, Prepared).
send_sessions_prepared(Name, Sessions, Prepared, Opts) -> 'Elixir.Wiregrid':send_sessions_prepared(Name, Sessions, Prepared, Opts).
send_users(Name, Users, Event) -> 'Elixir.Wiregrid':send_users(Name, Users, Event).
send_users(Name, Users, Event, Opts) -> 'Elixir.Wiregrid':send_users(Name, Users, Event, Opts).
send_users_prepared(Name, Users, Prepared) -> 'Elixir.Wiregrid':send_users_prepared(Name, Users, Prepared).
send_users_prepared(Name, Users, Prepared, Opts) -> 'Elixir.Wiregrid':send_users_prepared(Name, Users, Prepared, Opts).
dispatch(Name, Targets, Event) -> 'Elixir.Wiregrid':dispatch(Name, Targets, Event).
dispatch(Name, Targets, Event, Opts) -> 'Elixir.Wiregrid':dispatch(Name, Targets, Event, Opts).
dispatch_prepared(Name, Targets, Prepared) -> 'Elixir.Wiregrid':dispatch_prepared(Name, Targets, Prepared).
dispatch_prepared(Name, Targets, Prepared, Opts) -> 'Elixir.Wiregrid':dispatch_prepared(Name, Targets, Prepared, Opts).
compile_dispatch(Name, Targets) -> 'Elixir.Wiregrid':compile_dispatch(Name, Targets).
dispatch_plan(Name, Plan, Event) -> 'Elixir.Wiregrid':dispatch_plan(Name, Plan, Event).
dispatch_plan(Name, Plan, Event, Opts) -> 'Elixir.Wiregrid':dispatch_plan(Name, Plan, Event, Opts).
dispatch_plan_prepared(Name, Plan, Prepared) -> 'Elixir.Wiregrid':dispatch_plan_prepared(Name, Plan, Prepared).
dispatch_plan_prepared(Name, Plan, Prepared, Opts) -> 'Elixir.Wiregrid':dispatch_plan_prepared(Name, Plan, Prepared, Opts).
ack(Name, Session) -> 'Elixir.Wiregrid':ack(Name, Session).
ack(Name, Session, DeliveryId) -> 'Elixir.Wiregrid':ack(Name, Session, DeliveryId).
ack_many(Name, Session, DeliveryIds) -> 'Elixir.Wiregrid':ack_many(Name, Session, DeliveryIds).
pending(Name, Session) -> 'Elixir.Wiregrid':pending(Name, Session).

set_presence(Name, Session, Status) -> 'Elixir.Wiregrid':set_presence(Name, Session, Status).
set_presence(Name, Session, Status, Metadata) -> 'Elixir.Wiregrid':set_presence(Name, Session, Status, Metadata).
presence(Name, User) -> 'Elixir.Wiregrid':presence(Name, User).
watch_presence(Name, Session, User) -> 'Elixir.Wiregrid':watch_presence(Name, Session, User).
watch_presence(Name, Session, User, Context) -> 'Elixir.Wiregrid':watch_presence(Name, Session, User, Context).
unwatch_presence(Name, Session, User) -> 'Elixir.Wiregrid':unwatch_presence(Name, Session, User).
watch_presence_many(Name, Session, Users) -> 'Elixir.Wiregrid':watch_presence_many(Name, Session, Users).
watch_presence_many(Name, Session, Users, Context) -> 'Elixir.Wiregrid':watch_presence_many(Name, Session, Users, Context).
unwatch_presence_many(Name, Session, Users) -> 'Elixir.Wiregrid':unwatch_presence_many(Name, Session, Users).
sync_presence_watches(Name, Session, Users) -> 'Elixir.Wiregrid':sync_presence_watches(Name, Session, Users).
sync_presence_watches(Name, Session, Users, Context) -> 'Elixir.Wiregrid':sync_presence_watches(Name, Session, Users, Context).

join_room(Name, Room, Session) -> 'Elixir.Wiregrid':join_room(Name, Room, Session).
join_room(Name, Room, Session, Opts) -> 'Elixir.Wiregrid':join_room(Name, Room, Session, Opts).
leave_room(Name, Room, Session) -> 'Elixir.Wiregrid':leave_room(Name, Room, Session).
join_rooms(Name, Rooms, Session) -> 'Elixir.Wiregrid':join_rooms(Name, Rooms, Session).
join_rooms(Name, Rooms, Session, Opts) -> 'Elixir.Wiregrid':join_rooms(Name, Rooms, Session, Opts).
leave_rooms(Name, Rooms, Session) -> 'Elixir.Wiregrid':leave_rooms(Name, Rooms, Session).
sync_rooms(Name, Session, Rooms) -> 'Elixir.Wiregrid':sync_rooms(Name, Session, Rooms).
sync_rooms(Name, Session, Rooms, Opts) -> 'Elixir.Wiregrid':sync_rooms(Name, Session, Rooms, Opts).
resume_room(Name, Room, OldSession, NewSession) -> 'Elixir.Wiregrid':resume_room(Name, Room, OldSession, NewSession).
room_members(Name, Room) -> 'Elixir.Wiregrid':room_members(Name, Room).
room_members(Name, Room, Limit) -> 'Elixir.Wiregrid':room_members(Name, Room, Limit).
room_metadata(Name, Room) -> 'Elixir.Wiregrid':room_metadata(Name, Room).
set_room_metadata(Name, Room, Session, Metadata) -> 'Elixir.Wiregrid':set_room_metadata(Name, Room, Session, Metadata).
set_room_metadata(Name, Room, Session, Metadata, Opts) -> 'Elixir.Wiregrid':set_room_metadata(Name, Room, Session, Metadata, Opts).
set_room_ttl(Name, Room, Session, TtlMs) -> 'Elixir.Wiregrid':set_room_ttl(Name, Room, Session, TtlMs).

activity(Name, Session, Topic, Kind, Value) -> 'Elixir.Wiregrid':activity(Name, Session, Topic, Kind, Value).
activity(Name, Session, Topic, Kind, Value, Opts) -> 'Elixir.Wiregrid':activity(Name, Session, Topic, Kind, Value, Opts).
activities(Name, Topic, Kind) -> 'Elixir.Wiregrid':activities(Name, Topic, Kind).
activities(Name, Topic, Kind, Limit) -> 'Elixir.Wiregrid':activities(Name, Topic, Kind, Limit).
typing(Name, Session, Topic) -> 'Elixir.Wiregrid':typing(Name, Session, Topic).
typing(Name, Session, Topic, Opts) -> 'Elixir.Wiregrid':typing(Name, Session, Topic, Opts).
receipt(Name, Session, Receipt) -> 'Elixir.Wiregrid':receipt(Name, Session, Receipt).
receipt(Name, Session, Receipt, Opts) -> 'Elixir.Wiregrid':receipt(Name, Session, Receipt, Opts).
get_receipt(Name, Session, ReceiptId) -> 'Elixir.Wiregrid':get_receipt(Name, Session, ReceiptId).
signal(Name, Room, Session, Kind, Payload) -> 'Elixir.Wiregrid':signal(Name, Room, Session, Kind, Payload).
signal(Name, Room, Session, Kind, Payload, Opts) -> 'Elixir.Wiregrid':signal(Name, Room, Session, Kind, Payload, Opts).

rate_limit(Name, Bucket, Key, Limit, WindowMs) -> 'Elixir.Wiregrid':rate_limit(Name, Bucket, Key, Limit, WindowMs).
rate_limit(Name, Bucket, Key, Limit, WindowMs, Opts) -> 'Elixir.Wiregrid':rate_limit(Name, Bucket, Key, Limit, WindowMs, Opts).
webhook(Name, Url, Body) -> 'Elixir.Wiregrid':webhook(Name, Url, Body).
webhook(Name, Url, Body, Opts) -> 'Elixir.Wiregrid':webhook(Name, Url, Body, Opts).
replay_session(Name, Session, Stream) -> 'Elixir.Wiregrid':replay_session(Name, Session, Stream).
replay_session(Name, Session, Stream, Opts) -> 'Elixir.Wiregrid':replay_session(Name, Session, Stream, Opts).

storage_bootstrap(Name) -> 'Elixir.Wiregrid.Storage':bootstrap(Name).
storage_health(Name) -> 'Elixir.Wiregrid':storage_health(Name).
storage_append(Name, Stream, Id, Event) -> 'Elixir.Wiregrid.Storage':append(Name, Stream, Id, Event).
storage_append(Name, Stream, Id, Event, Meta) -> 'Elixir.Wiregrid.Storage':append(Name, Stream, Id, Event, Meta).
storage_get(Name, Stream, Id) -> 'Elixir.Wiregrid.Storage':get(Name, Stream, Id).
storage_page(Name, Stream) -> 'Elixir.Wiregrid.Storage':page(Name, Stream).
storage_page(Name, Stream, Cursor, Limit) -> 'Elixir.Wiregrid.Storage':page(Name, Stream, Cursor, Limit).
read_history(Name, Session, Stream) -> 'Elixir.Wiregrid':read_history(Name, Session, Stream).
read_history(Name, Session, Stream, Cursor) -> 'Elixir.Wiregrid':read_history(Name, Session, Stream, Cursor).
read_history(Name, Session, Stream, Cursor, Limit) -> 'Elixir.Wiregrid':read_history(Name, Session, Stream, Cursor, Limit).
storage_delete(Name, Stream, Id) -> 'Elixir.Wiregrid.Storage':delete(Name, Stream, Id).
storage_prune(Name, Stream, BeforeMs) -> 'Elixir.Wiregrid.Storage':prune(Name, Stream, BeforeMs).
storage_prune(Name, Stream, BeforeMs, Limit) -> 'Elixir.Wiregrid.Storage':prune(Name, Stream, BeforeMs, Limit).

cache_get(Name, Key) -> 'Elixir.Wiregrid.Cache':get(Name, Key).
cache_put(Name, Key, Value) -> 'Elixir.Wiregrid.Cache':put(Name, Key, Value).
cache_put(Name, Key, Value, Ttl) -> 'Elixir.Wiregrid.Cache':put(Name, Key, Value, Ttl).
cache_delete(Name, Key) -> 'Elixir.Wiregrid.Cache':delete(Name, Key).
cache_incr(Name, Key) -> 'Elixir.Wiregrid.Cache':incr(Name, Key).
cache_incr(Name, Key, Delta) -> 'Elixir.Wiregrid.Cache':incr(Name, Key, Delta).
cache_incr(Name, Key, Delta, Ttl) -> 'Elixir.Wiregrid.Cache':incr(Name, Key, Delta, Ttl).
cache_health(Name) -> 'Elixir.Wiregrid':cache_health(Name).

session(Name, Session) -> 'Elixir.Wiregrid':session(Name, Session).
user_sessions(Name, User) -> 'Elixir.Wiregrid':user_sessions(Name, User).
user_sessions(Name, User, Limit) -> 'Elixir.Wiregrid':user_sessions(Name, User, Limit).
session_state(Name, Session) -> 'Elixir.Wiregrid':session_state(Name, Session).
session_state(Name, Session, Limit) -> 'Elixir.Wiregrid':session_state(Name, Session, Limit).
topic_info(Name, Topic) -> 'Elixir.Wiregrid':topic_info(Name, Topic).
topic_info(Name, Topic, Limit) -> 'Elixir.Wiregrid':topic_info(Name, Topic, Limit).
room_info(Name, Room) -> 'Elixir.Wiregrid':room_info(Name, Room).
room_info(Name, Room, Limit) -> 'Elixir.Wiregrid':room_info(Name, Room, Limit).
user_info(Name, User) -> 'Elixir.Wiregrid':user_info(Name, User).
user_info(Name, User, Limit) -> 'Elixir.Wiregrid':user_info(Name, User, Limit).
subscriptions(Name, Session) -> 'Elixir.Wiregrid':subscriptions(Name, Session).
subscriptions(Name, Session, Limit) -> 'Elixir.Wiregrid':subscriptions(Name, Session, Limit).
topic_sessions(Name, Topic) -> 'Elixir.Wiregrid':topic_sessions(Name, Topic).
topic_sessions(Name, Topic, Limit) -> 'Elixir.Wiregrid':topic_sessions(Name, Topic, Limit).
session_rooms(Name, Session) -> 'Elixir.Wiregrid':session_rooms(Name, Session).
session_rooms(Name, Session, Limit) -> 'Elixir.Wiregrid':session_rooms(Name, Session, Limit).
presence_watches(Name, Session) -> 'Elixir.Wiregrid':presence_watches(Name, Session).
presence_watches(Name, Session, Limit) -> 'Elixir.Wiregrid':presence_watches(Name, Session, Limit).
limits(Name) -> 'Elixir.Wiregrid':limits(Name).
topic_subscriber_count(Name, Topic) -> 'Elixir.Wiregrid':topic_subscriber_count(Name, Topic).
room_member_count(Name, Room) -> 'Elixir.Wiregrid':room_member_count(Name, Room).
presence_watcher_count(Name, User) -> 'Elixir.Wiregrid':presence_watcher_count(Name, User).
user_session_count(Name, User) -> 'Elixir.Wiregrid':user_session_count(Name, User).
room_member(Name, Room, Session) -> 'Elixir.Wiregrid':'room_member?'(Name, Room, Session).
subscribed(Name, Session, Topic) -> 'Elixir.Wiregrid':'subscribed?'(Name, Session, Topic).
decode_payload(Name, Payload) -> 'Elixir.Wiregrid':decode_payload(Name, Payload).
delivery_event(Name, Envelope) -> 'Elixir.Wiregrid.Consumer':event(Name, Envelope).
consume_delivery(Name, Envelope, Handler) -> 'Elixir.Wiregrid.Consumer':consume(Name, Envelope, Handler).
consume_many_deliveries(Name, Envelopes, Handler) -> 'Elixir.Wiregrid':consume_many_deliveries(Name, Envelopes, Handler).
consume_ordered_deliveries(Name, Envelopes, Handler) -> 'Elixir.Wiregrid':consume_ordered_deliveries(Name, Envelopes, Handler).
consume_projection(Name, Envelopes, Accumulator, Reducer, Commit) -> 'Elixir.Wiregrid':consume_projection(Name, Envelopes, Accumulator, Reducer, Commit).
request_session(Name, Requester, Target, Event) -> 'Elixir.Wiregrid':request_session(Name, Requester, Target, Event).
request_session(Name, Requester, Target, Event, Opts) -> 'Elixir.Wiregrid':request_session(Name, Requester, Target, Event, Opts).
reply(Name, Replier, RequestEnvelope, Event) -> 'Elixir.Wiregrid':reply(Name, Replier, RequestEnvelope, Event).
reply(Name, Replier, RequestEnvelope, Event, Opts) -> 'Elixir.Wiregrid':reply(Name, Replier, RequestEnvelope, Event, Opts).
request_context(Envelope) -> 'Elixir.Wiregrid':request_context(Envelope).
transport_audience(Name) -> 'Elixir.Wiregrid':transport_audience(Name).
issue_transport_token(Subject, Keys) -> 'Elixir.Wiregrid':issue_transport_token(Subject, Keys).
issue_transport_token(Subject, Keys, Opts) -> 'Elixir.Wiregrid':issue_transport_token(Subject, Keys, Opts).
verify_transport_token(Token, Keys) -> 'Elixir.Wiregrid':verify_transport_token(Token, Keys).
verify_transport_token(Token, Keys, Opts) -> 'Elixir.Wiregrid':verify_transport_token(Token, Keys, Opts).

health(Name) -> 'Elixir.Wiregrid':health(Name).
readiness(Name) -> 'Elixir.Wiregrid':readiness(Name).
readiness_report(Name) -> 'Elixir.Wiregrid':readiness_report(Name).
deployment_report(Name) -> 'Elixir.Wiregrid':deployment_report(Name).
ready(Name) -> 'Elixir.Wiregrid':'ready?'(Name).
liveness(Name) -> 'Elixir.Wiregrid':liveness(Name).
stats(Name) -> 'Elixir.Wiregrid':stats(Name).
pressure(Name) -> 'Elixir.Wiregrid':pressure(Name).
prometheus_metrics(Name) -> 'Elixir.Wiregrid':prometheus_metrics(Name).
drain(Name) -> 'Elixir.Wiregrid':drain(Name).
undrain(Name) -> 'Elixir.Wiregrid':undrain(Name).
await_idle(Name) -> 'Elixir.Wiregrid':await_idle(Name).
await_idle(Name, TimeoutMs) -> 'Elixir.Wiregrid':await_idle(Name, TimeoutMs).
graceful_shutdown(Name) -> 'Elixir.Wiregrid':graceful_shutdown(Name).
graceful_shutdown(Name, TimeoutMs) -> 'Elixir.Wiregrid':graceful_shutdown(Name, TimeoutMs).

%% Constructors used by typed BEAM-language facades. They return ordinary terms.
topic_user(Id) -> {user, Id}.
topic_channel(Id) -> {channel, Id}.
topic_thread(Id) -> {thread, Id}.
topic_room(Id) -> {room, Id}.
topic_game(Id) -> {game, Id}.
topic_document(Id) -> {document, Id}.
topic_custom(Namespace, Value) -> {custom, Namespace, Value}.
presence_status(Status) when Status =:= online; Status =:= idle; Status =:= dnd; Status =:= invisible; Status =:= offline -> Status.
presence_custom(Value) -> {custom, Value}.
signal_kind(Kind) when Kind =:= ring; Kind =:= accept; Kind =:= decline; Kind =:= cancel; Kind =:= offer; Kind =:= answer; Kind =:= ice_candidate; Kind =:= leave; Kind =:= reconnect; Kind =:= membership -> Kind.

%% Heterogeneous dispatch constructors used by typed facades.
target_topic(Topic) -> {topic, Topic}.
target_room(Room) -> {room, Room}.
target_user(User) -> {user, User}.
target_session(Session) -> {session, Session}.
