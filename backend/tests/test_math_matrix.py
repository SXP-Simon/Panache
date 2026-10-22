# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-22：作业矩阵、行列式与分段函数的真实二维几何回归。."""

from pathlib import Path

import pytest
import symbol_fallback as symbols
from math_table import parse_table
from PIL import Image, ImageDraw, ImageFont

FONT_ROOT = Path(__file__).resolve().parents[1] / "font_assets"
KINDS = ("matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "cases")


@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("size", [24, 40, 70])
@pytest.mark.parametrize("font_name", ["云烟体.ttf", "霞鹜文楷.ttf"])
def test_matrix_uses_real_rows_and_columns_without_spurious_grid(kind, size, font_name):
    path = str(FONT_ROOT / font_name)
    font = ImageFont.truetype(path, size)
    normalized = symbols.normalize_text_for_font(f"⟦ {kind}: 1  (a)/(b) ; x²  123 ⟧")
    assert len(normalized) == 1
    box = symbols._layout_math_char(normalized, font, path, symbols._LayoutMemo())
    assert len(box.children) == 4
    for column in range(2):
        upper, ux, uy = box.children[column]
        lower, lx, ly = box.children[column + 2]
        assert uy + upper.bbox[3] < ly + lower.bbox[1]
        if kind == "cases":
            assert ux + upper.bbox[0] == lx + lower.bbox[0]
        else:
            assert abs(ux + sum(upper.bbox[::2]) / 2 - lx - sum(lower.bbox[::2]) / 2) <= 1
    expected_paths = (
        0 if kind == "matrix" else 1 if kind == "cases" else 4 if kind == "Vmatrix" else 2
    )
    assert len(box.paths) == expected_paths
    axis = symbols._math_axis(font, path)
    assert abs((box.bbox[1] + box.bbox[3]) / 2 - axis) <= 2
    image = Image.new("1", (2000, 1200))
    symbols._paint_math_box(ImageDraw.Draw(image), box, (300, 400))
    ink = image.getbbox()
    assert ink is not None
    assert box.bbox[0] <= ink[0] - 300 < ink[2] - 300 <= box.bbox[2]
    assert box.bbox[1] <= ink[1] - 400 < ink[3] - 400 <= box.bbox[3]


def test_augmented_matrix_only_draws_the_requested_separator():
    path = str(FONT_ROOT / "霞鹜文楷.ttf")
    font = ImageFont.truetype(path, 48)
    normalized = symbols.normalize_text_for_font("⟦ bmatrix: 1  0 | 2 ; 0  1 | 3 ⟧")
    box = symbols._layout_math_char(normalized, font, path, symbols._LayoutMemo())
    assert len(box.paths) == 3
    assert len({pen for _, pen in box.paths}) == 1


def test_single_row_empty_cells_nested_matrices_and_invalid_shapes():
    assert parse_table("⟦ pmatrix: 1    3 ⟧").rows == (("1", "", "3"),)
    for source in (
        "⟦ cases: x ; y ⟧",
        "⟦ pmatrix: 1  2 ; 3 ⟧",
        "⟦ pmatrix: 1\n2 ⟧",
        "⟦ pmatrix: " + " ; ".join(["1"] * 33) + " ⟧",
    ):
        assert parse_table(source) is None
        assert symbols.convert_tables_to_drawn(source) == source
    source = "⟦ bmatrix: ⟦ pmatrix: 1  2 ; 3  4 ⟧  0 ; 0  1 ⟧"
    normalized = symbols.normalize_text_for_font(source)
    assert len(normalized) == 1
    inner = symbols._TABLE_MAP[normalized].rows[0][0]
    assert len(inner) == 1
    assert symbols._TABLE_MAP[inner].kind == "pmatrix"
    assert symbols.convert_tables_to_drawn("[ 1  2 ; 3  4 ]") == "[ 1  2 ; 3  4 ]"


def test_substack_inside_operator_script_remains_two_rows():
    path = str(FONT_ROOT / "霞鹜文楷.ttf")
    font = ImageFont.truetype(path, 70)
    normalized = symbols.normalize_text_for_font("∑_(⟦ matrix: i=0 ; j=1 ⟧)ⁿaᵢⱼ")
    assert "⟦" not in normalized
    script = next(symbols._SCRIPT_MAP[char] for char in normalized if char in symbols._SCRIPT_MAP)
    lower = next(text for text, superscript in script if not superscript)
    assert len(lower) == 1
    assert symbols._TABLE_MAP[lower].rows == (("i=0",), ("j=1",))
    box = symbols._layout_math_text(normalized, font, path)
    image = Image.new("1", (1200, 800))
    symbols._paint_math_box(ImageDraw.Draw(image), box, (200, 300))
    ink = image.getbbox()
    assert ink is not None
    assert ink[1] >= box.bbox[1] + 300
    assert ink[3] <= box.bbox[3] + 300
