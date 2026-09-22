#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./scripts/doctor.sh
mix local.hex --force
mix local.rebar --force
mix deps.get
printf 'Wiregrid development dependencies are ready.\n'
