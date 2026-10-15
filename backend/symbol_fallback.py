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
import threading
from dataclasses import dataclass
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
            # 2026-10-15：系统字体可能是 TTC 集合，明确读取首个字面。
            f = TTFont(norm_path, fontNumber=0)
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
    # 2026-10-15：桌面版资源目录与运行目录不同，优先读取明确配置的字体目录。
    possible_dirs = [
        os.getenv("FONT_ASSETS_DIR"), os.getenv("FONT_ASSETS_BUNDLED_DIR"),
        os.path.join(os.path.dirname(__file__), "font_assets"),
        "./ttf_files", "./backend/font_assets", "./font_assets", "../ttf_files", "../font_assets",
    ]
    for d in possible_dirs:
        if not d:
            continue
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
        "/System/Library/Fonts/Apple Symbols.ttf",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
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

# 2026-10-15：分式和根式使用不重叠的辅助私用区，避免第 513 个分式覆盖根式。
_DYNAMIC_PUA_COUNTER = 0xF0000
_MAX_DYNAMIC_EXPRESSIONS = 4096
_MAX_MATH_DEPTH = 48
_REGISTRY_LOCK = threading.RLock()
_FRACTION_KEYS = {value: char for char, value in _VULGAR_FRACTION_MAP.items()}
_MATH_NODE_DEPTH: Dict[str, int] = {}

# 动态根式映射表：PUA 码点 -> (被开方数, 根指数)
_RADICAL_MAP: Dict[str, Tuple[str, Optional[str]]] = {}
_DYNAMIC_RADICAL_COUNTER = 0xF8000
_RADICAL_KEYS: Dict[Tuple[str, Optional[str]], str] = {}

# 2026-10-15：用主手写字体绘制脚标，避免 Unicode 小字形缺失或混入印刷体。
_SCRIPT_MAP: Dict[str, tuple] = {}
_SCRIPT_KEYS: Dict[tuple, str] = {}
_DYNAMIC_SCRIPT_COUNTER = 0xFC000
_SUPER_TO_TEXT = str.maketrans("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱˣʸᵏᵐ", "0123456789+-=()nixykm")
_SUB_TO_TEXT = str.maketrans("₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵧ", "0123456789+-=()aehijklmnoprstuvxy")
_SUPER_CHARS = frozenset(chr(cp) for cp in _SUPER_TO_TEXT)
_SUB_CHARS = frozenset(chr(cp) for cp in _SUB_TO_TEXT)


def is_math_glyph(char: str) -> bool:
    return char in _VULGAR_FRACTION_MAP or char in _RADICAL_MAP or char in _SCRIPT_MAP


def register_dynamic_script(content: str, superscript: bool) -> str:
    """2026-10-15：将脚标作为一个可测量的整体，保留完整字符与表达式。"""
    return _register_script_parts(((content, superscript),))


def _register_script_parts(parts) -> str:
    global _DYNAMIC_SCRIPT_COUNTER
    key = tuple(parts)
    with _REGISTRY_LOCK:
        if key in _SCRIPT_KEYS:
            return _SCRIPT_KEYS[key]
        if len(_SCRIPT_MAP) >= _MAX_DYNAMIC_EXPRESSIONS:
            return ''.join(f"{'^' if superscript else '_'}({content})" for content, superscript in key)
        char = chr(_DYNAMIC_SCRIPT_COUNTER)
        _DYNAMIC_SCRIPT_COUNTER += 1
        _SCRIPT_MAP[char] = key
        _SCRIPT_KEYS[key] = char
        return char


