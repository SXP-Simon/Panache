# Copyright (c) 2026 Simon and Handwriting Web contributors.

from pathlib import Path

import pytest
import symbol_fallback as symbols
from app import _english_spacing
from math_table import Rule, parse_table
from PIL import Image, ImageDraw, ImageFont
from test_math_page_layout import assert_inside, draft, real_core, template

X = "⟦ X | 0  1  2  3 ; ── ; P | (8)/(15)  (4)/(15)  (2)/(15)  (1)/(15) ⟧"
Y = "⟦ Y | 1  2  3 ; ── ; P | ⅓  ⅓  ⅓ ⟧"
FONT = Path(__file__).resolve().parents[1] / "font_assets/云烟体.ttf"


@pytest.mark.parametrize("source", [X, Y])
@pytest.mark.parametrize("font_name", ["云烟体.ttf", "李国夫手写体.ttf"])
def test_distribution_table_has_shared_columns_and_centered_fraction_cells(source, font_name):
    converted = symbols.normalize_text_for_font(source)
    assert len(converted) == 1
    assert converted in symbols._TABLE_MAP
    font_path = FONT.parent / font_name
    font = ImageFont.truetype(str(font_path), 64)
    box = symbols._layout_math_char(converted, font, str(font_path), symbols._LayoutMemo())
    table = symbols._TABLE_MAP[converted]
    columns = len(table.rows[0])
    assert len(box.children) == columns * 2
    for column in range(columns):
        upper, ux, uy = box.children[column]
        lower, lx, ly = box.children[columns + column]
        upper_center = ux + (upper.bbox[0] + upper.bbox[2]) / 2
        lower_center = lx + (lower.bbox[0] + lower.bbox[2]) / 2
        assert abs(upper_center - lower_center) <= 1
        assert uy + upper.bbox[3] < ly + lower.bbox[1]
    assert len(box.paths) == 2
    image = Image.new("1", (2000, 800))
    symbols._paint_math_box(ImageDraw.Draw(image), box, (100, 100))
    ink = image.getbbox()
    assert ink is not None
    assert box.bbox[0] <= ink[0] - 100
    assert box.bbox[1] <= ink[1] - 100
    assert box.bbox[2] >= ink[2] - 100
    assert box.bbox[3] >= ink[3] - 100
    rule_y = box.paths[1][0][0][1] + 100
    assert image.crop((100, rule_y - 2, 100 + box.advance, rule_y + 3)).getbbox()


@pytest.mark.parametrize(
    "source",
    [
        "⟦ a  b ; c  d ⟧",
        "⟦ a | b ; c  d ⟧",
        "⟦ a | b ; c | d  e ⟧",
        "⟦ a || b ; c || d ⟧",
        "⟦ a|b ; c|d ⟧",
        "⟦ a | b ; ── ; ── ; c | d ⟧",
        "[ a | b ; c | d ]",
        "⟦ a | b ⟧",
        "⟦ a | (b ; c | d ⟧",
    ],
)
def test_ambiguous_and_unruled_matrix_stays_literal(source):
    assert symbols.convert_tables_to_drawn(source) == source
    assert symbols.convert_tables_to_drawn("[ a | b ; ── ; c | d ]") == "[ a | b ; ── ; c | d ]"


def test_empty_cells_frames_single_columns_and_dashed_rules_keep_structure():
    table = parse_table("⟦ | a    b | ; ── ; | c    d | ⟧")
    assert table is not None
    assert table.rows == (("a", "", "b"), ("c", "", "d"))
    assert table.vertical == (Rule(0), Rule(3))
    single = parse_table("⟦ ── ; a ; ── ; b ; ── ⟧")
    assert single is not None
    assert single.rows == (("a",), ("b",))
    assert single.horizontal == (Rule(0), Rule(1), Rule(2))
    dashed = parse_table("⟦ a ┆ b ; ╌╌ ; c ┆ d ⟧")
    assert dashed is not None
    assert dashed.vertical == (Rule(1, dashed=True),)
    assert dashed.horizontal == (Rule(1, dashed=True),)
    empty = parse_table("⟦  | a ; ── ; b |  ⟧")
    assert empty is not None
    assert empty.rows == (("", "a"), ("b", ""))


def test_english_spacing_preserves_table_columns_and_nested_math():
    normalized = symbols.normalize_text_for_font(_english_spacing(X))
    assert len(normalized) == 1
    assert len(symbols._TABLE_MAP[normalized].rows[0]) == 5
    nested = symbols.normalize_text_for_font(
        "⟦ x | √((x+1)/(x-1))  a_(n) ; ── ; p | (1)/(2)  (3)/(4) ⟧"
    )
    assert len(nested) == 1
    assert len(symbols._TABLE_MAP[nested].rows[0]) == 3
    assert set(symbols._TABLE_MAP).isdisjoint(symbols._SCRIPT_MAP)


@pytest.mark.parametrize("ruled", [False, True])
@pytest.mark.parametrize("size", [(200, 240), (700, 400)])
def test_table_fits_page_without_splitting_cells_or_clipping(size, ruled):
    font = ImageFont.truetype(str(FONT), 56)
    tpl = template(size=size, font=font, line_spacing=70, ruled_origin=10 if ruled else None)
    converted = symbols.normalize_text_for_font(X)
    text = "\n".join([converted] * 4)
    pages, consumed = draft(real_core, text, tpl)
    assert consumed[-1][1] == len(text)
    assert_inside(pages, tpl)
    assert len(pages) >= 2


def test_dashed_rules_are_rendered_as_separate_pen_strokes():
    normalized = symbols.normalize_text_for_font("⟦ a ┆ b ; ╌╌ ; c ┆ d ⟧")
    font = ImageFont.truetype(str(FONT), 56)
    box = symbols._layout_math_char(normalized, font, str(FONT), symbols._LayoutMemo())
    assert len(box.paths) > 4
    assert all(len(path) == 2 for path, _ in box.paths)
    assert all(thickness >= 1 for _, thickness in box.paths)
