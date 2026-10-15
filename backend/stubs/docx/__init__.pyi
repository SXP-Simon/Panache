# Copyright (c) 2026 Simon and Handwriting Web contributors.
from collections.abc import Iterator

class XmlElement:
    tag: str
    text: str | None
    def iter(self) -> Iterator[XmlElement]: ...

class Paragraph:
    text: str
    _element: XmlElement

class Cell:
    text: str
    _element: XmlElement

class Row:
    cells: list[Cell]

class Table:
    rows: list[Row]

class DocumentObject:
    paragraphs: list[Paragraph]
    tables: list[Table]

def Document(docx: str) -> DocumentObject: ...
