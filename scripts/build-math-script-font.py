#!/usr/bin/env python3
# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-22：从 KaTeX Caligraphic (OFL 1.1) 重建内部 Unicode 花体备用字库."""

import argparse
import string
from pathlib import Path
from typing import Protocol, cast

from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
from fontTools.ttLib.tables._n_a_m_e import NameRecord

LETTERS = (
    "\U0001d49c\u212c\U0001d49e\U0001d49f\u2130\u2131\U0001d4a2\u210b\u2110"
    "\U0001d4a5\U0001d4a6\u2112\u2133\U0001d4a9\U0001d4aa\U0001d4ab\U0001d4ac"
    "\u211b\U0001d4ae\U0001d4af\U0001d4b0\U0001d4b1\U0001d4b2\U0001d4b3\U0001d4b4\U0001d4b5"
)


class CmapTable(Protocol):
    """2026-10-22：fontTools 的字符表编辑边界."""

    tables: list[CmapSubtable]


class NameTable(Protocol):
    """2026-10-22：字体名称记录."""

    names: list[NameRecord]


def build(source: Path, output: Path) -> None:
    """2026-10-22：映射全部大写花体；不保留 ASCII 映射，避免影响普通文字."""
    font = TTFont(source, recalcTimestamp=False)
    try:
        original = font.getBestCmap()
        if original is None or any(ord(char) not in original for char in string.ascii_uppercase):
            msg = "Expected a complete KaTeX Caligraphic uppercase font"
            raise ValueError(msg)
        table = CmapSubtable.newSubtable(12)
        table.platformID, table.platEncID, table.language = 3, 10, 0
        table.cmap = {ord(char): original[ord("A") + index] for index, char in enumerate(LETTERS)}
        cast("CmapTable", font["cmap"]).tables = [table]
        names = {
            1: "Panache Math Script",
            2: "Regular",
            3: "PanacheMathScript-Regular",
            4: "Panache Math Script",
            6: "PanacheMathScript-Regular",
        }
        for record in cast("NameTable", font["name"]).names:
            if record.nameID in names:
                record.string = names[record.nameID].encode(record.getEncoding())
        output.parent.mkdir(parents=True, exist_ok=True)
        font.save(str(output))
    finally:
        font.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    build(arguments.source, arguments.output)
