"""Semantic witnesses must detect errors even when all required words and numbers are present."""

import unittest

from content_matrix import CASES, graph_checks, table_check


class ContentWitnessTests(unittest.TestCase):
    def test_swapping_two_values_fails_on_their_respective_rows(self):
        expected = CASES["table2"]["tables"][0]
        result = table_check(
            [["项目", "数值"], ["输入能量", "40 J"], ["输出能量", "50 J"]], expected
        )
        self.assertTrue(result["header_present"])
        self.assertTrue(result["data_row_count"])
        self.assertEqual(result["row_matches"], [False, False])
        result = table_check(
            [["项目", "数值"], ["输入能量", "150 J"], ["输出能量", "40 J"]], expected
        )
        self.assertEqual(result["row_matches"], [False, True])

    def test_graph_requires_matching_direction_and_edge_label(self):
        expected = CASES["flow1"]["graphs"][0]
        points = [(0, 0), (0, -2), (-3, -4), (3, -4)]
        marks = [
            {
                "kind": "diamond" if i == 1 else "rectangle",
                "position": point,
                "text": expected["nodes"][i],
            }
            for i, point in enumerate(points)
        ]
        graph = {
            "marks": marks
            + [
                {"kind": "left", "position": [-1.5, -3], "text": "是"},
                {"kind": "right", "position": [1.5, -3], "text": "否"},
            ],
            "segments": [
                {"from": points[i], "to": points[j], "arrow": True}
                for i, j in [(0, 1), (1, 2), (1, 3)]
            ],
        }
        self.assertTrue(graph_checks(graph, expected)["expected_edges_match"])
        graph["marks"][-1]["text"] = "是"
        graph["marks"][-2]["text"] = "否"
        wrong = graph_checks(graph, expected)
        self.assertTrue(wrong["expected_nodes_present"])
        self.assertFalse(wrong["expected_edges_match"])
        graph["marks"][-1]["text"] = "否"
        graph["marks"][-2]["text"] = "是"
        graph["segments"][0]["from"], graph["segments"][0]["to"] = points[1], points[0]
        self.assertFalse(graph_checks(graph, expected)["expected_edges_match"])


if __name__ == "__main__":
    unittest.main()
