"""HTML pretty-print via BeautifulSoup."""

from __future__ import annotations

from bs4 import BeautifulSoup
from bs4.formatter import HTMLFormatter

PRETTY_FORMATTER = HTMLFormatter(
    indent="\t",
    void_element_close_prefix="",
)


def prettify_html(html: str) -> str:
    """Indent markup with tabs using BeautifulSoup."""
    soup = BeautifulSoup(html, "html.parser")
    pretty = soup.prettify(formatter=PRETTY_FORMATTER)
    if not pretty.endswith("\n"):
        pretty += "\n"
    return pretty
