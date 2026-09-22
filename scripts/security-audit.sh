#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
bad() { printf 'SECURITY FAIL: %s\n' "$1" >&2; fail=1; }

if rg -n --glob '!lib/wiregrid/safe_term.ex' 'binary_to_term\s*\(' lib src >/tmp/wg-audit.$$ 2>/dev/null; then
  cat /tmp/wg-audit.$$ >&2
  bad 'untrusted term decoding exists outside Wiregrid.SafeTerm'
fi
rm -f /tmp/wg-audit.$$

if rg -n 'String\.to_atom|binary_to_atom|list_to_atom' lib src; then
  bad 'dynamic atom creation found'
fi

if rg -n 'rescue\s+_\s*->\s*:ok|catch\s+_\s*,\s*_\s*->\s*:ok' lib src; then
  bad 'broad exception swallowing found'
fi

if rg -n --glob '*.ex' --glob '*.exs' --glob '*.erl' --glob '*.lfe' --glob '*.sh' --glob '*.py' --glob '!scripts/security-audit.sh' --glob '!bindings/gleam/build/**' 'TODO|FIXME|HACK|placeholder|example\.invalid' lib src mix.exs scripts bindings; then
  bad 'unfinished marker or fake endpoint found in release code'
fi

if rg -n --glob '!lib/wiregrid/safe_term.ex' ':erlang\.term_to_binary\([^\n]*\[:compressed|compressed:' lib src; then
  bad 'compressed ETF generation found in runtime boundary code'
fi

if rg -n 'authorization|bearer|webhook.*secret|DATABASE_URL' lib | rg -n 'Logger\.|IO\.(inspect|puts)' >/dev/null; then
  bad 'possible sensitive value logging found'
fi

if [[ "$fail" -ne 0 ]]; then exit 1; fi
printf 'Static security policy scan passed.\n'
