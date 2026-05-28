# AI_SYS 프로젝트 진행 현황 및 향후 실행 로드맵

작성일: 2026-05-11
기준 브랜치: `임재현` (HEAD ebe4a11 + Phase L/M 패치)
문서 목적: 2026-05-10 스냅샷 이후 진행된 백엔드 분리·온디바이스 IR 파이프라인 도입·복습 노트 약점 OX 모음 구현 까지의 변경을 정리.

---

## 1. 핵심 변화 — 완전 온디바이스(Backend-free) 전환

이전까지 일부 경로(검색·IR 추출·유사 판례)에 **HTTP 백엔드**를 호출하던 구조를 제거하고, 모든 추론·검색·분류를 **iOS 디바이스 내부**에서 처리하도록 재구성했다. 결과적으로 앱은 네트워크 없이도 풀 기능 동작하며, 인스턴스 비용 0원·요청 비밀번호 노출 0건이 되었다.

| 영역 | Before (2026-05-10) | After (2026-05-11) |
|------|---------------------|--------------------|
| `searchCases` | FastAPI `/search` | `LocalCaseStore.searchCorpus` + `LocalCaseSearchEngine` |
| `irExtract` | `/ir/extract` (`ir_pipeline.py`) | `LocalIRPipeline.extract` (Swift 포팅) |
| `listSimilarCases` | `/cases/similar` | `LocalCaseSearchEngine.similar` (NLEmbedding) |
| `groundedAnswer / serverGenerateOXQuiz` | `/grounded`, `/quiz/ox` | `throw .notSupportedOffline` |
| `healthCheck` | `/health` | 상수 `true` |

---

## 2. 신규 모듈 (Swift)

### 2-1. `LegalIssueDictionary.swift`

법률 논점 사전 + 관련 키워드 그래프. `struct LegalIssue { keyword, category, related, importance }` 60+ entry. 형사소송법·형법·헌법·경찰학 빈출 쟁점.

API:
- `static let issues`
- `static let index: [String: LegalIssue]`
- `static func detect(in:) -> (direct: [String], related: [String])`
- `static func inferCategory(from:) -> String`

### 2-2. `LocalIRPipeline.swift`

`code/backend/app/ir_pipeline.py` 의 Swift 포팅.

- `extract(text:topKeywords:topSentences:) -> APIIRExtractResponse`
- `normalize(_:)` — URL/공백 정리 + `fixOCRSpacing` 으로 OCR 띄어쓰기 보정 (예: "담보하 는" → "담보하는", "관 한" → "관한")
- `extractKeyphrases(from:topN:)` — Apple `NLTagger` (lexicalClass=.noun) + 정규식 폴백, 어미·조사 stripper, `LegalIssueDictionary` 가산점, **정형 신호(조문) 쿼터 제한**으로 본문 명사 우선 노출
- `extractKeySentences(from:topN:)` — TextRank 대신 (키워드 빈도) + (법률 힌트) + (정형 신호) 합산 점수
- `splitSentences(_:)` — 종결어미+마침표 기반 분리 + 조사로 시작하는 OCR 단편을 직전 문장과 병합
- `inferDomain` / `buildStudyFocus`

### 2-3. `LocalCaseSearchEngine.swift`

- `search(query:in:limit:)` — 토큰 점수 (제목 ×3, 키워드 ×2, 본문 ×1, 사전 확장)
- `similar(to:in:topK:)` — actor-safe (token-only)

### 2-4. `LocalCaseStore.swift`

- `final class LocalCaseStore: @unchecked Sendable`, `static let shared`
- 이중 코퍼스: `searchCorpus` (raw 포함) + `displayCorpus` (UI)
- `updateScanned(searchable:display:)`
- `loadBundleSeed()` — `seed_cases.json` 자동 로드 (선택)

### 2-5. `LocalSimilarityEngine.swift`

