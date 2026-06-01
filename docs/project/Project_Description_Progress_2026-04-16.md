# AI_SYS 진행상황 상세 보고서

작성일: 2026-04-16
최종 업데이트: 2026-05-07
문서 버전: v1.3

## 1. 목적
이 문서는 현재 저장소 기준 구현 진행 상태를 코드/DB/API/앱 연동 관점에서 상세히 기록한다.
특히 다음 항목의 완료 여부를 명확히 한다.
- iOS 앱 <-> 백엔드 API <-> PostgreSQL 연결 상태
- Swift 더미 데이터의 DB 이관 여부
- llama.cpp 기반 로컬 LLM 추론 엔진 구현 상태
- OCR 및 화면 UX(소형 뒤로가기 포함) 구현 상태
- 실기기(iPhone) 테스트 준비 상태

## 2. 현재 아키텍처 상태

앱 (SwiftUI)
-> API 서버 (FastAPI)
-> DB (PostgreSQL)
-> 로컬 LLM (llama.cpp via LlamaSwift)

보조 흐름:
- OCR(Vision) 입력 -> 검색 탭 쿼리 전달 -> /search API 조회
- Home 대시보드 -> /dashboard/recommended, /dashboard/wrong-answers 조회

## 3. 백엔드 진행 상태

### 3-1. 기존 구현 확인
- /health
- /search
- /cases/{case_number}
- /cases

### 3-2. 신규 구현
대시보드 API 추가:
- GET /dashboard/recommended
  - published_cases 기반 추천 복습 카드 반환
  - case_number, case_name, subject, issue, accuracy 필드 제공
- GET /dashboard/wrong-answers
  - user_case_history + cases 조인 기반 오답 목록 반환
  - title, memo, date 필드 제공

### 3-3. 스키마 확장
pydantic 응답 모델 신규 추가:
- RecommendedCaseItem
- WrongAnswerListItem
- RecommendedCasesResponse
- WrongAnswersResponse

## 4. DB(더미 데이터 이관) 진행 상태

### 4-1. 기존 상태
- 초기 데이터는 제한된 건수로 운영되었다.

### 4-2. 신규 이관
Swift 앱 데이터 흐름을 DB 중심 구조로 정리했다.
추가 case_number 목록:
- 2021도16503
- 2022도12345
- 2021도1234
- 2020도4521
- 2018도19876
- 2023도16220
- 2021도20457
- 2017도18543

또한 오답노트 데이터를 user_case_history 기반으로 정리했다.

결과적으로 앱 더미 데이터와 DB 데이터의 정합성이 크게 개선되었고,
백엔드 연결 시 앱이 실제 DB 기반 데이터로 동작한다.

## 5. iOS 앱 진행 상태

### 5-1. NetworkService 확장
- API_BASE_URL 오버라이드 지원 (UserDefaults)
- 현재 baseURL 확인 함수 추가
- 추천/오답 대시보드 API 호출 함수 추가

### 5-2. 모델/스토어 확장
- APIRecommendedCase, APIWrongAnswerItem 추가
- ReviewStore.applyRemoteDashboard() 추가
- Home 대시보드가 원격 데이터로 갱신 가능

### 5-3. Home 화면
- 백엔드 연결 시 추천 복습/오답 노트를 DB 기반으로 로드
- 현재 연결 중인 API 주소 표시
- 실패 시 로컬 더미 폴백 메시지 표시

### 5-4. OCR
- PhotosPicker + Vision OCR 구현
- 인식 텍스트를 검색 쿼리로 전달
- OCR 탭에서 Search 탭으로 자동 이동

### 5-5. 네비게이션 UX
- 주요 상세 뷰에 소형 뒤로가기 버튼 적용

## 6. 로컬 LLM(llama.cpp) 진행 상태

### 6-1. 패키지 연결
- LlamaSwift 패키지 연결 완료
- canImport(LlamaSwift) 경로에서 컴파일됨

