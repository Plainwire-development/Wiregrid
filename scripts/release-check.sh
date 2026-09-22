#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./scripts/verify.sh
USERS=100 SESSIONS_PER_USER=1 TOPICS=10 MESSAGES=1000 MESSAGES_PER_SEC=0 \
  ACK_DELAY_MS=0 SLOW_PERCENT=0 RECONNECT_PERCENT=5 ./scripts/load.sh
printf 'Wiregrid release check passed.\n'
