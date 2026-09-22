# postgres storage

pass a caller-owned postgrex-compatible connection or pool:

```elixir
storage: {Wiregrid.Storage.Postgres, conn: pool}
```

`bootstrap/1` runs idempotent schema statements inside one transaction and uses a transaction-scoped postgres advisory lock.

writes are parameterized and idempotent by `(stream, id)`. pages use `(inserted_at_ms, id)` ordering. retention deletes are bounded.

schema sql is in `priv/migrations/postgres/001_events.sql`.

```sh
DATABASE_URL=... ./scripts/db-init.sh postgres
```

wiregrid does not own the pool. pool size, tls, credentials, failover, backups, monitoring, and retention policy stay with the application/operator.
