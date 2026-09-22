#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./scripts/doctor.sh
./scripts/check-source-links.py
./scripts/check-bindings.py
./scripts/check-foreign.py
./scripts/check-docs.py
mix format --check-formatted
mix deps.unlock --check-unused
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test

mkdir -p _build/manual_erlang
ERL_ROOT="$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')"
erlc -Werror -I "$ERL_ROOT/usr/include" -o _build/manual_erlang src/*.erl

./scripts/security-audit.sh

./scripts/check-gleam.sh
./scripts/check-lfe.sh
make -C native/c test
for f in priv/ui/wiregrid.js priv/ui/wiregrid.esm.js priv/ui/js/*.js; do node --check "$f"; done

printf 'Wiregrid verification gates passed.\n'
