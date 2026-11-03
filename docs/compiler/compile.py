"""Compile a markdown post into a DJB-style static HTML page."""

from __future__ import annotations

import html as libhtml
import os
import re
from pathlib import Path

from converter import convert
from format_html import prettify_html
from metadata import require_meta, split_metadata
from template import TEMPLATE_CSS, TEMPLATE_HTML, fill_template

# ${domain} / ${DOMAIN} in markdown → apex domain from env / .env
DOMAIN_PLACEHOLDER_RE = re.compile(r"\$\{domain\}", re.IGNORECASE)


def resolve_domain(explicit: str | None = None) -> str:
    """DOMAIN from arg, environment, or repo-root .env (default example.com)."""
    if explicit and explicit.strip():
        return explicit.strip()
    env_val = (os.environ.get("DOMAIN") or "").strip()
    if env_val:
        return env_val
    # Walk up from this file: docs/compiler → docs → repo root
    root = Path(__file__).resolve().parents[2]
    env_file = root / ".env"
    if env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            if key.strip() == "DOMAIN":
                val = val.strip().strip("'").strip('"')
                if val:
                    return val
    return "example.com"


def expand_domain(text: str, domain: str) -> str:
    """Replace ${domain} (any case) with the apex domain."""
    return DOMAIN_PLACEHOLDER_RE.sub(domain, text)


def compile_file(
    input_path: Path,
    output_path: Path | None,
    dark: bool = False,
    domain: str | None = None,
) -> Path:
    text = input_path.read_text(encoding="utf-8")
    text = expand_domain(text, resolve_domain(domain))
    meta, md_body = split_metadata(text)
    require_meta(meta)

    title = meta["title"]
    page_title = meta.get("page_title") or title or input_path.stem
    # CLI --dark wins; front matter theme: dark also enables it.
    # Starts the no-JS checkbox checked; the reader can still flip it.
    theme = (meta.get("theme") or "").strip().lower()
    use_dark = dark or theme == "dark"

    body_html = convert(md_body)

    output_html = fill_template(
        TEMPLATE_HTML,
        {
            "css": TEMPLATE_CSS,
            "page_title": libhtml.escape(page_title, quote=False),
            "theme_checked": " checked" if use_dark else "",
            "body_html": body_html,
        },
    )
    output_html = prettify_html(output_html)

    if output_path is None:
        output_path = input_path.with_suffix(".html")
    output_path.write_text(output_html, encoding="utf-8")
    return output_path
