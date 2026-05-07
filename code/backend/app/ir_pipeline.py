"""
ir_pipeline.py
한국어 판례 텍스트를 대상으로 TF-IDF 기반 정보검색 파이프라인을 제공합니다.

주요 기능:
- 한국어 형태소 분석 (KoNLPy Okt)
- TF-IDF 행렬 구성
- 코사인 유사도 기반 유사 판례 검색
- TF-IDF 기반 키워드 추출
- TextRank 기반 핵심 문장 추출 (LLM 입력용 축약)
"""

from __future__ import annotations

import re
from collections import Counter
from typing import Any

import numpy as np

try:
    import pandas as pd
except Exception:
    pd = None  # type: ignore[assignment]

try:
    from sklearn.metrics.pairwise import cosine_similarity
except Exception:
    cosine_similarity = None  # type: ignore[assignment]

try:
    from konlpy.tag import Okt
    _okt = Okt()
    _USE_OKT = True
except Exception:
    # konlpy 미설치 환경(CI, 테스트)에서는 단순 공백 분리로 폴백
    _USE_OKT = False

# 한국어 불용어 (법률 문서 기준 최소 집합)
_STOPWORDS: frozenset[str] = frozenset({
    "이", "가", "은", "는", "을", "를", "의", "에", "에서", "로", "으로",
    "와", "과", "도", "만", "에게", "한", "하여", "하고", "하는", "있는",
    "그", "및", "또는", "등", "위", "위한", "따라", "대한", "관한",
    "있다", "없다", "된다", "한다", "것", "수", "바", "때", "경우",
})

_LEGAL_TERM_HINTS: tuple[str, ...] = (
    "위법", "적법", "고의", "과실", "구성요건", "책임", "정당방위",
    "긴급피난", "상당", "필요", "영장", "압수", "수색", "증거",
    "공소", "기소", "무죄", "유죄", "양형", "재심", "항소", "상고",
    "체포", "구속", "자백", "진술", "피고인", "피의자",
)

_LEGAL_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"제\s*\d+\s*조(?:\s*의\s*\d+)?(?:\s*제\s*\d+\s*항)?(?:\s*제\s*\d+\s*호)?"),
    re.compile(r"\d{2,4}\s*[가-힣]{1,3}\s*\d+"),
    re.compile(r"\d{4}\s*[.년]\s*\d{1,2}\s*[.월]\s*\d{1,2}\s*[.일]?"),
    re.compile(r"(대법원|헌법재판소|고등법원|지방법원|가정법원|행정법원|특허법원)"),
)

_DOMAIN_HINTS: dict[str, tuple[str, ...]] = {
    "criminal_law": (
        "형법", "총론", "각론", "구성요건", "위법성", "책임", "죄형법정주의", "죄수", "고의", "과실",
    ),
    "criminal_procedure_evidence": (
        "형사소송법", "증거", "전문법칙", "자백", "압수", "수색", "영장", "증거능력", "위법수집증거", "유류물",
    ),
    "criminal_procedure_investigation": (
        "수사", "체포", "구속", "재수사", "사법경찰관", "검사", "수사준칙", "재체포", "재구속",
    ),
    "constitutional_law": (
        "헌법", "위헌", "합헌", "과잉금지원칙", "목적", "수단", "최소침해", "법익균형", "헌법재판소",
    ),
    "police_committees": (
        "위원회", "국가경찰위원회", "자치경찰위원회", "정보공개위원회", "징계위원회", "소청심사위원회", "심의위원회",
    ),
}


