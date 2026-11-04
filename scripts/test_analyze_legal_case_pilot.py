import hashlib
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from matplotlib.figure import Figure
import pandas as pd

from analyze_legal_case_pilot import (
    attach_reviews, plot_retrieval_comparison, retrieval_summary, sample_frame, save_figure,
)
from analyze_rag_logs import save_figure as save_historical_figure


class LegalCaseAnalysisTests(unittest.TestCase):
    def report(self):
        text = "가상 원문"
        fingerprint = hashlib.sha256(text.encode()).hexdigest()
        samples = []
        for mode in ("currentOnly", "keyword", "hybrid"):
            run = {
                "targetDocumentID": "target", "corpusFingerprints": {"target": fingerprint},
                "search": {"requestedMode": mode, "effectiveMode": mode, "hits": [],
                           "semanticModelIdentity": {
                               "warmBeforeSearch": "false", "vectorCacheHits": "0", "vectorCacheMisses": "1"
                           } if mode == "hybrid" else {}},
                "retrievalMS": 10,
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

    def test_retrieval_metrics_use_fixed_k_and_exclude_missing_gold(self):
        report = self.report()
        report["dataset"]["queries"].append({
            "id": "positive", "targetDocumentID": "target", "relevantDocumentIDs": ["ref"]})
        for sample in list(report["samples"]):
            positive = copy.deepcopy(sample)
            positive["queryID"] = "positive"
            if positive["run"]["search"]["requestedMode"] != "currentOnly":
                positive["run"]["search"]["hits"] = [
                    {"chunk": {"documentID": "distractor"}}, {"chunk": {"documentID": "ref"}}]
            report["samples"].append(positive)
        frame = sample_frame(report)
        summary = retrieval_summary(frame)
        self.assertEqual(list(summary.index), ["keyword", "hybrid"])
        for mode in summary.index:
            self.assertAlmostEqual(summary.loc[mode, "precision_at_3"], 1 / 6)
            self.assertEqual(summary.loc[mode, "recall_at_3"], 1)
            self.assertEqual(summary.loc[mode, "mrr_at_3"], 0.5)
            self.assertEqual(summary.loc[mode, "no_reference_success_rate"], 1)
            self.assertEqual(summary.loc[mode, "positive_queries"], 1)
            self.assertEqual(summary.loc[mode, "no_reference_queries"], 1)

    def test_undefined_metrics_remain_missing_and_fallback_is_not_hybrid(self):
        summary = retrieval_summary(sample_frame(self.report()))
        self.assertTrue(summary["recall_at_3"].isna().all())
        self.assertTrue(summary["mrr_at_3"].isna().all())
        report = self.report()
        report["samples"][-1]["run"]["search"]["effectiveMode"] = "keyword"
        with self.assertRaisesRegex(ValueError, "fallback"):
            retrieval_summary(sample_frame(report))

    def test_invalid_timing_and_cache_metadata_are_rejected(self):
        for value in (-1, float("nan"), None, True):
            report = self.report()
            report["samples"][0]["run"]["retrievalMS"] = value
            with self.assertRaisesRegex(ValueError, "Invalid retrieval time"):
                sample_frame(report)
        report = self.report()
        report["samples"][-1]["run"]["search"]["semanticModelIdentity"]["vectorCacheHits"] = "-1"
        with self.assertRaisesRegex(ValueError, "Invalid embedding cache"):
            sample_frame(report)

    def test_quality_bars_show_real_values_and_latency_uses_log_scale(self):
        frame = sample_frame(self.report())
        summary = retrieval_summary(frame)
        with patch("analyze_legal_case_pilot.save_figure") as save:
            plot_retrieval_comparison(frame, summary, Path("."))
        self.assertEqual(save.call_count, 3)
        quality = save.call_args_list[1].args[0]
        heights = [bar.get_height() for bar in quality.axes[0].patches]
        self.assertEqual(len(heights), 10)
        for offset in (0, 5):
            self.assertEqual(heights[offset], 0)
            self.assertTrue(pd.isna(heights[offset + 1]))
            self.assertTrue(pd.isna(heights[offset + 2]))
            self.assertEqual(heights[offset + 3], 1)
        latency = save.call_args_list[2].args[0]
        self.assertEqual(latency.axes[0].get_yscale(), "log")
        self.assertTrue(all(value == 0.01 for line in latency.axes[0].lines for value in line.get_ydata()))
        from matplotlib import pyplot as plt
        for call in save.call_args_list:
            plt.close(call.args[0])

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
