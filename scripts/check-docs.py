#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    ROOT / "README.md",
    ROOT / "SECURITY.md",
    ROOT / "CONTRIBUTING.md",
    ROOT / "CHANGELOG.md",
    ROOT / "bindings" / "lfe" / "README.md",
    ROOT / "native" / "c" / "README.md",
    *sorted((ROOT / "docs").glob("*.md")),
]
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
HEADING_RE = re.compile(r"^#{1,6}\s+(.+)$")

errors: list[str] = []

for path in FILES:
    text = path.read_text(encoding="utf-8")
    fence = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.startswith("```"):
            fence = not fence
            continue
        if fence:
            continue

        m = HEADING_RE.match(line)
        if m and any(ch.isupper() for ch in m.group(1) if ch.isascii()):
            errors.append(f"{path.relative_to(ROOT)}:{lineno}: heading should stay lowercase")

        for target in LINK_RE.findall(line):
            target = target.strip().split("#", 1)[0]
            if not target or "://" in target or target.startswith("mailto:"):
                continue
            resolved = (path.parent / target).resolve()
            try:
                resolved.relative_to(ROOT)
            except ValueError:
                errors.append(f"{path.relative_to(ROOT)}:{lineno}: link escapes repository: {target}")
                continue
            if not resolved.exists():
                errors.append(f"{path.relative_to(ROOT)}:{lineno}: missing link target: {target}")

    if fence:
        errors.append(f"{path.relative_to(ROOT)}: unclosed fenced code block")

if errors:
    print("doc-check: failed", file=sys.stderr)
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"doc-check: ok ({len(FILES)} files)")
