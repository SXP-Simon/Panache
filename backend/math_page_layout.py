# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""含复合数学字形的 handright 页布局."""

import functools
import math
import os
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from random import Random
from typing import Protocol, cast

from handright import Template
from handright._util import Page
from PIL import Image, ImageDraw
from PIL.ImageFont import FreeTypeFont, ImageFont

if __package__:
    from .library_boundary import install_member, member
else:
    from library_boundary import install_member, member


type Font = FreeTypeFont | ImageFont

type BBox = tuple[int, int, int, int]
type Raster = tuple[Image.Image, BBox, int]
type Unit = tuple[Image.Image, BBox, int, int]
type DrawPage = Callable[[Page, str, int, Template, Random], int]


class RuledTemplate(Template):
    """2026-10-17：保留纸张横线原点，插图临时调整上边距时也不改变行网格。."""

    __slots__ = ("ruled_origin",)

    ruled_origin: int


class StrokeDrawer(Protocol):
    """2026-10-15：只暴露引擎删除线需要的绘图接口."""

    def line(self, xy: tuple[float, ...], fill: int, width: int) -> None:
        """2026-10-15：记录一条指定粗细的笔画."""
        ...


@dataclass(frozen=True)
class _CoreAdapter:
    draw_page: DrawPage
    draw_char: Callable[[ImageDraw.ImageDraw, str, tuple[int, int], Font], int]
    get_font: Callable[[Template, Random], Font]
    check_template: Callable[[Page, Template], None]
    strike: Callable[[StrokeDrawer, int, int, Template, Random], None]
    gauss: Callable[[Random, float, float], float]
    white: int
    grid: int
    layout_error: type[Exception]


def _bindings(module: object) -> _CoreAdapter:
    """Validate the callable surface of the pinned handrightbeta engine."""
    for name in (
        "_draw_page",
        "_draw_char",
        "_get_font",
        "_check_template",
        "_draw_strikethrough",
        "gauss",
    ):
        value: object = getattr(module, name, None)
        if not callable(value):
            msg = f"handright engine member {name} is not callable"
            raise TypeError(msg)
    white: object = getattr(module, "_WHITE", None)
    feature: object = getattr(module, "Feature", None)
    grid: object = getattr(feature, "GRID_LAYOUT", None)
    error: object = getattr(module, "LayoutError", None)
    if not isinstance(white, int) or not isinstance(grid, int):
        msg = "handright engine constants are invalid"
        raise TypeError(msg)
    if not isinstance(error, type) or not issubclass(error, Exception):
        msg = "handright layout error class is invalid"
        raise TypeError(msg)
    return _CoreAdapter(
        cast("DrawPage", member(module, "_draw_page")),
        cast(
            "Callable[[ImageDraw.ImageDraw, str, tuple[int, int], Font], int]",
            member(module, "_draw_char"),
        ),
        cast("Callable[[Template, Random], Font]", member(module, "_get_font")),
        cast("Callable[[Page, Template], None]", member(module, "_check_template")),
        cast(
            "Callable[[StrokeDrawer, int, int, Template, Random], None]",
            member(module, "_draw_strikethrough"),
        ),
        cast("Callable[[Random, float, float], float]", member(module, "gauss")),
        white,
        grid,
        error,
    )


def _font_path(font: Font) -> str | None:
    value: object = getattr(font, "path", None)
    return os.fsdecode(value) if isinstance(value, (str, bytes, Path)) else None


def _font_size(font: Font) -> int:
    value: object = getattr(font, "size", 30)
    return value if isinstance(value, int) else 30


_MIN_FONT_SIZE = 8

type Stroke = tuple[tuple[float, ...], int, int]


@dataclass(frozen=True)
class _Area:
    width: int
    height: int


