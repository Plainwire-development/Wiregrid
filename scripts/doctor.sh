#!/usr/bin/env bash
set -euo pipefail

required=(erl erlc elixir mix)
optional=(docker podman psql redis-cli cqlsh gleam lfe shellcheck)
fail=0

printf 'Wiregrid toolchain check\n'
for cmd in "${required[@]}"; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf 'ok   %-12s %s\n' "$cmd" "$(command -v "$cmd")"
  else
    printf 'MISS %-12s required\n' "$cmd"
    fail=1
  fi
done

for cmd in "${optional[@]}"; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf 'opt  %-12s %s\n' "$cmd" "$(command -v "$cmd")"
  fi
done

if command -v elixir >/dev/null 2>&1; then elixir --version; fi
if command -v mix >/dev/null 2>&1; then mix --version; fi

if [[ "$fail" -ne 0 ]]; then
  printf '\nInstall Erlang/OTP and Elixir (>= 1.17) before building Wiregrid.\n' >&2
fi
exit "$fail"
