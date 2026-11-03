"""CSS style attribute helpers shared by layout polish."""

from __future__ import annotations

import re

# Markdown img width= must be a positive length with an explicit unit.
IMG_WIDTH_RE = re.compile(
    r"^(\d+(?:\.\d+)?)(%|px|em|rem)$",
    re.IGNORECASE,
)


def parse_style_decl(style: str) -> dict[str, str]:
    """Split a CSS style attribute into a name → value map."""
    out: dict[str, str] = {}
    for part in style.split(";"):
        part = part.strip()
        if not part or ":" not in part:
            continue
        name, value = part.split(":", 1)
        out[name.strip().lower()] = value.strip()
    return out


def style_from_decl(decls: dict[str, str]) -> str:
    return "; ".join(f"{k}: {v}" for k, v in decls.items()) + (";" if decls else "")


def normalize_length(raw: object, what: str = "width") -> str:
    """Require a positive CSS length: N%, Npx, Nem, or Nrem.

    Percent becomes a fraction of CSS --measure (em-based in template.css)
    so figures track font zoom: 30% → calc(var(--measure) * 30 / 100).
    """
    value = str(raw).strip()
    if not value:
        raise ValueError(f"invalid {what}; empty value")
    match = IMG_WIDTH_RE.fullmatch(value)
    if match is None:
        raise ValueError(
            f"invalid {what}={value!r}; "
            "expected a positive number with unit %, px, em, or rem"
        )
    number = match.group(1)
    if float(number) <= 0:
        raise ValueError(
            f"invalid {what}={value!r}; must be positive"
        )
    unit = match.group(2).lower()
    if unit == "%":
        # Measure lives in CSS (--measure); no em constant here.
        return f"calc(var(--measure) * {number} / 100)"
    return f"{number}{unit}"
