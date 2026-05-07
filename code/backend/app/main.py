from contextlib import asynccontextmanager
from datetime import datetime, timezone
from threading import Lock
from time import time

from fastapi import FastAPI, HTTPException, Query

from .database import close_pool, get_conn
from .schemas import (
    CaseItem,
    Citation,
    GroundedAnswerRequest,
    GroundedAnswerResponse,
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
    build_study_focus,
    build_tfidf_matrix,
    extract_key_sentences,
    extract_legal_keyphrases,
    find_similar_cases,
    infer_study_domain,
    normalize_legal_text,
)
from .grounding import validate_grounded_answer


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    try:
        yield
    finally:
        close_pool()


app = FastAPI(title="AI_SYS API", version="0.1.0", lifespan=_lifespan)

_SIMILAR_INDEX_CACHE: dict[str, object] = {
    "built_at": 0.0,
    "tfidf_df": None,
    "case_ids": set(),
}
_SIMILAR_INDEX_TTL_SECONDS = 300
_SIMILAR_INDEX_LOCK = Lock()


def _escape_like(value: str) -> str:
    """Escape LIKE wildcards so user input does not act as a wildcard pattern."""
    if not value:
        return ""
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _build_case_snippet(issue: str | None, holding: str | None, exam: str | None, limit: int = 220) -> str:
    joined = " ".join(x.strip() for x in [issue or "", holding or "", exam or ""] if x and x.strip())
    if not joined:
        return "요약 정보 부족"
    return joined[:limit]


def _retrieve_grounded_cases(question: str, top_k: int) -> list[dict[str, str]]:
    normalized = normalize_legal_text(question)
    if not normalized or len(normalized) < 2:
        return []
    keyphrases = extract_legal_keyphrases(normalized, top_n=6)
    case_no_match = None
    for token in keyphrases:
        if any(ch.isdigit() for ch in token):
            case_no_match = token
            break

    like_query = f"%{_escape_like(normalized[:80])}%"
    keyphrase_filters = [f"%{_escape_like(kw)}%" for kw in keyphrases[:3]]

    sql = """
        SELECT
            c.case_number,
            c.case_name,
            c.subject,
            c.issue_summary,
            c.holding_summary,
            c.exam_points,
            c.source_url,
            (
                CASE WHEN %(case_no)s IS NOT NULL AND c.case_number ILIKE %(case_no_like)s THEN 8 ELSE 0 END
              + CASE WHEN c.case_name ILIKE %(q_like)s THEN 4 ELSE 0 END
              + CASE WHEN c.issue_summary ILIKE %(q_like)s THEN 3 ELSE 0 END
              + CASE WHEN c.holding_summary ILIKE %(q_like)s THEN 3 ELSE 0 END
              + CASE WHEN c.exam_points ILIKE %(q_like)s THEN 2 ELSE 0 END
              + CASE WHEN %(kw1)s <> '' AND (
                    c.issue_summary ILIKE %(kw1)s OR c.holding_summary ILIKE %(kw1)s OR c.exam_points ILIKE %(kw1)s
                ) THEN 2 ELSE 0 END
              + CASE WHEN %(kw2)s <> '' AND (
                    c.issue_summary ILIKE %(kw2)s OR c.holding_summary ILIKE %(kw2)s OR c.exam_points ILIKE %(kw2)s
                ) THEN 1 ELSE 0 END
              + CASE WHEN %(kw3)s <> '' AND (
                    c.issue_summary ILIKE %(kw3)s OR c.holding_summary ILIKE %(kw3)s OR c.exam_points ILIKE %(kw3)s
                ) THEN 1 ELSE 0 END
            ) AS relevance
        FROM published_cases c
        WHERE
            c.case_name ILIKE %(q_like)s
            OR c.issue_summary ILIKE %(q_like)s
            OR c.holding_summary ILIKE %(q_like)s
            OR c.exam_points ILIKE %(q_like)s
            OR (%(case_no)s IS NOT NULL AND c.case_number ILIKE %(case_no_like)s)
        ORDER BY relevance DESC, c.updated_at DESC
        LIMIT %(limit)s
    """

    params = {
        "q_like": like_query,
        "case_no": case_no_match,
        "case_no_like": f"%{_escape_like(case_no_match)}%" if case_no_match else None,
        "kw1": keyphrase_filters[0] if len(keyphrase_filters) > 0 else "",
        "kw2": keyphrase_filters[1] if len(keyphrase_filters) > 1 else "",
        "kw3": keyphrase_filters[2] if len(keyphrase_filters) > 2 else "",
        "limit": max(1, min(top_k, 10)),
    }

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            rows = cur.fetchall()

    return [
        {
            "case_number": row[0],
            "case_name": row[1],
            "subject": row[2] or "",
            "issue_summary": row[3] or "",
            "holding_summary": row[4] or "",
            "exam_points": row[5] or "",
            "source_url": row[6] or "",
            "relevance": str(row[7]),
        }
        for row in rows
    ]


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
            cur.execute(sql, {"q_like": f"%{_escape_like(q)}%", "limit": limit})
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

    normalized = normalize_legal_text(body.text)
    if not normalized:
        return IRExtractResponse(keywords=[], key_sentences="")

    keywords = extract_legal_keyphrases(normalized, top_n=body.top_keywords)
    key_sentences = extract_key_sentences(normalized, top_n=body.top_sentences)
    domain = infer_study_domain(normalized, keywords)
    study_focus = build_study_focus(domain, keywords, key_sentences)

    return IRExtractResponse(
        keywords=keywords,
        key_sentences=key_sentences,
        domain=domain,
        study_focus=study_focus,
    )


