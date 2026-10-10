# -*- coding: utf-8 -*-
"""
符号规范化与真实字形层级回退引擎 (Symbol Normalization & True Glyph Fallback Engine)

1. 清洗 Word 公式中的特殊空格（如 \u2005）与不可见字符；
2. 动态挂载手写绘制引擎的字形 Fallback 机制：当主手写字体（如云烟体）缺失
   下标（如 ₆）、上标（如 ²）、希腊字母（如 Σ、α、β）、数学符号（如 ⇒、∈、√、≤、≥、≠）时，
   自动调用备用字库（如李国夫手写体）按相同字号在底图上直接绘制真实字形，
   彻底告别降级为 "_6"、"Sigma"、"=>" 等破坏数学排版形态的问题。
"""

import functools
import glob
import logging
import os
import re
from typing import Dict, List, Optional, Set, Tuple


from PIL import ImageFont

try:
    from fontTools.ttLib import TTFont
except ImportError:
    TTFont = None

logger = logging.getLogger(__name__)

# 不可见字符、变体空格及特殊分隔符的通用清洗映射
_INVISIBLE_AND_SPECIAL_SPACES = {
    "\u00a0": " ",  # Non-breaking space
    "\u2000": " ",  # En quad
    "\u2001": " ",  # Em quad
    "\u2002": " ",  # En space
    "\u2003": " ",  # Em space
    "\u2004": " ",  # Three-per-em space
    "\u2005": " ",  # Four-per-em space (常见于 Word 公式)
    "\u2006": " ",  # Six-per-em space
    "\u2007": " ",  # Figure space
    "\u2008": " ",  # Punctuation space
    "\u2009": " ",  # Thin space
    "\u200a": " ",  # Hair space
    "\u202f": " ",  # Narrow no-break space
    "\u205f": " ",  # Medium mathematical space
    "\u3000": "  ",  # Full-width space
    "\u200b": "",  # Zero-width space
    "\u200c": "",  # Zero-width non-joiner
    "\u200d": "",  # Zero-width joiner
    "\ufeff": "",  # Byte order mark
}

# 普遍等价但易被生僻 Unicode 代替的符号映射
_UNIVERSAL_CANONICAL_MAP = {
    "\u2223": "|",  # Divides / Math bar (∣) -> ASCII Vertical Bar (|)
    "\u2225": "||",  # Parallel to (∥) -> Double vertical bar
    "\u2236": ":",  # Ratio (∶) -> Colon
}

# 缓存各字体的 cmap 码点集合
_FONT_CMAP_CACHE: Dict[str, Set[int]] = {}
_FALLBACK_FONTS_POOL: List[Tuple[str, Set[int]]] = []
_ENGINE_INITIALIZED = False


def _find_fallback_font_files() -> List[str]:
    """寻找本地包含完整数学字形的手写字体或系统字体作为备用字库池。"""
    candidates = []
    # 优先选择本地手写体
    possible_dirs = ["./ttf_files", "./backend/font_assets", "./font_assets", "../ttf_files", "../font_assets"]
    for d in possible_dirs:
        for f in glob.glob(os.path.join(d, "*.ttf")):
            if f not in candidates:
                candidates.append(f)

    # Windows / Linux 系统高质量备用字体池（优先包含全量数学符号与上下标的字库）
    system_candidates = [
        "C:/Windows/Fonts/seguisym.ttf",
        "C:/Windows/Fonts/segoeui.ttf",
        "C:/Windows/Fonts/calibri.ttf",
        "C:/Windows/Fonts/arial.ttf",
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/simsun.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSerif.ttf",
    ]
    for sc in system_candidates:
        if os.path.exists(sc) and sc not in candidates:
            candidates.append(sc)

    return candidates


# 标准真分数及常用手写竖式分数字符与 (分子, 分母) 映射表
_VULGAR_FRACTION_MAP: Dict[str, Tuple[str, str]] = {
    "½": ("1", "2"),
    "⅓": ("1", "3"),
    "⅔": ("2", "3"),
    "¼": ("1", "4"),
    "¾": ("3", "4"),
    "⅕": ("1", "5"),
    "⅖": ("2", "5"),
    "⅗": ("3", "5"),
    "⅘": ("4", "5"),
    "⅙": ("1", "6"),
    "⅚": ("5", "6"),
    "⅛": ("1", "8"),
    "⅜": ("3", "8"),
    "⅝": ("5", "8"),
    "⅞": ("7", "8"),
    # PUA 扩充手写常用分数：⁴⁄₃, ⅑, ⅒ 等
    "\ue001": ("4", "3"),
    "\ue002": ("1", "9"),
    "\ue003": ("1", "10"),
}

