# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：保留圈号原字符语义，以当前手写字体数字与自然闭合圈组合绘制."""

import math

if __package__:
    from .math_pen import Pen
else:
    from math_pen import Pen


def circled_number(char: str) -> str | None:
    """2026-10-24：仅识别 Unicode 公开圈号范围，不改括号序号、带圈字母或数字正文."""
    value = ord(char)
    if char == "⓪":
        return "0"
    for start, end, first in ((0x2460, 0x2473, 1), (0x3251, 0x325F, 21), (0x32B1, 0x32BF, 36)):
        if start <= value <= end:
            return str(first + value - start)
    return None


def circle_path(width: int, height: int, pen: Pen) -> tuple[tuple[tuple[int, int], ...], int]:
    """2026-10-24：轻微椭圆、倾斜和连贯不规则度模拟一笔画圈，末端明确闭合."""
    points: list[tuple[int, int]] = []
    steps = max(80, min(4096, 4 * (width + height)))
    for step in range(steps + 1):
        angle = math.tau * step / steps
        radius = 1 + 0.014 * math.sin(2 * angle + pen.slant * 8)
        radius += pen.naturalness * 0.018 * math.sin(3 * angle + 0.7)
        x = width / 2 + width / 2 * math.cos(angle) * radius
        x += pen.slant * height * math.sin(angle) * 0.25
        y = height / 2 + height / 2 * math.sin(angle) * radius
        points.append((round(x), round(y)))
    points[-1] = points[0]
    return tuple(points), pen.width
