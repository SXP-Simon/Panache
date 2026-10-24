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
    """2026-10-24：用不等长弧段画偏斜、上窄下宽的手绘圈，避免近似正圆."""
    points: list[tuple[int, int]] = []
    curves = (
        ((0.30, 0.02), (0.60, -0.045), (0.94, 0.015), (1.00, 0.34)),
        ((1.00, 0.34), (1.045, 0.63), (0.88, 0.98), (0.60, 1.00)),
        ((0.60, 1.00), (0.29, 1.015), (0.06, 0.88), (0.02, 0.60)),
        ((0.02, 0.60), (-0.04, 0.35), (0.07, 0.105), (0.30, 0.02)),
    )
    steps = max(20, min(1024, width + height))
    shear = 0.14 + 0.04 * math.sin(phase) + pen.slant * 0.25
    for segment, curve in enumerate(curves):
        for step in range(steps):
            t = step / steps
            weights = ((1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t**3)
            x = sum(weight * point[0] for weight, point in zip(weights, curve, strict=True))
            y = sum(weight * point[1] for weight, point in zip(weights, curve, strict=True))
            angle = math.tau * (segment + t) / 4
            x = 0.5 + (x - 0.5) * (1 + 0.025 * math.sin(phase))
            x += pen.naturalness * 0.01 * math.sin(2 * angle)
            y += pen.naturalness * 0.008 * math.sin(angle)
            points.append((round(width * x + height * shear * (0.5 - y)), round(height * y)))
    points.append(points[0])
    return tuple(points), pen.width
