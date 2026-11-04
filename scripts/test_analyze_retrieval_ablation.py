import copy
import hashlib
from pathlib import Path
import unittest
from unittest.mock import patch

import matplotlib.pyplot as plt

from analyze_retrieval_ablation import E5_SHA, MODES, PHASES, ablation_frame, plot_comparison, summarize


class RetrievalAblationTests(unittest.TestCase):
    def report(self):
        documents = [{"id": name, "title": name, "text": text} for name, text in
                     [("target", "현재 원문"), ("ref", "관련 선례"), ("other", "다른 선례")]]
        queries = [{"id": name, "targetDocumentID": "target", "question": name,
                    "relevantDocumentIDs": relevant} for name, relevant in [("positive", ["ref"]), ("negative", [])]]
        samples = []
        for query in queries:
            for mode in MODES:
                for phase in PHASES:
                    for repetition in ([1] if phase == PHASES[0] else [1, 2, 3]):
                        hits = []
                        for rank, doc in enumerate(documents[1:], 1):
                            hits.append({
                                "chunk": {"id": doc["id"] + ":0", "documentID": doc["id"],
                                          "documentFingerprint": hashlib.sha256(doc["text"].encode()).hexdigest(),
                                          "startUTF16": 0, "endUTF16": len(doc["text"].encode("utf-16-le")) // 2,
                                          "text": doc["text"]},
                                "score": 0.9 if mode == "semantic" else 1 / (60 + rank),
                                "keywordRank": None if mode == "semantic" else rank,
                                "semanticRank": None if mode == "keyword" else rank,
                            })
                        identity = {} if mode == "keyword" else {
                            "sha256": E5_SHA, "warmBeforeSearch": "false" if phase == PHASES[0] else "true",
                            "vectorCacheHits": "0" if phase == PHASES[0] else "2",
                            "vectorCacheMisses": "3" if phase == PHASES[0] else "1",
                        }
                        samples.append({
                            "queryID": query["id"], "queryText": query["question"] + " target",
                            "phase": phase, "repetition": repetition,
                            "durationMS": 1000 if phase == PHASES[0] else repetition * 10,
                            "search": {"requestedMode": mode, "effectiveMode": mode, "hits": hits,
                                       "semanticModelIdentity": identity, "chunkCount": 2,
                                       "semanticScoredChunkCount": 0 if mode == "keyword" else 2},
                            "relevance": {"precisionAtK": 1 / 3 if query["relevantDocumentIDs"] else 0,
                                          "recallAtK": 1 if query["relevantDocumentIDs"] else None,
                                          "reciprocalRank": 1 if query["relevantDocumentIDs"] else None,
                                          "noRelevantDocumentCorrect": None if query["relevantDocumentIDs"] else False,
                                          "evaluatedDocumentIDs": ["ref", "other"]},
                        })
        return {"schemaVersion": 1, "configuration": {"environment": "simulator_not_device_evidence"},
                "dataset": {"queries": queries, "documents": documents}, "samples": samples}

    def test_quality_counts_queries_once_and_warm_cost_uses_three_repeats(self):
        frame, hits = ablation_frame(self.report())
        quality, timing = summarize(frame)
        self.assertEqual(len(frame), 24)
        self.assertEqual(len(hits), 48)
        self.assertEqual(list(quality.index), MODES)
        for mode in MODES:
            self.assertEqual(quality.loc[mode, "queries"], 2)
            self.assertAlmostEqual(quality.loc[mode, "precision_at_3"], 1 / 6)
            self.assertEqual(quality.loc[mode, "recall_at_3"], 1)
            self.assertEqual(quality.loc[mode, "mrr_at_3"], 1)
            self.assertEqual(quality.loc[mode, "no_reference_success"], 0)
        warm = timing.loc[timing["phase"].eq(PHASES[1])]
        self.assertTrue(warm["observations"].eq(3).all())
        self.assertTrue(warm["median_seconds"].eq(0.02).all())
        self.assertTrue(warm["min_seconds"].eq(0.01).all())
        self.assertTrue(warm["max_seconds"].eq(0.03).all())

    def test_missing_duplicate_fallback_and_invalid_times_are_rejected(self):
        for change in ("missing", "duplicate", "fallback", "nan", "negative"):
            report = self.report()
            if change == "missing":
                report["samples"].pop()
            elif change == "duplicate":
                report["samples"].append(copy.deepcopy(report["samples"][0]))
            elif change == "fallback":
                report["samples"][0]["search"]["effectiveMode"] = "hybrid"
            else:
                report["samples"][0]["durationMS"] = float("nan") if change == "nan" else -1
            with self.subTest(change=change), self.assertRaises(ValueError):
                ablation_frame(report)

    def test_cached_query_is_not_accepted_as_uncached_query_measurement(self):
        report = self.report()
        warm = next(s for s in report["samples"] if s["phase"] == PHASES[1] and s["search"]["requestedMode"] == "semantic")
        warm["search"]["semanticModelIdentity"]["vectorCacheMisses"] = "0"
        with self.assertRaisesRegex(ValueError, "re-encode"):
            ablation_frame(report)

    def test_source_metric_and_semantic_condition_tampering_is_rejected(self):
        for change in ("source", "metric", "lexical", "model"):
            report = self.report()
            sample = next(s for s in report["samples"] if s["search"]["requestedMode"] == "semantic")
            if change == "source":
                sample["search"]["hits"][0]["chunk"]["text"] = "변조"
            elif change == "metric":
                sample["relevance"]["precisionAtK"] = 1
            elif change == "lexical":
                sample["search"]["hits"][0]["keywordRank"] = 1
            else:
                sample["search"]["semanticModelIdentity"]["sha256"] = "different"
            with self.subTest(change=change), self.assertRaises(ValueError):
                ablation_frame(report)

    def test_figures_compare_three_modes_and_separate_cold_and_warm_cost(self):
        frame, _ = ablation_frame(self.report())
        quality, timing = summarize(frame)
        with patch("analyze_retrieval_ablation.save_figure") as save:
            plot_comparison(quality, timing, Path("."))
        self.assertEqual(save.call_count, 3)
        bars = save.call_args_list[1].args[0].axes[0].patches
        self.assertEqual(len(bars), 15)
        for offset in (0, 5, 10):
            self.assertAlmostEqual(bars[offset].get_height(), 1 / 6)
            self.assertEqual(bars[offset + 1].get_height(), 1)
            self.assertEqual(bars[offset + 3].get_height(), 0)
        axes = save.call_args_list[2].args[0].axes
        self.assertEqual(len(axes), 2)
        self.assertTrue(all(ax.get_yscale() == "log" for ax in axes))
        for call in save.call_args_list:
            plt.close(call.args[0])


if __name__ == "__main__":
    unittest.main()
