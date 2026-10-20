# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""符号规范化与真实字形层级回退引擎 (Symbol Normalization & True Glyph Fallback Engine).

1. 清洗 Word 公式中的特殊空格（如 \u2005）与不可见字符；
2. 动态挂载手写绘制引擎的字形 Fallback 机制：当主手写字体（如云烟体）缺失
   下标（如 ₆）、上标（如 ²）、希腊字母（如 Σ、α、β）、数学符号（如 ⇒、∈、√、≤、≥、≠）时，
   自动调用备用字库（如李国夫手写体）按相同字号在底图上直接绘制真实字形，
   彻底告别降级为 "_6"、"Sigma"、"=>" 等破坏数学排版形态的问题。
"""

import functools
import io
import os
import re
import threading
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from random import Random
from typing import Protocol, cast

import handright._core as core
from handright import Template
from PIL import Image, ImageDraw, ImageFont

if __package__:
    from .library_boundary import install_member, member
    from .logging_setup import get_logger
    from .math_page_layout import install_math_page_layout
    from .math_table import Table, parse_table, table_spans
else:
    from library_boundary import install_member, member
    from logging_setup import get_logger
    from math_page_layout import install_math_page_layout
    from math_table import Table, parse_table, table_spans


type Font = ImageFont.FreeTypeFont | ImageFont.ImageFont
type BBox = tuple[int, int, int, int]
type ScriptParts = tuple[tuple[str, bool], ...]
type BoxChild = tuple[_MathBox, int, int]
type BoxPath = tuple[tuple[tuple[int, int], ...], int]


def font_path_of(font: Font) -> str | None:
    """Return a validated filesystem font path."""
    value: object = getattr(font, "path", None)
    return os.fsdecode(value) if isinstance(value, (str, bytes, Path)) else None


def font_size_of(font: Font) -> int:
    """Return the known font size or the bitmap fallback size."""
    value: object = getattr(font, "size", 30)
    return value if isinstance(value, int) else 30


class _FontBounds(Protocol):
    def getbbox(self, text: str) -> object: ...


class MathDrawer(Protocol):
    """Drawing operations used by composed handwritten mathematical glyphs."""

    def text(self, xy: tuple[int, int], text: str, *, fill: int, font: Font | None) -> None:
        """Apply this operation to the current drawing surface."""
        ...

    def line(self, xy: list[tuple[int, int]], *, fill: int, width: int, joint: str) -> None:
        """Apply this operation to the current drawing surface."""
        ...


def font_bbox_of(font: Font, text: str) -> BBox:
    """Validate Pillow bitmap-font results at the untyped library boundary."""
    value: object = cast("_FontBounds", font).getbbox(text)
    if isinstance(value, tuple):
        parts = cast("tuple[object, ...]", value)
        if len(parts) == BBOX_COORDINATES and all(isinstance(part, int) for part in parts):
            return cast("BBox", parts)
    msg = "Pillow font returned an invalid bounding box"
    raise TypeError(msg)


try:
    from fontTools.ttLib import TTFont as _TTFont

    ttfont_type = _TTFont
except ImportError:
    ttfont_type = None

logger = get_logger(__name__)

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
_FONT_CMAP_CACHE: dict[str, set[int]] = {}
_FALLBACK_FONTS_POOL: list[tuple[str, set[int]]] = []
_CHAR_FALLBACK_CACHE: dict[int, str | None] = {}


@dataclass
class _EngineState:
    initialized: bool = False
    accent_counter: int = 0x100000
    script_counter: int = 0xFC000
    radical_counter: int = 0xF8000
    pua_counter: int = 0xF0000


_state = _EngineState()
MONOCHROME_WHITE = 1
BBOX_COORDINATES = 4
MAX_FONT_VARIANTS = 256


_FONT_VARIANTS: dict[tuple[ImageFont.FreeTypeFont, int], ImageFont.FreeTypeFont] = {}


@functools.lru_cache(maxsize=128)
def _get_font_cmap(font_source: object) -> set[int]:
    """获取或从缓存中读取字体的 cmap 码点集合，支持文件路径、BytesIO 或字节数据."""
    if not font_source or not ttfont_type:
        return set()

    # 1. 字符串文件路径
    if isinstance(font_source, (str, bytes, Path)):
        try:
            if not Path(os.fsdecode(font_source)).exists():
                return set()
            norm_path = str(Path(os.fsdecode(font_source)).resolve())
            # 2026-10-15：系统字体可能是 TTC 集合，明确读取首个字面。
            f = ttfont_type(norm_path, fontNumber=0)
            cmap = f.getBestCmap()
            f.close()
            return set(cmap.keys()) if cmap else set()
        except Exception as e:
            logger.debug("读取字体 cmap 失败 (%s): %s", font_source, e, exc_info=True)
            return set()

    # 2. BytesIO 或其他文件流
    try:
        if isinstance(font_source, io.BytesIO):
            pos = font_source.tell()
            font_source.seek(0)
            f = ttfont_type(font_source)
            cmap = f.getBestCmap()
            f.close()
            font_source.seek(pos)
            return set(cmap.keys()) if cmap else set()
    except Exception as e:
        logger.debug("读取内存流字体 cmap 失败: %s", e, exc_info=True)

    return set()


@functools.lru_cache(maxsize=256)
def _get_cached_image_font(font_path: object, size: int) -> Font:
    """带 LRU 缓存的 FreeTypeFont 加载器，彻底避免在排版绘制热路径中重复从磁盘读字体."""
    if (
        font_path
        and isinstance(font_path, (str, bytes, Path))
        and Path(os.fsdecode(font_path)).exists()
    ):
        try:
            return ImageFont.truetype(os.fsdecode(font_path), size=size)
        except Exception:
            logger.debug("Primary font loading failed", exc_info=True)
    for fb_path, _ in _FALLBACK_FONTS_POOL:
        try:
            return ImageFont.truetype(fb_path, size=size)
        except Exception:
            logger.debug("Fallback font loading failed", exc_info=True)
            continue
    return ImageFont.load_default()


def _find_fallback_font_for_char(cp: int) -> str | None:
    """快速 O(1) 查找覆盖指定码点的备用字库路径."""
    if cp in _CHAR_FALLBACK_CACHE:
        return _CHAR_FALLBACK_CACHE[cp]
    for fb_path, fb_cmap in _FALLBACK_FONTS_POOL:
        if cp in fb_cmap:
            _CHAR_FALLBACK_CACHE[cp] = fb_path
            return fb_path
    _CHAR_FALLBACK_CACHE[cp] = None
    return None


def _find_fallback_font_files() -> list[str]:
    """寻找本地包含完整数学字形的手写字体或系统字体作为备用字库池."""
    candidates: list[str] = []
    # 优先选择本地手写体
    # 2026-10-15：桌面版资源目录与运行目录不同，优先读取明确配置的字体目录。
    possible_dirs = [
        os.getenv("FONT_ASSETS_DIR"),
        os.getenv("FONT_ASSETS_BUNDLED_DIR"),
        str(Path(__file__).parent / "font_assets"),
        "./ttf_files",
        "./backend/font_assets",
        "./font_assets",
        "../ttf_files",
        "../font_assets",
    ]
    for d in possible_dirs:
        if not d:
            continue
        for candidate in Path(d).glob("*.ttf"):
            f = str(candidate)
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
        if Path(sc).exists() and sc not in candidates:
            candidates.append(sc)

    return candidates


# 标准真分数及常用手写竖式分数字符与 (分子, 分母) 映射表
_VULGAR_FRACTION_MAP: dict[str, tuple[str, str]] = {
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
_MAX_DYNAMIC_EXPRESSIONS = 4096
_MAX_MATH_DEPTH = 48
_REGISTRY_LOCK = threading.RLock()
_FRACTION_KEYS = {value: char for char, value in _VULGAR_FRACTION_MAP.items()}
_MATH_NODE_DEPTH: dict[str, int] = {}

# 动态根式映射表：PUA 码点 -> (被开方数, 根指数)
_RADICAL_MAP: dict[str, tuple[str, str | None]] = {}
_RADICAL_KEYS: dict[tuple[str, str | None], str] = {}

# 2026-10-15：用主手写字体绘制脚标，避免 Unicode 小字形缺失或混入印刷体。
_SCRIPT_MAP: dict[str, ScriptParts] = {}
_SCRIPT_KEYS: dict[ScriptParts, str] = {}
_SUPER_TO_TEXT = str.maketrans("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱˣʸᵏᵐ", "0123456789+-=()nixykm")
_SUB_TO_TEXT = str.maketrans(
    "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵧ", "0123456789+-=()aehijklmnoprstuvxy"
)
_SUPER_CHARS = frozenset(chr(cp) for cp in _SUPER_TO_TEXT)
_SUB_CHARS = frozenset(chr(cp) for cp in _SUB_TO_TEXT)

# 2026-10-15：组合附加符绑定完整基底，独立私用区避免与分式、根式和脚标冲突。
_ACCENT_MAP: dict[str, tuple[str, str]] = {}
_ACCENT_KEYS: dict[tuple[str, str], str] = {}
_ACCENT_MARKS = frozenset("\u0304\u0302\u20d7\u0332\u0307\u0308\u0303\u0306\u0301\u0300\u030c")


_TABLE_MAP: dict[str, Table] = {}
_TABLE_KEYS: dict[Table, str] = {}


def convert_tables_to_drawn(text: str) -> str:
    """2026-10-20：只将带明确规则的完整表格注册为不可拆分的复合字形."""

    def replace(source: str) -> str:
        table = parse_table(source)
        if table is None:
            return source
        table = Table(
            tuple(
                tuple(_transform_math_segments(cell, _normalize_math_content) for cell in row)
                for row in table.rows
            ),
            table.vertical,
            table.horizontal,
        )
        with _REGISTRY_LOCK:
            if table in _TABLE_KEYS:
                return _TABLE_KEYS[table]
            if len(_TABLE_KEYS) >= _MAX_DYNAMIC_EXPRESSIONS:
                return source
            char = chr(0x104000 + len(_TABLE_KEYS))
            _TABLE_KEYS[table] = char
            _TABLE_MAP[char] = table
            return char

    output: list[str] = []
    copied = 0
    protected = tuple(
        match.span()
        for match in _NON_MATH_SLASH_RE.finditer(text)
        if match.group().startswith(("`", "~~~"))
    )
    for start, end in table_spans(text, protected):
        output.extend((text[copied:start], replace(text[start:end])))
        copied = end
    output.append(text[copied:])
    return "".join(output)


def is_math_glyph(char: str) -> bool:
    """Check whether a registered glyph requires mathematical layout."""
    return (
        char in _TABLE_MAP
        or char in _VULGAR_FRACTION_MAP
        or char in _RADICAL_MAP
        or char in _SCRIPT_MAP
        or char in _ACCENT_MAP
    )


def register_dynamic_accent(body: str, mark: str) -> str:
    """2026-10-15：带预算注册重音，超限保留可读基底及原组合符."""
    key = (body, mark)
    with _REGISTRY_LOCK:
        if key in _ACCENT_KEYS:
            return _ACCENT_KEYS[key]
        node_depth = 1 + max((_MATH_NODE_DEPTH.get(ch, 0) for ch in body), default=0)
        if (
            mark not in _ACCENT_MARKS
            or len(_ACCENT_MAP) >= _MAX_DYNAMIC_EXPRESSIONS
            or node_depth > _MAX_MATH_DEPTH
        ):
            return (body if len(body) == 1 else f"({body})") + mark
        char = chr(_state.accent_counter)
        _state.accent_counter += 1
        _ACCENT_MAP[char], _ACCENT_KEYS[key], _MATH_NODE_DEPTH[char] = key, char, node_depth
        return char


def _convert_accent_segment(text: str) -> str:
    output: list[str] = []
    for char in text:
        if char not in _ACCENT_MARKS or not output:
            output.append(char)
            continue
        if output[-1] == ")":
            depth, start = 1, len(output) - 2
            while start >= 0:
                if output[start] == ")":
                    depth += 1
                elif output[start] == "(":
                    depth -= 1
                    if depth == 0:
                        break
                start -= 1
            if depth or start == len(output) - 2:
                output.append(char)
                continue
            body = "".join(output[start + 1 : -1])
        elif output[-1].isalnum() or is_math_glyph(output[-1]):
            start, body = len(output) - 1, output[-1]
        else:
            output.append(char)
            continue
        output[start:] = register_dynamic_accent(body, char)
    return "".join(output)


def convert_accents_to_drawn(text: str) -> str:
    """2026-10-15：括号是前端的基底范围标记，组合符不再占独立横向字位."""
    return _transform_math_segments(text, _convert_accent_segment)


def register_dynamic_script(content: str, *, superscript: bool) -> str:
    """2026-10-15：将脚标作为一个可测量的整体，保留完整字符与表达式."""
    return _register_script_parts(((content, superscript),))


def _register_script_parts(parts: Iterable[tuple[str, bool]]) -> str:
    key = tuple(parts)
    with _REGISTRY_LOCK:
        if key in _SCRIPT_KEYS:
            return _SCRIPT_KEYS[key]
        if len(_SCRIPT_MAP) >= _MAX_DYNAMIC_EXPRESSIONS:
            return "".join(
                f"{'^' if superscript else '_'}({content})" for content, superscript in key
            )
        char = chr(_state.script_counter)
        _state.script_counter += 1
        _SCRIPT_MAP[char] = key
        _SCRIPT_KEYS[key] = char
        return char


def _script_group(text: str, start: int) -> tuple[str, int] | None:
    if text[start] not in "({":
        return None
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
    return (text[start + 1 : end - 1], end) if not depth and end > start + 2 else None


def _script_token(text: str, index: int) -> tuple[str, bool, int] | None:
    """2026-10-15：读取 Unicode 连续脚标或明确括号脚标，不改普通文件名下划线."""
    char = text[index]
    chars = _SUPER_CHARS if char in _SUPER_CHARS else _SUB_CHARS if char in _SUB_CHARS else None
    if chars is not None:
        end = index + 1
        while end < len(text) and text[end] in chars:
            end += 1
        return (
            text[index:end].translate(_SUPER_TO_TEXT if char in _SUPER_CHARS else _SUB_TO_TEXT),
            char in _SUPER_CHARS,
            end,
        )
    if char not in "^_" or index == 0 or text[index - 1] == "\\":
        return None
    start = index + 1
    if start >= len(text):
        return None
    group = _script_group(text, start)
    if group:
        return group[0], char == "^", group[1]
    if char == "^" and text[start].isalnum():
        return text[start], True, start + 1
    return None


def convert_scripts_to_drawn(text: str) -> str:
    """Register complete script atoms without changing literal identifiers."""
    output: list[str] = []
    index = 0
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


def register_dynamic_radical(radicand: str, root_index: str | None = None) -> str:
    """动态注册一个新的手写带封顶横线的根式并分配 PUA 码点."""
    clean_idx = root_index.strip() if root_index else None
    key = (radicand.strip(), clean_idx)
    with _REGISTRY_LOCK:
        if key in _RADICAL_KEYS:
            return _RADICAL_KEYS[key]
        # 2026-10-15：保留已有引用；达到进程预算后保留可读公式，不淘汰仍在绘制的字符。
        node_depth = 1 + max(
            (_MATH_NODE_DEPTH.get(ch, 0) for ch in key[0] + (clean_idx or "")), default=0
        )
        if len(_RADICAL_MAP) >= _MAX_DYNAMIC_EXPRESSIONS or node_depth > _MAX_MATH_DEPTH:
            index = f"[{clean_idx}]" if clean_idx else ""
            return rf"\sqrt{index}{{{key[0]}}}"
        ch = chr(_state.radical_counter)
        _state.radical_counter += 1
        _RADICAL_MAP[ch] = key
        _RADICAL_KEYS[key] = ch
        _MATH_NODE_DEPTH[ch] = node_depth
        return ch


def register_dynamic_fraction(num: str, denom: str) -> str:
    """动态注册一个新的手写分式并分配 PUA 码点."""
    key = (num.strip(), denom.strip())
    with _REGISTRY_LOCK:
        if key in _FRACTION_KEYS:
            return _FRACTION_KEYS[key]
        node_depth = 1 + max((_MATH_NODE_DEPTH.get(ch, 0) for ch in key[0] + key[1]), default=0)
        if len(_FRACTION_KEYS) >= _MAX_DYNAMIC_EXPRESSIONS or node_depth > _MAX_MATH_DEPTH:
            return f"({key[0]})/({key[1]})"
        ch = chr(_state.pua_counter)
        _state.pua_counter += 1
        _VULGAR_FRACTION_MAP[ch] = key
        _FRACTION_KEYS[key] = ch
        _MATH_NODE_DEPTH[ch] = node_depth
        return ch


def _extract_balanced_paren_backward(text: str, slash_pos: int) -> tuple[int, int, str] | None:
    """从 slash_pos 向左寻找平衡匹配的括号 (分子)."""
    p = slash_pos - 1
    while p >= 0 and text[p].isspace():
        p -= 1
    if p < 0 or text[p] != ")":
        return None
    end = p
    depth = 0
    while p >= 0:
        if text[p] == ")":
            depth += 1
        elif text[p] == "(":
            depth -= 1
            if depth == 0:
                return (p, end + 1, text[p + 1 : end])
        p -= 1
    return None


def _extract_balanced_paren_forward(text: str, slash_pos: int) -> tuple[int, int, str] | None:
    """从 slash_pos 向右寻找平衡匹配的括号 (分母)."""
    p = slash_pos + 1
    while p < len(text) and text[p].isspace():
        p += 1
    if p >= len(text) or text[p] != "(":
        return None
    start = p
    depth = 0
    while p < len(text):
        if text[p] == "(":
            depth += 1
        elif text[p] == ")":
            depth -= 1
            if depth == 0:
                return (start, p + 1, text[start + 1 : p])
        p += 1
    return None


def _extract_braced_group(text: str, start: int) -> tuple[str, int] | None:
    """2026-10-15：平衡读取 LaTeX 花括号组，转义花括号不参与配对."""
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
                return text[start + 1 : pos], pos + 1
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


def _transform_math_segments(text: str, transform: Callable[[str], str]) -> str:
    """2026-10-15：分式和根式共用保护范围，代码块和链接中的数学字样保留原文."""
    output: list[str] = []
    last = 0
    for match in _NON_MATH_SLASH_RE.finditer(text):
        output.append(transform(text[last : match.start()]))
        output.append(match.group())
        last = match.end()
    output.append(transform(text[last:]))
    return "".join(output)


def convert_slashed_fractions_to_vertical(text: str, _depth: int = 0) -> str:
    """2026-10-15：只转换数学片段，保护普通文本中的斜杠及过深的公式."""
    if _depth >= _MAX_MATH_DEPTH:
        return text
    return _transform_math_segments(
        text, lambda segment: _convert_fraction_segment(segment, _depth)
    )


_DENOMINATOR_TOKEN = re.compile(r"^([a-zA-Z0-9.%₁₂₃₄₅₆₇₈₉₀²³]+)(?![0-9a-zA-Z._/])")
_NUMERATOR_TOKEN = re.compile(r"([a-zA-Z0-9.%₁₂₃₄₅₆₇₈₉₀²³]+)$")


def _fraction_left(text: str, slash: int) -> tuple[int, str] | None:
    balanced = _extract_balanced_paren_backward(text, slash)
    if balanced:
        return balanced[0], balanced[2]
    match = _NUMERATOR_TOKEN.search(text[:slash].rstrip())
    return (match.start(), match.group(1)) if match else None


def _fraction_right(text: str, slash: int) -> tuple[int, str] | None:
    balanced = _extract_balanced_paren_forward(text, slash)
    if balanced:
        return balanced[1], balanced[2]
    suffix = text[slash + 1 :].lstrip()
    match = _DENOMINATOR_TOKEN.match(suffix)
    if not match:
        return None
    start = slash + 1 + len(text[slash + 1 :]) - len(suffix)
    end = start + match.end()
    remainder = text[end:].lstrip()
    if remainder.startswith("("):
        offset = len(text[end:]) - len(remainder)
        argument = _extract_balanced_paren_forward(text, end + offset - 1)
        if argument:
            end = argument[1]
    return end, text[start:end]


def _has_compound_fraction_side(text: str, slash: int) -> bool:
    if _extract_balanced_paren_backward(text, slash) or _extract_balanced_paren_forward(
        text, slash
    ):
        return True
    suffix = text[slash + 1 :].lstrip()
    match = _DENOMINATOR_TOKEN.match(suffix)
    return bool(match and suffix[match.end() :].lstrip().startswith("("))


def _resolve_balanced_fractions(text: str, _depth: int, p_single: re.Pattern[str]) -> str:
    changed = True
    while changed:
        changed = False
        for slash in range(len(text) - 1, -1, -1):
            if text[slash] != "/" or not _has_compound_fraction_side(text, slash):
                continue
            left, right = _fraction_left(text, slash), _fraction_right(text, slash)
            if left is None or right is None:
                continue

            def clean(content: str) -> str:
                return convert_radicals_to_drawn(
                    p_single.sub(
                        lambda m: register_dynamic_fraction(m.group(1), m.group(2)), content.strip()
                    ),
                    _depth + 1,
                )

            glyph = register_dynamic_fraction(clean(left[1]), clean(right[1]))
            replacement = text[: left[0]] + glyph + text[right[0] :]
            if replacement != text:
                text, changed = replacement, True
                break
    return text


def _convert_fraction_segment(text: str, _depth: int) -> str:
    """自动将文本中出现的 (A)/(B) 复杂代数分式以及数值、导数、倒数单项分式转换为上下竖式分式."""
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
        if numerator is None or denominator is None:
            pos = match.end()
            continue

        def normalize_part(part: str) -> str:
            return convert_radicals_to_drawn(
                convert_slashed_fractions_to_vertical(part, _depth + 1), _depth + 1
            )

        replacement = register_dynamic_fraction(
            normalize_part(numerator[0]), normalize_part(denominator[0])
        )
        text = text[: match.start()] + replacement + text[denominator[1] :]
        pos = match.start() + len(replacement)

    # 1. 基础单项式分式正则（数值、导数、单字母变量、带下标变量等）：
    # 数值、导数和带下标变量都按完整单项处理。
    # 注意：负向前瞻禁止跟随 '('，防止将 f'(y) · y / f(y) 中的 y / f 误切分为分式！
    p_single = re.compile(
        r"(?<![0-9a-zA-Z._])([0-9.]+|[dD][a-zA-Z]|[εa-zA-Z][0-9₁₂₃₄₅₆₇₈₉₀]?)\s*\/\s*"
        r"([0-9.]+|[dD]?[a-zA-Z][0-9₁₂₃₄₅₆₇₈₉₀%²³]?)(?![0-9a-zA-Z._/(])"
    )

    # 深度平衡括号扫描支持嵌套函数及其完整参数。
    # 只要存在形如 (A)/(B) 或 (A)/b 或 a/(B) 的斜杠，均精准剥离外层并注册为手写竖式分式

    # 2.1 先执行深度平衡括号分式解析
    text = _resolve_balanced_fractions(text, _depth, p_single)

    # 2.2 最后兜底转换纯平铺的单项分式 (如 0.2/t, 1/y 等)
    return p_single.sub(lambda m: register_dynamic_fraction(m.group(1), m.group(2)), text)


def _resolve_latex_sqrt(s: str, _depth: int) -> str:
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
            s = s[: m.start()] + dyn_char + s[end:]
            pos = m.start() + len(dyn_char)
        else:
            pos = m.end()
    return s


def _resolve_unicode_paren_sqrt(s: str, _depth: int) -> str:
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
            if s[p] == "(":
                depth += 1
            elif s[p] == ")":
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
            s = s[: m.start()] + dyn_char + s[close_paren + 1 :]
            pos = m.start() + len(dyn_char)
        else:
            pos = m.end()
    return s


def _replace_single_sqrt(m: re.Match[str]) -> str:
    root_idx = m.group(1) or None
    inner = m.group(2)
    return register_dynamic_radical(inner, root_idx)


def convert_radicals_to_drawn(text: str, _depth: int = 0) -> str:
    """Convert supported root expressions into complete handwritten radical glyphs."""
    if not text:
        return ""
    if _depth >= _MAX_MATH_DEPTH:
        return text

    # 2026-10-15：直接粘贴的立方根/四次根也使用可伸展封顶，代码与路径保留字面字符。
    text = _transform_math_segments(
        text, lambda segment: segment.replace("∛", "³√").replace("∜", "⁴√")
    )

    # 1. 深度平衡解析 LaTeX \\sqrt[n]{...} 和 \\sqrt{...}

    text = _resolve_latex_sqrt(text, _depth)

    # 2. 深度平衡解析 [⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ0-9a-zA-Z]*√\s*\(...\)

    text = _resolve_unicode_paren_sqrt(text, _depth)

    # 3. 匹配单项无括号根式，例如 √x, √2, ³√8, √y₁
    p_single_sqrt = re.compile(r"([⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ]*)√([0-9a-zA-Zα-ωΑ-Ω₀-₉²³⁴]+)")

    return p_single_sqrt.sub(_replace_single_sqrt, text)


@functools.lru_cache(maxsize=8192)
def _get_char_glyph_and_bbox_cached(
    char: str, font_path: str | None, font_size: int
) -> tuple[Font, BBox, int, bool]:
    """Resolve the font, ink bounds, advance and fallback status for one glyph."""
    main = _get_cached_image_font(font_path, font_size) if font_path else None
    cmap = _get_font_cmap(font_path) if font_path else set[int]()
    if main is not None and (not cmap or ord(char) in cmap):
        bbox = font_bbox_of(main, char)
        if bbox[2] > bbox[0] and bbox[3] > bbox[1]:
            return main, bbox, max(1, bbox[2] - bbox[0] + 1), False
    fallback = _find_fallback_font_for_char(ord(char))
    if fallback and fallback != font_path:
        font = _get_cached_image_font(fallback, font_size)
        bbox = font_bbox_of(font, char)
        if bbox[2] > bbox[0] and bbox[3] > bbox[1]:
            return font, bbox, max(1, bbox[2] - bbox[0] + 1), True
    width = int(font_size * 0.4)
    return main or ImageFont.load_default(), (0, 0, width, font_size), width, False


def _get_char_glyph_and_bbox(
    char: str, font: Font, font_path: str | None = None
) -> tuple[Font, BBox, int]:
    """获取单个字符的最佳可用字体、真实渲染包围盒 bbox 及前进量 advance."""
    f_path = font_path or font_path_of(font)
    f_size = font_size_of(font)
    fb_font, bb, adv, _ = _get_char_glyph_and_bbox_cached(char, f_path, f_size)
    return (fb_font, bb, adv)


@dataclass(frozen=True)
class _MathBox:
    """2026-10-15：同一盒模型同时驱动测量和绘制，bbox 使用右/下开区间."""

    advance: int
    bbox: tuple[int, int, int, int]
    children: tuple[BoxChild, ...] = ()
    paths: tuple[BoxPath, ...] = ()
    glyph: str | None = None
    font: Font | None = None


@dataclass
class _LayoutMemo:
    boxes: dict[tuple[str, int], _MathBox] = field(default_factory=dict[tuple[str, int], _MathBox])
    active: set[tuple[str, int]] = field(default_factory=set[tuple[str, int]])


def _union_bounds(bounds: Iterable[BBox]) -> BBox:
    visible = [box for box in bounds if box[2] > box[0] and box[3] > box[1]]
    if not visible:
        return (0, 0, 0, 0)
    return (
        min(b[0] for b in visible),
        min(b[1] for b in visible),
        max(b[2] for b in visible),
        max(b[3] for b in visible),
    )


def _compose_box(
    advance: int, children: Iterable[BoxChild] = (), paths: Iterable[BoxPath] = ()
) -> _MathBox:
    bounds = [
        (box.bbox[0] + x, box.bbox[1] + y, box.bbox[2] + x, box.bbox[3] + y)
        for box, x, y in children
    ]
    for points, thickness in paths:
        pad = (thickness + 1) // 2
        bounds.append(
            (
                min(x for x, _ in points) - pad,
                min(y for _, y in points) - pad,
                max(x for x, _ in points) + pad + 1,
                max(y for _, y in points) + pad + 1,
            )
        )
    return _MathBox(int(advance), _union_bounds(bounds), tuple(children), tuple(paths))


def _math_axis(font: Font, font_path: str | None) -> int:
    # 2026-10-15：分数线与当前手写字体的小写文字中轴对齐，不再固定在字号的 0.52 倍。
    _, bbox, _ = _get_char_glyph_and_bbox("x", font, font_path)
    return round((bbox[1] + bbox[3]) / 2)


def _layout_script(
    content: str, font: Font, font_path: str | None, memo: _LayoutMemo, *, superscript: bool
) -> _MathBox:
    size = font_size_of(font)
    small = _get_cached_image_font(font_path, max(8, round(size * 0.65)))
    body = _layout_math_text(content, small, font_path, memo)
    _, base_bbox, _ = _get_char_glyph_and_bbox("x", font, font_path)
    if superscript:
        dy = base_bbox[1] + round(size * 0.10) - body.bbox[3]
    else:
        dy = base_bbox[3] - round(size * 0.10) - body.bbox[1]
    return _compose_box(body.advance + max(1, round(size * 0.03)), ((body, 0, dy),))


def _accent_paths(mark: str, bbox: BBox, size: int) -> tuple[tuple[tuple[int, int], ...], ...]:
    left, top, right, bottom = bbox
    right = max(left + 1, right - 1)
    center = (left + right) // 2
    gap, rise = max(2, round(size * 0.10)), max(3, round(size * 0.15))
    y = top - gap - rise
    simple = {
        "\u0332": (((left, bottom + gap), (right, bottom + gap)),),
        "\u0304": (((left, top - gap), (right, top - gap)),),
        "\u0302": (((left, top - gap), (center, y), (right, top - gap)),),
        "\u030c": (((left, y), (center, top - gap), (right, y)),),
        "\u0301": (((center - rise // 2, top - gap), (center + rise // 2, y)),),
        "\u0300": (((center - rise // 2, y), (center + rise // 2, top - gap)),),
        "\u0306": (
            (
                (left, y),
                (left + (right - left) // 4, y + rise),
                (left + 3 * (right - left) // 4, y + rise),
                (right, y),
            ),
        ),
    }
    if mark in simple:
        return simple[mark]
    if mark == "\u20d7":
        head = max(3, min(round(size * 0.16), (right - left) // 3))
        return (
            ((left, y), (right, y)),
            ((right - head, y - rise), (right, y), (right - head, y + rise)),
        )
    if mark in ("\u0307", "\u0308"):
        radius = max(1, round(size * 0.035))
        centers = (
            (center,)
            if mark == "\u0307"
            else (center - max(2, round(size * 0.12)), center + max(2, round(size * 0.12)))
        )
        return tuple(
            ((x - radius, top - gap - radius), (x + radius, top - gap - radius)) for x in centers
        )
    width = max(1, right - left)
    return (
        (
            (left, y + rise // 2),
            (left + width // 4, y),
            (left + 3 * width // 4, y + rise),
            (right, y + rise // 2),
        ),
    )


def _layout_accent(
    accent: tuple[str, str], font: Font, font_path: str | None, memo: _LayoutMemo
) -> _MathBox:
    content, mark = accent
    size = font_size_of(font)
    body = _layout_math_text(content, font, font_path, memo)
    thickness = max(1, round(size * 0.035))
    return _compose_box(
        body.advance,
        ((body, 0, 0),),
        tuple((path, thickness) for path in _accent_paths(mark, body.bbox, size)),
    )


def _table_rule(
    start: tuple[int, int], end: tuple[int, int], thickness: int, size: int, *, dashed: bool
) -> list[BoxPath]:
    # 2026-10-20：格线共用直线端点与笔宽，避免人为偏移造成接缝和粗细错觉。
    if not dashed:
        return [((start, end), thickness)]
    length = max(end[0] - start[0], end[1] - start[1])
    dash = max(3, round(size * 0.18))
    horizontal = end[0] != start[0]
    paths: list[BoxPath] = []
    for position in range(0, length, dash * 2):
        stop = min(length, position + dash)
        a = (start[0] + position, start[1]) if horizontal else (start[0], start[1] + position)
        b = (start[0] + stop, start[1]) if horizontal else (start[0], start[1] + stop)
        paths.append(((a, b), thickness))
    return paths


def _table_grid_paths(
    table: Table, widths: list[int], heights: list[int], size: int
) -> list[BoxPath]:
    thin = max(1, round(size * 0.025))
    paths: list[BoxPath] = []
    vertical = {rule.position: rule for rule in table.vertical}
    horizontal = {rule.position: rule for rule in table.horizontal}
    for index in range(len(widths) + 1):
        rule = vertical.get(index)
        x = sum(widths[:index])
        paths.extend(
            _table_rule(
                (x, 0),
                (x, sum(heights)),
                thin,
                size,
                dashed=bool(rule and rule.dashed),
            )
        )
    for index in range(len(heights) + 1):
        rule = horizontal.get(index)
        y = sum(heights[:index])
        paths.extend(
            _table_rule(
                (0, y),
                (sum(widths), y),
                thin,
                size,
                dashed=bool(rule and rule.dashed),
            )
        )
    return paths


def _layout_table(table: Table, font: Font, font_path: str | None, memo: _LayoutMemo) -> _MathBox:
    # 2026-10-20：以各列最大墨迹宽度和各行高度定位，分数与普通文字共用手写字形。
    size = font_size_of(font)
    pad = max(3, round(size * 0.22))
    gap = max(4, round(size * 0.20))
    boxes = [[_layout_math_text(cell, font, font_path, memo) for cell in row] for row in table.rows]
    widths = [
        max(box.bbox[2] - box.bbox[0] for box in column) + pad * 2
        for column in zip(*boxes, strict=True)
    ]
    # 2026-10-20：整表统一行高，单元格按实际墨迹居中，分数不挤压相邻行。
    row_height = (
        max(max(box.bbox[3] - box.bbox[1], round(size * 0.65)) for row in boxes for box in row)
        + gap * 2
    )
    heights = [row_height] * len(boxes)
    children: list[BoxChild] = []
    y = 0
    for row, height in zip(boxes, heights, strict=True):
        x = 0
        for box, width in zip(row, widths, strict=True):
            children.append(
                (
                    box,
                    x + (width - box.bbox[2] + box.bbox[0]) // 2 - box.bbox[0],
                    y + (height - box.bbox[3] + box.bbox[1]) // 2 - box.bbox[1],
                )
            )
            x += width
        y += height
    # 2026-10-20：补齐每个单元格的四边；全部格线同宽，原文虚线保留虚线样式。
    paths = _table_grid_paths(table, widths, heights, size)
    return _compose_box(sum(widths) + pad, children, paths)


def _layout_math_char(char: str, font: Font, font_path: str | None, memo: _LayoutMemo) -> _MathBox:
    size = font_size_of(font)
    if char in _TABLE_MAP:
        return _layout_table(_TABLE_MAP[char], font, font_path, memo)
    if char in _ACCENT_MAP:
        return _layout_accent(_ACCENT_MAP[char], font, font_path, memo)
    if char in _SCRIPT_MAP:
        parts = [
            _layout_script(content, font, font_path, memo, superscript=superscript)
            for content, superscript in _SCRIPT_MAP[char]
        ]
        return _compose_box(
            max(part.advance for part in parts), tuple((part, 0, 0) for part in parts)
        )
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
        return _compose_box(
            line_width + max(3, round(size * 0.1)),
            ((num, nx, ny), (den, dx, dy)),
            ((((1, axis), (line_width - 1, axis)), thickness),),
        )
    if char in _RADICAL_MAP:
        radicand, index = _RADICAL_MAP[char]
        body = _layout_math_text(radicand, font, font_path, memo)
        gap = max(2, round(size * 0.09))
        top = body.bbox[1] - gap
        bottom = max(body.bbox[3], top + round(size * 0.58))
        height = bottom - top
        stem_width = max(10, round(size * 0.46))
        thickness = max(1, round(size * 0.035))
        offset = 0
        children: list[BoxChild] = []
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
        points = (
            (offset + 1, top + round(height * 0.63)),
            (offset + round(stem_width * 0.20), top + round(height * 0.55)),
            (offset + round(stem_width * 0.43), bottom - 1),
            (offset + stem_width - 2, top),
            (right, top),
        )
        return _compose_box(right + gap, children, ((points, thickness),))
    chosen, bbox, advance = _get_char_glyph_and_bbox(char, font, font_path)
    return _MathBox(advance, bbox, glyph=char, font=chosen)


def _layout_math_text(
    text: str, font: Font, font_path: str | None = None, memo: _LayoutMemo | None = None
) -> _MathBox:
    if memo is None:
        memo = _LayoutMemo()
    # 2026-10-15：分式/根式注册时保留的基底文本也可包含前端组合附加符。
    text = convert_accents_to_drawn(text)
    font_path = font_path or font_path_of(font)
    key = (text, id(font))
    if key in memo.boxes:
        return memo.boxes[key]
    active = memo.active
    if key in active or len(active) >= _MAX_MATH_DEPTH:
        # 2026-10-15：极深脚标或外部传入的私用字符循环按字面渲染，不能递归耗尽栈。
        x = 0
        children: list[BoxChild] = []
        for char in text:
            chosen, bbox, advance = _get_char_glyph_and_bbox(char, font, font_path)
            children.append((_MathBox(advance, bbox, glyph=char, font=chosen), x, 0))
            x += advance
        return _compose_box(x, children)
    active.add(key)
    x, index = 0, 0
    children: list[BoxChild] = []
    while index < len(text):
        token = _script_token(text, index)
        if token:
            content, superscript, index = token
            box = _layout_script(content, font, font_path, memo, superscript=superscript)
            following = _script_token(text, index) if index < len(text) else None
            if following and following[1] != superscript:
                other = _layout_script(
                    following[0], font, font_path, memo, superscript=following[1]
                )
                box = _compose_box(max(box.advance, other.advance), ((box, 0, 0), (other, 0, 0)))
                index = following[2]
        else:
            box = _layout_math_char(text[index], font, font_path, memo)
            index += 1
        children.append((box, x, 0))
        x += box.advance
    result = _compose_box(x, children)
    active.remove(key)
    memo.boxes[key] = result
    return result


def _paint_math_box(draw: ImageDraw.ImageDraw, box: _MathBox, xy: tuple[int, int]) -> None:

    x, y = xy
    if box.glyph is not None:
        cast("MathDrawer", draw).text((x, y), box.glyph, fill=MONOCHROME_WHITE, font=box.font)
    for child, dx, dy in box.children:
        _paint_math_box(draw, child, (x + dx, y + dy))
    for points, thickness in box.paths:
        draw.line(
            [(x + px, y + py) for px, py in points],
            fill=MONOCHROME_WHITE,
            width=thickness,
            joint="curve",
        )


def _draw_text_or_fraction(
    draw: ImageDraw.ImageDraw, text: str, xy: tuple[int, int], font: Font, font_path: str | None
) -> tuple[int, int]:
    box = _layout_math_text(text, font, font_path)
    _paint_math_box(draw, box, xy)
    return box.advance, box.bbox[3] - box.bbox[1]


def _measure_text_or_fraction(text: str, font: Font, font_path: str | None) -> tuple[int, int]:
    box = _layout_math_text(text, font, font_path)
    return box.advance, box.bbox[3] - box.bbox[1]


def _get_rendered_text_bbox(
    text: str, font: Font, font_path: str | None
) -> tuple[int, int, int, int]:
    return _layout_math_text(text, font, font_path).bbox


def _fallback_draw_char(
    original: Callable[[ImageDraw.ImageDraw, str, tuple[int, int], Font], int],
) -> Callable[[ImageDraw.ImageDraw, str, tuple[int, int], Font], int]:
    def fallback_draw_char(
        draw: ImageDraw.ImageDraw, char: str, xy: tuple[int, int], font: Font
    ) -> int:
        if char in (" ", "\t", "\n"):
            return original(draw, char, xy, font)

        # 2026-10-15：复合公式和脚标使用同一测量/绘制盒，保留主字体手写字形。
        if is_math_glyph(char):
            return _draw_text_or_fraction(draw, char, xy, font, font_path_of(font))[0]

        font_path = font_path_of(font)
        font_size = font_size_of(font)
        fb_font, _bb, adv, is_fallback = _get_char_glyph_and_bbox_cached(char, font_path, font_size)
        if is_fallback:
            cast("MathDrawer", draw).text(xy, char, fill=MONOCHROME_WHITE, font=fb_font)
            return adv

        return original(draw, char, xy, font)

    return fallback_draw_char


def _cached_get_font(template: Template, rand: Random) -> Font:
    font = template.get_font()
    sigma = template.get_font_size_sigma()
    if not sigma or not isinstance(font, ImageFont.FreeTypeFont):
        return font
    actual_font_size = max(int(rand.gauss(font.size, sigma)), 1)
    if actual_font_size == font.size:
        return font

    key = (font, actual_font_size)
    variant = _FONT_VARIANTS.get(key)
    if variant is None:
        variant = font.font_variant(size=actual_font_size)
        if len(_FONT_VARIANTS) >= MAX_FONT_VARIANTS:
            _FONT_VARIANTS.clear()
        _FONT_VARIANTS[key] = variant
    return variant


def init_glyph_fallback_engine() -> None:
    """初始化底层 handright 绘制引擎的真实字形 Fallback 挂载与变体缓存优化."""
    if _state.initialized:
        return

    if not ttfont_type:
        logger.warning("未安装 fontTools，跳过真实字形 Fallback 挂载")
        _state.initialized = True
        return

    # 1. 扫描并缓存备用字库的 cmap
    for font_path in _find_fallback_font_files():
        try:
            cmap = _get_font_cmap(font_path)
            if cmap:
                _FALLBACK_FONTS_POOL.append((font_path, cmap))
        except Exception as e:
            logger.debug("读取备用字体 cmap 失败 (%s): %s", font_path, e, exc_info=True)

    # 2. 挂载 handright._core._draw_char 与 handright._core._get_font
    try:
        orig_draw_char = cast(
            "Callable[[ImageDraw.ImageDraw, str, tuple[int, int], Font], int]",
            member(core, "_draw_char"),
        )

        install_member(core, "_draw_char", _fallback_draw_char(orig_draw_char))

        # 挂载带缓存的 _get_font，彻底解决 FreeType 每字重复重载导致的内存溢出 (Out Of Memory)
        install_member(core, "_get_font", _cached_get_font)
        # 2026-10-15：只对含复合数学字形的文本按实际墨迹调整换行与行距。
        install_math_page_layout(core, is_math_glyph, _get_rendered_text_bbox)
        logger.info(
            "真实字形 Fallback 引擎挂载成功，已加载 %s 款备用字库", len(_FALLBACK_FONTS_POOL)
        )
    except Exception as e:
        logger.warning("挂载字形 Fallback 引擎失败: %s", e, exc_info=True)

    _state.initialized = True


# 模块导入时自动初始化
init_glyph_fallback_engine()


def clean_invisible_and_special_characters(text: str) -> str:
    """清理文本中的不可见字符、Word 公式特殊空格以及通用数学符号规范化."""
    if not text:
        return ""

    chars: list[str] = []
    for ch in text:
        if ch in _INVISIBLE_AND_SPECIAL_SPACES:
            chars.append(_INVISIBLE_AND_SPECIAL_SPACES[ch])
        elif ch in _UNIVERSAL_CANONICAL_MAP:
            chars.append(_UNIVERSAL_CANONICAL_MAP[ch])
        else:
            chars.append(ch)

    return "".join(chars)


def normalize_text_for_font(text: str, font_path: str | None = None) -> str:
    """Normalize mathematical text while preserving protected literal content."""
    if not text:
        return ""
    _ = font_path
    # 确保引擎已挂载
    if not _state.initialized:
        init_glyph_fallback_engine()

    cleaned = clean_invisible_and_special_characters(text)
    # 2026-10-20：先解码表格 JSON 单元格，避免数学转换破坏引号中的反斜杠转义。
    return _transform_math_segments(convert_tables_to_drawn(cleaned), _normalize_math_content)


def _normalize_math_content(segment: str) -> str:
    return convert_accents_to_drawn(
        convert_scripts_to_drawn(
            convert_radicals_to_drawn(convert_slashed_fractions_to_vertical(segment))
        )
    )


# Public typed integration boundaries used by the API and rendering tools.
get_cached_image_font = _get_cached_image_font
get_rendered_text_bbox = _get_rendered_text_bbox
measure_text_or_fraction = _measure_text_or_fraction

measure_math_text = _measure_text_or_fraction
render_math_text = _draw_text_or_fraction
math_text_bbox = _get_rendered_text_bbox


def measure_drawn_advance(char: str, font: Font) -> int:
    """Measure the actual installed handright callback, including whitespace."""
    draw = ImageDraw.Draw(Image.new("1", (1, 1)))
    callback = cast(
        "Callable[[ImageDraw.ImageDraw, str, tuple[int, int], Font], int]",
        member(core, "_draw_char"),
    )
    return callback(draw, char, (0, 0), font)
