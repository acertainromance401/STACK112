#!/usr/bin/env python3
"""Compare native keyword, E5-only, and hybrid retrieval without LLM generation."""

import argparse
import hashlib
import json
import math
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from analyze_legal_case_pilot import save_figure


MODES = ["keyword", "semantic", "hybrid"]
LABELS = ["B1: keyword", "S: E5-only", "H: hybrid"]
COLORS = ["#3b6ea8", "#cf8b30", "#249d8c"]
PHASES = ["provider_cold", "warm_passages_uncached_query"]
E5_SHA = "1629184be879a108e16cceef62f7a0fedfff4eefb81cd734d646f8f404b85cdc"


def ablation_frame(report: dict) -> tuple[pd.DataFrame, pd.DataFrame]:
    if report["schemaVersion"] != 1 or report["configuration"]["environment"] != "simulator_not_device_evidence":
        raise ValueError("Unsupported ablation schema or environment")
    queries = {query["id"]: query for query in report["dataset"]["queries"]}
    documents = {doc["id"]: doc for doc in report["dataset"]["documents"]}
    if len(queries) != len(report["dataset"]["queries"]) or len(documents) != len(report["dataset"]["documents"]):
        raise ValueError("Duplicate query or document IDs")
    seen = set()
    rows, hit_rows = [], []
    selected = {}
    for sample in report["samples"]:
        search = sample["search"]
        mode, phase = search["requestedMode"], sample["phase"]
        key = (sample["queryID"], mode, phase, sample["repetition"])
        if key in seen:
            raise ValueError(f"Duplicate sample: {key}")
        seen.add(key)
        if mode not in MODES or phase not in PHASES or search["effectiveMode"] != mode:
            raise ValueError(f"Unknown or fallback retrieval condition: {key}")
        query = queries[sample["queryID"]]
        if sample["queryText"] != query["question"] + " " + documents[query["targetDocumentID"]]["title"]:
            raise ValueError(f"Wrong query text: {key}")
        duration = sample["durationMS"]
        if isinstance(duration, bool) or not isinstance(duration, (float, int)) or not math.isfinite(duration) or duration <= 0:
            raise ValueError(f"Invalid retrieval duration: {key}")
        identity = search["semanticModelIdentity"]
        if mode != "keyword":
            if identity["sha256"] != E5_SHA or search["semanticScoredChunkCount"] != search["chunkCount"]:
                raise ValueError(f"Wrong model or incomplete semantic scoring: {key}")
            if identity["warmBeforeSearch"] != ("false" if phase == "provider_cold" else "true"):
                raise ValueError(f"Wrong provider state: {key}")
            if phase == PHASES[1] and (int(identity["vectorCacheMisses"]) != 1
                                      or int(identity["vectorCacheHits"]) != search["chunkCount"]):
                raise ValueError(f"Warm timing must re-encode only the query: {key}")
        elif search["semanticScoredChunkCount"] != 0 or identity:
            raise ValueError(f"Keyword condition used semantic scoring: {key}")
        hits = search["hits"]
        if len(hits) > 3 or len({hit["chunk"]["id"] for hit in hits}) != len(hits):
            raise ValueError(f"Invalid top-k or duplicate chunks: {key}")
        ids = list(dict.fromkeys(hit["chunk"]["documentID"] for hit in hits))
        if any(sum(hit["chunk"]["documentID"] == doc for hit in hits) > 2 for doc in ids):
            raise ValueError(f"Per-document chunk cap exceeded: {key}")
        for rank, hit in enumerate(hits, 1):
            chunk = hit["chunk"]
            doc = documents[chunk["documentID"]]
            start, end = chunk["startUTF16"], chunk["endUTF16"]
            original = doc["text"].encode("utf-16-le")
            if (doc["id"] == query["targetDocumentID"] or not 0 <= start < end <= len(original) // 2
                    or original[start * 2:end * 2].decode("utf-16-le") != chunk["text"]
                    or hashlib.sha256(doc["text"].encode()).hexdigest() != chunk["documentFingerprint"]):
                raise ValueError(f"Invalid source chunk: {key}")
            score = hit["score"]
            if not isinstance(score, (float, int)) or not math.isfinite(score):
                raise ValueError(f"Invalid hit score: {key}")
            if mode == "semantic" and (hit.get("keywordRank") is not None
                                       or hit.get("semanticRank") is None or not 0.30 < score <= 1.00001):
                raise ValueError(f"Semantic-only condition is not pure cosine retrieval: {key}")
            hit_rows.append({
                "query_id": sample["queryID"], "mode": mode, "phase": phase,
                "repetition": sample["repetition"], "rank": rank, "document_id": doc["id"],
                "chunk_id": chunk["id"], "start_utf16": start, "end_utf16": end,
                "keyword_rank": hit.get("keywordRank"), "semantic_rank": hit.get("semanticRank"),
                "score": score, "text": chunk["text"],
            })
        chunk_ids = tuple(hit["chunk"]["id"] for hit in hits)
        cell = (sample["queryID"], mode)
        if cell in selected and selected[cell] != chunk_ids:
            raise ValueError(f"Ranking changed across repeated timings; inspect before averaging: {cell}")
        selected[cell] = chunk_ids
        gold = set(query["relevantDocumentIDs"])
        correct = len(set(ids) & gold)
        precision = correct / 3
        recall = correct / len(gold) if gold else None
        reciprocal = next((1 / rank for rank, doc in enumerate(ids, 1) if doc in gold), 0) if gold else None
        no_reference = not ids if not gold else None
        saved = sample["relevance"]
        for name, value in [("precisionAtK", precision), ("recallAtK", recall), ("reciprocalRank", reciprocal)]:
            recorded = saved.get(name)
            if (value is None and recorded is not None) or (value is not None
                    and (not isinstance(recorded, (float, int)) or not math.isclose(value, recorded, abs_tol=1e-12))):
                raise ValueError(f"Native relevance metric mismatch: {key}, {name}")
        if saved.get("noRelevantDocumentCorrect") != no_reference or saved["evaluatedDocumentIDs"] != ids:
            raise ValueError(f"Native relevance identity mismatch: {key}")
        rows.append({
            "query_id": sample["queryID"], "mode": mode, "phase": phase,
            "repetition": sample["repetition"], "seconds": duration / 1000,
            "precision_at_3": precision, "recall_at_3": recall, "mrr_at_3": reciprocal,
            "no_reference_success": no_reference,
            "reference_candidate_contaminated": any(hit["chunk"]["documentID"] not in gold for hit in hits[:2]),
            "document_ids": "|".join(ids), "chunk_ids": "|".join(chunk_ids),
            "e5_cache_hits": identity.get("vectorCacheHits"),
            "e5_cache_misses": identity.get("vectorCacheMisses"),
            "e5_warm_before_search": identity.get("warmBeforeSearch"),
        })
    expected = {(q, m, p, r) for q in queries for m in MODES for p in PHASES
                for r in ([1] if p == PHASES[0] else [1, 2, 3])}
    if seen != expected:
        raise ValueError("Incomplete or unexpected query/mode/phase/repetition grid")
    return pd.DataFrame(rows), pd.DataFrame(hit_rows)


