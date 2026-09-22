#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
./scripts/check-bindings.py

OUT="${WIREGRID_LFE_OUT:-$ROOT/_build/lfe_bindings}"
mkdir -p "$OUT"

# Compile the macro package first, then every shipped LFE module. Keeping this
# list dynamic prevents a new high-throughput helper from silently escaping CI.
mapfile -t ALL_LFE < <(find bindings/lfe -maxdepth 1 -type f -name '*.lfe' -print | LC_ALL=C sort)
FILES=(bindings/lfe/wiregrid_macros.lfe)
for file in "${ALL_LFE[@]}"; do
  [[ "$file" == "bindings/lfe/wiregrid_macros.lfe" ]] || FILES+=("$file")
done

if command -v lfec >/dev/null 2>&1; then
  for file in "${FILES[@]}"; do
    lfec -o "$OUT" "$file"
  done
elif command -v lfe >/dev/null 2>&1; then
  for file in "${FILES[@]}"; do
    lfe -noshell -eval "(progn (c \"$file\" (list (tuple 'outdir \"$OUT\"))) (halt))"
  done
elif [[ "${WIREGRID_REQUIRE_LFE:-0}" == "1" ]]; then
  printf 'LFE compiler is required but neither lfec nor lfe is installed.\n' >&2
  exit 1
else
  printf 'SKIP LFE compiler not installed. Set WIREGRID_REQUIRE_LFE=1 to make this fatal.\n'
  exit 0
fi

printf 'LFE binding compilation passed (%s modules).\n' "${#FILES[@]}"