def _script_token(text: str, index: int):
    """2026-10-15：读取 Unicode 连续脚标或明确括号脚标，不改普通文件名下划线。"""
    char = text[index]
    chars = _SUPER_CHARS if char in _SUPER_CHARS else _SUB_CHARS if char in _SUB_CHARS else None
    if chars is not None:
        end = index + 1
        while end < len(text) and text[end] in chars:
            end += 1
        return text[index:end].translate(_SUPER_TO_TEXT if char in _SUPER_CHARS else _SUB_TO_TEXT), char in _SUPER_CHARS, end
    if char not in "^_" or index == 0 or text[index - 1] == "\\":
        return None
    start = index + 1
    if start >= len(text):
        return None
    if text[start] in "({":
        opening, closing = text[start], ")" if text[start] == "(" else "}"
        depth, end = 1, start + 1
        while end < len(text) and depth:
            if text[end] == "\\":
                end += 2
                continue
            if text[end] == opening:
                depth += 1
            elif text[end] == closing:
                depth -= 1
            end += 1
        if not depth and end > start + 2:
            return text[start + 1:end - 1], char == "^", end
    elif char == "^" and text[start].isalnum():
        return text[start], True, start + 1
    return None


def convert_scripts_to_drawn(text: str) -> str:
    output, index = [], 0
    while index < len(text):
        token = _script_token(text, index)
        if token:
            content, superscript, index = token
            parts = [(content, superscript)]
            following = _script_token(text, index) if index < len(text) else None
            if following and following[1] != superscript:
                parts.append(following[:2])
                index = following[2]
            output.append(_register_script_parts(parts))
        else:
            output.append(text[index])
            index += 1
    return "".join(output)


def register_dynamic_radical(radicand: str, root_index: Optional[str] = None) -> str:
    """动态注册一个新的手写带封顶横线的根式并分配 PUA 码点。"""
    global _DYNAMIC_RADICAL_COUNTER
    clean_idx = root_index.strip() if root_index else None
    key = (radicand.strip(), clean_idx)
    with _REGISTRY_LOCK:
        if key in _RADICAL_KEYS:
            return _RADICAL_KEYS[key]
        # 2026-10-15：保留已有引用；达到进程预算后保留可读公式，不淘汰仍在绘制的字符。
        node_depth = 1 + max((_MATH_NODE_DEPTH.get(ch, 0) for ch in key[0] + (clean_idx or "")), default=0)
        if len(_RADICAL_MAP) >= _MAX_DYNAMIC_EXPRESSIONS or node_depth > _MAX_MATH_DEPTH:
            index = f"[{clean_idx}]" if clean_idx else ""
            return rf"\sqrt{index}{{{key[0]}}}"
        ch = chr(_DYNAMIC_RADICAL_COUNTER)
        _DYNAMIC_RADICAL_COUNTER += 1
        _RADICAL_MAP[ch] = key
        _RADICAL_KEYS[key] = ch
        _MATH_NODE_DEPTH[ch] = node_depth
        return ch


def register_dynamic_fraction(num: str, denom: str) -> str:
    """动态注册一个新的手写分式并分配 PUA 码点。"""
    global _DYNAMIC_PUA_COUNTER
    key = (num.strip(), denom.strip())
    with _REGISTRY_LOCK:
        if key in _FRACTION_KEYS:
            return _FRACTION_KEYS[key]
        node_depth = 1 + max((_MATH_NODE_DEPTH.get(ch, 0) for ch in key[0] + key[1]), default=0)
        if len(_FRACTION_KEYS) >= _MAX_DYNAMIC_EXPRESSIONS or node_depth > _MAX_MATH_DEPTH:
            return f"({key[0]})/({key[1]})"
        ch = chr(_DYNAMIC_PUA_COUNTER)
        _DYNAMIC_PUA_COUNTER += 1
        _VULGAR_FRACTION_MAP[ch] = key
        _FRACTION_KEYS[key] = ch
        _MATH_NODE_DEPTH[ch] = node_depth
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


def _extract_braced_group(text: str, start: int):
    """2026-10-15：平衡读取 LaTeX 花括号组，转义花括号不参与配对。"""
    while start < len(text) and text[start].isspace():
        start += 1
    if start >= len(text) or text[start] != "{":
        return None
    depth, pos = 1, start + 1
    while pos < len(text):
        if text[pos] == "\\":
            pos += 2
            continue
        if text[pos] == "{":
            depth += 1
        elif text[pos] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:pos], pos + 1
        pos += 1
    return None


