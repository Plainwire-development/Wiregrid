# storage

`Wiregrid.Storage` is an append-oriented event-stream interface.

its contract is bootstrap, append, exact get, bounded page, delete, bounded prune, and health.

streams are validated wiregrid topics encoded deterministically. ids are bounded binaries. pagination uses `(inserted_at_ms, id)` as the cursor, which keeps rows with the same timestamp from being skipped or repeated.

memory storage is bounded ets and is idempotent by `(stream, id)`. postgres and scylla are optional durable adapters. redis is intentionally a cache/counter adapter, not durable history.

an app chooses which events are persisted. `publish(..., persist: true)` stores the event after validation/authorization and before local fanout.
