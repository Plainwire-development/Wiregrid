%% Small, closed FFI helpers for the typed Gleam facade.
-module(wiregrid_gleam_ffi).
-export([
    atom/1,
    normalize_result/1,
    fanout_stats/1,
    ack_stats/1,
    presence_snapshot/2,
    replay_stats/1,
    replay_session_typed/3,
    replay_session_typed/4,
    topology/3,
    start_profile/2,
    instance_child_spec_profile/2,
    connect_encoded/3,
    connect_resumable_encoded/3,
    connect_actor/3,
    connect_resumable_actor/3,
    resume_actor/4,
    actor_publish/4,
    actor_publish_room/4,
    actor_send_user/4,
    actor_send_session/4,
    actor_dispatch/4,
    publish_class/4,
    publish_room_class/4,
    send_user_class/4,
    send_session_class/4,
    send_sessions_class/4,
    send_users_class/4,
    dispatch_class/4,
    rate_limit_token_bucket/7
]).

%% Closed conversion only. No arbitrary atom creation is performed.
atom(<<"online">>) -> online;
atom(<<"idle">>) -> idle;
atom(<<"dnd">>) -> dnd;
atom(<<"invisible">>) -> invisible;
atom(<<"offline">>) -> offline;
atom(<<"durable">>) -> durable;
atom(<<"ephemeral">>) -> ephemeral;
atom(<<"ring">>) -> ring;
atom(<<"accept">>) -> accept;
atom(<<"decline">>) -> decline;
atom(<<"cancel">>) -> cancel;
atom(<<"offer">>) -> offer;
atom(<<"answer">>) -> answer;
atom(<<"ice_candidate">>) -> ice_candidate;
atom(<<"leave">>) -> leave;
atom(<<"reconnect">>) -> reconnect;
atom(<<"membership">>) -> membership.

normalize_result(ok) -> {ok, nil};
normalize_result({ok, Value}) -> {ok, Value};
normalize_result({error, Reason}) -> {error, Reason};
normalize_result(Value) -> {ok, Value}.

%% Typed operational summaries for Gleam. Application payloads remain dynamic,
%% but common runtime results should not force every caller to decode maps.
fanout_stats(Value) when is_map(Value) ->
    {ok, {maps:get(sent, Value, 0),
          maps:get(dropped, Value, 0),
          maps:get(evicted, Value, 0),
          maps:get(gone, Value, 0),
          maps:get(excluded, Value, 0),
          maps:get(overloaded, Value, 0)}};
fanout_stats(_) -> {error, invalid_fanout_stats}.

ack_stats(Value) when is_map(Value) ->
    Unknown = maps:get(unknown, Value, []),
    case is_list(Unknown) of
        true -> {ok, {maps:get(acked, Value, 0), length(Unknown), maps:get(pending, Value, 0)}};
        false -> {error, invalid_ack_stats}
    end;
ack_stats(_) -> {error, invalid_ack_stats}.

%% Stable typed views for common runtime state. Arbitrary application metadata
%% remains opaque to Gleam, but callers should not need to understand Elixir
%% maps just to inspect presence or durable replay progress.
presence_snapshot(Name, User) ->
    presence_snapshot_value(wiregrid_api:presence(Name, User)).

