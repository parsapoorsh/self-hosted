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

# ${domain} / ${DOMAIN} in markdown -> apex domain from env / .env
DOMAIN_PLACEHOLDER_RE = re.compile(r"\$\{domain\}", re.IGNORECASE)
# ${https_port_suffix} -> empty or :8443 when HTTPS_PORT is non-default
HTTPS_PORT_SUFFIX_RE = re.compile(r"\$\{https_port_suffix\}", re.IGNORECASE)


def read_env_key(key: str) -> str | None:
    """Read a single KEY from repo-root .env if present."""
    root = Path(__file__).resolve().parents[2]
    env_file = root / ".env"
    if not env_file.is_file():
        return None
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, val = line.partition("=")
        if k.strip() == key:
            val = val.strip().strip("'").strip('"')
            if val:
                return val
    return None


def resolve_domain(explicit: str | None = None) -> str:
    """DOMAIN from arg, environment, or repo-root .env (default example.com)."""
    if explicit and explicit.strip():
        return explicit.strip()
    env_val = (os.environ.get("DOMAIN") or "").strip()
    if env_val:
        return env_val
    from_file = read_env_key("DOMAIN")
    if from_file:
        return from_file
    return "example.com"


def resolve_https_port_suffix(explicit: str | None = None) -> str:
    """Empty when HTTPS is 443; otherwise ':PORT' for public URL links."""
    if explicit is not None:
        return explicit
    port = (os.environ.get("HTTPS_PORT") or "").strip()
    if not port:
        port = read_env_key("HTTPS_PORT") or "443"
    if port == "443":
        return ""
    return f":{port}"


def expand_placeholders(
    text: str,
    domain: str,
    https_port_suffix: str = "",
) -> str:
    """Replace ${domain} and ${https_port_suffix} in markdown."""
    text = DOMAIN_PLACEHOLDER_RE.sub(domain, text)
    text = HTTPS_PORT_SUFFIX_RE.sub(https_port_suffix, text)
    return text


def compile_file(
    input_path: Path,
    output_path: Path | None,
    dark: bool = False,
    domain: str | None = None,
) -> Path:
    text = input_path.read_text(encoding="utf-8")
    text = expand_placeholders(
        text,
        resolve_domain(domain),
        resolve_https_port_suffix(),
    )
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