@dataclass(frozen=True)
class _Metrics:
    left: int
    top: int
    right: int
    bottom: int
    area: _Area
    spacing: int
    font_size: int
    grid: bool
    cell_width: int
    gap: int
    ruled_origin: int | None

    @classmethod
    def create(cls, page: Page, tpl: Template, api: _CoreAdapter) -> "_Metrics":
        api.check_template(page, tpl)
        left, top = tpl.get_left_margin(), tpl.get_top_margin()
        right = page.width() - tpl.get_right_margin()
        bottom = page.height() - tpl.get_bottom_margin()
        area = _Area(right - left, bottom - top)
        if area.width <= 0 or area.height <= 0:
            msg = "No writable area for mathematical glyphs"
            raise api.layout_error(msg)
        font_size = _font_size(tpl.get_font())
        return cls(
            left,
            top,
            right,
            bottom,
            area,
            tpl.get_line_spacing(),
            font_size,
            api.grid in tpl.get_features(),
            max(1, tpl.get_word_spacing() + font_size),
            max(2, round(font_size * 0.12)),
            tpl.ruled_origin if isinstance(tpl, RuledTemplate) else None,
        )


@dataclass
class _StrokeCapture:
    strokes: list[Stroke] = field(default_factory=list[Stroke])

    def line(self, xy: tuple[float, ...], fill: int, width: int) -> None:
        self.strokes.append((tuple(xy), fill, max(1, width)))


def _stroke_bounds(stroke: Stroke) -> BBox:
    points, _, thickness = stroke
    pad = (thickness + 1) // 2 + 1
    return (
        math.floor(min(points[::2]) - pad),
        math.floor(min(points[1::2]) - pad),
        math.ceil(max(points[::2]) + pad + 1),
        math.ceil(max(points[1::2]) + pad + 1),
    )


def _resize(image: Image.Image, ratio: float) -> Image.Image:
    return image.resize(
        (max(1, int(image.width * ratio)), max(1, int(image.height * ratio))),
        Image.Resampling.NEAREST,
    )


@dataclass(frozen=True)
class _PairCanvas:
    image: Image.Image
    left: int
    top: int
    ratio: float
    advance: int

    @classmethod
    def create(cls, bounds: list[BBox], advance: int, area: _Area) -> "_PairCanvas":
        left, top = min(bound[0] for bound in bounds), min(bound[1] for bound in bounds)
        right, bottom = max(bound[2] for bound in bounds), max(bound[3] for bound in bounds)
        # 2026-10-15：先缩放坐标再分配蒙版，极端删除线参数不能产生超大中间画布。
        ratio = min(
            1,
            area.width / max(1, max(advance, right) - min(0, left)),
            area.height / max(1, bottom - top),
        )
        size = (
            max(1, min(area.width, int((right - left) * ratio))),
            max(1, min(area.height, int((bottom - top) * ratio))),
        )
        return cls(Image.new("1", size, 0), left, top, ratio, advance)

    def paste(self, glyph: Image.Image, x: int, y: int) -> None:
        if self.ratio < 1:
            glyph = _resize(glyph, self.ratio)
        position = (
            max(0, min(self.image.width - glyph.width, round((x - self.left) * self.ratio))),
            max(0, min(self.image.height - glyph.height, round((y - self.top) * self.ratio))),
        )
        self.image.paste(glyph, position, glyph)

    def draw_strokes(self, strokes: list[Stroke]) -> None:
        draw = ImageDraw.Draw(self.image)
        for points, fill, thickness in strokes:
            draw.line(
                tuple(
                    round((value - (self.left if index % 2 == 0 else self.top)) * self.ratio)
                    for index, value in enumerate(points)
                ),
                fill=fill,
                width=max(1, round(thickness * self.ratio)),
            )

    def raster(self) -> Raster:
        left, top = math.floor(self.left * self.ratio), math.floor(self.top * self.ratio)
        bbox = (left, top, left + self.image.width, top + self.image.height)
        return self.image, bbox, max(1, math.floor(self.advance * self.ratio))


