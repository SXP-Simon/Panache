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
from typing import Any, Dict, List, Optional, Set, Tuple


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
_CHAR_FALLBACK_CACHE: Dict[int, Optional[str]] = {}
_ENGINE_INITIALIZED = False


@functools.lru_cache(maxsize=128)
def _get_font_cmap(font_source: Any) -> Set[int]:
    """获取或从缓存中读取字体的 cmap 码点集合，支持文件路径、BytesIO 或字节数据。"""
    if not font_source or not TTFont:
        return set()

    # 1. 字符串文件路径
    if isinstance(font_source, (str, bytes, os.PathLike)):
        try:
            if not os.path.exists(font_source):
                return set()
            norm_path = os.path.normpath(os.path.abspath(font_source))
            f = TTFont(norm_path)
            cmap = f.getBestCmap()
            f.close()
            return set(cmap.keys()) if cmap else set()
        except Exception as e:
            logger.debug(f"读取字体 cmap 失败 ({font_source}): {e}")
            return set()

    # 2. BytesIO 或其他文件流
    try:
        import io
        if isinstance(font_source, io.BytesIO):
            pos = font_source.tell()
            font_source.seek(0)
            f = TTFont(font_source)
            cmap = f.getBestCmap()
            f.close()
            font_source.seek(pos)
            return set(cmap.keys()) if cmap else set()
    except Exception as e:
        logger.debug(f"读取内存流字体 cmap 失败: {e}")

    return set()


@functools.lru_cache(maxsize=256)
def _get_cached_image_font(font_path: Any, size: int) -> ImageFont.FreeTypeFont:
    """带 LRU 缓存的 FreeTypeFont 加载器，彻底避免在排版绘制热路径中重复从磁盘读字体。"""
    if font_path and isinstance(font_path, (str, bytes, os.PathLike)) and os.path.exists(font_path):
        try:
            return ImageFont.truetype(font_path, size=size)
        except Exception:
            pass
    for fb_path, _ in _FALLBACK_FONTS_POOL:
        try:
            return ImageFont.truetype(fb_path, size=size)
        except Exception:
            continue
    return ImageFont.load_default()


def _find_fallback_font_for_char(cp: int) -> Optional[str]:
    """快速 O(1) 查找覆盖指定码点的备用字库路径。"""
    if cp in _CHAR_FALLBACK_CACHE:
        return _CHAR_FALLBACK_CACHE[cp]
    for fb_path, fb_cmap in _FALLBACK_FONTS_POOL:
        if cp in fb_cmap:
            _CHAR_FALLBACK_CACHE[cp] = fb_path
            return fb_path
    _CHAR_FALLBACK_CACHE[cp] = None
    return None


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

# 动态根式映射表：PUA 码点 -> (被开方数, 根指数)
_RADICAL_MAP: Dict[str, Tuple[str, Optional[str]]] = {}
_DYNAMIC_RADICAL_COUNTER = 0xE400


def register_dynamic_radical(radicand: str, root_index: Optional[str] = None) -> str:
    """动态注册一个新的手写带封顶横线的根式并分配 PUA 码点。"""
    global _DYNAMIC_RADICAL_COUNTER
    clean_idx = root_index.strip() if root_index else None
    key = (radicand.strip(), clean_idx)
    for ch, v in _RADICAL_MAP.items():
        if v == key:
            return ch
    ch = chr(_DYNAMIC_RADICAL_COUNTER)
    _DYNAMIC_RADICAL_COUNTER += 1
    _RADICAL_MAP[ch] = key
    return ch


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


def _extract_balanced_paren_backward(text: str, slash_pos: int):
    """从 slash_pos 向左寻找平衡匹配的括号 (分子)"""
    p = slash_pos - 1
    while p >= 0 and text[p].isspace():
        p -= 1
    if p < 0 or text[p] != ')':
        return None
    end = p
    depth = 0
    while p >= 0:
        if text[p] == ')':
            depth += 1
        elif text[p] == '(':
            depth -= 1
            if depth == 0:
                return (p, end + 1, text[p + 1:end])
        p -= 1
    return None


