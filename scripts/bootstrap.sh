#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./scripts/setup-dev.sh
mix compile --warnings-as-errors
printf 'Wiregrid compiled successfully.\n'
