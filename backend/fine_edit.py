# Copyright (c) 2026 Simon and Panache contributors.
"""2026-11-18：可编辑墨迹单元、页面图集与导出合成."""

import base64
import io
import math
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, replace
from typing import Annotated, cast

import numpy as np
from generation_cancellation import check_cancelled
from ink_effects import MAX_RADIUS, InkColor, InkEffects, filtered_alpha, require_layers
from PIL import Image
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, TypeAdapter

_DRAFT = "panache_fine_draft"
_TILES = "panache_fine_tiles"
_OPAQUE = 100
_BYTE = 255
_HEX = 16
_FILTER_PAD = 4
_WARP_LIMIT = 65_535
_MIN_WARP_DIVISOR = 0.15
_MIN_WARP_DETERMINANT = 1e-12
_MAX_WARP_AREA_RATIO = 32
MAX_FINE_EDITS_BYTES = 4_000_000
type InkStyle = tuple[InkColor, InkEffects, int]
type Position = tuple[int, int]
type ByteWriter = Callable[[Image.Image], bytes]
type InkPair = tuple[InkStyle, InkStyle | None]
type Coefficient = Annotated[float, Field(ge=-65535, le=65535)]
type Warp = tuple[
    Coefficient,
    Coefficient,
    Coefficient,
    Coefficient,
    Coefficient,
    Coefficient,
    Coefficient,
    Coefficient,
]


class GlyphAdjustment(BaseModel):
    """2026-11-18：位移使用纸面像素，缩放和浓淡使用百分比."""

    model_config = ConfigDict(extra="forbid", strict=True)
    id: int = Field(ge=0)
    dx: int = Field(default=0, ge=-65535, le=65535)
    dy: int = Field(default=0, ge=-65535, le=65535)
    scale: int = Field(default=100, ge=50, le=200)
    angle: int = Field(default=0, ge=-45, le=45)
    opacity: int = Field(default=100, ge=0, le=100)
    color: Annotated[str, StringConstraints(pattern=r"^#[0-9a-fA-F]{6}$")] | None = None
    thickness: int = Field(default=0, ge=-20, le=20)
    softness: int = Field(default=0, ge=-20, le=20)
    warp: Warp | None = None

    def apply_shape(self, effects: InkEffects) -> InkEffects:
        """2026-11-18：在全局字迹基础上应用以 0.1 px 为单位的选区偏移."""
        return replace(
            effects,
            thickness=max(-MAX_RADIUS, min(MAX_RADIUS, effects.thickness + self.thickness / 10)),
            softness=max(0, min(MAX_RADIUS, effects.softness + self.softness / 10)),
        )


class FineEdits(BaseModel):
    """2026-11-18：仅当可编辑文本的指纹相同时应用保存的调整."""

    model_config = ConfigDict(extra="forbid", strict=True)
    key: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
    glyphs: list[GlyphAdjustment] = Field(max_length=10000)


_edits_adapter = TypeAdapter(FineEdits)


def parse_edits(raw: str | None) -> FineEdits | None:
    """2026-11-18：在进入渲染前限制调整表大小."""
    if not raw:
        return None
    if len(raw) > MAX_FINE_EDITS_BYTES:
        msg = "Too many fine edits"
        raise ValueError(msg)
    return _edits_adapter.validate_json(raw)


@dataclass(frozen=True)
class DraftGlyph:
    """2026-11-18：排版后的墨迹位置与正文中的单元标识."""

    id: int
    image: Image.Image
    position: Position
    baseline: int
    rigid: bool


@dataclass(frozen=True)
class GlyphTile:
    """2026-11-18：渲染后的局部主字迹、拉丁字迹."""

    id: int
    position: Position
    baseline: int
    primary: Image.Image
    latin: Image.Image


def remember_draft(target: Image.Image, glyph: DraftGlyph) -> None:
    """2026-11-18：保存未合并的单元，避免用矩形擦掉相邻文字."""
    cast("list[DraftGlyph]", target.info.setdefault(_DRAFT, [])).append(glyph)


def start_draft(target: Image.Image) -> None:
    """2026-11-18：标记需要返回墨迹单元的空白草稿."""
    target.info[_DRAFT] = []


def drafts(target: Image.Image) -> list[DraftGlyph] | None:
    """2026-11-18：区分普通出图与收集编辑信息的草稿页."""
    return cast("list[DraftGlyph] | None", target.info.get(_DRAFT))


