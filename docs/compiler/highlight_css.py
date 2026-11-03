"""Build dual-theme Pygments token CSS for fenced code blocks."""

from __future__ import annotations

import re

from pygments.formatters import HtmlFormatter

CSS_CLASS = "codehilite"
LIGHT_STYLE = "default"
DARK_STYLE = "monokai"

# Global layout rules from Pygments; page template owns pre background.
SKIP_PREFIXES = (
    "pre {",
    "td.linenos",
    "span.linenos",
)
WRAPPER_RE = re.compile(rf"\.{re.escape(CSS_CLASS)}\s*\{{")


def token_rules(style: str) -> list[str]:
    raw = HtmlFormatter(style=style).get_style_defs(f".{CSS_CLASS}")
    out: list[str] = []
    for line in raw.splitlines():
        s = line.strip()
        if not s:
            continue
        if any(s.startswith(p) for p in SKIP_PREFIXES):
            continue
        if WRAPPER_RE.match(s):
            continue
        out.append(s)
    return out


def build_highlight_css() -> str:
    """Light token colors, plus dark overrides under the theme toggle."""
    light = token_rules(LIGHT_STYLE)
    dark = token_rules(DARK_STYLE)
    lines = [
        "/* Pygments token colors (compile-time; light defaults). */",
        *light,
        "/* Dark theme token colors (same classes, toggle-scoped). */",
    ]
    for rule in dark:
        lines.append(f"body:has(#theme-toggle:checked) {rule}")
    return "\n".join(lines) + "\n"
