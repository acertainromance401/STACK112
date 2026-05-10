# AI_SYS 완벽 가이드: 아키텍처, 파이프라인, 배포

> 최종 수정: 2026년 5월 11일  
> 현재 상태: **iOS 앱은 완전 온디바이스(Backend-free) 모드로 운영 중**. 본 문서의 FastAPI/EC2/RDS 섹션은 (a) 다중 사용자 동기화 또는 (b) 외부 시스템 연동이 필요해질 때를 위한 *선택적 참고 자료*이며, 현재 빌드는 백엔드 없이도 풀 기능 동작합니다.
> - 단일 진실 공급원: [Project_Descriptions/Project_Status_and_Roadmap_2026-05-11.md](../Project_Descriptions/Project_Status_and_Roadmap_2026-05-11.md)
> - 단말 IR 파이프라인 매핑: `code/backend/app/ir_pipeline.py` ↔ `code/ios/AISYSApp/Sources/LocalIRPipeline.swift` (Swift 포팅, 동일 알고리즘)

---

## 목차
1. [시스템 전체 구조](#시스템-전체-구조)
2. [로컬 독립 동작 경로](#로컬-독립-동작-경로)
3. [서버 연결 경로](#서버-연결-경로)
4. [데이터 파이프라인 상세](#데이터-파이프라인-상세)
5. [현재 성능 상태](#현재-성능-상태)
6. [배포 아키텍처](#배포-아키텍처)
7. [배포 단계별 가이드](#배포-단계별-가이드)

---

## 시스템 전체 구조

```
┌─────────────────────────────────────────────────────────────┐
│                    iOS App (SwiftUI)                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────┐  ┌────────────┐  ┌──────────┐                │
│  │ HomeView │  │SearchView  │  │ OCRView  │                │
│  └────┬─────┘  └────┬───────┘  └────┬─────┘                │
│       │             │               │                       │
│       └─────────────┴───────────────┘                       │
│               │                                             │
│               ▼                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │       CaseSummaryView + CaseSummaryViewModel        │  │
│  │  (APICase → LLM요약 → OX퀴즈 → 정형화 출력)          │  │
│  └──────────────────────────────────────────────────────┘  │
│               │                                             │
│       ┌───────┴────────┐                                   │
│       │                │                                   │
│       ▼                ▼                                   │
│  ┌─────────────┐  ┌────────────────┐                      │
│  │ LLMService  │  │ NetworkService │                      │
│  │ (llama.cpp) │  │  (FastAPI API) │                      │
│  └─────────────┘  └────────────────┘                      │
│       │                │                                   │
│       │(로컬)           │(옵셔널)                            │
└───────┼────────────────┼───────────────────────────────────┘
        │                │
        ▼                ▼
   [로컬]          [서버] (선택적)
   GGUF           FastAPI
   모델           PostgreSQL
              +pgvector

```

---

## 로컬 독립 동작 경로

### 경로 1: OCR 스캔 → LLM 요약 (완전 로컬)

```
1. OCRView
   ├─ 사진 선택 → PhotosPicker
   ├─ Vision OCR 수행 (백그라운드 스레드)
   │  └─ VNRecognizeTextRequest
   └─ 텍스트 추출: "recognizedText" 획득

2. processOCRText()
   ├─ NetworkService.irExtract() 호출 (백엔드 없으면 실패)
   │  └─ 실패 시: 로컬 폴백 키워드 추출
   ├─ 임시 APICase 생성
   │  ├─ caseNumber: "OCR 스캔 판례"
   │  ├─ caseName: recognizedText.prefix(40)
   │  ├─ issueSummary: keySentences (백엔드 IR or 로컬 폴백)
   │  ├─ subject: keywords.joined()
   │  └─ examPoints: keywords.joined()
   ├─ ScannedCase 저장 (SwiftData)
   │  ├─ ocrRawText
   │  ├─ keywords[]
   │  ├─ keySentences
   │  └─ caseName
   └─ CaseSummaryView로 이동

3. CaseSummaryView
   ├─ apiCase 선택
   ├─ CaseSummaryViewModel.select(caseItem)
   ├─ ensureModelReady() → LLMService.loadModelIfNeeded()
   │  └─ llama.cpp 모델 로드 (Bundle or Documents)
   │     ├─ Llama-3.2-1B-Instruct-Q4_K_M.gguf (770MB)
   │     ├─ n_ctx: 512, n_batch: 128
   │     └─ 2개 스레드, 백그라운드에서 decode
   └─ LLMService.summarize(caseItem)

4. LLM 요약 생성
   ├─ PromptTemplate.summarize() 구성
   │  ├─ [ROLE] 법률 연구원
   │  ├─ [TASK] 판례 요약
   │  ├─ [RULES] 증거 기반만 사용
   │  ├─ [EVIDENCE] 추출된 필드들
   │  └─ [OUTPUT] 정형화 형식
   │
   ├─ 프롬프트 길이 제한: 1200자
   ├─ Task.detached에서 llama_decode 실행
   ├─ 토큰 생성: 최대 160개
   └─ 결과 파싱: LLMSummary 생성
      ├─ oneLineSummary: "한 줄 요약" (140자 제한)
      ├─ keyIssue: "핵심 쟁점" (220자 제한)
      ├─ rulingPoint: "판결 요지" (260자 제한)
      └─ examTakeaway: "시험 포인트" (180자 제한)

5. OX 퀴즈 생성 (선택사항)
   ├─ LLMService.generateOXQuiz()
   ├─ 동일 llama 엔진으로 동작
   ├─ OX문제 N개 생성
   └─ OXQuizQuestion[] 반환

✅ 장점
- 백엔드 없어도 완전 동작
- 네트워크 대기 없음
- 프라이버시 보호 (로컬 처리)
- 실시간 응답

❌ 제약
- OCR 정확도 (Vision.framework 한계)
- 유사도 검색 불가 (IR 백엔드 필요)
- 검색 기능 불가

```

---

### 경로 2: 로컬 저장 판례 조회 (완전 로컬)

```
1. SearchView → ScannedCase 조회
   ├─ @Query로 로컬 SwiftData 쿼리
   │  └─ sort: scannedAt (역순)
   ├─ 첫 20개만 표시
   └─ "더보기" 버튼으로 전체 확장

2. 항목 클릭
   ├─ ScannedCase → APICase 변환
   ├─ CaseSummaryView로 이동
   └─ LLM 요약 생성 (위 경로 3-5 동일)

✅ 로컬 DB 완전 독립 동작
```

---

## 서버 연결 경로

### 경로 3: 키워드 검색 → DB 조회 → LLM 요약 (서버 의존)

```
1. SearchView
   ├─ 키워드 입력 (e.g., "영장주의")
   ├─ search(query) 호출
   └─ NetworkService.searchCases()

2. BackendAPI /search?q=keyword&limit=10
   ├─ PostgreSQL 쿼리
   ├─ pgvector 코사인 유사도 검색 (선택)
   ├─ APICase[] 반환
   │  ├─ caseNumber
   │  ├─ caseName
   │  ├─ courtName
   │  ├─ issueSummary
   │  ├─ holdingSummary
   │  └─ examPoints
   └─ JSON 응답 (백그라운드에서 디코딩)

3. SearchView 렌더링
   ├─ List + .lazy로 성능 최적화
   ├─ SearchResultCard 표시
   └─ 사용자 선택

4. CaseSummaryView (로컬 LLM 요약)
   ├─ 경로 3-5와 동일
   ├─ 로컬 llama로 요약 생성
   └─ OX퀴즈 생성

❌ 문제점
- 백엔드 필수 (로컬 검색 없음)
- 네트워크 지연 (검색 3-5초)
- 서버 다운 시 검색 불가

```

---

### 경로 4: 백엔드 추천 사례 조회 (서버 의존)

```
1. HomeView
   ├─ ReviewStore (현재 하드코딩)
   ├─ recommendedCases[]
   └─ wrongAnswers[]

2. 향후 개선
   ├─ NetworkService.getRecommendedCases()
   ├─ /recommended?user_id=...&limit=20
   ├─ 사용자 정답률 기반 추천
   └─ 오답 노트와 함께 표시

```

---

## 데이터 파이프라인 상세

### OCR → IR 키워드 추출

#### 백엔드 IR 파이프라인 (로컬)

```python
# code/backend/app/ir_pipeline.py

1. normalize_legal_text(text)
   ├─ URL/포탈 제거
   ├─ 정규화 마크업 정리
   ├─ 중복 공백 제거
   └─ 반환: 정제된 텍스트

2. tokenize(text)
   ├─ Okt 형태소 분석 (로컬)
   ├─ 또는 공백 분리 폴백
   ├─ 불용어 필터링
   └─ 반환: token[]

3. extract_legal_keyphrases(text, top_n=5)
   ├─ 토큰화 후 빈도 계산
   ├─ 법률 용어 가중치 추가 (+1.5)
   │  ├─ "위법", "적법", "고의", "과실"
   │  ├─ "구성요건", "책임", "정당방위"
   │  └─ 등 30+ 용어
   ├─ 조문/사건번호 패턴 가중치 (+0.8)
   ├─ 상위 N개 반환
   └─ 반환: keyword[] (예: ["위법성", "자백", "증거"])

4. extract_key_sentences(text, top_n=3)
   ├─ 문장 분리 (줄바꿈 기반)
   ├─ 각 문장에 TextRank 스코어 계산
   ├─ 법률 신호 개수 가산
   ├─ 상위 N개 문장 선택
   └─ 반환: 연결된 핵심 문장 (예: "상고인의 주장은... 판단한다.")

5. build_tfidf_matrix(cases)
   ├─ pandas DataFrame으로 TF-IDF 계산
   ├─ 모든 케이스 토큰화
   ├─ TF-IDF 스코어 계산
   └─ 반환: (tfidf_df, idf_series)

6. find_similar_cases(query_text, tfidf_df, top_k=3)
   ├─ 쿼리 텍스트 토큰화
   ├─ 쿼리 TF-IDF 벡터 생성
   ├─ 코사인 유사도 계산
   ├─ 상위 K개 선택
   └─ 반환: case_id[]

```

#### FastAPI 엔드포인트

```python
# code/backend/app/main.py

POST /ir/extract
├─ Request: IRExtractRequest
│  └─ text: "OCR 텍스트..."
│
├─ 처리:
│  ├─ normalize_legal_text(text)
│  ├─ extract_legal_keyphrases(text, top_n=5)
│  └─ extract_key_sentences(text, top_n=3)
│
├─ Response: IRExtractResponse
│  ├─ keywords: ["키워드1", "키워드2", ...]
│  └─ keySentences: "핵심 문장 연결..."
│
└─ HTTP 200 / 500 (실패 시 iOS 로컬 폴백)

GET /search?q=keyword&limit=10
├─ PostgreSQL 풀텍스트 검색 또는 정확 매칭
├─ pgvector 코사인 유사도 (선택사항)
├─ Response: SearchResponse
│  ├─ total: 정수
│  └─ items: APICase[]
└─ HTTP 200 / 404

GET /cases/{case_number}
├─ PostgreSQL에서 단일 케이스 조회
├─ Response: CaseItem
└─ HTTP 200 / 404

GET /health
└─ Response: HealthResponse {"status": "ok"}

```

---

## 현재 성능 상태

### Energy Report (최적화 적용 후)

| 항목 | 이전 | 최적화 후 | 개선율 |
|------|------|---------|--------|
| **CPU** | 88.2% | 예상 60% | 32% ↓ |
| **메모리** | 213 MB | 예상 120 MB | 44% ↓ |
| **열 상태** | Serious | Fair | ✓ |
| **OCR** | 메인스레드 블로킹 | 백그라운드 | ✓ |
| **JSON 디코딩** | 메인스레드 | 백그라운드 | ✓ |
| **리스트 렌더링** | ForEach | List + lazy | ✓ |

### 적용된 최적화

1. **llama.cpp 파라미터**
   - n_ctx: 2048 → 512 (-75%)
   - n_batch: 512 → 128 (-75%)
   - threads: 2-6 → 2 (-67%)
   - maxTokens: 512 → 160 (-69%)

2. **스레드 최적화**
   - OCR을 Task.detached로 백그라운드 실행
   - JSON 디코딩을 백그라운드 실행
   - llama_decode를 백그라운드 실행

3. **UI 최적화**
   - ForEach → List + .lazy
   - LazyView로 뷰 계층 구조 최소화

4. **메모리 관리**
   - llama_memory_clear() 제거
   - 프롬프트 길이 1200자 제한
   - 배치 트림 마진 조정

---

## 배포 아키텍처

### 프로덕션 환경 구성

```
┌─────────────────────────────────────────────────────────┐
│                    Apple App Store                      │
│         (AI_SYS iOS App - v1.0 Release)                 │
└────────────────────┬────────────────────────────────────┘
                     │
        ┌────────────┴────────────┐
        │                         │
        ▼                         ▼
   [로컬 모드]              [서버 모드]
   (필수)                   (선택)
   
   ├─ GGUF 모델           ├─ FastAPI 서버
   ├─ SwiftData DB       ├─ PostgreSQL DB
   ├─ Vision OCR         ├─ pgvector
   └─ 온디바이스 LLM      └─ TF-IDF 검색

```

### 백엔드 서버 구성 (AWS EC2)

```
┌──────────────────────────────────────┐
│         AWS EC2 Instance             │
│  (Ubuntu 22.04, t3.medium)           │
├──────────────────────────────────────┤
│                                      │
│  ┌────────────────────────────────┐ │
│  │    FastAPI Application         │ │
│  │  (code/backend/app/main.py)    │ │
│  ├────────────────────────────────┤ │
│  │ - /search endpoint             │ │
│  │ - /cases endpoint              │ │
│  │ - /ir/extract endpoint         │ │
│  │ - /health endpoint             │ │
│  └────────────────────────────────┘ │
│          ▲      ▲                   │
│          │      │                   │
│    ┌─────┘      └──────────┐        │
│    │                       │        │
│    ▼                       ▼        │
│ ┌─────────────┐  ┌──────────────┐  │
│ │ PostgreSQL  │  │   Redis      │  │
│ │  (21GB)     │  │  (캐시)      │  │
│ │             │  │              │  │
│ │ - cases     │  │ - 검색 결과  │  │
│ │ - vectors   │  │ - 사용자 세션 │  │
│ │ - pgvector  │  │              │  │
│ └─────────────┘  └──────────────┘  │
│                                      │
└──────────────────────────────────────┘

```

### 데이터베이스 스키마 (PostgreSQL)

```sql
-- 판례 테이블
CREATE TABLE published_cases (
    id BIGSERIAL PRIMARY KEY,
    case_number VARCHAR(255) UNIQUE NOT NULL,
    case_name TEXT NOT NULL,
    court_name VARCHAR(100) NOT NULL,
    decision_date DATE,
    subject VARCHAR(100),
    issue_summary TEXT,
    holding_summary TEXT,
    exam_points TEXT,
    source_url TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- 벡터 인덱싱 (pgvector)
CREATE TABLE case_vectors (
    case_id BIGINT PRIMARY KEY REFERENCES published_cases(id),
    embedding vector(384),  -- sentence-transformers 임베딩
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_case_vectors ON case_vectors USING ivfflat (embedding vector_cosine_ops);

-- 인덱싱
CREATE INDEX idx_case_number ON published_cases(case_number);
CREATE INDEX idx_court_name ON published_cases(court_name);
CREATE INDEX idx_subject ON published_cases(subject);

-- 풀텍스트 검색
CREATE INDEX idx_issue_fts ON published_cases 
    USING GIN(to_tsvector('korean', issue_summary));

```

---

## 배포 단계별 가이드

## 현재 배포 판정 (2026-05-07)

- 백엔드 런타임 스모크: 통과 (`/health` 200)
- 도커 배포 구성: 유효 (`docker compose config` 통과)
- iOS 테스트: 2건 실패
   - `AISYSAppTests.testSaveWrongAnswerAddsItemToTop`
   - `AISYSAppTests.testRecommendedCasesExist`
- 판정
   - 내부 배포(시연/TestFlight 내부): 가능
   - 운영 배포/스토어 제출: 테스트 정비 후 진행 권장

### Phase 1: 로컬 앱 완성 & 테스트 (현재 상태)

#### ✅ 완료 사항
- iOS 앱 UI/UX 구현
- 온디바이스 LLM (llama.cpp) 통합
- OCR 기능 구현
- SwiftData 로컬 저장
- CPU/메모리 최적화

#### 📋 TODO
1. **모델 다운로드 속도 최적화**
   - 현재: 770MB GGUF, 앱 번들에 포함
   - 개선: 첫 실행 시 동적 다운로드 (옵션)
   - LLM 초기 로드 5-10초 → 1-2초 목표

2. **정형화 검증**
   - LLMSummary 파싱 성공률 측정
   - fallback 텍스트 정확도 평가
   - 추가 테스트 (50+ 케이스)

3. **OX 퀴즈 성능**
   - 생성 시간 측정
   - 문제 품질 평가
   - 사용자 피드백 수집

### Phase 2: 백엔드 배포 (선택사항)

#### 1단계: 개발 서버 구축

```bash
# AWS EC2에 배포
# (Ubuntu 22.04, t3.medium)

# 1. 환경 설정
ssh ubuntu@<EC2_IP>
sudo apt update && sudo apt upgrade -y

# 2. Python 환경
sudo apt install -y python3.10 python3-pip python3-venv
python3 -m venv /opt/aisys-env
source /opt/aisys-env/bin/activate

# 3. 의존성 설치
pip install -r requirements.txt
# - fastapi
# - uvicorn
# - psycopg2-binary
# - sqlalchemy
# - pandas
# - scikit-learn
# - konlpy
# - pgvector

# 4. PostgreSQL 설치
sudo apt install -y postgresql postgresql-contrib
sudo systemctl start postgresql
sudo -u postgres createdb aisys_db
sudo -u postgres createuser aisys_user -P

# 5. pgvector 설치
sudo apt install -y postgresql-server-dev-14
cd /tmp
git clone https://github.com/pgvector/pgvector.git
cd pgvector
make
sudo make install

# 6. 데이터베이스 초기화
psql -U aisys_user -d aisys_db -f code/db/schema.sql
psql -U aisys_user -d aisys_db -f code/db/seed.sql

# 7. FastAPI 실행
uvicorn code.backend.app.main:app --host 0.0.0.0 --port 8000

# 8. Nginx 리버스 프록시 설정
sudo apt install -y nginx
# (nginx 설정 파일 작성...)
sudo systemctl restart nginx

# 9. SSL 인증서 (Let's Encrypt)
sudo apt install -y certbot python3-certbot-nginx
sudo certbot certonly --nginx -d yourdomain.com
```

#### 2단계: iOS 앱 수정

```swift
// code/ios/AISYSApp/Sources/NetworkService.swift

// 1. API 엔드포인트 변경
#if DEBUG
    private static let fallbackBaseURL = "http://yourdomain.com:8000"
#else
    private static let fallbackBaseURL = "https://yourdomain.com"
#endif

// 2. 헬스 체크 추가
await NetworkService.shared.healthCheck()

// 3. 오류 핸들링
if !backendConnected {
    // 로컬 모드로 자동 폴백
    useFallback = true
}
```

#### 3단계: 모니터링 & 로깅

```python
# code/backend/app/main.py

from pythonjsonlogger import jsonlogger
import logging

# 구조화된 로깅 설정
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@app.post("/search")
def search_cases(q: str, limit: int = 10):
    logger.info("search_query", extra={
        "query": q,
        "limit": limit,
        "timestamp": datetime.now().isoformat()
    })
    # ...

# Sentry 통합
import sentry_sdk
sentry_sdk.init("https://your-sentry-dsn@sentry.io/...")
```

### Phase 3: AppStore 제출

#### 1단계: 앱 검토 준비

```
1. 앱 정보 작성
   - 앱 이름: "AI_SYS - 판례 통합 학습"
   - 설명: "OCR 스캔으로 판례 분석 및 OX 퀴즈 생성"
   - 스크린샷: 5장
   - 미리보기 영상: 30초

2. 개인정보 보호 정책
   - 로컬 처리: SwiftData에만 저장
   - 서버 연결 시: 익명화된 데이터 전송
   - 모델: 기기 내 저장, 전송 없음

3. 심사 체크리스트
   ✓ 암호화: HTTPS only
   ✓ 개인정보: 최소 수집
   ✓ 광고: 없음
   ✓ IAP: 없음 (무료 앱)
   ✓ 분류: 교육
```

#### 2단계: 앱 스토어 배포

```bash
# Xcode에서
1. Product → Archive
2. Organizer → Distribute App
3. App Store Connect → Upload
4. 메타데이터 검토
5. 제출
6. Apple 심사 (1-3일)
```

---

## 배포 후 운영

### 모니터링 (CloudWatch)

```
1. 주요 지표
   - API 응답시간: 목표 < 500ms
   - 에러율: 목표 < 1%
   - CPU 사용률: 목표 < 30%
   - 메모리 사용률: 목표 < 60%

2. 알람 설정
   - 응답시간 > 1초 → 알림
   - 에러율 > 5% → 알림
   - CPU > 80% → 알림

3. 대시보드
   - 실시간 요청/응답 시간
   - 5분 단위 에러율
   - 1시간 단위 활성 사용자
```

### 데이터 관리

```
1. 정기 백업 (매일)
   - PostgreSQL 풀 백업
   - S3에 저장
   - 30일 보관

2. 벡터 인덱스 최적화 (주간)
   - pgvector REINDEX
   - 성능 분석

3. 로그 정리 (월간)
   - 90일 이상 로그 삭제
   - 아카이빙
```

---

## 기술 스택 요약

| 계층 | 기술 | 버전 |
|------|------|------|
| **프론트엔드** | Swift/SwiftUI | 5.0+ |
| **로컬 모델** | llama.cpp/llama.swift | latest |
| **로컬 DB** | SwiftData | iOS 17+ |
| **OCR** | Vision.framework | native |
| **백엔드** | FastAPI | 0.100+ |
| **데이터베이스** | PostgreSQL | 14+ |
| **벡터 검색** | pgvector | 0.5+ |
| **호스팅** | AWS EC2 | t3.medium |
| **CI/CD** | GitHub Actions | native |

---

## FAQ

### Q: 왜 로컬 LLM을 선택했나?
A: 판례라는 민감한 법률 정보의 프라이버시 보호, 네트워크 지연 제거, 사용자 경험 향상

### Q: 모델을 바꿀 수 있나?
A: 네, GGUF 포맷의 다른 모델로 교체 가능
- 예: Mistral 7B, Qwen, LLaMA 2

### Q: 벡터 검색의 이점은?
A: 키워드 검색보다 의미론적 유사도로 더 정확한 판례 검색

### Q: 오프라인에서 사용 가능한가?
A: 로컬 경로는 100% 오프라인 가능
- OCR, LLM, OX 퀴즈 모두 로컬

### Q: 학습 데이터 수집은?
A: 대법원 판례 검색 API (공개 데이터)
- /code/backend/scripts/fetch_cases.py 참조

---

## 라이센스 & 기여

- **라이센스**: MIT
- **모델**: GGUF (Llama 3.2 1B, CC-BY-NC-4.0)
- **데이터**: 대법원 공개 판례 (공정 이용)

---

**작성일**: 2026년 5월 6일  
**최종 검토**: 2026년 5월 7일 / Conditional Release

