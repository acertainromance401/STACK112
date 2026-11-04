#!/usr/bin/env python3
"""Analyze exported real-model samples; never infer legal correctness from format."""

import argparse
import hashlib
import json
import math
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import ListedColormap
from matplotlib.patches import FancyBboxPatch
import pandas as pd


MODES = ["currentOnly", "keyword", "hybrid"]
LABELS = ["B0: current only", "B1: keyword", "H: hybrid E5"]
SEARCH_MODES = ["keyword", "hybrid"]
SEARCH_COLORS = ["#3b6ea8", "#249d8c"]


def sample_frame(report: dict) -> pd.DataFrame:
    queries = {query["id"]: query for query in report["dataset"]["queries"]}
    documents = {doc["id"]: doc for doc in report["dataset"]["documents"]}
    rows = []
    seen = set()
    for sample in report["samples"]:
        query_id = sample["queryID"]
        query = queries[query_id]
        run = sample["run"]
        mode = run["search"]["requestedMode"]
        key = (query_id, mode, sample["repetition"])
        if key in seen:
            raise ValueError(f"Duplicate sample: {key}")
        seen.add(key)
        if run["targetDocumentID"] != query["targetDocumentID"]:
            raise ValueError(f"Wrong target: {key}")
        for doc_id, fingerprint in run["corpusFingerprints"].items():
            actual = hashlib.sha256(documents[doc_id]["text"].encode()).hexdigest()
            if actual != fingerprint:
                raise ValueError(f"Source fingerprint mismatch: {doc_id}")
        hits = list(dict.fromkeys(hit["chunk"]["documentID"] for hit in run["search"]["hits"]))
        relevant = set(query["relevantDocumentIDs"])
        evaluated = hits[:3]
        relevant_hits = set(evaluated) & relevant
        reciprocal_rank = (next((1 / rank for rank, doc_id in enumerate(evaluated, 1)
                                 if doc_id in relevant), 0) if relevant else None)
        retrieval_ms = run["retrievalMS"]
        if (isinstance(retrieval_ms, bool) or not isinstance(retrieval_ms, (int, float))
                or not math.isfinite(retrieval_ms) or retrieval_ms < 0):
            raise ValueError(f"Invalid retrieval time: {key}")
        identity = run["search"]["semanticModelIdentity"]
        warm = cache_hits = cache_misses = None
        if mode == "hybrid" and run["search"]["effectiveMode"] == mode:
            warm = identity["warmBeforeSearch"]
            cache_hits = int(identity["vectorCacheHits"])
            cache_misses = int(identity["vectorCacheMisses"])
            if warm not in ("true", "false") or min(cache_hits, cache_misses) < 0:
                raise ValueError(f"Invalid embedding cache telemetry: {key}")
        evidence = run["evidence"]
        reference_ids = list(dict.fromkeys(
            item["chunk"]["documentID"] for item in evidence if item["id"] != "E0"))
        for item in evidence:
            chunk = item["chunk"]
            original = documents[chunk["documentID"]]["text"].encode("utf-16-le")
            excerpt = original[chunk["startUTF16"] * 2:chunk["endUTF16"] * 2].decode("utf-16-le")
            if excerpt != chunk["text"]:
                raise ValueError(f"Delivered evidence range mismatch: {key}, {item['id']}")
        trace = run.get("generation")
        output = trace["output"] if trace else ""
        output_hash = hashlib.sha256(output.encode()).hexdigest() if trace else None
        if output_hash != sample.get("outputSHA256"):
            raise ValueError(f"Output fingerprint mismatch: {key}")
        claims = run["claims"]
        success = (not run.get("failureReason") and not (trace or {}).get("failureReason")
                   and bool(claims) and all(not claim["unknownCitationIDs"] for claim in claims))
        if success != sample["outputSuccess"]:
            raise ValueError(f"Output-success disagreement: {key}")
        rows.append({
            "query_id": query_id, "mode": mode, "repetition": sample["repetition"],
            "effective_mode": run["search"]["effectiveMode"],
            "mode_match": run["search"]["effectiveMode"] == mode, "environment": run["environment"],
            "retrieved_document_ids": "|".join(hits),
            "expected_document_ids": "|".join(sorted(relevant)),
            "retrieved_documents": len(hits), "irrelevant_documents": len(set(hits) - relevant),
            "relevant_retrieved": len(set(hits) & relevant),
            "exact_reference_set": set(hits) == relevant,
            "precision_at_3": len(relevant_hits) / 3,
            "recall": len(relevant_hits) / len(relevant) if relevant else None,
            "reciprocal_rank": reciprocal_rank,
            "no_reference_correct": not hits if not relevant else None,
            "retrieval_seconds_simulator_only": retrieval_ms / 1000,
            "e5_warm_before_search": warm,
            "e5_cache_hits": cache_hits, "e5_cache_misses": cache_misses,
            "reference_evidence_ids": "|".join(reference_ids),
            "irrelevant_evidence_documents": len(set(reference_ids) - relevant),
            "reference_evidence_documents": len(reference_ids),
            "delivered_characters": "|".join(str(len(item["chunk"]["text"])) for item in evidence),
            "output_present": bool(output.strip()), "output_success": success,
            "basic_grounding_proxy": sample.get("basicGroundingProxy"),
            "output_sha256": output_hash, "output": output,
            "failure_reason": run.get("failureReason"),
            "generation_attempts": trace["attempts"] if trace else 0,
            "inference_seconds_simulator_only": trace["inferenceMS"] / 1000 if trace else None,
        })
    expected = {(query_id, mode, 1) for query_id in queries for mode in MODES}
    if seen != expected:
        raise ValueError(f"Incomplete or unexpected sample grid: expected {expected}, found {seen}")
    return pd.DataFrame(rows)


