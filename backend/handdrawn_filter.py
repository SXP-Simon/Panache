# -*- coding: utf-8 -*-
"""
手绘风格图像滤镜与仿真模块 (Handdrawn Filter & Noise Simulation)

将用户粘贴或插入的示意图、电路图、几何草图等：
1. 灰度化与二值化/反色提取纯净线稿；
2. 应用弹性形变/随机微小扰动模拟手绘笔迹的不平整；
3. 加入微弱墨水深浅扰动与随机椒盐/墨滴微噪点；
4. 将白色/浅色背景透明化（RGBA），便于自然贴合在背景纸张或手写排版流中。
"""

import io
import random
from typing import Tuple, Union
import cv2
import numpy as np
from PIL import Image


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