presence_snapshot_value(Value) when is_map(Value) ->
    case presence_name(maps:get(status, Value, offline)) of
        {ok, StatusName, Custom} ->
            Sessions = maps:get(sessions, Value, 0),
            Metadata = maps:get(metadata, Value, #{}),
            Updated = maps:get(updated_at_ms, Value, 0),
            case is_integer(Sessions) andalso Sessions >= 0 andalso
                 is_integer(Updated) andalso Updated >= 0 of
                true -> {ok, {StatusName, Custom, Sessions, Metadata, Updated}};
                false -> {error, invalid_presence_snapshot}
            end;
        error -> {error, invalid_presence_snapshot}
    end;
presence_snapshot_value(_) -> {error, invalid_presence_snapshot}.

presence_name(online) -> {ok, <<"online">>, <<>>};
presence_name(idle) -> {ok, <<"idle">>, <<>>};
presence_name(dnd) -> {ok, <<"dnd">>, <<>>};
presence_name(invisible) -> {ok, <<"invisible">>, <<>>};
presence_name(offline) -> {ok, <<"offline">>, <<>>};
presence_name({custom, Value}) when is_binary(Value) -> {ok, <<"custom">>, Value};
presence_name(_) -> error.

replay_stats(Value) when is_map(Value) ->
    Delivered = maps:get(delivered, Value, 0),
    Dropped = maps:get(dropped, Value, 0),
    Complete = maps:get(complete_page, Value, false),
    case is_integer(Delivered) andalso Delivered >= 0 andalso
         is_integer(Dropped) andalso Dropped >= 0 andalso is_boolean(Complete) of
        true ->
            {ok, {Delivered, Dropped, Complete,
                  maps:get(resume_cursor, Value, nil),
                  maps:get(next_cursor, Value, nil),
                  maps:get(stopped, Value, nil)}};
        false -> {error, invalid_replay_stats}
    end;
replay_stats(_) -> {error, invalid_replay_stats}.

replay_session_typed(Name, Session, Stream) ->
    replay_result(wiregrid_api:replay_session(Name, Session, Stream)).

replay_session_typed(Name, Session, Stream, Opts) ->
    replay_result(wiregrid_api:replay_session(Name, Session, Stream, Opts)).

replay_result({ok, Value}) -> replay_stats(Value);
replay_result({error, _} = Error) -> Error;
replay_result(_) -> {error, invalid_replay_result}.

topology(Subscriptions, PresenceWatches, Rooms) ->
    #{subscriptions => Subscriptions, presence_watches => PresenceWatches, rooms => Rooms}.

start_profile(Name, <<"small">>) -> wiregrid_api:start_instance(Name, [{profile, small}]);
start_profile(Name, <<"balanced">>) -> wiregrid_api:start_instance(Name, [{profile, balanced}]);
start_profile(Name, <<"large">>) -> wiregrid_api:start_instance(Name, [{profile, large}]);
start_profile(_Name, _) -> {error, invalid_profile}.

instance_child_spec_profile(Name, <<"small">>) -> wiregrid_api:instance_child_spec(Name, [{profile, small}]);
instance_child_spec_profile(Name, <<"balanced">>) -> wiregrid_api:instance_child_spec(Name, [{profile, balanced}]);
instance_child_spec_profile(Name, <<"large">>) -> wiregrid_api:instance_child_spec(Name, [{profile, large}]);
instance_child_spec_profile(_Name, _) -> {error, invalid_profile}.

connect_encoded(Name, User, Pid) ->
    wiregrid_api:connect(Name, User, Pid, [{delivery_format, encoded}]).

connect_resumable_encoded(Name, User, Pid) ->
    wiregrid_api:connect_resumable(Name, User, Pid, [{delivery_format, encoded}]).

%% Typed Gleam actor helpers. Identity-bearing publication is kept in this
%% closed FFI so a Gleam caller cannot accidentally omit the authenticated
%% session_id option when using an Actor value.
connect_actor(Name, User, Pid) ->
    case wiregrid_api:connect(Name, User, Pid) of
        {ok, Session} -> {ok, {Name, Session, User}};
        Error -> Error
    end.

connect_resumable_actor(Name, User, Pid) ->
    case wiregrid_api:connect_resumable(Name, User, Pid) of
        {ok, Session, Token} -> {ok, {Name, Session, User, Token}};
        Error -> Error
    end.

resume_actor(Name, User, Pid, Token) ->
    case wiregrid_api:resume_session(Name, User, Pid, Token) of
        {ok, Result} when is_map(Result) ->
            case {maps:find(session_id, Result), maps:find(resume_token, Result)} of
                {{ok, Session}, {ok, Next}} ->
                    Restored = maps:get(restored, Result, #{}),
                    {ok, {Name, Session, User, Next, Restored}};
                _ ->
                    {error, invalid_resume_result}
            end;
        Error -> Error
    end.

actor_publish(Name, Session, Topic, Event) ->
    wiregrid_api:publish(Name, Topic, Event, [{session_id, Session}]).

actor_publish_room(Name, Session, Room, Event) ->
    wiregrid_api:publish_room(Name, Room, Event, [{session_id, Session}]).

actor_send_user(Name, Session, User, Event) ->
    wiregrid_api:send_user(Name, User, Event, [{session_id, Session}]).

actor_send_session(Name, Session, Target, Event) ->
    wiregrid_api:send_session(Name, Target, Event, [{session_id, Session}]).

actor_dispatch(Name, Session, Targets, Event) ->
    wiregrid_api:dispatch(Name, Targets, Event, [{session_id, Session}]).

publish_class(Name, Topic, Event, Class) ->
    wiregrid_api:publish(Name, Topic, Event, [{class, class(Class)}]).

publish_room_class(Name, Room, Event, Class) ->
    wiregrid_api:publish_room(Name, Room, Event, [{class, class(Class)}]).

send_user_class(Name, User, Event, Class) ->
    wiregrid_api:send_user(Name, User, Event, [{class, class(Class)}]).

send_session_class(Name, Session, Event, Class) ->
    wiregrid_api:send_session(Name, Session, Event, [{class, class(Class)}]).

send_sessions_class(Name, Sessions, Event, Class) ->
    wiregrid_api:send_sessions(Name, Sessions, Event, [{class, class(Class)}]).

send_users_class(Name, Users, Event, Class) ->
    wiregrid_api:send_users(Name, Users, Event, [{class, class(Class)}]).

dispatch_class(Name, Targets, Event, Class) ->
    wiregrid_api:dispatch(Name, Targets, Event, [{class, class(Class)}]).

class(<<"durable">>) -> durable;
class(<<"ephemeral">>) -> ephemeral.


rate_limit_token_bucket(Name, Bucket, Key, Limit, WindowMs, Burst, IdleTtlMs) ->
    wiregrid_api:rate_limit(Name, Bucket, Key, Limit, WindowMs,
        [{policy, token_bucket}, {burst, Burst}, {idle_ttl_ms, IdleTtlMs}]).
