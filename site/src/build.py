#!/usr/bin/env python3
"""Assemble the static Wiregrid manual from shared chrome and page bodies."""

from __future__ import annotations

import html
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
SITE = HERE.parent
PAGES = HERE / "pages"

NAV = [
    ("index.html", "Front"),
    ("install.html", "Install"),
    ("chat.html", "Chat façade"),
    ("sessions.html", "Sessions and resume"),
    ("publish.html", "Topics, publish, dispatch"),
    ("delivery.html", "Delivery and acknowledgements"),
    ("presence.html", "Presence, rooms, signals"),
    ("storage.html", "Storage"),
    ("configuration.html", "Configuration"),
    ("security.html", "Authorization and security"),
    ("elixir.html", "Elixir API"),
    ("erlang.html", "Erlang API"),
    ("gleam.html", "Gleam"),
    ("lfe.html", "LFE"),
    ("foreign.html", "C ABI and the gateway"),
    ("ui.html", "Browser UI kit"),
    ("cowboy.html", "Cowboy transport"),
    ("operations.html", "Clustering and operations"),
    ("architecture.html", "Architecture"),
]

# Official marks, referenced relatively so file:// and GitHub Pages both work.
# Elixir (white word, for dark grounds): elixir-lang.org/downloads/logos/elixir-light.svg
# Erlang/OTP: erlang.org/assets/img/erlang-logo.svg
# The center coin is the existing Plainwire wire grid, drawn on top so the
# charcoal ring cuts into the two logos.
MARKS = """<span class="marks" role="img" aria-label="Elixir, Erlang/OTP, and Plainwire">
  <span class="logo elixir"><img src="assets/elixir-light.svg" alt="" width="583" height="245"></span>
  <svg class="grid" width="52" height="52" viewBox="26 0 52 52" aria-hidden="true">
    <circle cx="52" cy="26" r="19.5" fill="#24211e"/>
    <circle cx="52" cy="26" r="16.5" fill="#f4efe4"/>
    <circle cx="52" cy="26" r="14.5" fill="#1b3834"/>
    <g stroke="#f0e2b8" stroke-width="1.05" fill="none">
      <path d="M41 20.5 H63 M41 26 H63 M41 31.5 H63"/>
      <path d="M45.5 15 V37 M52 15 V37 M58.5 15 V37"/>
    </g>
  </svg>
  <span class="logo erlang"><img src="assets/erlang-logo.svg" alt="" width="1594" height="1397"></span>
</span>"""


def slug(text: str) -> str:
    text = re.sub(r"<[^>]+>", "", text)
    text = text.strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text or "section"


def outline(body: str) -> tuple[str, str]:
    """Insert heading ids and return (body, toc html)."""
    used: dict[str, int] = {}
    items: list[str] = []

    def repl(match: re.Match[str]) -> str:
        level = match.group(1)
        inner = match.group(2)
        plain = re.sub(r"<[^>]+>", "", inner)
        base = slug(plain)
        n = used.get(base, 0)
        used[base] = n + 1
        ident = base if n == 0 else f"{base}-{n + 1}"
        cls = "h3" if level == "3" else "h2"
        items.append(f'<li><a class="{cls}" href="#{ident}">{html.escape(plain)}</a></li>')
        return f'<h{level} id="{ident}">{inner}</h{level}>'

    body = re.sub(r"<h([23])>(.*?)</h\1>", repl, body, flags=re.S)
    toc = "<ol>" + "".join(items) + "</ol>" if items else "<p>This page is short.</p>"
    return body, toc


def nav_html(current: str) -> str:
    rows = []
    for href, title in NAV:
        current_attr = ' aria-current="page"' if href == current else ""
        rows.append(f'<li><a href="{href}"{current_attr}>{html.escape(title)}</a></li>')
    return "<ol>" + "".join(rows) + "</ol>"


def page_shell(filename: str, title: str, body: str, toc: str) -> str:
    desc = html.escape(title)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{desc} — Wiregrid manual</title>
  <link rel="stylesheet" href="manual.css">
</head>
<body>
  <header class="mast">
    <a class="brand" href="index.html">
      {MARKS}
      <span class="word">
        <span class="name">Wiregrid</span>
        <span class="sub">Plainwire · Manual 1.0</span>
      </span>
    </a>
    <form class="find" role="search" action="index.html">
      <input id="q" type="search" placeholder="Filter pages" autocomplete="off" aria-label="Filter the manual">
    </form>
  </header>
  <hr class="oxblood">
  <div id="results" class="results"></div>
  <div class="frame">
    <nav class="contents" aria-label="Contents">
      <h2>Contents</h2>
      {nav_html(filename)}
    </nav>
    <article class="sheet">
      {body}
    </article>
    <nav class="onthepage" aria-label="On this page">
      <h2>On this page</h2>
      {toc}
    </nav>
  </div>
  <p class="foot">Wiregrid 1.0 · Plainwire · <a href="https://github.com/Plainwire-development/Wiregrid">github.com/Plainwire-development/Wiregrid</a></p>
  <script src="search-index.js"></script>
  <script src="manual.js"></script>
</body>
</html>
"""


def plain_text(fragment: str) -> str:
    text = re.sub(r"<script[\s\S]*?</script>", " ", fragment)
    text = re.sub(r"<style[\s\S]*?</style>", " ", text)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def main() -> None:
    index = []
    for filename, title in NAV:
        source = PAGES / filename
        raw = source.read_text(encoding="utf-8").strip()
        body, toc = outline(raw)
        text = plain_text(raw)
        index.append({"href": filename, "title": title, "text": text[:600]})
        (SITE / filename).write_text(page_shell(filename, title, body, toc), encoding="utf-8")
        print(f"wrote {filename}")

    lines = ["window.WG_SEARCH = ["]
    for item in index:
        lines.append(
            "  {href: "
            + js(item["href"])
            + ", title: "
            + js(item["title"])
            + ", text: "
            + js(item["text"])
            + "},"
        )
    lines.append("];")
    (SITE / "search-index.js").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (SITE / ".nojekyll").write_text("", encoding="utf-8")
    print(f"indexed {len(index)} pages")


def js(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


if __name__ == "__main__":
    main()