# 2026-10-15：普通链接、日期、路径和代码必须先保护，不能把其中的斜杠当除号。
_NON_MATH_SLASH_RE = re.compile(
    r"```[\s\S]*?(?:```|\Z)|~~~[\s\S]*?(?:~~~|\Z)|`[^`\n]*`"
    r"|(?:https?|ftp|file)://[^\s<>\"']+|www\.[^\s<>\"']+"
    r"|[A-Za-z]:[\\/][^\s<>\"']+"
    r"|\b\d{4}/\d{1,2}(?:/\d{1,2})?\b|\b\d{1,2}/\d{1,2}/\d{2,4}\b"
    r"|(?<![\w)])(?:\.{0,2}/)[\w.-]+/[^\s<>\"']+"
    r"|\b[\w.-]+/[\w.-]+/[^\s<>\"']+"
)


def _transform_math_segments(text: str, transform) -> str:
    """2026-10-15：分式和根式共用保护范围，代码块和链接中的数学字样保留原文。"""
    output, last = [], 0
    for match in _NON_MATH_SLASH_RE.finditer(text):
        output.append(transform(text[last:match.start()]))
        output.append(match.group())
        last = match.end()
    output.append(transform(text[last:]))
    return "".join(output)


def convert_slashed_fractions_to_vertical(text: str, _depth: int = 0) -> str:
    """2026-10-15：只转换数学片段，保护普通文本中的斜杠及过深的公式。"""
    if _depth >= _MAX_MATH_DEPTH:
        return text
    return _transform_math_segments(text, lambda segment: _convert_fraction_segment(segment, _depth))


def _convert_fraction_segment(text: str, _depth: int) -> str:
    """自动将文本中出现的 (A)/(B) 复杂代数分式以及数值、导数、倒数单项分式转换为上下竖式分式。"""
    if not text:
        return ""

    # 2026-10-15：API 直接接收的 frac 也需解析，不能只依赖前端预处理。
    command = re.compile(r"\\(?:dfrac|tfrac|frac)(?![a-zA-Z])")
    pos = 0
    while True:
        match = command.search(text, pos)
        if not match:
            break
        numerator = _extract_braced_group(text, match.end())
        denominator = _extract_braced_group(text, numerator[1]) if numerator else None
        if not denominator:
            pos = match.end()
            continue
        def normalize_part(part):
            return convert_radicals_to_drawn(
                convert_slashed_fractions_to_vertical(part, _depth + 1), _depth + 1
            )
        replacement = register_dynamic_fraction(
            normalize_part(numerator[0]), normalize_part(denominator[0])
        )
        text = text[:match.start()] + replacement + text[denominator[1]:]
        pos = match.start() + len(replacement)

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
                        num_clean = convert_radicals_to_drawn(num_inner, _depth + 1)
                        denom_clean = convert_radicals_to_drawn(denom_inner, _depth + 1)
                        dyn_char = register_dynamic_fraction(num_clean, denom_clean)

                        replacement = s[:l_start] + dyn_char + s[r_end:]
                        if replacement == s:
                            continue
                        s = replacement
                        changed = True
                        break
        return s

    # 2.1 先执行深度平衡括号分式解析
    text = _resolve_balanced_fractions(text)

    # 2.2 最后兜底转换纯平铺的单项分式 (如 0.2/t, 1/y 等)
    text = p_single.sub(lambda m: register_dynamic_fraction(m.group(1), m.group(2)), text)

    return text


