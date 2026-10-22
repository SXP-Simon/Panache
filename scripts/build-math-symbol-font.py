"""Build the internal blackboard-capital fallback from KaTeX AMS (SIL OFL 1.1).

Requires fonttools. Supply flutter_math_fork's lib/katex_fonts/fonts/
KaTeX_AMS-Regular.ttf as --source. Normal application builds use the checked-in
output and do not need Python or fonttools.
"""

import argparse
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable


def build(source: Path, output: Path) -> None:
    font = TTFont(source, recalcTimestamp=False)
    original = font.getBestCmap()
    legacy = {
        "C": 0x2102,
        "H": 0x210D,
        "N": 0x2115,
        "P": 0x2119,
        "Q": 0x211A,
        "R": 0x211D,
        "Z": 0x2124,
    }
    mapping = {
        legacy.get(chr(code), 0x1D538 + code - ord("A")): original[code]
        for code in range(ord("A"), ord("Z") + 1)
    }
    table = CmapSubtable.newSubtable(12)
    table.platformID, table.platEncID, table.language = 3, 10, 0
    table.cmap = mapping
    font["cmap"].tables = [table]
    names = {
        1: "Handwriting Math Symbols",
        2: "Regular",
        3: "HandwritingMathSymbols-Regular",
        4: "Handwriting Math Symbols",
        6: "HandwritingMathSymbols-Regular",
    }
    for record in font["name"].names:
        if record.nameID in names:
            record.string = names[record.nameID].encode(record.getEncoding())
    options = subset.Options()
    options.recalc_timestamp = False
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=mapping)
    subsetter.subset(font)
    output.parent.mkdir(parents=True, exist_ok=True)
    font.save(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "crates/handwriting-core/assets/HandwritingMathSymbols.ttf",
    )
    arguments = parser.parse_args()
    build(arguments.source, arguments.output)