def retrieval_summary(samples: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for mode in SEARCH_MODES:
        subset = samples.loc[samples["mode"].eq(mode)]
        if subset.empty or not subset["mode_match"].all():
            raise ValueError(f"Cannot compare missing or fallback retrieval mode: {mode}")
        no_reference = subset["no_reference_correct"].dropna()
        contaminated = subset["irrelevant_evidence_documents"].gt(0)
        rows.append({
            "mode": mode, "samples": len(subset),
            "positive_queries": int(subset["recall"].notna().sum()),
            "no_reference_queries": len(no_reference),
            "precision_at_3": subset["precision_at_3"].mean(),
            "recall_at_3": subset["recall"].mean(),
            "mrr_at_3": subset["reciprocal_rank"].mean(),
            "no_reference_successes": int(no_reference.sum()),
            "no_reference_success_rate": no_reference.mean(),
            "irrelevant_evidence_requests": int(contaminated.sum()),
            "irrelevant_evidence_request_rate": contaminated.mean(),
        })
    return pd.DataFrame(rows).set_index("mode")


def attach_reviews(samples: pd.DataFrame, reviews: pd.DataFrame) -> pd.DataFrame:
    keys = ["query_id", "mode", "output_sha256"]
    if reviews.duplicated(keys).any():
        raise ValueError("Duplicate quality reviews")
    if not reviews["semantic_rating"].isin(["correct", "partial", "incorrect", "unassessable"]).all():
        raise ValueError("Unknown semantic review rating")
    merged = samples.merge(reviews, on=keys, how="outer", validate="one_to_one", indicator=True)
    if not merged["_merge"].eq("both").all():
        raise ValueError("Reviews must match every sample and exact output hash")
    return merged.drop(columns="_merge")


def save_figure(fig: plt.Figure, output: Path, name: str) -> None:
    for extension in ("png", "svg"):
        fig.savefig(output / f"{name}.{extension}", dpi=180, bbox_inches="tight")
    svg = output / f"{name}.svg"
    svg.write_text("\n".join(line.rstrip(" \t") for line in svg.read_text(encoding="utf-8").splitlines()) + "\n",
                   encoding="utf-8")
    plt.close(fig)


def plot_retrieval_comparison(samples: pd.DataFrame, summary: pd.DataFrame, output: Path) -> None:
    fig, ax = plt.subplots(figsize=(16, 9))
    ax.set_axis_off()
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.set_title("Retrieval configurations: what changes?", loc="left", weight="bold", fontsize=23, pad=24)
    lanes = [
        ("B0", "Current source only", ["No reference search", "Current evidence E0", "Same Llama"], "#65758b"),
        ("B1", "Keyword RAG", ["Keyword / case-number rank", "Top-3 chunks; up to 2 refs", "Same Llama"], SEARCH_COLORS[0]),
        ("H", "Hybrid RAG", ["Keyword rank + E5 cosine rank", "RRF; top-3 chunks; up to 2 refs", "Same Llama"], SEARCH_COLORS[1]),
    ]
    for y, (short, title, stages, color) in zip([0.79, 0.56, 0.33], lanes):
        ax.text(0.01, y + 0.06, short, fontsize=25, color=color, weight="bold")
        ax.text(0.01, y + 0.015, title, fontsize=13)
        for x, width, text in zip([0.19, 0.51, 0.83], [0.27, 0.27, 0.15], stages):
            box = FancyBboxPatch((x, y), width, 0.12, boxstyle="round,pad=0.012",
                                 edgecolor=color, facecolor="#f4f7fa", linewidth=1.8)
            ax.add_patch(box)
            ax.text(x + width / 2, y + 0.06, text, ha="center", va="center", fontsize=12)
        for left, right in [(0.465, 0.495), (0.785, 0.815)]:
            ax.annotate("", (right, y + 0.06), (left, y + 0.06),
                        arrowprops={"arrowstyle": "->", "color": color, "lw": 1.8})
    ax.text(0.01, 0.19, "E5-only retrieval: NOT IMPLEMENTED / NOT RUN (no measured score or zero-valued bar)",
            fontsize=14, color="#65758b",
            bbox={"boxstyle": "round,pad=0.65", "edgecolor": "#aab5c2", "facecolor": "#f4f7fa", "linestyle": "--"})
    ax.text(0.01, 0.07, "Shared: question + current title; same exclusions; 320-character chunks / 64 overlap.\n"
            "Same generator and budget: Llama-3.2-1B Q4_K_M; 512-token context; delivered excerpts of 96 characters.\n"
            "B1 vs H tests adding E5 + rank fusion together, not two different generation models.",
            fontsize=12, linespacing=1.7)
    fig.tight_layout()
    save_figure(fig, output, "04-retrieval-configurations")

    metrics = ["precision_at_3", "recall_at_3", "mrr_at_3", "no_reference_success_rate",
               "irrelevant_evidence_request_rate"]
    counts = summary.iloc[0]
    labels = [f"Document P@3\nn={int(counts['samples'])}; fixed k=3",
              f"Document Recall@3\npositive queries; n={int(counts['positive_queries'])}",
              f"Document MRR@3\npositive queries; n={int(counts['positive_queries'])}",
              f"No-reference success\nnegative queries; n={int(counts['no_reference_queries'])}",
              f"Irrelevant refs in input\nlower is better; n={int(counts['samples'])}"]
    fig, ax = plt.subplots(figsize=(16, 9))
    for j, (mode, color) in enumerate(zip(SEARCH_MODES, SEARCH_COLORS)):
        values = summary.loc[mode, metrics].to_numpy(dtype=float)
        positions = [i + (j - 0.5) * 0.34 for i in range(len(metrics))]
        bars = ax.bar(positions, values, width=0.32, color=color, label=LABELS[MODES.index(mode)])
        ax.bar_label(bars, labels=[f"{v:.3f}" if math.isfinite(v) else "N/A" for v in values],
                     padding=7, fontsize=13)
        for x, value in zip(positions, values):
            if value == 0:
                ax.plot(x, 0, marker="_", color=color, markersize=22, markeredgewidth=4, clip_on=False)
    ax.set_ylim(0, 1.20)
    ax.set_xticks(range(len(metrics)), labels, fontsize=11)
    ax.set_ylabel("Score / rate (0 to 1)", fontsize=13)
    ax.set_title("B1 vs H: document-level retrieval quality", loc="left", fontsize=23, weight="bold", pad=45)
    deltas = summary.loc["hybrid", metrics] - summary.loc["keyword", metrics]
    delta_text = "   |   ".join(f"{value:+.3f}" if pd.notna(value) else "N/A" for value in deltas)
    ax.text(0, 1.05, f"H minus B1, left to right:  {delta_text}", transform=ax.transAxes, fontsize=13)
    ax.legend(loc="upper right", fontsize=13)
    ax.yaxis.grid(True, alpha=0.18)
    ax.set_axisbelow(True)
    fig.text(0.04, 0.055, "Provisional document labels; not legal-answer accuracy. Missing gold-reference cases are excluded from Recall / MRR.\n"
             "One execution per query/configuration; no confidence intervals. B0 performs no reference search; E5-only was not run.",
             fontsize=11, linespacing=1.6)
    fig.tight_layout(rect=(0.02, 0.12, 0.99, 1))
    save_figure(fig, output, "05-retrieval-quality-comparison")

    times = samples.loc[samples["mode"].isin(SEARCH_MODES)]
    if not times["retrieval_seconds_simulator_only"].gt(0).all():
        raise ValueError("Retrieval times must be positive for the logarithmic timing plot")
    matrix = times.pivot(index="query_id", columns="mode", values="retrieval_seconds_simulator_only")
    hybrid = times.loc[times["mode"].eq("hybrid")].set_index("query_id")
    fig, ax = plt.subplots(figsize=(16, 9))
    for mode, color in zip(SEARCH_MODES, SEARCH_COLORS):
        values = matrix[mode].to_numpy()
        ax.plot(range(len(matrix)), values, "o-", color=color, linewidth=2.5, markersize=10,
                label=LABELS[MODES.index(mode)])
        for x, seconds in enumerate(values):
            label = f"{seconds * 1000:.1f} ms" if seconds < 1 else f"{seconds:.2f} s"
            ax.annotate(label, (x, seconds), xytext=(0, 13), textcoords="offset points",
                        ha="center", fontsize=15, color=color, weight="bold")
    tick_labels = []
    for query_id in matrix.index:
        row = hybrid.loc[query_id]
        tick_labels.append(f"{query_id}\nE5 cache hits/misses: {int(row['e5_cache_hits'])}/{int(row['e5_cache_misses'])}\n"
                           f"warmBeforeSearch: {row['e5_warm_before_search']}")
    ax.set_xticks(range(len(matrix)), tick_labels, fontsize=12)
    ax.set_yscale("log")
    ax.set_ylim(matrix.min().min() / 2, matrix.max().max() * 3)
    ax.set_ylabel("Retrieval-path wall time, seconds (LOG SCALE)", fontsize=13)
    ax.set_title("Observed retrieval cost: cache state differs across queries", loc="left",
                 fontsize=23, weight="bold", pad=24)
    ax.legend(loc="upper right", fontsize=13)
    ax.grid(axis="y", which="both", alpha=0.18)
    fig.text(0.04, 0.055, "Simulator CPU; one execution per cell; fixed B0 -> B1 -> H order; no randomization or confidence intervals.\n"
             "retrievalMS includes task dispatch / retrieval, excluding subsequent Llama preparation and generation. Not a controlled warm-cache benchmark.",
             fontsize=11, linespacing=1.6)
    fig.tight_layout(rect=(0.02, 0.12, 0.99, 1))
    save_figure(fig, output, "06-retrieval-latency")


def analyze(raw: Path, output: Path, reviews_path: Path | None = None) -> dict:
    report_path = raw / "report.json"
    report = json.loads(report_path.read_text())
    samples = sample_frame(report)
    cosines = pd.json_normalize(json.loads((raw / "cosines.json").read_text()))
    if cosines.empty or not {"queryID", "chunk.documentID", "cosine"}.issubset(cosines.columns):
        raise ValueError("Missing real embedding diagnostics")
    if cosines.duplicated(["queryID", "chunk.id"]).any():
        raise ValueError("Duplicate query/chunk cosine observations")
    if not cosines["cosine"].dropna().between(-1.00001, 1.00001).all():
        raise ValueError("Invalid native cosine value")
    if set(cosines["queryID"]) != set(samples["query_id"]):
        raise ValueError("Cosine diagnostics do not cover the sample queries")
    cosine_groups = cosines.groupby(["queryID", "chunk.documentID"], as_index=False).agg(
        chunk_count=("cosine", "size"), scored_count=("cosine", "count"),
        min_cosine=("cosine", "min"), median_cosine=("cosine", "median"), max_cosine=("cosine", "max")
    )
    if reviews_path is not None:
        samples = attach_reviews(samples, pd.read_csv(reviews_path, keep_default_na=False))
    summary = samples.groupby("mode", sort=False).agg(
        samples=("query_id", "size"), mode_matches=("mode_match", "sum"),
        output_present=("output_present", "sum"), output_success=("output_success", "sum"),
        exact_reference_sets=("exact_reference_set", "sum"),
        irrelevant_document_selections=("irrelevant_documents", "sum"),
        irrelevant_evidence_selections=("irrelevant_evidence_documents", "sum")
    ).reindex(MODES)
    for mode in MODES:
        subset = samples.loc[samples["mode"].eq(mode)]
        if reviews_path is not None:
            summary.loc[mode, "ai_review_correct"] = int(subset["semantic_rating"].eq("correct").sum())
            summary.loc[mode, "valid_and_ai_correct"] = int(
                (subset["semantic_rating"].eq("correct") & subset["output_success"]).sum())
    output.mkdir(parents=True, exist_ok=True)
    samples.to_csv(output / "samples.csv", index=False)
    retrieval = retrieval_summary(samples)
    retrieval.to_csv(output / "retrieval_mode_summary.csv")
    samples.loc[samples["mode"].isin(SEARCH_MODES), [
        "query_id", "mode", "effective_mode", "environment", "retrieval_seconds_simulator_only",
        "e5_warm_before_search", "e5_cache_hits", "e5_cache_misses",
    ]].to_csv(output / "retrieval_timings.csv", index=False)
    summary.to_csv(output / "mode_summary.csv")
    cosine_groups.to_csv(output / "cosine_summary.csv", index=False)
    cosines.to_csv(output / "chunk_cosines.csv", index=False)
    plt.rcParams.update({"font.family": "DejaVu Sans", "svg.fonttype": "path"})
    plot_retrieval_comparison(samples, retrieval, output)
    matrix = samples.pivot(index="query_id", columns="mode", values="exact_reference_set").reindex(columns=MODES)
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.imshow(matrix.to_numpy(dtype=float), vmin=0, vmax=1,
              cmap=ListedColormap(["#f3d9d4", "#d7ebe3"]), aspect="auto")
    for i, query_id in enumerate(matrix.index):
        for j, mode in enumerate(MODES):
            row = samples.loc[samples["query_id"].eq(query_id) & samples["mode"].eq(mode)].iloc[0]
            refs = row["retrieved_document_ids"].replace("sc-", "").replace("|", "\n") or "(none)"
            ax.text(j, i, refs, ha="center", va="center", fontsize=10)
    ax.set_xticks(range(3), LABELS)
    ax.set_yticks(range(len(matrix)), matrix.index)
    ax.set_title("Selected references: exact provisional relevance set", loc="left", weight="bold", pad=18)
    fig.text(0.02, 0.01, "Green: exact set. Red: missing or extraneous reference. B0 performs no retrieval by design.",
             fontsize=9)
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    save_figure(fig, output, "01-reference-selection")
    fig, ax = plt.subplots(figsize=(11, 5))
    ticks = []
    for i, ((query_id, doc_id), group) in enumerate(cosines.groupby(["queryID", "chunk.documentID"])):
        values = group["cosine"].dropna().to_list()
        ax.scatter([i + ((j % 7) - 3) * 0.03 for j in range(len(values))], values, s=22, alpha=0.7)
        ticks.append(f"{query_id}\n{doc_id.removeprefix('sc-')}")
    ax.axhline(0.30, color="#a13e39", linestyle="--", label="Current cosine cutoff: 0.30")
    ax.set_xticks(range(len(ticks)), ticks, fontsize=9)
    ax.set_ylim(0, 1.02)
    ax.set_ylabel("Actual E5 cosine (not a probability)")
    ax.set_title("Native E5 scores include same-field distractors", loc="left", weight="bold")
    ax.legend(loc="lower right")
    fig.tight_layout()
    save_figure(fig, output, "02-actual-chunk-cosines")
    result = {
        "scope": "3 judgments, 3 queries, 9 real-model attempts; one sample per cell; simulator only",
        "independent_expert_review": False,
        "report_sha256": hashlib.sha256(report_path.read_bytes()).hexdigest(),
        "analysis_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "model_sha256": report["modelSHA256"],
        "pandas_version": pd.__version__, "matplotlib_version": matplotlib.__version__,
        "mode_summary": summary.reset_index().to_dict(orient="records"),
        "retrieval_summary": json.loads(retrieval.reset_index().to_json(orient="records")),
    }
    (output / "analysis_summary.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reviews", type=Path)
    arguments = parser.parse_args()
    print(json.dumps(analyze(arguments.raw, arguments.output, arguments.reviews), ensure_ascii=False, indent=2))