def attach_tiles(target: Image.Image, background: Image.Image, tiles: list[GlyphTile]) -> None:
    """2026-11-18：同页的插图前后片段累计单元，不覆盖原有单元."""
    target.info[_TILES] = [*page_tiles(background), *tiles]


def page_tiles(page: Image.Image) -> tuple[GlyphTile, ...]:
    """2026-11-18：读取当前页的可编辑单元."""
    return tuple(cast("list[GlyphTile]", page.info.get(_TILES, [])))


@dataclass(frozen=True)
class _Tile:
    id: int
    position: Position
    baseline: int
    mask: Image.Image


def _prepare_tiles(page: Image.Image) -> Iterable[_Tile]:
    # 2026-11-18：留出全局滤镜的最大扩张范围，拖动全局滑块无需重新排版。
    pad = _FILTER_PAD
    for glyph in page_tiles(page):
        check_cancelled()
        size = (glyph.primary.width + pad * 2, glyph.primary.height + pad * 2)
        channels: list[Image.Image] = []
        for channel in (glyph.primary, glyph.latin):
            padded = Image.new("L", size)
            padded.paste(channel, (pad, pad))
            channels.append(padded)
        mask = Image.merge("RGB", (*channels, Image.new("L", size)))
        x, y = glyph.position
        yield _Tile(glyph.id, (x - pad, y - pad), glyph.baseline, mask)


def _rgb(value: str) -> InkColor:
    return int(value[1:3], _HEX), int(value[3:5], _HEX), int(value[5:7], _HEX)


@dataclass(frozen=True)
class EditPage:
    """2026-11-18：预览与导出使用同一批原始蒙版."""

    paper: Image.Image
    styles: InkPair
    tiles: tuple[_Tile, ...]

    @classmethod
    def from_image(cls, page: Image.Image, styles: InkPair) -> "EditPage":
        """2026-11-18：纸面与插图保持独立，滤镜只作用于字迹."""
        return cls(require_layers(page)[0], styles, tuple(_prepare_tiles(page)))

    def preview(self, png: ByteWriter, positions: list[Position] | None) -> dict[str, object]:
        """2026-11-18：把小蒙版打包进图集，每页只需解码一次."""
        tile_area = sum(tile.mask.width * tile.mask.height for tile in self.tiles)
        width = max(1, math.isqrt(tile_area), *(tile.mask.width for tile in self.tiles))
        x, y, row = 0, 0, 0
        slots: list[tuple[_Tile, Position]] = []
        for tile in self.tiles:
            if x + tile.mask.width > width:
                x, y, row = 0, y + row, 0
            slots.append((tile, (x, y)))
            x += tile.mask.width
            row = max(row, tile.mask.height)
        atlas = Image.new("RGB", (width, max(1, y + row)))
        glyphs: list[list[int]] = []
        for tile, pos in slots:
            atlas.paste(tile.mask, pos)
            glyphs.append([tile.id, *tile.position, *tile.mask.size, *pos, tile.baseline])
        result: dict[str, object] = {
            "atlas": base64.b64encode(png(atlas)).decode("ascii"),
            "glyphs": glyphs,
        }
        if positions is not None:
            result["source_ranges"] = [positions[tile.id] for tile in self.tiles]
        return result

    def flatten(self, edits: Mapping[int, GlyphAdjustment]) -> Image.Image:
        """2026-11-18：在固定版面上合并已变换的单元，不参与换行."""
        pixels = np.array(self.paper.convert("RGB"), dtype=np.uint8)
        primary, latin = self.styles
        styles = (primary, latin or primary)
        for tile in self.tiles:
            check_cancelled()
            edit = edits.get(tile.id)
            _paint(pixels, tile, styles, edit)
        return Image.fromarray(pixels)