def normalize_legal_text(text: str) -> str:
    """판례 분석에 불필요한 노이즈를 줄여 핵심 문자 신호를 살립니다."""
    if not text:
        return ""

    cleaned = text
    cleaned = re.sub(r"https?://\S+", " ", cleaned)
    cleaned = re.sub(r"www\.\S+", " ", cleaned)
    cleaned = re.sub(r"portal\.scourt\.go\.kr\S*", " ", cleaned)
    cleaned = re.sub(
        r"\[\s*(판시사항|판결요지|참조조문|참조판례|전문|주문|원심판결|이유)\s*\]",
        r"\n[\1]\n",
        cleaned,
    )
    cleaned = re.sub(r"[\t\r\f\v]", " ", cleaned)
    cleaned = re.sub(r"\n{2,}", "\n", cleaned)
    cleaned = re.sub(r"[ ]{2,}", " ", cleaned)
    return cleaned.strip()


def extract_legal_keyphrases(text: str, top_n: int = 10) -> list[str]:
    """법률 문서에서 조문/사건번호/쟁점어를 우선 추출합니다."""
    normalized = normalize_legal_text(text)
    if not normalized:
        return []

    ranked: list[str] = []
    seen: set[str] = set()

    def push(term: str) -> None:
        cleaned = term.strip()
        if not cleaned or cleaned in seen:
            return
        seen.add(cleaned)
        ranked.append(cleaned)

    for pattern in _LEGAL_PATTERNS:
        for m in pattern.findall(normalized):
            if isinstance(m, tuple):
                value = "".join(x for x in m if x)
            else:
                value = m
            push(re.sub(r"\s+", "", value))
            if len(ranked) >= top_n:
                return ranked[:top_n]

    hangul_terms = re.findall(r"[가-힣]{2,14}", normalized)
    counts = Counter(hangul_terms)
    scored: list[tuple[str, float]] = []
    for term, freq in counts.items():
        if term in _STOPWORDS:
            continue
        if len(term) < 2:
            continue
        score = float(freq)
        if any(hint in term for hint in _LEGAL_TERM_HINTS):
            score += 1.5
        if term.endswith("죄") or term.endswith("조"):
            score += 0.8
        scored.append((term, score))

    scored.sort(key=lambda x: x[1], reverse=True)
    for term, _ in scored:
        push(term)
        if len(ranked) >= top_n:
            break

    return ranked[:top_n]


def count_legal_signals(text: str) -> dict[str, int]:
    """텍스트 내 법률 신호(조문/사건번호/법원명/날짜) 개수를 집계합니다."""
    normalized = normalize_legal_text(text)
    if not normalized:
        return {
            "article_refs": 0,
            "case_numbers": 0,
            "date_refs": 0,
            "court_refs": 0,
            "term_hints": 0,
        }

    return {
        "article_refs": len(_LEGAL_PATTERNS[0].findall(normalized)),
        "case_numbers": len(_LEGAL_PATTERNS[1].findall(normalized)),
        "date_refs": len(_LEGAL_PATTERNS[2].findall(normalized)),
        "court_refs": len(_LEGAL_PATTERNS[3].findall(normalized)),
        "term_hints": sum(1 for hint in _LEGAL_TERM_HINTS if hint in normalized),
    }


# ---------------------------------------------------------------------------
# 형태소 분석 / 토크나이징
# ---------------------------------------------------------------------------

def tokenize(text: str) -> list[str]:
    """한국어 텍스트를 형태소 단위로 분리하고 불용어를 제거합니다."""
    if not text or not text.strip():
        return []

    if _USE_OKT:
        morphs = _okt.morphs(text, stem=True)
    else:
        morphs = text.split()

    return [m for m in morphs if m not in _STOPWORDS and len(m) > 1]


# ---------------------------------------------------------------------------
# TF-IDF 행렬 구성
# ---------------------------------------------------------------------------

