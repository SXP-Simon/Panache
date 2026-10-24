# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：从当前字体采样数学笔触，只改变笔画而不扰动公式布局."""

import itertools
import math
from collections.abc import Generator, Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass
from statistics import median
from threading import RLock
from typing import Protocol, cast
from weakref import WeakKeyDictionary

from handright import Template
from PIL import ImageFont

type Font = ImageFont.FreeTypeFont | ImageFont.ImageFont
type Points = tuple[tuple[int, int], ...]
type PenPath = tuple[Points, int]
type RootProfile = tuple[tuple[float, float], ...]

SYMBOLS = frozenset("¬→←↔⇒⇐⇔≤≥≠")
_NATURALNESS: ContextVar[float] = ContextVar("math_pen_naturalness", default=0)
_INK_THRESHOLD = 127
_ROOT_SAMPLE_SIZE = 96
_MIN_ROOT_COLUMNS = 8
_VALLEY_X_RANGE = (0.15, 0.8)


class _Mask(Protocol):
    size: tuple[int, int]

    def getbbox(self) -> tuple[int, int, int, int] | None: ...
    def __iter__(self) -> Iterator[int]: ...
    def __getitem__(self, index: int) -> int: ...


class _MaskFont(Protocol):
    def getmask(self, text: str) -> _Mask: ...


@dataclass(frozen=True)
class Pen:
    """2026-10-24：字库采样失败时使用受字号约束的保守笔触."""

    size: int
    width: int
    slant: float
    root_profile: RootProfile = ()

    @property
    def naturalness(self) -> float:
        """2026-10-24：读取当前请求的有界自然度，不在字库采样结果中保存请求状态."""
        return _NATURALNESS.get()

    def path(self, points: Points) -> PenPath:
        """2026-10-24：固定连接端点，小幅弧线由已有自然度控制并限制在安全间隙内."""
        result: list[tuple[int, int]] = []
        amplitude = self.size * 0.016 * _NATURALNESS.get()
        for start, end in itertools.pairwise(points):
            dx, dy = end[0] - start[0], end[1] - start[1]
            length = max(1, math.hypot(dx, dy))
            bend = amplitude * min(1, length / max(1, self.size * 0.5))
            for step in range(9):
                t = step / 8
                offset = bend * math.sin(math.pi * t)
                x = start[0] + dx * t - dy / length * offset
                y = start[1] + dy * t + dx / length * offset
                point = (round(x), round(y))
                if not result or result[-1] != point:
                    result.append(point)
        return tuple(result), self.width

    def radical_path(
        self, hook: tuple[int, int, int, int], right: int, index_right: int | None = None
    ) -> PenPath:
        """2026-10-24：仅适配主字体根钩轮廓，封顶端点和被开方数布局保持固定."""
        offset, top, stem_width, height = hook
        if self.root_profile:
            points = tuple(
                (
                    offset + 1 + round(x * (stem_width - 3)),
                    top + round(y * (height - 1)),
                )
                for x, y in self.root_profile
            )
        else:
            points = (
                (offset + 1, top + round(height * 0.63)),
                (offset + round(stem_width * 0.20), top + round(height * 0.55)),
                (offset + round(stem_width * 0.43), top + height - 1),
                (offset + stem_width - 2, top),
            )
        if index_right is not None:
            # 2026-10-24：起笔较高的勾形根号仍须避开既有根指数，不移动指数本身。
            clearance = self.width + max(2, round(self.size * 0.04))
            floor = top + round(height * 0.34) + clearance
            points = tuple(
                (x, max(y, floor) if x <= index_right + clearance else y) for x, y in points
            )
        # 2026-10-24：最后一段始终从原封顶起点接出，不将原生字形横向拉长。
        points = (*points[:-1], (offset + stem_width - 2, top), (right, top))
        return self.path(points)


_PEN_CACHE: WeakKeyDictionary[Font, dict[int, Pen]] = WeakKeyDictionary()
_PEN_CACHE_LOCK = RLock()


def font_pen(font: Font, size: int) -> Pen:
    """2026-10-24：弱引用缓存采样结果，上传字体可在请求结束后正常释放."""
    with _PEN_CACHE_LOCK:
        samples = _PEN_CACHE.get(font)
        if samples is None:
            samples = {}
            _PEN_CACHE[font] = samples
        if size not in samples:
            samples[size] = _sample_font_pen(font, size)
        return samples[size]


