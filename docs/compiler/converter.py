"""Convert markdown to HTML with stock + DJB extensions."""

from __future__ import annotations

import markdown
from markdown.extensions.admonition import AdmonitionExtension
from markdown.extensions.codehilite import CodeHiliteExtension
from markdown.extensions.extra import ExtraExtension
from markdown.extensions.sane_lists import SaneListExtension
from markdown.extensions.smarty import SmartyExtension
from markdown.extensions.toc import TocExtension

from extensions import DjbExtension


def convert(text: str) -> str:
    """Render markdown to an HTML fragment."""
    md = markdown.Markdown(
        extensions=[
            ExtraExtension(),
            # Pre-render fence colors with Pygments (no client highlighter).
            CodeHiliteExtension(
                css_class="codehilite",
                guess_lang=False,
                use_pygments=True,
            ),
            SaneListExtension(),
            SmartyExtension(),
            TocExtension(
                permalink=False,
                title="Contents",
            ),
            AdmonitionExtension(),
            DjbExtension(),
        ],
        output_format="html",
    )
    return md.convert(text)