def convert_radicals_to_drawn(text: str, _depth: int = 0) -> str:
    """将文本中出现的根式 \\sqrt[n]{...}, \\sqrt{...}, [n]√(...), √(...) 或单项根式 √x 转换为带上方封顶横线的手写根式字符。"""
    if not text:
        return ""
    if _depth >= _MAX_MATH_DEPTH:
        return text

    # 1. 深度平衡解析 LaTeX \\sqrt[n]{...} 和 \\sqrt{...}
    def _resolve_latex_sqrt(s: str) -> str:
        p_sqrt = re.compile(r"\\sqrt(?:\s*\[([^{}]+)\])?\s*\{")
        pos = 0
        while True:
            m = p_sqrt.search(s, pos)
            if not m:
                break
            root_idx = m.group(1)
            start_brace = m.end() - 1
            group = _extract_braced_group(s, start_brace)
            if group:
                inner, end = group
                inner_cleaned = convert_radicals_to_drawn(
                    convert_slashed_fractions_to_vertical(inner, _depth + 1), _depth + 1
                )
                dyn_char = register_dynamic_radical(inner_cleaned, root_idx)
                s = s[:m.start()] + dyn_char + s[end:]
                pos = m.start() + len(dyn_char)
            else:
                pos = m.end()
        return s

    text = _resolve_latex_sqrt(text)

    # 2. 深度平衡解析 [⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ0-9a-zA-Z]*√\s*\(...\)
    def _resolve_unicode_paren_sqrt(s: str) -> str:
        # 2026-10-15：普通数字/字母在根号前表示系数，只有上标才作为根指数。
        p_rad = re.compile(r"([⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ]*)√\s*\(")
        pos = 0
        while True:
            m = p_rad.search(s, pos)
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
                inner_cleaned = convert_radicals_to_drawn(
                    convert_slashed_fractions_to_vertical(inner, _depth + 1), _depth + 1
                )
                dyn_char = register_dynamic_radical(inner_cleaned, root_idx)
                s = s[:m.start()] + dyn_char + s[close_paren + 1:]
                pos = m.start() + len(dyn_char)
            else:
                pos = m.end()
        return s

    text = _resolve_unicode_paren_sqrt(text)

    # 3. 匹配单项无括号根式，例如 √x, √2, ³√8, √y₁
    p_single_sqrt = re.compile(r"([⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ]*)√([0-9a-zA-Zα-ωΑ-Ω₀-₉²³⁴]+)")

    def _replace_single_sqrt(m):
        root_idx = m.group(1) or None
        inner = m.group(2)
        return register_dynamic_radical(inner, root_idx)

    text = p_single_sqrt.sub(_replace_single_sqrt, text)

    return text


@functools.lru_cache(maxsize=8192)
def _get_char_glyph_and_bbox_cached(
    char: str, font_path: Optional[str], font_size: int
) -> Tuple[Any, Tuple[int, int, int, int], int, bool]:
    """返回 (font_object, bbox, advance, is_fallback)。
    仅当主字体缺失该字符时才回退至备用字库，绝不误伤用户选中的主字体。
    """
    cp = ord(char)
    main_font = _get_cached_image_font(font_path, font_size) if font_path else None
    main_cmap = _get_font_cmap(font_path) if font_path else set()

    is_missing = False
    if font_path and main_cmap:
        if cp not in main_cmap:
            is_missing = True
        else:
            bb = main_font.getbbox(char)
            if (bb[2] - bb[0] <= 0) or (bb[3] - bb[1] <= 0):
                is_missing = True
            else:
                w = max(1, bb[2] - bb[0] + 1)
                return (main_font, bb, w, False)
    elif main_font:
        bb = main_font.getbbox(char)
        if (bb[2] - bb[0] <= 0) or (bb[3] - bb[1] <= 0):
            is_missing = True
        else:
            w = max(1, bb[2] - bb[0] + 1)
            return (main_font, bb, w, False)
    else:
        is_missing = True

    if is_missing:
        fb_path = _find_fallback_font_for_char(cp)
        if fb_path and fb_path != font_path:
            fb_font = _get_cached_image_font(fb_path, font_size)
            f_bb = fb_font.getbbox(char)
            if (f_bb[2] - f_bb[0] > 0) and (f_bb[3] - f_bb[1] > 0):
                w = max(1, f_bb[2] - f_bb[0] + 1)
                return (fb_font, f_bb, w, True)

        # 没有任何 fallback 字体支持，回退到主字体或默认占位
        font_to_use = main_font or ImageFont.load_default()
        return (font_to_use, (0, 0, int(font_size * 0.4), font_size), int(font_size * 0.4), False)

    bb = main_font.getbbox(char)
    w = max(1, bb[2] - bb[0] + 1)
    return (main_font, bb, w, False)


