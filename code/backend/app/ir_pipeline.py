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

import numpy as np
import pandas as pd
from sklearn.metrics.pairwise import cosine_similarity

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
) -> tuple[pd.DataFrame, pd.Series]:
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
    tfidf_df: pd.DataFrame,
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
    tfidf_df: pd.DataFrame,
    idf_series: pd.Series,
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
    idf_series: pd.Series,
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
    # 문장 분리 (한국어 종결어미 기준)
    import re
    sentences = re.split(r"(?<=[다요니])\s+", text.strip())
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

    top_indices = sorted(
        np.argsort(scores)[-top_n:].tolist()
    )  # 원문 순서 유지
    return "\n".join(sentences[i] for i in top_indices)
