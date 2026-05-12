# AI_SYS LLM Hybrid Contract

최종 업데이트: 2026-05-07 (v1.2)

This document defines the three implementation artifacts for AI_SYS:
1. Search response JSON schema with evidence fields
2. App-side LLM prompt templates
3. Hallucination prevention rules

Current status note:
- iOS 앱은 온디바이스 llama.cpp 기반 요약/퀴즈 생성 경로를 사용한다.
- 대시보드 API는 /dashboard/recommended, /dashboard/wrong-answers를 기준으로 운영한다.

## 1) Search Response JSON Schema (Evidence Included)

Primary backend models are implemented in:
- code/backend/app/schemas.py

### Response shape (v2)

```json
{
  "query": "string",
  "normalized_query": "string",
  "total": 3,
  "items": [
    {
      "id": "uuid-string",
      "case_number": "2022do12345",
      "case_name": "case name",
      "court_name": "court",
      "decision_date": "2022-05-12",
      "subject": "criminal procedure",
      "issue_summary": "...",
      "holding_summary": "...",
      "exam_points": "...",
      "source_url": "https://...",
      "updated_at": "2026-04-15T12:00:00Z"
    }
  ],
  "evidence": [
    {
      "rank": 1,
      "case_number": "2022do12345",
      "case_name": "case name",
      "snippet": "matched text snippet",
      "matched_fields": ["case_name", "issue_summary"],
      "relevance_score": 0.92,
      "source_url": "https://..."
    }
  ],
  "generated_at": "2026-04-15T12:00:00Z"
}
```

## 2) App-LLM Input Templates

Implemented in:
- code/ios/AISYSApp/Sources/PromptTemplates.swift

Included templates:
- summarize(...)
- compare(...)
- quiz(...)

Template design principles:
- strict role/task/rules separation
- evidence-first input block
- fixed output format for parser stability
- explicit "insufficient evidence" handling

## 3) Hallucination Prevention Rules

Implemented in:
- code/backend/app/grounding.py

Rules:
- must_have_citation
- citation_must_exist_in_retrieval
- no_unsupported_numeric_facts
- uncertainty_on_missing_evidence
- quote_must_match_snippet

Server helper:
- validate_grounded_answer(answer_text, cited_case_numbers, retrieved_case_numbers)

Use this helper after model generation and before returning responses.
If violations exist, return safe fallback output with explicit uncertainty and citation request.
