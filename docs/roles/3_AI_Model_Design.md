# AI 모델 설계 (AI Model Design)

## 개요
AI_SYS의 AI 모델 설계는 정보 검색(Information Retrieval)과 프롬프트 엔지니어링을 중심으로 합니다. 현재 구현은 온디바이스 LLM(LlamaSwift/llama.cpp)과 서버 검색 API를 결합해 판례 요약/퀴즈 생성을 수행합니다.

---

## 책임사항

### 1. 정보 검색 모델 개발
- 키워드 기반 검색 알고리즘
- 의미론적 유사도 계산
- 검색 결과 순위 매김

### 2. 프롬프트 엔지니어링
- 프롬프트 템플릿 작성
- 사용자 입력 최적화
- 출력 포맷 정의

### 3. LLM 통합 및 최적화
- 로컬 모델(GGUF) 로딩/추론 최적화
- 서버 검색 결과와의 결합
- 폴백 엔진 기반 서비스 연속성 확보

### 4. 모델 성능 평가
- 정확도 측정
- 응답 시간 분석
- 사용자 만족도 평가

### 5. 정책/판례 분석
- 정책 의도 파악
- 판례 유사성 분석
- 권한 검증 로직 개발

---

## 기술 스택

| 항목 | 기술 |
|------|------|
| **로컬 모델** | GGUF (예: Llama-3.2-1B-Instruct 계열) |
| **프레임워크** | LlamaSwift (llama.cpp iOS) |
| **검색 엔진** | 키워드 기반 + 벡터 기반 검색 |
| **개발 언어** | Python, Swift |

---

## 프로젝트 구조

```
code/
├── stitch_prompts_ai_sys.txt        # 프롬프트 템플릿 모음
├── backend/
│   └── app/
│       ├── grounding.py             # 모델 기반 응답 생성
│       └── main.py                  # API 엔드포인트
└── ios/
    └── AISYSApp/Sources/
        ├── LLMService.swift         # 로컬 LLM 서비스
        ├── LocalLLMEngines.swift    # LLM 엔진 설정
        └── PromptTemplates.swift    # 프롬프트 템플릿

data/
├── raw/                             # 원본 정책/판례 데이터
├── normalized/                      # 정규화된 데이터
├── templates/
│   └── scourt_permission_request_email.md  # 이메일 템플릿
└── policy/
    └── SCourt_Policy_Check_Guide.md # 정책 검증 가이드
```

---

## 주요 파일 설명

### `stitch_prompts_ai_sys.txt`
- 모든 프롬프트 템플릿 모음
- 역할별 프롬프트 정의
- Few-shot 예제 포함

### `grounding.py`
- 백엔드의 AI 추론 로직
- 정책/판례 데이터 활용
- 응답 생성 및 검증

### `LLMService.swift`
- `LlamaCppEngine` / `RuleBasedLocalEngine` 이중 엔진 구조 관리
- `summarize()`, `generateQuiz()`, `compare()` 인터페이스 제공
- 앱 시작 시 선로딩, ready 상태 대기

### `PromptTemplates.swift`
- `LLMPromptTemplate.summarize()` — 판례 요약 (one_line_summary / key_issue / ruling_point / exam_takeaway)
- `LLMPromptTemplate.compare()` — 판례 비교 (common_points / differences / likely_exam_trap / citations)
- `LLMPromptTemplate.quiz()` — 객관식 퀴즈 생성 (prompt / options / answer / explanation)
- 모든 템플릿: `[ROLE]`, `[TASK]`, `[EVIDENCE]`, `[RULES]`, `[OUTPUT]` 구조

### `grounding.py` (backend)
- `HALLUCINATION_RULES`: 5가지 환각 방지 규칙 정의
  - `must_have_citation` — 모든 법적 주장에 인용 필수
  - `citation_must_exist_in_retrieval` — 인용된 사건번호는 검색 결과 내에 있어야 함
  - `no_unsupported_numeric_facts` — 근거 없는 날짜/조리번호/수치 금지
  - `uncertainty_on_missing_evidence` — 증거 부족 시 명시적 불확실성 진술 필요
  - `quote_must_match_snippet` — 인용문은 증거 스니펫과 실제 일치 필요
- `validate_grounded_answer()` — 서버 사이드 경량 검증, 위반된 규칙 키 반환

---

## 프롬프트 아키텍처

### 프롬프트 구성 요소

```
1. 시스템 프롬프트 (System Prompt)
   - 모델의 역할 정의
   - 동작 방식 설명
   
2. 사용자 입력 (User Input)
   - 질문 또는 요청
   
3. 컨텍스트 (Context)
   - 관련 정책/판례 정보
   
4. 제약 조건 (Constraints)
   - 출력 포맷
   - 길이 제한
```

### 템플릿 예제

**검색 쿼리 확장**
```
System: 당신은 법률 정보 검색 전문가입니다.
User: "권한 신청"을 관련 검색어로 확장하세요.
Response: [권한 신청, 권한 검증, 승인 절차, ...]
```