def _get_char_glyph_and_bbox(
    char: str, font, font_path: Optional[str] = None
) -> Tuple[Any, Tuple[int, int, int, int], int]:
    """获取单个字符的最佳可用字体、真实渲染包围盒 bbox 及前进量 advance。"""
    f_path = font_path or getattr(font, "path", None)
    f_size = getattr(font, "size", 30)
    fb_font, bb, adv, _ = _get_char_glyph_and_bbox_cached(char, f_path, f_size)
    return (fb_font, bb, adv)


@dataclass(frozen=True)
class _MathBox:
    """2026-10-15：同一盒模型同时驱动测量和绘制，bbox 使用右/下开区间。"""
    advance: int
    bbox: Tuple[int, int, int, int]
    children: tuple = ()
    paths: tuple = ()
    glyph: Optional[str] = None
    font: Any = None


def _union_bounds(bounds):
    visible = [box for box in bounds if box[2] > box[0] and box[3] > box[1]]
    if not visible:
        return (0, 0, 0, 0)
    return (min(b[0] for b in visible), min(b[1] for b in visible),
            max(b[2] for b in visible), max(b[3] for b in visible))


def _compose_box(advance, children=(), paths=()):
    bounds = [(box.bbox[0] + x, box.bbox[1] + y, box.bbox[2] + x, box.bbox[3] + y)
              for box, x, y in children]
    for points, thickness in paths:
        pad = (thickness + 1) // 2
        bounds.append((min(x for x, _ in points) - pad, min(y for _, y in points) - pad,
                       max(x for x, _ in points) + pad + 1, max(y for _, y in points) + pad + 1))
    return _MathBox(int(advance), _union_bounds(bounds), tuple(children), tuple(paths))


def _math_axis(font, font_path):
    # 2026-10-15：分数线与当前手写字体的小写文字中轴对齐，不再固定在字号的 0.52 倍。
    _, bbox, _ = _get_char_glyph_and_bbox('x', font, font_path)
    return round((bbox[1] + bbox[3]) / 2)


def _layout_script(content, superscript, font, font_path, memo):
    size = getattr(font, 'size', 30)
    small = _get_cached_image_font(font_path, max(8, round(size * 0.65)))
    body = _layout_math_text(content, small, font_path, memo)
    _, base_bbox, _ = _get_char_glyph_and_bbox('x', font, font_path)
    if superscript:
        dy = base_bbox[1] + round(size * 0.10) - body.bbox[3]
    else:
        dy = base_bbox[3] - round(size * 0.10) - body.bbox[1]
    return _compose_box(body.advance + max(1, round(size * 0.03)), ((body, 0, dy),))