def _sample_font_pen(font: Font, size: int) -> Pen:
    """2026-10-24：横画估计笔宽，竖画上下墨迹估计斜度，不读取备用字体的风格."""
    width = max(1, round(size * 0.03))
    sampler = cast("_MaskFont", font)
    dash = sampler.getmask("-")
    bounds = dash.getbbox()
    if bounds and bounds[3] - bounds[1] <= size * 0.22:
        coverage = sum(value / 255 for value in dash)
        width = round(coverage / max(1, bounds[2] - bounds[0]))
    width = max(1, min(round(size * 0.055), width))
    slant = 0.0
    stem = sampler.getmask("l")
    bounds = stem.getbbox()
    if bounds:
        w, _ = stem.size
        top, bottom = bounds[1], bounds[3]
        band = max(1, (bottom - top) // 4)
        upper = [
            x for y in range(top, top + band) for x in range(w) if stem[y * w + x] > _INK_THRESHOLD
        ]
        lower = [
            x
            for y in range(bottom - band, bottom)
            for x in range(w)
            if stem[y * w + x] > _INK_THRESHOLD
        ]
        if upper and lower:
            slant = max(-0.18, min(0.18, (median(upper) - median(lower)) / max(1, bottom - top)))
    return Pen(size, width, slant, _sample_root_profile(font))


def _sample_root_profile(font: Font) -> RootProfile:
    """2026-10-24：从原生根号列中心采样起笔、谷底和上升臂，空白/占位框安全回退."""
    if not isinstance(font, ImageFont.FreeTypeFont):
        return ()
    try:
        # 2026-10-24：固定小画布采样，避免小字号失真或超大字号产生二次方开销。
        native = font.font_variant(size=_ROOT_SAMPLE_SIZE)
        mask = cast("_MaskFont", native).getmask("√")
        return _root_profile_from_mask(mask)
    except (OSError, ValueError, UnicodeError):
        return ()


def _root_profile_from_mask(mask: _Mask) -> RootProfile:
    """2026-10-24：提取列中心与最低转折，拒绝占位框和缺少上升臂的异常字形."""
    bounds = mask.getbbox()
    if bounds is None:
        return ()
    width, _ = mask.size
    columns = [
        [y for y in range(bounds[1], bounds[3]) if mask[y * width + x] > _INK_THRESHOLD]
        for x in range(bounds[0], bounds[2])
    ]
    centers = [(x, float(median(ys))) for x, ys in enumerate(columns) if ys]
    if len(centers) < _MIN_ROOT_COLUMNS:
        return ()
    ys = [y for _, y in centers]
    low, high = min(ys), max(ys)
    if high - low < (bounds[3] - bounds[1]) * 0.45:
        return ()
    valley = max(range(len(centers)), key=lambda index: centers[index][1])
    if not _VALLEY_X_RANGE[0] < valley / (len(centers) - 1) < _VALLEY_X_RANGE[1]:
        return ()
    end = next(
        (
            index
            for index in range(valley + 1, len(centers))
            if ys[index] <= low + (high - low) * 0.1
        ),
        len(centers) - 1,
    )
    start_x, _ = centers[0]
    end_x, end_y = centers[end]
    if high - end_y < (high - low) * 0.6 or end_x <= start_x:
        return ()
    positions = sorted({round(end * step / 8) for step in range(9)} | {valley})
    profile = tuple(
        ((centers[index][0] - start_x) / (end_x - start_x), (ys[index] - low) / (high - low))
        for index in positions
    )
    return (*profile[:-1], (1.0, 0.0))


@contextmanager
def template_pen(template: Template) -> Generator[None, None, None]:
    """2026-10-24：请求隔离地复用笔画偏移和旋转设置，不改变随机数流与用户参数."""
    size = getattr(template.get_font(), "size", 30)
    strength = min(
        1.0,
        max(
            template.get_perturb_x_sigma() / max(1, size * 0.04),
            template.get_perturb_y_sigma() / max(1, size * 0.04),
            template.get_perturb_theta_sigma() / 0.08,
        ),
    )
    token = _NATURALNESS.set(strength)
    try:
        yield
    finally:
        _NATURALNESS.reset(token)


def symbol_paths(char: str, pen: Pen, axis: int) -> tuple[int, tuple[PenPath, ...]]:
    """2026-10-24：独立保留箭头朝向、双横线和否定短竖，绝不以近似字符替换含义."""
    size = pen.size
    width = max(4, round(size * (0.83 if char in "→←↔⇒⇐⇔" else 0.5)))
    half = max(2, round(size * 0.18))
    gap = max(pen.width * 2 + 1, round(size * 0.13))
    paths: list[Points]
    if char == "¬":
        paths = [((0, axis), (width, axis), (width, axis + half))]
    elif char in "<≥>≤":
        y = axis - gap // 2 if char in "≤≥" else axis
        tip, edge = (0, width) if char in "<≤" else (width, 0)
        paths = [((edge, y - half), (tip, y), (edge, y + half))]
        if char in "≤≥":
            paths.append(((0, y + half + gap), (width, y + half + gap)))
    elif char == "≠":
        paths = [((0, axis - gap), (width, axis - gap)), ((0, axis + gap), (width, axis + gap))]
        paths.append(
            ((round(width * 0.8), axis - half - gap), (round(width * 0.2), axis + half + gap))
        )
    else:
        double = char in "⇒⇐⇔"
        levels = (axis - gap // 2, axis + gap // 2) if double else (axis,)
        head = max(half, round(size * 0.23))
        reach = half + gap // 2 if double else half
        inset = round(head * (gap // 2) / reach) if double else 0
        left = inset if char in "←↔⇐⇔" else 0
        right = width - inset if char in "→↔⇒⇔" else width
        paths = [((left, y), (right, y)) for y in levels]
        if char in "→↔⇒⇔":
            paths.append(
                ((width - head, axis - reach), (width, axis), (width - head, axis + reach))
            )
        if char in "←↔⇐⇔":
            paths.append(((head, axis - reach), (0, axis), (head, axis + reach)))
    # 2026-10-24：以数学中轴为锚点剪切笔画；公式文字、上下标和行基线不随之漂移。
    transformed = tuple(
        pen.path(tuple((round(x + pen.slant * (axis - y)), y) for x, y in points))
        for points in paths
    )
    return width + max(2, round(size * 0.09)), transformed
