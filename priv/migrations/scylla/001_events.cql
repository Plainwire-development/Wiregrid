CREATE KEYSPACE IF NOT EXISTS wiregrid
WITH replication = {'class': 'NetworkTopologyStrategy', 'replication_factor': 3};

CREATE TABLE IF NOT EXISTS wiregrid.wiregrid_events (
  stream blob,
  bucket bigint,
  inserted_at_ms bigint,
  id blob,
  event blob,
  meta blob,
  PRIMARY KEY ((stream, bucket), inserted_at_ms, id)
) WITH CLUSTERING ORDER BY (inserted_at_ms ASC, id ASC);

CREATE TABLE IF NOT EXISTS wiregrid.wiregrid_event_lookup (
  stream blob,
  id blob,
  bucket bigint,
  inserted_at_ms bigint,
  event blob,
  meta blob,
  PRIMARY KEY ((stream, id))
);

CREATE TABLE IF NOT EXISTS wiregrid.wiregrid_stream_buckets (
  stream blob,
  bucket bigint,
  PRIMARY KEY ((stream), bucket)
) WITH CLUSTERING ORDER BY (bucket ASC);
