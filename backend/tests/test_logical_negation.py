# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：否定符不能随手写字体变成双点，原始证明也不能丢失逻辑记号."""

from pathlib import Path

import app
import cv2
import handright._core as core
import numpy as np
import pytest
import symbol_fallback as symbols
from PIL import Image, ImageDraw, ImageFont
from test_generation_parameters import parameters

FONT_ROOT = Path(__file__).resolve().parents[1] / "font_assets"
PROOF = """（1）证明：
① ¬(p∧¬q)　前提
② q→¬r　前提
③ r　前提
④ ¬q　②③拒取式、双重否定律
⑤ ¬p\u2228q　①德摩根律、双重否定律
⑥ ¬p　⑤④析取三段论"""


@pytest.fixture(autouse=True)
def bundled_fonts_only(monkeypatch):
    # 2026-10-24：故意把空轮廓字库放在前面，回退必须靠随包资源而非本机字体成功。
    paths = [
        FONT_ROOT / f"{name}.ttf" for name in ("云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷")
    ]
    monkeypatch.setattr(
        symbols,
        "_FALLBACK_FONTS_POOL",
        [(str(path), symbols._get_font_cmap(str(path))) for path in paths],
    )
    symbols._CHAR_FALLBACK_CACHE.clear()
    symbols._get_char_glyph_and_bbox_cached.cache_clear()
    yield
    symbols._CHAR_FALLBACK_CACHE.clear()
    symbols._get_char_glyph_and_bbox_cached.cache_clear()


@pytest.mark.parametrize("name", ["云烟体", "华阳手写体", "霞鹜文楷"])
@pytest.mark.parametrize("size", [18, 36, 72, 124])
def test_negation_is_connected_bar_and_right_leg_in_actual_handright_path(name, size):
    font_path = str(FONT_ROOT / f"{name}.ttf")
    font = ImageFont.truetype(font_path, size)
    image = Image.new("1", (size * 4, size * 4))
    advance = core._draw_char(ImageDraw.Draw(image), "¬", (size, size), font)
    bounds = image.getbbox()
    assert advance > 0
    assert bounds is not None
    mask = np.asarray(image.crop(bounds), dtype=np.uint8)
    components, _ = cv2.connectedComponents(mask, connectivity=8)
    assert components == 2, "否定符必须是一条连通折线，不能回退为两个点"
    assert np.max(mask.sum(axis=1)) >= mask.shape[1] * 0.7
    assert np.max(mask[:, mask.shape[1] // 2 :].sum(axis=0)) >= mask.shape[0] * 0.7
    measured = symbols.math_text_bbox("¬", font, font_path)
    assert measured[0] + size <= bounds[0] < bounds[2] <= measured[2] + size
    assert measured[1] + size <= bounds[1] < bounds[3] <= measured[3] + size
    if name != "霞鹜文楷":
        chosen, _, _ = symbols._get_char_glyph_and_bbox("¬", font, font_path)
        assert Path(chosen.path).name == "霞鹜文楷.ttf"


@pytest.mark.parametrize("name", ["云烟体", "华阳手写体", "霞鹜文楷"])
@pytest.mark.parametrize("style", ["standard", "homework"])
def test_original_proof_keeps_all_negations_and_renders_on_ruled_paper(name, style):
    font_path = FONT_ROOT / f"{name}.ttf"
    normalized = symbols.normalize_text_for_font(PROOF, str(font_path))
    assert PROOF.count("¬") == normalized.count("¬") == 6
    assert all(marker in normalized for marker in "①②③④⑤⑥")
    values = parameters(
        layout_style=style,
        width="1400",
        height="1250",
        font_size="54",
        line_spacing="112",
        top_margin="40",
        bottom_margin="60",
        left_margin="90",
        right_margin="90",
        isUnderlined="true",
        fill="(28,48,35,255)",
    ).model_dump(exclude_none=True)
    background = app._background_for(values, None)
    template = app._template_for(values, background, ImageFont.truetype(str(font_path), 54))
    pages = list(app.handwrite_with_page_breaks(PROOF, template, str(font_path)))
    assert len(pages) == 1
    delta = np.any(np.asarray(pages[0].convert("RGB")) != np.asarray(background), axis=2)
    ys, xs = np.nonzero(delta)
    assert len(xs) > 1500
    assert xs.min() >= template.get_left_margin()
    assert xs.max() < pages[0].width - template.get_right_margin()
    assert ys.min() >= template.get_top_margin()
    assert ys.max() < pages[0].height - template.get_bottom_margin()