- Apple `NLEmbedding(language: .korean)` 단어 임베딩 → 평균 → L2-normalized → cosine
- 이전부터 존재하던 모듈을 ReviewView 약점 추천에 비동기 캐시로 통합

---

## 3. UX 개선

### 3-1. 검색 결과에 "내가 스캔한 판례" 본문 매칭

- `ScannedCase.toSearchableAPICase()` — OCR 원문 1500자를 issueSummary 검색 corpus 에 합성
- `displayCorpus` 와 분리해 UI 노출은 정제된 텍스트 유지
- `SearchView.task` / `.onChange(of: scannedCases.count)` 에서 양쪽 코퍼스 동기화
- 기존: List 가 ScrollView 안에서 높이 0 으로 축소 → ForEach + VStack 으로 교체

### 3-2. 복습 노트 — 자주 틀리는 영역 OX 모음 (신규)

- 약점 카드 클릭 → `WeakOXListView` 로 NavigationLink 이동 (이전: Search 탭 + 빈 결과)
- `store.wrongQuizRecords` 를 `subject` prefix/contains 매칭으로 필터링
- 카드 형태로 사건번호·문제·내 답·정답·해설 표시
- 빈 상태 안내 ("이 영역의 오답 기록이 없습니다.")

### 3-3. Review 탭 진입 lag 해소

- 이전: body 평가 시마다 `LocalSimilarityEngine.findSimilar` 동기 호출 → 첫 탭 진입에 NLEmbedding 워밍업 비용이 메인 스레드로 흘러 들어감
- 현재: `@State similarRecommendations` 캐시 + `.task(id: similarityCacheKey)` 에서 `Task.detached(priority: .utility)` 로 분리 계산
- 캐시 키: weakSubjects 라벨 + savedCases.count + scannedCases.count

### 3-4. 학습카드 한국어 자연스러움

- `extractIssueCore` / `buildSummaryOutput.sanitize` / `sanitizeQuizStatement` 모두에 leading particle("는 "/"은 "/"이 "/"가 "/...) 제거
- `koreanObjectMarker(_:)` — 한글 음절 받침 유무로 "을/를" 자동 선택
- `composeStudyCardOneLine` 의 `"...을(를) 다툰 판례."` → 자연 조사
- `pickHoldingSentence` 가 본문 전체에서 (적극)/(소극) 마커 검색 (이전: 쟁점 문장에만)
- `smartTruncateKorean` 가 limit 미만이면 그대로 반환, 잘릴 땐 종결어미 우선·실패 시 "(이하 생략)" (이전: "...")
- `sanitizeQuizStatement` 가 OCR 헤더(`자 2025마8671 결정`, `[제목]`, `〈…〉`) 제거

### 3-5. 키워드·시험 포인트 표시 정제

- `extractKeyphrases` — 정형 신호 우선 매칭을 `topN/4` 로 제한, 본문 명사가 먼저 노출
- OCRView `examPoints` — 단순 조항 나열 대신 `studyFocus[0]` + 본문 키워드 조합으로 가독성 향상
- 약점 카드 primary keyword 결정 시 정형 신호(`제○조`) 제외

### 3-6. 뒤로가기 버튼 정리

- 탭 root view (HomeView, OCRView, SearchView, ReviewView, MyPageView)에서 `withSmallBackButton()` 제거
- 이전: root에서 dismiss는 no-op이라 버튼이 보여도 동작 안 함
- 푸시된 sub view (CaseSummaryView, OXQuizView, QuizView, WrongAnswerSaveView, WeakOXListView)에는 유지

---

## 4. 검증 결과 (iPhone 12 mini, 2026-05-11)

