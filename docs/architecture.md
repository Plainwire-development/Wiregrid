# architecture

wiregrid keeps lifecycle work and fanout work separate.

`Wiregrid.Runtime` handles changes that need several indexes to move together, like sessions, subscriptions, rooms, presence watches, resume state, and drain state. one runtime process per instance serializes those changes so the ets tables stay consistent.

normal publishing does not go through that process. fanout reads the indexed ets tables directly and walks recipients in bounded batches, which keeps one runtime mailbox from becoming the throughput ceiling for the whole instance.

## the main pieces

`Wiregrid.Tables` owns the per-instance ets tables. `Wiregrid.Runtime` owns cross-table lifecycle changes. `Wiregrid.Delivery` owns reservations, acknowledgements, and slow-consumer behavior. `Wiregrid.Fanout` walks topic, room, and user indexes. `Wiregrid.Expiry` handles ttl work without creating one timer process for every row. `Wiregrid.Storage` and `Wiregrid.Cache` are adapter boundaries. `Wiregrid.Cluster` is optional and stays out of a single-node instance.

instances use `rest_for_one` supervision. losing the table owner rebuilds the runtime against fresh tables. restarting only the runtime can rebuild process monitors without throwing the tables away.

## pressure and acknowledgements

every session has bounded delivery capacity.

ephemeral events are allowed to fall off once a consumer crosses the soft limit. durable events keep their reservation until the consumer acknowledges them and are allowed up to the hard limit. after that, new durable work is rejected instead of growing the mailbox forever.

wiregrid does not call `process_info/2` on every recipient to decide whether it is safe to send. delivery pressure is tracked by wiregrid itself, so cost stays predictable as fanout grows.

replay, websocket delivery, lfe workers, and foreign clients all use the same reservation model. there is not a hidden fast path with different reliability rules.

## persistence

for a normal publish the order is roughly:

1. validate the topic, event, and options
2. authorize the acting session if there is one
3. encode the event once
4. persist it if requested
5. fan it out locally
6. forward it to the cluster if clustering is on

`Wiregrid.Chat.say/4` enables persistence for normal chat messages. the lower level `Wiregrid.publish/4` leaves persistence up to the caller.

single-user delivery can also carry an event id, metadata, and `persist: true`. persisted direct events use `{:user, user_id}` as the stream.

## adapters

storage and cache adapters run inline by default because that is the cheapest path for a local adapter you trust.

`adapter_mode: :isolated` puts calls behind supervised tasks with a per-instance pending limit and deadline. when the budget is full, the call returns `{:error, :adapter_overloaded}` instead of creating another process and hoping the machine survives it. timeouts, failures, and rejections are included in health and metrics.

## prepared fanout

`Wiregrid.prepare/2` validates and encodes an event once. prepared publish/send calls can reuse those bytes across multiple destinations.

prepared handles are signed for the instance that created them. treat them as an in-process optimization only. they are not credentials and should never be accepted from an untrusted client.

## why there is so much lfe

lfe sits on top of the same runtime, it does not own a second set of sessions or routing tables.

there is a fairly big lfe stack because the work was split by behavior instead of shoved into one binding file. fixed-route macros, mailbox collection, ordered lanes, coalescing, decode-late kernels, folds, and worker loops all have different rules about ordering, acknowledgement, and failure. keeping those pieces separate makes the hot paths easier to audit and lets an app use one part without pulling every other pattern into the same worker.

lfe is useful here because actor loops and pattern matching are the language, not an awkward library bolted on top, and its macros are good at generating boring fixed routing code at compile time. the correctness-sensitive state still belongs to the normal wiregrid runtime, so installing lfe does not create another source of truth.

wiregrid works without lfe.

## clients outside the beam

`Wiregrid.Foreign.Gateway` owns ordinary wiregrid sessions for c and other non-beam clients. the wire format is small, versioned, and bounded. foreign processes do not receive ets table ids, pids, erlang external terms, or other vm internals.

read `foreign-clients.md` for the actual protocol boundary.