_DYNAMIC_PUA_COUNTER = 0xE200


def register_dynamic_fraction(num: str, denom: str) -> str:
    """动态注册一个新的手写分式并分配 PUA 码点。"""
    global _DYNAMIC_PUA_COUNTER
    key = (num.strip(), denom.strip())
    for ch, v in _VULGAR_FRACTION_MAP.items():
        if v == key:
            return ch
    ch = chr(_DYNAMIC_PUA_COUNTER)
    _DYNAMIC_PUA_COUNTER += 1
    _VULGAR_FRACTION_MAP[ch] = key
    return ch


def convert_slashed_fractions_to_vertical(text: str) -> str:
    """自动将文本中出现的 (A)/(B) 复杂代数分式以及数值、导数单项分式转换为上下竖式分式。"""
    if not text:
        return ""

    # 0. 将前缀真分数字符紧跟代数项（如 s = ½gt²）中保留真分数或转换为标准表达式
    # 1. 匹配带括号的公式型分式：(分子)/(分母)，如 (ε(x₁))/(|x₁|), (gt · dt)/(½gt²), (0.00005)/(1.1062)
    # 若分母中含 ½ 等真分数，直接保留真分数字符（如 ½gt²）而不是写成 1/2gt² 斜杠，保持书写自然
    p1 = re.compile(r"\(([^\(\)\n\r]+?)\)\s*\/\s*\(([^\(\)\n\r]+?)\)")
    text = p1.sub(lambda m: register_dynamic_fraction(m.group(1), m.group(2)), text)

    # 2. 匹配数值分式与微分比值：如 0.00005/1.1062, 0.0005/0.947, 1/x₁, 1/x₂, dt/t, ds/s, dV/V, dR/R
    # 限制前驱与后继字符，防止误伤 2026.03.18 日期或 URL
    p2 = re.compile(
        r"(?<![0-9a-zA-Z._])([0-9.]+|[dD][stVR]|[εa-z][0-9₁₂₃₄]?)\s*\/\s*([0-9.]+|[stVR]|[xX][0-9₁₂₃₄]?)(?![0-9a-zA-Z._])"
    )
    text = p2.sub(lambda m: register_dynamic_fraction(m.group(1), m.group(2)), text)

    return text


def _draw_vertical_fraction(draw, char: str, xy: Tuple[int, int], font) -> int:
    """按真实手写规范绘制上下结构的竖式分数（分子、居中分数横线、分母）。"""
    import handright._core as core

    num, denom = _VULGAR_FRACTION_MAP[char]
    font_path = getattr(font, "path", None)
    font_size = getattr(font, "size", 30)

    # 分子和分母采用缩小子号（约 0.58 倍主字号），符合手写行内竖式分数比例
    sub_size = max(10, int(font_size * 0.58))
    try:
        f_sub = ImageFont.truetype(font_path, sub_size) if font_path else font
    except Exception:
        f_sub = font

    nb = f_sub.getbbox(num)
    nw, nh = nb[2] - nb[0], nb[3] - nb[1]
    db = f_sub.getbbox(denom)
    dw, dh = db[2] - db[0], db[3] - db[1]

    line_w = max(nw, dw) + 6
    x, y = xy

    # 分数线位置: 位于当前字符单元的垂直黄金分割位置（对齐文字基线）
    line_y = y + int(font_size * 0.52)
    line_thickness = max(1, int(font_size * 0.05))
    draw.line([(x, line_y), (x + line_w, line_y)], fill=core._WHITE, width=line_thickness)

    # 分子: 紧挨分数线正上方
    nx = x + (line_w - nw) // 2 - nb[0]
    ny = line_y - nh - 1 - nb[1]
    draw.text((nx, ny), num, fill=core._WHITE, font=f_sub)

    # 分母: 紧挨分数线正下方
    dx = x + (line_w - dw) // 2 - db[0]
    dy = line_y + line_thickness + 1 - db[1]
    draw.text((dx, dy), denom, fill=core._WHITE, font=f_sub)

    return line_w + 4



