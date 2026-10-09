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
