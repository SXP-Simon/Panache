# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：多字体笔触、语义拓扑、自然度隔离与嵌套公式的实际墨迹回归."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import app
import cv2
import math_pen
import numpy as np
import pytest
import symbol_fallback as symbols
from PIL import Image, ImageDraw, ImageFont
from test_generation_parameters import parameters

FONTS = Path(__file__).resolve().parents[1] / "font_assets"


def selected(name, size):
    return ImageFont.truetype(str(FONTS / f"{name}.ttf"), size)


def raster(text, font):
    box = symbols._layout_math_text(text, font)
    left, top, right, bottom = box.bbox
    image = Image.new("1", (right - left + 8, bottom - top + 8))
    symbols._paint_math_box(ImageDraw.Draw(image), box, (4 - left, 4 - top))
    assert image.getbbox() is not None
    assert image.getbbox()[0] > 0
    assert image.getbbox()[1] > 0
    assert image.getbbox()[2] < image.width
    assert image.getbbox()[3] < image.height
    return box, image


@pytest.mark.parametrize("name", ["云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷"])
@pytest.mark.parametrize("size", [18, 36, 72, 124])
@pytest.mark.parametrize("strength", [0, 1, 100])
def test_symbols_keep_direction_and_separate_semantic_strokes(name, size, strength):
    font = selected(name, size)
    tpl = app._template_for(
        parameters(perturb_x_sigma=str(strength), perturb_y_sigma=str(strength)).model_dump(),
        Image.new("RGB", (1000, 1000), "white"),
        font,
    )
    with math_pen.template_pen(tpl):
        for char in sorted(math_pen.SYMBOLS):
            box, image = raster(char, font)
            box = box.children[0][0]
            components, _ = cv2.connectedComponents(
                np.asarray(image, dtype=np.uint8), connectivity=8
            )
            assert components == (3 if char in "≤≥" else 2), (name, size, strength, char)
            assert box.advance > 0
            assert box.glyph is None
            assert box.semantic == char
            if char in "→←↔⇒⇐⇔":
                assert len(box.paths) == (2 if char in "→←" else 4 if char == "⇔" else 3)
            if char in "≤≥":
                assert len(box.paths) == 2
            if char == "¬":
                points = box.paths[0][0]
                assert points[-1][1] > points[0][1]
                assert points[-1][0] > points[0][0]


def test_font_stroke_samples_change_weight_and_slant_without_fallback():
    pens = [
        math_pen.font_pen(selected(name, 124), 124) for name in ("云烟体", "华阳手写体", "霞鹜文楷")
    ]
    assert len({(pen.width, pen.slant) for pen in pens}) > 1
    assert all(1 <= pen.width <= 7 and abs(pen.slant) <= 0.18 for pen in pens)


def test_naturalness_is_bounded_repeatable_and_request_local():
    font = selected("云烟体", 124)
    pen = math_pen.font_pen(font, 124)
    points = ((0, 40), (240, 40))
    plain = pen.path(points)

    def draw(strength):
        tpl = app._template_for(
            parameters(perturb_x_sigma=str(strength)).model_dump(),
            Image.new("RGB", (1000, 1000), "white"),
            font,
        )
        with math_pen.template_pen(tpl):
            return pen.path(points)

    with ThreadPoolExecutor(max_workers=4) as executor:
        paths = list(executor.map(draw, [0, 100, 0, 100]))
    assert paths[0] == paths[2] == plain
    assert paths[1] == paths[3] != plain
    assert paths[1][0][0] == points[0]
    assert paths[1][0][-1] == points[-1]
    assert max(abs(y - 40) for _, y in paths[1][0]) <= 2
    assert pen.path(points) == plain


@pytest.mark.parametrize("name", ["云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷"])
def test_nested_fraction_radical_keep_children_and_use_current_pen(name):
    font = selected(name, 72)
    prepared = symbols.normalize_text_for_font("√((a+1)/(b+2)) ≤ (x²+1)/(y+2)")
    plain_box, _ = raster(prepared, font)
    tpl = app._template_for(
        parameters(perturb_theta_sigma="100").model_dump(),
        Image.new("RGB", (1200, 1200), "white"),
        font,
    )
    with math_pen.template_pen(tpl):
        natural_box, _ = raster(prepared, font)
    assert plain_box.advance == natural_box.advance

    def structure(box):
        return (
            box.glyph,
            box.semantic,
            tuple((structure(child), x, y) for child, x, y in box.children),
        )

    assert structure(plain_box) == structure(natural_box)

    # 2026-10-24：上层公式的文字位置与语法不受弧线控制影响，分母也不能贴上分数横线。
    def fractions(box):
        if len(box.children) == 2 and len(box.paths) == 1:
            (num, _, ny), (den, _, dy) = box.children
            assert num.bbox[3] + ny < den.bbox[1] + dy
        for child, _, _ in box.children:
            fractions(child)

    fractions(natural_box)
