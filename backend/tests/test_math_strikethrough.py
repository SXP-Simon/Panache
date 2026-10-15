"""数学行的错字、删除线及后续正确字必须分别可见。"""

import random
from types import SimpleNamespace

import pytest
from PIL import Image
from handright import Template
import handright._core as real_core

from math_page_layout import install_math_page_layout


class Font:
    def __init__(self, size=24):
        self.size = size

    def font_variant(self, size):
        return Font(size)


def make_core():
    core = SimpleNamespace(**{name: getattr(real_core, name) for name in
                             ("_check_template", "_get_font", "gauss", "Feature", "LayoutError", "_WHITE")})
    core._draw_page = lambda *args: (_ for _ in ()).throw(AssertionError("math layout expected"))

    def draw_char(draw, char, xy, font):
        draw.rectangle((xy[0], xy[1], xy[0] + font.size - 1, xy[1] + font.size - 1), fill=1)
        return font.size

    core._draw_char = draw_char
    core._draw_strikethrough = lambda draw, x, y, tpl, rand: draw.line(
        (x, y, x + tpl.get_font().size - 1, y + tpl.get_font().size - 1), fill=1, width=2)
    install_math_page_layout(core, lambda char: char == "§",
                             lambda char, font, path: (0, 0, font.size, font.size))
    return core


def template(size=(180, 160), **kwargs):
    params = dict(background=Image.new("RGB", size, "white"), font=Font(), line_spacing=30,
                  fill=(0, 0, 0), left_margin=10, right_margin=10, top_margin=10, bottom_margin=10,
                  word_spacing=0, font_size_sigma=0, word_spacing_sigma=0, line_spacing_sigma=0,
                  perturb_x_sigma=0, perturb_y_sigma=0, perturb_theta_sigma=0, strikethrough_probability=1)
    params.update(kwargs)
    return Template(**params)


def draft(text, tpl, seed=7, core=None):
    core = core or make_core()
    rand, start, pages, consumed = random.Random(seed), 0, [], []
    while start < len(text):
        page = real_core.Page("1", tpl.get_size(), 0, len(pages))
        end = core._draw_page(page, text, start, tpl, rand)
        assert end > start
        pages.append(page.image)
        consumed.append(end - start)
        start = end
        assert len(pages) <= len(text)
    return pages, consumed


def runs(image, axis="x"):
    occupied, result = [], []
    for index in range(image.width if axis == "x" else image.height):
        box = (index, 0, index + 1, image.height) if axis == "x" else (0, index, image.width, index + 1)
        if image.crop(box).getbbox():
            occupied.append(index)
    for index in occupied:
        if not result or index != result[-1][-1] + 1:
            result.append([index])
        else:
            result[-1].append(index)
    return result


def test_struck_wrong_glyph_precedes_intact_correct_glyph():
    pages, consumed = draft("§", template())
    assert consumed == [1]
    columns = runs(pages[0])
    assert len(columns) == 2
    assert len(columns[1]) == 24
    assert columns[1][0] > columns[0][-1] + 1
    correct = pages[0].crop((columns[1][0], 0, columns[1][-1] + 1, pages[0].height))
    assert sum(pixel != 0 for pixel in correct.getdata()) == 24 * 24


def test_pair_advance_includes_wrong_and_correct_glyphs():
    pages, consumed = draft("§§", template(size=(180, 160), word_spacing=3))
    assert consumed == [2]
    assert len(runs(pages[0])) == 4
    assert pages[0].getbbox()[2] - pages[0].getbbox()[0] >= 4 * 24


def test_narrow_page_keeps_corrected_pairs_whole_across_pages():
    tpl = template(size=(100, 140))
    pages, consumed = draft("§" * 8, tpl)
    assert len(pages) > 1
    assert sum(consumed) == 8
    row_count = 0
    for page in pages:
        left, top, right, bottom = page.getbbox()
        assert 10 <= left < right <= 90
        assert 10 <= top < bottom <= 130
        rows = runs(page, "y")
        row_count += len(rows)
        for row in rows:
            assert len(runs(page.crop((0, row[0], page.width, row[-1] + 1)))) == 2
    assert row_count == 8


def test_corrected_pair_seed_repeats_with_spacing_and_size_perturbations():
    tpl = template(size=(130, 180), font_size_sigma=3, line_spacing_sigma=2, word_spacing_sigma=2)
    first, first_consumed = draft("§" * 9, tpl, seed=44)
    second, second_consumed = draft("§" * 9, tpl, seed=44)
    assert first_consumed == second_consumed
    assert [page.tobytes() for page in first] == [page.tobytes() for page in second]


def test_very_narrow_page_scales_entire_pair_and_finishes():
    pages, consumed = draft("§§", template(size=(46, 90)))
    assert sum(consumed) == 2
    for page in pages:
        left, top, right, bottom = page.getbbox()
        assert 10 <= left < right <= 36
        assert 10 <= top < bottom <= 80


@pytest.mark.parametrize("parameters", [
    {"strikethrough_length_sigma": 10**9, "strikethrough_width": 2},
    {"strikethrough_length_sigma": 0, "strikethrough_width": 10**9,
     "strikethrough_width_sigma": 10**9},
])
def test_extreme_strikethrough_parameters_allocate_only_page_sized_masks(monkeypatch, parameters):
    # 2026-10-15：在 Image.new 之前断言，不能先分配十亿像素删除线再缩回纸张。
    tpl = template(size=(100, 140), strikethrough_angle_sigma=0, **parameters)
    original_new = Image.new
    allocated = []

    def guarded_new(mode, size, color=0):
        allocated.append(size)
        assert 0 < size[0] <= 100 and 0 < size[1] <= 140
        return original_new(mode, size, color)

    monkeypatch.setattr("math_page_layout.Image.new", guarded_new)
    core = make_core()
    core._draw_strikethrough = real_core._draw_strikethrough
    pages, consumed = draft("§§", tpl, seed=7, core=core)
    assert sum(consumed) == 2
    assert allocated
    assert all(page.getbbox() is not None for page in pages)