def summarize(frame: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    quality = frame.loc[frame["phase"].eq(PHASES[0])].groupby("mode").agg(
        queries=("query_id", "size"), positive_queries=("recall_at_3", "count"),
        negative_queries=("no_reference_success", "count"),
        precision_at_3=("precision_at_3", "mean"), recall_at_3=("recall_at_3", "mean"),
        mrr_at_3=("mrr_at_3", "mean"), no_reference_success=("no_reference_success", "mean"),
        reference_candidate_contaminated=("reference_candidate_contaminated", "mean")
    ).reindex(MODES)
    timing = frame.groupby(["query_id", "mode", "phase"], as_index=False).agg(
        observations=("seconds", "size"), median_seconds=("seconds", "median"),
        min_seconds=("seconds", "min"), max_seconds=("seconds", "max")
    )
    return quality, timing


def plot_comparison(quality: pd.DataFrame, timing: pd.DataFrame, output: Path) -> None:
    plt.rcParams.update({"font.family": "DejaVu Sans", "svg.fonttype": "path"})
    fig, ax = plt.subplots(figsize=(16, 9))
    ax.set_axis_off()
    cells = [
        ["B1: keyword", "Keyword / case-number rank", "No E5", "Lexical reciprocal rank\n+ existing exact-case bonus"],
        ["S: E5-only", "E5 cosine rank", "E5", "Cosine > 0.30\nNO lexical rank / exact-case bonus"],
        ["H: hybrid", "Keyword + E5 cosine ranks", "E5", "RRF (k=60)\n+ existing exact-case bonus"],
    ]
    table = ax.table(cellText=cells, colLabels=["Search configuration", "Selection signal", "Encoder", "Final ranking"],
                     cellLoc="center", bbox=[0, 0.30, 1, 0.58], colWidths=[0.19, 0.32, 0.10, 0.39])
    table.auto_set_font_size(False)
    table.set_fontsize(14)
    for row, color in enumerate(COLORS, 1):
        table[row, 0].set_facecolor(color)
        table[row, 0].get_text().set_color("white")
        table[row, 0].get_text().set_weight("bold")
    ax.set_title("Three measured retrieval configurations", loc="left", fontsize=24, weight="bold", pad=25)
    ax.text(0, 0.13, "Shared corpus, question + current title, exclusions, 320-character chunks / 64 overlap.\n"
            "Top-3 chunks; at most 2 per document. B0 is not a retrieval method.\n"
            "Retrieval-only experiment: NO Llama generation; top-2 reference candidates are not delivered LLM evidence.",
            fontsize=14, linespacing=1.8)
    fig.tight_layout()
    save_figure(fig, output, "01-configurations")

    metrics = ["precision_at_3", "recall_at_3", "mrr_at_3", "no_reference_success", "reference_candidate_contaminated"]
    counts = quality.iloc[0]
    ticks = [f"Document P@3\nn={int(counts['queries'])}; fixed k=3",
             f"Document Recall@3\nn={int(counts['positive_queries'])} positive queries",
             f"Document MRR@3\nn={int(counts['positive_queries'])} positive queries",
             f"No-reference success\nn={int(counts['negative_queries'])} negative queries",
             f"Top-2 ref contamination\nn={int(counts['queries'])}; lower is better"]
    fig, ax = plt.subplots(figsize=(16, 9))
    for index, (mode, label, color) in enumerate(zip(MODES, LABELS, COLORS)):
        values = quality.loc[mode, metrics].to_numpy(dtype=float)
        positions = [i + (index - 1) * 0.25 for i in range(len(metrics))]
        bars = ax.bar(positions, values, width=0.23, color=color, label=label)
        ax.bar_label(bars, labels=[f"{v:.3f}" if math.isfinite(v) else "N/A" for v in values], padding=7, fontsize=11)
        for x, value in zip(positions, values):
            if value == 0:
                ax.plot(x, 0, "_", color=color, markersize=18, markeredgewidth=4, clip_on=False)
    ax.set_xticks(range(len(metrics)), ticks, fontsize=11)
    ax.set_ylim(0, 1.20)
    ax.set_ylabel("Score / rate (0 to 1)")
    ax.set_title("Does E5 alone or fusion improve retrieval quality?", loc="left", fontsize=23, weight="bold", pad=22)
    ax.legend(loc="upper right", fontsize=12)
    ax.grid(axis="y", alpha=0.18)
    ax.set_axisbelow(True)
    fig.text(0.035, 0.045, "Quality counts each query once, not each timing repetition. Provisional document gold; no expert legal-answer evaluation.\n"
             "The last metric concerns selected reference candidates, NOT actual LLM input. No LLM was run in this experiment.",
             fontsize=11, linespacing=1.6)
    fig.tight_layout(rect=(0.01, 0.12, 0.99, 1))
    save_figure(fig, output, "02-quality-comparison")

    fig, axes = plt.subplots(1, 2, figsize=(18, 9))
    low, high = timing["min_seconds"].min() / 3, timing["max_seconds"].max() * 4
    queries = sorted(timing["query_id"].unique())
    for ax, phase, title in zip(axes, PHASES, [
            "Fresh provider: first search (n=1 per cell)",
            "Warm passages, uncached query (median of 3)"]):
        for index, (mode, label, color) in enumerate(zip(MODES, LABELS, COLORS)):
            group = timing.loc[timing["mode"].eq(mode) & timing["phase"].eq(phase)].set_index("query_id").loc[queries]
            values = group["median_seconds"].to_numpy()
            positions = [i + (index - 1) * 0.25 for i in range(len(queries))]
            errors = [values - group["min_seconds"].to_numpy(), group["max_seconds"].to_numpy() - values]
            ax.bar(positions, values, width=0.23, color=color, label=label,
                   yerr=errors if phase == PHASES[1] else None, capsize=3)
            for x, value in zip(positions, values):
                ax.annotate(f"{value:.3f}", (x, value), xytext=(0, 8), textcoords="offset points",
                            ha="center", fontsize=10)
        ax.set_yscale("log")
        ax.set_ylim(low, high)
        ax.set_xticks(range(len(queries)), queries)
        ax.set_title(title, fontsize=16, weight="bold", pad=18)
        ax.set_ylabel("Synchronous retrieval wall time, seconds (LOG SCALE)")
        ax.grid(axis="y", alpha=0.18)
        ax.set_axisbelow(True)
    fig.suptitle("Is the extra search cost justified? Separate startup from reuse.", fontsize=23, weight="bold")
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, ncol=3, loc="upper center", bbox_to_anchor=(0.5, 0.94),
               fontsize=12, frameon=False)
    fig.text(0.035, 0.04, "Simulator CPU; fresh provider per query/configuration, not an OS-cold run. Warm repeats evict only the query vector.\n"
             "Mode order rotated across queries. Warm whiskers show min-max, not confidence intervals. No generation, dispatch, memory or energy benchmark.",
             fontsize=11, linespacing=1.6)
    fig.tight_layout(rect=(0.01, 0.12, 0.99, 0.89))
    save_figure(fig, output, "03-search-cost")


def analyze(raw: Path, output: Path) -> dict:
    report_path = raw / "report.json"
    report = json.loads(report_path.read_text())
    frame, hits = ablation_frame(report)
    quality, timing = summarize(frame)
    output.mkdir(parents=True, exist_ok=True)
    frame.to_csv(output / "samples.csv", index=False)
    hits.to_csv(output / "hits.csv", index=False)
    quality.to_csv(output / "quality_summary.csv")
    timing.to_csv(output / "timing_summary.csv", index=False)
    plot_comparison(quality, timing, output)
    result = {
        "scope": report["configuration"], "native_samples": len(frame),
        "unique_quality_queries_per_mode": len(report["dataset"]["queries"]),
        "report_sha256": hashlib.sha256(report_path.read_bytes()).hexdigest(),
        "analysis_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "figure_helper_sha256": hashlib.sha256(Path(save_figure.__code__.co_filename).read_bytes()).hexdigest(),
        "pandas_version": pd.__version__, "matplotlib_version": matplotlib.__version__,
        "quality": json.loads(quality.reset_index().to_json(orient="records")),
        "timing": json.loads(timing.to_json(orient="records")),
    }
    (output / "analysis_summary.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(analyze(args.raw, args.output), indent=2, ensure_ascii=False))
