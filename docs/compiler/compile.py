"""Compile a markdown post into a DJB-style static HTML page."""

from __future__ import annotations

import html as libhtml
from pathlib import Path

from converter import convert
from format_html import prettify_html
from metadata import require_meta, split_metadata
from template import TEMPLATE_CSS, TEMPLATE_HTML, fill_template


def compile_file(
    input_path: Path,
    output_path: Path | None,
    dark: bool = False,
) -> Path:
    text = input_path.read_text(encoding="utf-8")
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
