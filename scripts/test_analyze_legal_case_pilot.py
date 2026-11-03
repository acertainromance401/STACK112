import hashlib
from pathlib import Path
import tempfile
import unittest

from matplotlib.figure import Figure
import pandas as pd

from analyze_legal_case_pilot import attach_reviews, sample_frame, save_figure
from analyze_rag_logs import save_figure as save_historical_figure


class LegalCaseAnalysisTests(unittest.TestCase):
    def report(self):
        text = "가상 원문"
        fingerprint = hashlib.sha256(text.encode()).hexdigest()
        samples = []
        for mode in ("currentOnly", "keyword", "hybrid"):
            run = {
                "targetDocumentID": "target", "corpusFingerprints": {"target": fingerprint},
                "search": {"requestedMode": mode, "effectiveMode": mode, "hits": []},
                "evidence": [{"id": "E0", "chunk": {
                    "documentID": "target", "startUTF16": 0, "endUTF16": len(text), "text": text}}],
                "claims": [], "environment": "simulator_not_device_evidence",
                "failureReason": "expected model failure"
            }
            samples.append({"queryID": "q", "repetition": 1, "run": run, "outputSuccess": False})
        return {"dataset": {"queries": [{"id": "q", "targetDocumentID": "target", "relevantDocumentIDs": []}],
                            "documents": [{"id": "target", "text": text}]}, "samples": samples}

    def test_failed_attempts_remain_in_grid_and_are_not_output_success(self):
        frame = sample_frame(self.report())
        self.assertEqual(len(frame), 3)
        self.assertFalse(frame["output_success"].any())
        self.assertTrue(frame["exact_reference_set"].all())

    def test_duplicate_or_missing_samples_are_rejected(self):
        report = self.report()
        report["samples"].append(report["samples"][0])
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            sample_frame(report)
        report = self.report()
        report["samples"].pop()
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            sample_frame(report)

    def test_tampered_source_or_evidence_is_rejected(self):
        report = self.report()
        report["samples"][0]["run"]["corpusFingerprints"]["target"] = "wrong"
        with self.assertRaisesRegex(ValueError, "fingerprint"):
            sample_frame(report)
        report = self.report()
        report["samples"][0]["run"]["evidence"][0]["chunk"]["text"] = "변조"
        with self.assertRaisesRegex(ValueError, "evidence"):
            sample_frame(report)

    def test_quality_reviews_require_exact_output_hash(self):
        samples = pd.DataFrame([{"query_id": "q", "mode": "hybrid", "output_sha256": "actual"}])
        reviews = pd.DataFrame([{"query_id": "q", "mode": "hybrid", "output_sha256": "different",
                                 "semantic_rating": "correct"}])
        with self.assertRaisesRegex(ValueError, "exact output"):
            attach_reviews(samples, reviews)

    def test_svg_exports_have_no_trailing_whitespace(self):
        with tempfile.TemporaryDirectory() as directory:
            for name, save in [("pilot", save_figure), ("historical", save_historical_figure)]:
                figure = Figure()
                figure.subplots().plot([0, 1], [1, 0])
                save(figure, Path(directory), name)
                lines = (Path(directory) / f"{name}.svg").read_text(encoding="utf-8").splitlines()
                self.assertTrue(lines)
                self.assertTrue(all(line == line.rstrip(" \t") for line in lines))


if __name__ == "__main__":
    unittest.main()