def _projected_geometry(
    warp: Warp,
    size: Position,
    scale: float,
    cos: float,
    sin: float,
) -> tuple[list[tuple[float, float]], tuple[float, ...]] | None:
    # 2026-11-19：用字迹中心为原点，先检查四个角没有越过透视消失线。
    a, b, c, d, e, f, g, h = warp
    inverse = (
        e - f * h,
        c * h - b,
        b * f - c * e,
        f * g - d,
        a - c * g,
        c * d - a * f,
        d * h - e * g,
        b * g - a * h,
        a * e - b * d,
    )
    if abs(a * inverse[0] + b * inverse[3] + c * inverse[6]) < _MIN_WARP_DETERMINANT:
        return None
    width, height = size
    points: list[tuple[float, float]] = []
    for u in (-width / 2, width / 2):
        for v in (-height / 2, height / 2):
            x, y = scale * (cos * u - sin * v), scale * (sin * u + cos * v)
            z = g * x + h * y + 1
            if z < _MIN_WARP_DIVISOR:
                return None
            point = ((a * x + b * y + c) / z, (d * x + e * y + f) / z)
            if max(abs(point[0]), abs(point[1])) > _WARP_LIMIT:
                return None
            points.append(point)
    px, py = zip(*points, strict=True)
    original_width = scale * (abs(cos) * width + abs(sin) * height)
    original_height = scale * (abs(sin) * width + abs(cos) * height)
    if (max(px) - min(px)) * (max(py) - min(py)) > (
        _MAX_WARP_AREA_RATIO * original_width * original_height
    ):
        return None
    return points, inverse


def _paint(
    paper: np.ndarray[tuple[int, ...], np.dtype[np.uint8]],
    tile: _Tile,
    styles: tuple[InkStyle, InkStyle],
    edit: GlyphAdjustment | None,
) -> None:
    # 2026-11-18：和 Web 的采样及整数 alpha 混合一致，PDF/ZIP 保留相同像素。
    width, height = tile.mask.size
    x, y = tile.position
    dx, dy = (edit.dx, edit.dy) if edit else (0, 0)
    scale = edit.scale / _OPAQUE if edit else 1.0
    angle = math.radians(edit.angle) if edit else 0.0
    cos, sin = math.cos(angle), math.sin(angle)
    cx, cy = x + width / 2 + dx, y + height / 2 + dy
    reach_x = scale * (abs(cos) * width + abs(sin) * height) / 2
    reach_y = scale * (abs(sin) * width + abs(cos) * height) / 2
    projected = (
        _projected_geometry(edit.warp, (width, height), scale, cos, sin)
        if edit and edit.warp
        else None
    )
    x_range = (-reach_x, reach_x)
    y_range = (-reach_y, reach_y)
    if projected:
        px, py = zip(*projected[0], strict=True)
        x_range, y_range = (min(px), max(px)), (min(py), max(py))
    left = max(0, math.floor(cx + x_range[0]))
    top = max(0, math.floor(cy + y_range[0]))
    right = min(paper.shape[1], math.ceil(cx + x_range[1]))
    bottom = min(paper.shape[0], math.ceil(cy + y_range[1]))
    if left >= right or top >= bottom:
        return
    yy, xx = np.ogrid[top:bottom, left:right]
    xx = xx + 0.5 - cx
    yy = yy + 0.5 - cy
    if projected:
        a, b, c, d, e, f, g, h, i = projected[1]
        z = g * xx + h * yy + i
        divisor = np.where(z != 0, z, np.nan)
        xx, yy = (a * xx + b * yy + c) / divisor, (d * xx + e * yy + f) / divisor
    # 2026-11-18：同一采样点恰好落在整数边界时，消除两端三角函数的尾数误差。
    epsilon = 1e-9
    sample_x = np.floor((xx * cos + yy * sin) / scale + width / 2 + epsilon)
    sample_y = np.floor((-xx * sin + yy * cos) / scale + height / 2 + epsilon)
    inside = (sample_x >= 0) & (sample_x < width) & (sample_y >= 0) & (sample_y < height)
    sx, sy = sample_x[inside].astype(np.int32), sample_y[inside].astype(np.int32)
    target = paper[top:bottom, left:right]
    rgb = target[inside].astype(np.uint32)
    opacity = edit.opacity if edit else _OPAQUE
    override = _rgb(edit.color) if edit and edit.color else None
    for channel, (default, effects, ink_alpha) in enumerate(styles):
        color = override or default
        mask = tile.mask.getchannel(channel)
        if mask.getbbox() is None:
            continue
        shape = edit.apply_shape(effects) if edit and (edit.thickness or edit.softness) else effects
        source = np.asarray(filtered_alpha(mask, shape, ink_alpha))[sy, sx]
        alpha = ((source.astype(np.uint32) * opacity + 50) // _OPAQUE)[:, None]
        rgb = (np.asarray(color, dtype=np.uint32) * alpha + rgb * (_BYTE - alpha) + 127) // _BYTE
    target[inside] = rgb


def encode_png(image: Image.Image) -> bytes:
    """2026-11-18：图集只保存像素，不携带生成阶段的元数据."""
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", compress_level=1)
    return buffer.getvalue()