@dataclass(frozen=True)
class _MathLayout:
    api: _CoreAdapter
    is_math_glyph: Callable[[str], bool]
    measure_bbox: Callable[[str, Font, str | None], BBox]

    def raster(self, char: str, font: Font) -> Raster:
        # 2026-10-15：测量只用于预留画布，前进量始终取实际绘制的返回值。
        left, top, right, bottom = self.measure_bbox(char, font, _font_path(font))
        left, top = math.floor(left), math.floor(top)
        right, bottom = math.ceil(right), math.ceil(bottom)
        image = Image.new("1", (max(1, right - left + 4), max(1, bottom - top + 4)), 0)
        origin = (2 - left, 2 - top)
        advance = self.api.draw_char(ImageDraw.Draw(image), char, origin, font)
        ink = image.getbbox()
        if ink is None:
            return image.crop((0, 0, 1, 1)), (0, 0, 0, 0), max(1, advance)
        bbox = (ink[0] - origin[0], ink[1] - origin[1], ink[2] - origin[0], ink[3] - origin[1])
        return image.crop(ink), bbox, max(1, advance)

    def fit(self, char: str, font: Font, area: _Area) -> Raster:
        # 2026-10-15：先以字体原生尺寸重绘；极窄纸张再整体等比缩小，分式不拆开。
        bbox = self.measure_bbox(char, font, _font_path(font))
        while (
            isinstance(font, FreeTypeFont)
            and _font_size(font) > _MIN_FONT_SIZE
            and (bbox[2] - min(0, bbox[0]) > area.width or bbox[3] - bbox[1] > area.height)
        ):
            ratio = min(
                area.width / max(1, bbox[2] - min(0, bbox[0])),
                area.height / max(1, bbox[3] - bbox[1]),
            )
            font = font.font_variant(
                size=max(_MIN_FONT_SIZE, min(_font_size(font) - 1, int(_font_size(font) * ratio)))
            )
            bbox = self.measure_bbox(char, font, _font_path(font))
        image, bbox, advance = self.raster(char, font)
        width = max(advance, bbox[2]) - min(0, bbox[0])
        height = bbox[3] - bbox[1]
        ratio = min(1, area.width / max(1, width), area.height / max(1, height))
        if ratio < 1:
            image = _resize(image, ratio)
            left, top = math.floor(bbox[0] * ratio), math.floor(bbox[1] * ratio)
            bbox = (left, top, left + image.width, top + image.height)
            advance = max(1, math.floor(advance * ratio))
        return image, bbox, advance


@dataclass(frozen=True)
class _Correction:
    layout: _MathLayout
    tpl: Template
    rand: Random
    area: _Area

    def compose(self, correct: Raster, wrong: str, font: Font) -> Raster:
        # 2026-10-15：先划掉错字，再在其右侧写正确字，不能把两者叠成一个字。
        image, bbox, advance = correct
        wrong_image, wrong_bbox, wrong_advance = self.layout.fit(wrong, font, self.area)
        capture = _StrokeCapture()
        self.layout.api.strike(capture, 0, 0, self.tpl, self.rand)
        bounds = [wrong_bbox, *(_stroke_bounds(stroke) for stroke in capture.strokes)]
        wrong_right = max(bound[2] for bound in bounds)
        offset = max(
            wrong_advance + max(0, self.tpl.get_word_spacing()),
            wrong_right + max(2, round(_font_size(font) * 0.08)),
        )
        bounds.append((bbox[0] + offset, bbox[1], bbox[2] + offset, bbox[3]))
        canvas = _PairCanvas.create(bounds, advance + offset, self.area)
        canvas.paste(wrong_image, wrong_bbox[0], wrong_bbox[1])
        canvas.draw_strokes(capture.strokes)
        canvas.paste(image, bbox[0] + offset, bbox[1])
        return canvas.raster()


@dataclass
class _Glyph:
    raster: Raster
    font: Font
    x: int
    jitter_x: float
    jitter_y: int
    corrected: bool = False

    def unit(self) -> Unit:
        image, bbox, _ = self.raster
        return image, bbox, self.x, self.jitter_y


