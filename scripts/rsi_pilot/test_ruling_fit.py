"""Check intentional gaps, specified row errors, missing targets and page diagnostics."""

import unittest

from row_intent_challenge import challenge_sheet, paired_challenge
from ruling_fit import diagnose_page, page_sequence


class RulingFitTest(unittest.TestCase):
    def test_same_pixels_require_different_row_judgments(self):
        free, named = paired_challenge()["paired_cases"]
        self.assertEqual(
            [free["indexed_rule"], named["indexed_rule"]], ["review", "review"]
        )
        self.assertEqual(
            [free["intent_aware_rule"], named["intent_aware_rule"]], ["pass", "review"]
        )
        self.assertEqual(free["nearest_p90_abs_rows"], named["nearest_p90_abs_rows"])
        self.assertLess(free["nearest_p90_abs_rows"], 0.025)
        self.assertEqual(free["unused_interior_rows"], [1])
        self.assertGreater(named["required_assignments"][1]["p90_abs_rows"], 0.95)

    def test_missing_required_line_stays_unmeasured(self):
        labels, _, _, glyphs = challenge_sheet()
        report = diagnose_page(labels, glyphs, required_rows={3: 4})
        self.assertIsNone(report["required_assignments"][0]["p90_abs_rows"])

    def test_interior_page_hole_and_duplicate(self):
        pages = [{"section": 1, "page": p} for p in (1, 3, 3)]
        data = page_sequence(pages)[0]
        self.assertEqual(data["missing_page_numbers"], [2])
        self.assertEqual(data["duplicate_page_numbers"], [3])


if __name__ == "__main__":
    unittest.main()
