# Copyright (c) 2026 Simon and Handwriting Web contributors.
from pathlib import Path

import pytest
import symbol_fallback as symbols
from handright import Template, handwrite
from PIL import Image, ImageDraw, ImageFont
from symbol_fallback import (
    _RADICAL_MAP,
    _get_char_glyph_and_bbox,
    _get_char_glyph_and_bbox_cached,
    clean_invisible_and_special_characters,
    init_glyph_fallback_engine,
    normalize_text_for_font,
)


def _font_asset(name):
    # 2026-10-15：测试路径不依赖启动目录，兼容 CI 在 backend/ 下运行。
    root = Path(__file__).resolve().parents[2]
    for directory in (root / "backend/font_assets", root / "font_assets", root / "ttf_files"):
        candidate = directory / name
        if candidate.is_file():
            return str(candidate)
    pytest.skip(f"Test font not available: {name}")


def test_clean_invisible_and_special_characters():
    # 测试 Word 公式常见特殊空格与生僻竖线符号替换
    text_with_spaces = "A\u2005B\u00a0C\u200b∣D"
    cleaned = clean_invisible_and_special_characters(text_with_spaces)
    assert cleaned == "A B C|D"


def test_math_symbols_preserved_in_text():
    # 验证数学符号（下标 ₆、希腊字母 Σ、箭头 ⇒ 等）不再被粗暴降级为 "_6" 或 "Sigma"
    sample = "L(G₆) = {a | a ∈ Σ} 且 N⇒ND"
    result = normalize_text_for_font(sample, _font_asset("云烟体.ttf"))

    assert any(symbols._SCRIPT_MAP.get(ch) == (("6", False),) for ch in result)
    assert "Σ" in result
    assert "⇒" in result
    assert "_6" not in result
    assert "Sigma" not in result


def test_true_glyph_fallback_rendering():
    # 测试即使使用缺失下标与 ⇒ 的“云烟体”，也能通过真实字形 Fallback 引擎成功绘制出像素
    init_glyph_fallback_engine()
    font_path = _font_asset("云烟体.ttf")
    if not Path(font_path).exists():
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
    converted = normalize_text_for_font(sample_text, _font_asset("云烟体.ttf"))
    # 确认文本中所有分式中的斜杠已被彻底消除
    assert "1/y₁" not in converted
    assert "1/y₂" not in converted
    assert "1/y" not in converted
    assert "0.2/t" not in converted

    # 验证在 handwrite 流程中渲染无异常
    bg = Image.new("RGB", (600, 200), (255, 255, 255))
    font = (
        ImageFont.truetype(_font_asset("云烟体.ttf"), size=30)
        if Path(_font_asset("云烟体.ttf")).exists()
        else ImageFont.load_default()
    )
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
    converted = normalize_text_for_font(text, _font_asset("云烟体.ttf"))
    # 竖式转换应保留分子与完整的分母 f(y)，而不是留下孤立的 /
    assert "/ f" not in converted

    assert "ε*(y" in converted
    assert any(symbols._SCRIPT_MAP.get(ch) == (("1", False),) for ch in converted)


def test_fallback_glyph_bbox_proportions():
    # 验证缺失字符 (ε, ₁, ·) fallback 到备用字体时，字形包围盒按实际比例计算，不会虚高撑大空白

    init_glyph_fallback_engine()
    font_path = _font_asset("云烟体.ttf")
    if not Path(font_path).exists():
        pytest.skip(f"Font not found: {font_path}")
    base_font = ImageFont.truetype(font_path, size=30)

    # 希腊字母 ε
    glyph_eps, bbox_eps, _adv_eps = _get_char_glyph_and_bbox("ε", base_font, font_path)
    assert glyph_eps is not None
    left, _top, right, _bottom = bbox_eps
    width = right - left
    # 小写希腊字母不能像默认方块一样撑大空白。
    assert 5 <= width <= 25

    # 下标 ₁
    glyph_sub1, bbox_sub1, _adv_sub1 = _get_char_glyph_and_bbox("₁", base_font, font_path)
    assert glyph_sub1 is not None
    w_sub = bbox_sub1[2] - bbox_sub1[0]
    assert 3 <= w_sub <= 20


