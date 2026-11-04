import copy
import hashlib
from pathlib import Path
import unittest
from unittest.mock import patch

import matplotlib.pyplot as plt

from analyze_long_summaries import LLAMA_SHA, MODES, SCORES, claim_units, evaluate, plot_results, summarize


class LongSummaryAnalysisTests(unittest.TestCase):
    def test_numeric_dates_are_not_split_into_separate_claims(self):
        self.assertEqual(claim_units("쟁점: 대법원 2026. 8. 24. 자 결정.\n1.\n다음 사실이다. 둘째."),
                         ["쟁점: 대법원 2026. 8. 24. 자 결정.", "1.", "다음 사실이다.", "둘째."])

    def fixture(self):
        source = "원심을 파기하고 환송한다."
        output = "결론: 파기하고 환송한다.\n포인트:"
        sample = {"documentID": "doc", "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(),
                  "input": {}, "searches": [], "prompt": source, "wrappedPrompt": source,
                  "rawOutput": output, "formatParsed": False,
                  "selectionMS": 10, "generationMS": 20, "totalMS": 30}
        hit = {"chunk": {"documentID": "doc", "documentFingerprint": sample["sourceSHA256"],
                         "startUTF16": 0, "endUTF16": len(source), "text": source},
               "score": 0.8, "keywordRank": None}
        samples, annotations = [], []
        for mode in MODES:
            current = copy.deepcopy(sample)
            current["mode"] = mode
            if mode != "fields":
                current["searches"] = [
                    {"requestedMode": mode, "effectiveMode": mode, "chunkCount": 1,
                     "semanticScoredChunkCount": 1, "semanticModelIdentity": {
                         "sha256": "1629184be879a108e16cceef62f7a0fedfff4eefb81cd734d646f8f404b85cdc"},
                     "hits": [copy.deepcopy(hit)]} for _ in range(3)]
            samples.append(current)
            annotations.append({
                "documentID": "doc", "mode": mode,
                "items": [{"id": "D1", "input": "full", "inputQuote": source, "output": "partial", "reason": "예비 검수",
                           "outputQuote": "파기하고 환송한다."}],
                "claims": [{"text": claim_units(output)[0], "status": "supported", "sourceQuote": source,
                            "inputSupported": True, "inputQuote": source, "reason": "원문 일치"},
                           {"text": "포인트:", "status": "non_substantive", "inputSupported": False, "reason": "빈 표제"}],
            })
        report = {"schemaVersion": 1, "configuration": {"environment": "simulator_not_device_evidence"},
                  "modelSHA256": LLAMA_SHA, "dataset": {"documents": [{"id": "doc", "text": source}]}, "samples": samples}
        gold = {"schemaVersion": 1, "reviewType": "AI provisional", "scoring": SCORES,
                "documents": [{"documentID": "doc", "alias": "D", "items": [
                    {"id": "D1", "category": "disposition", "fact": "파기 환송", "sourceQuote": source}]}]}
        review = {"schemaVersion": 1, "reviewType": "AI provisional", "samples": annotations}
        return report, gold, review

    def test_partial_coverage_and_non_substantive_headings(self):
        samples, items, claims = evaluate(*self.fixture())
        summary = summarize(samples)
        self.assertEqual(len(items), 4)
        self.assertEqual(len(claims), 8)
        self.assertTrue(summary["input_coverage"].eq(1).all())
        self.assertTrue(summary["output_coverage"].eq(0.5).all())
        self.assertTrue(summary["source_faithfulness"].eq(1).all())
        self.assertTrue(summary["disposition_preserved"].eq(0).all())

    def test_incomplete_duplicate_and_untraceable_reviews_are_rejected(self):
        for change in ("missing", "duplicate", "quote", "claim", "gold", "model", "timing", "external", "prompt"):
            report, gold, review = self.fixture()
            if change == "missing":
                report["samples"].pop()
            elif change == "duplicate":
                review["samples"].append(copy.deepcopy(review["samples"][0]))
            elif change == "quote":
                review["samples"][0]["items"][0]["outputQuote"] = "실제로 생성되지 않은 문장"
            elif change == "claim":
                review["samples"][0]["claims"].pop()
            elif change == "gold":
                gold["documents"][0]["items"][0]["sourceQuote"] = "없는 근거"
            elif change == "model":
                report["modelSHA256"] = "wrong"
            elif change == "timing":
                report["samples"][0]["selectionMS"] = float("nan")
            elif change == "prompt":
                report["samples"][0]["wrappedPrompt"] = "다른 실제 입력"
            else:
                report["samples"][1]["searches"][0]["hits"][0]["chunk"]["documentID"] = "other"
            with self.subTest(change=change), self.assertRaises(ValueError):
                evaluate(report, gold, review)

    def test_no_substantive_units_remains_undefined_not_perfect(self):
        report, gold, review = self.fixture()
        for sample, annotation in zip(report["samples"], review["samples"]):
            sample["rawOutput"] = "포인트:"
            annotation["items"][0].update(output="absent", outputQuote="")
            annotation["claims"] = [annotation["claims"][1]]
        samples, _, _ = evaluate(report, gold, review)
        summary = summarize(samples)
        self.assertTrue(summary["source_faithfulness"].isna().all())
        self.assertTrue(summary["substantive_units"].eq(0).all())

    def test_unsupported_claims_do_not_become_source_faithful(self):
        report, gold, review = self.fixture()
        for annotation in review["samples"]:
            annotation["claims"][0].update(status="unsupported", sourceQuote="", inputSupported=False, inputQuote="")
        samples, _, _ = evaluate(report, gold, review)
        summary = summarize(samples)
        self.assertTrue(summary["source_faithfulness"].eq(0).all())
        self.assertTrue(summary["unsupported_units"].eq(1).all())

    def test_four_figures_show_measured_coverage_and_all_modes(self):
        samples, _, _ = evaluate(*self.fixture())
        summary = summarize(samples)
        with patch("analyze_long_summaries.save_figure") as save:
            plot_results(samples, summary, Path("."))
        self.assertEqual(save.call_count, 4)
        bars = save.call_args_list[0].args[0].axes[0].patches
        self.assertEqual(len(bars), 8)
        self.assertEqual([bar.get_height() for bar in bars], [100] * 4 + [50] * 4)
        for call in save.call_args_list:
            plt.close(call.args[0])


if __name__ == "__main__":
    unittest.main()