def _extract_balanced_paren_forward(text: str, slash_pos: int):
    """从 slash_pos 向右寻找平衡匹配的括号 (分母)"""
    p = slash_pos + 1
    while p < len(text) and text[p].isspace():
        p += 1
    if p >= len(text) or text[p] != '(':
        return None
    start = p
    depth = 0
    while p < len(text):
        if text[p] == '(':
            depth += 1
        elif text[p] == ')':
            depth -= 1
            if depth == 0:
                return (start, p + 1, text[start + 1:p])
        p += 1
    return None


def convert_slashed_fractions_to_vertical(text: str) -> str:
    """自动将文本中出现的 (A)/(B) 复杂代数分式以及数值、导数、倒数单项分式转换为上下竖式分式。"""
    if not text:
        return ""

    # 1. 基础单项式分式正则（数值、导数、单字母变量、带下标变量等）：
    # 例如：1/2, 3/4, 4/3, 1/3, 1/300, 1/y, 1/y₁, 1/y₂, 2/t, 0.2/t, dt/t, ds/s, dV/V, dR/R, 0.00005/0.9863
    # 注意：负向前瞻禁止跟随 '('，防止将 f'(y) · y / f(y) 中的 y / f 误切分为分式！
    p_single = re.compile(
        r"(?<![0-9a-zA-Z._])([0-9.]+|[dD][a-zA-Z]|[εa-zA-Z][0-9₁₂₃₄₅₆₇₈₉₀]?)\s*\/\s*([0-9.]+|[dD]?[a-zA-Z][0-9₁₂₃₄₅₆₇₈₉₀%²³]?)(?![0-9a-zA-Z._/(])"
    )

    # 2. 深度平衡括号分式扫描：能够精准匹配 (ε*(s))/(s), (gt · ε*(t))/(1/2 gt²), (2ε*(t))/t 等任意嵌套函数括号！
    # 只要存在形如 (A)/(B) 或 (A)/b 或 a/(B) 的斜杠，均精准剥离外层并注册为手写竖式分式
    def _resolve_balanced_fractions(s: str) -> str:
        p_denom_token = re.compile(r"^([a-zA-Z0-9.%₁₂₃₄₅₆₇₈₉₀²³]+)(?![0-9a-zA-Z._/])")
        p_numer_token = re.compile(r"([a-zA-Z0-9.%₁₂₃₄₅₆₇₈₉₀²³]+)$")

        changed = True
        while changed:
            changed = False
            # 从右往左寻找未被转化的斜杠
            for i in range(len(s) - 1, -1, -1):
                if s[i] == '/':
                    # 检查左侧与右侧
                    left_info = _extract_balanced_paren_backward(s, i)
                    right_info = _extract_balanced_paren_forward(s, i)

                    # 检查右侧是否是形如 f(...) 的复合函数调用
                    suffix_peek = s[i + 1:].lstrip()
                    m_peek = p_denom_token.match(suffix_peek)
                    right_is_func = False
                    if m_peek:
                        after_peek = suffix_peek[m_peek.end():].lstrip()
                        if after_peek.startswith('('):
                            right_is_func = True

                    # 只要左右两侧至少有一侧是括号复合结构，或右侧为函数调用 f(y)
                    if left_info or right_info or right_is_func:
                        if left_info:
                            l_start, l_end, l_content = left_info
                        else:
                            # 尝试匹配左侧紧挨的单 token
                            prefix = s[:i].rstrip()
                            m_left = p_numer_token.search(prefix)
                            if not m_left:
                                continue
                            l_start = m_left.start()
                            l_end = i
                            l_content = m_left.group(1)

                        if right_info:
                            r_start, r_end, r_content = right_info
                        else:
                            # 尝试匹配右侧紧挨的单 token，并检查是否为函数调用形如 f(y)
                            suffix = s[i + 1:].lstrip()
                            m_right = p_denom_token.match(suffix)
                            if not m_right:
                                continue
                            skip_spaces = len(s[i + 1:]) - len(suffix)
                            r_start = i + 1 + skip_spaces + m_right.start()
                            r_end = i + 1 + skip_spaces + m_right.end()
                            r_content = m_right.group(1)
                            # 如果紧接着括号 (y)，则将函数参数一并纳为分母整体：f(y)
                            rem = s[r_end:].lstrip()
                            if rem.startswith('('):
                                paren_offset = len(s[r_end:]) - len(rem)
                                f_arg = _extract_balanced_paren_forward(s, r_end + paren_offset - 1)
                                if f_arg:
                                    r_end = f_arg[1]
                                    r_content = s[r_start:r_end]

                        # 对提取出的分子分母递归清洗内部可能含有的简单单项式、根式或真分数
                        num_inner = p_single.sub(lambda m: register_dynamic_fraction(m.group(1), m.group(2)), l_content.strip())
                        denom_inner = p_single.sub(lambda m: register_dynamic_fraction(m.group(1), m.group(2)), r_content.strip())
                        num_clean = convert_radicals_to_drawn(num_inner)
                        denom_clean = convert_radicals_to_drawn(denom_inner)
                        dyn_char = register_dynamic_fraction(num_clean, denom_clean)

                        s = s[:l_start] + dyn_char + s[r_end:]
                        changed = True
                        break
        return s

    # 2.1 先执行深度平衡括号分式解析
    text = _resolve_balanced_fractions(text)

    # 2.2 最后兜底转换纯平铺的单项分式 (如 0.2/t, 1/y 等)
    text = p_single.sub(lambda m: register_dynamic_fraction(m.group(1), m.group(2)), text)

    return text


