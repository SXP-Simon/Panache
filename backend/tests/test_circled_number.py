# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：圈号使用所选手写数字，外圈不碰墨迹，行首和引用保持原字符."""

import gc
import io
import weakref
from pathlib import Path

import app
import cv2
import numpy as np
import pytest
import symbol_fallback as symbols
from circled_number import circled_number, native_circled_available
from math_pen import template_pen
from PIL import Image, ImageDraw, ImageFont
from test_generation_parameters import parameters

FONTS = Path(__file__).resolve().parents[1] / "font_assets"
MARKERS = "⓪①⑥⑨⑩⑲⑳㉑㉟㊱㊿"


@pytest.mark.parametrize("char", ["a", "1", "⑴", "Ⓐ", "❶", "㊀"])
def test_unrelated_characters_are_not_reinterpreted(char):
    assert circled_number(char) is None


def test_all_number_ranges_preserve_original_values():
    chars = "⓪" + "".join(chr(c) for c in range(0x2460, 0x2474))
    chars += "".join(chr(c) for c in range(0x3251, 0x3260))
    chars += "".join(chr(c) for c in range(0x32B1, 0x32C0))
    assert [circled_number(c) for c in chars] == [str(i) for i in range(51)]
    assert symbols.normalize_text_for_font(chars) == chars


@pytest.mark.parametrize("name", ["云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷", "志莽行书"])
@pytest.mark.parametrize("size", [18, 36, 72, 124])
@pytest.mark.parametrize("naturalness", [0, 100])
def test_handwritten_digits_are_enclosed_with_clearance_and_one_closed_loop(
    name, size, naturalness, monkeypatch
):
    monkeypatch.setattr(symbols, "native_circled_available", lambda *_: False)
    font = ImageFont.truetype(str(FONTS / f"{name}.ttf"), size)
    tpl = app._template_for(
        parameters(perturb_x_sigma=str(naturalness)).model_dump(),
        Image.new("RGB", (800, 800)),
        font,
    )
    with template_pen(tpl):
        for marker in MARKERS:
            box = symbols._layout_math_text(marker, font).children[0][0]
            assert box.semantic == marker
            assert symbols.is_math_glyph(marker)
            assert box.advance >= box.bbox[2]
            child, dx, dy = box.children[0]
            small = font.font_variant(size=max(1, round(size * 0.66)))
            native = symbols._primary_mask(circled_number(marker), small)
            assert child.bitmap.tobytes() == native.tobytes()
            left, top, right, bottom = box.bbox
            outline = Image.new("1", (right - left + 8, bottom - top + 8))
            for points, thickness in box.paths:
                ImageDraw.Draw(outline).line(
                    [(x - left + 4, y - top + 4) for x, y in points],
                    fill=1,
                    width=thickness,
                    joint="curve",
                )
            ink = np.asarray(outline, dtype=np.uint8)
            count, _ = cv2.connectedComponents(ink, connectivity=8)
            assert count == 2
            _, spaces = cv2.connectedComponents(1 - ink, connectivity=4)
            center = spaces[ink.shape[0] // 2, ink.shape[1] // 2]
            assert center != 0
            assert center != spaces[0, 0], "圈内空间不能与外部连通"
            distance = cv2.distanceTransform(1 - ink, cv2.DIST_L2, 3)
            for y, row in enumerate(np.asarray(child.bitmap)):
                for x in np.flatnonzero(row):
                    assert distance[dy - top + 4 + y, dx - left + 4 + x] >= 1.9


def test_uploaded_font_digits_are_not_replaced_by_a_file_based_fallback():
    font = ImageFont.truetype(io.BytesIO((FONTS / "云烟体.ttf").read_bytes()), 72)
    box = symbols._layout_math_text("㉑", font).children[0][0]
    child = box.children[0][0]
    expected = symbols._primary_mask("21", font.font_variant(size=48))
    assert child.bitmap.tobytes() == expected.tobytes()


def test_missing_circles_have_a_visibly_oval_silhouette_without_naturalness():
    font = ImageFont.truetype(str(FONTS / "华阳手写体.ttf"), 72)
    for marker in "⓪㉑㉟㊱㊿":
        box = symbols._layout_math_text(marker, font).children[0][0]
        points = np.asarray(box.paths[0][0], dtype=float)
        axes = np.linalg.eigvalsh(np.cov(points.T))
        assert (axes[-1] / axes[0]) ** 0.5 > 1.18
        assert tuple(points[0]) == tuple(points[-1])


@pytest.mark.parametrize("name", ["云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷"])
@pytest.mark.parametrize("size", [18, 72, 124])
def test_primary_native_circles_remain_pixel_identical(name, size):
    font = ImageFont.truetype(str(FONTS / f"{name}.ttf"), size)
    for marker in "①②③④⑤⑥":
        box = symbols._layout_math_text(marker, font).children[0][0]
        assert box.glyph == marker
        assert box.font is font
        assert not box.paths
        assert not box.children
        actual = Image.new("1", (size * 4, size * 4))
        expected = actual.copy()
        symbols._paint_math_box(ImageDraw.Draw(actual), box, (size, size))
        ImageDraw.Draw(expected).text((size, size), marker, font=font, fill=1)
        assert actual.tobytes() == expected.tobytes()


def test_primary_font_without_circled_glyphs_uses_fallback():
    font = ImageFont.truetype(str(FONTS / "志莽行书.ttf"), 72)
    assert not native_circled_available(font, "①")
    box = symbols._layout_math_text("①", font).children[0][0]
    assert box.glyph is None
    assert box.children
    assert box.paths
    assert box.semantic == "①"


def test_real_missing_circle_uses_fallback_and_upload_lookup_does_not_hold_font():
    font = ImageFont.truetype(io.BytesIO((FONTS / "云烟体.ttf").read_bytes()), 72)
    assert native_circled_available(font, "①")
    assert not native_circled_available(font, "㉑")
    box = symbols._layout_math_text("㉑", font).children[0][0]
    assert box.glyph is None
    assert box.children
    assert box.paths
    assert box.bbox[3] <= 72
    ref = weakref.ref(font)
    del font
    gc.collect()
    assert ref() is None


def test_inline_references_have_the_same_semantics_as_the_leading_marker():
    font = ImageFont.truetype(str(FONTS / "华阳手写体.ttf"), 62)
    source = "④ ¬p　①③拒取式\n⑥ r　⑤双重否定律"
    text = symbols.normalize_text_for_font(source)
    assert text.count("①") == text.count("③") == text.count("④") == 1
    box = symbols._layout_math_text(text, font)
    assert [
        child.semantic
        for child, _, _ in box.children
        if child.semantic is not None and circled_number(child.semantic) is not None
    ] == [
        "④",
        "①",
        "③",
        "⑥",
        "⑤",
    ]
