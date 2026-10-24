# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：保留主字体根钩与横画的原生墨迹，仅在高公式中适配高度."""

import math
from dataclasses import dataclass
from itertools import groupby
from statistics import median
from threading import RLock
from typing import Protocol, cast
from weakref import WeakKeyDictionary

from PIL import Image, ImageDraw, ImageFont

if __package__:
    from .math_pen import Pen
else:
    from math_pen import Pen

type Font = ImageFont.FreeTypeFont | ImageFont.ImageFont
_SAMPLE_SIZE_LIMIT = 128
_MASK_SIDE_LIMIT = 4096
_ROOF_WIDTH_LIMIT = 4096
_MASK_PIXEL_LIMIT = 1_000_000
_MIN_ROOT_COLUMNS = 8
_MIN_VALIDATION_SIZE = 24
_MIN_CAP_WIDTH = 3


class _Pixels(Protocol):
    def tobytes(self) -> bytes: ...


class _Bounds(Protocol):
    def getbbox(self, text: str) -> tuple[int, int, int, int]: ...


class _Drawer(Protocol):
    def text(
        self, xy: tuple[int, int], text: str, *, font: ImageFont.FreeTypeFont, fill: int
    ) -> None: ...


@dataclass(frozen=True)
class NativeRoot:
    """2026-10-24：弱缓存值只含像素和字号，不能持有请求字体对象."""

    hook: Image.Image
    bar: Image.Image | None
    size: int


_CACHE: WeakKeyDictionary[Font, NativeRoot | None] = WeakKeyDictionary()
_LOCK = RLock()


def native_root(font: Font) -> NativeRoot | None:
    """2026-10-24：仅采样当前字体，缺字或异常根号交由调用方补绘."""
    with _LOCK:
        if font not in _CACHE:
            _CACHE[font] = _sample(font)
        return _CACHE[font]


def _sample(font: Font) -> NativeRoot | None:
    if not isinstance(font, ImageFont.FreeTypeFont):
        return None
    size = min(font.size, _SAMPLE_SIZE_LIMIT)
    try:
        source = font if font.size == size else font.font_variant(size=size)
        hook = _glyph(source, "√")
        validation = (
            _glyph(source.font_variant(size=64), "√") if size < _MIN_VALIDATION_SIZE else hook
        )
        if hook is None or validation is None or not _valid_hook(validation):
            return None
        bar = _glyph(source, "-")
        if bar is not None and bar.height > size * 0.22:
            bar = None
        return NativeRoot(hook, bar, size)
    except (OSError, ValueError, UnicodeError):
        return None


def _glyph(font: ImageFont.FreeTypeFont, char: str) -> Image.Image | None:
    left, top, right, bottom = cast("_Bounds", font).getbbox(char)
    width, height = right - left, bottom - top
    if width <= 0 or height <= 0 or not _within_budget(width, height):
        return None
    mask = Image.new("1", (width, height))
    cast("_Drawer", ImageDraw.Draw(mask)).text((-left, -top), char, font=font, fill=1)
    bounds = mask.getbbox()
    return mask.crop(bounds) if bounds else None


def _within_budget(width: int, height: int) -> bool:
    return max(width, height) <= _MASK_SIDE_LIMIT and width * height <= _MASK_PIXEL_LIMIT


def _valid_hook(mask: Image.Image) -> bool:
    # 2026-10-24：形态检查只拒绝占位框，不将采样中心线重新描成等宽笔画。
    pixels = cast("_Pixels", mask.convert("L")).tobytes()
    centers = [
        median(rows)
        for x in range(mask.width)
        if (rows := [y for y in range(mask.height) if pixels[y * mask.width + x]])
    ]
    if len(centers) < _MIN_ROOT_COLUMNS:
        return False
    valley = max(range(len(centers)), key=centers.__getitem__)
    return (
        max(centers) - min(centers) > mask.height * 0.45
        and mask.width * 0.10 < valley < mask.width * 0.8
        and centers[-1] < max(centers) - mask.height * 0.4
    )