def convert_radicals_to_drawn(text: str) -> str:
    """将文本中出现的根式 \\sqrt[n]{...}, \\sqrt{...}, [n]√(...), √(...) 或单项根式 √x 转换为带上方封顶横线的手写根式字符。"""
    if not text:
        return ""

    # 1. 深度平衡解析 LaTeX \\sqrt[n]{...} 和 \\sqrt{...}
    def _resolve_latex_sqrt(s: str) -> str:
        p_sqrt = re.compile(r"\\sqrt(?:\s*\[([^{}]+)\])?\s*\{")
        changed = True
        while changed:
            changed = False
            m = p_sqrt.search(s)
            if not m:
                break
            root_idx = m.group(1)
            start_brace = m.end() - 1
            depth = 1
            end_brace = -1
            for p in range(start_brace + 1, len(s)):
                if s[p] == '\\':
                    continue
                if s[p] == '{':
                    depth += 1
                elif s[p] == '}':
                    depth -= 1
                    if depth == 0:
                        end_brace = p
                        break
            if end_brace != -1:
                inner = s[start_brace + 1 : end_brace].strip()
                inner_cleaned = convert_radicals_to_drawn(convert_slashed_fractions_to_vertical(inner))
                dyn_char = register_dynamic_radical(inner_cleaned, root_idx)
                s = s[:m.start()] + dyn_char + s[end_brace + 1:]
                changed = True
        return s

    text = _resolve_latex_sqrt(text)

    # 2. 深度平衡解析 [⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ0-9a-zA-Z]*√\s*\(...\)
    def _resolve_unicode_paren_sqrt(s: str) -> str:
        p_rad = re.compile(r"([⁰¹²³⁴⁵⁶⁷⁸⁹ⁿa-zA-Z0-9]*)√\s*\(")
        changed = True
        while changed:
            changed = False
            m = p_rad.search(s)
            if not m:
                break
            root_idx = m.group(1) or None
            open_paren = m.end() - 1
            depth = 1
            close_paren = -1
            for p in range(open_paren + 1, len(s)):
                if s[p] == '(':
                    depth += 1
                elif s[p] == ')':
                    depth -= 1
                    if depth == 0:
                        close_paren = p
                        break
            if close_paren != -1:
                inner = s[open_paren + 1 : close_paren].strip()
                inner_cleaned = convert_radicals_to_drawn(convert_slashed_fractions_to_vertical(inner))
                dyn_char = register_dynamic_radical(inner_cleaned, root_idx)
                s = s[:m.start()] + dyn_char + s[close_paren + 1:]
                changed = True
        return s

    text = _resolve_unicode_paren_sqrt(text)

    # 3. 匹配单项无括号根式，例如 √x, √2, ³√8, √y₁
    p_single_sqrt = re.compile(r"([⁰¹²³⁴⁵⁶⁷⁸⁹ⁿa-zA-Z0-9]*)√([0-9a-zA-Zα-ωΑ-Ω₁-₉²³⁴]+)")

    def _replace_single_sqrt(m):
        root_idx = m.group(1) or None
        inner = m.group(2)
        return register_dynamic_radical(inner, root_idx)

    text = p_single_sqrt.sub(_replace_single_sqrt, text)

    return text