@dataclass
class _PageRenderer:
    layout: _MathLayout
    page: Page
    text: str
    tpl: Template
    rand: Random
    metrics: _Metrics = field(init=False)
    draw: ImageDraw.ImageDraw = field(init=False)
    correction: _Correction = field(init=False)
    candidates: tuple[str, ...] = field(init=False)
    previous_y: int | None = field(init=False, default=None)
    previous_bottom: int = field(init=False)

    def __post_init__(self) -> None:
        self.metrics = _Metrics.create(self.page, self.tpl, self.layout.api)
        self.draw = self.page.draw()
        self.correction = _Correction(self.layout, self.tpl, self.rand, self.metrics.area)
        self.previous_bottom = self.metrics.top - self.metrics.gap
        self.candidates = tuple(
            char for char in self.text if char not in self.tpl.get_end_chars() + " \n\t\r"
        )

    def _prepare(self, char: str, cursor: float) -> _Glyph:
        font = self.layout.api.get_font(self.tpl, self.rand)
        raster = self.layout.fit(char, font, self.metrics.area)
        jitter_x = (
            self.layout.api.gauss(self.rand, 0, self.tpl.get_word_spacing_sigma())
            if self.metrics.grid
            else 0
        )
        jitter_y = round(self.layout.api.gauss(self.rand, 0, self.tpl.get_line_spacing_sigma()))
        # 2026-10-15：保留位置扰动，但不能让负边承或网格抖动越过纸张左边距。
        x = max(self.metrics.left - raster[1][0], round(cursor + jitter_x))
        return _Glyph(raster, font, x, jitter_x, jitter_y)

    def _would_wrap(self, glyph: _Glyph, start: int, *, has_units: bool) -> bool:
        _, bbox, advance = glyph.raster
        if glyph.x + bbox[2] > self.metrics.right:
            if has_units:
                return True
            glyph.x = self.metrics.right - bbox[2]
        # 2026-10-15：开括号等禁行尾字符，在尚有空间时尽量与下一个字形一起换行。
        if (
            has_units
            and self.text[start] in self.tpl.get_start_chars()
            and start + 1 < len(self.text)
        ):
            next_bbox = self.layout.measure_bbox(
                self.text[start + 1], glyph.font, _font_path(glyph.font)
            )
            footprint = max(advance, bbox[2]) - min(0, bbox[0])
            return glyph.x + footprint + max(0, next_bbox[2]) > self.metrics.right
        return False

    def _correct(self, glyph: _Glyph, cursor: float, *, has_units: bool) -> bool:
        glyph.corrected = bool(
            self.candidates and self.rand.random() < self.tpl.get_strikethrough_probability()
        )
        if not glyph.corrected:
            return False
        # 2026-10-15：涂改使用引擎的笔画与参数，固定使用传入的局部随机源。
        glyph.raster = self.correction.compose(
            glyph.raster, self.rand.choice(self.candidates), glyph.font
        )
        bbox = glyph.raster[1]
        glyph.x = max(self.metrics.left - bbox[0], round(cursor + glyph.jitter_x))
        if has_units and glyph.x + bbox[2] > self.metrics.right:
            return True
        glyph.x = min(glyph.x, self.metrics.right - bbox[2])
        return False

    def _advance(self, glyph: _Glyph, char: str) -> float:
        _, bbox, advance = glyph.raster
        compound = self.layout.is_math_glyph(char) or glyph.corrected
        if self.metrics.grid:
            # 2026-10-15：普通文字保留用户的固定网格字距，复合单元才额外占格。
            cells = math.ceil(max(advance, bbox[2]) / self.metrics.cell_width) if compound else 1
            return glyph.x + cells * self.metrics.cell_width
        step = self.layout.api.gauss(
            self.rand, advance + self.tpl.get_word_spacing(), self.tpl.get_word_spacing_sigma()
        )
        # 2026-10-15：负字距是普通文字的显式参数，不能被数学行的防碰撞规则覆盖。
        return glyph.x + max(1, step, bbox[2] if compound else 1)

    def _line(self, start: int) -> tuple[list[Unit], int]:
        units: list[Unit] = []
        cursor: float = self.metrics.left
        while start < len(self.text) and self.text[start] != "\n":
            char = self.text[start]
            char_state = self.rand.getstate()
            glyph = self._prepare(char, cursor)
            if self._would_wrap(glyph, start, has_units=bool(units)) or self._correct(
                glyph, cursor, has_units=bool(units)
            ):
                self.rand.setstate(char_state)
                break
            units.append(glyph.unit())
            cursor = self._advance(glyph, char)
            start += 1
        if start < len(self.text) and self.text[start] == "\n":
            start += 1
        return units, start

    def _fit_line(
        self, units: list[Unit], max_height: int | None = None
    ) -> tuple[list[Unit], int, int]:
        min_y = min(bbox[1] + dy for _, bbox, _, dy in units)
        max_y = max(bbox[3] + dy for _, bbox, _, dy in units)
        # 2026-10-15：极端纵向抖动时整体缩放行字形，不裁掉墨迹。
        height = self.metrics.area.height if max_height is None else max_height
        if max_height is None and max_y - min_y <= height:
            return units, min_y, max_y
        factor = min(1, height / (max_y - min_y))
        adjusted: list[Unit] = []
        for image, bbox, x, dy in units:
            scaled = _resize(image, factor)
            y1 = math.floor((bbox[1] + dy - min_y) * factor)
            adjusted.append(
                (scaled, (bbox[0], y1, bbox[0] + scaled.width, y1 + scaled.height), x, 0)
            )
        return adjusted, 0, max(bbox[3] for _, bbox, _, _ in adjusted)

    def _blank_line(self) -> None:
        # 2026-10-15：空行正常消耗输入和基础行距，避免循环卡在换行符。
        metrics = self.metrics
        previous_y = (
            self.previous_y if self.previous_y is not None else metrics.top - metrics.font_size
        )
        self.previous_y = previous_y + metrics.spacing
        self.previous_bottom = max(self.previous_bottom, self.previous_y + metrics.font_size)

    def _baseline(self, min_y: int) -> int:
        metrics = self.metrics
        if self.previous_y is None:
            required = max(metrics.top - min_y, metrics.top + metrics.spacing - metrics.font_size)
        else:
            required = max(
                self.previous_y + metrics.spacing, self.previous_bottom + metrics.gap - min_y
            )
        if metrics.ruled_origin is None:
            return required
        # 2026-10-17：高公式可以占多行，但后续书写必须回到原纸张的整行距网格。
        origin = metrics.ruled_origin + metrics.spacing - metrics.font_size
        return origin + max(0, math.ceil((required - origin) / metrics.spacing)) * metrics.spacing

    def render(self, start: int) -> int:
        while start < len(self.text):
            line_start, line_state = start, self.rand.getstate()
            units, start = self._line(start)
            if not units:
                self._blank_line()
                continue
            units, min_y, max_y = self._fit_line(units)
            baseline = self._baseline(min_y)
            if baseline + max_y > self.metrics.bottom:
                if line_start == 0 or self.previous_y is None:
                    anchor = self._baseline(0)
                    if self.metrics.ruled_origin is not None and anchor < self.metrics.bottom:
                        # 2026-10-17：整页巨公式按可用完整行格缩小，不能贴页底破坏横线相位。
                        units, min_y, max_y = self._fit_line(units, self.metrics.bottom - anchor)
                        baseline = anchor
                    else:
                        baseline = self.metrics.bottom - max_y
                else:
                    self.rand.setstate(line_state)
                    return line_start
            for image, bbox, x, dy in units:
                self.draw.bitmap(
                    (x + bbox[0], baseline + dy + bbox[1]), image, fill=self.layout.api.white
                )
            self.previous_y, self.previous_bottom = baseline, baseline + max_y
        return start


def install_math_page_layout(
    core: object,
    is_math_glyph: Callable[[str], bool],
    measure_bbox: Callable[[str, Font, str | None], BBox],
) -> None:
    """2026-10-15：安装按真实墨迹范围换行、调行距与分页的布局适配器."""
    api = _bindings(core)
    original = api.draw_page
    if getattr(original, "_math_page_layout", False):
        return
    layout = _MathLayout(api, is_math_glyph, measure_bbox)

    @functools.wraps(original)
    def draw_page(page: Page, text: str, start: int, tpl: Template, rand: Random) -> int:
        if not any(is_math_glyph(char) for char in text[start:]):
            return original(page, text, start, tpl, rand)
        return _PageRenderer(layout, page, text, tpl, rand).render(start)

    install_member(draw_page, "_math_page_layout", value=True)
    install_member(core, "_draw_page", draw_page)
