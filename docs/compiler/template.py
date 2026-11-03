"""HTML template load and {{ placeholder }} fill."""

from __future__ import annotations

import re
from pathlib import Path

HERE = Path(__file__).resolve().parent

TEMPLATE_HTML = (HERE / "template.html").read_text(encoding="utf-8")
TEMPLATE_CSS = (HERE / "template.css").read_text(encoding="utf-8")

PLACEHOLDER_RE = re.compile(r"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}")


def fill_template(template: str, values: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in values:
            raise KeyError(f"unknown template placeholder: {key}")
        return values[key]

    # Tiny {{ name }} slots in template.html — not HTML structure.
    return PLACEHOLDER_RE.sub(replace, template)
