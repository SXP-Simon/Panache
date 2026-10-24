# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：主字体根钩轮廓、缺字回退与实际公式墨迹的连通/间隙回归."""

from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

import cv2
import math_pen
import numpy as np
import pytest
import symbol_fallback as symbols
from handright import Template
from PIL import Image, ImageDraw, ImageFont

FONTS = Path(__file__).resolve().parents[1] / "font_assets"
NAMES = ("云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷", "志莽行书")
SOURCES = (
    r"\sqrt{x}",
    r"\sqrt{a+b+c+d+e+f+g}",
    r"\sqrt{\frac{a+b}{c+d}}",
    r"\sqrt{1+\sqrt{1+\sqrt{x}}}",
    r"\frac{\sqrt{x+1}}{\sqrt{x-1}}",
    r"\sqrt[123]{\frac{x+1}{x-1}}",
)


def selected(name, size=72):
    return ImageFont.truetype(str(FONTS / f"{name}.ttf"), size)


def test_native_profiles_preserve_distinct_start_heights_and_turns():
    profiles = [math_pen.font_pen(selected(name), 72).root_profile for name in NAMES[:4]]
    assert all(profiles)
    assert len(set(profiles)) == 4
    # 2026-10-24：华阳的勾形起笔较高，文楷有较低的左侧短臂；不能统一成同一折线。
    assert profiles[1][0][1] < profiles[0][0][1] < profiles[3][0][1]
    assert all(profile[-1] == (1, 0) for profile in profiles)
    assert all(max(y for _, y in profile) == 1 for profile in profiles)


def test_missing_native_root_and_bad_outline_fall_back_safely():
    font = selected("志莽行书")
    assert not math_pen.font_pen(font, 72).root_profile
    plain = math_pen.Pen(72, 2, 0)
    assert plain.radical_path((0, 0, 33, 72), 180)[0][-1] == (180, 0)
    # 2026-10-24：占位框的列中心没有根钩谷底，不能将方框形状套入公式。
    mask = Image.new("L", (20, 30))
    ImageDraw.Draw(mask).rectangle((1, 1, 18, 28), outline=255, width=2)
    assert not math_pen._root_profile_from_mask(mask.im)
    with patch.object(font, "font_variant", side_effect=OSError("invalid native glyph")):
        assert not math_pen._sample_root_profile(font)


def test_radical_profile_changes_only_paths_not_child_positions_or_advance():
    font = selected("华阳手写体")
    text = symbols.normalize_text_for_font(r"\sqrt[12]{\frac{x+1}{x-1}}")
    sampled = symbols._layout_math_text(text, font)
    original = math_pen.font_pen

    def geometric(selected_font, size):
        return replace(original(selected_font, size), root_profile=())

    with patch.object(symbols, "font_pen", side_effect=geometric):
        fallback = symbols._layout_math_text(text, font)

    def structure(box):
        return (
            box.advance,
            box.glyph,
            box.semantic,
            tuple((structure(child), x, y) for child, x, y in box.children),
        )

    assert structure(sampled) == structure(fallback)
    assert sampled.children[0][0].paths != fallback.children[0][0].paths


def check_root_ink(box):
    for child, _, _ in box.children:
        check_root_ink(child)
    if not box.paths or len(box.paths[0][0]) < 3 or not box.children:
        return
    # 2026-10-24：此用例只有根式的多点路径；分式横线最多两个几何端点展开成九点。
    path = box.paths[0][0]
    if path[-1][0] - path[0][0] <= 0 or path[-1][1] == path[0][1]:
        return
    left, top, right, bottom = box.bbox
    size = (right - left + 8, bottom - top + 8)
    origin = (4 - left, 4 - top)
    root = Image.new("1", size)
    draw = ImageDraw.Draw(root)
    for points, thickness in box.paths:
        draw.line(
            [(x + origin[0], y + origin[1]) for x, y in points],
            fill=1,
            width=thickness,
            joint="curve",
        )
    pixels = np.asarray(root, dtype=np.uint8)
    assert cv2.connectedComponents(pixels, connectivity=8)[0] == 2
    assert root.getbbox()[0] > 0
    assert root.getbbox()[1] > 0
    assert root.getbbox()[2] < root.width
    assert root.getbbox()[3] < root.height
    for child, x, y in box.children:
        content = Image.new("1", size)
        symbols._paint_math_box(ImageDraw.Draw(content), child, (origin[0] + x, origin[1] + y))
        assert not np.logical_and(pixels, np.asarray(content)).any()


@pytest.mark.parametrize("name", NAMES)
@pytest.mark.parametrize("size", [8, 18, 72, 124])
@pytest.mark.parametrize("source", SOURCES)
@pytest.mark.parametrize("naturalness", [0, 1])
def test_adapted_roots_are_connected_and_do_not_touch_body_or_index(
    name, size, source, naturalness
):
    font = selected(name, size)
    template = Template(
        background=Image.new("RGB", (1000, 1000), "white"),
        font=font,
        perturb_x_sigma=naturalness * size * 0.04,
        perturb_y_sigma=0,
        perturb_theta_sigma=0,
    )
    with math_pen.template_pen(template):
        check_root_ink(symbols._layout_math_text(symbols.normalize_text_for_font(source), font))
