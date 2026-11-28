"""Regression cases for indexed alignment, incomplete evidence, and raster scoring."""

import tempfile
import unittest
from pathlib import Path

from paper_geometry import (
    generate_depth_paper,
    generate_public_paper,
    load_labels,
    score_ink,
    score_layout,
)
from PIL import Image, ImageDraw


class PaperGeometryTest(unittest.TestCase):
    def setUp(self):
        self.labels = {
            "size": [100, 100],
            "xs": [10, 50, 90],
            "rows": [[20] * 3, [40] * 3, [60] * 3],
        }
        self.glyphs = [
            {
                "bounds": [10, 12, 12, 8],
                "photo_quad": [[10, 12], [22, 12], [22, 20], [10, 20]],
                "photo_baseline": [[10, 20], [22, 20]],
            }
        ]

    def test_shift_is_not_snapped_to_nearest_ruling(self):
        self.assertEqual(score_layout(self.labels, self.glyphs)["median_abs_rows"], 0)
        self.glyphs[0]["photo_baseline"] = [[10, 40], [22, 40]]
        self.assertEqual(score_layout(self.labels, self.glyphs)["median_abs_rows"], 1)

    def test_edited_quad_uses_current_coordinates(self):
        glyph = self.glyphs[0]
        glyph["adjustment"] = {"dy": 20}
        glyph["current_photo_quad"] = [[x, y + 20] for x, y in glyph["photo_quad"]]
        self.assertEqual(score_layout(self.labels, self.glyphs)["p90_abs_rows"], 1)

    def test_missing_projection_and_empty_depth(self):
        result = score_layout(self.labels, self.glyphs + [{"bounds": [10, 40, 15, 8]}])
        self.assertEqual(result["coverage"], 0.5)
        self.assertIsNone(result["depth_bands"]["bottom"]["p90_abs_rows"])

    def test_foreground_is_required(self):
        bg = Image.new("L", (100, 100), 220)
        self.assertEqual(
            score_ink(self.labels, bg, bg, self.glyphs)["glyphs_with_visible_ink"], 0
        )
        final = bg.copy()
        ImageDraw.Draw(final).rectangle((12, 14, 20, 19), fill=50)
        result = score_ink(self.labels, bg, final, self.glyphs)
        self.assertEqual(result["glyphs_with_visible_ink"], 1)
        self.assertEqual(result["outside_quad_changed_fraction"], 0)
        self.assertAlmostEqual(result["median_ink_bottom_signed_rows"], -0.05)

    def test_public_sources_replay(self):
        with tempfile.TemporaryDirectory() as folder:
            for key, generate, expected in [
                ("public-grid", generate_public_paper, 19),
                ("public-depth", generate_depth_paper, 13),
            ]:
                path = Path(folder) / "page.png"
                labels = generate(path)
                first = path.read_bytes()
                self.assertEqual(labels, load_labels(key))
                self.assertEqual(len(labels["rows"]), expected)
                generate(path)
                self.assertEqual(first, path.read_bytes())


if __name__ == "__main__":
    unittest.main()