def test_radical_vinculum_conversion_and_rendering():
    # 测试根式转换与横线封顶手写渲染：\\sqrt{...}, √( ... ), ³√( ... ), √x 均无外层括号并完成绘制

    sample_text = "计算 \\sqrt{x^2 + 1} 与 √(y₁ - y₂) 以及 ³√(8) 和 √x"
    converted = normalize_text_for_font(sample_text, _font_asset("云烟体.ttf"))

    # 确认原始带括号的根号模式已被替换为动态根式 PUA 码点，且括号被剥离
    assert "\\sqrt{" not in converted
    assert "√(y₁ - y₂)" not in converted
    assert "³√(8)" not in converted
    assert len(_RADICAL_MAP) > 0

    # 验证在 handwrite 流程中渲染无异常
    bg = Image.new("RGB", (700, 200), (255, 255, 255))
    font = (
        ImageFont.truetype(_font_asset("云烟体.ttf"), size=30)
        if Path(_font_asset("云烟体.ttf")).exists()
        else ImageFont.load_default()
    )
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
    converted = normalize_text_for_font(text, _font_asset("云烟体.ttf"))
    # 2026-10-15：必须验证公式结构，生成图片本身不能证明 LaTeX 已被正确解析。

    first_root = next(ch for ch in converted if ch in symbols._RADICAL_MAP)
    inner_fraction = symbols._RADICAL_MAP[first_root][0]
    assert symbols._VULGAR_FRACTION_MAP[inner_fraction] == ("1", "2")
    outer_fraction = next(ch for ch in converted if ch in symbols._VULGAR_FRACTION_MAP)
    numerator, denominator = symbols._VULGAR_FRACTION_MAP[outer_fraction]
    assert denominator == "2"
    assert symbols._RADICAL_MAP[numerator] == ("x+1", None)
    bg = Image.new("RGB", (700, 200), (255, 255, 255))
    font = (
        ImageFont.truetype(_font_asset("云烟体.ttf"), size=30)
        if Path(_font_asset("云烟体.ttf")).exists()
        else ImageFont.load_default()
    )
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


def test_font_switching_no_fallback_leak():
    # 测试切换不同字体时，主字库支持的常规字符（如汉字、英文字母、数字）不被 fallback 覆盖

    font_path_1 = _font_asset("云烟体.ttf")
    font_path_2 = _font_asset("李国夫手写体.ttf")
    if not Path(font_path_1).exists() or not Path(font_path_2).exists():
        pytest.skip("Test fonts not available")

    # 1. 汉字 '你' 在两款字体中均存在
    _, _, _, is_fb_1 = _get_char_glyph_and_bbox_cached("你", font_path_1, 30)
    assert not is_fb_1, "主字体1支持的字符绝不能被 fallback"

    _, _, _, is_fb_2 = _get_char_glyph_and_bbox_cached("你", font_path_2, 30)
    assert not is_fb_2, "主字体2支持的字符绝不能被 fallback"


def test_large_font_and_heavy_rendering_no_oom():
    # 测试大体积字体（如悠哉手写体 15MB）配合 font_size_sigma 大量字符渲染时，变体缓存生效且无 OOM
    font_path = _font_asset("悠哉手写体.ttf")
    if not Path(font_path).exists():
        font_path = _font_asset("云烟体.ttf")
    if not Path(font_path).exists():
        pytest.skip("No test font")

    font = ImageFont.truetype(font_path, size=30)
    font.path = font_path
    bg = Image.new("RGB", (800, 1000), (255, 255, 255))
    template = Template(
        background=bg,
        font=font,
        line_spacing=40,
        fill=(0, 0, 0),
        left_margin=20,
        top_margin=20,
        right_margin=20,
        bottom_margin=20,
        font_size_sigma=2,
    )
    long_text = "5、向量相似性与距离度量计算\n余弦相似度：cos(x,y)=(x·y)/(||x||₂||y||₂)\n" * 20
    converted = normalize_text_for_font(long_text, font_path)
    images = list(handwrite(converted, template))
    assert len(images) > 0
    # 验证 font 变体缓存被成功创建与复用
    assert any(key[0] is font for key in symbols._FONT_VARIANTS)
    assert sum(key[0] is font for key in symbols._FONT_VARIANTS) > 0


@pytest.mark.parametrize(
    "text",
    [
        "2026/10/15",
        "2026/10",
        "10/15/2026",
        "https://example.com/a/b",
        "www.example.com/a/b",
        "C:/Users/Simon",
        "/tmp/math/input.txt",
        "../assets/image.png",
        "assets/fonts/a.ttf",
        "`a/b`",
        "https://example.com/√(x)",
        "C:/math/√(x).txt",
        "`√(x) + a/b`",
        "/tmp/√(x).txt",
        "../assets/√(x).png",
        "assets/math/√(x).png",
        "```python\na/b + √(x)\n```",
        "~~~text\na/b + √(x)\n~~~",
        "```text\na/b + √(x)",
    ],
)
def test_non_math_slashes_are_preserved(text):
    # 2026-10-15：文档中的日期、链接、路径及代码不参与自动分式排版。
    assert normalize_text_for_font(text) == text


def test_prose_slashes_and_math_can_coexist():

    text = normalize_text_for_font("2026/10/15 https://example.com/a/b 求 1/y 和 (a+b)/(c+d)")
    assert "2026/10/15 https://example.com/a/b" in text
    assert any(symbols._VULGAR_FRACTION_MAP.get(ch) == ("1", "y") for ch in text)
    assert any(symbols._VULGAR_FRACTION_MAP.get(ch) == ("a+b", "c+d") for ch in text)


