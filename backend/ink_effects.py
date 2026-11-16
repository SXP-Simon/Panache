# Copyright (c) 2026 Simon and Panache contributors.
"""2026-11-16：透明墨迹层和与预览共享的整数滤镜."""

from dataclasses import dataclass
from typing import cast

import cv2
import numpy as np
from numpy.typing import NDArray
from PIL import Image, ImageChops

INK_LAYERS_KEY = "panache_ink_layers"
FULL_OPACITY = 100
MAX_RADIUS = 2
type InkColor = tuple[int, int, int]
type InkMask = NDArray[np.uint8]


@dataclass(frozen=True)
class InkEffects:
    """Bound the same pixel operations used in both clients."""

    opacity: int
    thickness: int
    softness: int

    @classmethod
    def from_form(cls, data: dict[str, str]) -> "InkEffects":
        """Parse bounded integer settings before allocating pixel buffers."""
        values = cls(
            int(data.get("ink_opacity", "100")),
            int(data.get("ink_thickness", "0")),
            int(data.get("ink_softness", "0")),
        )
        if not (
            0 <= values.opacity <= FULL_OPACITY
            and abs(values.thickness) <= MAX_RADIUS
            and 0 <= values.softness <= MAX_RADIUS
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


def new_layered_paper(image: Image.Image) -> Image.Image:
    """Mark a request-local page for layered rendering."""
    paper = image.convert("RGB")
    result = paper.copy()
    result.info[INK_LAYERS_KEY] = (paper, Image.new("L", paper.size))
    return result


def attach_ink(background: Image.Image, rendered: Image.Image) -> Image.Image:
    """Merge a text fragment into its existing transparent ink layer."""
    paper, alpha = require_layers(background)
    fragment = ImageChops.invert(rendered.convert("L"))
    combined = ImageChops.lighter(alpha, fragment)
    result = composite(paper, combined, (0, 0, 0), InkEffects(100, 0, 0))
    result.info[INK_LAYERS_KEY] = (paper, combined)
    return result


def alpha_png(alpha: Image.Image) -> Image.Image:
    """Encode the grayscale mask as a conventional black transparent PNG."""
    image = Image.new("RGBA", alpha.size)
    image.putalpha(alpha)
    return image


def _soften(mask: InkMask, radius: int) -> InkMask:
    size = 2 * radius + 1
    for kernel_size in ((size, 1), (1, size)):
        mask = np.asarray(
            cv2.blur(mask, kernel_size, borderType=cv2.BORDER_REPLICATE), dtype=np.uint8
        )
    return mask


def composite(
    paper: Image.Image,
    alpha: Image.Image,
    color: InkColor,
    effects: InkEffects,
    color_alpha: int = 255,
) -> Image.Image:
    """Apply signed morphology, separable box blur and opacity to ink only."""
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

        changed = stroke(mask, abs(effects.thickness))
        if thin:
            changed = (
                (changed.astype(np.uint16) * 7 + mask.astype(np.uint16) * 3 + 5) // 10
            ).astype(np.uint8)
        mask = changed
    if effects.softness:
        mask = _soften(mask, effects.softness)
    result = paper.copy()
    adjusted = (
        (np.asarray(mask, dtype=np.uint32) * effects.opacity * color_alpha + 12_750) // 25_500
    ).astype(np.uint8)
    result.paste(color, (0, 0, result.width, result.height), Image.fromarray(adjusted))
    return result
