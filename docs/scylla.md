# scylla storage

wiregrid splits long-lived streams into time buckets instead of keeping one permanent partition for every stream. the default bucket width is one day.

three tables are used: bucketed events, an exact `(stream, id)` lookup, and a small per-stream bucket directory.

first-write idempotency is anchored by an lwt lookup record containing the canonical timestamp, bucket, and event. retries can repair the event row and bucket directory from that record without inventing a second canonical copy.

all data queries are bounded and partition-directed. values use prepared statements. the keyspace name is validated separately because cql cannot parameterize identifiers.

the checked-in schema uses keyspace `wiregrid` and a network-topology replication factor of 3. use replication factor 1 only for a disposable one-node dev cluster. production rf has to match the actual node/rack topology.

```elixir
storage: {Wiregrid.Storage.Scylla,
  conn: xandra_pool,
  keyspace: "wiregrid",
  replication_factor: 3,
  bucket_ms: 86_400_000
}
```

`scripts/db-init.sh scylla` applies the same checked-in schema. `SCYLLA_KEYSPACE` and `SCYLLA_REPLICATION_FACTOR` can generate a validated temporary deployment copy without editing the migration file.

changing `bucket_ms` for existing data should be treated as a storage migration, not a live tuning switch.
