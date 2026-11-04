import unittest

from analyze_preserved_summaries import coverage


class PreservedSummaryAnalysisTests(unittest.TestCase):
    def items(self):
        return [{"id": f"C{i}", "status": "absent", "reason": "Test-only absent item"} for i in range(1, 7)]

    def test_partial_item_is_one_twelfth_not_summary_accuracy(self):
        items = self.items()
        items[1] = {"id": "C2", "status": "partial", "quote": "some duty", "reason": "Test-only partial quote"}
        self.assertAlmostEqual(coverage(items, "some duty"), 1 / 12)

    def test_missing_duplicate_or_unmatched_reviews_fail(self):
        items = self.items()
        with self.assertRaises(ValueError):
            coverage(items[:-1], "")
        items[-1]["id"] = "C1"
        with self.assertRaises(ValueError):
            coverage(items, "")
        items = self.items()
        items[0] = {"id": "C1", "status": "full", "quote": "missing", "reason": "Test-only unmatched quote"}
        with self.assertRaises(ValueError):
            coverage(items, "different text")


if __name__ == "__main__":
    unittest.main()
