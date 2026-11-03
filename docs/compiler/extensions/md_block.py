"""<md-name> ... </md-name> block with nested Markdown."""

from __future__ import annotations

from xml.etree import ElementTree as etree

from markdown.blockprocessors import BlockProcessor

from extensions.constants import MD_BLOCK_END_RE, MD_BLOCK_START_RE


class MdBlockProcessor(BlockProcessor):
    """Parse <md-name>...</md-name> into an element with nested Markdown.

    The tag applies to everything inside (text, images, lists, ...).
    """

    def test(self, parent, block):
        lines = block.splitlines()
        if not lines:
            return False
        return MD_BLOCK_START_RE.match(lines[0].rstrip()) is not None

    def run(self, parent, blocks):
        block = blocks.pop(0)
        lines = block.splitlines()
        match = MD_BLOCK_START_RE.match(lines[0].rstrip())
        if match is None:
            return False
        name = match.group(1).lower()
        tag = f"md-{name}"

        body_parts, closed = self.collect_body(name, lines, blocks)
        if not closed:
            raise ValueError(f"unclosed md block <{tag}>")

        el = etree.SubElement(parent, tag)
        body = "\n\n".join(part for part in body_parts if part is not None)
        body = body.strip("\n")
        if body.strip():
            self.parser.parseChunk(el, body)
        return True

    def collect_body(
        self,
        name: str,
        lines: list[str],
        blocks: list[str],
    ) -> tuple[list[str], bool]:
        """Gather body until matching </md-name>."""
        end_re = MD_BLOCK_END_RE
        body_parts: list[str] = []
        closed = False

        def is_end(line: str) -> bool:
            m = end_re.match(line.rstrip())
            return m is not None and m.group(1).lower() == name

        first_body = "\n".join(lines[1:])
        if first_body.strip() == "" and is_end(first_body.strip()):
            closed = True
        elif first_body:
            end_at = None
            first_lines = first_body.splitlines()
            for i, line in enumerate(first_lines):
                if is_end(line):
                    end_at = i
                    break
            if end_at is not None:
                body_parts.append("\n".join(first_lines[:end_at]))
                closed = True
            else:
                body_parts.append(first_body)

        while not closed and blocks:
            more = blocks.pop(0)
            more_lines = more.splitlines()
            end_at = None
            for i, line in enumerate(more_lines):
                if is_end(line):
                    end_at = i
                    break
            if end_at is not None:
                if end_at > 0:
                    body_parts.append("\n".join(more_lines[:end_at]))
                rest = "\n".join(more_lines[end_at + 1:]).strip("\n")
                if rest.strip():
                    blocks.insert(0, rest)
                closed = True
            else:
                body_parts.append(more)

        return body_parts, closed
