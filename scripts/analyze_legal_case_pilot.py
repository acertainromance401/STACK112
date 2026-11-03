#!/usr/bin/env python3
"""Analyze exported real-model samples; never infer legal correctness from format."""

import argparse
import hashlib
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import ListedColormap
import pandas as pd


MODES = ["currentOnly", "keyword", "hybrid"]
LABELS = ["B0: current only", "B1: keyword", "H: hybrid E5"]


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
            "recall": len(set(hits) & relevant) / len(relevant) if relevant else None,
            "no_reference_correct": not hits if not relevant else None,
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
    summary.to_csv(output / "mode_summary.csv")
    cosine_groups.to_csv(output / "cosine_summary.csv", index=False)
    cosines.to_csv(output / "chunk_cosines.csv", index=False)
    plt.rcParams.update({"font.family": "DejaVu Sans", "svg.fonttype": "path"})
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
