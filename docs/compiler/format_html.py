"""HTML pretty-print via BeautifulSoup (safe for <pre> / code fences)."""

from __future__ import annotations

import html as libhtml
import re

from bs4 import BeautifulSoup, NavigableString
from bs4.formatter import EntitySubstitution, HTMLFormatter

# Escape <>&"' so cat <<EOF and similar stay text inside <pre>, not tags.
PRETTY_FORMATTER = HTMLFormatter(
    indent="\t",
    void_element_close_prefix="",
    entity_substitution=EntitySubstitution.substitute_html,
)

# Placeholders must not look like HTML or markdown.
PRE_PLACEHOLDER = "<!--DJB_PRE_{}-->"


def prettify_html(html: str) -> str:
    """Indent markup with tabs; keep fenced/pre text HTML-escaped."""
    # Stash <pre>...</pre> before parse so a broken tree cannot eat fence bodies.
    pres: list[str] = []

    def stash(match: re.Match[str]) -> str:
        pres.append(match.group(0))
        return PRE_PLACEHOLDER.format(len(pres) - 1)

    stashed = re.sub(
        r"<pre\b[^>]*>.*?</pre>",
        stash,
        html,
        flags=re.DOTALL | re.IGNORECASE,
    )

    soup = BeautifulSoup(stashed, "html.parser")
    pretty = soup.prettify(formatter=PRETTY_FORMATTER)
    if not pretty.endswith("\n"):
        pretty += "\n"

    for i, block in enumerate(pres):
        # Re-escape text nodes inside pre in case the original was already
        # partially decoded; parse one pre and serialize with html escaping.
        safe = _serialize_pre_escaped(block)
        pretty = pretty.replace(PRE_PLACEHOLDER.format(i), safe)

    return pretty


def _serialize_pre_escaped(pre_html: str) -> str:
    """Return a <pre>...</pre> fragment with all text content escaped."""
    soup = BeautifulSoup(pre_html, "html.parser")
    pre = soup.find("pre")
    if pre is None:
        return libhtml.escape(pre_html)

    def walk(node) -> None:
        for child in list(node.children):
            if isinstance(child, NavigableString):
                # NavigableString is already the decoded text; escape for HTML.
                text = str(child)
                escaped = libhtml.escape(text, quote=False)
                if escaped != text:
                    child.replace_with(escaped)
            elif getattr(child, "name", None):
                walk(child)

    walk(pre)
    # formatter=None: we already inserted entity strings; do not double-escape.
    out = pre.decode(formatter=None)
    return out
