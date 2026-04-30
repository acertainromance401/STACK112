from fastapi import FastAPI, HTTPException, Query
from .database import get_conn
from .schemas import (
    CaseItem,
    HealthResponse,
    IRExtractRequest,
    IRExtractResponse,
    LLMSummarizeRequest,
    LLMSummarizeResponse,
    OXQuizItem,
    RecommendedCasesResponse,
    SearchResponse,
    SimilarCasesResponse,
    WrongAnswersResponse,
)
from .ir_pipeline import (
    build_tfidf_matrix,
    extract_key_sentences,
    extract_keywords,
    find_similar_cases,
)

app = FastAPI(title="AI_SYS API", version="0.1.0")


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok")


@app.get("/cases/{case_number}", response_model=CaseItem)
def get_case(case_number: str) -> CaseItem:
    sql = """
        SELECT
            id::text,
            case_number,
            case_name,
            court_name,
            decision_date,
            subject,
            issue_summary,
            holding_summary,
            exam_points,
            source_url,
            updated_at
        FROM published_cases
        WHERE case_number = %(case_number)s
        LIMIT 1
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, {"case_number": case_number})
            row = cur.fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="Case not found or not published")

    return CaseItem(
        id=row[0],
        case_number=row[1],
        case_name=row[2],
        court_name=row[3],
        decision_date=row[4],
        subject=row[5],
        issue_summary=row[6],
        holding_summary=row[7],
        exam_points=row[8],
        source_url=row[9],
        updated_at=row[10],
    )


@app.get("/search", response_model=SearchResponse)
def search_cases(
    q: str = Query(..., min_length=1, description="사건번호 또는 키워드"),
    limit: int = Query(10, ge=1, le=50),
) -> SearchResponse:
    sql = """
        SELECT
            c.id::text,
            c.case_number,
            c.case_name,
            c.court_name,
            c.decision_date,
            c.subject,
            c.issue_summary,
            c.holding_summary,
            c.exam_points,
            c.source_url,
            c.updated_at
        FROM cases c
        LEFT JOIN case_keywords k ON c.id = k.case_id
        WHERE c.status = 'published'
          AND (
              c.case_number ILIKE %(q_like)s
              OR c.case_name ILIKE %(q_like)s
              OR c.issue_summary ILIKE %(q_like)s
              OR k.keyword ILIKE %(q_like)s
          )
        GROUP BY
            c.id,
            c.case_number,
            c.case_name,
            c.court_name,
            c.decision_date,
            c.subject,
            c.issue_summary,
            c.holding_summary,
            c.exam_points,
            c.source_url,
            c.updated_at
        ORDER BY c.updated_at DESC
        LIMIT %(limit)s
    """

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, {"q_like": f"%{q}%", "limit": limit})
            rows = cur.fetchall()

    items = [
        CaseItem(
            id=row[0],
            case_number=row[1],
            case_name=row[2],
            court_name=row[3],
            decision_date=row[4],
            subject=row[5],
            issue_summary=row[6],
            holding_summary=row[7],
            exam_points=row[8],
            source_url=row[9],
            updated_at=row[10],
        )
        for row in rows
    ]
    return SearchResponse(total=len(items), items=items)


@app.get("/cases", response_model=SearchResponse)
def list_cases(limit: int = Query(20, ge=1, le=100)) -> SearchResponse:
    sql = """
        SELECT
            id::text,
            case_number,
            case_name,
            court_name,
            decision_date,
            subject,
            issue_summary,
            holding_summary,
            exam_points,
            source_url,
            updated_at
        FROM published_cases
        ORDER BY updated_at DESC
        LIMIT %(limit)s
    """

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, {"limit": limit})
            rows = cur.fetchall()

    items = [
        CaseItem(
            id=row[0],
            case_number=row[1],
            case_name=row[2],
            court_name=row[3],
            decision_date=row[4],
            subject=row[5],
            issue_summary=row[6],
            holding_summary=row[7],
            exam_points=row[8],
            source_url=row[9],
            updated_at=row[10],
        )
        for row in rows
    ]
    return SearchResponse(total=len(items), items=items)


@app.get("/dashboard/recommended", response_model=RecommendedCasesResponse)
def dashboard_recommended(limit: int = Query(7, ge=1, le=30)) -> RecommendedCasesResponse:
    sql = """
        WITH ranked AS (
            SELECT
                case_number,
                case_name,
                subject,
                COALESCE(issue_summary, '핵심 쟁점 요약 없음') AS issue,
                ROW_NUMBER() OVER (ORDER BY updated_at DESC) AS rn
            FROM published_cases
        )
        SELECT
            case_number,
            case_name,
            subject,
            issue,
            35 + ((rn * 7) %% 55) AS accuracy
        FROM ranked
        ORDER BY rn
        LIMIT %(limit)s
    """

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, {"limit": limit})
            rows = cur.fetchall()

    items = [
        {
            "case_number": row[0],
            "case_name": row[1],
            "subject": row[2],
            "issue": row[3],
            "accuracy": int(row[4]),
        }
        for row in rows
    ]
    return RecommendedCasesResponse(total=len(items), items=items)


@app.get("/dashboard/wrong-answers", response_model=WrongAnswersResponse)
def dashboard_wrong_answers(
    user_id: str = Query(..., min_length=1),
    limit: int = Query(20, ge=1, le=100),
) -> WrongAnswersResponse:
    sql = """
        SELECT
            CONCAT(c.case_number, ' ', c.case_name) AS title,
            COALESCE(h.note, c.issue_summary, '메모 없음') AS memo,
            TO_CHAR(COALESCE(h.solved_at, h.created_at), 'YYYY.MM.DD') AS solved_date
        FROM user_case_history h
        JOIN cases c ON c.id = h.case_id
        WHERE h.user_id = %(user_id)s
          AND h.is_wrong_answer = TRUE
        ORDER BY COALESCE(h.solved_at, h.created_at) DESC
        LIMIT %(limit)s
    """

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, {"user_id": user_id, "limit": limit})
            rows = cur.fetchall()

    items = [
        {
            "title": row[0],
            "memo": row[1],
            "date": row[2],
        }
        for row in rows
    ]
    return WrongAnswersResponse(total=len(items), items=items)


# ---------------------------------------------------------------------------
# IR 파이프라인 엔드포인트
# ---------------------------------------------------------------------------

@app.post("/ir/extract", response_model=IRExtractResponse)
def ir_extract(body: IRExtractRequest) -> IRExtractResponse:
    """OCR 텍스트 → 키워드 + 핵심 문장 반환.
    Swift OCRView에서 스캔한 텍스트를 전송하면 Llama 입력용으로 축약합니다."""

    # IDF는 단일 문서이므로 코퍼스 없이 단어 빈도만으로 계산
    # (DB 판례 전체를 인덱싱한 tfidf_df가 없는 환경에서도 동작)
    from .ir_pipeline import tokenize
    import numpy as np
    import pandas as pd

    tokens = tokenize(body.text)
    if not tokens:
        return IRExtractResponse(keywords=[], key_sentences="")

    doc_len = len(tokens)
    term_counts: dict[str, int] = {}
    for t in tokens:
        term_counts[t] = term_counts.get(t, 0) + 1

    # 단일 문서이므로 IDF=1 고정, TF만으로 키워드 순위 결정
    tf_scores = {t: c / doc_len for t, c in term_counts.items()}
    sorted_kw = sorted(tf_scores.items(), key=lambda x: x[1], reverse=True)
    keywords = [kw for kw, _ in sorted_kw[: body.top_keywords]]

    key_sentences = extract_key_sentences(body.text, top_n=body.top_sentences)

    return IRExtractResponse(keywords=keywords, key_sentences=key_sentences)


@app.get("/cases/{case_number}/similar", response_model=SimilarCasesResponse)
def similar_cases(
    case_number: str,
    top_k: int = Query(5, ge=1, le=20),
) -> SimilarCasesResponse:
    """특정 판례와 TF-IDF 코사인 유사도가 높은 판례를 반환합니다."""

    # DB에서 published 판례 전체 텍스트 로드
    sql = """
        SELECT case_number, issue_summary, holding_summary, exam_points
        FROM published_cases
        WHERE issue_summary IS NOT NULL
        ORDER BY updated_at DESC
        LIMIT 500
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()

    if not rows:
        raise HTTPException(status_code=404, detail="판례 데이터가 없습니다")

    cases = [
        {
            "case_id": row[0],
            "full_text": " ".join(filter(None, [row[1], row[2], row[3]])),
        }
        for row in rows
    ]

    if not any(c["case_id"] == case_number for c in cases):
        raise HTTPException(status_code=404, detail="Case not found or not published")

    tfidf_df, _ = build_tfidf_matrix(cases)
    results = find_similar_cases(case_number, tfidf_df, top_k=top_k)

    return SimilarCasesResponse(
        case_number=case_number,
        total=len(results),
        items=results,
    )