def _layout_math_char(char, font, font_path, memo):
    size = getattr(font, 'size', 30)
    if char in _SCRIPT_MAP:
        parts = [_layout_script(content, superscript, font, font_path, memo)
                 for content, superscript in _SCRIPT_MAP[char]]
        return _compose_box(max(part.advance for part in parts), tuple((part, 0, 0) for part in parts))
    if char in _VULGAR_FRACTION_MAP:
        numerator, denominator = _VULGAR_FRACTION_MAP[char]
        # 2026-10-15：0.76 替代 0.58；嵌套仍保留手写可读的字高，由真实边界撑开分数。
        small = _get_cached_image_font(font_path, max(10, round(size * 0.76)))
        num = _layout_math_text(numerator, small, font_path, memo)
        den = _layout_math_text(denominator, small, font_path, memo)
        padding = max(3, round(size * 0.12))
        line_width = max(num.bbox[2] - num.bbox[0], den.bbox[2] - den.bbox[0], 1) + 2 * padding
        axis = _math_axis(font, font_path)
        thickness, gap = max(1, round(size * 0.035)), max(2, round(size * 0.08))
        nx = (line_width - (num.bbox[2] - num.bbox[0])) // 2 - num.bbox[0]
        dx = (line_width - (den.bbox[2] - den.bbox[0])) // 2 - den.bbox[0]
        ny = axis - (thickness + 1) // 2 - gap - num.bbox[3]
        dy = axis + (thickness + 1) // 2 + gap + 1 - den.bbox[1]
        return _compose_box(line_width + max(3, round(size * 0.1)),
                            ((num, nx, ny), (den, dx, dy)), ((((1, axis), (line_width - 1, axis)), thickness),))
    if char in _RADICAL_MAP:
        radicand, index = _RADICAL_MAP[char]
        body = _layout_math_text(radicand, font, font_path, memo)
        gap = max(2, round(size * 0.09))
        top = body.bbox[1] - gap
        bottom = max(body.bbox[3], top + round(size * 0.58))
        height = bottom - top
        stem_width = max(10, round(size * 0.46))
        thickness = max(1, round(size * 0.035))
        offset, children = 0, []
        if index:
            # 根指数先还原普通字符再缩小，不能对上标字形重复缩放。
            index_text = index.translate(_SUPER_TO_TEXT)
            small = _get_cached_image_font(font_path, max(8, round(size * 0.46)))
            idx = _layout_math_text(index_text, small, font_path, memo)
            index_bottom = top + round(height * 0.34)
            children.append((idx, -idx.bbox[0], index_bottom - idx.bbox[3]))
            offset = max(0, idx.bbox[2] - idx.bbox[0] - round(size * 0.16))
        body_x = offset + stem_width + max(1, round(size * 0.04)) - body.bbox[0]
        children.append((body, body_x, 0))
        right = body_x + body.bbox[2] + gap
        # 一条连贯笔画从根钩到封顶横线，随被开方式真实高度伸展。
        points = ((offset + 1, top + round(height * 0.63)),
                  (offset + round(stem_width * 0.20), top + round(height * 0.55)),
                  (offset + round(stem_width * 0.43), bottom - 1),
                  (offset + stem_width - 2, top), (right, top))
        return _compose_box(right + gap, children, ((points, thickness),))
    chosen, bbox, advance = _get_char_glyph_and_bbox(char, font, font_path)
    return _MathBox(advance, bbox, glyph=char, font=chosen)


def _layout_math_text(text, font, font_path=None, memo=None):
    if memo is None:
        memo = {}
    font_path = font_path or getattr(font, 'path', None)
    key = (text, id(font))
    if key in memo:
        return memo[key]
    active = memo.setdefault('_active', set())
    if key in active or len(active) >= _MAX_MATH_DEPTH:
        # 2026-10-15：极深脚标或外部传入的私用字符循环按字面渲染，不能递归耗尽栈。
        x, children = 0, []
        for char in text:
            chosen, bbox, advance = _get_char_glyph_and_bbox(char, font, font_path)
            children.append((_MathBox(advance, bbox, glyph=char, font=chosen), x, 0))
            x += advance
        return _compose_box(x, children)
    active.add(key)
    x, children, index = 0, [], 0
    while index < len(text):
        token = _script_token(text, index)
        if token:
            content, superscript, index = token
            box = _layout_script(content, superscript, font, font_path, memo)
            following = _script_token(text, index) if index < len(text) else None
            if following and following[1] != superscript:
                other = _layout_script(*following[:2], font, font_path, memo)
                box = _compose_box(max(box.advance, other.advance), ((box, 0, 0), (other, 0, 0)))
                index = following[2]
        else:
            box = _layout_math_char(text[index], font, font_path, memo)
            index += 1
        children.append((box, x, 0))
        x += box.advance
    result = _compose_box(x, children)
    active.remove(key)
    memo[key] = result
    return result


