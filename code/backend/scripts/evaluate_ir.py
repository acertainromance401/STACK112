#!/usr/bin/env python3
"""IR 추출 품질을 빠르게 점검하는 스크립트.

입력 형식(JSONL):
{"id":"sample-1","text":"...판례 텍스트..."}
{"id":"sample-2","text":"..."}

출력:
- 샘플별 지표(JSONL)
- 전체 평균 지표(JSON)
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from statistics import mean
from typing import Any

from app.ir_pipeline import (
    count_legal_signals,
    extract_key_sentences,
    extract_legal_keyphrases,
    normalize_legal_text,
)


def _safe_div(numerator: float, denominator: float) -> float:
    if denominator == 0:
        return 0.0
    return numerator / denominator


def evaluate_sample(sample_id: str, text: str, top_keywords: int, top_sentences: int) -> dict[str, Any]:
    normalized = normalize_legal_text(text)
    keywords = extract_legal_keyphrases(normalized, top_n=top_keywords)
    key_sentences = extract_key_sentences(normalized, top_n=top_sentences)

    original_signals = count_legal_signals(normalized)
    summary_signals = count_legal_signals(key_sentences)

    original_total = sum(original_signals.values())
    summary_total = sum(summary_signals.values())
    retention = _safe_div(summary_total, original_total)

    return {
        "id": sample_id,
        "keywords": keywords,
        "key_sentences": key_sentences,
        "original_signals": original_signals,
        "summary_signals": summary_signals,
        "signal_retention": round(retention, 4),
    }


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            obj = json.loads(stripped)
            if "text" not in obj:
                raise ValueError(f"line {line_no}: missing 'text'")
            if "id" not in obj:
                obj["id"] = f"row-{line_no}"
            rows.append(obj)
    return rows


def summarize(results: list[dict[str, Any]]) -> dict[str, Any]:
    if not results:
        return {
            "samples": 0,
            "avg_signal_retention": 0.0,
            "avg_keyword_count": 0.0,
            "avg_key_sentence_length": 0.0,
        }

    return {
        "samples": len(results),
        "avg_signal_retention": round(mean(r["signal_retention"] for r in results), 4),
        "avg_keyword_count": round(mean(len(r["keywords"]) for r in results), 2),
        "avg_key_sentence_length": round(mean(len(r["key_sentences"]) for r in results), 2),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate IR extraction quality for legal-text signals")
    parser.add_argument("--input", required=True, help="Path to input JSONL file")
    parser.add_argument("--output", default="", help="Path to output JSON file (summary)")
    parser.add_argument("--per-sample", default="", help="Optional output JSONL path for per-sample results")
    parser.add_argument("--top-keywords", type=int, default=10)
    parser.add_argument("--top-sentences", type=int, default=5)
    args = parser.parse_args()

    input_path = Path(args.input)
    rows = load_jsonl(input_path)

    results = [
        evaluate_sample(
            sample_id=str(row.get("id", "")),
            text=str(row.get("text", "")),
            top_keywords=args.top_keywords,
            top_sentences=args.top_sentences,
        )
        for row in rows
    ]

    summary = summarize(results)

    if args.per_sample:
        per_sample_path = Path(args.per_sample)
        per_sample_path.parent.mkdir(parents=True, exist_ok=True)
        with per_sample_path.open("w", encoding="utf-8") as f:
            for item in results:
                f.write(json.dumps(item, ensure_ascii=False) + "\n")

    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
