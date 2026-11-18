# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：在最终出图时保留复合数学结构，不按连通域拆散格线和内容。."""

import copy
import functools
import math
from dataclasses import dataclass
from typing import TYPE_CHECKING, cast

from handright._util import Page
from PIL import Image, ImageChops, ImageDraw

if TYPE_CHECKING:
    from collections.abc import Callable, Iterable, Sequence
    from random import Random

    from handright import Template

if __package__:
    from .fine_edit import DraftGlyph, GlyphTile, attach_tiles, drafts
    from .ink_effects import attach_ink, latin_layer
    from .ink_effects import layers as page_layers
    from .library_boundary import install_member, member
else:
    from fine_edit import DraftGlyph, GlyphTile, attach_tiles, drafts
    from ink_effects import attach_ink, latin_layer
    from ink_effects import layers as page_layers
    from library_boundary import install_member, member


_KEY = "panache_math_ink"
_RGB_CHANNELS = 3
_RGBA_CHANNELS = 4
type Ink = int | str | tuple[int, int, int] | tuple[int, int, int, int]


def _ink(template: "Template", rand: "Random") -> Ink:
    fill = template.get_fill()
    sigma = template.get_ink_depth_sigma()
    depth = rand.gauss(0, sigma) if sigma else 0

    def channel(value: int) -> int:
        return max(0, min(255, int(value + depth)))

    if isinstance(fill, (str, int)):
        return channel(fill) if isinstance(fill, int) else fill
    if len(fill) == _RGB_CHANNELS:
        return channel(fill[0]), channel(fill[1]), channel(fill[2])
    if len(fill) == _RGBA_CHANNELS:
        return channel(fill[0]), channel(fill[1]), channel(fill[2]), fill[3]
    msg = "Unsupported handwriting ink color"
    raise ValueError(msg)


@dataclass(frozen=True)
class MathInk:
    """2026-10-24：随页传递可序列化的结构蒙版，不使用跨请求全局注册表。."""

    mask: Image.Image
    position: tuple[int, int]
    latin: bool


def remember_math_ink(
    page: Page, mask: Image.Image, position: tuple[int, int], *, latin: bool = False
) -> None:
    """2026-10-24：记录已完成缩放、分页和位置扰动的复合结构。."""
    layers = cast("list[MathInk]", page.image.info.setdefault(_KEY, []))
    layers.append(MathInk(mask, position, latin))


class _TileRenderer:
    def __init__(self, core: object, template: "Template", rand: "Random") -> None:
        self.extract = cast(
            "Callable[[object, tuple[int, int, int, int]], Iterable[int]]",
            member(core, "_extract_strokes"),
        )
        self.paint = cast(
            "Callable[[object, Iterable[int], Template, Random], None]",
            member(core, "_draw_strokes"),
        )
        self.template = copy.copy(template)
        self.template.set_fill((0, 0, 0))
        self.rand = rand
        self.padding = min(
            96, math.ceil(3 * max(template.get_perturb_x_sigma(), template.get_perturb_y_sigma()))
        )

    def render(self, glyph: DraftGlyph) -> GlyphTile:
        # 2026-11-18：按字运行原引擎的笔画扰动，保留重叠文字各自的墨迹。
        raw = glyph.image
        if raw.mode == "LA":
            primary, latin = raw.getchannel("L"), raw.getchannel("A")
        else:
            primary, latin = raw.convert("L"), Image.new("L", raw.size)
        pad = (
            0
            if glyph.rigid or primary.getbbox() is None
            else max(
                self.padding,
                min(96, math.ceil(max(raw.size) * self.template.get_perturb_theta_sigma() * 1.5)),
            )
        )
        if glyph.rigid:
            primary = self._rigid(primary)
        elif (bounds := primary.getbbox()) is not None:
            canvas = Image.new("RGB", (raw.width + pad * 2, raw.height + pad * 2), "white")
            self.template.set_background(canvas)
            bitmap = Image.new("1", canvas.size)
            bitmap.paste(primary.convert("1"), (pad, pad))
            region = tuple(value + pad for value in bounds)
            self.paint(
                canvas.load(),
                self.extract(bitmap.load(), cast("tuple[int, int, int, int]", region)),
                self.template,
                self.rand,
            )
            primary = ImageChops.invert(canvas.getchannel("R"))
        if pad:
            canvas_latin = Image.new("L", primary.size)
            canvas_latin.paste(latin, (pad, pad))
            latin = canvas_latin
        latin = self._rigid(latin)
        bounds = ImageChops.lighter(primary, latin).getbbox()
        x, y = glyph.position
        if bounds:
            x, y = x + bounds[0], y + bounds[1]
            primary, latin = primary.crop(bounds), latin.crop(bounds)
        return GlyphTile(glyph.id, (x - pad, y - pad), glyph.baseline, primary, latin)

    def _rigid(self, mask: Image.Image) -> Image.Image:
        if not self.template.get_ink_depth_sigma() or mask.getbbox() is None:
            return mask
        color = _ink(self.template, self.rand)
        density = 255 - (color[0] if isinstance(color, tuple) else 0)
        return ImageChops.multiply(mask, Image.new("L", mask.size, density))


