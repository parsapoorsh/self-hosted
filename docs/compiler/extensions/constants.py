"""Shared constants and regexes for DJB markdown extensions."""

from __future__ import annotations

import re

# DJB-style brown for quoted third-party wording (blog.cr.yp.to hybrid post, etc.).
QUOTE_COLOR = "#663319"
HEADING_TAGS = ("h1", "h2", "h3", "h4", "h5", "h6")
TASK_MARK_RE = re.compile(r"^(\s*)\[([ xX])\](\s+)")
# <md-name> ... </md-name>  block wrapper; nested Markdown still runs.
MD_BLOCK_START_RE = re.compile(
    r"^<md-([A-Za-z][\w-]*)\s*>\s*$",
    re.IGNORECASE,
)
MD_BLOCK_END_RE = re.compile(
    r"^</md-([A-Za-z][\w-]*)\s*>\s*$",
    re.IGNORECASE,
)
# ^^colored quote^^ - same brown <font> DJB uses around cited phrases.
QUOTE_COLOR_RE = r"\^\^((?:(?!\^\^).)+)\^\^"
# ~~deleted text~~ -> <del>
STRIKE_RE = r"()~~(.+?)~~"
# ![alt](url){...} / ![alt][ref]{...} - attrs must be {: ...}, not {width=...}.
IMG_ATTR_LIST_RE = re.compile(
    r"!\[[^\]]*\]"
    r"(?:"
    r"\([^)]*\)"
    r"|"
    r"\[[^\]]*\]"
    r")"
    r"\s*"
    r"\{([^{}]*)\}"
)
