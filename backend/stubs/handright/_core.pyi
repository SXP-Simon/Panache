# Copyright (c) 2026 Simon and Handwriting Web contributors.
from collections.abc import Callable
from random import Random
from typing import Protocol

from handright import Feature as Feature
from handright import LayoutError as LayoutError
from handright import Template
from handright._util import Page
from PIL.ImageDraw import ImageDraw
from PIL.ImageFont import FreeTypeFont, ImageFont

type Font = FreeTypeFont | ImageFont

__all__ = [
    "_WHITE",
    "_check_template",
    "_draw_char",
    "_draw_page",
    "_draw_strikethrough",
    "_get_font",
]
_WHITE: int

class StrokeDrawer(Protocol):
    def line(self, xy: tuple[float, ...], fill: int, width: int) -> None: ...

_draw_char: Callable[[ImageDraw, str, tuple[int, int], Font], int]
_get_font: Callable[[Template, Random], Font]
_draw_page: Callable[[Page, str, int, Template, Random], int]

def _check_template(page: Page, tpl: Template) -> None: ...
def _draw_strikethrough(
    draw: StrokeDrawer, x: int, y: int, tpl: Template, rand: Random
) -> None: ...
def gauss(rand: Random, mu: float, sigma: float) -> float: ...
