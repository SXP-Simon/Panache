# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""手绘风格图像滤镜与仿真模块 (Handdrawn Filter & Noise Simulation).

将用户粘贴或插入的示意图、电路图、几何草图等：
1. 灰度化与二值化/反色提取纯净线稿；
2. 应用弹性形变/随机微小扰动模拟手绘笔迹的不平整；
3. 加入微弱墨水深浅扰动与随机椒盐/墨滴微噪点；
4. 将白色/浅色背景透明化（RGBA），便于自然贴合在背景纸张或手写排版流中。
"""

import base64
import copy
import io
import re
from collections.abc import Callable, Iterable

import cv2
import numpy as np
from handright import Template
from numpy.typing import NDArray
from PIL import Image

if __package__:
    from .logging_setup import get_logger
else:
    from logging_setup import get_logger

logger = get_logger(__name__)
INK_DIFFERENCE_THRESHOLD = 15
MAX_IMAGE_SCALE = 7.0
MAX_IMAGE_PERCENT = 700.0


def decode_base64_image(image_str: str) -> Image.Image | None:
    """从 Markdown 图片中包含的 base64 编码字符串或 Data URL 中安全解码 PIL.Image."""
    try:
        if "," in image_str:
            image_str = image_str.split(",", 1)[1]
        raw_bytes = base64.b64decode(image_str)
        return Image.open(io.BytesIO(raw_bytes)).convert("RGB")
    except (ValueError, OSError):
        logger.exception("Unable to decode embedded image")
        return None


def fit_image_to_layout(
    image: Image.Image,
    max_width: int,
    max_height: int,
    scale: float = 1.0,
) -> Image.Image:
    """根据目标缩放比例及页面版心最大可用宽高，智能等比例缩放图片（支持放大与缩小）.

    :param image: PIL 图像对象
    :param max_width: 版心允许的最大物理宽度
    :param max_height: 页面允许的最大物理高度
    :param scale: 用户指定的尺寸比例因子（例如 0.5 缩小，1.5 放大，默认 1.0）
    :return: 缩放后的 PIL.Image
    """
    w, h = image.size
    if w <= 0 or h <= 0:
        return image

    # 首先根据用户指定的 scale 缩放原始图
    target_w = float(w) * scale
    target_h = float(h) * scale

    # 接着以版心可用宽高为硬性上限进行限制，确保绝不撑爆版面
    ratio = min(max_width / target_w, max_height / target_h, 1.0)
    final_w = max(1, int(target_w * ratio))
    final_h = max(1, int(target_h * ratio))

    if final_w == w and final_h == h:
        return image

    return image.resize((final_w, final_h), Image.Resampling.LANCZOS)


def process_image_to_handdrawn(
    image_input: bytes | Image.Image | NDArray[np.uint8],
    ink_color: tuple[int, int, int] = (20, 20, 25),
    jitter_intensity: float = 1.0,
    noise_ratio: float = 0.003,
) -> Image.Image:
    """将输入图片转换为仿手绘墨水线稿风格的透明 PNG 图片.

    :param image_input: 输入图片（bytes, PIL.Image 或 numpy.ndarray）
    :param ink_color: 墨水 RGB 颜色，默认为深墨黑 (20, 20, 25)
    :param jitter_intensity: 笔触随机抖动强度（模拟人手画线的不平整）
    :param noise_ratio: 墨水飞溅/细微噪点比例
    :return: 具有透明背景的 PIL.Image (RGBA)
    """
    rng = np.random.default_rng()
    # 1. 统一转换为 OpenCV BGR 格式
    if isinstance(image_input, bytes):
        nparr = np.frombuffer(image_input, np.uint8)
        img_bgr = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    elif isinstance(image_input, Image.Image):
        img_rgb = image_input.convert("RGB")
        img_bgr = cv2.cvtColor(np.array(img_rgb), cv2.COLOR_RGB2BGR)
    else:
        img_bgr = image_input

    if img_bgr is None:
        msg = "无法解码输入图片"
        raise ValueError(msg)

    h, w = img_bgr.shape[:2]

    # 2. 灰度化与自适应阈值线稿提取
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)

    # 轻微高斯模糊去除高频数字噪点
    blurred = cv2.GaussianBlur(gray, (3, 3), 0)

    # 自适应二值化：提取黑白边缘，反转使得线条为 255（白色），背景为 0（黑色）
    binary = cv2.adaptiveThreshold(
        blurred,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY_INV,
        blockSize=15,
        C=5,
    )

    # 3. 模拟手绘笔触的微弱几何形变与抖动 (Elastic/Jitter Distortion)
    if jitter_intensity > 0:
        # 构造低频随机位移场
        scale = max(8, int(min(w, h) / 40))
        small_dx = (rng.random((h // scale + 2, w // scale + 2)) - 0.5) * (jitter_intensity * 2.5)
        small_dy = (rng.random((h // scale + 2, w // scale + 2)) - 0.5) * (jitter_intensity * 2.5)

        dx = cv2.resize(small_dx, (w, h), interpolation=cv2.INTER_CUBIC)
        dy = cv2.resize(small_dy, (w, h), interpolation=cv2.INTER_CUBIC)

        grid_x, grid_y = np.meshgrid(np.arange(w, dtype=np.float64), np.arange(h, dtype=np.float64))
        map_x = np.clip(grid_x + dx, 0, w - 1).astype(np.float32)
        map_y = np.clip(grid_y + dy, 0, h - 1).astype(np.float32)

        binary = cv2.remap(binary, map_x, map_y, interpolation=cv2.INTER_LINEAR)

    # 4. 模拟墨水深度不均 (Ink depth shading)
    # 通过微弱的高斯噪声扰动线条的透明度/粗细
    ink_mask = binary.astype(np.float32) / 255.0
    ink_noise = rng.uniform(0.75, 1.0, size=(h, w)).astype(np.float32)
    alpha_channel = (ink_mask * ink_noise * 255.0).astype(np.uint8)

    # 5. 添加微弱的手写墨水飞溅/细微噪点 (Salt/Ink Splatter)
    if noise_ratio > 0:
        noise_mask = rng.random((h, w)) < noise_ratio
        # 仅在线条附近产生少量微弱墨滴飞溅
        dilated = cv2.dilate(binary, np.ones((5, 5), np.uint8), iterations=1)
        splatter_zone = (dilated > 0) & noise_mask
        alpha_channel[splatter_zone] = rng.integers(
            100, 200, size=np.count_nonzero(splatter_zone), dtype=np.uint8
        )

    # 6. 合成 RGBA 图像
    r_val, g_val, b_val = ink_color
    r_channel = np.full((h, w), r_val, dtype=np.uint8)
    g_channel = np.full((h, w), g_val, dtype=np.uint8)
    b_channel = np.full((h, w), b_val, dtype=np.uint8)

    rgba = np.dstack([r_channel, g_channel, b_channel, alpha_channel])
    return Image.fromarray(rgba, mode="RGBA")


def get_rendered_ink_bottom_y(image: Image.Image, background: Image.Image) -> int:
    """对比渲染结果与原始底图，检测当前页面最后一行墨迹字符的最低 Y 坐标."""
    try:
        im_arr = np.array(image)
        bg_arr = np.array(background)
        # 计算 RGB 差异
        diff = np.abs(im_arr.astype(np.int16) - bg_arr.astype(np.int16))
        # 差异显著的点即为绘制的墨迹
        ink_mask = np.any(diff > INK_DIFFERENCE_THRESHOLD, axis=2)
        y_indices, _ = np.where(ink_mask)
        if len(y_indices) > 0:
            return int(np.max(y_indices))
    except (ValueError, OSError, TypeError):
        logger.exception("Image processing fallback was required")
    return 0


# 匹配 Markdown 图片标记 ![alt](data:image/... 或 url/base64)
MARKDOWN_IMAGE_RE = re.compile(
    r"!\[(.*?)\]\(((?:data:image\/[^;]+;base64,)?[A-Za-z0-9+/=\s]+)\)",
    re.DOTALL,
)


def _parse_image_scale(alt_text: str) -> float:
    """Parse image scaling requested in an illustration caption."""
    if not alt_text or "|" not in alt_text:
        return 1.0
    try:
        parts = alt_text.split("|", 1)
        param = parts[1].strip().lower()
        if "%" in param:
            pct_match = re.search(r"(\d+(?:\.\d+)?)\s*%", param)
            if pct_match:
                pct = float(pct_match.group(1))
                return max(0.1, min(7.0, pct / 100.0))
        scale_match = re.search(r"(?:scale\s*=\s*|w\s*=\s*)?(\d+(?:\.\d+)?)", param)
        if scale_match:
            val = float(scale_match.group(1))
            if val > MAX_IMAGE_SCALE:
                # 可能是百分比整数如 150、200、500 或 700
                if val <= MAX_IMAGE_PERCENT:
                    return max(0.1, min(7.0, val / 100.0))
            else:
                return max(0.1, min(7.0, val))
    except (ValueError, OSError, TypeError):
        logger.exception("Image processing fallback was required")
    return 1.0


class _InlineRenderer:
    def __init__(
        self, template: Template, handwrite_fn: Callable[[str, Template], Iterable[Image.Image]]
    ) -> None:
        """Keep the page stream and image insertion cursor for one document."""
        self.template = template
        self.handwrite = handwrite_fn
        self.background = template.get_background()
        self.canvas = self.background.copy()
        self.top = template.get_top_margin()
        self.pages: list[Image.Image] = []
        self.dirty = False

    def text(self, content: str) -> None:
        """Render a text fragment and advance the insertion cursor."""
        if not content.strip():
            return
        template = copy.copy(self.template)
        template.set_background(self.canvas)
        template.set_top_margin(self.top)
        pages = list(self.handwrite(content, template))
        if not pages:
            return
        self.canvas = pages[-1]
        self.dirty = True
        ink_bottom = get_rendered_ink_bottom_y(self.canvas, self.background)
        origin = self.top if len(pages) == 1 else self.template.get_top_margin()
        self.top = max(origin, ink_bottom + self.template.get_line_spacing())
        self.pages.extend(pages[:-1])

    def image(self, data: str, scale: float) -> None:
        """Fit an image inside the page margins, starting a new page as needed."""
        raw = decode_base64_image(data)
        if raw is None:
            return
        template = self.template
        width, height = self.background.size
        top, bottom = template.get_top_margin(), template.get_bottom_margin()
        left, right = template.get_left_margin(), template.get_right_margin()
        image = fit_image_to_layout(
            process_image_to_handdrawn(raw),
            width - left - right,
            int((height - top - bottom) * 0.45),
            scale,
        )
        image_width, image_height = image.size
        if self.top + image_height > height - bottom:
            if self.dirty:
                self.pages.append(self.canvas)
            self.canvas = self.background.copy()
            self.top = top
            self.dirty = False
        x = left + max(0, (width - left - right - image_width) // 2)
        self.canvas.paste(image, (x, self.top), image)
        self.dirty = True
        self.top += image_height + template.get_line_spacing()

    def result(self) -> list[Image.Image]:
        """Return completed pages and the final dirty canvas."""
        if self.dirty:
            self.pages.append(self.canvas)
        return self.pages or [self.background.copy()]


def render_inline_markdown_images(
    text: str, template: Template, handwrite_fn: Callable[[str, Template], Iterable[Image.Image]]
) -> Iterable[Image.Image]:
    """Insert image fragments between handwriting segments while retaining lazy text rendering."""
    if not MARKDOWN_IMAGE_RE.search(text):
        return handwrite_fn(text, template)
    renderer = _InlineRenderer(template, handwrite_fn)
    end = 0
    for match in MARKDOWN_IMAGE_RE.finditer(text):
        renderer.text(text[end : match.start()])
        renderer.image(match.group(2).strip(), _parse_image_scale(match.group(1).strip()))
        end = match.end()
    renderer.text(text[end:])
    return renderer.result()
