#!/usr/bin/env python3
"""Audit source-bounded summary reviews and plot the native four-mode pilot."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from analyze_legal_case_pilot import save_figure


MODES = ["fields", "keyword", "semantic", "hybrid"]
LABELS = ["F: current fields", "K: keyword", "S: E5-only", "H: hybrid"]
COLORS = ["#65758b", "#3b6ea8", "#cf8b30", "#249d8c"]
SCORES = {"full": 1.0, "partial": 0.5, "absent": 0.0, "contradicted": 0.0}
LLAMA_SHA = "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83"
E5_SHA = "1629184be879a108e16cceef62f7a0fedfff4eefb81cd734d646f8f404b85cdc"


def claim_units(output: str) -> list[str]:
    """Keep every nonempty output unit; headings are explicitly reviewed too."""
    return [part.strip() for part in re.split(r"\n|(?<=[!?。])\s+|(?<=[^\d]\.)\s+", output) if part.strip()]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evaluate(report: dict, gold: dict, review: dict) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    if report["schemaVersion"] != 1 or report["configuration"]["environment"] != "simulator_not_device_evidence":
        raise ValueError("Unsupported native schema/environment")
    if report["modelSHA256"] != LLAMA_SHA:
        raise ValueError("Unexpected generation model")
    if gold["schemaVersion"] != 1 or review["schemaVersion"] != 1 or gold["scoring"] != SCORES:
        raise ValueError("Unsupported review rubric")
    if review["reviewType"] != gold["reviewType"]:
        raise ValueError("Review provenance mismatch")
    documents = {doc["id"]: doc for doc in report["dataset"]["documents"]}
    references = {doc["documentID"]: doc for doc in gold["documents"]}
    if (len(documents) != len(report["dataset"]["documents"]) or len(references) != len(gold["documents"])
            or set(documents) != set(references)):
        raise ValueError("Duplicate or mismatched sources")
    annotations = {(item["documentID"], item["mode"]): item for item in review["samples"]}
    expected = {(doc, mode) for doc in documents for mode in MODES}
    if len(annotations) != len(review["samples"]) or set(annotations) != expected:
        raise ValueError("Review must cover each unique document/mode cell")
    seen, rows, item_rows, claim_rows = set(), [], [], []
    for sample in report["samples"]:
        key = (sample["documentID"], sample["mode"])
        if key in seen or key not in expected:
            raise ValueError(f"Duplicate/unknown native cell: {key}")
        seen.add(key)
        document, reference = documents[key[0]], references[key[0]]
        source = document["text"]
        if not sample["prompt"] or sample["prompt"] not in sample["wrappedPrompt"]:
            raise ValueError(f"Reviewed prompt differs from delivered chat input: {key}")
        if sample["sourceSHA256"] != hashlib.sha256(source.encode()).hexdigest():
            raise ValueError(f"Source fingerprint mismatch: {key}")
        for field in ("selectionMS", "generationMS", "totalMS"):
            value = sample[field]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                raise ValueError(f"Invalid native timing: {key}, {field}")
        if sample["totalMS"] + 1 < sample["selectionMS"] + sample["generationMS"]:
            raise ValueError(f"Inconsistent total time: {key}")
        searches = sample["searches"]
        if len(searches) != (0 if key[1] == "fields" else 3):
            raise ValueError(f"Wrong facet count: {key}")
        for search in searches:
            if search["effectiveMode"] != key[1] or search["requestedMode"] != key[1] or not search["hits"]:
                raise ValueError(f"Fallback/empty search: {key}")
            if key[1] in ("semantic", "hybrid"):
                if (search["semanticModelIdentity"]["sha256"] != E5_SHA
                        or search["semanticScoredChunkCount"] != search["chunkCount"]):
                    raise ValueError(f"Wrong/incomplete E5 scoring: {key}")
            for hit in search["hits"]:
                chunk = hit["chunk"]
                start, end = chunk["startUTF16"], chunk["endUTF16"]
                if (chunk["documentID"] != key[0] or chunk["documentFingerprint"] != sample["sourceSHA256"]
                        or not 0 <= start < end <= len(source.encode("utf-16-le")) // 2
                        or source.encode("utf-16-le")[start * 2:end * 2].decode("utf-16-le") != chunk["text"]):
                    raise ValueError(f"Nonoriginal or external evidence: {key}")
                if key[1] == "semantic" and (hit.get("keywordRank") is not None or not 0.30 < hit["score"] <= 1.00001):
                    raise ValueError(f"Impure semantic selector: {key}")
        annotation = annotations[key]
        items = {item["id"]: item for item in annotation["items"]}
        if len(items) != len(annotation["items"]) or set(items) != {item["id"] for item in reference["items"]}:
            raise ValueError(f"Missing/duplicate item annotation: {key}")
        for item in reference["items"]:
            scored = items[item["id"]]
            if not item["sourceQuote"] or item["sourceQuote"] not in source:
                raise ValueError(f"Gold not grounded in original source: {item['id']}")
            if (scored["input"] not in ("full", "partial", "absent") or scored["output"] not in SCORES
                    or not scored["reason"].strip()):
                raise ValueError(f"Invalid item judgment: {key}, {item['id']}")
            quote = scored.get("outputQuote", "")
            if scored["output"] != "absent" and (not quote or quote not in sample["rawOutput"]):
                raise ValueError(f"Untraceable output judgment: {key}, {item['id']}")
            input_quote = scored.get("inputQuote", "")
            if scored["input"] != "absent" and (not input_quote or input_quote not in sample["prompt"]):
                raise ValueError(f"Untraceable input judgment: {key}, {item['id']}")
            item_rows.append({
                "document_id": key[0], "alias": reference["alias"], "mode": key[1], "item_id": item["id"],
                "category": item["category"], "fact": item["fact"], "source_quote": item["sourceQuote"],
                "input_status": scored["input"], "input_score": SCORES[scored["input"]],
                "output_status": scored["output"], "output_score": SCORES[scored["output"]],
                "input_quote": input_quote, "output_quote": quote, "reason": scored["reason"],
            })
        claims = annotation["claims"]
        if [claim["text"] for claim in claims] != claim_units(sample["rawOutput"]):
            raise ValueError(f"Review must account for every output unit in order: {key}")
        for index, claim in enumerate(claims, 1):
            status = claim["status"]
            if status not in ("supported", "unsupported", "contradicted", "non_substantive") or not claim["reason"].strip():
                raise ValueError(f"Invalid claim review: {key}")
            quote = claim.get("sourceQuote", "")
            if status in ("supported", "contradicted") and (not quote or quote not in source):
                raise ValueError(f"Untraceable source claim: {key}")
            if type(claim["inputSupported"]) is not bool:
                raise ValueError(f"Invalid input-support judgment: {key}")
            if claim["inputSupported"] and (not claim.get("inputQuote") or claim["inputQuote"] not in sample["prompt"]):
                raise ValueError(f"Untraceable input-support judgment: {key}")
            claim_rows.append({
                "document_id": key[0], "mode": key[1], "unit": index, "text": claim["text"],
                "status": status, "input_supported": claim["inputSupported"], "source_quote": quote,
                "input_quote": claim.get("inputQuote", ""), "reason": claim["reason"],
            })
        substantive = [claim for claim in claims if claim["status"] != "non_substantive"]
        supported = sum(claim["status"] == "supported" for claim in substantive)
        input_supported = sum(claim["inputSupported"] for claim in substantive)
        disposition = [item["id"] for item in reference["items"] if item["category"] == "disposition"]
        if len(disposition) != 1:
            raise ValueError("Exactly one disposition item per document is required")
        rows.append({
            "document_id": key[0], "alias": reference["alias"], "mode": key[1],
            "source_characters": len(source), "prompt_characters": len(sample["prompt"]),
            "prompt_sha256": hashlib.sha256(sample["wrappedPrompt"].encode()).hexdigest(),
            "output_sha256": hashlib.sha256(sample["rawOutput"].encode()).hexdigest(),
            "output_characters": len(sample["rawOutput"]), "items": len(items),
            "fully_preserved_items": sum(item["output"] == "full" for item in items.values()),
            "partially_preserved_items": sum(item["output"] == "partial" for item in items.values()),
            "contradicted_items": sum(item["output"] == "contradicted" for item in items.values()),
            "input_coverage": sum(SCORES[item["input"]] for item in items.values()) / len(items),
            "output_coverage": sum(SCORES[item["output"]] for item in items.values()) / len(items),
            "substantive_units": len(substantive), "source_supported_units": supported,
            "non_substantive_units": len(claims) - len(substantive),
            "input_supported_units": input_supported,
            "unsupported_units": sum(claim["status"] == "unsupported" for claim in substantive),
            "contradicted_units": sum(claim["status"] == "contradicted" for claim in substantive),
            "source_faithfulness": supported / len(substantive) if substantive else None,
            "input_faithfulness": input_supported / len(substantive) if substantive else None,
            "disposition_preserved": items[disposition[0]]["output"] == "full",
            "format_parsed": sample["formatParsed"], "generation_failed": sample.get("failureReason") is not None,
            "selection_seconds": sample["selectionMS"] / 1000, "generation_seconds": sample["generationMS"] / 1000,
            "total_seconds": sample["totalMS"] / 1000,
        })
    if seen != expected:
        raise ValueError("Incomplete native grid")
    return pd.DataFrame(rows), pd.DataFrame(item_rows), pd.DataFrame(claim_rows)


def summarize(samples: pd.DataFrame) -> pd.DataFrame:
    summary = samples.groupby("mode", sort=False).agg(
        documents=("document_id", "count"), input_coverage=("input_coverage", "mean"),
        fully_preserved_items=("fully_preserved_items", "sum"),
        partially_preserved_items=("partially_preserved_items", "sum"),
        contradicted_items=("contradicted_items", "sum"),
        output_coverage=("output_coverage", "mean"), substantive_units=("substantive_units", "sum"),
        non_substantive_units=("non_substantive_units", "sum"),
        source_supported_units=("source_supported_units", "sum"), input_supported_units=("input_supported_units", "sum"),
        unsupported_units=("unsupported_units", "sum"), contradicted_units=("contradicted_units", "sum"),
        disposition_preserved=("disposition_preserved", "sum"), format_parsed=("format_parsed", "sum"),
        generation_failures=("generation_failed", "sum"), median_total_seconds=("total_seconds", "median"),
    ).reindex(MODES)
    denominator = summary["substantive_units"].where(summary["substantive_units"].gt(0))
    summary["source_faithfulness"] = summary["source_supported_units"] / denominator
    summary["input_faithfulness"] = summary["input_supported_units"] / denominator
    return summary


def plot_results(samples: pd.DataFrame, summary: pd.DataFrame, output: Path) -> None:
    plt.rcParams.update({"font.family": "DejaVu Sans", "svg.fonttype": "path", "font.size": 13})
    fig, ax = plt.subplots(figsize=(16, 8))
    positions = list(range(4))
    for offset, column, label, color in [(-0.19, "input_coverage", "Delivered input", "#8ba6c6"),
                                        (0.19, "output_coverage", "Generated summary", "#249d8c")]:
        bars = ax.bar([x + offset for x in positions], summary[column] * 100, width=0.36, label=label, color=color)
        ax.bar_label(bars, fmt="%.1f%%", padding=5, fontsize=14)
    ax.set_xticks(positions, LABELS)
    ax.set_ylim(0, 110)
    ax.set_ylabel("Core-item coverage (%)")
    ax.set_title("Long-judgment summaries: input coverage vs output coverage", loc="left", weight="bold", pad=22)
    ax.legend(loc="upper right")
    fig.text(0.08, 0.015, "3 judgments; 6 frozen items each; full=1, partial=0.5. Source-bounded AI preliminary review, not expert accuracy.", fontsize=11)
    fig.tight_layout(rect=(0, 0.045, 1, 1))
    save_figure(fig, output, "01-core-coverage")

    fig, ax = plt.subplots(figsize=(16, 8))
    matrix = samples.pivot(index="alias", columns="mode", values="output_coverage").reindex(columns=MODES)
    image = ax.imshow(matrix * 100, vmin=0, vmax=100, cmap="YlGnBu", aspect="auto")
    for row in range(len(matrix)):
        for column in range(4):
            value = matrix.iloc[row, column] * 100
            ax.text(column, row, f"{value:.1f}%", ha="center", va="center", fontsize=24,
                    color="white" if value >= 55 else "#18243b", weight="bold")
    ax.set_xticks(positions, LABELS)
    ax.set_yticks(range(len(matrix)), ["Judgment " + alias for alias in matrix.index])
    ax.set_title("Core information preserved in each generated summary", loc="left", weight="bold", pad=22)
    fig.colorbar(image, ax=ax, label="Core-item coverage (%)")
    fig.text(0.08, 0.015, "One generation per cell; same production template/budget. F is the fields baseline, not the final UI card.", fontsize=11)
    fig.tight_layout(rect=(0, 0.045, 1, 1))
    save_figure(fig, output, "02-per-judgment-quality")

    fig, axes = plt.subplots(1, 2, figsize=(17, 8))
    for column, label, color in [("source_faithfulness", "Supported by full source", "#249d8c"),
                                 ("input_faithfulness", "Supported by delivered input", "#3b6ea8")]:
        offset = -0.19 if column == "source_faithfulness" else 0.19
        values = summary[column] * 100
        bars = axes[0].bar([x + offset for x in positions], values.fillna(0), width=0.36, color=color, label=label)
        axes[0].bar_label(bars, labels=[f"{v:.1f}%" if pd.notna(v) else "N/A" for v in values], padding=5, fontsize=11)
    axes[0].set_ylim(0, 120)
    axes[0].set_ylabel("Supported substantive output units (%)")
    axes[0].legend(fontsize=10, loc="upper right")
    bottom = [0] * 4
    for column, label, color in [("source_supported_units", "Source-supported", "#249d8c"),
                                 ("unsupported_units", "Unsupported / unverifiable", "#cf8b30"),
                                 ("contradicted_units", "Contradicts source", "#c64d58")]:
        bars = axes[1].bar(positions, summary[column], bottom=bottom, color=color, label=label)
        axes[1].bar_label(bars, labels=[str(int(value)) if value else "" for value in summary[column]],
                         label_type="center", color="white", fontsize=14)
        bottom = [a + b for a, b in zip(bottom, summary[column])]
    axes[1].set_ylabel("Substantive output units (count)")
    axes[1].legend(fontsize=10, loc="upper right")
    axes[1].set_ylim(0, max(bottom + [1]) * 1.45)
    for ax in axes:
        ax.set_xticks(positions, ["F", "K", "S", "H"])
    fig.suptitle("Faithfulness and explicit error counts", x=0.06, ha="left", weight="bold", fontsize=21)
    fig.text(0.06, 0.015, "AI preliminary review of every sentence/line unit. N/A means no substantive units; omissions are measured in coverage, not here.", fontsize=11)
    fig.tight_layout(rect=(0, 0.045, 1, 0.94))
    save_figure(fig, output, "03-faithfulness-errors")

    aliases = sorted(samples["alias"].unique())
    fig, axes = plt.subplots(1, len(aliases), figsize=(18, 8), sharey=True, squeeze=False)
    for alias, ax in zip(aliases, axes[0]):
        data = samples[samples["alias"].eq(alias)].set_index("mode").reindex(MODES)
        ax.bar(positions, data["selection_seconds"], color="#cf8b30", label="Evidence / prompt preparation")
        ax.bar(positions, data["generation_seconds"], bottom=data["selection_seconds"], color="#3b6ea8", label="Llama generation")
        for position, value in enumerate(data["total_seconds"]):
            ax.annotate(f"{value:.1f}s", (position, value), xytext=(0, 5), textcoords="offset points", ha="center", fontsize=12)
        ax.set_xticks(positions, ["F", "K", "S", "H"])
        ax.set_title("Judgment " + alias)
        ax.margins(y=0.2)
    axes[0][0].set_ylabel("Request wall time (seconds)")
    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=2, bbox_to_anchor=(0.5, 0.94), frameon=False)
    fig.suptitle("Observed summary cost: preparation and generation", x=0.06, ha="left", weight="bold", fontsize=21)
    fig.text(0.06, 0.015, "One observation/cell; fresh E5 provider per S/H cell (cold costs included). Llama initial load excluded. Simulator, not device latency.", fontsize=11)
    fig.tight_layout(rect=(0, 0.045, 1, 0.88))
    save_figure(fig, output, "04-summary-cost")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    root = args.directory
    paths = {name: root / name for name in ("raw/report.json", "gold.json", "review.json")}
    contents = {name: json.loads(path.read_text(encoding="utf-8")) for name, path in paths.items()}
    samples, items, claims = evaluate(contents["raw/report.json"], contents["gold.json"], contents["review.json"])
    summary = summarize(samples)
    for name, frame, index in [("samples", samples, False), ("items", items, False),
                                ("claims", claims, False), ("mode_summary", summary, True)]:
        frame.to_csv(root / f"{name}.csv", index=index)
    plot_results(samples, summary, root)
    metadata = {
        "scope": "12 native raw summaries; source-bounded AI preliminary review, not independent legal accuracy",
        "hashes": {name: sha256(path) for name, path in paths.items()},
        "analyzerSHA256": sha256(Path(__file__)),
        "figureHelperSHA256": sha256(Path(__file__).with_name("analyze_legal_case_pilot.py")),
        "versions": {"pandas": pd.__version__, "matplotlib": matplotlib.__version__},
        "identicalPromptGroups": [
            {"documentID": key[0], "promptSHA256": key[1], "modes": group["mode"].tolist(),
             "outputHashes": group["output_sha256"].tolist()}
            for key, group in samples.groupby(["document_id", "prompt_sha256"]) if len(group) > 1
        ],
        "summary": json.loads(summary.reset_index().to_json(orient="records")),
    }
    (root / "analysis_summary.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(summary.to_string())


if __name__ == "__main__":
    main()
