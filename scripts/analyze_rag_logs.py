#!/usr/bin/env python3
"""Extract XCTest evidence and analyze simulator logs with pandas."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd


RUNS = {
    "ondevice-rag-tests.log": "Legacy runtime",
    "ondevice-rag-root-tests.log": "Root synchronization",
    "rag-research-tests.log": "Research integration",
    "rag-research-tests-final.log": "Research + native generation",
    "rag-research-tests-regressions.log": "Research regressions",
    "rag-e5-tests.log": "Initial E5 integration",
    "rag-e5-focused.log": "Small conversion check",
    "rag-e5-base-tests.log": "E5-base regression",
    "rag-real-e2e.log": "Native RAG E2E",
    "rag-pinned-final-tests.log": "Pinned regression",
    "rag-ui-metadata-final.log": "Final research regression",
}
BASE = "rag-e5-base-tests.log"
PINNED = "rag-pinned-final-tests.log"
E2E = "rag-real-e2e.log"
UI = "rag-ui-metadata-final.log"
NATIVE_TESTS = {
    "testRealKoreanEmbeddingsRankParaphraseAboveUnrelatedTextAndReuseExactVectors":
        "E5 ranking + cache checks",
    "testActualGGUFHybridRetrievalHasVerifiableModelIdentity":
        "E5 hybrid identity check",
    "testOversizedEmbeddingDoesNotSilentlyTruncateSource":
        "E5 oversized-input check",
}
ROOT_TEST = "testRootSynchronizesInitialDataSameCountEditsAndDeletion"
E2E_TEST = "testRealGGUFAndEmbeddingProduceCitedResearchOutput"
LEGACY_NATIVE_TEST = "testRealTokenizerPreservesEvidenceAndRepeatedInferenceWorks"

CASE_START = re.compile(r"^Test Case '-\[(?P<class_name>[\w.]+) (?P<test_name>\w+)\]' started\.$")
CASE_END = re.compile(
    r"^Test Case '-\[(?P<class_name>[\w.]+) (?P<test_name>\w+)\]' "
    r"(?P<status>passed|failed|skipped) \((?P<seconds>[\d.]+) seconds\)\.$"
)
SUMMARY = re.compile(
    r"Executed (?P<count>\d+) tests?, with (?P<failures>\d+) failures? "
    r"\((?P<unexpected>\d+) unexpected\) in (?P<case_seconds>[\d.]+) "
    r"\((?P<suite_seconds>[\d.]+)\) seconds"
)
SUITE_START = re.compile(r"^Test Suite '(?:All tests|Selected tests)' started at (.+)\.$")
OBSERVER = re.compile(r"([\d.]+) elapsed -- Testing started completed\.")
FAILURE = re.compile(
    r"error: -\[(?P<class_name>[\w.]+) (?P<test_name>\w+)\] : (?P<message>.+)"
)
BUFFER = re.compile(
    r"^(?:load_tensors|llama_kv_cache|sched_reserve):\s+"
    r"(?P<backend>\S+)\s+(?P<buffer_type>model|KV|compute) buffer size\s*=\s*"
    r"(?P<size_mib>[\d.]+)\s+MiB"
)
PERF = re.compile(r"llama_perf|tokens per second|tokens/s|prompt eval time|eval time\s*=")
STRUCTURED = re.compile(r'"(?:retrievalMS|inferenceMS|sampledPeakMB)"\s*:')


def parse_log(path: Path) -> dict:
    data = path.read_bytes()
    text = data.decode("utf-8")
    cases, failures, buffers, diagnostics = [], [], [], []
    starts = {}
    summaries = []
    observer_seconds = None
    observer_line = None
    started_at = None
    outcome = None
    perf_count = 0
    structured_count = 0
    for line_number, line in enumerate(text.splitlines(), 1):
        case_offset = line.find("Test Case '-[")
        case_line = line[case_offset:] if case_offset >= 0 else line
        if case_offset > 0 and (CASE_START.match(case_line) or CASE_END.match(case_line)):
            diagnostics.append({
                "log": path.name, "line": line_number, "kind": "xctest_interleaved_prefix",
                "message": line,
            })
        if match := CASE_START.match(case_line):
            key = (match["class_name"], match["test_name"])
            if key in starts:
                raise ValueError(f"{path.name}:{line_number}: duplicate active test")
            starts[key] = line_number
        if match := CASE_END.match(case_line):
            key = (match["class_name"], match["test_name"])
            if key not in starts:
                candidates = [
                    active for active in starts
                    if active[1] == key[1] and active[0].replace(".", "") == key[0].replace(".", "")
                ]
                if len(candidates) != 1:
                    raise ValueError(f"{path.name}:{line_number}: test end without unique start")
                key = candidates[0]
                diagnostics.append({
                    "log": path.name, "line": line_number,
                    "kind": "xctest_interleaved_progress",
                    "message": f"Matched active {key[0]} {key[1]}; original: {line}",
                })
            cases.append({
                "log": path.name, **match.groupdict(),
                "class_name": key[0], "raw_end_class_name": match["class_name"],
                "seconds": float(match["seconds"]),
                "start_line": starts.pop(key), "end_line": line_number,
            })
        if match := SUMMARY.search(line):
            summaries.append((line_number, match))
        if match := SUITE_START.match(line):
            started_at = match[1]
        if match := OBSERVER.search(line):
            observer_seconds = float(match[1])
            observer_line = line_number
        if match := FAILURE.search(line):
            failures.append({"log": path.name, "line": line_number, **match.groupdict()})
        if match := BUFFER.match(line):
            buffers.append({
                "log": path.name, "line": line_number, **match.groupdict(),
                "size_mib": float(match["size_mib"]),
            })
        if "check_double_bos_eos:" in line:
            diagnostics.append({"log": path.name, "line": line_number,
                                "kind": "double_bos_warning", "message": line})
        if "load_tensors: offloaded " in line:
            diagnostics.append({"log": path.name, "line": line_number,
                                "kind": "gpu_offload", "message": line})
        perf_count += bool(PERF.search(line))
        structured_count += bool(STRUCTURED.search(line))
        if line.strip() == "** TEST SUCCEEDED **":
            outcome = "passed"
        elif line.strip() == "** TEST FAILED **":
            outcome = "failed"
    if starts or not summaries or not cases or not started_at or outcome is None:
        raise ValueError(f"{path.name}: incomplete XCTest run")
    if "platform=iOS Simulator" not in text:
        raise ValueError(f"{path.name}: expected an explicit iOS Simulator destination")
    summary_line, summary = summaries[-1]
    count = int(summary["count"])
    failed_tests = sum(case["status"] == "failed" for case in cases)
    assertion_failures = int(summary["failures"])
    if len(cases) != count:
        raise ValueError(f"{path.name}: parsed {len(cases)} cases, summary says {count}")
    if assertion_failures != len(failures):
        raise ValueError(f"{path.name}: assertion failure evidence does not reconcile")
    if (outcome == "passed") != (failed_tests == 0 and assertion_failures == 0):
        raise ValueError(f"{path.name}: result marker contradicts test results")
    case_sum = sum(case["seconds"] for case in cases)
    reported_sum = float(summary["case_seconds"])
    if abs(case_sum - reported_sum) > max(0.005, count * 0.001):
        raise ValueError(f"{path.name}: test duration sum does not reconcile")
    suite_seconds = float(summary["suite_seconds"])
    if observer_seconds is None or observer_seconds < suite_seconds:
        raise ValueError(f"{path.name}: missing/invalid test-operation elapsed time")
    return {
        "run": {
            "log": path.name, "label": RUNS.get(path.name, path.stem),
            "started_at_local": started_at, "environment": "iOS Simulator",
            "outcome": outcome, "tests": count,
            "passed_tests": sum(case["status"] == "passed" for case in cases),
            "failed_tests": failed_tests,
            "skipped_tests": sum(case["status"] == "skipped" for case in cases),
            "assertion_failures": assertion_failures,
            "case_seconds_sum": case_sum, "reported_case_seconds": reported_sum,
            "suite_elapsed_seconds": suite_seconds,
            "observer_elapsed_seconds": observer_seconds,
            "observer_minus_suite_seconds": observer_seconds - suite_seconds,
            "summary_line": summary_line, "observer_line": observer_line,
            "native_perf_lines": perf_count, "structured_measurement_lines": structured_count,
        },
        "source": {"log": path.name, "sha256": hashlib.sha256(data).hexdigest(),
                   "bytes": len(data), "line_count": len(text.splitlines())},
        "cases": cases, "failures": failures, "buffers": buffers, "diagnostics": diagnostics,
    }


def timing_group(test_name: str) -> str:
    if test_name in NATIVE_TESTS:
        return "Native E5 checks"
    if test_name == ROOT_TEST:
        return "Hosted corpus synchronization"
    return "Other functional checks"


def save_figure(fig, output: Path, name: str) -> None:
    fig.savefig(output / f"{name}.png", dpi=180, facecolor=fig.get_facecolor())
    svg = output / f"{name}.svg"
    fig.savefig(svg, facecolor=fig.get_facecolor())
    svg.write_text("\n".join(line.rstrip(" \t") for line in svg.read_text(encoding="utf-8").splitlines()) + "\n",
                   encoding="utf-8")
    plt.close(fig)


def make_plots(runs: pd.DataFrame, cases: pd.DataFrame, output: Path) -> None:
    plt.rcParams.update({
        "font.family": "DejaVu Sans", "font.size": 11,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.labelcolor": "#253548", "text.color": "#172435",
        "axes.edgecolor": "#BDCAD7", "figure.facecolor": "#F8FAFC",
        "axes.facecolor": "#F8FAFC", "svg.fonttype": "path",
    })
    pinned = cases.loc[cases["log"].eq(PINNED)].copy()
    pinned["timing_group"] = pinned["test_name"].map(timing_group)
    groups = pinned.groupby("timing_group", sort=False).agg(
        tests=("test_name", "size"), seconds=("seconds", "sum")
    ).sort_values("seconds", ascending=True)
    colors = {"Native E5 checks": "#287D8E", "Hosted corpus synchronization": "#6B7F9C",
              "Other functional checks": "#A0ACBB"}
    fig, ax = plt.subplots(figsize=(11, 5))
    bars = ax.barh(groups.index, groups["seconds"], color=[colors[g] for g in groups.index])
    total = pinned["seconds"].sum()
    for bar, (_, row) in zip(bars, groups.iterrows()):
        ax.text(bar.get_width() + 0.15, bar.get_y() + bar.get_height() / 2,
                f'{row["seconds"]:.3f}s | {int(row["tests"])} tests | {row["seconds"]/total:.1%}',
                va="center", fontsize=11)
    ax.set_xlim(0, groups["seconds"].max() * 1.65)
    ax.set_xlabel("Sum of XCTest case wall times (seconds)")
    ax.set_title("Where the final 36-test regression spends time", loc="left", pad=18, weight="bold")
    fig.text(0.03, 0.025, "Simulator functional checks, not per-request latency. Native checks include load, hashing and assertions.",
             color="#566476", fontsize=10)
    fig.subplots_adjust(left=0.30, right=0.98, bottom=0.17, top=0.85)
    save_figure(fig, output, "01-final-regression-cost")

    fig, (left, right) = plt.subplots(1, 2, figsize=(13, 5),
                                     gridspec_kw={"width_ratios": [2, 1]})
    native = cases.loc[cases["log"].isin([BASE, PINNED, UI])
                       & cases["test_name"].isin(NATIVE_TESTS)].copy()
    labels = list(NATIVE_TESTS)
    run_colors = {BASE: "#A0ACBB", PINNED: "#287D8E", UI: "#C18438"}
    offsets = {BASE: -0.17, PINNED: 0, UI: 0.17}
    for log, group in native.groupby("log", sort=False):
        positions = [labels.index(name) + offsets[log] for name in group["test_name"]]
        left.scatter(group["seconds"], positions, s=60, color=run_colors[log],
                     label=runs.set_index("log").loc[log, "label"])
        for seconds, y in zip(group["seconds"], positions):
            left.annotate(f"{seconds:.3f}", (seconds, y), xytext=(6, 0),
                          textcoords="offset points", va="center", fontsize=9)
    left.set_yticks(range(len(labels)), [NATIVE_TESTS[name] for name in labels])
    left.invert_yaxis()
    left.set_xlim(0, native["seconds"].max() + 1.6)
    left.set_xlabel("XCTest case seconds")
    left.set_title("Native E5 checks: 2-3 observations each", loc="left", fontsize=12)
    left.legend(loc="lower right", fontsize=9)
    e2e = cases.loc[cases["log"].eq(E2E), "seconds"].item()
    right.barh(["Actual RAG E2E"], [e2e], color="#287D8E", height=0.35)
    right.text(e2e / 2, 0, f"{e2e:.3f}s\nn = 1", ha="center", va="center",
               color="white", fontsize=13, weight="bold")
    right.set_xlim(0, 115)
    right.set_ylim(-0.7, 0.7)
    right.set_xlabel("XCTest case seconds")
    right.set_title("Retrieval + actual generation", loc="left", fontsize=12)
    fig.suptitle("Observed native-model test costs", x=0.03, ha="left", weight="bold", fontsize=16)
    fig.text(0.03, 0.03, "Different workloads and separate scales. No isolated inference, cache speedup, or device benchmark is measured.",
             fontsize=10, color="#566476")
    fig.subplots_adjust(left=0.23, right=0.98, bottom=0.18, top=0.81, wspace=0.5)
    save_figure(fig, output, "02-native-check-observations")

    selected = runs.set_index("log").loc[[BASE, PINNED, E2E, UI]].copy()
    fig, ax = plt.subplots(figsize=(11, 5))
    x = range(len(selected))
    ax.bar(x, selected["suite_elapsed_seconds"], color="#287D8E", label="XCTest suite elapsed")
    ax.bar(x, selected["observer_minus_suite_seconds"], bottom=selected["suite_elapsed_seconds"],
           color="#C8D1DD", label="Observer minus suite (not separately profiled)")
    for i, (_, row) in enumerate(selected.iterrows()):
        ax.text(i, row["observer_elapsed_seconds"] + 3, f'{row["observer_elapsed_seconds"]:.3f}s',
                ha="center", weight="bold")
        small = row["suite_elapsed_seconds"] < 15
        label_y = row["suite_elapsed_seconds"] + 6 if small else row["suite_elapsed_seconds"] / 2
        ax.text(i, label_y, f'{row["suite_elapsed_seconds"]:.3f}s',
                ha="center", va="center", color="#253548" if small else "white", fontsize=10)
    ax.set_xticks(list(x), ["E5-base\n36 tests", "Pinned\n36 tests", "RAG E2E\n1 test",
                           "Final research\n17 tests"])
    ax.set_ylim(0, selected["observer_elapsed_seconds"].max() * 1.35)
    ax.set_ylabel("Seconds")
    ax.set_title("Test-operation time is not inference time", loc="left", pad=18, weight="bold")
    ax.legend(loc="upper left", fontsize=10)
    fig.text(0.03, 0.025, "Observer interval is reported by Xcode; it is not the full shell/build duration or app response latency.",
             color="#566476", fontsize=10)
    fig.subplots_adjust(left=0.09, right=0.98, bottom=0.20, top=0.85)
    save_figure(fig, output, "03-timing-boundaries")

    history = runs.set_index("log").loc[
        ["rag-e5-tests.log", "rag-e5-focused.log", BASE, E2E, PINNED, UI]
    ]
    fig, ax = plt.subplots(figsize=(12, 5))
    x = range(len(history))
    ax.bar(x, history["passed_tests"], color="#287D8E", label="Passed test cases")
    ax.bar(x, history["failed_tests"], bottom=history["passed_tests"],
           color="#C18438", label="Failed test cases")
    for i, (_, row) in enumerate(history.iterrows()):
        ax.text(i, row["tests"] + 0.8, f'{int(row["passed_tests"])}/{int(row["tests"])}',
                ha="center", weight="bold")
    ax.set_xticks(list(x), ["Initial E5\nintegration", "Small GGUF\nranking", "E5-base\nregression",
                           "Native RAG\nE2E", "Pinned\nregression", "Final research\nregression"])
    ax.set_ylim(0, 46)
    ax.set_ylabel("Completed test cases")
    ax.set_title("Development failures were retained, then corrected", loc="left", pad=18, weight="bold")
    ax.legend(loc="upper right", fontsize=10)
    fig.text(0.03, 0.025, "Different selections and code/model revisions: test pass counts are not legal accuracy or RAG output success rates.",
             color="#566476", fontsize=10)
    fig.subplots_adjust(left=0.08, right=0.98, bottom=0.20, top=0.85)
    save_figure(fig, output, "04-development-validation")


def analyze(logs_dir: Path, output: Path) -> dict:
    parsed = [parse_log(logs_dir / name) for name in RUNS]
    runs = pd.DataFrame([item["run"] for item in parsed]).sort_values("started_at_local")
    cases = pd.DataFrame([case for item in parsed for case in item["cases"]])
    failures = pd.DataFrame([row for item in parsed for row in item["failures"]])
    buffers = pd.DataFrame([row for item in parsed for row in item["buffers"]])
    diagnostics = pd.DataFrame([row for item in parsed for row in item["diagnostics"]])
    sources = pd.DataFrame([item["source"] for item in parsed])
    pinned = cases.loc[cases["log"].eq(PINNED)].copy()
    pinned["timing_group"] = pinned["test_name"].map(timing_group)
    groups = pinned.groupby("timing_group", as_index=False).agg(
        tests=("test_name", "size"), seconds=("seconds", "sum")
    )
    groups["share_of_case_time"] = groups["seconds"] / pinned["seconds"].sum()
    corrected = cases.loc[cases["log"].isin([BASE, PINNED, UI]) & cases["test_name"].isin(NATIVE_TESTS)]
    native_stats = corrected.groupby("test_name", as_index=False).agg(
        observations=("seconds", "size"), min_seconds=("seconds", "min"),
        max_seconds=("seconds", "max")
    )
    repo = Path(__file__).resolve().parents[1]
    current_tests = []
    test_source_hashes = {}
    # Keep the source cohort of the eleven historical logs separate from later pilots.
    for filename in ("AISYSAppTests.swift", "GGUFEmbeddingTests.swift", "RAGResearchTests.swift"):
        source = repo / "code/ios/AISYSAppTests" / filename
        source_data = source.read_bytes()
        relative = source.relative_to(repo).as_posix()
        test_source_hashes[relative] = hashlib.sha256(source_data).hexdigest()
        for name in re.findall(r"func (test\w+)\(", source_data.decode("utf-8")):
            current_tests.append({"class_name": f"AISYSAppTests.{source.stem}",
                                  "test_name": name, "current_source": relative})
    current = pd.DataFrame(current_tests)
    latest = cases.merge(runs[["log", "started_at_local"]], on="log").sort_values(
        ["started_at_local", "end_line"]
    ).drop_duplicates(["class_name", "test_name"], keep="last")
    coverage = latest.merge(current, on=["class_name", "test_name"], how="outer", validate="one_to_one")
    missing = coverage["log"].isna()
    if missing.any():
        raise ValueError(f"Current tests absent from logs: {coverage.loc[missing, 'test_name'].tolist()}")
    commit = subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
    ).strip()
    summary = {
        "scope": "Simulator XCTest wall time; not physical-device performance",
        "analysis_schema_version": 1,
        "analysis_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "source_commit_at_analysis": commit,
        "versions": {"python": platform.python_version(), "pandas": pd.__version__,
                     "matplotlib": matplotlib.__version__},
        "log_count": len(runs), "completed_case_observations": len(cases),
        "unique_test_methods": len(cases[["class_name", "test_name"]].drop_duplicates()),
        "current_test_method_count": len(current),
        "historical_only_test_method_count": int(coverage["current_source"].isna().sum()),
        "current_test_latest_status": coverage.loc[coverage["current_source"].notna(), "status"]
            .value_counts().to_dict(),
        "current_test_source_sha256": test_source_hashes,
        "passed_case_observations": int(cases["status"].eq("passed").sum()),
        "failed_case_observations": int(cases["status"].eq("failed").sum()),
        "assertion_failure_records": len(failures),
        "latest_observed_status": latest["status"].value_counts().to_dict(),
        "final_case_seconds_sum": float(pinned["seconds"].sum()),
        "final_group_timings": groups.to_dict(orient="records"),
        "corrected_native_checks": native_stats.to_dict(orient="records"),
        "rag_e2e_case_seconds": cases.loc[cases["log"].eq(E2E), "seconds"].item(),
        "rag_e2e_observations": len(cases.loc[cases["log"].eq(E2E)]),
        "raw_token_performance_line_count": int(runs["native_perf_lines"].sum()),
        "structured_measurement_line_count": int(runs["structured_measurement_lines"].sum()),
        "physical_device_log_count": 0,
        "double_bos_warning_records": int(diagnostics["kind"].eq("double_bos_warning").sum()),
        "buffer_unit": "MiB; allocation declarations, not process footprint",
    }
    output.mkdir(parents=True, exist_ok=True)
    for name, frame in {
        "runs": runs, "test_cases": cases, "failure_evidence": failures,
        "native_buffer_events": buffers, "diagnostics": diagnostics,
        "sources": sources, "test_method_coverage": coverage,
        "final_group_timings": groups, "native_check_observations": native_stats,
    }.items():
        frame.to_csv(output / f"{name}.csv", index=False, float_format="%.6f")
    (output / "analysis_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8"
    )
    make_plots(runs, cases, output)
    print(runs[["log", "tests", "failed_tests", "assertion_failures",
                "suite_elapsed_seconds", "observer_elapsed_seconds"]].to_string(index=False))
    print("\n" + json.dumps(summary, ensure_ascii=False, indent=2, allow_nan=False))
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    analyze(args.logs_dir, args.output_dir)


if __name__ == "__main__":
    main()
