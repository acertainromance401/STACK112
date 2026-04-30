from datetime import date, datetime
from typing import Literal, Optional

from pydantic import BaseModel


class CaseItem(BaseModel):
    id: str
    case_number: str
    case_name: str
    court_name: str
    decision_date: Optional[date] = None
    subject: str
    issue_summary: Optional[str] = None
    holding_summary: Optional[str] = None
    exam_points: Optional[str] = None
    source_url: Optional[str] = None
    updated_at: datetime


class HealthResponse(BaseModel):
    status: str


class SearchResponse(BaseModel):
    total: int
    items: list[CaseItem]


class RecommendedCaseItem(BaseModel):
    case_number: str
    case_name: str
    subject: str
    issue: str
    accuracy: int


class WrongAnswerListItem(BaseModel):
    title: str
    memo: str
    date: str


class RecommendedCasesResponse(BaseModel):
    total: int
    items: list[RecommendedCaseItem]


class WrongAnswersResponse(BaseModel):
    total: int
    items: list[WrongAnswerListItem]


class SearchEvidence(BaseModel):
    rank: int
    case_number: str
    case_name: str
    snippet: str
    matched_fields: list[str]
    relevance_score: float
    source_url: Optional[str] = None


class SearchResponseV2(BaseModel):
    query: str
    normalized_query: str
    total: int
    items: list[CaseItem]
    evidence: list[SearchEvidence]
    generated_at: datetime


class Citation(BaseModel):
    case_number: str
    case_name: str
    quoted_text: str
    reason: str


class GroundedAnswerRequest(BaseModel):
    question: str
    intent: Literal["summary", "compare", "qa", "quiz"]
    top_k: int = 3


class GroundedAnswerResponse(BaseModel):
    question: str
    answer: str
    citations: list[Citation]
    safety_flags: list[str]
    generated_at: datetime


# ---------------------------------------------------------------------------
# IR 파이프라인 스키마
# ---------------------------------------------------------------------------

class IRExtractRequest(BaseModel):
    """OCR로 추출한 판례 텍스트를 정제·축약 요청"""
    text: str
    top_keywords: int = 10
    top_sentences: int = 5


class IRExtractResponse(BaseModel):
    """키워드 및 핵심 문장 반환"""
    keywords: list[str]
    key_sentences: str


class SimilarCaseItem(BaseModel):
    case_id: str
    similarity: float
    rank: int


class SimilarCasesResponse(BaseModel):
    case_number: str
    total: int
    items: list[SimilarCaseItem]


# ---------------------------------------------------------------------------
# LLM 요약 / OX 퀴즈 스키마
# ---------------------------------------------------------------------------

class OXQuizItem(BaseModel):
    statement: str
    answer: bool          # True=O, False=X
    explanation: str


class LLMSummarizeRequest(BaseModel):
    """핵심 문장 + 메타 정보로 요약 및 OX 퀴즈 생성 요청"""
    case_number: str
    case_name: str
    key_sentences: str    # ir_pipeline.extract_key_sentences() 결과
    keywords: list[str]   # ir_pipeline.extract_keywords() 결과
    generate_quiz: bool = True
    quiz_count: int = 3


class LLMSummarizeResponse(BaseModel):
    case_number: str
    one_line_summary: str
    key_issue: str
    ruling_point: str
    exam_takeaway: str
    quiz: list[OXQuizItem]
