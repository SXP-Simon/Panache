# Copyright (c) 2026 Simon and Panache contributors.
"""2026-11-18：可编辑墨迹单元、页面图集与导出合成."""

import base64
import io
import math
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from typing import Annotated, cast

import numpy as np
from generation_cancellation import check_cancelled
from ink_effects import InkColor, InkEffects, filtered_alpha, require_layers
from PIL import Image
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, TypeAdapter

_DRAFT = "panache_fine_draft"
_TILES = "panache_fine_tiles"
_OPAQUE = 100
_BYTE = 255
_HEX = 16
_FILTER_PAD = 4
type InkStyle = tuple[InkColor, InkEffects, int]
type Position = tuple[int, int]
type ByteWriter = Callable[[Image.Image], bytes]
type InkPair = tuple[InkStyle, InkStyle | None]


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
    max_bytes = 1_000_000
    if len(raw) > max_bytes:
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
    left, top = max(0, math.floor(cx - reach_x)), max(0, math.floor(cy - reach_y))
    right = min(paper.shape[1], math.ceil(cx + reach_x))
    bottom = min(paper.shape[0], math.ceil(cy + reach_y))
    if left >= right or top >= bottom:
        return
    yy, xx = np.ogrid[top:bottom, left:right]
    xx = xx + 0.5 - cx
    yy = yy + 0.5 - cy
    # 2026-11-18：同一采样点恰好落在整数边界时，消除两端三角函数的尾数误差。
    epsilon = 1e-9
    sx = np.floor((xx * cos + yy * sin) / scale + width / 2 + epsilon).astype(np.int32)
    sy = np.floor((-xx * sin + yy * cos) / scale + height / 2 + epsilon).astype(np.int32)
    inside = (sx >= 0) & (sx < width) & (sy >= 0) & (sy < height)
    target = paper[top:bottom, left:right]
    rgb = target[inside].astype(np.uint32)
    opacity = edit.opacity if edit else _OPAQUE
    override = _rgb(edit.color) if edit and edit.color else None
    for channel, (default, effects, ink_alpha) in enumerate(styles):
        color = override or default
        mask = tile.mask.getchannel(channel)
        if mask.getbbox() is None:
            continue
        source = np.asarray(filtered_alpha(mask, effects, ink_alpha))[sy[inside], sx[inside]]
        alpha = ((source.astype(np.uint32) * opacity + 50) // _OPAQUE)[:, None]
        rgb = (np.asarray(color, dtype=np.uint32) * alpha + rgb * (_BYTE - alpha) + 127) // _BYTE
    target[inside] = rgb


def encode_png(image: Image.Image) -> bytes:
    """2026-11-18：图集只保存像素，不携带生成阶段的元数据."""
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", compress_level=1)
    return buffer.getvalue()
