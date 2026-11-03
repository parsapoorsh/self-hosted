"""HTML string postprocessors for DJB tag names and pre cleanup."""

from __future__ import annotations

import re

import markdown

# Small chip over each fence; click handled by template.html script.
COPY_BUTTON_HTML = (
    '<button type="button" class="code-copy" title="Copy" '
    'aria-label="Copy code">Copy</button>'
)


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

    Fenced output looks like ``<pre><tt>...\\n</tt></pre>`` (or bare
    ``<pre>...\\n</pre>``). Strip one trailing newline before the last
    close-tag inside the pre, so the box has no blank last line.
    """

    PRE_RE = re.compile(
        r"(<pre\b[^>]*>)(.*?)(</pre>)",
        re.DOTALL | re.IGNORECASE,
    )

    def run(self, text: str) -> str:
        def fix(match: re.Match[str]) -> str:
            open_tag, body, close_tag = match.group(1), match.group(2), match.group(3)
            # ...text\n</tt>  or  ...text\n
            body = re.sub(r"\n(?=(?:</[^>]+>\s*)*$)", "", body, count=1)
            if body.endswith("\n"):
                body = body[:-1]
            return f"{open_tag}{body}{close_tag}"

        return self.PRE_RE.sub(fix, text)


class DjbCodeBlockPostprocessor(markdown.postprocessors.Postprocessor):
    """Wrap each fenced block in a shell with a top-right copy button.

    CodeHilite emits ``<div class="codehilite"><pre>...</pre></div>``.
    Any remaining bare ``<pre>`` (no hilite wrapper) gets the same shell.
    """

    CODEHILITE_RE = re.compile(
        r'<div class="codehilite">.*?</div>',
        re.DOTALL | re.IGNORECASE,
    )
    PRE_RE = re.compile(
        r"<pre\b[^>]*>.*?</pre>",
        re.DOTALL | re.IGNORECASE,
    )

    def run(self, text: str) -> str:
        def wrap_hilite(match: re.Match[str]) -> str:
            return (
                f'<div class="code-block">{COPY_BUTTON_HTML}'
                f"{match.group(0)}</div>"
            )

        text = self.CODEHILITE_RE.sub(wrap_hilite, text)

        # Bare <pre> not already inside a code-block (hilite path covered above).
        out: list[str] = []
        last = 0
        for match in self.PRE_RE.finditer(text):
            start, end = match.start(), match.end()
            out.append(text[last:start])
            window = text[max(0, start - 200):start]
            open_at = window.rfind('<div class="code-block">')
            close_at = window.rfind("</div>")
            if open_at > close_at:
                out.append(match.group(0))
            else:
                out.append(
                    f'<div class="code-block">{COPY_BUTTON_HTML}'
                    f"{match.group(0)}</div>"
                )
            last = end
        out.append(text[last:])
        return "".join(out)
