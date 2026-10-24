# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：在最终出图时保留复合数学结构，不按连通域拆散格线和内容。."""

import functools
from dataclasses import dataclass
from typing import TYPE_CHECKING, cast

from handright._util import Page
from PIL import Image, ImageDraw

if TYPE_CHECKING:
    from collections.abc import Callable, Sequence
    from random import Random

    from handright import Template

if __package__:
    from .library_boundary import install_member, member
else:
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


def remember_math_ink(page: Page, mask: Image.Image, position: tuple[int, int]) -> None:
    """2026-10-24：记录已完成缩放、分页和位置扰动的复合结构。."""
    layers = cast("list[MathInk]", page.image.info.setdefault(_KEY, []))
    layers.append(MathInk(mask, position))


def install_math_ink(core: object) -> None:
    """2026-10-24：普通笔画沿用原引擎，数学结构在最终阶段保持布局几何。."""
    renderer = member(core, "_Renderer")
    original = cast("Callable[[object, Page], Image.Image]", member(renderer, "_perturb_and_merge"))
    if getattr(original, "_math_ink", False):
        return

    @functools.wraps(original)
    def merge(instance: object, page: Page) -> Image.Image:
        layers = cast("list[MathInk]", page.image.info.get(_KEY, []))
        if not layers:
            return original(instance, page)
        # 2026-10-24：保留草稿供重试/多进程使用；只在副本移除结构的实际墨迹。
        prose = Page("1", page.image.size, 0, page.num)
        prose.image = page.image.copy()
        prose.image.info.pop(_KEY, None)
        for layer in layers:
            prose.image.paste(0, layer.position, layer.mask)
        canvas = original(instance, prose)
        templates = cast("Sequence[Template]", member(instance, "_templates"))
        template = templates[page.num % len(templates)]
        rand = cast("Random", member(instance, "_rand"))
        # 2026-10-24：布局已预留真实边界；再次随机旋转会越界或碰撞相邻行。
        for layer in layers:
            ImageDraw.Draw(canvas).bitmap(layer.position, layer.mask, fill=_ink(template, rand))
        return canvas

    install_member(merge, "_math_ink", value=True)
    install_member(renderer, "_perturb_and_merge", merge)
