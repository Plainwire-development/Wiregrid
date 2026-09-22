#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

target="${1:-all}"

postgres() {
  : "${DATABASE_URL:?DATABASE_URL is required for PostgreSQL initialization}"
  command -v psql >/dev/null 2>&1 || { echo 'psql is required' >&2; return 1; }
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f priv/migrations/postgres/001_events.sql
}

scylla() {
  command -v cqlsh >/dev/null 2>&1 || { echo 'cqlsh is required' >&2; return 1; }

  local host="${SCYLLA_HOST:-127.0.0.1}"
  local port="${SCYLLA_PORT:-9042}"
  local keyspace="${SCYLLA_KEYSPACE:-wiregrid}"
  local replication_factor="${SCYLLA_REPLICATION_FACTOR:-3}"
  local migration tmp status

  if [[ ! "$keyspace" =~ ^[A-Za-z_][A-Za-z0-9_]{0,47}$ ]]; then
    echo 'SCYLLA_KEYSPACE must be a CQL identifier up to 48 characters' >&2
    return 2
  fi

  if [[ ! "$replication_factor" =~ ^[0-9]+$ ]] ||
     (( replication_factor < 1 || replication_factor > 16 )); then
    echo 'SCYLLA_REPLICATION_FACTOR must be an integer from 1 through 16' >&2
    return 2
  fi

  migration="priv/migrations/scylla/001_events.cql"
  tmp="$(mktemp "${TMPDIR:-/tmp}/wiregrid-scylla.XXXXXX.cql")"

  # The checked-in migration intentionally documents the production-oriented
  # defaults. Generate a validated deployment copy so a one-node development
  # cluster can select RF=1 without maintaining a second drifting schema file.
  sed \
    -e "s/CREATE KEYSPACE IF NOT EXISTS wiregrid /CREATE KEYSPACE IF NOT EXISTS ${keyspace} /" \
    -e "s/'replication_factor': 3/'replication_factor': ${replication_factor}/" \
    -e "s/wiregrid\\./${keyspace}./g" \
    "$migration" >"$tmp"

  status=0
  cqlsh "$host" "$port" -f "$tmp" || status=$?
  rm -f "$tmp"
  return "$status"
}

case "$target" in
  postgres) postgres ;;
  scylla) scylla ;;
  all) postgres; scylla ;;
  *) echo 'usage: scripts/db-init.sh [postgres|scylla|all]' >&2; exit 2 ;;
esac
