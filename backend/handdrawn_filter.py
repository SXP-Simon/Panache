# -*- coding: utf-8 -*-
"""
手绘风格图像滤镜与仿真模块 (Handdrawn Filter & Noise Simulation)

将用户粘贴或插入的示意图、电路图、几何草图等：
1. 灰度化与二值化/反色提取纯净线稿；
2. 应用弹性形变/随机微小扰动模拟手绘笔迹的不平整；
3. 加入微弱墨水深浅扰动与随机椒盐/墨滴微噪点；
4. 将白色/浅色背景透明化（RGBA），便于自然贴合在背景纸张或手写排版流中。
"""

import base64
import io
import random
import re
from typing import Optional, Tuple, Union
import cv2
import numpy as np
from PIL import Image


def decode_base64_image(image_str: str) -> Optional[Image.Image]:
    """从 Markdown 图片中包含的 base64 编码字符串或 Data URL 中安全解码 PIL.Image。"""
    try:
        if "," in image_str:
            image_str = image_str.split(",", 1)[1]
        raw_bytes = base64.b64decode(image_str)
        return Image.open(io.BytesIO(raw_bytes)).convert("RGB")
    except Exception:
        return None



def fit_image_to_layout(
    image: Image.Image,
    max_width: int,
    max_height: int,
) -> Image.Image:
    """根据页面版心最大可用宽高，智能等比例缩放图片，避免超大图撑爆页面或侵占过多行数。

    :param image: PIL 图像对象
    :param max_width: 允许的最大宽度（如版心可用宽度）
    :param max_height: 允许的最大高度（如页面可用高度的 40%~50%）
    :return: 缩放后的 PIL.Image
    """
    w, h = image.size
    if w <= max_width and h <= max_height:
        return image

    ratio = min(max_width / float(w), max_height / float(h))
    new_w = max(1, int(w * ratio))
    new_h = max(1, int(h * ratio))

    return image.resize((new_w, new_h), Image.Resampling.LANCZOS)