@functools.lru_cache(maxsize=4096)
def _get_char_glyph_and_bbox_cached(char: str, font_path: Optional[str], font_size: int) -> Tuple[Any, Tuple[int, int, int, int], int]:
    main_cmap = _get_font_cmap(font_path) if font_path else set()
    cp = ord(char)
    font = _get_cached_image_font(font_path, font_size)

    is_missing = False
    if main_cmap and (cp not in main_cmap):
        is_missing = True
    else:
        left, top, right, bottom = font.getbbox(char)
        if (right - left <= 0) or (bottom - top <= 0):
            is_missing = True

    if is_missing:
        fb_path = _find_fallback_font_for_char(cp)
        if fb_path:
            fb_font = _get_cached_image_font(fb_path, font_size)
            f_left, f_top, f_right, f_bottom = fb_font.getbbox(char)
            if (f_right - f_left > 0) and (f_bottom - f_top > 0):
                return (fb_font, (f_left, f_top, f_right, f_bottom), max(1, f_right - f_left))
        return (font, (0, 0, int(font_size * 0.4), font_size), int(font_size * 0.4))
    else:
        bb = font.getbbox(char)
        w = max(1, bb[2] - bb[0] + 1)
        return (font, bb, w)


def _get_char_glyph_and_bbox(char: str, font, font_path: Optional[str]) -> Tuple[Any, Tuple[int, int, int, int], int]:
    """获取单个字符的最佳可用字体、真实渲染包围盒 bbox 及前进量 advance。
    支持主字体与备用字库（Fallback fonts）的精确匹配，彻底避免缺失字符（如 ε、₁、·、²）返回虚假宽度的留白问题。
    """
    f_path = font_path or getattr(font, "path", None)
    f_size = getattr(font, "size", 30)
    return _get_char_glyph_and_bbox_cached(char, f_path, f_size)


def _measure_radical(char: str, font, font_path: Optional[str]) -> Tuple[int, int]:
    """测量带封顶横线的根式整体宽度与高度"""
    radicand, root_index = _RADICAL_MAP[char]
    font_size = getattr(font, "size", 30)

    rw = 0
    if root_index:
        root_size = max(8, int(font_size * 0.5))
        f_root = _get_cached_image_font(font_path, root_size)
        rw, _ = _measure_text_or_fraction(root_index, f_root, font_path)

    _, _, adv_sqrt = _get_char_glyph_and_bbox("√", font, font_path)
    w_inner, _ = _measure_text_or_fraction(radicand, font, font_path)

    total_w = rw + adv_sqrt + w_inner + max(2, int(font_size * 0.1))
    return total_w, font_size


def _draw_text_or_fraction(draw, text: str, xy: Tuple[int, int], font, font_path: Optional[str]) -> Tuple[int, int]:
    """绘制一段可能包含真分数/带封顶根式/普通文本的子串，返回 (总宽度, 最大高度)"""
    import handright._core as core
    x, y = xy
    start_x = x
    font_size = getattr(font, "size", 30)
    max_h = font_size

    for ch in text:
        if ch in _VULGAR_FRACTION_MAP:
            # 嵌套递归绘制更小字号的子分数
            w = _draw_vertical_fraction(draw, ch, (x, y), font)
            x += w
        elif ch in _RADICAL_MAP:
            # 嵌套递归绘制带封顶横线的根式
            w = _draw_radical_with_vinculum(draw, ch, (x, y), font)
            x += w
        else:
            fb_font, bb, adv = _get_char_glyph_and_bbox(ch, font, font_path)
            draw.text((x, y), ch, fill=core._WHITE, font=fb_font)
            x += adv
    return x - start_x, max_h


