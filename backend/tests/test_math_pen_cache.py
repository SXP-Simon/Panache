# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：数学笔触缓存复用采样，但不能延长上传字体的存活时间."""

import gc
import io
import weakref
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

import math_pen
from PIL import ImageFont


def uploaded_font():
    path = Path(__file__).resolve().parents[1] / "font_assets" / "云烟体.ttf"
    return ImageFont.truetype(io.BytesIO(path.read_bytes()), 42)


def test_pen_cache_releases_uploaded_font_while_returned_pen_stays_alive():
    font = uploaded_font()
    reference = weakref.ref(font)
    pen = math_pen.font_pen(font, 42)
    del font
    gc.collect()
    assert reference() is None
    assert pen.size == 42
    assert pen.path(((0, 0), (42, 0)))[1] == pen.width


def test_pen_cache_reuses_sampling_for_the_same_live_font():
    font = uploaded_font()
    with patch.object(font, "getmask", wraps=font.getmask) as getmask:
        first = math_pen.font_pen(font, 42)
        with ThreadPoolExecutor(max_workers=4) as executor:
            repeated = list(executor.map(lambda _: math_pen.font_pen(font, 42), range(8)))
        assert all(pen is first for pen in repeated)
        assert getmask.call_count == 2


def test_pen_cache_does_not_reuse_a_previous_upload_by_size_alone():
    first_font, second_font = uploaded_font(), uploaded_font()
    first = math_pen.font_pen(first_font, 42)
    with patch.object(second_font, "getmask", wraps=second_font.getmask) as getmask:
        second = math_pen.font_pen(second_font, 42)
    assert second == first
    assert second is not first
    assert getmask.call_count == 2
