"""组合重音的结构与像素回归。"""

from pathlib import Path

import pytest
from PIL import Image, ImageDraw, ImageFont

import symbol_fallback as symbols


FONT_PATH = str(Path(__file__).resolve().parents[1] / "font_assets/云烟体.ttf")


@pytest.mark.parametrize("mark", sorted(symbols._ACCENT_MARKS))
@pytest.mark.parametrize("body", ["x", "AB", "aₙ+bₙ"])
def test_combining_marks_bind_the_complete_base_without_extra_advance(body, mark):
    source = body + mark if len(body) == 1 else f"({body}){mark}"
    converted = symbols.normalize_text_for_font(source)
    assert len(converted) == 1
    registered_body, registered_mark = symbols._ACCENT_MAP[converted]
    assert registered_mark == mark
    font = ImageFont.truetype(FONT_PATH, 40)
    decorated = symbols._layout_math_text(converted, font, FONT_PATH)
    base = symbols._layout_math_text(registered_body, font, FONT_PATH)
    assert decorated.advance == base.advance
    assert decorated.bbox[1] < base.bbox[1] if mark != "\u0332" else decorated.bbox[3] > base.bbox[3]


@pytest.mark.parametrize("mark", sorted(symbols._ACCENT_MARKS))
@pytest.mark.parametrize("size", [24, 40, 64])
def test_accent_pixels_fit_measured_bbox_and_extend_to_correct_side(mark, size):
    font = ImageFont.truetype(FONT_PATH, size)
    converted = symbols.normalize_text_for_font(f"(xy){mark}")
    declared = symbols._get_rendered_text_bbox(converted, font, FONT_PATH)
    image = Image.new("1", (800, 600), 0)
    advance, _ = symbols._draw_text_or_fraction(ImageDraw.Draw(image), converted, (200, 200), font, FONT_PATH)
    ink = image.getbbox()
    actual = tuple(ink[index] - 200 for index in range(4))
    assert declared[0] <= actual[0] < actual[2] <= declared[2]
    assert declared[1] <= actual[1] < actual[3] <= declared[3]
    assert advance == symbols._measure_text_or_fraction(converted, font, FONT_PATH)[0]
    base = symbols._layout_math_text("xy", font, FONT_PATH)
    region = (0, 200 + base.bbox[3], image.width, image.height) if mark == "\u0332" else (0, 0, image.width, 200 + base.bbox[1])
    assert image.crop(region).getbbox(), "accent must produce visible pixels outside the base"


def test_vector_includes_an_arrowhead_and_is_not_a_plain_overbar():
    font = ImageFont.truetype(FONT_PATH, 64)
    vector = symbols._layout_math_char(symbols.normalize_text_for_font("(AB)⃗"), font, FONT_PATH, {})
    assert len(vector.children) == 1
    assert len(vector.paths) == 2
    shaft, arrowhead = vector.paths
    assert shaft[0][0][1] == shaft[0][1][1]
    assert len(arrowhead[0]) == 3
    assert arrowhead[0][0][1] < arrowhead[0][1][1] < arrowhead[0][2][1]


@pytest.mark.parametrize("source", [r"(\frac{a}{b})̄", r"(\sqrt{x²+1})⃗", r"\frac{x̄}{ÿ}", "x̄̂", "(aₙ+bₙ)̲"])
def test_accents_nest_with_fractions_roots_scripts_and_other_accents(source):
    font = ImageFont.truetype(FONT_PATH, 40)
    converted = symbols.normalize_text_for_font(source)
    box = symbols._layout_math_text(converted, font, FONT_PATH)
    assert box.advance > 0
    assert box.bbox[3] > box.bbox[1]
    assert any(char in symbols._ACCENT_MAP for char in converted) or converted in symbols._VULGAR_FRACTION_MAP
    image = Image.new("1", (1200, 1200), 0)
    symbols._draw_text_or_fraction(ImageDraw.Draw(image), converted, (300, 300), font, FONT_PATH)
    assert image.getbbox()


@pytest.mark.parametrize("source", ["`x̄ + (AB)⃗`", "```math\nx̄\n```", "https://example.com/x̄", "C:/math/x̄.txt", "̄x", "()̄", "(x̄"])
def test_accent_literals_and_orphan_marks_are_preserved(source):
    if source == "(x̄":
        # 2026-10-15：未闭合外层括号不妨碍其中独立 x 的重音，但不能吞掉括号。
        assert symbols.normalize_text_for_font(source).startswith("(")
    else:
        assert symbols.normalize_text_for_font(source) == source


def test_accent_budget_reuses_existing_nodes_and_preserves_new_source(monkeypatch):
    existing = symbols.register_dynamic_accent("stable-accent-base", "\u0304")
    monkeypatch.setattr(symbols, "_MAX_DYNAMIC_EXPRESSIONS", 0)
    assert symbols.register_dynamic_accent("stable-accent-base", "\u0304") == existing
    assert symbols.normalize_text_for_font("(unregistered-base)̄") == "(unregistered-base)̄"


def test_accent_private_range_and_depth_budget(monkeypatch):
    monkeypatch.setattr(symbols, "_ACCENT_MAP", {})
    monkeypatch.setattr(symbols, "_ACCENT_KEYS", {})
    monkeypatch.setattr(symbols, "_MATH_NODE_DEPTH", {})
    monkeypatch.setattr(symbols, "_DYNAMIC_ACCENT_COUNTER", 0x100000)
    monkeypatch.setattr(symbols, "_MAX_MATH_DEPTH", 4)
    inner = "x"
    for _ in range(8):
        inner = symbols.register_dynamic_accent(inner, "\u0304")
    assert max(symbols._MATH_NODE_DEPTH.values()) == 4
    assert "\u0304" in inner
    assert all(0x100000 <= ord(char) < 0x101000 for char in symbols._ACCENT_MAP)
    assert not (symbols._ACCENT_MAP.keys() & symbols._SCRIPT_MAP.keys())
    assert not (symbols._ACCENT_MAP.keys() & symbols._RADICAL_MAP.keys())
    assert not (symbols._ACCENT_MAP.keys() & symbols._VULGAR_FRACTION_MAP.keys())


@pytest.mark.parametrize("source,index", [("∛(x+1)", "³"), ("∜x", "⁴")])
def test_pasted_higher_roots_use_structural_vinculum(source, index):
    converted = symbols.normalize_text_for_font(source)
    assert symbols._RADICAL_MAP[converted][1] == index
    assert symbols.normalize_text_for_font(f"`{source}` https://example.com/{source}") == f"`{source}` https://example.com/{source}"
