# 프론트엔드 (Frontend)

## 개요
AI_SYS의 프론트엔드는 iOS 기반의 모바일 애플리케이션으로, 사용자에게 직관적인 인터페이스를 제공합니다. 로컬 LLM을 통합하여 오프라인 기능도 지원합니다.

---

## 책임사항

### 1. 사용자 인터페이스 설계 및 구현
- SwiftUI를 활용한 UI 개발
- 사용자 경험(UX) 최적화
- 반응형 디자인

### 2. 사용자 경험(UX) 개선
- 직관적인 네비게이션
- 접근성 개선
- 성능 최적화

### 3. 로컬 LLM 통합
- Llama-3.2-1B-Instruct 모델 통합
- 오프라인 추론 지원
- 모델 성능 최적화

### 4. 이미지 인식 (OCR) 기능
- 문서 이미지 캡처
- OCR 처리
- 추출된 텍스트 처리

### 5. 백엔드 API 통신
- REST API 호출
- 네트워크 통신 관리
- 데이터 캐싱

---

## 기술 스택

| 항목 | 기술 |
|------|------|
| **플랫폼** | iOS 14+ |
| **언어** | Swift |
| **UI 프레임워크** | SwiftUI |
| **로컬 LLM** | GGUF 파일 외부 배치(`Documents/models`) + LlamaSwift |
| **네트워킹** | URLSession |

---

## 프로젝트 구조

```
code/ios/
├── project.yml                    # Xcode 프로젝트 설정
├── README.md                      # iOS 설명 문서
├── AISYS.xcodeproj/              # Xcode 프로젝트
│   ├── project.pbxproj
│   └── project.xcworkspace/
└── AISYSApp/
    ├── Sources/
    │   ├── AISYSApp.swift                 # 앱 진입점
    │   ├── AppRuntimeState.swift          # 앱 상태 관리
    │   ├── LLMService.swift               # 로컬 LLM 서비스
    │   ├── LocalLLMEngines.swift          # LLM 엔진 설정
    │   ├── NetworkService.swift           # 백엔드 통신
    │   ├── OCRView.swift                  # 이미지 인식 화면
    │   ├── HomeView.swift                 # 홈 화면
    │   ├── SearchFlowViews.swift          # 검색 플로우
    │   ├── CaseSummaryViewModel.swift     # 케이스 요약 로직
    │   ├── RootTabView.swift              # 탭 네비게이션
    │   ├── NavigationBackButton.swift     # 뒤로가기 버튼
    │   ├── Models.swift                   # 데이터 모델
    │   └── PromptTemplates.swift          # 프롬프트 템플릿
    └── AISYSAppTests/
        └── AISYSAppTests.swift            # 단위 테스트
```

---

## 주요 파일 설명

### `AISYSApp.swift`
- SwiftUI 앱 진입점
- 기본 애플리케이션 구조
- 윈도우 정의

### `AppRuntimeState.swift`
- 탭 선택 상태 (`selectedTab: Int`)
- OCR → Search 탭 간 쿼리 전달 (`pendingSearchQuery: String?`)
- `@MainActor` 기반 화면 전용 상태 관리

### `LLMService.swift`
- 이중 엔진 구조: `LlamaCppEngine`(주개) + `RuleBasedLocalEngine`(fallback)
- 상태 머신: `idle` → `loading(progress)` → `ready` → `inferring` → `error`
- 주개 엔진 실패 시 Rule-based fallback 자동 전환
- `@MainActor` 기반, `@Published` 상태 노출

### `NetworkService.swift`
- `actor` 기반 스레드 안전 구현
- `timeoutIntervalForRequest: 8초`, `timeoutIntervalForResource: 12초`
- `waitsForConnectivity: false` (실기기 네트워크 지연 방지)
- JSON `keyDecodingStrategy: .convertFromSnakeCase` 적용
- `UserDefaults` 기반 API 주소 오버라이드 지원
- `/health`, `/search`, `/cases`, `/cases/{caseNumber}`, `/dashboard/recommended`, `/dashboard/wrong-answers` 등 호출 메서드 구현

### `OCRView.swift`
- `PhotosPicker` + `Vision OCR` 조합
- OCR 인식 텍스트를 `AppRuntimeState.pendingSearchQuery`에 저장
- `SearchView`에서 `onChange(of: runtime.pendingSearchQuery)`로 자동 검색 실행

### `PromptTemplates.swift`
- LLM 프롬프트 템플릿
- 사용자 입력 템플릿화
- 응답 포맷 정의

---

## 주요 기능

### 1. 홈 화면
- 최근 검색 내역
- 빠른 액세스 메뉴
- 시스템 상태 표시

### 2. 검색 기능
- 키워드 검색
- 필터링 옵션
- 검색 결과 표시

### 3. OCR 기능
- 문서 이미지 촬영
- 텍스트 자동 추출
- 추출된 내용 검토

### 4. 케이스 분석
- 분석 요청
- 실시간 처리
- 결과 표시

### 5. 로컬 LLM 통합
- 오프라인 추론
- 빠른 응답 시간
- 프라이버시 보호