| 항목 | 결과 |
|------|------|
| 빌드 (Debug-iphoneos, codesign) | ** BUILD SUCCEEDED ** |
| 디바이스 설치 / 실행 (UUID `8B1BD1BC...`) | OK |
| 검색 — 사건번호 직접 입력 (`2025마8671`) | OK |
| 검색 — 본문 단어("민사") 매칭 | OK (스캔 판례 hit) |
| Review 탭 진입 즉시성 | 이전 1초 lag → 즉시 표시 |
| 약점 카드 → OX 모음 화면 | OK |
| 한 줄 요약 / 핵심 쟁점 / 판결 결론 | OK — leading particle 제거, "을/를" 정상 |
| OX 퀴즈 statement | 일부 raw OCR 잔재 남음 (P1) |
| 뒤로가기 버튼 | sub view에서만 표시·동작 |

---

## 5. 알려진 한계 / 후속 과제

### P1 — OX 자연스러움

- statement가 OCR 결정요지 본문을 그대로 인용 → 받침 어색·생략 잔재 가능
- 해결안: 시드 OX 풀 도입(아래 6번 데이터 항목) 또는 1B 변형기 트리거 완화

### P2 — 시드 판례 코퍼스 부재

- 사용자 OCR 외 검색 대상 없음 → "유사 판례" 추천이 사실상 사용자 본인 판례 한정
- 해결안: `seed_cases.json` 50~200건 번들 (대법원 공보 발췌)

### P3 — 분류 택소노미 일반화

- `LocalIRPipeline.domainHints` 가 5도메인. 행정법·민사실체법 등 라벨 부재
- 해결안: 시험별 분류 트리 확장 (`docs/research/police_exam_classification_tree.md` 기반)

---

## 6. 데이터 보강 우선순위 (사용자 협조 항목)

| 우선 | 데이터 | 형식 | 효과 |
|------|--------|------|------|
| 1 | 시드 판례 50~200건 | JSON (`code/ios/AISYSApp/Sources/seed_cases.json`) | 검색·유사판례·OX 풀 즉시 보강 |
| 2 | 시험별 분류 트리 | TXT/MD (3-level) | 분류 정확도 |
| 3 | 빈출 키워드 사전 | CSV (키워드, 카테고리, 중요도, 관련어) | `LegalIssueDictionary` 확장 |
| 4 | 판시사항/결정요지 라벨 셋 | JSON 50건 | LLM few-shot 프롬프트 |
| 5 | OX 시드 문제 풀 | JSON 30~50건 (3~5문항/판례) | OX 단조로움 해소 |
| 6 | OCR PDF↔정답 텍스트 쌍 | 폴더 단위 | `fixOCRSpacing` 룰 데이터 기반 보강 |

---

## 7. 변경된 파일 (HEAD ebe4a11 대비)

```
code/ios/AISYSApp/Sources/LegalIssueDictionary.swift    (신규)  ~310 lines
code/ios/AISYSApp/Sources/LocalIRPipeline.swift         (신규)  ~430 lines
code/ios/AISYSApp/Sources/LocalCaseSearchEngine.swift   (신규)  ~150 lines
code/ios/AISYSApp/Sources/LocalCaseStore.swift          (신규)  ~140 lines
code/ios/AISYSApp/Sources/NetworkService.swift          전면 교체
code/ios/AISYSApp/Sources/SearchFlowViews.swift         +200 lines (WeakOXListView, 비동기 추천)
code/ios/AISYSApp/Sources/LLMService.swift              ~120 lines (조사·문장 정제)
code/ios/AISYSApp/Sources/OCRView.swift                 ~80 lines (leading particle, examPoints, holding)
code/ios/AISYSApp/Sources/ScannedCase.swift             ~30 lines (toSearchableAPICase)
code/ios/AISYS.xcodeproj/project.pbxproj                +5 file refs (수동)
```

---

## 8. 다음 마일스톤 (제안)

1. 시드 판례 JSON 5건 샘플 작성 → 사용자 확인 후 50건 확장
2. OX 시드 풀 도입 (P1·P5 해결)
3. App Store 1차 TestFlight 빌드 (release-2026-05-12 태그 후)
