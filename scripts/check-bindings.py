#!/usr/bin/env python3
"""Static ABI consistency checks usable even without BEAM/Gleam/LFE compilers."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ERL = ROOT / "src" / "wiregrid_api.erl"
GLEAM = ROOT / "bindings" / "gleam" / "src" / "wiregrid.gleam"
LFE_DIR = ROOT / "bindings" / "lfe"
ELIXIR = ROOT / "lib" / "wiregrid.ex"


def fail(message: str) -> None:
    print(f"binding-check: {message}", file=sys.stderr)
    raise SystemExit(1)


def erlang_exports(text: str) -> set[tuple[str, int]]:
    match = re.search(r"-export\(\[(.*?)\]\)\.", text, re.S)
    if not match:
        fail("wiregrid_api.erl has no export block")
    exports: set[tuple[str, int]] = set()
    for name, arity in re.findall(r"('?[^',\s/]+'?|[a-zA-Z0-9_?]+)\s*/\s*(\d+)", match.group(1)):
        exports.add((name.strip("'"), int(arity)))
    return exports


def erlang_definitions(text: str) -> set[tuple[str, int]]:
    definitions: set[tuple[str, int]] = set()
    pattern = re.compile(
        r"^(?P<name>[a-z][a-zA-Z0-9_]*|'[^']+')\s*\((?P<args>[^\n]*)\)\s*(?:when\s+[^\n]+)?->",
        re.M,
    )
    for match in pattern.finditer(text):
        name = match.group("name").strip("'")
        args = match.group("args").strip()
        arity = 0 if not args else top_level_arity(args)
        definitions.add((name, arity))
    return definitions


def top_level_arity(args: str) -> int:
    depth = 0
    in_string = False
    escaped = False
    commas = 0
    for char in args:
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            commas += 1
    return commas + 1




def gleam_external_pairs(text: str, module_name: str) -> set[tuple[str, int]]:
    """Parse Gleam externals with balanced parameter parentheses.

    A regex that stops at `) ->` breaks as soon as an external takes more than
    one function-typed argument because nested `fn(...) -> ...` signatures
    contain the same token sequence. This small scanner keeps the offline ABI
    check correct for higher-order bindings.
    """
    marker = f'@external(erlang, "{module_name}", "'
    pairs: set[tuple[str, int]] = set()
    pos = 0

    while True:
        start = text.find(marker, pos)
        if start < 0:
            break
        fn_name_start = start + len(marker)
        fn_name_end = text.find('"', fn_name_start)
        if fn_name_end < 0:
            fail(f"unterminated Gleam external near offset {start}")
        external_name = text[fn_name_start:fn_name_end]

        fn_kw = text.find('fn ', fn_name_end)
        if fn_kw < 0:
            fail(f"Gleam external {external_name} has no function declaration")
        open_paren = text.find('(', fn_kw)
        if open_paren < 0:
            fail(f"Gleam external {external_name} has no argument list")

        depth = 1
        i = open_paren + 1
        in_string = False
        escaped = False
        while i < len(text) and depth > 0:
            ch = text[i]
            if in_string:
                if escaped:
                    escaped = False
                elif ch == '\\':
                    escaped = True
                elif ch == '"':
                    in_string = False
            else:
                if ch == '"':
                    in_string = True
                elif ch == '(':
                    depth += 1
                elif ch == ')':
                    depth -= 1
            i += 1

        if depth != 0:
            fail(f"Gleam external {external_name} has unbalanced argument parentheses")

        args = text[open_paren + 1:i - 1].strip()
        # Gleam allows a trailing comma in multiline function signatures; it
        # does not represent an extra argument.
        if args.endswith(','):
            args = args[:-1].rstrip()
        pairs.add((external_name, 0 if not args else top_level_arity(args)))
        pos = i

    return pairs

def check_lfe_balance(path: Path) -> None:
    depth = 0
    in_string = False
    escaped = False
    for line_no, raw in enumerate(path.read_text().splitlines(), 1):
        # LFE comments in this tree use `;;`; none are embedded in string literals.
        line = raw.split(";", 1)[0] if not in_string else raw
        for char in line:
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
            else:
                if char == '"':
                    in_string = True
                elif char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth < 0:
                        fail(f"{path.relative_to(ROOT)}:{line_no}: extra closing parenthesis")
    if depth != 0 or in_string:
        fail(f"{path.relative_to(ROOT)}: unbalanced LFE source (depth={depth}, string={in_string})")


erl_text = ERL.read_text()
exports = erlang_exports(erl_text)
definitions = erlang_definitions(erl_text)
missing_defs = sorted(exports - definitions)
if missing_defs:
    fail(f"wiregrid_api exports without matching definition: {missing_defs}")

export_names = {name for name, _arity in exports}

lfe_paths = sorted(LFE_DIR.glob("*.lfe"))
lfe_defs: dict[str, set[str]] = {}
for path in lfe_paths:
    check_lfe_balance(path)
    text = path.read_text()
    module_match = re.search(r"\(defmodule\s+([a-zA-Z0-9_-]+)", text)
    if not module_match:
        fail(f"{path.relative_to(ROOT)} has no defmodule")
    module = module_match.group(1)
    lfe_defs[module] = set(re.findall(r"\(defun\s+([a-zA-Z0-9_?+-]+)\s*\(", text))

    calls = set(re.findall(r"wiregrid_api:([a-zA-Z0-9_?]+)", text))
    unknown = sorted(calls - export_names)
    if unknown:
        fail(f"{path.relative_to(ROOT)} calls unknown wiregrid_api functions: {unknown}")

# Cross-check local LFE module calls as well. LFE accepts both module:function
# and (: module function ...) syntax; this catches misspellings offline without
# pretending to replace the real LFE compiler.
for path in lfe_paths:
    text = path.read_text()
    calls: set[tuple[str, str]] = set()
    calls.update(re.findall(r"\b(wiregrid_[a-zA-Z0-9_-]+):([a-zA-Z0-9_?+-]+)", text))
    calls.update(re.findall(r"\(:\s+(wiregrid_[a-zA-Z0-9_-]+)\s+([a-zA-Z0-9_?+-]+)", text))
    for module, function in sorted(calls):
        if module == "wiregrid_api":
            continue
        if module not in lfe_defs:
            fail(f"{path.relative_to(ROOT)} references missing local LFE module {module}")
        if function not in lfe_defs[module]:
            fail(f"{path.relative_to(ROOT)} calls missing {module}:{function}")

required_lfe = {
    "wiregrid",
    "wiregrid_worker",
    "wiregrid_selector",
    "wiregrid_fold",
    "wiregrid_fast",
    "wiregrid_macros",
    "wiregrid_router",
    "wiregrid_pipeline",
    "wiregrid_stream",
    "wiregrid_plan",
    "wiregrid_actor",
    "wiregrid_mailbox",
    "wiregrid_kernel",
    "wiregrid_batch_worker",
    "wiregrid_policy",
    "wiregrid_projection",
    "wiregrid_transport",
    "wiregrid_lane",
    "wiregrid_coalesce",
}
missing_lfe = sorted(required_lfe - set(lfe_defs))
if missing_lfe:
    fail(f"required LFE modules are missing: {missing_lfe}")


# Macro definitions are single-clause in Wiregrid's macro package. Accidentally
# redefining the same macro name/arity is especially dangerous because caller
# behavior can then depend on compiler/order details. Parse signatures across
# line breaks because the larger generated worker macros intentionally wrap.
macro_defs: dict[tuple[str, int], list[int]] = {}
macro_path = LFE_DIR / "wiregrid_macros.lfe"
macro_text = macro_path.read_text()
macro_sig_re = re.compile(r"\(defmacro\s+([a-zA-Z0-9_?+-]+)\s+\(([^)]*)\)", re.S)
for match in macro_sig_re.finditer(macro_text):
    name, args = match.groups()
    arity = 0 if not args.strip() else len(args.split())
    line_no = macro_text.count("\n", 0, match.start()) + 1
    macro_defs.setdefault((name, arity), []).append(line_no)

duplicate_macros = {key: lines for key, lines in macro_defs.items() if len(lines) > 1}
if duplicate_macros:
    fail(f"duplicate LFE macro definitions: {duplicate_macros}")

# Keep the exported macro surface honest. A typo in export-macro is otherwise
# only discovered on machines that happen to have LFE installed.
export_match = re.search(r"\(export-macro\s+(.*?)\)\)", macro_text, re.S)
if not export_match:
    fail("wiregrid_macros.lfe has no export-macro declaration")
exported_macro_names = set(re.findall(r"[a-zA-Z][a-zA-Z0-9_?+-]*", export_match.group(1)))
defined_macro_names = {name for name, _arity in macro_defs}
missing_macro_defs = sorted(exported_macro_names - defined_macro_names)
if missing_macro_defs:
    fail(f"exported LFE macros without definitions: {missing_macro_defs}")
unexported_macros = sorted(defined_macro_names - exported_macro_names)
if unexported_macros:
    fail(f"defined LFE macros not exported: {unexported_macros}")

# `wiregrid.lfe` is the complete ordinary LFE facade. Macro/fast modules are
# optional accelerators; users should not have to bypass the facade for ABI
# operations or constructors.
lfe_facade_text = (LFE_DIR / "wiregrid.lfe").read_text()
lfe_facade_calls = set(re.findall(r"wiregrid_api:([a-zA-Z0-9_?]+)", lfe_facade_text))
missing_lfe_abi = sorted(export_names - lfe_facade_calls)
if missing_lfe_abi:
    fail(f"LFE facade does not cover ABI names: {missing_lfe_abi}")

gleam_text = GLEAM.read_text()
gleam_calls = {
    function
    for module, function in re.findall(r'@external\(erlang, "([^"]+)", "([^"]+)"\)', gleam_text)
    if module == "wiregrid_api"
}
unknown_gleam = sorted(gleam_calls - export_names)
if unknown_gleam:
    fail(f"Gleam binding references unknown wiregrid_api functions: {unknown_gleam}")

# Check the closed Gleam helper FFI too. This catches typed-wrapper drift even
# when Gleam/BEAM compilers are unavailable in the current environment.
GLEAM_FFI = ROOT / "src" / "wiregrid_gleam_ffi.erl"
gleam_ffi_text = GLEAM_FFI.read_text()
gleam_ffi_exports = erlang_exports(gleam_ffi_text)
gleam_ffi_defs = erlang_definitions(gleam_ffi_text)
missing_ffi_defs = sorted(gleam_ffi_exports - gleam_ffi_defs)
if missing_ffi_defs:
    fail(f"wiregrid_gleam_ffi exports without definitions: {missing_ffi_defs}")
helper_pairs = gleam_external_pairs(gleam_text, "wiregrid_gleam_ffi")
unknown_helper_pairs = sorted(helper_pairs - gleam_ffi_exports)
if unknown_helper_pairs:
    fail(f"Gleam helper externals reference unavailable FFI arities: {unknown_helper_pairs}")

# Compare external declaration arities too. This is intentionally limited to
# the plain wiregrid_api boundary; helper FFI modules have their own Erlang
# compiler gate in real CI.
gleam_pairs = gleam_external_pairs(gleam_text, "wiregrid_api")
missing_export_arities = sorted(gleam_pairs - exports)
if missing_export_arities:
    fail(f"Gleam externals reference unavailable wiregrid_api arities: {missing_export_arities}")

# Gleam wraps every operational ABI name. `signal_kind/1` is intentionally not
# surfaced because the closed `Signal` type converts to the exact atom without
# exposing a dynamic constructor.
allowed_gleam_gaps = {"signal_kind"}
unexpected_gleam_gaps = sorted(export_names - gleam_calls - allowed_gleam_gaps)
if unexpected_gleam_gaps:
    fail(f"Gleam binding is missing operational ABI names: {unexpected_gleam_gaps}")

# Sanity-check that every direct Elixir.Wiregrid call from the Erlang ABI names a
# function present in the canonical facade. Arity is compiler-checked in CI;
# this static pass catches typos when BEAM tooling is unavailable.
# Accept both parenthesized definitions (`def foo(x)`) and idiomatic
# zero-arity one-liners (`def version, do: ...`).  The compiler remains the
# authority on arity in CI; this offline checker only guards against misspelled
# canonical function names when BEAM tooling is unavailable.
elixir_names = set(
    re.findall(
        r"^\s*def\s+([a-zA-Z0-9_?!]+)(?=\s*(?:\(|,|\bdo\b))",
        ELIXIR.read_text(),
        re.M,
    )
)
abi_elixir_names = set(re.findall(r"'Elixir\.Wiregrid':('?[^'(]+'?|[a-zA-Z0-9_?!]+)\(", erl_text))
abi_elixir_names = {name.strip("'") for name in abi_elixir_names}
unknown_elixir = sorted(abi_elixir_names - elixir_names)
if unknown_elixir:
    fail(f"wiregrid_api calls missing canonical Wiregrid functions: {unknown_elixir}")

# Stronger offline arity check for direct calls into the canonical Wiregrid
# facade. This intentionally handles the simple public function signatures in
# wiregrid.ex, including trailing default arguments. Real compilation remains
# authoritative for complex pattern heads.
elixir_text = ELIXIR.read_text()
canonical_callable_arities: set[tuple[str, int]] = set()
def_re = re.compile(r"^\s*def\s+([a-zA-Z0-9_?!]+)\s*\((.*?)\)(?=\s*(?:,\s*do:|\s+do\b|$))", re.M | re.S)
for name, args in def_re.findall(elixir_text):
    max_arity = 0 if not args.strip() else top_level_arity(args.strip())
    # Wiregrid public defaults are trailing. Count top-level `\\` markers to
    # derive the additionally callable lower arities generated by Elixir.
    depth = 0
    defaults = 0
    i = 0
    while i < len(args) - 1:
        ch = args[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "\\" and args[i + 1] == "\\" and depth == 0:
            defaults += 1
            i += 1
        i += 1
    for arity in range(max_arity - defaults, max_arity + 1):
        canonical_callable_arities.add((name, arity))

abi_calls: set[tuple[str, int]] = set()
abi_call_re = re.compile(r"'Elixir\.Wiregrid':('?[^'(]+'?|[a-zA-Z0-9_?!]+)\((.*?)\)", re.S)
for name, args in abi_call_re.findall(erl_text):
    abi_calls.add((name.strip("'"), 0 if not args.strip() else top_level_arity(args.strip())))
missing_elixir_arities = sorted(abi_calls - canonical_callable_arities)
if missing_elixir_arities:
    fail(f"wiregrid_api calls unavailable canonical Wiregrid arities: {missing_elixir_arities}")

print(
    "binding-check: ok "
    f"({len(exports)} Erlang ABI exports, {len(gleam_calls)} Gleam externals, "
    f"{len(list(LFE_DIR.glob('*.lfe')))} LFE modules)"
)
