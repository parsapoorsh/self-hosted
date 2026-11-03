"""DJB markdown extensions: syntax sugar + HTML tree polish."""

from __future__ import annotations

import markdown
from markdown.inlinepatterns import SimpleTagInlineProcessor

from extensions.constants import QUOTE_COLOR_RE, STRIKE_RE
from extensions.img_attr_syntax import ImgAttrSyntaxPreprocessor
from extensions.md_block import MdBlockProcessor
from extensions.postprocess import (
    DjbCodeBlockPostprocessor,
    DjbInlineTagPostprocessor,
    DjbPreTrailingNewlinePostprocessor,
)
from extensions.quote_color import QuoteColorProcessor
from extensions.tree_polish import DjbTreeprocessor


class DjbExtension(markdown.Extension):
    """All DJB authoring helpers: syntax sugar + HTML tree polish."""

    def extendMarkdown(self, md):
        md.preprocessors.register(
            ImgAttrSyntaxPreprocessor(md),
            "djb_img_attr_syntax",
            175,
        )
        md.inlinePatterns.register(
            QuoteColorProcessor(QUOTE_COLOR_RE, md),
            "djb_quote_color",
            175,
        )
        md.inlinePatterns.register(
            SimpleTagInlineProcessor(STRIKE_RE, "del"),
            "djb_strike",
            175,
        )
        md.parser.blockprocessors.register(
            MdBlockProcessor(md.parser),
            "djb_md_block",
            175,
        )
        # After toc (priority 5); higher runs first, so 4 is after toc.
        md.treeprocessors.register(
            DjbTreeprocessor(md),
            "djb_polish",
            4,
        )
        # After raw-html restore so fenced <code> blocks are renamed too.
        md.postprocessors.register(
            DjbInlineTagPostprocessor(md),
            "djb_inline_tags",
            5,
        )
        # After fences are restored and tags renamed.
        md.postprocessors.register(
            DjbPreTrailingNewlinePostprocessor(md),
            "djb_pre_trim",
            4,
        )
        # After pre trim: wrap hilite/pre in copy-button shell.
        md.postprocessors.register(
            DjbCodeBlockPostprocessor(md),
            "djb_code_block",
            3,
        )


__all__ = ["DjbExtension"]