**케이스 분석**
```
System: 제공된 정책을 기반으로 권한 검증을 수행하세요.
User: 사용자가 X 권한을 요청했습니다.
Context: [관련 정책 내용]
Response: {
  "권한": "X",
  "승인": true/false,
  "이유": "..."
}
```

---

## 정보 검색 모델

### 1. 키워드 기반 검색
```
검색어 전처리 → 토큰화 → 정규화 → 매칭
```

### 2. 벡터 기반 검색 (향후 확장)
```
텍스트 → 임베딩 → 유사도 계산 → 순위 매김
```

### 3. 검색 결과 순위 매김
- TF-IDF 점수
- 사용자 상호작용 데이터
- 시간 기반 가중치

---

## 환각 방지 (Grounding)

### `HALLUCINATION_RULES` (grounding.py)

| 규칙 키 | 설명 |
|---------|------|
| `must_have_citation` | 모든 법적 주장에 사건번호 인용 필수 |
| `citation_must_exist_in_retrieval` | 인용 사건번호는 검색 결과에 실제 존재해야 함 |
| `no_unsupported_numeric_facts` | 근거 없는 날짜/조리번호/수치 삽입 금지 |
| `uncertainty_on_missing_evidence` | 증거 부족 시 명시적 불확실성 진술 필요 |
| `quote_must_match_snippet` | 인용문은 증거 스니펫과 실제 일치 필요 |

### `validate_grounded_answer()` (server-side)
```python
# 사용 예
위반 = validate_grounded_answer(
    answer_text=generated_text,
    cited_case_numbers=["2021도16503"],
    retrieved_case_numbers={"2021도16503", "2022도12345"}
)
# 반환: 위반된 규칙 키 리스트 ([] = 정상)
```

---

## 모델 성능 지표

### 응답 시간 (Latency)
- 로컈 데이터 로드 (`loadInitialCasesIfNeeded`): 네트워크 상태에 따라 다름
- LLM 추론 참조: RuleBasedEngine < LlamaCpp (실기기 계측 미완료)
- 서버 검색 응답: `timeoutIntervalForRequest: 8초` 기준

### 파싱 성공률
- `LLMSummary(rawOutput:)` 실패 시 fallback 데이터 (`toCaseDetail()`) 사용
- 목표: 파싱 실패률 < 5% (미달성, 현재 관측 미제)

---

## 로컬 LLM 최적화

### 모델 선택 이유
- **GGUF 경량 모델**: 모바일 디바이스에서의 로컬 추론 적합
- **양자화 모델(Q4 계열)**: 메모리 사용량 절감과 응답 속도 균형

### 최적화 기법

1. **프롬프트 최적화**
   - 불필요한 토큰 제거
   - 명확한 지시사항 제공

2. **모델 양자화**
   - 정밀도 손실 최소화
   - 메모리 사용량 감소

3. **배치 처리**
   - 여러 요청 동시 처리
   - 처리량 증가

---

## 개발 워크플로우

### 1. 프롬프트 개발
```
초안 작성 → 테스트 → 평가 → 최적화 → 배포
```

### 2. 모델 평가
```
테스트 세트 준비 → 평가 메트릭 정의 → 성능 측정 → 개선
```

### 3. A/B 테스트
```
버전 A 배포 → 사용자 피드백 수집 → 버전 B 테스트 → 최종 선택
```

---

## 데이터 흐름

```
사용자 입력 또는 OCR 추출 텍스트
    ↓
[정보 검색] - 키워드/유사도 기반 후보 판례 검색
    ↓
[유사 판례 Top-K] 선정
    ↓
[프롬프트 템플릿]에 근거 데이터 결합
    ↓
온디바이스 LLM 추론 (키워드 추출/요약/OX 퀴즈)
    ↓
응답 생성 및 Grounding 검증
    ↓
사용자에게 제시
```

---

## 앱 개발 흐름 (설계안, 미구현)

이 섹션은 앞으로 구현할 기능의 목표 흐름을 정리한 설계 문서이며, 현재 코드에 전부 반영된 상태는 아닙니다.

### 목표 시나리오

1. OCR 입력
- 사용자가 판례 원문 이미지를 업로드/촬영
- OCR로 원문 텍스트 추출

2. 정보 검색(IR)
- 추출 텍스트에서 검색용 토큰/질의 생성
- 단어 벡터화(임베딩) 후 문서 간 유사도 계산
- 유사도 점수 기반 Top-K 유사 판례 검색

3. 유사 판례 찾기 기능
- 앱 내 "유사한 판례 찾기" 탭/버튼에서 후보 목록 제공
- 유사도 점수, 핵심 쟁점, 사건번호를 함께 노출

4. 온디바이스 LLM 후처리 (Llama)
- OCR 원문 + Top-K 판례를 근거로 키워드 추출
- 학습용 간단 요약 생성
- O/X 퀴즈 생성(기초 난이도)

5. 안전장치
- LLM 출력은 근거 없는 사실 생성 방지를 위해 Grounding 규칙으로 검증
- 검증 실패 시 폴백(간단 요약/퀴즈 미생성 또는 안전 문구)

### AI 모델 설계 파트 담당 범위