def process_image_to_handdrawn(
    image_input: Union[bytes, Image.Image, np.ndarray],
    ink_color: Tuple[int, int, int] = (20, 20, 25),
    jitter_intensity: float = 1.0,
    noise_ratio: float = 0.003,
) -> Image.Image:
    """将输入图片转换为仿手绘墨水线稿风格的透明 PNG 图片。

    :param image_input: 输入图片（bytes, PIL.Image 或 numpy.ndarray）
    :param ink_color: 墨水 RGB 颜色，默认为深墨黑 (20, 20, 25)
    :param jitter_intensity: 笔触随机抖动强度（模拟人手画线的不平整）
    :param noise_ratio: 墨水飞溅/细微噪点比例
    :return: 具有透明背景的 PIL.Image (RGBA)
    """
    # 1. 统一转换为 OpenCV BGR 格式
    if isinstance(image_input, bytes):
        nparr = np.frombuffer(image_input, np.uint8)
        img_bgr = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    elif isinstance(image_input, Image.Image):
        img_rgb = image_input.convert("RGB")
        img_bgr = cv2.cvtColor(np.array(img_rgb), cv2.COLOR_RGB2BGR)
    elif isinstance(image_input, np.ndarray):
        img_bgr = image_input
    else:
        raise ValueError(f"不支持的输入图片类型: {type(image_input)}")

    if img_bgr is None:
        raise ValueError("无法解码输入图片")

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
        small_dx = (np.random.rand(h // scale + 2, w // scale + 2) - 0.5) * (jitter_intensity * 2.5)
        small_dy = (np.random.rand(h // scale + 2, w // scale + 2) - 0.5) * (jitter_intensity * 2.5)

        dx = cv2.resize(small_dx, (w, h), interpolation=cv2.INTER_CUBIC)
        dy = cv2.resize(small_dy, (w, h), interpolation=cv2.INTER_CUBIC)

        grid_x, grid_y = np.meshgrid(np.arange(w), np.arange(h))
        map_x = np.clip(grid_x + dx, 0, w - 1).astype(np.float32)
        map_y = np.clip(grid_y + dy, 0, h - 1).astype(np.float32)

        binary = cv2.remap(binary, map_x, map_y, interpolation=cv2.INTER_LINEAR)

    # 4. 模拟墨水深度不均 (Ink depth shading)
    # 通过微弱的高斯噪声扰动线条的透明度/粗细
    ink_mask = binary.astype(np.float32) / 255.0
    ink_noise = np.random.uniform(0.75, 1.0, size=(h, w)).astype(np.float32)
    alpha_channel = (ink_mask * ink_noise * 255.0).astype(np.uint8)

    # 5. 添加微弱的手写墨水飞溅/细微噪点 (Salt/Ink Splatter)
    if noise_ratio > 0:
        noise_mask = np.random.rand(h, w) < noise_ratio
        # 仅在线条附近产生少量微弱墨滴飞溅
        dilated = cv2.dilate(binary, np.ones((5, 5), np.uint8), iterations=1)
        splatter_zone = (dilated > 0) & noise_mask
        alpha_channel[splatter_zone] = np.random.randint(100, 200, size=np.count_nonzero(splatter_zone), dtype=np.uint8)

    # 6. 合成 RGBA 图像
    r_val, g_val, b_val = ink_color
    r_channel = np.full((h, w), r_val, dtype=np.uint8)
    g_channel = np.full((h, w), g_val, dtype=np.uint8)
    b_channel = np.full((h, w), b_val, dtype=np.uint8)

    rgba = np.dstack([r_channel, g_channel, b_channel, alpha_channel])
    return Image.fromarray(rgba, mode="RGBA")


def get_rendered_ink_bottom_y(image: Image.Image, background: Image.Image) -> int:
    """对比渲染结果与原始底图，检测当前页面最后一行墨迹字符的最低 Y 坐标。"""
    try:
        im_arr = np.array(image)
        bg_arr = np.array(background)
        # 计算 RGB 差异
        diff = np.abs(im_arr.astype(np.int16) - bg_arr.astype(np.int16))
        # 差异显著的点即为绘制的墨迹
        ink_mask = np.any(diff > 15, axis=2)
        y_indices, _ = np.where(ink_mask)
        if len(y_indices) > 0:
            return int(np.max(y_indices))
    except Exception:
        pass
    return 0


# 匹配 Markdown 图片标记 ![alt](data:image/... 或 url/base64)
MARKDOWN_IMAGE_RE = re.compile(
    r"!\[(.*?)\]\(((?:data:image\/[^;]+;base64,)?[A-Za-z0-9+/=\s]+)\)",
    re.DOTALL,
)


def _parse_image_scale(alt_text: str) -> float:
    """从 alt 文本中解析缩放比例（如 '插图 1|50%'、'插图 1|scale=0.6' 或 '30%'），默认 1.0 (100%)。"""
    if not alt_text or "|" not in alt_text:
        return 1.0
    try:
        parts = alt_text.split("|", 1)
        param = parts[1].strip().lower()
        if "%" in param:
            pct_match = re.search(r"(\d+(?:\.\d+)?)\s*%", param)
            if pct_match:
                pct = float(pct_match.group(1))
                return max(0.1, min(1.0, pct / 100.0))
        scale_match = re.search(r"(?:scale\s*=\s*|w\s*=\s*)?(\d+(?:\.\d+)?)", param)
        if scale_match:
            val = float(scale_match.group(1))
            if val > 1.0:
                # 可能是百分比整数如 50
                if val <= 100.0:
                    return max(0.1, min(1.0, val / 100.0))
            else:
                return max(0.1, min(1.0, val))
    except Exception:
        pass
    return 1.0


def render_inline_markdown_images(
    text: str,
    template,
    handwrite_fn,
) -> list:
    """解析 Markdown 中的插图标记，将文本与插图进行手写与墨水线稿智能排版合成。
    
    当文本不包含图片标记时，直接调用 handwrite_fn(text, template)。
    当文本包含图片标记时，按图片将内容划分为多个片段，并在上一段文本下方对齐贴合插图，
    消除文字与插图重叠碰撞问题。
    """
    if not MARKDOWN_IMAGE_RE.search(text):
        return handwrite_fn(text, template)

    # 解析文本片段与图片列表
    parts = []
    last_end = 0
    for match in MARKDOWN_IMAGE_RE.finditer(text):
        before_text = text[last_end:match.start()]
        alt_text = match.group(1).strip()
        img_data = match.group(2).strip()
        scale = _parse_image_scale(alt_text)
        parts.append(("text", before_text, 1.0))
        parts.append(("image", img_data, scale))
        last_end = match.end()
    remaining = text[last_end:]
    if remaining:
        parts.append(("text", remaining, 1.0))

    bg_orig = template.get_background()
    width, height = bg_orig.size
    top_margin_orig = template.get_top_margin()
    bottom_margin = template.get_bottom_margin()
    left_margin = template.get_left_margin()
    right_margin = template.get_right_margin()
    line_spacing = template.get_line_spacing()

    usable_width = width - left_margin - right_margin
    max_img_height = int((height - top_margin_orig - bottom_margin) * 0.45)

    all_pages = []
    current_canvas = bg_orig.copy()
    current_top = top_margin_orig
    page_dirty = False

    def clone_template_with_top(base_tpl, canvas, top_val):
        new_tpl = copy.copy(base_tpl)
        new_tpl.set_background(canvas)
        new_tpl.set_top_margin(top_val)
        return new_tpl

    import copy

    for part_type, content, scale in parts:
        if part_type == "text":
            if not content.strip():
                continue
            # 渲染当前文本片段
            sub_tpl = clone_template_with_top(template, current_canvas, current_top)
            rendered_sub = list(handwrite_fn(content, sub_tpl))
            if not rendered_sub:
                continue

            if len(rendered_sub) == 1:
                # 仍在当前页
                current_canvas = rendered_sub[0]
                page_dirty = True
                ink_bottom = get_rendered_ink_bottom_y(current_canvas, bg_orig)
                current_top = max(current_top, ink_bottom + line_spacing)
            else:
                # 文本跨页，已填满前面页面
                all_pages.extend(rendered_sub[:-1])
                current_canvas = rendered_sub[-1]
                page_dirty = True
                ink_bottom = get_rendered_ink_bottom_y(current_canvas, bg_orig)
                current_top = max(top_margin_orig, ink_bottom + line_spacing)

        elif part_type == "image":
            raw_img = decode_base64_image(content)
            if raw_img is None:
                continue

            # 转换为透明墨水手绘风格
            hd_img = process_image_to_handdrawn(raw_img)
            # 自适应页面版心缩放，根据 scale 调节最大允许宽度
            target_max_width = max(50, int(usable_width * scale))
            target_max_height = max(50, int(max_img_height * scale))
            fitted_img = fit_image_to_layout(
                hd_img, max_width=target_max_width, max_height=target_max_height
            )
            img_w, img_h = fitted_img.size

            # 检查当前页剩余空间是否放得下该图片
            if current_top + img_h > height - bottom_margin:
                # 空间不足，当前页落版翻页
                if page_dirty:
                    all_pages.append(current_canvas)
                current_canvas = bg_orig.copy()
                current_top = top_margin_orig
                page_dirty = False

            # 将图片居中粘贴在版心横向区域
            paste_x = left_margin + max(0, (usable_width - img_w) // 2)
            paste_y = current_top
            current_canvas.paste(fitted_img, (paste_x, paste_y), fitted_img)
            page_dirty = True

            # 更新下一段文字的起始 top_margin，向下推移图片高度加上整行行间距
            current_top = paste_y + img_h + line_spacing

    if page_dirty:
        all_pages.append(current_canvas)

    return all_pages if all_pages else [bg_orig.copy()]

