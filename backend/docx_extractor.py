# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""Extract paragraph, table and OMML formula text from Word documents."""

from collections.abc import Iterator
from itertools import zip_longest
from typing import Protocol, cast

from docx import Document

if __package__:
    from .library_boundary import member
    from .logging_setup import get_logger
else:
    from library_boundary import member
    from logging_setup import get_logger


logger = get_logger(__name__)


class _XmlElement(Protocol):
    tag: str
    text: str | None

    def __iter__(self) -> Iterator["_XmlElement"]: ...


_WORD = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
_MATH = "{http://schemas.openxmlformats.org/officeDocument/2006/math}"
_HIDDEN = {_WORD + name for name in ("del", "moveFrom", "sdtPr", "tblPr", "trPr", "tcPr", "pPr")}


def _xml_text(element: _XmlElement) -> str:
    # 2026-10-24：保留可见域、超链接与原生公式，排除删除修订和格式元数据。
    if element.tag in _HIDDEN:
        return ""
    if element.tag in {_WORD + "t", _MATH + "t"}:
        return element.text or ""
    if element.tag == _WORD + "tab":
        return "\t"
    if element.tag in {_WORD + "br", _WORD + "cr"}:
        return "\n"
    return "".join(_xml_text(child) for child in element)


def _blocks(element: _XmlElement, names: set[str]) -> Iterator[_XmlElement]:
    for child in element:
        if child.tag in _HIDDEN:
            continue
        if child.tag in names:
            yield child
        else:
            yield from _blocks(child, names)


def _document_lines(element: _XmlElement) -> Iterator[str]:
    for block in _blocks(element, {_WORD + "p", _WORD + "tbl"}):
        if block.tag == _WORD + "p":
            yield from _xml_text(block).split("\n")
        else:
            yield from _table_lines(block)


def _cell_lines(cell: _XmlElement) -> list[str]:
    lines = [line.strip() for line in _document_lines(cell)]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return lines


def _table_lines(table: _XmlElement) -> Iterator[str]:
    # 2026-10-24：按实际 XML 单元格读取，避免合并格重复；多行内容按行配对。
    for row in _blocks(table, {_WORD + "tr"}):
        cells = [_cell_lines(cell) for cell in _blocks(row, {_WORD + "tc"})]
        for parts in zip_longest(*cells, fillvalue=""):
            yield "\t".join(part for part in parts if part)


def extract_text_from_docx(file_path: str) -> str:
    """Read ordinary text and native Office formulas in document order."""
    try:
        document = Document(file_path)
    except Exception:
        logger.exception("Unable to read Word document: %s", file_path)
        raise
    element = member(document, "_element")
    body = cast("_XmlElement", member(element, "body"))
    return "\n".join(_document_lines(body))
