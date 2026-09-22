# elixir api

`Wiregrid` is the main low level api. applications should use it instead of reaching into wiregrid ets tables or internal processes.

for a normal chat app, `Wiregrid.Chat` is usually easier. it still calls this same api underneath.

## finding out what is running

these calls are safe compatibility checks:

- `Wiregrid.version/0`
- `Wiregrid.protocol_version/0`
- `Wiregrid.capabilities/1`
- `Wiregrid.describe/1`

use them when a plugin, transport, or admin tool needs to feature-detect an instance without reading internal state.

## the main groups

lifecycle is `start_instance`, `connect`, resumable connect/resume, and disconnect.

routing is subscribe/unsubscribe, publish, prepared publish, room/topic fanout, direct user/session sends, and heterogeneous dispatch.

pressure is acknowledgements and pending-delivery inspection.

presence, rooms, transient activity, receipts, signaling, storage/cache access, health, draining, and shutdown all live on the same public facade.

operations that can fail use tagged tuples. ids, tokens, prepared handles, and cursors should be treated as opaque values.

## prepared fanout

`Wiregrid.prepare/2` validates and encodes an event once. prepared publish/send functions reuse that encoded body across a bounded destination set.

`dispatch/4` and `dispatch_prepared/4` can target a mix of topics, rooms, users, and sessions. the whole target set is bounded and deduplicated first, but execution is not a transaction. each target group reports its own result so the caller can decide what a partial failure means.

prepared handles are signed for one instance and are only meant for trusted in-process code. do not serialize them to clients.

## inspection

`Wiregrid.Query` exposes bounded summaries without returning owner pids, monitor refs, resume-token hashes, adapter secrets, or ets identifiers.

`read_history/5` pages a durable stream after a `:read` authorization check for that session. `page_events/4` is the in-process call for code that already decided the caller is allowed to read.

use `session_state`, `topic_info`, `room_info`, `user_info`, and the count helpers for admin/debug tooling instead of reading internal tables.

## rate limits tied to a session

`Wiregrid.Actor.rate_limit/5` adds the actor session id to the limiter key. this is useful for application operations that should be bound to the same authenticated session as the rest of the actor api.

for hot consumers, `Wiregrid.Consumer.Worker` supports a bounded `collect_wait_ms` micro-batch window from 0 to 50 ms. it only collects up to the configured burst and never turns the mailbox into an unbounded app queue.
