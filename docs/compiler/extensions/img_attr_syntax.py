"""Require {: ...} attr_list on images; reject {width=...} shorthand."""

from __future__ import annotations

from markdown.preprocessors import Preprocessor

from extensions.constants import IMG_ATTR_LIST_RE


class ImgAttrSyntaxPreprocessor(Preprocessor):
    """Fail compile if an image uses {attrs} without the leading colon.

    attr_list accepts both `{width=25%}` and `{: width=25%}`. Only the
    colon form is allowed here so authoring stays consistent.
    """

    def run(self, lines: list[str]) -> list[str]:
        in_fence = False
        fence_marker = ""

        for line_no, line in enumerate(lines, start=1):
            stripped = line.lstrip()
            if stripped.startswith("```") or stripped.startswith("~~~"):
                marker = stripped[:3]
                if not in_fence:
                    in_fence = True
                    fence_marker = marker
                elif marker == fence_marker:
                    in_fence = False
                    fence_marker = ""
                continue
            if in_fence:
                continue

            for match in IMG_ATTR_LIST_RE.finditer(line):
                inner = match.group(1)
                if inner.lstrip().startswith(":"):
                    continue
                raise ValueError(
                    f"line {line_no}: img attrs must use "
                    f"'{{: ...}}' form, got '{{{inner}}}'; "
                    f"example: ![alt](pic.jpg){{: width=25%}}"
                )

        return lines
