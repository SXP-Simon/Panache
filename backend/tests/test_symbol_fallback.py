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


def test_vertical_fraction_conversion_and_rendering():
    # 测试全面分式转换：1/y, 1/y₁, 1/y₂, 2/t, 0.2/t, (A)/(B) 均转为无斜杠的竖式
    sample_text = "求 1/y₁ 及 1/y₂，且 f(y)=1/y，相对误差为 0.2/t，(1/y² · y)/(1/y)"
    converted = normalize_text_for_font(sample_text, "ttf_files/云烟体.ttf")
    # 确认文本中所有分式中的斜杠已被彻底消除
    assert "1/y₁" not in converted
    assert "1/y₂" not in converted
    assert "1/y" not in converted
    assert "0.2/t" not in converted

    # 验证在 handwrite 流程中渲染无异常
    bg = Image.new("RGB", (600, 200), (255, 255, 255))
    font = ImageFont.truetype("ttf_files/云烟体.ttf", size=30) if os.path.exists("ttf_files/云烟体.ttf") else ImageFont.load_default()
    template = Template(
        background=bg,
        font=font,
        line_spacing=40,
        fill=(0, 0, 0),
        left_margin=20,
        top_margin=20,
        right_margin=20,
        bottom_margin=20,
    )
    images = list(handwrite(converted, template))
    assert len(images) > 0


def test_function_division_not_corrupted():
    # 验证复合函数除法如 f'(y) · y / f(y) 不会被粗暴截断或破坏
    text = "由于 f'(y) · y / f(y)，相对误差 ε*(y₁) = 0.05"
    converted = normalize_text_for_font(text, "ttf_files/云烟体.ttf")
    # 竖式转换应保留分子与完整的分母 f(y)，而不是留下孤立的 /
    assert "/ f" not in converted
    assert "ε*(y₁)" in converted


def test_fallback_glyph_bbox_proportions():
    # 验证缺失字符 (ε, ₁, ·) fallback 到备用字体时，字形包围盒按实际比例计算，不会虚高撑大空白
    from backend.symbol_fallback import _get_char_glyph_and_bbox
    init_glyph_fallback_engine()
    font_path = "ttf_files/云烟体.ttf"
    if not os.path.exists(font_path):
        pytest.skip(f"Font not found: {font_path}")
    base_font = ImageFont.truetype(font_path, size=30)
    
    # 希腊字母 ε
    glyph_eps, bbox_eps, adv_eps = _get_char_glyph_and_bbox("ε", base_font, font_path)
    assert glyph_eps is not None
    left, top, right, bottom = bbox_eps
    width = right - left
    # 30px 字号下，小写希腊字母宽度应在合理范围 (8~25px)，绝不能像默认方块一样达到 30px 以上甚至撑大空白
    assert 5 <= width <= 25

    # 下标 ₁
    glyph_sub1, bbox_sub1, adv_sub1 = _get_char_glyph_and_bbox("₁", base_font, font_path)
    assert glyph_sub1 is not None
    w_sub = bbox_sub1[2] - bbox_sub1[0]
    assert 3 <= w_sub <= 20


def test_radical_vinculum_conversion_and_rendering():
    # 测试根式转换与横线封顶手写渲染：\\sqrt{...}, √( ... ), ³√( ... ), √x 均无外层括号并完成绘制
    from backend.symbol_fallback import _RADICAL_MAP
    sample_text = "计算 \\sqrt{x^2 + 1} 与 √(y₁ - y₂) 以及 ³√(8) 和 √x"
    converted = normalize_text_for_font(sample_text, "ttf_files/云烟体.ttf")

    # 确认原始带括号的根号模式已被替换为动态根式 PUA 码点，且括号被剥离
    assert "\\sqrt{" not in converted
    assert "√(y₁ - y₂)" not in converted
    assert "³√(8)" not in converted
    assert len(_RADICAL_MAP) > 0

    # 验证在 handwrite 流程中渲染无异常
    bg = Image.new("RGB", (700, 200), (255, 255, 255))
    font = ImageFont.truetype("ttf_files/云烟体.ttf", size=30) if os.path.exists("ttf_files/云烟体.ttf") else ImageFont.load_default()
    template = Template(
        background=bg,
        font=font,
        line_spacing=40,
        fill=(0, 0, 0),
        left_margin=20,
        top_margin=20,
        right_margin=20,
        bottom_margin=20,
    )
    images = list(handwrite(converted, template))
    assert len(images) > 0
    # 验证确实绘制了包含横线与字形的墨水像素
    pixels = list(images[0].getdata())
    drawn_count = sum(1 for p in pixels if p != (255, 255, 255))
    assert drawn_count > 100


def test_nested_radical_and_fraction_rendering():
    # 测试嵌套根式与分式组合：\\sqrt{\\frac{1}{2}} 与 \\frac{\\sqrt{x+1}}{2}
    text = "复杂公式：\\sqrt{\\frac{1}{2}} 与 \\frac{\\sqrt{x+1}}{2}"
    converted = normalize_text_for_font(text, "ttf_files/云烟体.ttf")
    bg = Image.new("RGB", (700, 200), (255, 255, 255))
    font = ImageFont.truetype("ttf_files/云烟体.ttf", size=30) if os.path.exists("ttf_files/云烟体.ttf") else ImageFont.load_default()
    template = Template(
        background=bg,
        font=font,
        line_spacing=40,
        fill=(0, 0, 0),
        left_margin=20,
        top_margin=20,
        right_margin=20,
        bottom_margin=20,
    )
    images = list(handwrite(converted, template))
    assert len(images) > 0


