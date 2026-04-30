# 사용 기술 설명: AI_SYS

작성일: 2026-04-02  
최종 업데이트: 2026-04-17  
문서 버전: v1.1

> 안내: 본 문서는 기획 기준과 실제 적용 기술을 함께 기록합니다.

## 0. 현재 적용 기술 (구현 기준)

| 구분 | 실제 적용 기술 | 비고 |
|------|----------------|------|
| iOS 앱 | SwiftUI, NavigationStack, TabView | Home/OCR/Search/Review/My Page 구성 |
| OCR | Vision + PhotosPicker | OCR 텍스트를 검색 쿼리로 전달 |
| 온디바이스 LLM | LlamaSwift (llama.cpp) + GGUF | 요약/퀴즈 생성 경로 연결 |
| API 서버 | FastAPI + Uvicorn | /health, /search, /cases, /dashboard/* |
| DB | PostgreSQL + pgvector | schema.sql 기반 초기화 |
| 컨테이너 | Docker Compose | ai_sys_team 프로젝트로 운영 |

운영 메모
- iOS deployment target은 16.4 기준으로 정렬했다.
- 실기기 연결 시 My Page에서 API base URL 오버라이드로 Mac 서버 주소를 저장해 사용한다.

## 1. 문서 목적
이 문서는 AI_SYS 구현에 사용할 기술 스택과 그 선택 이유를 정리한다.  
특히 AI 기술, 검색 구조, 데이터 처리 방식, 서비스 구성, 운영 관점을 함께 설명해 기획 문서와 실제 구현 방향 사이의 연결 기준으로 사용한다.

## 2. 기술 스택 한눈에 보기

| 구분 | 사용 기술 | 역할 |
|------|-----------|------|
| AI/생성 | LLM, RAG | 판례 문맥 기반 질의응답 및 요약 생성 |
| 검색 | 임베딩 모델, 벡터 DB, reranking | 관련 판례 탐색과 검색 정확도 개선 |
| 데이터 | 판례 원문, 메타데이터, 전처리 파이프라인 | 검색 가능한 학습 자산 구성 |
| 백엔드 | Python, FastAPI | 검색/요약/오답 저장 API 제공 |
| 프론트엔드 | 웹 UI 또는 앱 UI | 검색, 판례 조회, 문제 풀이, 복습 경험 제공 |
| 저장소/운영 | GitHub, 로그 관리, 테스트 | 문서/코드 관리와 품질 검증 |

## 3. AI 기술 설명

### 3.1 LLM
- 역할: 사용자의 질문을 이해하고, 검색된 판례 문맥을 바탕으로 자연어 응답과 요약을 생성한다.
- 사용 목적:
  - 판례 쟁점 요약
  - 결론과 시험 포인트 정리
  - 사용자 질문에 대한 근거 중심 설명 생성
- 기대 효과:
  - 긴 판결문을 짧고 이해하기 쉬운 형태로 재구성할 수 있다.
  - 시험 준비생이 필요한 핵심만 빠르게 확인할 수 있다.

### 3.2 RAG (Retrieval-Augmented Generation)
- 역할: 생성형 AI가 내부 DB에 적재된 판례 데이터를 먼저 검색한 뒤 그 결과를 근거로 답변하도록 만드는 구조다.
- 사용 목적:
  - 할루시네이션을 줄이고 근거 기반 답변을 강화한다.
  - 최신 또는 특정 판례 문맥을 답변에 반영한다.
- 기대 효과:
  - 단순 생성형 응답보다 신뢰도가 높은 결과를 제공할 수 있다.
  - 출처 연결이 가능한 설명 구조를 만들 수 있다.

### 3.3 임베딩 모델
- 역할: 판례 문서와 사용자 질문을 벡터 형태로 변환해 의미 기반 유사도 검색을 가능하게 한다.
- 사용 목적:
  - 정확한 키워드가 아니어도 의미가 유사한 판례를 찾는다.
  - 사건명, 법리, 쟁점 단위 검색 품질을 높인다.
- 기대 효과:
  - 단순 문자열 검색보다 더 자연스러운 검색 경험을 제공할 수 있다.

### 3.4 Reranking
- 역할: 1차 검색으로 모은 판례 후보를 다시 평가해 더 관련성 높은 순서로 정렬한다.
- 사용 목적:
  - 상위 검색 결과의 정확도를 개선한다.
  - 검색 결과가 많을 때 실제로 필요한 판례를 앞쪽에 배치한다.
- 기대 효과:
  - 사용자가 원하는 판례를 더 적은 클릭으로 찾을 가능성이 높아진다.

## 4. 데이터 기술 설명

### 4.1 판례 데이터셋
- 구성 요소:
  - 판례명
  - 사건번호
  - 법원 정보
  - 핵심 쟁점
  - 판결 요지
  - 시험 포인트
  - 출처 링크 또는 원문 참조 정보
- 역할: 검색, 요약, 출처 제공의 기반 자산으로 사용된다.

### 4.2 데이터 전처리
- 역할: 수집한 판례 데이터를 검색 가능한 구조로 정리한다.
- 주요 작업:
  - 텍스트 정리
  - 메타데이터 정규화
  - 중복 제거
  - 누락 출처 검수
  - 청크 분할
- 기대 효과:
  - 검색 정확도와 응답 일관성을 높일 수 있다.

### 4.3 벡터 데이터베이스
- 후보 기술: FAISS, ChromaDB, Pinecone 등
- 역할: 임베딩된 판례 데이터를 저장하고 유사도 검색을 빠르게 수행한다.
- 사용 목적:
  - 대량의 판례 문서를 빠르게 검색한다.
  - 쟁점 단위 탐색을 실시간 서비스에 가깝게 제공한다.

### 4.4 내부 판례 DB 저장 구조
- 역할: 외부 API 유무와 무관하게 서비스가 안정적으로 동작할 수 있도록 판례 원문과 메타데이터를 내부 기준 데이터로 저장한다.
- 저장 원칙:
  - 판례 원문은 가능한 한 원본에 가깝게 그대로 보관한다.
  - 메타데이터는 검색과 학습 기능에서 바로 사용할 수 있도록 구조화해 별도 컬럼으로 저장한다.
  - 검색용 청크, 키워드, 임베딩 데이터는 원문과 분리해 관리한다.
- 최소 메타데이터 항목:
  - 사건번호
  - 판례명
  - 법원명
  - 선고일
  - 과목
  - 핵심 쟁점
  - 판결 요지
  - 시험 포인트
  - 출처 링크
  - 수집일/수정일
  - 데이터 상태

### 4.5 판례 데이터 확보 및 적재 파이프라인
- 1단계. 원문 확보:
  - 공식 공개 파일데이터, 공식 사이트의 이용 가능한 출처, 운영자 수집 자료를 통해 초기 판례 원문 후보를 확보한다.
- 2단계. 기본 메타데이터 추출:
  - 사건번호, 판례명, 법원명, 선고일, 출처 링크를 추출한다.
- 3단계. 내부 DB 저장:
  - 원문 텍스트와 기본 메타데이터를 판례 기본 테이블에 저장한다.
- 4단계. 전처리:
  - 공백 정리, 메타데이터 정규화, 중복 제거, 누락 값 검수를 수행한다.
- 5단계. 청크 분할:
  - 원문을 검색과 RAG에 적합한 단위로 분할해 저장한다.
- 6단계. 요약 메타데이터 생성:
  - 핵심 쟁점, 결론, 시험 포인트, 검색 키워드를 생성하고 검수한다.
- 7단계. 임베딩 및 인덱싱:
  - 청크별 임베딩을 생성하고 벡터 검색 인덱스를 구축한다.
- 8단계. 검수 후 공개:
  - 검수 완료 상태의 데이터만 서비스 응답에 사용한다.

### 4.6 권장 DB 논리 구조
- cases:
  - 판례 기본 정보와 원문 텍스트 저장
- case_chunks:
  - 검색 및 RAG용 원문 청크 저장
- case_keywords:
  - 검색 키워드와 가중치 저장
- case_relations:
  - 유사 판례, 관련 판례, 반대 취지 판례 연결
- user_case_history:
  - 사용자 조회, 오답, 복습 이력 저장

### 4.7 검색과 요약에서의 활용 방식
- 사건번호 입력:
  - 내부 DB에서 사건번호 exact match를 우선 수행한다.
- 키워드 입력:
  - 메타데이터와 키워드 인덱스를 기반으로 우선 검색한다.
- OCR 입력:
  - OCR 텍스트에서 키워드를 추출해 내부 DB 검색으로 연결한다.
- 요약 생성:
  - 원문 전체를 직접 LLM에 넣기보다 관련 청크를 선택해 RAG 방식으로 전달한다.
- 출처 제공:
  - 내부 DB에 저장된 출처 링크와 사건번호를 함께 표시한다.

## 5. 백엔드 기술 설명

### 5.1 Python
- 역할: AI 파이프라인과 데이터 처리, API 서버 구현의 중심 언어다.
- 선택 이유:
  - LLM, 벡터 검색, 데이터 처리 라이브러리 생태계가 풍부하다.
  - 빠른 프로토타이핑에 적합하다.

### 5.2 FastAPI
- 역할: 검색, 판례 조회, 요약, 오답 저장, 복습 추천 기능을 API 형태로 제공한다.
- 예상 엔드포인트 예시:
  - POST /search
  - GET /cases/{id}
  - POST /cases/ingest
  - POST /ask
  - POST /wrong-answers
  - GET /review-recommendations
- 선택 이유:
  - Python 기반 AI 서비스와 연결이 쉽다.
  - 문서화와 테스트에 유리하다.

## 6. 프론트엔드 기술 설명

### 6.1 웹 또는 앱 UI
- 역할: 수험생이 검색, 요약 확인, 문제 풀이, 복습을 수행하는 사용자 인터페이스를 제공한다.
- 주요 화면:
  - 홈
  - 판례 검색
  - 판례 요약 상세
  - 관련 문제 풀이
  - 오답 저장
  - 복습 대시보드

### 6.2 화면 설계 방향
- 빠르게 찾고 바로 이해할 수 있는 흐름을 우선한다.
- 긴 설명보다 카드형 요약과 핵심 포인트 중심 구성을 사용한다.
- 복습 화면은 재방문 시작점 역할을 하도록 설계한다.

## 7. 운영 및 품질 기술 설명

### 7.1 로그 및 모니터링
- 역할: 검색 실패, 응답 시간, 출처 누락, 저장 실패 같은 이벤트를 추적한다.
- 목적:
  - 검색 품질 개선 포인트를 찾는다.
  - 사용자 이탈 구간을 확인한다.

### 7.2 테스트
- 역할: 핵심 사용자 시나리오와 검색 정확도, 요약 품질을 점검한다.
- 검증 대상:
  - 검색 성공 여부
  - 출처 노출 여부
  - 문제 연계 흐름
  - 오답 저장 및 복습 추천 흐름

### 7.3 버전 관리
- 기술: Git, GitHub
- 역할: 문서와 구현 코드를 관리하고 변경 이력을 추적한다.

## 8. 기술 선택 이유 요약
- RAG: 판례 근거 기반 응답을 위해 필요하다.
- 임베딩 + 벡터 DB: 의미 기반 판례 검색 품질을 높이기 위해 필요하다.
- Reranking: 상위 결과의 정확도를 높이기 위해 필요하다.
- Python + FastAPI: AI 파이프라인과 API를 빠르게 연결하기에 적합하다.
- 구조화된 UI: 수험생이 검색에서 복습까지 한 흐름으로 사용할 수 있게 해준다.

## 9. 향후 확장 가능 기술
- 과목별 판례 추천 모델
- 사용자별 취약 쟁점 분석 모델
- 판례와 기출 문제 자동 매핑 기능
- 학습 이력 기반 개인화 복습 스케줄링
- 관리자용 품질 검수 대시보드

## 10. PostgreSQL 기준 DB 스키마 초안

### 10.1 설계 원칙
- 원문은 기준 데이터이므로 가능한 한 원본에 가깝게 보관한다.
- 검색과 요약에 필요한 메타데이터는 원문과 분리해 구조화한다.
- RAG 검색용 청크와 키워드는 별도 테이블로 관리한다.
- 사용자 복습 데이터는 판례 데이터와 직접 연결 가능하도록 관계형 구조를 유지한다.

### 10.2 핵심 테이블

#### cases
- 역할: 판례 기본 정보와 원문 텍스트 저장
- 주요 컬럼:
  - id
  - case_number
  - case_name
  - court_name
  - decision_date
  - case_type
  - subject
  - raw_text
  - issue_summary
  - holding_summary
  - exam_points
  - source_url
  - source_name
  - status
  - collected_at
  - updated_at

#### case_chunks
- 역할: 원문을 검색 및 RAG용 단위로 분할 저장
- 주요 컬럼:
  - id
  - case_id
  - chunk_index
  - chunk_text
  - token_count
  - embedding_vector 또는 vector_ref
  - created_at

#### case_keywords
- 역할: 검색용 키워드와 가중치 저장
- 주요 컬럼:
  - id
  - case_id
  - keyword
  - weight
  - created_at

#### case_relations
- 역할: 유사 판례, 관련 판례, 반대 취지 판례 연결
- 주요 컬럼:
  - id
  - source_case_id
  - target_case_id
  - relation_type
  - score
  - created_at

#### user_case_history
- 역할: 사용자 조회, 오답, 복습 이력 저장
- 주요 컬럼:
  - id
  - user_id
  - case_id
  - viewed_at
  - wrong_count
  - confidence_level
  - review_due_at
  - created_at
  - updated_at

### 10.3 SQL 예시

```sql
create table cases (
    id bigserial primary key,
    case_number varchar(100) not null unique,
    case_name varchar(255) not null,
    court_name varchar(100) not null,
    decision_date date,
    case_type varchar(100),
    subject varchar(100),
    raw_text text not null,
    issue_summary text,
    holding_summary text,
    exam_points text,
    source_url text,
    source_name varchar(100),
    status varchar(50) not null default 'collected',
    collected_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table case_chunks (
    id bigserial primary key,
    case_id bigint not null references cases(id) on delete cascade,
    chunk_index integer not null,
    chunk_text text not null,
    token_count integer,
    vector_ref text,
    created_at timestamptz not null default now(),
    unique (case_id, chunk_index)
);

create table case_keywords (
    id bigserial primary key,
    case_id bigint not null references cases(id) on delete cascade,
    keyword varchar(100) not null,
    weight numeric(5,2) not null default 1.00,
    created_at timestamptz not null default now()
);

create table case_relations (
    id bigserial primary key,
    source_case_id bigint not null references cases(id) on delete cascade,
    target_case_id bigint not null references cases(id) on delete cascade,
    relation_type varchar(50) not null,
    score numeric(5,2),
    created_at timestamptz not null default now()
);

create table user_case_history (
    id bigserial primary key,
    user_id bigint not null,
    case_id bigint not null references cases(id) on delete cascade,
    viewed_at timestamptz,
    wrong_count integer not null default 0,
    confidence_level varchar(20),
    review_due_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (user_id, case_id)
);
```

### 10.4 적재 예시 흐름
- 운영자가 판례 원문과 기본 메타데이터를 확보한다.
- cases에 원문과 사건번호, 판례명, 법원명, 과목, 출처를 저장한다.
- 원문을 단락 또는 토큰 단위로 분리해 case_chunks에 저장한다.
- 검색 키워드와 시험 포인트를 생성해 case_keywords와 cases 요약 필드에 반영한다.
- 유사 판례 연결이 확인되면 case_relations에 저장한다.
- 사용자 풀이 및 오답 데이터는 user_case_history에 누적한다.

### 10.5 운영 메모
- MVP에서는 PostgreSQL 단일 DB로 시작하고, 임베딩 저장은 vector_ref 또는 pgvector 확장 적용 여부에 따라 결정한다.
- 사건번호 검색은 exact match 인덱스를 사용한다.
- 키워드 검색은 case_keywords와 cases 메타데이터 필드를 함께 사용한다.
- 요약 생성 시에는 raw_text 전체 대신 case_chunks 상위 결과만 LLM에 전달한다.
- status 값은 collected, parsed, reviewed, published 정도로 단순하게 시작하는 것이 적절하다.

## 11. 시각자료 (Mermaid)

```mermaid
flowchart LR
  U[사용자 질문] --> E[임베딩 변환]
  E --> V[벡터 DB 검색]
  V --> R[Reranking]
  R --> C[관련 판례 컨텍스트 구성]
  C --> L[LLM 응답 생성]
  L --> O[요약, 출처, 시험 포인트 제공]
```