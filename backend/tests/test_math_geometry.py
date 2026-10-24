# Copyright (c) 2026 Simon and Handwriting Web contributors.

"""真实墨迹的公式边界、连笔和脚标布局回归。."""

from pathlib import Path

import cv2
import numpy as np
import pytest
import symbol_fallback as symbols
from PIL import Image, ImageDraw, ImageFont

FORMULAS = [
    r"\frac{1}{2}",
    r"\frac{x²+1}{x-1}",
    r"\frac{1}{1+\frac{2}{3}}",
    r"\frac{\frac{a}{b}}{\frac{c}{d}}",
    r"\sqrt{x²+1}",
    r"\sqrt{\frac{x+1}{x-1}}",
    r"\frac{\sqrt{x+1}}{\sqrt{x-1}}",
    r"\sqrt{1+\sqrt{1+\sqrt{x}}}",
    r"\sqrt[12]{x³}",
    "aₙ₊₁=x_(A)+x^(ab)",
    r"\frac{-b+\sqrt{b²-4ac}}{2a}",
    "xₙ² + y²ₘ",
]


def font_for(name, size):
    path = Path(__file__).resolve().parents[1] / "font_assets" / name
    if not path.is_file():
        pytest.skip(f"Font not available: {name}")
    return ImageFont.truetype(str(path), size)


def rendered(source, font):
    converted = symbols.normalize_text_for_font(source)
    image = Image.new("1", (4000, 2400), 0)
    advance, height = symbols._draw_text_or_fraction(
        ImageDraw.Draw(image), converted, (256, 256), font, font.path
    )
    return converted, image, advance, height


@pytest.mark.parametrize("name", ["云烟体.ttf", "李国夫手写体.ttf"])
@pytest.mark.parametrize("size", [24, 40, 64])
@pytest.mark.parametrize("formula", FORMULAS)
def test_declared_math_bounds_contain_all_actual_ink(name, size, formula):
    # 2026-10-15：测量必须包含真实墨迹，不能只验证“能生成一张图片”。
    font = font_for(name, size)
    converted, image, advance, height = rendered(formula, font)
    declared = symbols._get_rendered_text_bbox(converted, font, font.path)
    ink = image.getbbox()
    assert ink is not None
    actual = tuple(ink[index] - 256 for index in range(4))
    assert declared[0] <= actual[0] <= actual[2] <= declared[2]
    assert declared[1] <= actual[1] <= actual[3] <= declared[3]
    assert advance >= declared[2]
    assert height == declared[3] - declared[1]
    assert symbols._measure_text_or_fraction(converted, font, font.path) == (advance, height)


@pytest.mark.parametrize("size", [24, 40, 64])
def test_radical_hook_and_roof_are_one_connected_pen_stroke(size):
    font = font_for("云烟体.ttf", size)
    _, image, _, _ = rendered(r"\sqrt{a+b+c+d}", font)
    pixels = np.asarray(image, dtype=np.uint8)
    count, _, stats, _ = cv2.connectedComponentsWithStats(pixels, connectivity=8)
    assert count > 1
    # 2026-10-15：最长横向连通域是封顶线；它必须连着根钩，具有完整根号高度。
    roof = max(stats[1:], key=lambda row: row[cv2.CC_STAT_WIDTH])
    assert roof[cv2.CC_STAT_HEIGHT] >= size * 0.45


def test_fraction_has_clear_space_above_and_below_the_bar():
    font = font_for("云烟体.ttf", 40)
    _, image, _, _ = rendered(r"\frac{123}{456}", font)
    pixels = np.asarray(image, dtype=np.uint8)
    rows = pixels.sum(axis=1)
    bar_y = int(rows.argmax())
    assert rows[bar_y] > 20
    # 2026-10-24：笔宽随所选字体变化，以完整横画范围检查两侧空隙，而非假定恒为一像素。
    bar_rows = np.flatnonzero(rows > rows.max() * 0.8)
    top, bottom = int(bar_rows.min()), int(bar_rows.max())
    assert rows[top - 1] == rows[top - 2] == 0
    assert rows[bottom + 1] == rows[bottom + 2] == 0
    assert rows[: top - 2].sum() > 0
    assert rows[bottom + 3 :].sum() > 0


def test_paired_scripts_share_one_column_and_use_handwriting_letters():
    font = font_for("云烟体.ttf", 40)
    sub, sub_image, sub_width, _ = rendered("xₙ", font)
    sup, sup_image, sup_width, _ = rendered("x²", font)
    paired, pair_image, pair_width, _ = rendered("xₙ²", font)
    assert pair_width == max(sub_width, sup_width)
    assert pair_image.getbbox()[1] == sup_image.getbbox()[1]
    assert pair_image.getbbox()[3] == sub_image.getbbox()[3]
    assert symbols._SCRIPT_MAP[sub[-1]] == (("n", False),)
    assert symbols._SCRIPT_MAP[sup[-1]] == (("2", True),)
    assert len(symbols._SCRIPT_MAP[paired[-1]]) == 2


def test_explicit_scripts_preserve_whole_expression_and_literal_identifiers():
    converted = symbols.normalize_text_for_font("x^(ab)+x_(A) file_name https://example.com/x_1")
    assert "file_name https://example.com/x_1" in converted
    scripts = [symbols._SCRIPT_MAP[ch] for ch in converted if ch in symbols._SCRIPT_MAP]
    assert (("ab", True),) in scripts
    assert (("A", False),) in scripts


def test_deep_script_input_and_external_private_use_cycles_do_not_overflow(monkeypatch):
    font = font_for("云烟体.ttf", 24)
    source = "x^(" * 600 + "n" + ")" * 600
    normalized = symbols.normalize_text_for_font(source)
    assert symbols._measure_text_or_fraction(normalized, font, font.path)[0] > 0
    char = chr(0xFD000)
    monkeypatch.setitem(symbols._SCRIPT_MAP, char, ((char, True),))
    assert symbols._measure_text_or_fraction(char, font, font.path)[0] > 0
