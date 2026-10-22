# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-22：理工作业实际墨迹回归，包含有 cmap 但没有轮廓的字体占位."""

from pathlib import Path

import pytest
import symbol_fallback as symbols
from PIL import Image, ImageDraw, ImageFont

FONT_ROOT = Path(__file__).resolve().parents[1] / "font_assets"
COURSE_SYMBOLS = "ϑϕϖϱϵϰℒℱℋℰℬℐℛℳΩμ°∮∯∰∬∭ℏ∠⊕⊗⊙ℵℓ≅≃≜∴∵"
CALLIGRAPHIC = (
    "\U0001d49c\u212c\U0001d49e\U0001d49f\u2130\u2131\U0001d4a2\u210b\u2110"
    "\U0001d4a5\U0001d4a6\u2112\u2133\U0001d4a9\U0001d4aa\U0001d4ab\U0001d4ac"
    "\u211b\U0001d4ae\U0001d4af\U0001d4b0\U0001d4b1\U0001d4b2\U0001d4b3\U0001d4b4\U0001d4b5"
)


@pytest.fixture
def bundled_fallbacks(monkeypatch):
    # 2026-10-22：不能借助本机系统字体让 CI 假通过；首个字库故意包含空占位。
    paths = [
        str(FONT_ROOT / name) for name in ("李国夫手写体.ttf", "霞鹜文楷.ttf", "悠哉手写体.ttf")
    ]
    paths.append(str(FONT_ROOT / "math/PanacheMathScript.ttf"))
    monkeypatch.setattr(
        symbols,
        "_FALLBACK_FONTS_POOL",
        [(path, symbols._get_font_cmap(path)) for path in paths],
    )
    symbols._CHAR_FALLBACK_CACHE.clear()
    symbols._get_char_glyph_and_bbox_cached.cache_clear()
    yield
    symbols._CHAR_FALLBACK_CACHE.clear()
    symbols._get_char_glyph_and_bbox_cached.cache_clear()


@pytest.mark.usefixtures("bundled_fallbacks")
@pytest.mark.parametrize("name", ["云烟体.ttf", "李国夫手写体.ttf"])
@pytest.mark.parametrize("size", [24, 40, 70])
@pytest.mark.parametrize("symbol", COURSE_SYMBOLS + CALLIGRAPHIC)
def test_course_symbols_resolve_to_real_ink_without_system_fonts(name, size, symbol):
    path = str(FONT_ROOT / name)
    selected = ImageFont.truetype(path, size)
    chosen, bounds, advance = symbols._get_char_glyph_and_bbox(symbol, selected, path)
    assert ord(symbol) in symbols._get_font_cmap(chosen.path)
    assert chosen.getmask(symbol).getbbox() is not None
    image = Image.new("1", (size * 4, size * 4))
    symbols._draw_text_or_fraction(ImageDraw.Draw(image), symbol, (size, size), selected, path)
    assert image.getbbox() is not None
    assert advance > 0
    assert bounds[3] > bounds[1]


@pytest.mark.usefixtures("bundled_fallbacks")
def test_variant_greek_table_cells_keep_their_ink_and_primary_handwriting():
    path = str(FONT_ROOT / "云烟体.ttf")
    font = ImageFont.truetype(path, 40)
    # 2026-10-22：这些变体用于电磁场、概率密度及误差分析，不能在表格里变成空单元格。
    table = symbols.normalize_text_for_font("⟦ ϑ | ϕ | \u03f1 ; ── ; ϵ | Ω | \u2112 ⟧")
    box = symbols._layout_math_text(table, font, path)
    cells = box.children[0][0].children
    assert len(cells) == 6
    for cell, _, _ in cells:
        image = Image.new("1", (200, 200))
        symbols._paint_math_box(ImageDraw.Draw(image), cell, (60, 60))
        assert image.getbbox() is not None
    chosen, _, _ = symbols._get_char_glyph_and_bbox("中", font, path)
    assert Path(chosen.path) == Path(path)