def fit_hook(ink: NativeRoot, size: int, required_height: int) -> Image.Image | None:
    """2026-10-24：普通根式保留原生像素，高分式才竖向适配，不横向压扁根钩."""
    ratio = size / ink.size
    width = max(1, round(ink.hook.width * ratio))
    natural_height = max(1, round(ink.hook.height * ratio))
    height = natural_height if required_height <= natural_height * 1.35 else required_height
    if not _within_budget(width, height):
        return None
    return (
        ink.hook
        if (width, height) == ink.hook.size
        else ink.hook.resize((width, height), Image.Resampling.NEAREST)
    )


def hook_join(mask: Image.Image) -> tuple[int, int]:
    """2026-10-24：封顶线连接上升臂真实墨迹，而非理想字框的右上角."""
    pixels = cast("_Pixels", mask.convert("L")).tobytes()
    for x in range(mask.width - 1, -1, -1):
        rows = [y for y in range(max(1, mask.height // 3)) if pixels[y * mask.width + x]]
        if rows:
            return x, round(median(rows))
    return mask.width - 1, 0


def index_clearance(mask: Image.Image, ceiling: int, right: int, padding: int) -> int:
    """2026-10-24：根据原生墨迹让开根指数，不能裁掉粗笔或改画起笔."""
    pixels = cast("_Pixels", mask.convert("L")).tobytes()
    xs = [
        x
        for y in range(max(0, min(mask.height, ceiling + padding + 1)))
        for x in range(mask.width)
        if pixels[y * mask.width + x]
    ]
    return max(0, right + padding - min(xs)) if xs else 0


def _extend_bar(bar: Image.Image, width: int, height: int) -> Image.Image:
    """2026-10-24：保留横画两端原生收笔，仅延长中段，避免把细尾端拉成大片空白."""
    if width <= bar.width or bar.width < _MIN_CAP_WIDTH:
        return bar.resize((width, height), Image.Resampling.NEAREST)
    bar = bar.resize((bar.width, height), Image.Resampling.NEAREST)
    cap = max(1, bar.width // 3)
    image = Image.new("1", (width, height))
    image.paste(bar.crop((0, 0, cap, height)), (0, 0))
    image.paste(
        bar.crop((cap, 0, max(cap + 1, bar.width - cap), height)).resize(
            (width - cap * 2, height), Image.Resampling.NEAREST
        ),
        (cap, 0),
    )
    image.paste(bar.crop((bar.width - cap, 0, bar.width, height)), (width - cap, 0))
    return image


def roof_mask(ink: NativeRoot, width: int, pen: Pen) -> tuple[Image.Image, int] | None:
    """2026-10-24：延续主字体横画的笔粗与边缘，轻微偏斜保留收笔，不画尺子直线."""
    if width > _ROOF_WIDTH_LIMIT or width <= 0:
        return None
    bar = ink.bar
    height = max(1, round(bar.height * pen.size / ink.size)) if bar else pen.width
    amplitude = max(1, round(pen.size * 0.012))
    if not _within_budget(width, height + amplitude + math.ceil(pen.size * 0.016)):
        return None
    image = _extend_bar(bar, width, height) if bar else Image.new("1", (width, height), 1)
    # 2026-10-24：确定性的小幅不对称存在于静态字迹中，自然度仅附加有界弧度。
    offsets = [
        round(
            amplitude
            * (0.55 * x / max(1, width - 1) + 0.45 * math.sin(math.pi * x / max(1, width - 1)))
            + pen.size * 0.016 * pen.naturalness * math.sin(math.pi * x / max(1, width - 1))
        )
        for x in range(width)
    ]
    result = Image.new("1", (width, height + max(offsets)))
    for offset, group in groupby(enumerate(offsets), key=lambda column: column[1]):
        columns = [x for x, _ in group]
        result.paste(image.crop((columns[0], 0, columns[-1] + 1, height)), (columns[0], offset))
    pixels = cast("_Pixels", image.convert("L")).tobytes()
    first = [y for y in range(height) if pixels[y * width]]
    return result, round(median(first)) if first else height // 2