- OCR 이후 IR 파이프라인 설계 (토큰화, 임베딩, 유사도 계산, Top-K 전략)
- 유사 판례 추천 랭킹 로직 설계
- 온디바이스 LLM 프롬프트 설계 (키워드/요약/OX 퀴즈)
- 출력 검증 규칙 및 실패 폴백 정책 설계

### 단계별 구현 제안

1. Phase 1: OCR 텍스트 정제 + 키워드 검색 기반 유사 판례 MVP
2. Phase 2: 임베딩/벡터 유사도 검색 도입
3. Phase 3: Llama 기반 키워드 추출 + 간단 요약
4. Phase 4: O/X 퀴즈 생성 + Grounding 검증 자동화

---

## 상호작용

### 백엔드와의 상호작용
- `grounding.py`를 통한 추론 처리
- 정책/판례 데이터 활용

### 프론트엔드와의 상호작용
- 로컬 LLM을 통한 오프라인 추론
- 프롬프트 템플릿 적용

### 데이터 관리와의 상호작용
- 정책/판례 데이터 활용
- 데이터 품질 피드백

---

## 참고 문서
- [프롬프트 템플릿](../code/stitch_prompts_ai_sys.txt)
- [정책 검증 가이드](../data/policy/SCourt_Policy_Check_Guide.md)
- [데이터 빌드 가이드](../code/Data_Build_Guide_AI_SYS.md)

---

## 참고 코드 및 추가 작성 항목

### 참고 코드 (현재 기준)
- `code/ios/AISYSApp/Sources/PromptTemplates.swift` - summarize/compare/quiz 프롬프트 템플릿
- `code/ios/AISYSApp/Sources/LLMService.swift` - 추론 호출 체인 및 상태 관리
- `code/ios/AISYSApp/Sources/LocalLLMEngines.swift` - LlamaCpp/RuleBased 엔진 전환 로직
- `code/ios/AISYSApp/Sources/Models.swift` - `LLMSummary` 파싱 및 fallback 변환
- `code/backend/app/grounding.py` - Grounding 규칙 및 검증 함수
- `code/backend/app/schemas.py` - `SearchEvidence`, `SearchResponseV2`, `GroundedAnswer*` 스키마

### 추가 작성 항목 (다음 단계)
1. OCR 원문 기반 키워드 추출 프롬프트(`extract_keywords`) 추가
2. O/X 퀴즈 생성 전용 프롬프트 및 파서 추가
3. Top-K 유사 판례 evidence를 일관되게 주입하는 생성 체인 보강
4. 파싱 실패 로그/보정 규칙 정교화 및 실패율 지표화

---

## 현재 진행 상황 (기준: 2026-04-28)

### 완료 사항 ✅

| 항목 | 상세 |
|------|------|
| 온디바이스 LLM 전략 확정 | 서버형 → 로컬 추론(LlamaSwift + GGUF) 전략으로 전환 완료 |
| LLM 상태 머신 | loading / ready / inferring / error 상태 관리 구현 |
| 프롬프트 흐름 구현 | 요약 / 퀴즈 생성 / 비교 프롬프트 흐름 구현 |
| 선로딩 로직 | 앱 시작 시 모델 선로딩 및 ready 대기 로직 반영 |
| Rule-based 폴백 | 엔진 실패 시 규칙 기반 fallback으로 기능 연속성 확보 |
| 정보 검색 기본 구성 | 사건번호/키워드 기반 검색 API와 연동 |

### 전략 전환 배경 (서버형 → 로컬형)

| 항목 | 이전 전략 | 현재 전략 |
|------|-----------|----------|
| 추론 위치 | 서버 API 호출 | 온디바이스 로컬 추론 |
| 오프라인 지원 | 불가 | 가능 |
| 개인정보 보호 | 외부 전송 발생 | 최소화 |
| 서버 비용 | 변동 리스크 | 없음 |
| 전환 이유 | — | 오프라인 학습 환경, 네트워크 의존도 감소 |

### 현재 제한 사항 ⚠️

- **출력 포맷 파싱 불안정**: 요약/퀴즈 파싱 실패 케이스 발생, 안정화 필요
- **모델 파라미터 미튜닝**: 샘플링 파라미터 최적화 미완료
- **실기기 성능 미계측**: 지연시간/발열/메모리 계측 기반 최적화 미흡
- **검색 정확도 고도화 미완료**: 재순위화, 쿼리 확장, 동의어 처리 미완

### 다음 작업 (우선순위 순)

1. **[P0]** 프롬프트 포맷 고정 — 필드 키 강제로 파싱 실패율 감소 (목표: < 5%)
2. **[P0]** 파서 보강 — 누락 필드 보정, 안전 디폴트 처리
3. **[P0]** 실패 로그 수집 포인트 추가
4. **[P1]** 검색 쿼리 정규화 — 불용어/동의어/사건번호 우선순위 처리
5. **[P2]** 개인화 고도화 — 오답 유형별 복습 추천, 과목/쟁점 기반 학습 경로 제안
6. **[P2]** 실기기 성능 계측 및 모델 파라미터 튜닝

---

**마지막 업데이트**: 2026-04-28
