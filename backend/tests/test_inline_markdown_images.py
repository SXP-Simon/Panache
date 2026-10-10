# -*- coding: utf-8 -*-
"""
Markdown 图文混排与手绘插图排版单元测试
"""

import base64
import io
import unittest
from unittest.mock import MagicMock

from PIL import Image, ImageDraw
from handdrawn_filter import (
    MARKDOWN_IMAGE_RE,
    decode_base64_image,
    fit_image_to_layout,
    render_inline_markdown_images,
)


class InlineMarkdownImageTest(unittest.TestCase):
    def setUp(self):
        # 构造一张测试图片并转 base64
        self.img = Image.new("RGB", (100, 60), (255, 255, 255))
        d = ImageDraw.Draw(self.img)
        d.line([0, 0, 100, 60], fill=(0, 0, 0), width=2)
        buf = io.BytesIO()
        self.img.save(buf, format="PNG")
        self.b64_data = base64.b64encode(buf.getvalue()).decode("utf-8")
        self.img_markdown = f"![草图](data:image/png;base64,{self.b64_data})"

    def test_markdown_regex_matching(self):
        text = f"前置文本\n{self.img_markdown}\n后续文本"
        matches = list(MARKDOWN_IMAGE_RE.finditer(text))
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0].group(1), "草图")
        self.assertIn(self.b64_data, matches[0].group(2))

    def test_decode_base64_image(self):
        decoded = decode_base64_image(f"data:image/png;base64,{self.b64_data}")
        self.assertIsNotNone(decoded)
        self.assertEqual(decoded.size, (100, 60))

        # 测试无效 base64
        invalid = decode_base64_image("invalid_base64_string")
        self.assertIsNone(invalid)

    def test_fit_image_to_layout_scales_down(self):
        large_img = Image.new("RGB", (1000, 800), (255, 255, 255))
        fitted = fit_image_to_layout(large_img, max_width=500, max_height=300)
        self.assertLessEqual(fitted.size[0], 500)
        self.assertLessEqual(fitted.size[1], 300)

    def test_render_inline_markdown_images_with_handwrite(self):
        bg = Image.new("RGB", (600, 800), (255, 255, 255))

        class MockTemplate:
            def __init__(self, bg):
                self._bg = bg
                self._top = 40
            def get_background(self):
                return self._bg
            def set_background(self, b):
                self._bg = b
            def get_top_margin(self):
                return self._top
            def set_top_margin(self, t):
                self._top = t
            def get_bottom_margin(self):
                return 40
            def get_left_margin(self):
                return 40
            def get_right_margin(self):
                return 40
            def get_line_spacing(self):
                return 30

        tpl = MockTemplate(bg)

        # 模拟 handwrite 行为：在背景上打上墨迹
        def mock_handwrite(text, template):
            canvas = template.get_background().copy()
            d = ImageDraw.Draw(canvas)
            # 在 top_margin 处画一道墨迹方块
            y = template.get_top_margin()
            d.rectangle([50, y, 200, y + 20], fill=(0, 0, 0))
            return [canvas]

        text = f"Question 1: Graph Proof\n{self.img_markdown}\nConclusion: Proved."
        pages = render_inline_markdown_images(text, tpl, mock_handwrite)

        self.assertEqual(len(pages), 1)
        self.assertEqual(pages[0].size, (600, 800))

    def test_parse_image_scale(self):
        from handdrawn_filter import _parse_image_scale
        self.assertAlmostEqual(_parse_image_scale("插图 1"), 1.0)
        self.assertAlmostEqual(_parse_image_scale("插图 1|50%"), 0.5)
        self.assertAlmostEqual(_parse_image_scale("插图 1|30%"), 0.3)
        self.assertAlmostEqual(_parse_image_scale("插图 1|scale=0.75"), 0.75)
        self.assertAlmostEqual(_parse_image_scale("插图 1|100%"), 1.0)



if __name__ == "__main__":
    unittest.main()