### 6-2. 엔진 구현
LlamaCppEngine에서 다음이 구현됨:
- GGUF 모델 로드
- llama context 생성
- sampler chain(top-k/top-p/temp/dist) 구성
- prompt 토크나이즈
- decode + sample 루프 기반 생성
- token piece 디코딩

### 6-3. 현재 제한
- 모델/프롬프트/샘플링 파라미터 튜닝은 추가 작업 필요
- iOS 16.0 타겟에서 llama 프레임워크가 16.4로 빌드된 경고가 있음(빌드 자체는 성공)

## 7. 실기기 테스트 준비 상태

### 7-1. API 연결
- 앱 내 MyPage에서 API 서버 주소를 직접 저장 가능
- 예: http://192.168.x.x:8000
- 저장 시 API_BASE_URL 오버라이드가 즉시 반영됨

### 7-2. 모델 파일
- 앱은 Documents/models 경로에서 GGUF 탐색
- 권장 파일명:
  Llama-3.2-1B-Instruct-Q4_K_M.gguf

### 7-3. iPhone 테스트 체크포인트
- Home 대시보드가 DB 데이터로 바뀌는지
- OCR 결과가 Search로 전달되는지
- CaseSummary 진입 시 로컬 LLM 생성 경로가 동작하는지
- 오프라인/백그라운드 복귀 시 안정성

## 8. CoreML vs llama.cpp 판단

현재 결론:
- 단기: llama.cpp 유지가 가장 현실적
  - 이미 GGUF 자산과 엔진 코드가 연결됨
  - 온디바이스 추론 경로 완성도가 더 높음
- 중장기: CoreML 병행 검토
  - 분류/랭킹/태깅 같은 경량 태스크부터 CoreML 전환
  - 생성형 전체를 CoreML로 옮기려면 모델 변환/품질/메모리 검증 비용이 큼

권장 전략:
1) 지금은 llama.cpp 기반 기능 완성
2) 성능 병목 구간만 CoreML 보조 모델 도입

## 9. 남은 주요 작업
- 실기기에서 API_BASE_URL 저장 후 실제 Mac API 통신 E2E 확인
- LLM 출력 포맷 안정화(LLMSummary 파싱 실패율 감소)
- 대시보드 추천 정확도 로직 고도화(현재는 단순 점수식)
- 에러/로딩 상태 UX 세부 개선

## 10. 결론
요청한 핵심 범위(앱-API-DB-LLM 연결, 더미 데이터 이관, OCR 연결, 실기기 준비)는 코드 기준으로 대부분 완료되었다.
현재 단계는 기능 완성 1차를 통과했으며, 실기기 E2E 검증 및 성능 튜닝이 다음 단계의 중심 과제다.

## 11. 2026-04-17 추가 반영 사항

### 11-1. 백엔드/DB 운영 이슈 해결
- 증상: Home 대시보드에서 /dashboard/recommended 호출 시 404 발생
- 원인: 잘못된 compose 프로젝트(ai_sys) 인스턴스가 8000 포트를 점유
- 조치:
  - 기존 ai_sys 스택 down
  - STACK112 기준 스택 재기동
  - DB init 실패("Resource deadlock avoided")는 볼륨 초기화 + 경로 재검증 후 정상화
- 검증:
  - /health 200
  - /dashboard/recommended 200 확인

### 11-2. LLM 준비 상태 개선
- 증상: 상세 화면에서 "LLM 엔진이 준비되지 않았습니다." 메시지 발생
- 조치:
  - 앱 시작 시 LLM 선로딩
  - 요약/퀴즈 실행 전 ready 상태 대기 로직 추가
- 효과:
  - 초기 진입 시 not-ready 발생 빈도 완화

### 11-3. 내비게이션 UX 정리
- 요청 반영: 주요 화면 전체에 공통 뒤로가기 버튼 적용
- 적용 대상:
  - Home, OCR, Search, Review, My Page
  - 상세/퀴즈/오답 저장 화면

## 12. 2026-05-07 추가 반영 사항 (LLM 품질·백엔드 안정화 사이클)

