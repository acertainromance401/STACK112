#!/usr/bin/env python3
"""Verify and compare the saved three-output sentence-preservation pilot."""

import csv
import hashlib
import json
from pathlib import Path

from analyze_long_summaries import SCORES


ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / "docs/research/summary-preservation-pilot-2026-11-04"
BASELINE = ROOT / "docs/research/long-summary-controlled-2026-11-04"
MODES = ("keyword", "semantic", "hybrid")
ITEM_IDS = {f"C{i}" for i in range(1, 7)}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def coverage(items: list[dict[str, str]], text: str) -> float:
    require(len(items) == 6 and {item["id"] for item in items} == ITEM_IDS, "Incomplete C1-C6 review")
    for item in items:
        require(item["status"] in SCORES, f"Unknown item status: {item}")
        require(bool(item.get("reason")), f"Missing item rationale: {item}")
        if item["status"] in ("full", "partial"):
            require(bool(item.get("quote")) and item["quote"] in text, f"Unmatched review quote: {item}")
    return sum(SCORES[item["status"]] for item in items) / 6


def main() -> None:
    for filename in ("pre_generation_sha256.txt", "input_review_sha256.txt"):
        for line in (DIRECTORY / filename).read_text().splitlines():
            expected, relative = line.split(maxsplit=1)
            actual = hashlib.sha256((ROOT / relative.strip()).read_bytes()).hexdigest()
            require(actual == expected, f"Frozen source changed: {relative}")
    report = json.loads((DIRECTORY / "raw/report.json").read_text())
    manifest_path = DIRECTORY / "raw/manifest.json"
    manifest = json.loads(manifest_path.read_text())
    require(report["manifest"] == manifest, "Manifest/report mismatch")
    require(manifest["contextTokens"] == 8192 and manifest["outputTokens"] == 128 and manifest["seed"] == 42,
            "Unexpected native evaluation settings")
    source = manifest["document"]["text"]
    require(manifest["sourceSHA256"] == digest(source), "Source hash mismatch")
    old = json.loads((BASELINE / "raw/report.json").read_text())
    require(manifest["sourceSHA256"] == old["manifest"]["sourceSHA256"], "Baseline source differs")
    require(manifest["modelSHA256"] == old["manifest"]["modelSHA256"], "Baseline model differs")
    input_reviews = json.loads((DIRECTORY / "input_review.json").read_text())["inputs"]
    output_reviews = json.loads((DIRECTORY / "review.json").read_text())["outputs"]
    old_inputs = json.loads((BASELINE / "input_review.json").read_text())["inputs"]
    old_outputs = json.loads((BASELINE / "review.json").read_text())["outputs"]
    for group in (manifest["conditions"], report["samples"], input_reviews, output_reviews):
        require(len(group) == 3 and {item["mode"] for item in group} == set(MODES), "Incomplete mode grid")
    rows = []
    for order, mode in enumerate(MODES, 1):
        condition = next(item for item in manifest["conditions"] if item["mode"] == mode)
        sample = next(item for item in report["samples"] if item["mode"] == mode)
        reviewed_input = next(item for item in input_reviews if item["mode"] == mode)
        reviewed_output = next(item for item in output_reviews if item["mode"] == mode)
        require(sample["order"] == order and sample["id"] == f"{mode}-seed42", "Unexpected generation order")
        require(sample == json.loads((DIRECTORY / "raw" / f"{sample['id']}.json").read_text()), "Checkpoint mismatch")
        require(sample["manifestSHA256"] == hashlib.sha256(manifest_path.read_bytes()).hexdigest(), "Manifest digest mismatch")
        require(condition["promptSHA256"] == digest(condition["wrappedPrompt"]) == reviewed_input["promptSHA256"],
                "Prompt digest mismatch")
        result = sample["result"]
        require(result["samplerSeed"] == 42, "Wrong actual sampler seed")
        require(result["promptTokenCount"] == result["originalPromptTokenCount"] == condition["promptTokenCount"],
                "Input token clipping or count mismatch")
        require(result["contextTokens"] == 8192 and result["outputTokenLimit"] == 128, "Unexpected output budget")
        require(0 < result["generatedTokenCount"] <= 128 and result["promptTokenCount"] <= 1536, "Token budget exceeded")
        require(result["stopReason"] in ("end_of_generation", "token_limit"), "Unknown termination")
        require(reviewed_output["outputSHA256"] == digest(result["text"]), "Output review digest mismatch")
        line_numbers = {i for i, line in enumerate(result["text"].splitlines(), 1) if line.strip()}
        require(len(reviewed_output["units"]) == len(line_numbers)
                and {unit["line"] for unit in reviewed_output["units"]} == line_numbers, "Unreviewed output line")
        plan = condition["plan"]
        require(plan["mode"] == mode, "Plan mode mismatch")
        require([item["role"] for item in plan["evidence"]] == ["principle", "facts", "reasoning", "disposition"],
                "Incomplete evidence roles")
        for item in plan["evidence"]:
            chunk = item["chunk"]
            require(chunk["documentFingerprint"] == manifest["sourceSHA256"], "Evidence source mismatch")
            start, end = chunk["startUTF16"], chunk["endUTF16"]
            require(0 <= start < end <= len(source.encode("utf-16-le")) // 2, "Invalid source range")
            restored = source.encode("utf-16-le")[start * 2:end * 2].decode("utf-16-le")
            require(restored == chunk["text"] and chunk["text"] in condition["prompt"], "Evidence text mismatch")
        for search in plan["searches"]:
            value = search["result"]
            require(value["requestedMode"] == value["effectiveMode"] == mode and not value["warnings"], "Search fallback")
            if mode != "keyword":
                require(value["semanticScoredChunkCount"] == value["chunkCount"], "Incomplete semantic scoring")
        new_input = coverage(reviewed_input["items"], condition["prompt"])
        new_output = coverage(reviewed_output["items"], result["text"])
        for policy in ("capped", "uncapped"):
            condition_id = f"{policy}-{mode}"
            old_condition = next(item for item in old["manifest"]["conditions"] if item["id"] == condition_id)
            old_sample = next(item for item in old["samples"]
                              if item["conditionID"] == condition_id and item["decoder"] == "seeded")
            old_input = next(item for item in old_inputs if item["promptSHA256"] == old_condition["promptSHA256"])
            old_output = next(item for item in old_outputs
                              if item["promptSHA256"] == old_condition["promptSHA256"]
                              and item["outputSHA256"] == digest(old_sample["result"]["text"]))
            rows.append({
                "mode": mode, "baseline_policy": policy,
                "baseline_input_coverage": coverage(old_input["items"], old_condition["prompt"]),
                "improved_input_coverage": new_input,
                "baseline_output_coverage": coverage(old_output["items"], old_sample["result"]["text"]),
                "improved_output_coverage": new_output,
                "baseline_prompt_tokens": old_sample["result"]["promptTokenCount"],
                "improved_prompt_tokens": result["promptTokenCount"],
                "baseline_generation_seconds": old_sample["generationMS"] / 1000,
                "improved_generation_seconds": sample["generationMS"] / 1000,
                "improved_generated_tokens": result["generatedTokenCount"],
                "improved_stop_reason": result["stopReason"],
                "new_prompt_equals_baseline": condition["wrappedPrompt"] == old_condition["wrappedPrompt"],
            })
    with (DIRECTORY / "comparison.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    metadata = {
        "schemaVersion": 1, "completedOutputs": 3, "rows": rows,
        "generationSeconds": sum(item["generationMS"] for item in report["samples"]) / 1000,
        "generationModelLoadSeconds": manifest["generationModelLoadMS"] / 1000,
        "newPromptsIdentical": len({item["promptSHA256"] for item in manifest["conditions"]}) == 1,
        "reportSHA256": hashlib.sha256((DIRECTORY / "raw/report.json").read_bytes()).hexdigest(),
        "reviewSHA256": hashlib.sha256((DIRECTORY / "review.json").read_bytes()).hexdigest(),
        "analyzerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "limitations": [
            "One previously observed judgment and one fixed seed; exploratory development, not held-out evaluation.",
            "Evidence selection and prompt changed together; no individual-change causal attribution.",
            "Four output labels differ from the earlier template; no direct parser-pass comparison.",
            "Shared E5 provider makes selection latencies cache-dependent and non-independent.",
        ],
    }
    (DIRECTORY / "analysis_summary.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    for row in rows:
        print(f"{row['mode']:8s} {row['baseline_policy']:8s} "
              f"input {row['baseline_input_coverage']:.1%} -> {row['improved_input_coverage']:.1%}; "
              f"output {row['baseline_output_coverage']:.1%} -> {row['improved_output_coverage']:.1%}")
    print("Verified 3 outputs, original ranges, fixed seeds, review quotes and frozen hashes.")


if __name__ == "__main__":
    main()
