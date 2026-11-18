# Copyright (c) 2026 Simon and Panache contributors.
"""2026-11-16：透明墨迹层和与预览共享的整数滤镜."""

from collections.abc import Callable
from dataclasses import dataclass
from typing import cast

import cv2
import numpy as np
from numpy.typing import NDArray
from PIL import Image, ImageChops

INK_LAYERS_KEY = "panache_ink_layers"
_LATIN_INK_KEY = "panache_latin_ink"
FULL_OPACITY = 100
MAX_RADIUS = 2
type InkColor = tuple[int, int, int]
type InkMask = NDArray[np.uint8]


@dataclass(frozen=True)
class InkEffects:
    """Bound the same pixel operations used in both clients."""

    opacity: int
    thickness: float
    softness: float

    @classmethod
    def from_form(cls, data: dict[str, str], *, prefix: str = "") -> "InkEffects":
        """Parse bounded integer settings before allocating pixel buffers."""
        values = cls(
            int(data.get(f"{prefix}ink_opacity", "100")),
            float(data.get(f"{prefix}ink_thickness", "0")),
            float(data.get(f"{prefix}ink_softness", "0")),
        )
        if not (
            0 <= values.opacity <= FULL_OPACITY
            and abs(values.thickness) <= MAX_RADIUS
            and 0 <= values.softness <= MAX_RADIUS
            and (values.thickness * 10).is_integer()
            and (values.softness * 10).is_integer()
        ):
            msg = "Ink effects out of range"
            raise ValueError(msg)
        return values


def layers(image: Image.Image) -> tuple[Image.Image, Image.Image] | None:
    """Return the immutable paper and alpha layers attached to a rendered page."""
    return cast("tuple[Image.Image, Image.Image] | None", image.info.get(INK_LAYERS_KEY))


def require_layers(image: Image.Image) -> tuple[Image.Image, Image.Image]:
    """Reject a malformed layered engine result."""
    result = layers(image)
    if result is None:
        msg = "Layered renderer did not return ink"
        raise ValueError(msg)
    return result


def latin_layer(image: Image.Image) -> Image.Image | None:
    """2026-11-18：返回可选的独立英文字迹蒙版."""
    return cast("Image.Image | None", image.info.get(_LATIN_INK_KEY))


def new_layered_paper(image: Image.Image, *, split_latin: bool = False) -> Image.Image:
    """Mark a request-local page for layered rendering."""
    paper = image.convert("RGB")
    result = paper.copy()
    result.info[INK_LAYERS_KEY] = (paper, Image.new("L", paper.size))
    if split_latin:
        result.info[_LATIN_INK_KEY] = Image.new("L", paper.size)
    return result


def attach_ink(
    background: Image.Image, rendered: Image.Image, rendered_latin: Image.Image | None = None
) -> Image.Image:
    """Merge a text fragment into its existing transparent ink layer."""
    paper, alpha = require_layers(background)
    fragment = ImageChops.invert(rendered.convert("L"))
    combined = ImageChops.lighter(alpha, fragment)
    latin = latin_layer(background)
    if latin is not None and rendered_latin is not None:
        latin = ImageChops.lighter(latin, ImageChops.invert(rendered_latin))
    all_ink = ImageChops.lighter(combined, latin) if latin is not None else combined
    result = composite(paper, all_ink, (0, 0, 0), InkEffects(100, 0, 0))
    result.info[INK_LAYERS_KEY] = (paper, combined)
    if latin is not None:
        result.info[_LATIN_INK_KEY] = latin
    return result


def alpha_png(alpha: Image.Image) -> Image.Image:
    """Encode the grayscale mask as a conventional black transparent PNG."""
    image = Image.new("RGBA", alpha.size)
    image.putalpha(alpha)
    return image


def _fractional_mask(
    mask: InkMask, radius: float, transform: Callable[[InkMask, int], InkMask]
) -> InkMask:
    # 2026-11-16：在相邻整数半径的遮罩之间插值，客户端和导出共享舍入规则。
    whole, weight = divmod(round(radius * 10), 10)
    lower = transform(mask, whole) if whole else mask
    if not weight:
        return lower
    upper = transform(mask, whole + 1)
    return (
        (lower.astype(np.uint16) * (10 - weight) + upper.astype(np.uint16) * weight + 5) // 10
    ).astype(np.uint8)


def _soften(mask: InkMask, radius: int) -> InkMask:
    size = 2 * radius + 1
    for kernel_size in ((size, 1), (1, size)):
        mask = np.asarray(
            cv2.blur(mask, kernel_size, borderType=cv2.BORDER_REPLICATE), dtype=np.uint8
        )
    return mask


def filtered_alpha(
    alpha: Image.Image,
    effects: InkEffects,
    color_alpha: int = 255,
) -> Image.Image:
    """2026-11-18：普通字迹与可编辑字形共用滤镜和透明度计算。."""
    mask = np.asarray(alpha, dtype=np.uint8)
    if effects.thickness:
        thin = effects.thickness < 0
        morph = cv2.erode if thin else cv2.dilate

        def stroke(source: InkMask, radius: int) -> InkMask:
            size = 2 * radius + 1
            kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (size, size))
            return np.asarray(
                morph(source, kernel, borderType=cv2.BORDER_REPLICATE), dtype=np.uint8
            )

        changed = _fractional_mask(mask, abs(effects.thickness), stroke)
        if thin:
            changed = (
                (changed.astype(np.uint16) * 7 + mask.astype(np.uint16) * 3 + 5) // 10
            ).astype(np.uint8)
        mask = changed
    if effects.softness:
        mask = _fractional_mask(mask, effects.softness, _soften)
    adjusted = (
        (np.asarray(mask, dtype=np.uint32) * effects.opacity * color_alpha + 12_750) // 25_500
    ).astype(np.uint8)
    return Image.fromarray(adjusted)


def composite(
    paper: Image.Image,
    alpha: Image.Image,
    color: InkColor,
    effects: InkEffects,
    color_alpha: int = 255,
) -> Image.Image:
    """Apply signed morphology, separable box blur and opacity to ink only."""
    result = paper.copy()
    result.paste(
        color, (0, 0, result.width, result.height), filtered_alpha(alpha, effects, color_alpha)
    )
    return result