def build_tfidf_matrix(
    cases: list[dict],
    text_field: str = "full_text",
    id_field: str = "case_id",
) -> tuple[Any, Any]:
    """
    판례 리스트로부터 TF-IDF 행렬을 구성합니다.

    Args:
        cases: [{"case_id": str, "full_text": str}, ...] 형태의 판례 목록
        text_field: 텍스트가 담긴 딕셔너리 키
        id_field: 문서 ID가 담긴 딕셔너리 키

    Returns:
        tfidf_df: (문서 수 × 어휘집 크기) TF-IDF DataFrame, index=case_id
        idf_series: 어휘집 기준 IDF 값 Series
    """
    if pd is None:
        raise RuntimeError("pandas is required for TF-IDF features. Install backend requirements first.")

    case_df = pd.DataFrame(cases)
    case_df["tokens"] = case_df[text_field].fillna("").apply(tokenize)
    case_df["token_str"] = case_df["tokens"].apply(lambda t: " ".join(t))

    # 전체 어휘집
    all_tokens = [tok for tokens in case_df["tokens"] for tok in tokens]
    vocabulary = sorted(set(all_tokens))
    vocab_size = len(vocabulary)
    num_docs = len(case_df)

    if vocab_size == 0:
        empty_df = pd.DataFrame(index=case_df[id_field], columns=[])
        return empty_df, pd.Series(dtype=float)

    # DF 계산
    df_counts = pd.Series(np.zeros(vocab_size, dtype=int), index=vocabulary)
    for tokens in case_df["tokens"]:
        for tok in set(tokens):
            if tok in df_counts.index:
                df_counts[tok] += 1

    # IDF = log((N+1) / (df+1)) + 1  (scikit-learn smooth IDF 방식)
    idf_series = np.log((num_docs + 1) / (df_counts + 1)) + 1

    # TF-IDF 행렬 구성
    tfidf_matrix = np.zeros((num_docs, vocab_size))
    for doc_idx, tokens in enumerate(case_df["tokens"]):
        if not tokens:
            continue
        doc_len = len(tokens)
        term_counts = pd.Series(np.zeros(vocab_size), index=vocabulary)
        for tok in tokens:
            if tok in term_counts.index:
                term_counts[tok] += 1
        tf_values = term_counts / doc_len
        tfidf_vector = (tf_values * idf_series).fillna(0)
        tfidf_matrix[doc_idx, :] = tfidf_vector.values

    tfidf_df = pd.DataFrame(
        tfidf_matrix,
        index=case_df[id_field].tolist(),
        columns=vocabulary,
    )
    return tfidf_df, idf_series


# ---------------------------------------------------------------------------
# 유사 판례 검색
# ---------------------------------------------------------------------------

def find_similar_cases(
    query_case_id: str,
    tfidf_df: Any,
    top_k: int = 5,
) -> list[dict]:
    """
    특정 판례와 코사인 유사도가 높은 판례를 반환합니다.

    Args:
        query_case_id: 기준 판례 ID
        tfidf_df: build_tfidf_matrix()의 반환값
        top_k: 반환할 유사 판례 수

    Returns:
        [{"case_id": str, "similarity": float, "rank": int}, ...]
    """
    if pd is None or cosine_similarity is None:
        raise RuntimeError("pandas and scikit-learn are required for similarity search.")

    if query_case_id not in tfidf_df.index:
        return []

    query_vector = tfidf_df.loc[query_case_id].values.reshape(1, -1)
    similarities = cosine_similarity(tfidf_df.values, query_vector).flatten()

    scores = pd.Series(similarities, index=tfidf_df.index)
    # 자기 자신 제외
    scores = scores.drop(index=query_case_id, errors="ignore")
    top = scores.sort_values(ascending=False).head(top_k)

    return [
        {"case_id": case_id, "similarity": round(float(sim), 4), "rank": rank + 1}
        for rank, (case_id, sim) in enumerate(top.items())
    ]