---

## 개발 워크플로우

### 1. 환경 설정
```bash
cd code/ios
open AISYS.xcodeproj
```

### 2. 빌드 및 실행
```bash
xcodebuild build
xcodebuild test
```

### 3. 시뮬레이터 실행
- Xcode에서 원하는 시뮬레이터 선택
- ▶ 버튼으로 실행

### 4. 디바이스 배포
- 실제 iOS 디바이스 연결
- 서명 설정
- 배포 실행

---

## 화면 구조

```
RootTabView (탭 네비게이션)
├── HomeView (탭 0 - 홈)
│   ├── 복습 대시보드 (추천 건수, 오답 건수)
│   ├── 현재 API 주소 표시
│   ├── 추청 복습 카드 목록 (/dashboard/recommended)
│   └── 주요 오답 노트 (/dashboard/wrong-answers)
├── OCRView (탭 1 - 스캔)
│   ├── PhotosPicker
│   ├── Vision OCR 처리
│   └── 텍스트 추출 후 SearchView로 쿼리 전달
├── SearchView (탭 2 - 검색)
│   ├── 키워드 검색 입력 (TextField)
│   ├── 추천 키워드: 영장주의, 자백배제법칙, 위법수집증거
│   ├── 검색 결과 카드 (SearchResultCard)
│   └── CaseSummaryView 진입
│       ├── LLM 요약 표시 (LLMSummary)
│       ├── 퀴즈 생성 트리거
│       └── QuizView (객관식 표시/정답/해설/오답 저장)
├── ReviewView (탭 3 - 복습)
│   └── 오답 리스트 조회
└── MyPageView (탭 4 - My Page)
    └── API 서버 주소 오버라이드 저장/초기화
```

---

## 앱 개발 흐름 (설계안, 미구현)

이 섹션은 현재 구현 완료 항목이 아니라, AI 모델 설계 문서와 동기화된 목표 앱 흐름입니다.

### 목표 사용자 플로우

1. OCR 입력
- 사용자가 판례 원문 이미지를 촬영/선택
- OCR 텍스트 추출 후 검색 질의 생성

2. 유사 판례 검색
- 정보검색 시스템에서 키워드/벡터 유사도 기반 후보 검색
- Top-K 유사 판례 목록 수신

3. 유사한 판례 찾기 UI
- 앱에서 사건번호, 핵심 쟁점, 유사도 점수를 카드로 표시
- 사용자가 유사 판례 상세로 진입

4. 온디바이스 LLM 학습 보조
- OCR 원문 + 유사 판례를 근거로 키워드 추출
- 간단 요약 생성
- O/X 퀴즈 생성

5. 실패 처리
- 검색 결과 부족/검증 실패 시 폴백 메시지 제공
- 기능 연속성 유지를 위해 기본 요약 또는 재시도 경로 제공

### 프론트엔드 담당 범위

- OCR 입력 UX 및 텍스트 전처리 연결
- 유사 판례 카드/상세 화면 설계
- 온디바이스 LLM 결과 표시 및 상호작용(UI)
- 실패/오프라인/타임아웃 상태 UX 설계

### 단계별 구현 제안

1. Phase 1: OCR 텍스트를 검색 탭으로 안정 전달
2. Phase 2: "유사한 판례 찾기" 목록/상세 UI 도입
3. Phase 3: 키워드 추출/요약 결과 화면 통합
4. Phase 4: O/X 퀴즈 생성 및 정답/해설 UI 완성

---

## 네트워크 통신

### 실제 API 엔드포인트
- `GET /health` — 서버 상태 확인
- `GET /search?q=&limit=` — 판례 검색
- `GET /cases?limit=` — 판례 목록
- `GET /cases/{caseNumber}` — 판례 상세
- `GET /dashboard/recommended?limit=` — 추천 복습
- `GET /dashboard/wrong-answers?user_id=&limit=` — 오답 목록

### 데이터 포맷
- 요청/응답: JSON (snakeCase → camelCase 자동 변환)
- 보디 미모델: `SearchAPIResponse`, `RecommendedCasesAPIResponse`, `WrongAnswersAPIResponse`

---

## 로컬 LLM 모델

### 모델 정보
- **형식**: GGUF
- **배치 정책**: 저장소 미포함, 기기 `Documents/models` 외부 배치
- **탐색 방식**: `LLAMA_MODEL_FILE` 우선 + fallback 파일명/첫 GGUF 자동 탐색

### 엔진 구조
- **`LlamaCppEngine`** (LlamaSwift 연동, 주개) — `#if canImport(LlamaSwift)` 조건부 로드
- **`RuleBasedLocalEngine`** (fallback) — LlamaSwift 로드 실패 시 자동 전환

### 모델 로케이터 (`LocalLLMModelLocator`)
1. `Documents/models/` 폴더에서 파일 탐색 (Info.plist `LLAMA_MODEL_FILE` 또는 fallback 이름)
2. 없으면 번들에서 선택적으로 탐색 후 `Documents/models/`로 복사
3. 둘 다 실패하면 Rule-based fallback 엔진 사용

