#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
./scripts/check-bindings.py

if command -v gleam >/dev/null 2>&1; then
  (cd bindings/gleam && gleam check)
elif [[ "${WIREGRID_REQUIRE_GLEAM:-0}" == "1" ]]; then
  printf 'Gleam compiler is required but gleam is not installed.\n' >&2
  exit 1
else
  printf 'SKIP Gleam compiler not installed. Set WIREGRID_REQUIRE_GLEAM=1 to make this fatal.\n'
  exit 0
fi