def _paint_math_box(draw, box, xy):
    import handright._core as core
    x, y = xy
    if box.glyph is not None:
        draw.text((x, y), box.glyph, fill=core._WHITE, font=box.font)
    for child, dx, dy in box.children:
        _paint_math_box(draw, child, (x + dx, y + dy))
    for points, thickness in box.paths:
        draw.line([(x + px, y + py) for px, py in points], fill=core._WHITE, width=thickness, joint='curve')


def _measure_radical(char: str, font, font_path: Optional[str]) -> Tuple[int, int]:
    box = _layout_math_text(char, font, font_path)
    return box.advance, box.bbox[3] - box.bbox[1]


def _draw_text_or_fraction(draw, text: str, xy: Tuple[int, int], font, font_path: Optional[str]) -> Tuple[int, int]:
    box = _layout_math_text(text, font, font_path)
    _paint_math_box(draw, box, xy)
    return box.advance, box.bbox[3] - box.bbox[1]


def _measure_text_or_fraction(text: str, font, font_path: Optional[str]) -> Tuple[int, int]:
    box = _layout_math_text(text, font, font_path)
    return box.advance, box.bbox[3] - box.bbox[1]


def _get_rendered_text_bbox(text: str, font, font_path: Optional[str]) -> Tuple[int, int, int, int]:
    return _layout_math_text(text, font, font_path).bbox


def _draw_radical_with_vinculum(draw, char: str, xy: Tuple[int, int], font) -> int:
    return _draw_text_or_fraction(draw, char, xy, font, getattr(font, 'path', None))[0]


def _draw_vertical_fraction(draw, char: str, xy: Tuple[int, int], font) -> int:
    return _draw_text_or_fraction(draw, char, xy, font, getattr(font, 'path', None))[0]


def init_glyph_fallback_engine():
    """初始化底层 handright 绘制引擎的真实字形 Fallback 挂载与变体缓存优化。"""
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

    # 2. 挂载 handright._core._draw_char 与 handright._core._get_font
    try:
        import handright._core as core

        orig_draw_char = core._draw_char

        def fallback_draw_char(draw, char: str, xy: Tuple[int, int], font) -> int:
            if char in (" ", "\t", "\n"):
                return orig_draw_char(draw, char, xy, font)

            # 2026-10-15：复合公式和脚标使用同一测量/绘制盒，保留主字体手写字形。
            if is_math_glyph(char):
                return _draw_text_or_fraction(draw, char, xy, font, getattr(font, "path", None))[0]

            font_path = getattr(font, "path", None)
            font_size = getattr(font, "size", 30)
            fb_font, bb, adv, is_fallback = _get_char_glyph_and_bbox_cached(char, font_path, font_size)
            if is_fallback:
                draw.text(xy, char, fill=core._WHITE, font=fb_font)
                return adv

            return orig_draw_char(draw, char, xy, font)

        core._draw_char = fallback_draw_char

        # 挂载带缓存的 _get_font，彻底解决 FreeType 每字重复重载导致的内存溢出 (Out Of Memory)
        def cached_get_font(template, rand) -> ImageFont:
            font = template.get_font()
            sigma = template.get_font_size_sigma()
            if not sigma:
                return font
            actual_font_size = max(int(rand.gauss(font.size, sigma)), 1)
            if actual_font_size == font.size:
                return font

            if not hasattr(font, "_variant_cache"):
                font._variant_cache = {}
            variant = font._variant_cache.get(actual_font_size)
            if variant is None:
                variant = font.font_variant(size=actual_font_size)
                if hasattr(font, "path"):
                    variant.path = font.path
                font._variant_cache[actual_font_size] = variant
            return variant

        core._get_font = cached_get_font
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
    return _transform_math_segments(
        cleaned,
        lambda segment: convert_scripts_to_drawn(convert_radicals_to_drawn(convert_slashed_fractions_to_vertical(segment))),
    )