### 실기기 운영 체크
- 실기기 모델 배치 절차 및 장애 점검표는 `code/ios/README.md`의 "실기기 모델 배치 절차" 섹션을 기준으로 운영

---

## 성능 최적화

### 메모리 관리
- 큰 모델 파일 효율적 로드
- 메모리 누수 방지

### 네트워크 최적화
- 요청 배치 처리
- 캐싱 전략
- 타임아웃 관리

### UI 반응성
- 백그라운드 작업 비동기 처리
- 메인 스레드 보호

---

## 상호작용

### 백엔드와의 상호작용
- REST API를 통한 데이터 송수신
- 에러 처리 및 재시도

### AI 모델 설계와의 상호작용
- 로컬 LLM 프롬프트 최적화
- 사용자 입력에 맞춘 템플릿 제공

### 데이터 관리와의 상호작용
- 로컬 데이터 캐시
- 서버 데이터 동기화

---

## 참고 문서
- [iOS 상세 가이드](../code/ios/README.md)
- [실행 가이드](../code/Run_Guide_AI_SYS.md)

---

## 참고 코드 및 추가 작성 항목

### 참고 코드 (현재 기준)
- `code/ios/AISYSApp/Sources/AISYSApp.swift` - 앱 진입점
- `code/ios/AISYSApp/Sources/AppRuntimeState.swift` - 탭/검색 전달 상태
- `code/ios/AISYSApp/Sources/SearchFlowViews.swift` - 검색/요약/퀴즈 UI 흐름
- `code/ios/AISYSApp/Sources/CaseSummaryViewModel.swift` - 검색 및 LLM 연동 상태 관리
- `code/ios/AISYSApp/Sources/NetworkService.swift` - 백엔드 API 호출 계층
- `code/ios/AISYSApp/Sources/LLMService.swift` - 온디바이스 LLM 추론 상태 머신
- `code/ios/AISYSApp/Sources/LocalLLMEngines.swift` - LlamaCpp/RuleBased 엔진 구현
- `code/ios/AISYSApp/Sources/Models.swift` - API 모델 및 LLM 파싱 모델

### 추가 작성 항목 (다음 단계)
1. "유사한 판례 찾기" 전용 화면/뷰모델 추가 (`SimilarCasesView.swift`, `SimilarCasesViewModel.swift`)
2. OCR 텍스트 -> 유사도 검색 API 호출 파이프라인 확장
3. O/X 퀴즈 모드 UI 및 데이터 모델 확장
4. 네트워크 실패/오프라인/파싱 실패 상태별 UX 세분화

---

## 현재 진행 상황 (기준: 2026-04-28)

### 완료 사항 ✅

| 항목 | 상세 |
|------|------|
| 5탭 구조 | Home / OCR / Search / Review / My Page 구현 완료 |
| Home 탭 | 백엔드 대시보드(추천/오답) 로딩 및 실패 폴백 처리 |
| OCR 탭 | PhotosPicker + Vision OCR, 인식 텍스트를 Search 탭으로 전달 |
| Search 탭 | 키워드 검색, 결과 카드, 판례 상세 진입 |
| Case Summary | 요약/퀴즈 생성 트리거 및 상태 표시 |
| Quiz 탭 | 객관식 표시/정답 확인/해설/오답 저장 흐름 |
| Review 탭 | 오답 리스트 조회 |
| My Page 탭 | API 서버 주소 오버라이드 저장/초기화 |
| 뒤로가기 UX | 주요 화면 공통 소형 뒤로가기 버튼 적용 |
| 로컬 LLM | LlamaSwift 연동 경로 확보, 상태 머신(loading/ready/inferring/error) 적용 |
| Rule-based 폴백 | 엔진 실패 시 규칙 기반 fallback으로 UX 보호 |
| API 오버라이드 | UserDefaults 기반 API 서버 주소 오버라이드 지원 |

### 현재 제한 사항 ⚠️

- **네트워크 에러 UX 미흡**: 실패/시간초과/오프라인 케이스별 사용자 메시지 미세분화
- **오답 동기화 미정교화**: 온라인/오프라인 충돌 처리 정책 미완성
- **접근성 미검증**: Dynamic Type, VoiceOver, 대비 검증 및 개선 필요
- **UI 테스트 부족**: 자동화된 UI 테스트/E2E 테스트 미구축

### 다음 작업 (우선순위 순)

1. **[P0]** 실기기(iPhone) E2E 검증 — Home/OCR/Search/요약/퀴즈/오답 전 경로 안정 동작 확인
2. **[P0]** 네트워크 실패/오프라인 케이스 UX 세분화
3. **[P1]** ViewModel 중심 단위 테스트 + 핵심 화면 스모크 테스트 구축
4. **[P1]** 오답 저장 서버 동기화 정책 정교화
5. **[P2]** 접근성 개선 — Dynamic Type, VoiceOver, 색 대비
6. **[P2]** 로딩/에러/빈 상태 디자인 일관화

---

**마지막 업데이트**: 2026-04-28