# ---------------------------------------------------------------------------
# LLM 요약 / OX 퀴즈 엔드포인트
# ---------------------------------------------------------------------------

@app.post("/llm/summarize", response_model=LLMSummarizeResponse)
def llm_summarize(body: LLMSummarizeRequest) -> LLMSummarizeResponse:
    """핵심 문장 + 키워드 → Llama 요약 및 OX 퀴즈 생성.
    Swift LLMService는 이 엔드포인트 대신 로컬 추론도 가능하지만,
    백엔드 호출 시 이 엔드포인트가 [EVIDENCE] 블록을 구성하여 응답합니다."""

    from .schemas import PromptTemplates  # noqa: F401 — 존재 시 사용
    import re

    evidence_block = (
        f"case_number: {body.case_number}\n"
        f"case_name: {body.case_name}\n"
        f"keywords: {', '.join(body.keywords)}\n"
        f"key_sentences:\n{body.key_sentences}"
    )

    # 현재는 규칙 기반으로 응답 구성 (Llama 연동 전 폴백)
    # 추후 LlamaCppEngine 서버 사이드 연동 시 이 블록을 교체합니다.
    summary_text = (
        f"{body.case_name} 판례는 다음 핵심 쟁점을 다룹니다: "
        f"{', '.join(body.keywords[:3])}."
    )

    quiz_items: list[OXQuizItem] = []
    sentences = [s.strip() for s in body.key_sentences.split("\n") if s.strip()]
    for i, sentence in enumerate(sentences[: body.quiz_count]):
        quiz_items.append(
            OXQuizItem(
                statement=sentence[:120],
                answer=True,
                explanation=f"[{body.case_number}] 판결문 핵심 문장에서 직접 도출된 내용입니다.",
            )
        )

    return LLMSummarizeResponse(
        case_number=body.case_number,
        one_line_summary=summary_text,
        key_issue=body.keywords[0] if body.keywords else "",
        ruling_point=sentences[0] if sentences else "",
        exam_takeaway=f"시험 포인트: {', '.join(body.keywords[:5])}",
        quiz=quiz_items,
    )