def test_protected_code_and_links_allow_surrounding_math_conversion():

    source = "```text\na/b + √(x)\n```\nhttps://example.com/√(x) 求 √(x+1) 和 1/y"
    converted = normalize_text_for_font(source)
    assert converted.startswith("```text\na/b + √(x)\n```\nhttps://example.com/√(x)")
    assert any(symbols._RADICAL_MAP.get(ch) == ("x+1", None) for ch in converted)
    assert any(symbols._VULGAR_FRACTION_MAP.get(ch) == ("1", "y") for ch in converted)


@pytest.mark.parametrize(
    ("source", "coefficient", "index"),
    [
        ("2√x", "2", None),
        ("a√(b)", "a", None),
        ("³√8", "", "³"),
        (r"\sqrt[3]{8}", "", "3"),
    ],
)
def test_radical_coefficients_are_not_root_indices(source, coefficient, index):

    converted = normalize_text_for_font(source)
    assert converted.startswith(coefficient)
    assert symbols._RADICAL_MAP[converted[len(coefficient) :]][1] == index


@pytest.mark.parametrize("command", [r"\frac", r"\dfrac", r"\tfrac"])
def test_raw_latex_fraction_is_structural(command):

    converted = normalize_text_for_font(command + r"{a+\frac{1}{2}}{\sqrt{x+1}}")
    numerator, denominator = symbols._VULGAR_FRACTION_MAP[converted]
    assert numerator.startswith("a+")
    assert symbols._VULGAR_FRACTION_MAP[numerator[2:]] == ("1", "2")
    assert symbols._RADICAL_MAP[denominator] == ("x+1", None)


def test_radical_escaped_braces_and_unclosed_groups():

    converted = normalize_text_for_font(r"\sqrt{x\}y}")
    assert symbols._RADICAL_MAP[converted] == (r"x\}y", None)
    for malformed in [r"\frac{1}", r"\sqrt{x", "√(x"]:
        assert normalize_text_for_font(malformed) == malformed


def test_dynamic_fraction_and_radical_codepoints_cannot_collide(monkeypatch):

    # 2026-10-15：旧实现在第 513 个不同分式处覆盖根式码点。
    monkeypatch.setattr(symbols, "_VULGAR_FRACTION_MAP", {})
    monkeypatch.setattr(symbols, "_FRACTION_KEYS", {})
    monkeypatch.setattr(symbols, "_RADICAL_MAP", {})
    monkeypatch.setattr(symbols, "_RADICAL_KEYS", {})
    radical = symbols.register_dynamic_radical("collision-root")
    fractions = {symbols.register_dynamic_fraction(f"n{i}", "denom") for i in range(513)}
    assert radical not in fractions


def test_dynamic_expression_budget_preserves_old_references_and_new_source(monkeypatch):

    existing = symbols.register_dynamic_fraction("retained-n", "retained-d")
    monkeypatch.setattr(symbols, "_MAX_DYNAMIC_EXPRESSIONS", 0)
    assert symbols.register_dynamic_fraction("retained-n", "retained-d") == existing
    assert normalize_text_for_font("(budget-n)/(budget-d)") == "(budget-n)/(budget-d)"
    assert normalize_text_for_font(r"\sqrt{budget-root}") == r"\sqrt{budget-root}"


def test_deeply_nested_latex_has_a_finite_conversion_budget():
    # 2026-10-15：深层用户输入不可触发 RecursionError，超限内容保留为原文。
    text = r"\sqrt{" * 600 + "x" + "}" * 600
    assert normalize_text_for_font(text)


def test_configured_fallback_font_directories_are_discovered(tmp_path, monkeypatch):

    configured = tmp_path / "configured.ttf"
    configured.touch()
    monkeypatch.setenv("FONT_ASSETS_BUNDLED_DIR", str(tmp_path))
    assert str(configured) in symbols._find_fallback_font_files()


def test_nested_math_measured_width_matches_drawn_advance():

    font = ImageFont.truetype(
        str(Path(__file__).resolve().parents[1] / "font_assets" / "云烟体.ttf"), size=14
    )
    image = Image.new("L", (1000, 1000), 0)
    draw = ImageDraw.Draw(image)
    for source in [r"\frac{1234}{56}", r"\sqrt[3]{\frac{1234}{56}}"]:
        converted = normalize_text_for_font(source)
        measured, _ = symbols._measure_text_or_fraction(converted, font, font.path)
        drawn, _ = symbols._draw_text_or_fraction(draw, converted, (100, 100), font, font.path)
        assert measured == drawn


def test_composite_registration_limits_render_recursion(monkeypatch):

    monkeypatch.setattr(symbols, "_MAX_MATH_DEPTH", 4)
    inner = "nested-leaf"
    for index in range(10):
        inner = symbols.register_dynamic_fraction(str(index), inner)
    assert "nested-leaf" not in inner  # 最内层原文由稳定的已注册节点持有。
    assert max((symbols._MATH_NODE_DEPTH.get(ch, 0) for ch in inner), default=0) <= 4
    assert "/" in inner  # 超限节点保留为可读分式，而非继续创建递归树。
