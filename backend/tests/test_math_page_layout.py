"""按真实像素验证数学字形分页，不依赖某个字体的具体字形。"""

import random
import pytest
from pathlib import Path
from types import SimpleNamespace

from PIL import Image, ImageFont
from handright import Template, Feature
import handright._core as real_core

from math_page_layout import install_math_page_layout


class Font:
    def __init__(self, size=24):
        self.size = size

    def font_variant(self, size):
        return Font(size)


def glyph_bbox(char, font, path=None):
    # 2026-10-15：模拟具有负边承、上伸和下伸的宽分式；墨迹是可精确检查的实心矩形。
    if char == "§":
        return (-3, -font.size, font.size * 3, font.size)
    if char == " ":
        return (0, 0, 0, 0)
    return (0, 0, font.size // 2, font.size)


def synthetic_core(original=None):
    core = SimpleNamespace(**{name: getattr(real_core, name) for name in
                             ("_check_template", "_get_font", "_draw_strikethrough", "gauss", "Feature", "LayoutError", "_WHITE")})

    def draw_char(draw, char, xy, font):
        bbox = glyph_bbox(char, font)
        if bbox != (0, 0, 0, 0):
            draw.rectangle((xy[0] + bbox[0], xy[1] + bbox[1],
                            xy[0] + bbox[2] - 1, xy[1] + bbox[3] - 1), fill=1)
        return max(font.size // 2, bbox[2] + 2)

    core._draw_page = original or (lambda *args: (_ for _ in ()).throw(AssertionError("unexpected plain delegation")))
    core._draw_char = draw_char
    install_math_page_layout(core, lambda char: char == "§", glyph_bbox)
    return core


def template(size=(230, 260), features=frozenset(), **kwargs):
    params = dict(background=Image.new("RGB", size, "white"), font=Font(), line_spacing=26,
                  fill=(0, 0, 0), left_margin=10, right_margin=10, top_margin=10, bottom_margin=10,
                  word_spacing=0, font_size_sigma=0, word_spacing_sigma=0, line_spacing_sigma=0,
                  perturb_x_sigma=0, perturb_y_sigma=0, perturb_theta_sigma=0,
                  features=features, strikethrough_probability=0)
    params.update(kwargs)
    return Template(**params)


def draft(core, text, tpl, seed=17):
    rand, start, pages, consumed = random.Random(seed), 0, [], []
    while start < len(text):
        page = real_core.Page("1", tpl.get_size(), 0, len(pages))
        end = core._draw_page(page, text, start, tpl, rand)
        assert end > start, "a page must consume input instead of looping"
        pages.append(page.image)
        consumed.append((start, end))
        start = end
        assert len(pages) <= len(text)
    return pages, consumed


def occupied_runs(image, axis):
    occupied = []
    for index in range(image.height if axis == "y" else image.width):
        box = (0, index, image.width, index + 1) if axis == "y" else (index, 0, index + 1, image.height)
        if image.crop(box).getbbox():
            occupied.append(index)
    runs = []
    for index in occupied:
        if not runs or index != runs[-1][-1] + 1:
            runs.append([index])
        else:
            runs[-1].append(index)
    return runs


def assert_inside(pages, tpl):
    for page in pages:
        left, top, right, bottom = page.getbbox()
        assert left >= tpl.get_left_margin()
        assert top >= tpl.get_top_margin()
        assert right <= page.width - tpl.get_right_margin()
        assert bottom <= page.height - tpl.get_bottom_margin()


def test_plain_text_delegates_without_consuming_randomness():
    calls = []

    def original(*args):
        calls.append(args)
        return 3

    core = synthetic_core(original)
    tpl, rand = template(), random.Random(99)
    state = rand.getstate()
    page = real_core.Page("1", tpl.get_size(), 0, 0)
    assert core._draw_page(page, "abc", 0, tpl, rand) == 3
    assert calls == [(page, "abc", 0, tpl, rand)]
    assert state == rand.getstate()


def test_tall_adjacent_lines_have_separate_ink_and_keep_margins():
    tpl = template()
    pages, consumed = draft(synthetic_core(), "§\n§\n§\n§", tpl)
    assert consumed == [(0, 7)]
    runs = occupied_runs(pages[0], "y")
    assert len(runs) == 4
    assert all(len(run) == 48 for run in runs)
    assert sum(pixel != 0 for pixel in pages[0].getdata()) == 4 * 75 * 48
    assert all(runs[index + 1][0] - runs[index][-1] >= 3 for index in range(3))
    assert_inside(pages, tpl)


def test_narrow_paper_wraps_whole_math_glyphs_and_paginates():
    tpl = template(size=(110, 140))
    pages, consumed = draft(synthetic_core(), "§" * 7, tpl)
    assert len(pages) == 4
    assert [end - start for start, end in consumed] == [2, 2, 2, 1]
    assert sum(len(occupied_runs(page, "y")) for page in pages) == 7
    assert sum(sum(pixel != 0 for pixel in page.getdata()) for page in pages) == 7 * 75 * 48
    assert_inside(pages, tpl)


def test_grid_reserves_multiple_cells_for_math_advance():
    tpl = template(size=(240, 180), features={Feature.GRID_LAYOUT})
    pages, _ = draft(synthetic_core(), "§§", tpl)
    runs = occupied_runs(pages[0], "x")
    assert len(runs) == 2
    assert runs[1][0] - runs[0][0] >= 3 * tpl.get_font().size
    assert_inside(pages, tpl)


def test_oversized_formula_scales_instead_of_clipping_or_looping():
    # 2026-10-15：可用宽度小于 8px 字号的数学字形，必须触发完整蒙版缩放兜底。
    tpl = template(size=(46, 78), left_margin=10, right_margin=10)
    pages, consumed = draft(synthetic_core(), "§\n§", tpl)
    assert consumed[-1][1] == 3
    assert_inside(pages, tpl)
    assert sum(page.getbbox() is not None for page in pages) >= 1


def test_seed_repeats_size_spacing_and_strikethrough_perturbations():
    tpl = template(size=(180, 260), font_size_sigma=4, word_spacing_sigma=3,
                   line_spacing_sigma=4, strikethrough_probability=0.5)
    first, first_consumed = draft(synthetic_core(), "§A§\n§A§\n§A§", tpl, seed=123)
    second, second_consumed = draft(synthetic_core(), "§A§\n§A§\n§A§", tpl, seed=123)
    assert first_consumed == second_consumed
    assert [image.tobytes() for image in first] == [image.tobytes() for image in second]
    assert_inside(first, tpl)


def test_installer_is_idempotent():
    core = synthetic_core()
    installed = core._draw_page
    install_math_page_layout(core, lambda char: True, glyph_bbox)
    assert core._draw_page is installed


def test_real_nested_fraction_root_ink_stays_inside_narrow_pages():
    import symbol_fallback as symbols

    font_path = Path(__file__).resolve().parents[1] / "font_assets/云烟体.ttf"
    font = ImageFont.truetype(str(font_path), 40)
    core = synthetic_core()
    core._draw_page = lambda *args: (_ for _ in ()).throw(AssertionError("math expected"))
    core._draw_char = lambda draw, char, xy, f: symbols._draw_text_or_fraction(
        draw, char, xy, f, str(font_path))[0]
    install_math_page_layout(core,
                             lambda ch: ch in symbols._VULGAR_FRACTION_MAP or ch in symbols._RADICAL_MAP,
                             symbols._get_rendered_text_bbox)
    formula = symbols.normalize_text_for_font(r"\frac{\sqrt{x²+1}}{\frac{1}{1+\sqrt{y}}}", str(font_path))
    tpl = template(size=(160, 240), font=font, line_spacing=42)
    pages, consumed = draft(core, "\n".join([formula] * 5), tpl)
    assert len(pages) >= 2
    assert consumed[-1][1] == len("\n".join([formula] * 5))
    assert_inside(pages, tpl)


@pytest.mark.parametrize("grid", [False, True])
@pytest.mark.parametrize("source", [r"\frac{abcdefgh}{2}", "√(x²+1)", "(AB)⃗"])
def test_right_aligned_math_keeps_the_formula_on_its_original_row(source, grid):
    from app import apply_right_align
    import symbol_fallback as symbols

    font_path = Path(__file__).resolve().parents[1] / "font_assets/云烟体.ttf"
    font = ImageFont.truetype(str(font_path), 40)
    tpl = template(size=(300, 400), font=font, line_spacing=60,
                   features={Feature.GRID_LAYOUT} if grid else frozenset())
    formula = symbols.normalize_text_for_font(source, str(font_path))
    plain, _ = draft(real_core, formula, tpl)
    aligned, _ = draft(real_core, apply_right_align(">>> " + formula, tpl), tpl)
    assert len(aligned) == len(plain) == 1
    plain_box, aligned_box = plain[0].getbbox(), aligned[0].getbbox()
    assert (aligned_box[1], aligned_box[3]) == (plain_box[1], plain_box[3])
    assert aligned_box[0] > plain_box[0] + 40
    assert_inside(aligned, tpl)


@pytest.mark.parametrize("features,spacing,step", [(frozenset(), -8, 6), ({Feature.GRID_LAYOUT}, -11, 13)])
def test_mixed_document_keeps_explicit_negative_spacing_for_plain_characters(features, spacing, step):
    tpl = template(word_spacing=spacing, features=features)
    pages, _ = draft(synthetic_core(), "AAAA\n§", tpl)
    first_row = occupied_runs(pages[0], "y")[0]
    plain_line = pages[0].crop((0, first_row[0], pages[0].width, first_row[-1] + 1))
    left, _, right, _ = plain_line.getbbox()
    # 2026-10-15：普通字宽 12，flow 的 advance+字距及 grid 的字号+字距均保留。
    assert right - left == 12 + 3 * step
