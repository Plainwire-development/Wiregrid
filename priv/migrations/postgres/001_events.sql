CREATE TABLE IF NOT EXISTS wiregrid_events (
  stream BYTEA NOT NULL,
  id BYTEA NOT NULL,
  event BYTEA NOT NULL,
  meta BYTEA NOT NULL,
  inserted_at_ms BIGINT NOT NULL,
  PRIMARY KEY (stream, inserted_at_ms, id),
  UNIQUE (stream, id)
);

CREATE INDEX IF NOT EXISTS wiregrid_events_retention_idx
  ON wiregrid_events (stream, inserted_at_ms);