def search_by_query(
    query_text: str,
    tfidf_df: Any,
    idf_series: Any,
    top_k: int = 5,
) -> list[dict]:
    """
    자유 텍스트 쿼리로 유사 판례를 검색합니다.

    Args:
        query_text: 검색 쿼리 문자열
        tfidf_df: build_tfidf_matrix()의 반환값
        idf_series: build_tfidf_matrix()의 반환값
        top_k: 반환할 판례 수

    Returns:
        [{"case_id": str, "similarity": float, "rank": int}, ...]
    """
    if pd is None or cosine_similarity is None:
        raise RuntimeError("pandas and scikit-learn are required for query search.")

    query_tokens = tokenize(query_text)
    if not query_tokens:
        return []

    vocabulary = tfidf_df.columns.tolist()
    vocab_size = len(vocabulary)
    query_len = len(query_tokens)

    query_term_counts = pd.Series(np.zeros(vocab_size), index=vocabulary)
    for tok in query_tokens:
        if tok in query_term_counts.index:
            query_term_counts[tok] += 1

    query_tf = query_term_counts / query_len
    query_tfidf = (query_tf * idf_series).fillna(0)
    query_vector = query_tfidf.values.reshape(1, -1)

    similarities = cosine_similarity(tfidf_df.values, query_vector).flatten()
    scores = pd.Series(similarities, index=tfidf_df.index)
    top = scores.sort_values(ascending=False).head(top_k)

    return [
        {"case_id": case_id, "similarity": round(float(sim), 4), "rank": rank + 1}
        for rank, (case_id, sim) in enumerate(top.items())
        if sim > 0
    ]


# ---------------------------------------------------------------------------
# 키워드 추출
# ---------------------------------------------------------------------------

def extract_keywords(
    text: str,
    idf_series: Any,
    top_n: int = 10,
) -> list[str]:
    """
    단일 문서에서 TF-IDF 기준 상위 키워드를 추출합니다.

    Args:
        text: 판례 원문 텍스트
        idf_series: 코퍼스 전체 기준 IDF Series (build_tfidf_matrix 반환값)
        top_n: 반환할 키워드 수

    Returns:
        키워드 문자열 리스트
    """
    tokens = tokenize(text)
    if not tokens:
        return []

    doc_len = len(tokens)
    term_counts: dict[str, int] = {}
    for tok in tokens:
        term_counts[tok] = term_counts.get(tok, 0) + 1

    scores: dict[str, float] = {}
    for tok, count in term_counts.items():
        tf = count / doc_len
        idf = float(idf_series.get(tok, np.log((1 + 1) / (0 + 1)) + 1))
        scores[tok] = tf * idf

    sorted_keywords = sorted(scores.items(), key=lambda x: x[1], reverse=True)
    return [kw for kw, _ in sorted_keywords[:top_n]]


# ---------------------------------------------------------------------------
# TextRank 기반 핵심 문장 추출 (LLM 입력 축약용)
# ---------------------------------------------------------------------------

def extract_key_sentences(
    text: str,
    top_n: int = 5,
) -> str:
    """
    TextRank 알고리즘으로 핵심 문장을 추출합니다.
    Llama 1B 컨텍스트 한계(~2048 토큰)에 맞게 판례 전문을 축약합니다.

    Args:
        text: 판례 원문 전체 텍스트
        top_n: 추출할 핵심 문장 수

    Returns:
        핵심 문장을 줄바꿈으로 연결한 문자열
    """
    normalized = normalize_legal_text(text)

    # 문장 분리 (한국어 종결어미 기준)
    sentences = re.split(
        r"(?<=[다요니!?])\s+|(?<=\.)\s+(?=[가-힣\[])|\n+",
        normalized.strip(),
    )
    sentences = [s.strip() for s in sentences if len(s.strip()) > 10]

    if len(sentences) <= top_n:
        return "\n".join(sentences)

    # 문장별 토큰 집합 구성
    sentence_tokens = [set(tokenize(s)) for s in sentences]

    # 문장 간 Jaccard 유사도로 유사도 행렬 구성
    n = len(sentences)
    sim_matrix = np.zeros((n, n))
    for i in range(n):
        for j in range(n):
            if i == j:
                continue
            union = sentence_tokens[i] | sentence_tokens[j]
            if not union:
                continue
            intersection = sentence_tokens[i] & sentence_tokens[j]
            sim_matrix[i][j] = len(intersection) / len(union)

    # TextRank: 반복적 점수 업데이트
    scores = np.ones(n) / n
    damping = 0.85
    for _ in range(30):
        new_scores = (1 - damping) / n + damping * sim_matrix.T @ scores
        if np.allclose(scores, new_scores, atol=1e-6):
            break
        scores = new_scores

    # 법률 신호가 강한 문장(조문, 사건번호 등)을 우선 반영
    priority_scores = np.zeros(n)
    for idx, sentence in enumerate(sentences):
        bonus = 0.0
        for pattern in _LEGAL_PATTERNS:
            bonus += len(pattern.findall(sentence)) * 0.15
        if any(h in sentence for h in _LEGAL_TERM_HINTS):
            bonus += 0.2
        priority_scores[idx] = bonus

    combined_scores = scores + priority_scores

    top_indices = sorted(
        np.argsort(combined_scores)[-top_n:].tolist()
    )  # 원문 순서 유지
    return "\n".join(sentences[i] for i in top_indices)


