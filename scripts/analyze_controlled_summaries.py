#!/usr/bin/env python3
"""Audit the case-C paired-policy experiment without pooling decoder regimes."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from analyze_legal_case_pilot import save_figure
from analyze_long_summaries import E5_SHA, LLAMA_SHA, MODES, SCORES, claim_units


POLICIES = ["capped", "uncapped"]
MODE_LABELS = ["F: fields", "K: keyword", "S: E5-only", "H: hybrid"]
SEEDS = [42]
COLORS = ["#8ba6c6", "#249d8c"]


def digest(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def positive_int(value: object) -> bool:
    return type(value) is int and value > 0


def valid_time(value: object) -> bool:
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def verify_hashes(root: Path, directory: Path) -> None:
    amendment = json.loads((directory / "scope_amendment.json").read_text())
    snapshots = amendment["sourceSnapshots"]
    require(snapshots == {"code/ios/AISYSAppTests/ControlledSummaryEvaluationTests.swift":
                          "measured/ControlledSummaryEvaluationTests.swift"}, "Unexpected measured-source mapping")
    for name in ("pre_generation_sha256.txt", "frozen_source_sha256.txt", "input_review_sha256.txt",
                 "scope_amendment_sha256.txt", "post_amendment_source_sha256.txt"):
        for line in (directory / name).read_text().splitlines():
            expected, relative = line.split(maxsplit=1)
            measured = directory / snapshots[relative] if name == "frozen_source_sha256.txt" and relative in snapshots else root / relative
            actual = hashlib.sha256(measured.read_bytes()).hexdigest()
            require(actual == expected, f"Frozen file changed: {relative}")


def validate_native(report: dict, manifest: dict, manifest_sha: str) -> dict:
    require(manifest["schemaVersion"] == 1, "Unsupported preflight schema")
    if report["schemaVersion"] == 2:
        status = report["executionStatus"]
        require(status["nativeTestIntentionallyInterrupted"] is True
                and status["requestedCompletedGenerations"] == status["completedAtStop"] == 24
                and status["originalPlannedGenerations"] == 40, "Unexpected scope/interruption record")
        require(report["generationModelLoadMS"] is None, "Interrupted run model-load time was not exported")
    elif report["schemaVersion"] == 1:
        require(valid_time(report["generationModelLoadMS"]), "Invalid native model-load time")
    else:
        raise ValueError("Unsupported native/assembled report schema")
    require(report["manifest"] == manifest, "Report/preflight mismatch")
    require(manifest["environment"] == "simulator_not_device_evidence", "Unexpected environment")
    require(manifest["modelSHA256"] == LLAMA_SHA, "Unexpected generator")
    source = manifest["document"]["text"]
    require(manifest["document"]["id"] == "sc-2026eu552", "Only judgment C is approved")
    require(manifest["sourceSHA256"] == digest(source), "Wrong source fingerprint")
    require(manifest["contextTokens"] == 8192 and manifest["outputTokens"] == 128, "Budget changed")
    require(manifest["facetQueries"] == ["핵심 쟁점 판시사항", "판단 이유 법리 원칙 예외", "주문 결론 파기 환송 기각"],
            "Facet queries changed")
    conditions = {c["id"]: c for c in manifest["conditions"]}
    expected_conditions = {f"{p}-{m}" for p in POLICIES for m in MODES}
    require(len(manifest["conditions"]) == 8 and set(conditions) == expected_conditions, "Incomplete condition grid")
    for key, c in conditions.items():
        require(key == f'{c["policy"]}-{c["mode"]}', "Condition ID mismatch")
        require(c["prompt"] and c["prompt"] in c["wrappedPrompt"], f"Wrong wrapped input: {key}")
        require(c["promptSHA256"] == digest(c["wrappedPrompt"]), f"Prompt hash mismatch: {key}")
        require(positive_int(c["promptTokenCount"]) and c["promptTokenCount"] + 136 <= 8192, f"Input overflow: {key}")
        require(valid_time(c["selectionMS"]), f"Invalid selection time: {key}")
        require(c["input"]["id"] == manifest["document"]["id"], f"Wrong input document: {key}")
        if c["policy"] == "uncapped":
            for field in ("caseName", "issueSummary", "holdingSummary", "examPoints"):
                require(not c["input"].get(field) or c["input"][field] in c["prompt"], f"Uncapped field clipped: {key}")
        searches = c["searches"]
        require(len(searches) == (0 if c["mode"] == "fields" else 3), f"Wrong searches: {key}")
        for search in searches:
            require(search["requestedMode"] == search["effectiveMode"] == c["mode"], f"Search fallback: {key}")
            require(not search["warnings"] and bool(search["hits"]), f"Search warning/empty: {key}")
            if c["mode"] in ("semantic", "hybrid"):
                require(search["semanticModelIdentity"]["sha256"] == E5_SHA
                        and search["semanticScoredChunkCount"] == search["chunkCount"], f"Incomplete/wrong E5: {key}")
            for hit in search["hits"]:
                chunk = hit["chunk"]
                start, end = chunk["startUTF16"], chunk["endUTF16"]
                encoded = source.encode("utf-16-le")
                require(chunk["documentID"] == manifest["document"]["id"]
                        and chunk["documentFingerprint"] == manifest["sourceSHA256"]
                        and 0 <= start < end <= len(encoded) // 2, f"External/invalid evidence: {key}")
                require(encoded[2 * start:2 * end].decode("utf-16-le") == chunk["text"], f"Nonoriginal chunk: {key}")
                if c["mode"] == "semantic":
                    require(hit.get("keywordRank") is None and 0.30 < hit["score"] <= 1.00001, f"Impure E5-only: {key}")
    for mode in MODES:
        left, right = conditions[f"capped-{mode}"], conditions[f"uncapped-{mode}"]
        require(left["input"] == right["input"] and left["searches"] == right["searches"]
                and left["selectionMS"] == right["selectionMS"], f"Unpaired selection: {mode}")
    require(len(report["samples"]) == 24, "Exactly 24 completed generations are required")
    expected_grid = {(c, "greedy", None, r) for c in conditions for r in (1, 2)}
    expected_grid |= {(c, "seeded", seed, 1) for c in conditions for seed in SEEDS}
    seen, ids = set(), set()
    ordered_conditions = manifest["conditions"]
    for order, s in enumerate(report["samples"], 1):
        require(s["id"] not in ids, "Duplicate output ID")
        ids.add(s["id"])
        key = (s["conditionID"], s["decoder"], s.get("seed"), s["repetition"])
        require(key in expected_grid and key not in seen, f"Duplicate/unexpected generation: {key}")
        seen.add(key)
        round_index, offset = divmod(order - 1, 8)
        expected_condition = ordered_conditions[(offset + round_index) % 8]["id"]
        expected_seed = [None, None, *SEEDS][round_index]
        require(s["order"] == order and s["conditionID"] == expected_condition
                and s.get("seed") == expected_seed
                and s["repetition"] == (round_index + 1 if round_index < 2 else 1), "Run order/seed changed")
        suffix = f"seed{s['seed']}" if s["decoder"] == "seeded" else f"greedy{s['repetition']}"
        require(s["id"] == f"{s['conditionID']}-{suffix}", "Output ID changed")
        require(s["manifestSHA256"] == manifest_sha, "Unfrozen delivered prompt")
        require(valid_time(s["generationMS"]) and type(s["formatParsed"]) is bool, "Invalid native measurement")
        result, c = s["result"], conditions[s["conditionID"]]
        require(result["text"].strip(), "Empty generation")
        require(result["originalPromptTokenCount"] == result["promptTokenCount"] == c["promptTokenCount"],
                "Input tokens silently clipped")
        require(result["contextTokens"] == 8192 and result["outputTokenLimit"] == 128, "Unequal generation budget")
        require(positive_int(result["generatedTokenCount"]) and result["generatedTokenCount"] <= 128, "Invalid output tokens")
        require(result.get("samplerSeed") == s.get("seed"), "Actual sampler seed differs")
        require(result["stopReason"] in ("end_of_generation", "token_limit"), "Unknown stop reason")
        require(result["stopReason"] != "token_limit" or result["generatedTokenCount"] == 128, "Wrong token-limit trace")
    require(seen == expected_grid, "Missing generation conditions")
    return conditions


def checked_items(items: list, reference: dict, text: str, is_input: bool) -> dict:
    indexed = {item["id"]: item for item in items}
    require(len(items) == len(indexed) == 6 and set(indexed) == set(reference), "Incomplete item review")
    for item in indexed.values():
        require(item["status"] in SCORES and (not is_input or item["status"] != "contradicted"),
                "Invalid item judgment")
        require(item["reason"].strip(), "Item judgment needs a reason")
        if item["status"] != "absent":
            require(item.get("quote") and item["quote"] in text, "Untraceable item quote")
    return indexed


def evaluate(report: dict, manifest: dict, manifest_sha: str, gold: dict,
             input_review: dict, output_review: dict) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    conditions = validate_native(report, manifest, manifest_sha)
    require(gold["schemaVersion"] == input_review["schemaVersion"] == output_review["schemaVersion"] == 1,
            "Unsupported review schema")
    require(gold["reviewType"] == input_review["reviewType"] == output_review["reviewType"]
            and gold["scoring"] == SCORES, "Review/rubric provenance changed")
    reference_doc = next(d for d in gold["documents"] if d["documentID"] == manifest["document"]["id"])
    reference = {i["id"]: i for i in reference_doc["items"]}
    require(set(reference) == {f"C{i}" for i in range(1, 7)}, "Wrong reference items")
    source = manifest["document"]["text"]
    require(all(i["sourceQuote"] and i["sourceQuote"] in source for i in reference.values()), "Ungrounded gold")
    inputs = {i["promptSHA256"]: i for i in input_review["inputs"]}
    require(len(inputs) == len(input_review["inputs"]) and set(inputs) == {c["promptSHA256"] for c in conditions.values()},
            "Incomplete/duplicate input reviews")
    input_items = {}
    for sha, annotation in inputs.items():
        members = [c for c in conditions.values() if c["promptSHA256"] == sha]
        require(set(annotation["conditionIDs"]) == {c["id"] for c in members}, "Wrong identical-input group")
        input_items[sha] = checked_items(annotation["items"], reference, members[0]["prompt"], True)
    outputs = {(r["promptSHA256"], r["outputSHA256"]): r for r in output_review["outputs"]}
    expected_outputs = {(conditions[s["conditionID"]]["promptSHA256"], digest(s["result"]["text"])) for s in report["samples"]}
    require(len(outputs) == len(output_review["outputs"]) and set(outputs) == expected_outputs, "Incomplete/duplicate output reviews")
    rows, item_rows, claim_rows = [], [], []
    for s in report["samples"]:
        c, result = conditions[s["conditionID"]], s["result"]
        output_sha = digest(result["text"])
        annotation = outputs[(c["promptSHA256"], output_sha)]
        reviewed = checked_items(annotation["items"], reference, result["text"], False)
        delivered = input_items[c["promptSHA256"]]
        for item_id, item in reviewed.items():
            item_rows.append({"sample_id": s["id"], "policy": c["policy"], "mode": c["mode"],
                              "decoder": s["decoder"], "seed": s.get("seed"), "item_id": item_id,
                              "input_status": delivered[item_id]["status"], "output_status": item["status"],
                              "input_score": SCORES[delivered[item_id]["status"]], "output_score": SCORES[item["status"]],
                              "input_quote": delivered[item_id].get("quote", ""), "output_quote": item.get("quote", ""),
                              "reason": item["reason"], "source_quote": reference[item_id]["sourceQuote"]})
        claims = annotation["claims"]
        require([i["text"] for i in claims] == claim_units(result["text"]), f"Incomplete output units: {s['id']}")
        for index, claim in enumerate(claims, 1):
            status = claim["status"]
            require(status in ("supported", "unsupported", "contradicted", "non_substantive")
                    and claim["reason"].strip() and type(claim["inputSupported"]) is bool, "Invalid claim judgment")
            if status in ("supported", "contradicted"):
                require(claim.get("sourceQuote") and claim["sourceQuote"] in source, "Ungrounded output claim")
            if claim["inputSupported"]:
                require(status == "supported" and claim.get("inputQuote") and claim["inputQuote"] in c["prompt"],
                        "Untraceable/contradicted input support")
            require(status != "non_substantive" or not claim["inputSupported"], "Heading counted as input support")
            claim_rows.append({"sample_id": s["id"], "unit": index, **claim})
        substantive = [i for i in claims if i["status"] != "non_substantive"]
        supported = sum(i["status"] == "supported" for i in substantive)
        input_supported = sum(i["inputSupported"] for i in substantive)
        rows.append({
            "sample_id": s["id"], "order": s["order"], "condition_id": c["id"],
            "policy": c["policy"], "mode": c["mode"], "decoder": s["decoder"],
            "seed": s.get("seed"), "repetition": s["repetition"],
            "prompt_sha256": c["promptSHA256"], "output_sha256": output_sha,
            "input_coverage": sum(SCORES[i["status"]] for i in delivered.values()) / 6,
            "output_coverage": sum(SCORES[i["status"]] for i in reviewed.values()) / 6,
            "full_items": sum(i["status"] == "full" for i in reviewed.values()),
            "partial_items": sum(i["status"] == "partial" for i in reviewed.values()),
            "contradicted_items": sum(i["status"] == "contradicted" for i in reviewed.values()),
            "disposition_preserved": reviewed["C6"]["status"] == "full",
            "substantive_units": len(substantive), "source_supported_units": supported,
            "input_supported_units": input_supported, "non_substantive_units": len(claims) - len(substantive),
            "unsupported_units": sum(i["status"] == "unsupported" for i in substantive),
            "contradicted_units": sum(i["status"] == "contradicted" for i in substantive),
            "source_faithfulness": supported / len(substantive) if substantive else None,
            "input_faithfulness": input_supported / len(substantive) if substantive else None,
            "prompt_tokens": result["promptTokenCount"], "generated_tokens": result["generatedTokenCount"],
            "stop_reason": result["stopReason"], "format_parsed": s["formatParsed"],
            "generation_seconds": s["generationMS"] / 1000, "selection_seconds": c["selectionMS"] / 1000,
        })
    return pd.DataFrame(rows), pd.DataFrame(item_rows), pd.DataFrame(claim_rows)


def compare(samples: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    seeded = samples[samples.decoder.eq("seeded")]
    summary = seeded.groupby(["policy", "mode"], sort=False).agg(
        seeds=("seed", "count"), input_coverage=("input_coverage", "first"),
        seed42_coverage=("output_coverage", "first"),
        full_items=("full_items", "sum"), partial_items=("partial_items", "sum"),
        contradicted_items=("contradicted_items", "sum"), dispositions=("disposition_preserved", "sum"),
        formats=("format_parsed", "sum"), prompt_tokens=("prompt_tokens", "first"),
        generated_tokens=("generated_tokens", "first"), generation_seconds=("generation_seconds", "first"),
        substantive_units=("substantive_units", "sum"), source_supported_units=("source_supported_units", "sum"),
        unsupported_units=("unsupported_units", "sum"), contradicted_units=("contradicted_units", "sum"),
    ).reset_index()
    summary["source_faithfulness"] = summary.source_supported_units / summary.substantive_units.where(summary.substantive_units.gt(0))
    require(summary.seeds.eq(1).all(), "One fixed seed per condition is required")
    paired = seeded[seeded.policy.eq("capped")].merge(seeded[seeded.policy.eq("uncapped")], on=["mode", "seed"],
                                                     suffixes=("_capped", "_uncapped"), validate="one_to_one")
    paired["coverage_delta"] = paired.output_coverage_uncapped - paired.output_coverage_capped
    paired["generation_seconds_delta"] = paired.generation_seconds_uncapped - paired.generation_seconds_capped
    paired_summary = paired.groupby("mode", sort=False).agg(
        pairs=("seed", "count"), coverage_delta=("coverage_delta", "first"),
        better=("coverage_delta", lambda x: int(x.gt(0).sum())),
        equal=("coverage_delta", lambda x: int(x.eq(0).sum())),
        worse=("coverage_delta", lambda x: int(x.lt(0).sum())),
    ).reset_index()
    greedy_rows = []
    for condition, group in samples[samples.decoder.eq("greedy")].groupby("condition_id", sort=False):
        require(len(group) == 2 and group.prompt_sha256.nunique() == 1, "Greedy diagnosis needs an identical-input pair")
        greedy_rows.append({"condition_id": condition, "policy": group.policy.iloc[0], "mode": group["mode"].iloc[0],
                            "repetitions": 2, "identical_output": group.output_sha256.nunique() == 1,
                            "coverage_first": group.sort_values("repetition").output_coverage.iloc[0],
                            "coverage_second": group.sort_values("repetition").output_coverage.iloc[1]})
    return summary, paired, paired_summary, pd.DataFrame(greedy_rows)


def identical_groups(samples: pd.DataFrame) -> list[dict]:
    groups = []
    for prompt_sha, group in samples.groupby("prompt_sha256", sort=False):
        conditions = sorted(group.condition_id.unique())
        if len(conditions) < 2:
            continue
        comparisons = []
        for (decoder, seed, repetition), matched in group.groupby(["decoder", "seed", "repetition"], dropna=False):
            comparisons.append({"decoder": decoder, "seed": None if pd.isna(seed) else int(seed),
                                "repetition": int(repetition), "outputs": len(matched),
                                "identical_output": matched.output_sha256.nunique() == 1})
        groups.append({"promptSHA256": prompt_sha, "conditions": conditions, "comparisons": comparisons})
    return groups


def plot_results(samples: pd.DataFrame, summary: pd.DataFrame, paired: pd.DataFrame,
                 greedy: pd.DataFrame, output: Path) -> None:
    plt.rcParams.update({"font.family": "DejaVu Sans", "svg.fonttype": "path", "font.size": 12})
    positions = list(range(4))
    footnote = "One judgment; six frozen items; one fixed seed (42). AI provisional review, not expert legal accuracy."
    fig, axes = plt.subplots(1, 2, figsize=(16, 7))
    for policy, offset, color in zip(POLICIES, [-0.19, 0.19], COLORS):
        frame = summary[summary.policy.eq(policy)].set_index("mode").reindex(MODES)
        for ax, column, title in zip(axes, ["input_coverage", "seed42_coverage"], ["Delivered input", "Generated summary at seed 42"]):
            values = frame[column] * 100
            bars = ax.bar([p + offset for p in positions], values, width=0.36, label=policy, color=color)
            ax.bar_label(bars, fmt="%.1f", padding=8)
            ax.set(xticks=positions, xticklabels=MODE_LABELS, ylim=(0, 115), ylabel="Core-item coverage (%)", title=title)
            ax.legend(loc="upper right")
    fig.suptitle("Removing field caps: evidence gained vs information summarized", weight="bold")
    fig.text(0.06, 0.015, footnote + " No multi-seed variation estimate.", fontsize=10)
    fig.tight_layout(rect=(0, 0.05, 1, 0.95))
    save_figure(fig, output, "01-input-output-coverage")

    labels = [f"{p} / {label}" for p in POLICIES for label in MODE_LABELS]
    condition_order = [f"{p}-{m}" for p in POLICIES for m in MODES]
    diagnosis = greedy.set_index("condition_id").reindex(condition_order)
    heatmap = samples[samples.decoder.eq("seeded")].pivot(index="condition_id", columns="seed", values="output_coverage").reindex(condition_order)
    fig, axes = plt.subplots(1, 2, figsize=(16, 8))
    bars = axes[0].barh(range(8), diagnosis.identical_output.astype(int), color=["#249d8c" if b else "#cc6861" for b in diagnosis.identical_output])
    axes[0].bar_label(bars, labels=["MATCH" if b else "DIFFERENT" for b in diagnosis.identical_output], padding=8)
    axes[0].set(yticks=range(8), yticklabels=labels, xlim=(0, 1.45), xticks=[0, 1], title="Greedy: exact output equality, two repetitions")
    axes[0].invert_yaxis()
    image = axes[1].imshow(heatmap * 100, vmin=0, vmax=100, cmap="YlGnBu", aspect="auto")
    for row in range(8):
        for col in range(len(SEEDS)):
            value = heatmap.iloc[row, col] * 100
            axes[1].text(col, row, f"{value:.1f}", ha="center", va="center", color="white" if value >= 55 else "#18243b")
    axes[1].set(xticks=range(len(SEEDS)), xticklabels=[f"seed {s}" for s in SEEDS], yticks=range(8), yticklabels=labels,
                title="Coverage (%) at one fixed seed")
    fig.colorbar(image, ax=axes[1], label="Core-item coverage (%)", shrink=0.8)
    fig.text(0.06, 0.015, footnote + " K/H inputs are identical within each policy.", fontsize=10)
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    save_figure(fig, output, "02-greedy-and-fixed-seed")

    fig, ax = plt.subplots(figsize=(13, 7))
    ax.axhline(0, color="#65758b", linewidth=1.5)
    for seed, offset, color in zip(SEEDS, [0], ["#3b6ea8"]):
        values = paired[paired.seed.eq(seed)].set_index("mode").reindex(MODES).coverage_delta * 100
        ax.scatter([p + offset for p in positions], values, s=100, label=f"seed {seed}", color=color)
        for position, value in zip(positions, values):
            ax.annotate(f"{value:+.1f}", (position + offset, value), xytext=(0, 10), textcoords="offset points", ha="center")
    ax.set(xticks=positions, xticklabels=MODE_LABELS, ylabel="Uncapped - capped coverage (percentage points)",
           title="Paired policy effect: same evidence selector and same seed")
    ax.set_ylim(-105, 105)
    ax.legend(loc="upper right")
    fig.text(0.08, 0.02, footnote + " Positive = uncapped improved; no statistical-significance claim.", fontsize=10)
    fig.tight_layout(rect=(0, 0.06, 1, 1))
    save_figure(fig, output, "03-paired-policy-differences")

    fig, axes = plt.subplots(1, 2, figsize=(16, 7))
    for policy, offset, color in zip(POLICIES, [-0.19, 0.19], COLORS):
        frame = summary[summary.policy.eq(policy)].set_index("mode").reindex(MODES)
        for ax, column, title in zip(axes, ["prompt_tokens", "generation_seconds"], ["Actual delivered prompt tokens", "Generation time at seed 42"]):
            bars = ax.bar([p + offset for p in positions], frame[column], width=0.36, label=policy, color=color)
            ax.bar_label(bars, fmt="%.0f", padding=5)
            ax.set(xticks=positions, xticklabels=MODE_LABELS, title=title)
            ax.margins(y=0.20)
            ax.legend()
    axes[0].set_ylabel("Tokens; no silent prompt clipping")
    axes[1].set_ylabel("Seconds (simulator, not device latency)")
    fig.text(0.05, 0.015, "Common context: 8,192; output allowance: 128 tokens. Selection was run once per mode; no repeated-seed timing estimate.", fontsize=10)
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    save_figure(fig, output, "04-token-and-time-cost")

    frame = summary.set_index(["policy", "mode"]).reindex(pd.MultiIndex.from_product([POLICIES, MODES]))
    fig, axes = plt.subplots(1, 2, figsize=(17, 8))
    left = [0] * 8
    for column, label, color in [("source_supported_units", "Source-supported", "#249d8c"),
                                 ("unsupported_units", "Unsupported", "#cf8b30"), ("contradicted_units", "Contradicted", "#cc6861")]:
        values = frame[column].tolist()
        axes[0].barh(range(8), values, left=left, label=label, color=color)
        left = [a + b for a, b in zip(left, values)]
    axes[0].set(yticks=range(8), yticklabels=labels, xlabel="Substantive units in one seed-42 output", title="Output-unit faithfulness to the full source")
    axes[0].invert_yaxis()
    axes[0].legend(loc="lower right", fontsize=10)
    matrix = frame[["formats", "dispositions", "contradicted_items"]].to_numpy()
    image = axes[1].imshow(matrix, cmap="Blues", aspect="auto", vmin=0, vmax=max(1, matrix.max()))
    for row in range(8):
        for col in range(3):
            axes[1].text(col, row, str(int(matrix[row, col])), ha="center", va="center")
    axes[1].set(xticks=range(3), xticklabels=["Format pass /1", "Disposition /1", "Contradicted items"],
                yticks=range(8), yticklabels=labels, title="Format, disposition and core-item errors")
    fig.text(0.04, 0.015, "Headings excluded from faithfulness. Contradicted units can include malformed identifiers; not all are legal polarity reversals.", fontsize=10)
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    save_figure(fig, output, "05-faithfulness-errors")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path("docs/research/long-summary-controlled-2026-11-04"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    directory = args.directory.resolve()
    verify_hashes(root, directory)
    load = lambda path: json.loads(path.read_text())
    manifest_path = directory / "raw/manifest.json"
    manifest, report = load(manifest_path), load(directory / "raw/report.json")
    if report["schemaVersion"] == 2:
        require(load(directory / "execution_status.json") == report["executionStatus"], "Interruption records differ")
    manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    for sample in report["samples"]:
        require(load(directory / "raw" / f"{sample['id']}.json") == sample, "Checkpoint/report mismatch")
    gold = load(root / "docs/research/long-summary-evaluation-2026-11-03/gold.json")
    samples, items, claims = evaluate(report, manifest, manifest_sha, gold, load(directory / "input_review.json"),
                                     load(directory / "review.json"))
    summary, paired, paired_summary, greedy = compare(samples)
    for name, frame in [("samples", samples), ("items", items), ("claims", claims), ("seed_summary", summary),
                        ("paired_seeds", paired), ("paired_summary", paired_summary), ("greedy_reproducibility", greedy)]:
        frame.to_csv(directory / f"{name}.csv", index=False)
    analysis = {
        "schemaVersion": 2, "scope": "one judgment, 24 completed generations; AI provisional, not expert accuracy",
        "multiSeedVarianceEvaluated": False, "fixedSeeds": SEEDS,
        "python": sys.version.split()[0], "pandas": pd.__version__, "matplotlib": matplotlib.__version__,
        "manifestSHA256": manifest_sha, "analyzerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "helperSHA256": {name: hashlib.sha256((root / "scripts" / name).read_bytes()).hexdigest()
                         for name in ("analyze_long_summaries.py", "analyze_legal_case_pilot.py")},
        "inputReviewSHA256": hashlib.sha256((directory / "input_review.json").read_bytes()).hexdigest(),
        "outputReviewSHA256": hashlib.sha256((directory / "review.json").read_bytes()).hexdigest(),
        "summary": json.loads(summary.to_json(orient="records")),
        "paired": json.loads(paired_summary.to_json(orient="records")),
        "greedyPairs": len(greedy), "greedyIdenticalPairs": int(greedy.identical_output.sum()),
        "identicalPromptGroups": identical_groups(samples),
        "strictFormatPasses": int(samples.format_parsed.sum()),
        "tokenLimitStops": int(samples.stop_reason.eq("token_limit").sum()),
    }
    (directory / "analysis_summary.json").write_text(json.dumps(analysis, ensure_ascii=False, indent=2) + "\n")
    plot_results(samples, summary, paired, greedy, directory)
    print(summary.to_string(index=False))
    print("\nPaired seed differences:\n" + paired_summary.to_string(index=False))
    print(f"\nGreedy exact matches: {analysis['greedyIdenticalPairs']}/{len(greedy)}; samples={len(samples)}, items={len(items)}, units={len(claims)}")


if __name__ == "__main__":
    main()
