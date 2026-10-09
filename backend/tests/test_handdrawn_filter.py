# -*- coding: utf-8 -*-
import numpy as np
from PIL import Image, ImageDraw
from handdrawn_filter import process_image_to_handdrawn


def test_process_image_to_handdrawn_basic():
    # 创建一张包含黑线矩形和圆形的简易测试图
    test_img = Image.new("RGB", (200, 200), color=(255, 255, 255))
    draw = ImageDraw.Draw(test_img)
    draw.rectangle([30, 30, 170, 170], outline=(0, 0, 0), width=3)
    draw.ellipse([60, 60, 140, 140], outline=(0, 0, 0), width=2)

    # 运行手绘墨水风格滤镜
    result = process_image_to_handdrawn(test_img, ink_color=(30, 30, 40))

    assert isinstance(result, Image.Image)
    assert result.mode == "RGBA"
    assert result.size == (200, 200)

    # 验证透明度通道：原白色背景应基本为透明（Alpha=0），线条位置有可见 Alpha
    arr = np.array(result)
    alpha = arr[:, :, 3]
    # 背景大部分像素应为 0
    assert np.count_nonzero(alpha == 0) > 10000
    # 线条像素应有非零 Alpha
    assert np.count_nonzero(alpha > 100) > 500


def test_fit_image_to_layout():
    from handdrawn_filter import fit_image_to_layout

    # 1. 较小图片不缩放
    small_img = Image.new("RGB", (300, 200))
    res_small = fit_image_to_layout(small_img, max_width=800, max_height=600)
    assert res_small.size == (300, 200)

    # 2. 超大宽度图片按比例缩放
    large_w_img = Image.new("RGB", (2000, 1000))
    res_w = fit_image_to_layout(large_w_img, max_width=1000, max_height=800)
    assert res_w.size == (1000, 500)

    # 3. 超大高度图片按比例缩放
    large_h_img = Image.new("RGB", (800, 1600))
    res_h = fit_image_to_layout(large_h_img, max_width=1000, max_height=800)
    assert res_h.size == (400, 800)
