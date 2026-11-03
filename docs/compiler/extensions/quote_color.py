"""^^text^^ → brown <font> for third-party wording."""

from __future__ import annotations

from xml.etree import ElementTree as etree

from markdown.inlinepatterns import InlineProcessor

from extensions.constants import QUOTE_COLOR


class QuoteColorProcessor(InlineProcessor):
    """Turn ^^text^^ into <font color="#663319">text</font>."""

    def handleMatch(self, match, data):
        el = etree.Element("font")
        el.set("color", QUOTE_COLOR)
        el.text = match.group(1)
        return el, match.start(0), match.end(0)
