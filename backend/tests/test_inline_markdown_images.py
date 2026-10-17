# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""Markdown 图文混排与手绘插图排版单元测试."""

import base64
import io
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
from handdrawn_filter import (
    MARKDOWN_IMAGE_RE,
    _parse_image_scale,
    decode_base64_image,
    fit_image_to_layout,
    process_image_to_handdrawn,
    render_inline_markdown_images,
)
from handright import Template, handwrite
from math_page_layout import RuledTemplate
from PIL import Image, ImageDraw, ImageFont


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

    def test_large_image_percentage_uses_fitted_size(self):
        fitted = fit_image_to_layout(self.img.resize((1000, 800)), 500, 300, 0.5)
        self.assertEqual(fitted.size, (187, 150))

    def test_transparent_black_line_survives_white_compositing(self):
        transparent = Image.new("RGBA", (80, 60), (0, 0, 0, 0))
        ImageDraw.Draw(transparent).line((10, 30, 70, 30), fill=(0, 0, 0, 255), width=3)
        white = Image.new("RGBA", transparent.size, (255, 255, 255, 255))
        opaque = Image.alpha_composite(white, transparent)
        masks = []
        for image in (transparent, opaque):
            result = process_image_to_handdrawn(image, jitter_intensity=0, noise_ratio=0)
            masks.append(np.asarray(result.getchannel("A")) > 0)
        self.assertTrue(np.array_equal(*masks))
        self.assertTrue(masks[0].any())
        self.assertFalse(masks[0][0, 0])
        buf = io.BytesIO()
        transparent.save(buf, format="PNG")
        decoded = decode_base64_image(base64.b64encode(buf.getvalue()).decode("ascii"))
        self.assertEqual(decoded.getpixel((0, 0)), (0, 0, 0, 0))
        self.assertEqual(decoded.getpixel((30, 30)), (0, 0, 0, 255))

    def test_phone_photo_exif_direction_and_decode_limits(self):
        photo = Image.new("RGB", (20, 10), "white")
        exif = Image.Exif()
        exif[274] = 6
        buf = io.BytesIO()
        photo.save(buf, format="JPEG", exif=exif)
        encoded = base64.b64encode(buf.getvalue()).decode("ascii")
        self.assertEqual(decode_base64_image(encoded).size, (10, 20))
        with patch("handdrawn_filter.MAX_IMAGE_PIXELS", 100):
            self.assertIsNone(decode_base64_image(encoded))
        with patch("handdrawn_filter.MAX_IMAGE_BYTES", 10):
            self.assertIsNone(decode_base64_image(encoded))
        self.assertIsNone(decode_base64_image(encoded + "!"))

    def test_invalid_embedded_image_reports_failure(self):
        bad = base64.b64encode(b"not an image").decode("ascii")
        with self.assertRaisesRegex(ValueError, "插图无法解码"):
            render_inline_markdown_images(
                f"![broken](data:image/png;base64,{bad})",
                MockTemplate(Image.new("RGB", (600, 800), "white")),
                lambda _text, _template: [],
            )

    def test_filter_receives_fitted_image_instead_of_full_resolution(self):
        buf = io.BytesIO()
        self.img.resize((1000, 800)).save(buf, format="PNG")
        data = base64.b64encode(buf.getvalue()).decode("ascii")
        with patch("handdrawn_filter.process_image_to_handdrawn") as process:
            process.return_value = Image.new("RGBA", (260, 208), (0, 0, 0, 0))
            render_inline_markdown_images(
                f"![图|50%](data:image/png;base64,{data})",
                MockTemplate(Image.new("RGB", (600, 800), "white")),
                lambda _text, _template: [],
            )
            self.assertEqual(process.call_args.args[0].size, (260, 208))

    def test_fit_image_to_layout_enlarges_small_image(self):
        small_img = Image.new("RGB", (100, 60), (255, 255, 255))
        # 放大 1.5 倍
        fitted = fit_image_to_layout(small_img, max_width=500, max_height=300, scale=1.5)
        self.assertEqual(fitted.size[0], 150)
        self.assertEqual(fitted.size[1], 90)

        # 放大 2.0 倍
        fitted_2x = fit_image_to_layout(small_img, max_width=500, max_height=300, scale=2.0)
        self.assertEqual(fitted_2x.size[0], 200)
        self.assertEqual(fitted_2x.size[1], 120)

        # 放大超过版心时截断在版心内
        fitted_clamped = fit_image_to_layout(small_img, max_width=120, max_height=300, scale=2.0)
        self.assertEqual(fitted_clamped.size[0], 120)
        self.assertEqual(fitted_clamped.size[1], 72)

    def test_text_after_image_returns_to_original_ruled_paper_grid(self):
        tpl = RuledTemplate(
            background=Image.new("RGB", (600, 800), "white"),
            font=ImageFont.truetype(
                str(Path(__file__).resolve().parents[1] / "font_assets/云烟体.ttf"), 24
            ),
            line_spacing=30,
            top_margin=40,
            bottom_margin=40,
            left_margin=40,
            right_margin=40,
        )
        tpl.ruled_origin = 40
        starts = []

        def handwrite(text, template):
            starts.append((text, template.get_top_margin(), template.ruled_origin))
            return [template.get_background().copy()]

        with patch("handdrawn_filter.process_image_to_handdrawn") as process:
            process.return_value = Image.new("RGBA", (100, 61), (0, 0, 0, 255))
            render_inline_markdown_images(self.img_markdown + "\n文字", tpl, handwrite)
        self.assertEqual(starts, [("\n文字", 160, 40)])

    def test_image_leaving_no_complete_text_row_starts_a_clean_page(self):
        for template_type, image_height in (
            (RuledTemplate, 661),
            (RuledTemplate, 725),
            (Template, 725),
        ):
            with self.subTest(template_type=template_type.__name__, image_height=image_height):
                tpl = template_type(
                    background=Image.new("RGB", (600, 805), "white"),
                    font=ImageFont.truetype(
                        str(Path(__file__).resolve().parents[1] / "font_assets/云烟体.ttf"), 24
                    ),
                    line_spacing=30,
                    top_margin=40,
                    bottom_margin=40,
                    left_margin=40,
                    right_margin=40,
                    line_spacing_sigma=0,
                    font_size_sigma=0,
                    word_spacing_sigma=0,
                    perturb_x_sigma=0,
                    perturb_y_sigma=0,
                    perturb_theta_sigma=0,
                )
                if isinstance(tpl, RuledTemplate):
                    tpl.ruled_origin = 40
                with patch("handdrawn_filter.process_image_to_handdrawn") as process:
                    process.return_value = Image.new("RGBA", (100, image_height), (0, 0, 0, 255))
                    pages = list(
                        render_inline_markdown_images(self.img_markdown + "文字", tpl, handwrite)
                    )
                self.assertEqual(len(pages), 2)
                self.assertEqual(pages[0].getpixel((300, 50)), (0, 0, 0))
                ink = np.any(np.asarray(pages[1]) < 255, axis=2)
                ys, xs = np.nonzero(ink)
                self.assertGreater(len(xs), 0)
                self.assertGreaterEqual(int(ys.min()), 40)
                self.assertLess(int(ys.max()), 100)
                self.assertGreaterEqual(int(xs.min()), 40)
                self.assertLess(int(xs.max()), 200)

    def test_render_inline_markdown_images_with_handwrite(self):
        bg = Image.new("RGB", (600, 800), (255, 255, 255))
        tpl = MockTemplate(bg)

        # 模拟 handwrite 行为：在背景上打上墨迹
        def mock_handwrite(_text, template):
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

        self.assertAlmostEqual(_parse_image_scale("插图 1"), 1.0)
        self.assertAlmostEqual(_parse_image_scale("插图 1|50%"), 0.5)
        self.assertAlmostEqual(_parse_image_scale("插图 1|30%"), 0.3)
        self.assertAlmostEqual(_parse_image_scale("插图 1|scale=0.75"), 0.75)
        self.assertAlmostEqual(_parse_image_scale("插图 1|100%"), 1.0)
        self.assertAlmostEqual(_parse_image_scale("插图 1|150%"), 1.5)
        self.assertAlmostEqual(_parse_image_scale("插图 1|200%"), 2.0)
        self.assertAlmostEqual(_parse_image_scale("插图 1|500%"), 5.0)
        self.assertAlmostEqual(_parse_image_scale("插图 1|700%"), 7.0)
        self.assertAlmostEqual(_parse_image_scale("插图 1|scale=6.5"), 6.5)

    def test_fit_image_to_layout_5_to_7_times(self):
        tiny_img = Image.new("RGB", (40, 20), (255, 255, 255))
        # 放大 5 倍
        fitted_5x = fit_image_to_layout(tiny_img, max_width=500, max_height=300, scale=5.0)
        self.assertEqual(fitted_5x.size, (200, 100))

        # 放大 7 倍
        fitted_7x = fit_image_to_layout(tiny_img, max_width=500, max_height=300, scale=7.0)
        self.assertEqual(fitted_7x.size, (280, 140))


if __name__ == "__main__":
    unittest.main()
