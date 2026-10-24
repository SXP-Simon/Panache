# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：原生根钩墨迹优先、缺字补绘与实际公式的连通/间隙回归."""

import gc
import io
import weakref
from pathlib import Path
from unittest.mock import patch

import cv2
import math_pen
import numpy as np
import pytest
import radical_ink
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


@pytest.mark.parametrize("name", NAMES[:4])
def test_primary_hook_keeps_actual_pixels_and_weight_variation(name):
    font = selected(name)
    ink = radical_ink.native_root(font)
    native = symbols._primary_mask("√", font)
    assert ink is not None
    assert native is not None
    assert ink.hook.size == native.size
    assert ink.hook.tobytes() == native.tobytes()
    assert radical_ink.fit_hook(ink, 72, round(72 * 0.58)) is ink.hook
    outer = symbols._layout_math_text(symbols.normalize_text_for_font(r"\sqrt{x}"), font)
    root = outer.children[0][0]
    assert root.semantic == "√"
    assert not root.paths
    actual_hook = next(child.bitmap for child, _, _ in root.children if child.bitmap is ink.hook)
    assert actual_hook.tobytes() == native.tobytes()


def test_wide_native_hook_is_not_squeezed_to_the_old_common_stem_width():
    font = selected("李国夫手写体")
    ink = radical_ink.native_root(font)
    assert ink is not None
    outer = symbols._layout_math_text(symbols.normalize_text_for_font(r"\sqrt{x}"), font)
    body, hook = outer.children[0][0].children[:2]
    assert hook[0].bitmap is ink.hook
    assert ink.hook.width > 72 * 0.46
    assert body[1] + body[0].bbox[0] > hook[1] + hook[0].bbox[2]


def test_roof_preserves_native_caps_instead_of_stretching_them():
    ink = radical_ink.native_root(selected("云烟体"))
    assert ink is not None
    assert ink.bar is not None
    bar = ink.bar
    extended = radical_ink._extend_bar(bar, 600, bar.height)
    cap = bar.width // 3
    assert (
        extended.crop((0, 0, cap, bar.height)).tobytes()
        == bar.crop((0, 0, cap, bar.height)).tobytes()
    )
    assert (
        extended.crop((600 - cap, 0, 600, bar.height)).tobytes()
        == bar.crop((bar.width - cap, 0, bar.width, bar.height)).tobytes()
    )


def test_uploaded_font_weak_cache_releases_font_and_reuses_live_resources():
    font = ImageFont.truetype(io.BytesIO((FONTS / "云烟体.ttf").read_bytes()), 72)
    reference = weakref.ref(font)
    ink = radical_ink.native_root(font)
    with patch.object(radical_ink, "_sample", side_effect=AssertionError("resampled live font")):
        assert radical_ink.native_root(font) is ink
    del font
    gc.collect()
    assert reference() is None
    assert ink is not None
    assert ink.hook.getbbox() is not None


def test_missing_native_root_and_bad_outline_fall_back_safely():
    font = selected("志莽行书")
    assert radical_ink.native_root(font) is None
    mask = Image.new("1", (20, 30))
    ImageDraw.Draw(mask).rectangle((1, 1, 18, 28), outline=1, width=2)
    assert not radical_ink._valid_hook(mask)
    pen = math_pen.Pen(72, 2, 0)
    path, _ = pen.radical_path((0, 0, 33, 72), 180)
    roof = [(x, y) for x, y in path if x >= 31]
    assert len({y for _, y in roof}) > 1
    assert max(y for _, y in roof) <= 3


def test_native_masks_and_oversized_roof_have_allocation_budgets():
    ink = radical_ink.native_root(selected("云烟体"))
    assert ink is not None
    with patch.object(radical_ink.Image, "new", side_effect=AssertionError("unbounded bitmap")):
        assert radical_ink.fit_hook(ink, 72, 100000) is None
        assert radical_ink.roof_mask(ink, 100000, math_pen.Pen(72, 2, 0)) is None


def test_quiet_and_natural_radicals_keep_content_and_index_positions():
    font = selected("华阳手写体")
    text = symbols.normalize_text_for_font(r"\sqrt[12]{\frac{x+1}{x-1}}")
    quiet = symbols._layout_math_text(text, font).children[0][0]
    template = Template(background=Image.new("RGB", (1000, 1000)), font=font, perturb_x_sigma=100)
    with math_pen.template_pen(template):
        natural = symbols._layout_math_text(text, font).children[0][0]
    assert quiet.advance == natural.advance
    assert [(child.glyph, x, y) for child, x, y in quiet.children] == [
        (child.glyph, x, y) for child, x, y in natural.children
    ]


def check_root_ink(box):
    for child, _, _ in box.children:
        check_root_ink(child)
    native = box.semantic == "√"
    fallback = bool(box.paths and box.children and box.paths[0][0][-1][1] != box.paths[0][0][0][1])
    if not native and not fallback:
        return
    left, top, right, bottom = box.bbox
    size = (right - left + 8, bottom - top + 8)
    origin = (4 - left, 4 - top)
    root = Image.new("1", size)
    draw = ImageDraw.Draw(root)
    content = []
    for child, x, y in box.children:
        if native and child.bitmap is not None:
            symbols._paint_math_box(draw, child, (origin[0] + x, origin[1] + y))
        else:
            content.append((child, x, y))
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
    for child, x, y in content:
        glyph = Image.new("1", size)
        symbols._paint_math_box(ImageDraw.Draw(glyph), child, (origin[0] + x, origin[1] + y))
        assert not np.logical_and(pixels, np.asarray(glyph)).any()


@pytest.mark.parametrize("name", NAMES)
@pytest.mark.parametrize("size", [8, 18, 72, 124])
@pytest.mark.parametrize("source", SOURCES)
@pytest.mark.parametrize("naturalness", [0, 1])
def test_roots_remain_connected_and_do_not_touch_body_or_index(name, size, source, naturalness):
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
