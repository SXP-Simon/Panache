# Copyright (c) 2026 Simon and Handwriting Web contributors.

import json
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
    assert len(box.paths) == columns + 4
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
    assert any(len(path) == 2 for path, _ in box.paths)
    assert all(len(path) == 2 for path, _ in box.paths)
    assert all(thickness >= 1 for _, thickness in box.paths)
    strokes = symbols._compose_box(box.advance, paths=box.paths)
    image = Image.new("1", (1000, 600))
    symbols._paint_math_box(ImageDraw.Draw(image), strokes, (20, 20))
    vertical_dashes = [
        path
        for path, _ in box.paths
        if len(path) == 2 and path[0][0] == path[1][0] and path[1][1] - path[0][1] <= 12
    ]
    first, second = vertical_dashes[:2]
    gap_y = (first[1][1] + second[0][1]) // 2
    assert not image.getpixel((20 + first[0][0], 20 + gap_y))


def test_complete_grid_encloses_every_cell_with_clear_ink_padding():
    converted = symbols.normalize_text_for_font(X)
    font = ImageFont.truetype(str(FONT), 64)
    box = symbols._layout_math_char(converted, font, str(FONT), symbols._LayoutMemo())
    vertical = [
        (points[0][0], width) for points, width in box.paths if points[0][0] == points[-1][0]
    ]
    horizontal = [
        (points[0][1], width) for points, width in box.paths if points[0][1] == points[-1][1]
    ]
    assert len(vertical) == 6
    assert len(horizontal) == 3
    assert vertical[0][0] == horizontal[0][0] == 0
    assert len({width for _, width in vertical + horizontal}) == 1
    assert horizontal[1][0] * 2 == horizontal[2][0]
    assert all(len(points) == 2 for points, _ in box.paths)
    image = Image.new("1", (1000, 600))
    symbols._paint_math_box(ImageDraw.Draw(image), box, (20, 20))
    for x, _ in vertical:
        for y in range(horizontal[-1][0] + 1):
            assert image.crop((20 + x - 2, 20 + y, 20 + x + 3, 21 + y)).getbbox()
    for y, _ in horizontal:
        for x in range(vertical[-1][0] + 1):
            assert image.crop((20 + x, 20 + y - 2, 21 + x, 20 + y + 3)).getbbox()
    for index, (child, x, y) in enumerate(box.children):
        row, column = divmod(index, 5)
        assert (
            abs(
                (y + child.bbox[1] + y + child.bbox[3])
                - (horizontal[row][0] + horizontal[row + 1][0])
            )
            <= 1
        )
        assert (
            abs(
                (x + child.bbox[0] + x + child.bbox[2])
                - (vertical[column][0] + vertical[column + 1][0])
            )
            <= 1
        )
        assert x + child.bbox[0] > vertical[column][0] + 5
        assert x + child.bbox[2] < vertical[column + 1][0] - 5
        assert y + child.bbox[1] > horizontal[row][0] + 5
        assert y + child.bbox[3] < horizontal[row + 1][0] - 5


@pytest.mark.parametrize(
    "cell",
    [
        "a|b",
        "a ; b",
        "a  b",
        'say "hello"',
        r"C:\Users\Simon\file.txt",
        "⟦ literal ⟧",
        "(unbalanced",
        "a||b",
        "a┆b",
    ],
)
def test_quoted_cell_keeps_literal_delimiters_whitespace_and_backslashes(cell):
    quoted = json.dumps(cell, ensure_ascii=False)
    source = f"⟦ X | {quoted} ; ── ; P | 1 ⟧"
    table = parse_table(source)
    assert table is not None
    assert table.rows == (("X", cell), ("P", "1"))
    normalized = symbols.normalize_text_for_font(source)
    assert len(normalized) == 1
    assert symbols._TABLE_MAP[normalized].rows == table.rows
    font = ImageFont.truetype(str(FONT), 40)
    box = symbols._layout_math_char(normalized, font, str(FONT), symbols._LayoutMemo())
    assert len(box.children) == 4


@pytest.mark.parametrize(
    "cell", ['"unclosed', '"a"garbage', 'prefix"a"', r'"invalid\q"', r'"line\nfeed"']
)
def test_malformed_quoted_cell_falls_back_without_partial_table(cell):
    source = f"⟦ X | {cell} ; ── ; P | 1 ⟧"
    assert parse_table(source) is None
    assert symbols.convert_tables_to_drawn(source) == source


def test_table_parsing_preserves_code_literals_and_handles_neighboring_tables():
    literal = '`⟦ "unclosed`'
    source = literal + " " + X + " " + Y
    normalized = symbols.normalize_text_for_font(source)
    assert normalized.startswith(literal + " ")
    assert sum(char in symbols._TABLE_MAP for char in normalized) == 2


def test_quoted_empty_cells_and_double_spaces_do_not_create_extra_columns():
    source = '⟦ X | "a  b"  ""  "c|d" ; ── ; P | "a ; b"  "──"  "⟦⟧" ⟧'
    table = parse_table(source)
    assert table is not None
    assert table.rows == (("X", "a  b", "", "c|d"), ("P", "a ; b", "──", "⟦⟧"))
    assert len(symbols.normalize_text_for_font(source)) == 1
