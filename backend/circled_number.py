# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：保留圈号原字符语义，以当前手写字体数字与自然闭合圈组合绘制."""

import io
import math
import os
from pathlib import Path
from threading import RLock
from weakref import WeakKeyDictionary

from fontTools.ttLib import TTFont, TTLibError

if __package__:
    from .math_pen import Font, Pen
else:
    from math_pen import Font, Pen

_NATIVE_CIRCLES: WeakKeyDictionary[Font, frozenset[int]] = WeakKeyDictionary()
_NATIVE_LOCK = RLock()
_CIRCLE_POINTS = (0x24EA, *range(0x2460, 0x2474), *range(0x3251, 0x3260), *range(0x32B1, 0x32C0))


def native_circled_available(font: Font, char: str) -> bool:
    """2026-10-24：只查询主字体码表，弱缓存不持有上传字体或其二进制内容."""
    with _NATIVE_LOCK:
        supported = _NATIVE_CIRCLES.get(font)
        if supported is None:
            path: object = getattr(font, "path", None)
            data: object = getattr(font, "font_bytes", None)
            source: str | io.BytesIO | None = None
            if isinstance(path, (str, bytes, Path)):
                source = os.fsdecode(path)
            elif isinstance(data, bytes):
                source = io.BytesIO(data)
            elif isinstance(path, io.BytesIO):
                source = io.BytesIO(path.getvalue())
            supported = frozenset[int]()
            if source is not None:
                try:
                    native = TTFont(source, fontNumber=0)
                    cmap = native.getBestCmap() or {}
                    supported = frozenset(
                        cp for cp in _CIRCLE_POINTS if cp in cmap and cmap[cp] != ".notdef"
                    )
                    native.close()
                except (OSError, ValueError, TTLibError):
                    supported = frozenset[int]()
            _NATIVE_CIRCLES[font] = supported
        return ord(char) in supported


def circled_number(char: str) -> str | None:
    """2026-10-24：仅识别 Unicode 公开圈号范围，不改括号序号、带圈字母或数字正文."""
    value = ord(char)
    if char == "⓪":
        return "0"
    for start, end, first in ((0x2460, 0x2473, 1), (0x3251, 0x325F, 21), (0x32B1, 0x32BF, 36)):
        if start <= value <= end:
            return str(first + value - start)
    return None


def circle_path(
    width: int, height: int, pen: Pen, phase: float = 0
) -> tuple[tuple[tuple[int, int], ...], int]:
    """2026-10-24：轻微椭圆、倾斜和连贯不规则度模拟一笔画圈，末端明确闭合."""
    points: list[tuple[int, int]] = []
    steps = max(80, min(4096, 4 * (width + height)))
    for step in range(steps + 1):
        angle = math.tau * step / steps
        radius = 1 + 0.025 * math.sin(2 * angle + pen.slant * 8 + phase)
        radius += pen.naturalness * 0.035 * math.sin(3 * angle + 0.7 + phase)
        x = width / 2 + width / 2 * math.cos(angle) * radius
        x += height * (pen.slant * 0.25 + 0.045) * math.sin(angle)
        y = height / 2 + height / 2 * math.sin(angle) * radius
        points.append((round(x), round(y)))
    points[-1] = points[0]
    return tuple(points), pen.width