def infer_study_domain(text: str, keywords: list[str] | None = None) -> str:
    """수험 과목 관점의 대분류 도메인을 추정합니다."""
    normalized = normalize_legal_text(text)
    corpus = f"{normalized} {' '.join(keywords or [])}".lower()

    # 동점 시 더 구체적인 도메인이 우선되도록 명시적 우선순위 사용
    priority = (
        "police_committees",
        "constitutional_law",
        "criminal_procedure_evidence",
        "criminal_procedure_investigation",
        "criminal_law",
    )

    best_domain = "general_legal"
    best_score = 0
    for domain in priority:
        hints = _DOMAIN_HINTS.get(domain, ())
        score = sum(1 for hint in hints if hint.lower() in corpus)
        if score > best_score:
            best_score = score
            best_domain = domain

    return best_domain


def build_study_focus(domain: str, keywords: list[str], key_sentences: str) -> list[str]:
    """도메인별 학습 체크포인트를 생성합니다. 강의 대체가 아닌 복습 가이드 용도입니다."""
    top_keywords = ", ".join(keywords[:4]) if keywords else "핵심 키워드 재확인"
    first_line = key_sentences.split("\n")[0].strip() if key_sentences.strip() else "핵심 문장 재확인"

    if domain == "constitutional_law":
        return [
            "위헌/합헌 결론을 먼저 암기하고, 판례 번호와 연결해서 복습",
            "위헌 사유를 목적·수단·최소침해·법익균형 순서로 분류",
            f"핵심 문장 체크: {first_line[:90]}",
        ]

    if domain == "criminal_procedure_evidence":
        return [
            "증거능력 인정/배제 기준을 OX로 반복 훈련",
            "영장 필요 여부와 예외 사유를 숫자·요건으로 분리 암기",
            f"쟁점 키워드: {top_keywords}",
        ]

    if domain == "criminal_procedure_investigation":
        return [
            "체포·구속·영장 관련 기한/절차 숫자를 우선 암기",
            "재수사 요청 가능 요건을 주체·시점·범위로 나눠 복습",
            f"핵심 문장 체크: {first_line[:90]}",
        ]

    if domain == "criminal_law":
        return [
            "유무죄 결론을 사실관계 포인트와 함께 연결 암기",
            "총론이면 학설별 결론 차이를 표로 정리해 반복",
            f"쟁점 키워드: {top_keywords}",
        ]

    if domain == "police_committees":
        return [
            "위원회별 인원 범위·구성 요건·기한 숫자를 OX로 반복",
            "한 글자/숫자 함정 지문을 중심으로 오답노트 축적",
            f"핵심 키워드 묶음: {top_keywords}",
        ]

    return [
        "핵심 쟁점-결론-시험포인트 3단 구조로 요약 후 복습",
        "헷갈리는 판례는 유사판례 2~3개와 비교하여 차이 암기",
        f"핵심 문장 체크: {first_line[:90]}",
    ]
