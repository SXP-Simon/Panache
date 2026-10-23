# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-23：课程公式转写后的实际墨迹与后端不支持的原始宏语义边界."""

from collections import Counter
from pathlib import Path

import pytest
import symbol_fallback as symbols
from PIL import Image, ImageDraw, ImageFont

FONT_ROOT = Path(__file__).resolve().parents[1] / "font_assets"

# 2026-10-23：后端接收 Web/Flutter 转写协议，不把这些案例误称为完整 LaTeX 宏包解析。
COURSEWORK = (
    (
        r"\frac{∂²u}{∂t²}=c²\frac{∂²u}{∂x²}",
        {"∂": 4, "u": 2, "t": 1, "x": 1, "c": 1, "2": 5},
    ),
    ("\u2112{f(t)}=(1)/(s+a)", {"\u2112": 1, "f": 1, "t": 1, "s": 1, "a": 1}),
    (
        (
            "⟦ pmatrix: (1)/(R₁)+(1)/(R₂)  -(1)/(R₂) ; "
            "-(1)/(R₂)  (1)/(R₂)+(1)/(R₃) ⟧"
            "⟦ pmatrix: U₁ ; U₂ ⟧=⟦ pmatrix: I ; 0 ⟧"
        ),
        {"R": 6, "U": 2, "I": 1, "0": 1},
    ),
    (
        "R=4.7 kΩ,C=100 nF;f₀=(1)/(2π√(LC))",
        {"R": 1, "Ω": 1, "C": 2, "F": 1, "π": 1, "L": 1},
    ),
    (
        "(d²x)/(dt²)+2ζω₀(dx)/(dt)+ω₀²x=0",
        {"d": 4, "x": 3, "t": 2, "ζ": 1, "ω": 2},
    ),
    ("Fe³⁺+SCN⁻ ⇌ FeSCN²⁺", {"F": 2, "e": 2, "S": 2, "C": 2, "N": 2, "⇌": 1}),
    ("⟦ cases: x²  x≥0 ; -x  x<0 ⟧", {"x": 4, "≥": 1, "<": 1, "0": 2}),
    (
        "⟨ψ|A|ϕ⟩=(1)/(2)∫_(−∞)^(∞)f(x) dx",
        {"ψ": 1, "A": 1, "ϕ": 1, "∫": 1, "∞": 2, "f": 1, "x": 2},
    ),
)


def _leaf_glyphs(box):
    result = box.glyph or ""
    return result + "".join(_leaf_glyphs(child) for child, _, _ in box.children)


@pytest.mark.parametrize(("source", "required"), COURSEWORK)
@pytest.mark.parametrize("font_name", ["霞鹜文楷.ttf", "李国夫手写体.ttf"])
@pytest.mark.parametrize("size", [24, 40, 70])
def test_realistic_course_formulas_keep_semantic_glyphs_and_complete_ink(
    source, required, font_name, size
):
    path = str(FONT_ROOT / font_name)
    font = ImageFont.truetype(path, size)
    normalized = symbols.normalize_text_for_font(source)
    box = symbols._layout_math_text(normalized, font, path)
    glyphs = Counter(_leaf_glyphs(box))
    for glyph, minimum in required.items():
        assert glyphs[glyph] >= minimum, (source, glyph, glyphs)
    margin = size * 2
    image = Image.new(
        "1", (box.bbox[2] - box.bbox[0] + 2 * margin, box.bbox[3] - box.bbox[1] + 2 * margin)
    )
    origin = (margin - box.bbox[0], margin - box.bbox[1])
    symbols._paint_math_box(ImageDraw.Draw(image), box, origin)
    ink = image.getbbox()
    assert ink is not None
    assert margin <= ink[0] < ink[2] <= image.width - margin
    assert margin <= ink[1] < ink[3] <= image.height - margin
    assert symbols.measure_math_text(normalized, font, path) == (
        box.advance,
        box.bbox[3] - box.bbox[1],
    )


@pytest.mark.parametrize(
    "source",
    [
        r"$\dv[2]{x}{t}+\pdv{f}{x}+\dd{x}$",
        r"$\vb{F}=m\va{a}$",
        r"$\SIrange{1}{10}{\volt}+\numlist{1;2;3}$",
        r"$\SI{1.23(4)}{\volt}+\num{1+2i}$",
        r"$\cancel{x}+\bcancel{y}+\xcancel{z}+\cancelto{0}{x}$",
        r"$\begin{multline}a+b+c\\=d+e\end{multline}$",
    ],
)
def test_raw_backend_macros_outside_render_protocol_remain_literal(source):
    # 2026-10-23：原始 API 未执行前端转换时，不能吞掉尚未解释的命令、参数或环境。
    assert symbols.normalize_text_for_font(source) == source
