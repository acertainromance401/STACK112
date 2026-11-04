import copy
import hashlib
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import matplotlib.pyplot as plt

from analyze_controlled_summaries import SEEDS, compare, digest, evaluate, identical_groups, plot_results, validate_native


ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / "docs/research/long-summary-controlled-2026-11-04"


class ControlledSummaryAnalysisTests(unittest.TestCase):
    def fixture(self):
        manifest_bytes = (DIRECTORY / "raw/manifest.json").read_bytes()
        manifest = json.loads(manifest_bytes)
        manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
        gold = json.loads((ROOT / "docs/research/long-summary-evaluation-2026-11-03/gold.json").read_text())
        inputs = json.loads((DIRECTORY / "input_review.json").read_text())
        samples = []
        for round_index, seed in enumerate([None, None, *SEEDS]):
            for offset in range(8):
                c = manifest["conditions"][(offset + round_index) % 8]
                repetition = round_index + 1 if seed is None else 1
                suffix = f"greedy{repetition}" if seed is None else f"seed{seed}"
                samples.append({
                    "id": f"{c['id']}-{suffix}", "order": len(samples) + 1, "conditionID": c["id"],
                    "decoder": "greedy" if seed is None else "seeded", "seed": seed, "repetition": repetition,
                    "manifestSHA256": manifest_sha, "generationMS": 1000, "formatParsed": False,
                    "result": {"text": "포인트:", "originalPromptTokenCount": c["promptTokenCount"],
                               "promptTokenCount": c["promptTokenCount"], "generatedTokenCount": 4,
                               "contextTokens": 8192, "outputTokenLimit": 128, "samplerSeed": seed,
                               "stopReason": "end_of_generation"},
                })
        outputs = [{"promptSHA256": sha, "outputSHA256": digest("포인트:"),
                    "items": [{"id": f"C{i}", "status": "absent", "reason": "synthetic empty heading fixture"} for i in range(1, 7)],
                    "claims": [{"text": "포인트:", "status": "non_substantive", "inputSupported": False,
                                "reason": "synthetic heading"}]} for sha in dict.fromkeys(c["promptSHA256"] for c in manifest["conditions"])]
        review = {"schemaVersion": 1, "reviewType": inputs["reviewType"], "outputs": outputs}
        report = {"schemaVersion": 2, "manifest": manifest, "generationModelLoadMS": None, "samples": samples,
                  "executionStatus": {"nativeTestIntentionallyInterrupted": True,
                                      "requestedCompletedGenerations": 24, "completedAtStop": 24,
                                      "originalPlannedGenerations": 40}}
        return report, manifest, manifest_sha, gold, inputs, review

    def test_complete_grid_keeps_seeded_and_greedy_separate(self):
        samples, items, claims = evaluate(*self.fixture())
        summary, paired, paired_summary, greedy = compare(samples)
        self.assertEqual((len(samples), len(items), len(claims)), (24, 144, 24))
        self.assertTrue(summary.seeds.eq(1).all())
        self.assertTrue(summary.source_faithfulness.isna().all())
        self.assertEqual((len(paired), len(greedy)), (4, 8))
        self.assertTrue(greedy.identical_output.all())
        self.assertTrue(paired_summary.equal.eq(1).all())
        self.assertEqual(len(identical_groups(samples)), 2)

    def test_completed_reduced_native_runner_report_is_also_supported(self):
        args = list(self.fixture())
        args[0].update(schemaVersion=1, generationModelLoadMS=1000)
        del args[0]["executionStatus"]
        samples, _, _ = evaluate(*args)
        self.assertEqual(len(samples), 24)

    def test_native_rejects_seed_budget_clipping_grid_and_source_changes(self):
        for mutation in ("seed", "budget", "clipped", "missing", "duplicate", "source", "hash", "selection", "order", "stop"):
            report, manifest, sha, *_ = self.fixture()
            sample = report["samples"][0]
            if mutation == "seed":
                report["samples"][16]["result"]["samplerSeed"] = 43
            elif mutation == "budget":
                sample["result"]["outputTokenLimit"] = 96
            elif mutation == "clipped":
                sample["result"]["promptTokenCount"] -= 1
            elif mutation == "missing":
                report["samples"].pop()
            elif mutation == "duplicate":
                report["samples"][-1] = copy.deepcopy(sample)
            elif mutation == "source":
                manifest["sourceSHA256"] = "wrong"
            elif mutation == "hash":
                sample["manifestSHA256"] = "wrong"
            elif mutation == "selection":
                manifest["conditions"][1]["selectionMS"] += 1
            elif mutation == "order":
                sample["order"] = 2
            else:
                sample["result"]["stopReason"] = "token_limit"
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                validate_native(report, manifest, sha)

    def test_untraceable_missing_duplicate_and_unsupported_reviews_are_rejected(self):
        for mutation in ("input_quote", "output_quote", "missing_item", "missing_unit", "duplicate", "missing_output", "input_support"):
            args = list(self.fixture())
            output = args[-1]["outputs"][0]
            if mutation == "input_quote":
                args[-2]["inputs"][0]["items"][0]["quote"] = "not in prompt"
            elif mutation == "output_quote":
                output["items"][0].update(status="partial", quote="not generated")
            elif mutation == "missing_item":
                output["items"].pop()
            elif mutation == "missing_unit":
                output["claims"].pop()
            elif mutation == "duplicate":
                args[-1]["outputs"].append(copy.deepcopy(output))
            elif mutation == "missing_output":
                args[-1]["outputs"].pop()
            else:
                output["claims"][0].update(inputSupported=True, inputQuote="not in prompt")
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                evaluate(*args)

    def test_single_seed_has_no_variation_or_mean_estimate(self):
        samples, _, _ = evaluate(*self.fixture())
        samples.loc[samples.decoder.eq("seeded"), "output_coverage"] = 0.5
        summary, _, paired_summary, _ = compare(samples)
        self.assertTrue(summary.seed42_coverage.eq(0.5).all())
        self.assertNotIn("sd_coverage", summary.columns)
        self.assertNotIn("mean_coverage", summary.columns)
        self.assertNotIn("sd_delta", paired_summary.columns)

    def test_greedy_mismatch_is_a_result_not_silently_discarded(self):
        samples, _, _ = evaluate(*self.fixture())
        samples.loc[samples.sample_id.eq("capped-fields-greedy2"), "output_sha256"] = "different"
        _, _, _, greedy = compare(samples)
        self.assertEqual(int(greedy.identical_output.sum()), 7)

    def test_all_five_figures_include_both_policies(self):
        samples, _, _ = evaluate(*self.fixture())
        summary, paired, _, greedy = compare(samples)
        with patch("analyze_controlled_summaries.save_figure") as save:
            plot_results(samples, summary, paired, greedy, Path("."))
        self.assertEqual(save.call_count, 5)
        input_bars = save.call_args_list[0].args[0].axes[0].patches
        self.assertEqual(len(input_bars), 8)
        self.assertAlmostEqual(input_bars[0].get_height(), 100 / 6)
        self.assertAlmostEqual(input_bars[4].get_height(), 50)
        for call in save.call_args_list:
            plt.close(call.args[0])


if __name__ == "__main__":
    unittest.main()
