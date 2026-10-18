# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-18：验证纸张横线在文档常用缩图尺寸下仍可见."""

import unittest

from app import NotebookOptions, create_notebook_image
from PIL import Image


class NotebookLinesTest(unittest.TestCase):
    def test_every_rule_survives_document_downscaling(self):
        for width, height, spacing, top in [(1600, 2200, 120, 100), (3481, 4507, 150, 50)]:
            layout = NotebookOptions(spacing, top, 100, 80, 80, underlined=True)
            paper = create_notebook_image(width, height, layout)
            for target_width in [640, 1270]:
                for method in [
                    Image.Resampling.NEAREST,
                    Image.Resampling.BILINEAR,
                    Image.Resampling.LANCZOS,
                ]:
                    with self.subTest(width=width, target=target_width, method=method):
                        target_height = round(height * target_width / width)
                        resized = paper.resize((target_width, target_height), method)
                        for y in range(top + spacing, height - 100, spacing):
                            center = round(y * target_height / height)
                            band = resized.crop(
                                (target_width // 2, center - 2, target_width // 2 + 1, center + 3)
                            )
                            self.assertLess(band.convert("L").getextrema()[0], 200)

    def test_unruled_paper_remains_opaque_white(self):
        paper = create_notebook_image(
            1600, 2200, NotebookOptions(120, 100, 100, 80, 80, underlined=False)
        )
        self.assertEqual(paper.mode, "RGB")
        self.assertEqual(paper.getextrema(), ((255, 255),) * 3)
