# erlang api

`src/wiregrid_api.erl` is the stable plain-term beam boundary. it exists so erlang and other beam languages do not have to build elixir structs, call macros, or guess keyword defaults.

```erlang
{ok, _} = wiregrid_api:start_instance(chat),
{ok, Sid} = wiregrid_api:connect(chat, <<"alice">>, self()),
Topic = wiregrid_api:topic_channel(<<"general">>),
ok = wiregrid_api:subscribe(chat, Sid, Topic),
{ok, _} = wiregrid_api:publish(chat, Topic, #{type => message}).
```

version and capability discovery is available through `version/0`, `protocol_version/0`, `capabilities/1`, and `describe/1`.

deliveries use the same beam message shape, `{'$wiregrid', EnvelopeMap}`. acknowledge them with `wiregrid_api:ack/3` and the `delivery_id` from the envelope.

prepared fanout and heterogeneous dispatch are available here too. construct destinations with `target_topic/1`, `target_room/1`, `target_user/1`, and `target_session/1`.

new beam-language bindings should normally target this module instead of calling elixir modules directly. the arguments/results are ordinary terms and option-bearing functions have explicit arities.

prepared handles are opaque instance-local values. do not persist them or accept them from a client.

## replay

`wiregrid_api:replay_session/3,4` reads one bounded storage page and sends it to a live session through normal authorization and delivery pressure. the result includes `resume_cursor`, `next_cursor`, `delivered`, `dropped`, and `stopped`.
