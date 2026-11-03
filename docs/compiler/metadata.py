"""Front-matter parsing for markdown posts."""

from __future__ import annotations

import re

FRONT_MATTER_RE = re.compile(
    r"\A---\s*\n(.*?)\n---",
    re.DOTALL,
)

KNOWN_META_KEYS = frozenset({
    "title",
    "page_title",
    "theme",
})

KNOWN_THEMES = frozenset({"dark", "light"})


def split_metadata(text: str) -> tuple[dict[str, str], str]:
    match = FRONT_MATTER_RE.match(text)
    meta: dict[str, str] = {}
    if not match:
        return meta, text

    for raw_line in match.group(1).splitlines():
        line = raw_line.strip()
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip().lower()
        if key not in KNOWN_META_KEYS:
            raise ValueError(
                f"unknown front matter key: {key!r}; "
                f"expected one of {', '.join(sorted(KNOWN_META_KEYS))}"
            )
        meta[key] = value.strip().strip("'\"")

    return meta, text[match.end():]


def require_meta(meta: dict[str, str]) -> None:
    """Fail compile on missing title or bad theme."""
    title = (meta.get("title") or "").strip()
    if not title:
        raise ValueError("missing front matter key: title")

    theme = (meta.get("theme") or "").strip().lower()
    if theme and theme not in KNOWN_THEMES:
        raise ValueError(
            f"invalid theme={theme!r}; expected dark or light"
        )
