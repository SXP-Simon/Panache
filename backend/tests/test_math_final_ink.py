# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：检查最终导出像素，不能只验证扰动前的表格草稿。."""

import io
from multiprocessing import get_context

import pytest
import symbol_fallback as symbols
from handright import handwrite
from PIL import Image, ImageChops, ImageFont
from test_math_page_layout import draft, real_core, template
from test_math_table import FONT, X

SNN = (
    "⟦ 点对 | 互为近邻 | 共同近邻 | SNN ; ── ; "
    "(1,2) | 否 | {3,4} | 0 ; ── ; (1,3) | 否 | {4} | 0 ; ── ; "
    "(1,4) | 是 | {3} | 1 ; ── ; (2,3) | 是 | {4} | 1 ; ── ; "
    "(2,4) | 否 | {3} | 0 ; ── ; (3,4) | 是 | ∅ | 0 ⟧"
)
SOURCES = [
    SNN,
    X,
    "⟦ a ┆ (1)/(2) ; ╌╌ ; √(3) ┆ b ⟧",
    "(x+1)/(x-1)",
    "⟦ pmatrix: 1  2 ; 3  4 ⟧",
    r"\begin{circuitikz}\draw (0,0) to[R,l=$R_1$] (3,0) to[C] (3,2);\end{circuitikz}",
]


def configured(size=(900, 1000), **kwargs):
    return template(
        size=size,
        font=ImageFont.truetype(str(FONT), 42),
        line_spacing=65,
        ink_depth_sigma=0,
        **kwargs,
    )


@pytest.mark.parametrize("source", SOURCES)
@pytest.mark.parametrize("seed", [0, 17, 42])
@pytest.mark.parametrize("size", [(900, 1000), (250, 300)])
def test_final_structures_preserve_all_cells_and_rules_under_strong_perturbation(
    source, seed, size
):
    text = symbols.normalize_text_for_font(source)
    reference = list(handwrite(text, configured(size), seed=seed))
    actual = list(
        handwrite(
            text,
            configured(size, perturb_x_sigma=12, perturb_y_sigma=12, perturb_theta_sigma=0.15),
            seed=seed,
        )
    )
    assert len(actual) == len(reference) == 1
    assert actual[0].tobytes() == reference[0].tobytes()
    data = io.BytesIO()
    actual[0].save(data, format="PNG")
    data.seek(0)
    assert Image.open(data).tobytes() == reference[0].tobytes()


def test_mixed_prose_keeps_handwriting_variation_and_tables_stay_intact():
    text = symbols.normalize_text_for_font("前文测试\n" + SNN + "\n后文测试")
    tpl = configured()
    quiet = next(iter(handwrite(text, tpl, seed=17)))
    noisy = next(
        iter(
            handwrite(
                text,
                configured(perturb_x_sigma=4, perturb_y_sigma=4, perturb_theta_sigma=0.08),
                seed=17,
            )
        )
    )
    # 表格占中部，正文位于其上下；正文的随机手写效果不能被整页关掉。
    pixels = quiet.convert("L")
    rules = [
        y
        for y in range(quiet.height)
        if sum(value < 128 for value in pixels.crop((0, y, quiet.width, y + 1)).getdata()) > 500
    ]
    assert len(rules) >= 8
    bounds = (0, min(rules), quiet.width, max(rules) + 1)
    assert quiet.crop(bounds).tobytes() == noisy.crop(bounds).tobytes()
    assert ImageChops.difference(quiet, noisy).getbbox() is not None


def test_multiple_pages_backgrounds_and_process_mapper_keep_structures():
    text = symbols.normalize_text_for_font("\n".join([SNN] * 3))
    templates = [
        configured((300, 340), background=Image.new("RGB", (300, 340), color), fill=(20, 60, 90))
        for color in ("white", "#f0f8ef")
    ]
    expected = list(handwrite(text, templates, seed=17))
    assert len(expected) >= 2
    with get_context("spawn").Pool(2) as pool:
        actual = list(handwrite(text, templates, seed=17, mapper=pool.map))
    assert [page.tobytes() for page in actual] == [page.tobytes() for page in expected]
    assert actual[0].getpixel((0, 0)) != actual[1].getpixel((0, 0))


def test_final_renderer_does_not_mutate_draft_and_preserves_ink_color():
    text = symbols.normalize_text_for_font(X)
    tpl = configured(fill=(20, 70, 100, 230), background=Image.new("RGBA", (900, 1000), "white"))
    pages, _ = draft(real_core, text, tpl)
    renderer = real_core._Renderer([tpl], seed=17)
    page = real_core.Page("1", tpl.get_size(), 0, 0)
    page.image = pages[0]
    before = page.image.tobytes()
    first, second = renderer(page), renderer(page)
    assert first.tobytes() == second.tobytes()
    assert page.image.tobytes() == before
    assert (20, 70, 100, 230) in set(first.getdata())