이번 사이클은 사용자 리서치(경찰 시험 수험생) 피드백과 실기기에서 관찰된 "LLM 출력이 조잡함" 이슈를 기점으로,
강의 대체가 아닌 "복습/오답 보조" 포지셔닝을 코드 전반에 강제하는 작업이 중심이었다.

### 12-1. iOS 안정성 (실기기 크래시 / 빌드 실패 차단)
- "판례 분석 시작" 진입 시 SIGABRT 크래시 → 원인 두 가지 동시 수정
  - OCRView 의 `recognize` / `processOCRText` 에 `@MainActor` 격리 적용해 동시성 충돌 제거
  - LlamaCppEngine prefill `batchLimit`을 `n_batch` 값과 일치(64/96/120, 메모리 티어별)시켜 llama_decode 내부 abort 차단
- `LLMService.isUsefulOXItem` 에서 Swift `String.matches(of:)` 미지원으로 인한 빌드 실패 → `NSRegularExpression` 기반 `countMatches(in:pattern:)` 헬퍼로 교체
- 손상된 `HomeView.swift` / `.gitignore` / `.github/` 디렉터리를 origin/임재현 에서 복구

### 12-2. iOS LLM 출력 품질 (요약/OX 품질 1차 안정화)
- Llama-3.2-Instruct GGUF에 chat template 미적용으로 base 모델처럼 동작하던 문제를 수정
  - `LLMService.wrapForLlama3Instruct(userPrompt:purpose:)` 추가 — 공식 `<|begin_of_text|>...system/user/assistant<|eot_id|>` 포맷 적용
  - 목적별(summarize/ox_quiz/quiz/compare) 시스템 메시지 분리 — "강의 대체 금지 / 근거 기반 / 형식 고정" 규칙을 system role에 고정
- `PromptTemplates.oxQuiz` 강화
  - "출력 예시 단어를 그대로 복사하지 마라" 명시 추가
  - 한 글자/숫자 함정 예시(14일↔10일, 위원장↔부위원장 등) 직접 제공
- `PromptTemplates.summarize` 강화
  - "강의 대체 금지 / 한 글자·숫자 함정 / 근거 없는 단정 금지" 규칙을 한국어로 강제
- OCR 진입 시 Vision 결과 후처리 추가 (`OCRView`)
  - `refineIRSentences()` / `inferIssueSummary()` / `inferHoldingSummary()` 로 OCR 원문에서 쟁점/결론 후보 1차 추출
  - `CaseSummaryViewModel.injectIRResult()` 가 OCR 주입 IR 을 보존하도록 수정 (이전에는 화면 진입 시 IR이 초기화돼 버려졌음)

### 12-3. iOS OX 퀴즈 품질·안전성
- `LLMService.isUsefulOXItem` 강화: 8~96자 길이 제한, 조문 4회 이상 폭주 컷, URL 컷, 출력 예시 echo(`진술 1`, `<문항`, `한국어 진술`) 컷
- `LLMService.sanitizeQuizStatement` 추가: 다중 조문 나열 압축, 88자 컷
- `LLMService.negateStatement` 안전화
  - 유죄↔무죄 단순 치환 제거 (원문에 두 단어가 동시 등장하는 경우 X 라벨 오답이 발생할 수 있어 위험)
  - "해당한다↔해당하지 않는다", "위법하다↔적법하다" 같은 명백한 단방향 패턴만 안전 부정
  - 안전 패턴이 없으면 "원문 결론과 정반대이다" 형태의 메타 부정 진술로 폴백
- `OXQuizQuestion.parseList` 정규식 기반 파싱을 라인 기반 prefix 매칭으로 교체
  - statement 내 `:` 가 들어가도 잘리지 않음
  - "참" / "TRUE" 도 O로 인정해 LLM 표기 차이 흡수

### 12-4. iOS RAG 연동 / 학습 가이드 카드
- `LLMService.summarize` 가 OCR 케이스/저사양 기기에서는 서버 grounded 요약(`/grounded/answer`)을 우선 시도하도록 변경
- `Models.APIIRExtractResponse`에 `domain`, `studyFocus` 추가
- `CaseSummaryViewModel`에 `irDomain`, `irStudyFocus` published state 추가
- `SearchFlowViews` 에 학습 가이드 카드 + "이 가이드로 OX 생성" 버튼 추가
  - 도메인별 한국어 라벨/아이콘/색상 매핑 (형법 / 형소-증거 / 형소-수사 / 헌법 / 경찰학-위원회 / 일반)