@app.get("/cases/{case_number}/similar", response_model=SimilarCasesResponse)
def similar_cases(
    case_number: str,
    top_k: int = Query(5, ge=1, le=20),
) -> SimilarCasesResponse:
    """특정 판례와 TF-IDF 코사인 유사도가 높은 판례를 반환합니다."""

    with _SIMILAR_INDEX_LOCK:
        cache_age = time() - float(_SIMILAR_INDEX_CACHE["built_at"])
        cached_tfidf = _SIMILAR_INDEX_CACHE["tfidf_df"]
        cached_case_ids = _SIMILAR_INDEX_CACHE["case_ids"]
        cache_valid = (
            cached_tfidf is not None
            and isinstance(cached_case_ids, set)
            and cache_age <= _SIMILAR_INDEX_TTL_SECONDS
        )

    if cache_valid:
        if case_number not in cached_case_ids:  # type: ignore[operator]
            raise HTTPException(status_code=404, detail="Case not found or not published")

        results = find_similar_cases(case_number, cached_tfidf, top_k=top_k)  # type: ignore[arg-type]
        return SimilarCasesResponse(
            case_number=case_number,
            total=len(results),
            items=results,
        )

    # DB에서 published 판례 전체 텍스트 로드
    sql = """
        SELECT case_number, case_name, subject, issue_summary, holding_summary, exam_points
        FROM published_cases
        WHERE issue_summary IS NOT NULL
        ORDER BY updated_at DESC
        LIMIT 700
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
            "full_text": normalize_legal_text(" ".join(filter(None, [row[1], row[2], row[3], row[4], row[5]]))),
        }
        for row in rows
    ]

    subject_by_case = {row[0]: (row[2] or "") for row in rows}
    query_subject = subject_by_case.get(case_number, "")

    if not any(c["case_id"] == case_number for c in cases):
        raise HTTPException(status_code=404, detail="Case not found or not published")

    tfidf_df, _ = build_tfidf_matrix(cases)

    with _SIMILAR_INDEX_LOCK:
        _SIMILAR_INDEX_CACHE["built_at"] = time()
        _SIMILAR_INDEX_CACHE["tfidf_df"] = tfidf_df
        _SIMILAR_INDEX_CACHE["case_ids"] = {c["case_id"] for c in cases}

    rough_results = find_similar_cases(case_number, tfidf_df, top_k=min(top_k * 3, 20))

    reranked = []
    for item in rough_results:
        score = float(item["similarity"])
        if query_subject and subject_by_case.get(item["case_id"], "") == query_subject:
            score += 0.03
        reranked.append({**item, "similarity": score})

    reranked.sort(key=lambda x: x["similarity"], reverse=True)
    results = [
        {
            "case_id": item["case_id"],
            "similarity": round(float(item["similarity"]), 4),
            "rank": idx + 1,
        }
        for idx, item in enumerate(reranked[:top_k])
    ]

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

    fallback_keywords = body.keywords or extract_legal_keyphrases(
        f"{body.case_name} {body.key_sentences}",
        top_n=5,
    )
    sentences = [s.strip() for s in body.key_sentences.split("\n") if s.strip()]
    key_issue = fallback_keywords[0] if fallback_keywords else "핵심 쟁점 확인 필요"
    ruling_point = sentences[0] if sentences else "핵심 문장 정보가 부족합니다."

    # 현재는 규칙 기반으로 응답 구성 (Llama 연동 전 폴백)
    # 추후 LlamaCppEngine 서버 사이드 연동 시 이 블록을 교체합니다.
    if fallback_keywords:
        summary_text = (
            f"{body.case_name} 판례는 다음 핵심 쟁점을 다룹니다: "
            f"{', '.join(fallback_keywords[:3])}."
        )
    else:
        summary_text = f"{body.case_name} 판례의 핵심 쟁점은 제공된 문장 중심으로 확인이 필요합니다."

    quiz_items: list[OXQuizItem] = []
    # O/X를 섞어 출제 — 모두 정답이면 학습 가치가 없음
    safe_flip_pairs = (
        ("해당한다", "해당하지 않는다"),
        ("인정된다", "인정되지 않는다"),
        ("적용된다", "적용되지 않는다"),
        ("성립한다", "성립하지 않는다"),
        ("위법하다", "적법하다"),
        ("적법하다", "위법하다"),
    )

    def _safe_negate(text: str) -> str | None:
        for pos, neg in safe_flip_pairs:
            if pos in text and neg not in text:
                return text.replace(pos, neg, 1)
        return None

    for i, sentence in enumerate(sentences[: body.quiz_count]):
        statement = sentence[:120]
        # 짝수 인덱스는 원문 그대로(O), 홀수 인덱스는 안전 부정(X)
        if i % 2 == 0:
            quiz_items.append(
                OXQuizItem(
                    statement=statement,
                    answer=True,
                    explanation=f"[{body.case_number}] 판결문 핵심 문장에서 직접 도출된 내용입니다.",
                )
            )
        else:
            negated = _safe_negate(statement)
            if negated is not None:
                quiz_items.append(
                    OXQuizItem(
                        statement=negated[:120],
                        answer=False,
                        explanation=f"[{body.case_number}] 판결의 결론과 반대 방향의 진술입니다.",
                    )
                )
            else:
                # 안전한 부정 패턴이 없으면 명백히 거짓인 메타 진술로 X 출제
                quiz_items.append(
                    OXQuizItem(
                        statement=f"본 판례의 결론은 「{statement[:60]}」와 정반대이다",
                        answer=False,
                        explanation=f"[{body.case_number}] 원문 결론을 뒤집은 함정 진술입니다.",
                    )
                )

    if not quiz_items and fallback_keywords:
        quiz_items = [
            OXQuizItem(
                statement=f"{fallback_keywords[0]}는(은) 본 판례의 핵심 쟁점이다.",
                answer=True,
                explanation=f"[{body.case_number}] 키워드 기반으로 도출된 핵심 쟁점입니다.",
            )
        ]

    citations = [s[:180] for s in sentences[:3]]

    return LLMSummarizeResponse(
        case_number=body.case_number,
        one_line_summary=summary_text,
        key_issue=key_issue,
        ruling_point=ruling_point,
        exam_takeaway=f"시험 포인트: {', '.join(fallback_keywords[:5])}",
        quiz=quiz_items,
        citations=citations,
    )


@app.post("/grounded/answer", response_model=GroundedAnswerResponse)
def grounded_answer(body: GroundedAnswerRequest) -> GroundedAnswerResponse:
    """근거 기반 답변 생성: 강의 대체가 아닌 복습/비교용 짧은 답변을 제공합니다."""
    if not body.question or not body.question.strip() or len(body.question.strip()) < 2:
        raise HTTPException(status_code=400, detail="질문이 너무 짧습니다 (2자 이상 필요)")
    retrieved = _retrieve_grounded_cases(body.question, body.top_k)
    if not retrieved:
        return GroundedAnswerResponse(
            question=body.question,
            answer="근거 데이터가 부족하여 단정하기 어렵습니다. 사건번호 또는 핵심 쟁점 키워드로 다시 검색해 주세요.",
            citations=[],
            safety_flags=["insufficient_evidence"],
            domain="general_legal",
            generated_at=datetime.now(timezone.utc),
        )

    citations = []
    for c in retrieved[: max(1, min(body.top_k, 4))]:
        snippet = _build_case_snippet(c["issue_summary"], c["holding_summary"], c["exam_points"])  # type: ignore[arg-type]
        citations.append(
            Citation(
                case_number=c["case_number"],
                case_name=c["case_name"],
                quoted_text=snippet,
                reason="질문 키워드와 쟁점/결론 문장 유사도 기반",
            )
        )

    merged_text = "\n".join(
        [
            f"{c['case_number']} {c['case_name']} {c['subject']} {c['issue_summary']} {c['holding_summary']} {c['exam_points']}"
            for c in retrieved[:3]
        ]
    )
    inferred_domain = infer_study_domain(merged_text, [c["subject"] for c in retrieved])

    if body.intent == "compare" and len(retrieved) >= 2:
        left = retrieved[0]
        right = retrieved[1]
        answer = (
            "비교 요약(강의 대체 아님):\n"
            f"- 공통점: {left['subject']} 범위에서 쟁점 판단 구조가 유사합니다.\n"
            f"- 차이점: [{left['case_number']}]는 {str(left['holding_summary'])[:70]} / "
            f"[{right['case_number']}]는 {str(right['holding_summary'])[:70]}\n"
            "- 복습 포인트: 결론만 외우지 말고 쟁점-근거-결론 순서로 암기하세요."
        )
    elif body.intent == "quiz":
        pivot = retrieved[0]
        answer = (
            "훈련용 체크포인트:\n"
            f"- [{pivot['case_number']}]에서 핵심 쟁점을 한 문장으로 말해보기\n"
            "- 유사 판례와 결론이 달라지는 요건 1개 찾기\n"
            "- OX로 변형: 결론 문장을 한 글자 바꿔 틀린 지문 만들기"
        )
    else:
        pivot = retrieved[0]
        answer = (
            "근거 기반 요약(강의 대체 아님):\n"
            f"- 사건: [{pivot['case_number']}] {pivot['case_name']}\n"
            f"- 쟁점: {str(pivot['issue_summary'])[:90]}\n"
            f"- 결론: {str(pivot['holding_summary'])[:90]}\n"
            "- 복습: 헷갈리는 포인트는 유사판례 비교/OX 반복으로 확인"
        )

    retrieved_case_set = {c["case_number"] for c in retrieved}
    retrieved_snippets = [
        _build_case_snippet(c["issue_summary"], c["holding_summary"], c["exam_points"])
        for c in retrieved
    ]
    cited_case_numbers = [c.case_number for c in citations]
    cited_quotes = [c.quoted_text for c in citations]
    violations = validate_grounded_answer(
        answer,
        cited_case_numbers,
        retrieved_case_set,
        cited_quotes=cited_quotes,
        retrieved_snippets=retrieved_snippets,
    )

    if not citations:
        violations.append("insufficient_citation")

    return GroundedAnswerResponse(
        question=body.question,
        answer=answer,
        citations=citations,
        safety_flags=violations,
        domain=inferred_domain,
        generated_at=datetime.now(timezone.utc),
    )