def _measure_text_or_fraction(text: str, font, font_path: Optional[str]) -> Tuple[int, int]:
    """测量可能包含真分数或带封顶根式的子串尺寸 (宽度, 高度)"""
    total_w = 0
    font_size = getattr(font, "size", 30)
    for ch in text:
        if ch in _VULGAR_FRACTION_MAP:
            n, d = _VULGAR_FRACTION_MAP[ch]
            sub_s = max(8, int(font_size * 0.58))
            f_sub = _get_cached_image_font(font_path, sub_s)
            nw, _ = _measure_text_or_fraction(n, f_sub, font_path)
            dw, _ = _measure_text_or_fraction(d, f_sub, font_path)
            total_w += max(nw, dw) + 10
        elif ch in _RADICAL_MAP:
            rw, _ = _measure_radical(ch, font, font_path)
            total_w += rw
        else:
            _, _, adv = _get_char_glyph_and_bbox(ch, font, font_path)
            total_w += adv
    return total_w, font_size


def _get_rendered_text_bbox(text: str, font, font_path: Optional[str]) -> Tuple[int, int, int, int]:
    """计算一段可能包含嵌套真分数字符或根式的复合文本的真实边界框 (min_x, min_y, max_x, max_y)"""
    min_x, min_y, max_x, max_y = 0, 9999, 0, -9999
    curr_x = 0
    has_valid = False
    fs = getattr(font, "size", 30)

    for ch in text:
        if ch in _VULGAR_FRACTION_MAP:
            w, h = _measure_text_or_fraction(ch, font, font_path)
            has_valid = True
            min_y = min(min_y, 0)
            max_y = max(max_y, fs)
            curr_x += w
        elif ch in _RADICAL_MAP:
            w, h = _measure_radical(ch, font, font_path)
            has_valid = True
            min_y = min(min_y, 0)
            max_y = max(max_y, fs)
            curr_x += w
        else:
            _, bb, adv = _get_char_glyph_and_bbox(ch, font, font_path)
            if bb and (bb[2] > bb[0] or bb[3] > bb[1]):
                has_valid = True
                min_y = min(min_y, bb[1])
                max_y = max(max_y, bb[3])
                curr_x += adv
            else:
                curr_x += int(fs * 0.5)

    if not has_valid:
        return (0, 0, max(1, len(text) * int(fs * 0.6)), fs)

    return (0, min_y if min_y != 9999 else 0, curr_x, max_y if max_y != -9999 else fs)


def _draw_radical_with_vinculum(draw, char: str, xy: Tuple[int, int], font) -> int:
    """按真实手写规范绘制带封顶横线的根式：
    1. 若有根指数（如 ³√），使用小字号在根号钩子上部绘制根指数；
    2. 绘制根号符号 √；
    3. 从根号右上角延伸出一条水平封顶横线（vinculum），完全覆盖被开方表达式；
    4. 在横线下方紧凑绘制被开方表达式（去除原有的外层括号）；
    5. 返回整体 advance 宽度。
    """
    import handright._core as core

    radicand, root_index = _RADICAL_MAP[char]
    font_path = getattr(font, "path", None)
    font_size = getattr(font, "size", 30)
    x, y = xy

    # 1. 绘制根指数 (如有)
    rw = 0
    if root_index:
        root_size = max(8, int(font_size * 0.48))
        f_root = _get_cached_image_font(font_path, root_size)
        rw, _ = _measure_text_or_fraction(root_index, f_root, font_path)
        root_y = y + int(font_size * 0.1)
        _draw_text_or_fraction(draw, root_index, (x, root_y), f_root, font_path)
        x += rw

    # 2. 绘制根号 √
    fb_font, bb_sqrt, adv_sqrt = _get_char_glyph_and_bbox("√", font, font_path)
    draw.text((x, y), "√", fill=core._WHITE, font=fb_font)

    # 根号右上端起点 vx
    sqrt_right = max(adv_sqrt, bb_sqrt[2] if bb_sqrt else adv_sqrt)
    vx = x + sqrt_right - max(1, int(font_size * 0.05))

    # 3. 测量被开方表达式尺寸与边界
    w_inner, _ = _measure_text_or_fraction(radicand, font, font_path)
    ib = _get_rendered_text_bbox(radicand, font, font_path)

    # 横线高度位置: 位于根号顶部右上端，且略高于被开方表达式的文字顶部
    line_thickness = max(1, int(font_size * 0.045))
    rad_top = ib[1] if (ib[1] is not None and ib[1] < 9999) else int(font_size * 0.15)
    vinculum_y = y + max(1, min(int(font_size * 0.14), rad_top - 2))

    # 横线长度：覆盖被开方数并在右侧留出少量余量
    vinculum_w = w_inner + max(3, int(font_size * 0.08))
    draw.line([(vx, vinculum_y), (vx + vinculum_w, vinculum_y)], fill=core._WHITE, width=line_thickness)

    # 4. 绘制被开方表达式
    rad_x = vx + max(1, int(font_size * 0.04))
    _draw_text_or_fraction(draw, radicand, (rad_x, y), font, font_path)

    # 5. 总 advance
    total_w = (vx + vinculum_w + max(2, int(font_size * 0.04))) - xy[0]
    return total_w