### 12-5. 백엔드 IR 파이프라인 / Grounded RAG
- `ir_pipeline.py`
  - `_DOMAIN_HINTS` 사전 추가 (criminal_law / criminal_procedure_evidence / criminal_procedure_investigation / constitutional_law / police_committees)
  - `infer_study_domain()` / `build_study_focus()` 추가 — 도메인별 복습 체크포인트 텍스트 자동 생성
  - 도메인 동점 처리에 명시적 우선순위(구체 도메인 우선) 적용해 dict 순서 의존 제거
- `main.py`
  - `POST /grounded/answer` 엔드포인트 신설: 사건번호/키워드 가중치 기반 retrieval + intent별(summary/compare/qa/quiz) 응답 + citation/safety_flags 반환
  - `/ir/extract` 응답에 `domain`, `study_focus` 포함
  - 유사 판례 검색에 case_name + subject 를 TF-IDF 코퍼스에 포함, 동일 subject 가중치 +0.03 reranking
  - TF-IDF 인덱스 캐시(5분 TTL) + 동시 재빌드 보호용 `threading.Lock` 도입
  - `@app.on_event("shutdown")` deprecated → FastAPI `lifespan` 핸들러로 교체
- `grounding.py`
  - `validate_grounded_answer` 가 인용문이 retrieved snippet 과 실제로 겹치는지(8자 슬라이딩 윈도우) 검증
  - `quote_must_match_snippet` rule 이 실제로 동작

### 12-6. 백엔드 보안·정확성 보강
- 사용자 입력 LIKE 와일드카드 미이스케이프 문제 수정
  - `_escape_like()` 헬퍼 추가, `_retrieve_grounded_cases` / `search_cases` 에 적용
  - 사용자 입력의 `%`, `_`, `\` 가 와일드카드로 해석돼 잘못된 매칭/성능 저하 일으키던 문제 차단
- `/grounded/answer` 가 빈/너무 짧은 질문(2자 미만)에 400 반환하도록 가드 추가
- `_retrieve_grounded_cases` 에서 빈 정규화 결과 시 빠른 반환 — 전체 row 매칭 위험 제거
- `/llm/summarize` OX 폴백이 모든 문항을 `answer=True`로 생성하던 문제 수정
  - 짝수 인덱스는 원문(O), 홀수는 안전 부정 패턴(X) 로 O/X 혼합 출제
  - 안전 부정 패턴 없으면 "본 판례 결론은 ~ 와 정반대이다" 형태 메타 부정 진술

### 12-7. 산출물 / 영향
- 빌드: Swift / Python 모두 컴파일·임포트 클린 (가상환경 미설치 환경의 fastapi 임포트 경고만 잔존)
- 사용자 체감 지점:
  - "LLM 출력이 조잡함" → chat template + 시스템 메시지 + OX 함정 강제로 1차 완화
  - "OX 가 전부 O" → 백엔드/iOS 양측에서 O/X 혼합 강제
  - "OCR 진입 시 LLM 결과 사라짐" → IR preservation + OCR 사전 후처리로 해결
  - 학습 가이드 카드 + 도메인 뱃지 → "강의 대체 금지" 포지셔닝을 UI 에서도 노출

### 12-8. 다음 후보
- `/llm/summarize` 의 규칙 기반 stub 을 서버측 LLM 으로 교체 (현재는 카드 키워드 결합)
- `build_tfidf_matrix` Python 이중 루프를 `sklearn.TfidfVectorizer` 로 치환 (동작 회귀 검증 포함)
- 도메인별 OX 함정 사전(예: 위원회별 인원·기한 숫자) DB 화하여 백엔드 OX 폴백 품질 추가 향상
- 실기기 prefill / decode 시간 계측 후 배치/컨텍스트 한도 재튜닝

