"""Post-parse polish: subtitles, tasks, colspans, image layout."""

from __future__ import annotations

from xml.etree import ElementTree as etree

from markdown.treeprocessors import Treeprocessor

from extensions.constants import HEADING_TAGS, TASK_MARK_RE
from style_util import normalize_length, parse_style_decl, style_from_decl


class DjbTreeprocessor(Treeprocessor):
    """Post-parse polish: subtitles, tasks, colspans, image layout."""

    def run(self, root):
        self.apply_heading_subtitles(root)
        self.apply_task_lists(root)
        self.apply_table_colspans(root)
        self.apply_image_layout(root)
        # After img width= is CSS, so float boxes can inherit it.
        self.apply_float_blocks(root)
        return root

    def apply_heading_subtitles(self, root) -> None:
        """Wrap text after the first ': ' in each heading in span.subtitle."""
        for heading in root.iter():
            if heading.tag in HEADING_TAGS:
                self.split_heading_at_colon(heading)

    def split_heading_at_colon(self, heading) -> bool:
        """If heading contains ': ', wrap the part after it in span.subtitle."""
        # Flat document-order parts: heading text, then each child + its tail.
        parts: list[tuple[str, object | None, str | None]] = []
        if heading.text:
            parts.append(("text", None, heading.text))
        for child in list(heading):
            parts.append(("el", child, None))
            if child.tail:
                parts.append(("tail", child, child.tail))

        split_idx = None
        split_offset = None
        for i, (kind, _ref, text) in enumerate(parts):
            if kind not in ("text", "tail") or not text:
                continue
            pos = text.find(": ")
            if pos >= 0:
                split_idx = i
                split_offset = pos
                break
        if split_idx is None:
            return False

        kind, _ref, text = parts[split_idx]
        before = text[:split_offset]
        after = text[split_offset + 2:]

        for child in list(heading):
            heading.remove(child)
        heading.text = None

        span = etree.Element("span")
        span.set("class", "subtitle")

        def append_str(parent, s: str) -> None:
            if not s:
                return
            if len(parent) == 0:
                parent.text = (parent.text or "") + s
            else:
                last = parent[-1]
                last.tail = (last.tail or "") + s

        # Prefix (everything before the split string) stays on the heading.
        for p_kind, p_ref, p_text in parts[:split_idx]:
            if p_kind == "text":
                append_str(heading, p_text or "")
            elif p_kind == "el":
                p_ref.tail = None
                heading.append(p_ref)
            elif p_kind == "tail":
                append_str(heading, p_text or "")

        append_str(heading, before + ": ")

        # Suffix goes into span.subtitle.
        append_str(span, after)
        for p_kind, p_ref, p_text in parts[split_idx + 1:]:
            if p_kind == "el":
                p_ref.tail = None
                span.append(p_ref)
            elif p_kind in ("text", "tail"):
                append_str(span, p_text or "")

        if not (span.text and span.text.strip()) and len(span) == 0:
            return False

        heading.append(span)
        return True

    def apply_task_lists(self, root) -> None:
        """Turn leading - [x] / - [ ] list text into disabled checkboxes."""
        for li in root.iter("li"):
            # Text may be li.text or nested in a single <p> (loose lists).
            target = li
            if not (li.text and li.text.strip()) and len(li) == 1 and li[0].tag == "p":
                target = li[0]

            text = target.text or ""
            if not text.strip():
                continue
            match = TASK_MARK_RE.match(text)
            if not match:
                continue
            checked = match.group(2).lower() == "x"
            prefix = match.group(1)
            gap = match.group(3)
            rest = text[match.end():]

            checkbox = etree.Element("input")
            checkbox.set("type", "checkbox")
            checkbox.set("disabled", "disabled")
            if checked:
                checkbox.set("checked", "checked")

            target.text = prefix if prefix else None
            checkbox.tail = f"{gap}{rest}" if (gap or rest) else None
            target.insert(0, checkbox)

    def apply_table_colspans(self, root) -> None:
        """Merge cells marked with a lone ``#`` into the previous cell."""
        for table in root.iter("table"):
            for row in table.iter("tr"):
                cells = [c for c in list(row) if c.tag in ("td", "th")]
                if not cells:
                    continue
                prev = None
                for cell in cells:
                    text = "".join(cell.itertext()).strip()
                    if text == "#" and prev is not None:
                        span = int(prev.get("colspan", "1"))
                        prev.set("colspan", str(span + 1))
                        row.remove(cell)
                    else:
                        prev = cell

    def apply_image_layout(self, root) -> None:
        """Turn Markdown width= on <img> into real CSS."""
        for img in root.iter("img"):
            decls = parse_style_decl(img.get("style") or "")

            for height_key in ("height", "data-height"):
                if img.get(height_key) is not None:
                    raise ValueError(
                        f"invalid img {height_key}={img.get(height_key)!r}; "
                        "height is not supported (layout uses height: auto)"
                    )
            style_height = decls.get("height")
            if (
                style_height is not None
                and str(style_height).strip().lower() not in ("", "auto")
            ):
                raise ValueError(
                    f"invalid img style height={style_height!r}; "
                    "height is not supported (layout uses height: auto)"
                )

            side = (
                img.get("float")
                or img.get("data-float")
                or decls.get("float")
            )
            if side is not None:
                raise ValueError(
                    f"invalid img float={side!r}; float is not supported"
                )
            if img.get("float") is not None:
                del img.attrib["float"]
            if img.get("data-float") is not None:
                del img.attrib["data-float"]

            width_raw = img.get("data-width")
            if width_raw is None and img.get("width") is not None:
                width_raw = img.get("width")
            if width_raw is None and "width" in decls:
                width_raw = decls["width"]
            if width_raw is not None:
                decls["width"] = normalize_length(
                    width_raw,
                    what="img width",
                )
                if img.get("width") is not None:
                    del img.attrib["width"]
                if img.get("data-width") is not None:
                    del img.attrib["data-width"]

            decls.setdefault("max-width", "100%")
            decls.setdefault("height", "auto")

            if "width" in decls:
                img.set("style", style_from_decl(decls))

    def apply_float_blocks(self, root) -> None:
        """md-left/md-right: put img width on the floated first child.

        Percentage width on an <img> inside a full-width <p> makes the float
        as wide as the block. Move width to the first child and let the image
        fill that box (width: 100%).
        """
        for tag in ("md-left", "md-right"):
            for block in root.iter(tag):
                if len(block) == 0:
                    continue
                first = block[0]
                img = first if first.tag == "img" else None
                if img is None:
                    for child in first.iter("img"):
                        img = child
                        break
                if img is None:
                    continue
                decls = parse_style_decl(img.get("style") or "")
                width = decls.get("width")
                if not width or width == "100%":
                    continue
                first_decls = parse_style_decl(first.get("style") or "")
                first_decls["width"] = width
                first_decls.setdefault("max-width", "100%")
                first_decls.setdefault("box-sizing", "border-box")
                first.set("style", style_from_decl(first_decls))
                decls["width"] = "100%"
                decls.setdefault("max-width", "100%")
                decls.setdefault("height", "auto")
                img.set("style", style_from_decl(decls))
