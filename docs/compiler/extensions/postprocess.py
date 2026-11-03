"""HTML string postprocessors for DJB tag names and pre cleanup."""

from __future__ import annotations

import re

import markdown


class DjbInlineTagPostprocessor(markdown.postprocessors.Postprocessor):
    """Map em/strong/code to DJB i/b/tt after fenced blocks are restored."""

    def run(self, text: str) -> str:
        text = text.replace("<em>", "<i>").replace("</em>", "</i>")
        text = text.replace("<strong>", "<b>").replace("</strong>", "</b>")
        # Keep attributes (language-*).
        text = re.sub(r"<code(\s[^>]*)?>", r"<tt\1>", text)
        text = text.replace("</code>", "</tt>")
        return text


class DjbPreTrailingNewlinePostprocessor(markdown.postprocessors.Postprocessor):
    """Drop the final newline Markdown leaves inside each <pre> block.

    Fenced output looks like ``<pre><tt>…\\n</tt></pre>`` (or bare
    ``<pre>…\\n</pre>``). Strip one trailing newline before the last
    close-tag inside the pre, so the box has no blank last line.
    """

    PRE_RE = re.compile(
        r"(<pre\b[^>]*>)(.*?)(</pre>)",
        re.DOTALL | re.IGNORECASE,
    )

    def run(self, text: str) -> str:
        def fix(match: re.Match[str]) -> str:
            open_tag, body, close_tag = match.group(1), match.group(2), match.group(3)
            # …text\n</tt>  or  …text\n
            body = re.sub(r"\n(?=(?:</[^>]+>\s*)*$)", "", body, count=1)
            if body.endswith("\n"):
                body = body[:-1]
            return f"{open_tag}{body}{close_tag}"

        return self.PRE_RE.sub(fix, text)
