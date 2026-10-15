# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""Extract paragraph, table and OMML formula text from Word documents."""

import logging
from collections.abc import Iterator
from typing import Protocol, cast

from docx import Document

if __package__:
    from .library_boundary import member
else:
    from library_boundary import member


logger = logging.getLogger(__name__)


class _XmlElement(Protocol):
    tag: str
    text: str | None

    def iter(self) -> Iterator["_XmlElement"]: ...


def _xml_text(container: object) -> str:
    element = cast("_XmlElement", member(container, "_element"))
    parts: list[str] = []
    for node in element.iter():
        if node.tag.endswith("}t") and node.text:
            parts.append(node.text)
        elif node.tag.endswith("}tab"):
            parts.append("\t")
        elif node.tag.endswith(("}br", "}cr")):
            parts.append("\n")
    return "".join(parts)


def extract_text_from_docx(file_path: str) -> str:
    """Read ordinary text and native Office formulas in document order."""
    try:
        document = Document(file_path)
    except Exception:
        logger.exception("Unable to read Word document: %s", file_path)
        raise
    lines = [_xml_text(paragraph) for paragraph in document.paragraphs]
    lines.extend(
        "\t".join(_xml_text(cell).strip() for cell in row.cells)
        for table in document.tables
        for row in table.rows
    )
    return "\n".join(lines)