def init_glyph_fallback_engine():
    """初始化底层 handright 绘制引擎的真实字形 Fallback 挂载。"""
    global _ENGINE_INITIALIZED, _FALLBACK_FONTS_POOL
    if _ENGINE_INITIALIZED:
        return

    if not TTFont:
        logger.warning("未安装 fontTools，跳过真实字形 Fallback 挂载")
        _ENGINE_INITIALIZED = True
        return

    # 1. 扫描并缓存备用字库的 cmap
    for font_path in _find_fallback_font_files():
        try:
            f = TTFont(font_path)
            cmap = f.getBestCmap()
            f.close()
            if cmap:
                _FALLBACK_FONTS_POOL.append((font_path, set(cmap.keys())))
        except Exception as e:
            logger.debug(f"读取备用字体 cmap 失败 ({font_path}): {e}")

    # 2. 挂载 handright._core._draw_char
    try:
        import handright._core as core

        orig_draw_char = core._draw_char

        def fallback_draw_char(draw, char: str, xy: Tuple[int, int], font) -> int:
            if char in (" ", "\t", "\n"):
                return orig_draw_char(draw, char, xy, font)

            # 优先拦截上下结构的真实手写分数
            if char in _VULGAR_FRACTION_MAP:
                return _draw_vertical_fraction(draw, char, xy, font)

            left, top, right, bottom = font.getbbox(char)
            # 若主字体获取该非空格字符的宽度或高度为 0（即主字库缺失该 Glyph 或为空白占位符）
            if (right - left == 0) or (bottom - top == 0):
                cp = ord(char)
                for fb_path, fb_cmap in _FALLBACK_FONTS_POOL:
                    if cp in fb_cmap:
                        try:
                            # 选用匹配的字号在原坐标绘制真实字形
                            fb_font = ImageFont.truetype(fb_path, size=font.size)
                            f_left, f_top, f_right, f_bottom = fb_font.getbbox(char)
                            # 确保备用字体在该字符上有实质可见像素（高度和宽度均大于0）
                            if (f_right - f_left > 0) and (f_bottom - f_top > 0):
                                draw.text(xy, char, fill=core._WHITE, font=fb_font)
                                return max(1, f_right - f_left)
                        except Exception:
                            continue
            return orig_draw_char(draw, char, xy, font)

        core._draw_char = fallback_draw_char
        logger.info(f"真实字形 Fallback 引擎挂载成功，已加载 {len(_FALLBACK_FONTS_POOL)} 款备用字库")
    except Exception as e:
        logger.warning(f"挂载字形 Fallback 引擎失败: {e}")

    _ENGINE_INITIALIZED = True



# 模块导入时自动初始化
init_glyph_fallback_engine()


def clean_invisible_and_special_characters(text: str) -> str:
    """清理文本中的不可见字符、Word 公式特殊空格以及通用数学符号规范化。"""
    if not text:
        return ""

    chars = []
    for ch in text:
        if ch in _INVISIBLE_AND_SPECIAL_SPACES:
            chars.append(_INVISIBLE_AND_SPECIAL_SPACES[ch])
        elif ch in _UNIVERSAL_CANONICAL_MAP:
            chars.append(_UNIVERSAL_CANONICAL_MAP[ch])
        else:
            chars.append(ch)

    return "".join(chars)


def normalize_text_for_font(text: str, font_path: Optional[str] = None) -> str:
    """对输入文本进行符号清洗与分式转换，同时保留真实数学 Unicode 符号（₆、²、Σ、⇒、∈、≤、≥ 等），
    自动将形如 (A)/(B) 或 数值/数值 转换为上下结构的真实手写竖式分数，
    由底层的 Glyph Fallback 引擎完成真实字形绘制，不再降级为 '_6' 或 'Sigma'。
    """
    if not text:
        return ""
    # 确保引擎已挂载
    if not _ENGINE_INITIALIZED:
        init_glyph_fallback_engine()

    cleaned = clean_invisible_and_special_characters(text)
    return convert_slashed_fractions_to_vertical(cleaned)