def _draw_vertical_fraction(draw, char: str, xy: Tuple[int, int], font) -> int:
    """按真实手写规范绘制上下结构的竖式分数（分子、居中分数横线、分母）。
    若分子或分母内部含有真分数符号，均以真实上下竖式嵌套绘制，绝不出现斜杠！
    """
    import handright._core as core

    num, denom = _VULGAR_FRACTION_MAP[char]
    font_path = getattr(font, "path", None)
    font_size = getattr(font, "size", 30)

    # 分子和分母采用缩小子号（约 0.58 倍主字号），符合手写行内竖式分数比例
    sub_size = max(10, int(font_size * 0.58))
    f_sub = _get_cached_image_font(font_path, sub_size)

    nw, nh = _measure_text_or_fraction(num, f_sub, font_path)
    dw, dh = _measure_text_or_fraction(denom, f_sub, font_path)

    line_w = max(nw, dw) + 6
    x, y = xy

    # 分数线位置: 严格对齐当前行内西文/数字文本的垂直中轴基线 (约 0.52 ~ 0.54)
    line_y = y + int(font_size * 0.52)
    line_thickness = max(1, int(font_size * 0.045))
    draw.line([(x, line_y), (x + line_w, line_y)], fill=core._WHITE, width=line_thickness)

    # 测量分子与分母整体实际文本边界
    nb = _get_rendered_text_bbox(num, f_sub, font_path)
    db = _get_rendered_text_bbox(denom, f_sub, font_path)

    # 分子: 底部紧挨分数线上方 3 像素处
    n_bottom = nb[3] if nb[3] > 0 else int(sub_size * 0.8)
    nx = x + max(0, (line_w - nw) // 2)
    ny = line_y - n_bottom - 3
    _draw_text_or_fraction(draw, num, (nx, ny), f_sub, font_path)

    # 分母: 顶部紧挨分数线下方 3 像素处
    d_top = db[1] if (db[1] is not None and db[1] >= 0) else 0
    dx = x + max(0, (line_w - dw) // 2)
    dy = line_y + line_thickness + 3 - d_top
    _draw_text_or_fraction(draw, denom, (dx, dy), f_sub, font_path)

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
            cmap = _get_font_cmap(font_path)
            if cmap:
                _FALLBACK_FONTS_POOL.append((font_path, cmap))
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

            # 优先拦截带封顶横线的真实手写根式
            if char in _RADICAL_MAP:
                return _draw_radical_with_vinculum(draw, char, xy, font)

            font_path = getattr(font, "path", None)
            font_size = getattr(font, "size", 30)
            fb_font, bb, adv = _get_char_glyph_and_bbox_cached(char, font_path, font_size)
            if fb_font is not font:
                draw.text(xy, char, fill=core._WHITE, font=fb_font)
                return adv

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
    """对输入文本进行符号清洗、分式与带封顶横线根式转换，同时保留真实数学 Unicode 符号（₆、²、Σ、⇒、∈、≤、≥ 等），
    自动将形如 (A)/(B) 或 数值/数值 转换为上下结构的真实手写竖式分数，
    自动将 \\sqrt{...}、√( ... ) 转换为带上方横线封顶的真实手写根式，
    由底层的 Glyph Fallback 引擎完成真实字形绘制，不再降级为 '_6' 或 'Sigma'。
    """
    if not text:
        return ""
    # 确保引擎已挂载
    if not _ENGINE_INITIALIZED:
        init_glyph_fallback_engine()

    cleaned = clean_invisible_and_special_characters(text)
    with_fractions = convert_slashed_fractions_to_vertical(cleaned)
    with_radicals = convert_radicals_to_drawn(with_fractions)
    return with_radicals

