#!/usr/bin/env python3
"""Cheap cross-module/source sanity checks for environments without Elixir.

This is deliberately conservative and is not a parser or a replacement for
`mix compile --warnings-as-errors`. It catches common release blockers early:
unknown Wiregrid module/function names and malformed single-backslash default
arguments introduced by generated/automated edits.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = sorted((ROOT / "lib").rglob("*.ex"))
SCAN_FILES = sorted(set(FILES + list((ROOT / "test").rglob("*.exs")) + list((ROOT / "test").rglob("*.ex")) + list((ROOT / "config").rglob("*.exs")) + [ROOT / "mix.exs"]))

MODULE_RE = re.compile(r"^defmodule\s+(Wiregrid(?:\.[A-Z][A-Za-z0-9_]*)*)\s+do\b", re.M)
PUBLIC_DEF_RE = re.compile(r"^\s*def\s+([a-zA-Z0-9_?!]+)(?:\s*\(|\s*,|\s+do(?=\s|:))", re.M)
CALL_RE = re.compile(r"\b(Wiregrid(?:\.[A-Z][A-Za-z0-9_]*)+)\.([a-zA-Z0-9_?!]+)\s*\(")
SINGLE_DEFAULT_RE = re.compile(r"(?<!\\)\\(?!\\)\s+(?:nil|\[\]|%\{\}|:[a-zA-Z_]|[0-9])")
QUALIFIED_DEF_RE = re.compile(r"^\s*defp?\s+[A-Z][A-Za-z0-9_.]*\.[a-zA-Z0-9_?!]+\s*\(")
LEGACY_AUTHORIZER_RE = re.compile(r"Wiregrid\.Authorizer\.check\(\s*cfg\.authorizer")
INLINE_HEREDOC_RE = re.compile(r'"""[^"\n]+"""')

modules: dict[str, tuple[Path, set[str]]] = {}
for path in FILES:
    text = path.read_text()
    match = MODULE_RE.search(text)
    if match:
        modules[match.group(1)] = (path, set(PUBLIC_DEF_RE.findall(text)))

errors: list[str] = []
for path in SCAN_FILES:
    text = path.read_text()
    for line_no, line in enumerate(text.splitlines(), 1):
        if SINGLE_DEFAULT_RE.search(line):
            errors.append(f"{path.relative_to(ROOT)}:{line_no}: suspicious single-backslash default argument")
        if QUALIFIED_DEF_RE.search(line):
            errors.append(f"{path.relative_to(ROOT)}:{line_no}: qualified function name after def/defp")
        if INLINE_HEREDOC_RE.search(line):
            errors.append(f"{path.relative_to(ROOT)}:{line_no}: one-line triple-quoted heredoc is parser-risky")

    if LEGACY_AUTHORIZER_RE.search(text):
        errors.append(f"{path.relative_to(ROOT)}: uses legacy Authorizer.check(cfg.authorizer, ...) boundary")

    # Type attributes may span several physical lines. A line-oriented filter
    # only removes the first `@spec` line and can misclassify a continuation
    # such as `{:ok, Wiregrid.Actor.t()}` as a runtime call. Skip the complete
    # attribute expression until the next definition/module attribute. This is
    # intentionally a conservative source check, not an Elixir parser.
    runtime_lines: list[str] = []
    skipping_type_attr = False
    type_attrs = ("@spec ", "@type ", "@typep ", "@callback ", "@macrocallback ")

    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith(type_attrs):
            skipping_type_attr = True
            continue

        if skipping_type_attr:
            if stripped.startswith(("def ", "defp ", "defmacro ", "defmacrop ", "@")):
                skipping_type_attr = False
            else:
                continue

        if not skipping_type_attr:
            runtime_lines.append(line)

    runtime_text = "\n".join(runtime_lines)

    for module, function in CALL_RE.findall(runtime_text):
        target = modules.get(module)
        if target is None:
            # Some optional modules may come from dependencies; only police
            # modules that are visibly part of the Wiregrid source namespace.
            continue
        if function not in target[1]:
            errors.append(
                f"{path.relative_to(ROOT)}: calls {module}.{function}/? but no public def with that name exists in {target[0].relative_to(ROOT)}"
            )

if errors:
    for error in sorted(set(errors)):
        print(f"source-link-check: {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"source-link-check: ok ({len(modules)} Wiregrid modules, {len(FILES)} Elixir files)")
