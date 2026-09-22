#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export USERS="${USERS:-1000}"
export SESSIONS_PER_USER="${SESSIONS_PER_USER:-1}"
export TOPICS="${TOPICS:-100}"
export SUBSCRIPTIONS_PER_SESSION="${SUBSCRIPTIONS_PER_SESSION:-1}"
export MESSAGES="${MESSAGES:-10000}"
export MESSAGES_PER_SEC="${MESSAGES_PER_SEC:-0}"
export DURATION_S="${DURATION_S:-0}"
export ACK_DELAY_MS="${ACK_DELAY_MS:-0}"
export SLOW_PERCENT="${SLOW_PERCENT:-0}"
export RECONNECT_PERCENT="${RECONNECT_PERCENT:-0}"
export ROOM_CHURN_PERCENT="${ROOM_CHURN_PERCENT:-5}"

export MIX_ENV=test
exec mix run scripts/load.exs
