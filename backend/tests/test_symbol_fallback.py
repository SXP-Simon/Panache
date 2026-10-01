# -*- coding: utf-8 -*-
import os
import pytest
from PIL import Image, ImageFont
from handright import Template, handwrite
from backend.symbol_fallback import (
    clean_invisible_and_special_characters,
    normalize_text_for_font,
    init_glyph_fallback_engine,
)


def test_clean_invisible_and_special_characters():
    # 测试 Word 公式常见特殊空格与生僻竖线符号替换
    text_with_spaces = "A\u2005B\u00a0C\u200b∣D"
    cleaned = clean_invisible_and_special_characters(text_with_spaces)
    assert cleaned == "A B C|D"


def test_math_symbols_preserved_in_text():
    # 验证数学符号（下标 ₆、希腊字母 Σ、箭头 ⇒ 等）不再被粗暴降级为 "_6" 或 "Sigma"
    sample = "L(G₆) = {a | a ∈ Σ} 且 N⇒ND"
    result = normalize_text_for_font(sample, "ttf_files/云烟体.ttf")
    assert "₆" in result
    assert "Σ" in result
    assert "⇒" in result
    assert "_6" not in result
    assert "Sigma" not in result


def test_true_glyph_fallback_rendering():
    # 测试即使使用缺失下标与 ⇒ 的“云烟体”，也能通过真实字形 Fallback 引擎成功绘制出像素
    init_glyph_fallback_engine()
    font_path = "ttf_files/云烟体.ttf"
    if not os.path.exists(font_path):
        pytest.skip(f"Font not found: {font_path}")

    font = ImageFont.truetype(font_path, size=30)
    bg = Image.new("RGB", (600, 200), (255, 255, 255))
    template = Template(
        background=bg,
        font=font,
        line_spacing=40,
        fill=(0, 0, 0),
        left_margin=20,
        top_margin=20,
        right_margin=20,
        bottom_margin=20,
        word_spacing=0,
        line_spacing_sigma=0,
        font_size_sigma=0,
        word_spacing_sigma=0,
        end_chars="",
        perturb_x_sigma=0,
        perturb_y_sigma=0,
        perturb_theta_sigma=0,
    )

    text = "公式：L(G₆) 与 N⇒ND 与 a∈Σ"
    images = list(handwrite(normalize_text_for_font(text, font_path), template))
    assert len(images) > 0

    # 验证确实在画布上绘制了墨水像素
    pixels = list(images[0].getdata())
    drawn_count = sum(1 for p in pixels if p != (255, 255, 255))
    assert drawn_count > 100
