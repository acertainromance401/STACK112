from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class HallucinationRule:
    key: str
    description: str


HALLUCINATION_RULES: tuple[HallucinationRule, ...] = (
    HallucinationRule(
        key="must_have_citation",
        description="Every legal claim must map to at least one citation case_number.",
    ),
    HallucinationRule(
        key="citation_must_exist_in_retrieval",
        description="All cited case_number values must be present in retrieved evidence.",
    ),
    HallucinationRule(
        key="no_unsupported_numeric_facts",
        description="Do not include unsupported dates, article numbers, or percentages.",
    ),
    HallucinationRule(
        key="uncertainty_on_missing_evidence",
        description="When evidence is insufficient, output an explicit uncertainty statement.",
    ),
    HallucinationRule(
        key="quote_must_match_snippet",
        description="Quoted text should be a direct or near-direct match to evidence snippet.",
    ),
)


def _quote_overlaps_snippets(quote: str, snippets: list[str], min_run: int = 8) -> bool:
    """Return True if a quote shares a non-trivial substring with any snippet."""
    if not quote or not snippets:
        return False
    cleaned = quote.strip()
    if len(cleaned) < min_run:
        return False
    # Try a sliding window of `min_run` characters: cheap proxy for direct quotation.
    for snippet in snippets:
        if not snippet:
            continue
        for start in range(0, len(cleaned) - min_run + 1):
            if cleaned[start : start + min_run] in snippet:
                return True
    return False


def validate_grounded_answer(
    answer_text: str,
    cited_case_numbers: list[str],
    retrieved_case_numbers: set[str],
    cited_quotes: list[str] | None = None,
    retrieved_snippets: list[str] | None = None,
) -> list[str]:
    """Return violated rule keys for lightweight server-side checks."""

    violations: list[str] = []

    if not cited_case_numbers:
        violations.append("must_have_citation")

    if cited_case_numbers and not set(cited_case_numbers).issubset(retrieved_case_numbers):
        violations.append("citation_must_exist_in_retrieval")

    lowered = answer_text.lower()
    if "unknown" in lowered and "insufficient" not in lowered:
        violations.append("uncertainty_on_missing_evidence")

    if cited_quotes and retrieved_snippets:
        unmatched = [q for q in cited_quotes if q and not _quote_overlaps_snippets(q, retrieved_snippets)]
        if unmatched:
            violations.append("quote_must_match_snippet")

    return violations