def _editable_page(
    core: object, template: "Template", rand: "Random", glyphs: list[DraftGlyph]
) -> Image.Image:
    renderer = _TileRenderer(core, template, rand)
    background = template.get_background()
    ink = Image.new("L", background.size, 255)
    latin = Image.new("L", background.size, 255) if latin_layer(background) is not None else None
    tiles = [renderer.render(glyph) for glyph in glyphs]
    for glyph in tiles:
        # 2026-11-18：原始位置用于计算插图后的排版光标；编辑位移只在合成时应用。
        ink.paste(0, glyph.position, glyph.primary)
        if latin is not None:
            latin.paste(0, glyph.position, glyph.latin)
    result = attach_ink(background, ink, latin)
    attach_tiles(result, background, tiles)
    return result


def _render_template(instance: object, page: Page) -> "Template":
    templates = cast("Sequence[Template]", member(instance, "_templates"))
    return templates[page.num % len(templates)]


def _render_layered(
    instance: object,
    page: Page,
    draw: "Callable[[object, Page, Image.Image | None], Image.Image]",
) -> Image.Image:
    template = _render_template(instance, page)
    background = template.get_background()
    if page_layers(background) is None:
        return draw(instance, page, None)
    # 2026-11-16：分离渲染墨迹浓度，保持普通字和复合公式使用相同的扰动。
    renderer_copy = copy.copy(instance)
    source = copy.copy(template)
    source.set_background(Image.new("RGB", background.size, "white"))
    source.set_fill((0, 0, 0))
    install_member(renderer_copy, "_templates", value=(source,))
    latin_canvas = (
        Image.new("L", background.size, 255) if latin_layer(background) is not None else None
    )
    return attach_ink(background, draw(renderer_copy, page, latin_canvas), latin_canvas)


def install_math_ink(core: object) -> None:
    """2026-10-24：普通笔画沿用原引擎，数学结构在最终阶段保持布局几何。."""
    renderer = member(core, "_Renderer")
    original = cast("Callable[[object, Page], Image.Image]", member(renderer, "_perturb_and_merge"))
    if getattr(original, "_math_ink", False):
        return

    def draw(instance: object, page: Page, latin_canvas: Image.Image | None = None) -> Image.Image:
        layers = cast("list[MathInk]", page.image.info.get(_KEY, []))
        if not layers:
            return original(instance, page)
        # 2026-10-24：保留草稿供重试/多进程使用；只在副本移除结构的实际墨迹。
        prose = Page("1", page.image.size, 0, page.num)
        prose.image = page.image.copy()
        prose.image.info.pop(_KEY, None)
        for layer in layers:
            if not layer.latin:
                prose.image.paste(0, layer.position, layer.mask)
        canvas = original(instance, prose)
        template = _render_template(instance, page)
        rand = cast("Random", member(instance, "_rand"))
        # 2026-10-24：布局已预留真实边界；再次随机旋转会越界或碰撞相邻行。
        for layer in layers:
            target = latin_canvas if layer.latin and latin_canvas is not None else canvas
            color = _ink(template, rand)
            if target is latin_canvas and isinstance(color, tuple):
                color = color[0]
            ImageDraw.Draw(target).bitmap(layer.position, layer.mask, fill=color)
        return canvas

    @functools.wraps(original)
    def merge(instance: object, page: Page) -> Image.Image:
        editable = drafts(page.image)
        if editable is None:
            return _render_layered(instance, page, draw)
        return _editable_page(
            core,
            _render_template(instance, page),
            cast("Random", member(instance, "_rand")),
            editable,
        )

    install_member(merge, "_math_ink", value=True)
    install_member(renderer, "_perturb_and_merge", merge)
