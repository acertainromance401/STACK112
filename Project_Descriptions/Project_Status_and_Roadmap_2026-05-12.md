# AI_SYS 프로젝트 진행 현황 및 향후 실행 로드맵

작성일: 2026-05-12
추가 반영: 2026-05-14 App Store 제출 상태 업데이트
기준 브랜치: `임재현` (HEAD `4fe8ed3` + LegalAnalyzer/캐시/App Store 패치)
문서 목적: 2026-05-11 스냅샷 이후 진행된 **LLM 지능화(LegalAnalyzer + 도메인 프롬프트 + 함정 카탈로그)**, **응답 캐시·동적 토큰**, **개인화 약점 OX 주입**, 그리고 **App Store 출시 준비(컴플라이언스·아이콘·온디바이스 LLM 번들 검증)** 까지의 변경을 정리.

---

## 0. 2026-05-14 추가 업데이트

- App Store Connect 메타데이터/스크린샷/App Privacy/App Review 입력 완료
- 개인정보 처리방침 URL은 `https://acertainromance401.github.io/stack112-privacy/` 사용
- 심사용 빌드 `1.0.0 (2)` 선택 후 **App Review 제출 완료**
- 제출용 스크린샷 선별본은 `code/ios/appstore_screenshots/` 에 정리

---

## 1. 핵심 변화 — 학습 지능화 + 출시 준비

2026-05-11 까지 "백엔드 분리·온디바이스 IR 파이프라인 도입"을 완료한 시점에서, 2026-05-12 는 다음 두 축을 동시에 끝낸 스냅샷이다.

| 축 | Before (2026-05-11) | After (2026-05-12) |
|---|---|---|
| 법률 도메인 분류 | `LocalIRPipeline.inferDomain` (룰 5도메인) | 점수제 + 신뢰도 + 폴백, `LegalAnalyzer.classify` |
| 함정 카탈로그 | 없음 | 5도메인별 8~14개 함정 패턴 (위원회 인원·기간·예외열거 등) |
| OX 도메인 프롬프트 | 일반 프롬프트 | `LegalAnalyzer.buildDecisionHints` 도메인 전용 hint 주입 |
| OX 폴백 품질 | 라벨 뒤집기 1종 | 도메인별 함정 카탈로그 셔플 N개 + 약점 키워드 주입 |
| 응답 캐시 | 없음 | summary/OX/RAG dict 캐시 (capacity 32) |
| 토큰 예산 | OX 고정 360 / Summary 220 | OX `min(360, 100+70*count)`, Summary 240 |
| 개인화 | 없음 | `weakKeywordsProvider` — 오답 누적 → 다음 OX 힌트에 자동 반영 |
| 키워드 추출 | NLTagger + 정형 신호 쿼터 | + `LegalIssueDictionary.detect` N-gram (importance 정렬, 쿼터 topN/3) |
| App Store 준비 | 미정리 | ITSAppUsesNonExemptEncryption=NO, LSSupportsOpeningDocumentsInPlace=NO, DEBUG-gated 서버 설정 UI, 1024×1024 AppIcon (RGB no-alpha) |

---

## 2. 신규/변경 모듈 (Swift)

### 2-1. `LegalAnalyzer.swift` (신규)

법률 도메인 분류 + 함정 카탈로그 + 개인화의 중앙 모듈. LLM 밖에서 도메인 인식을 명시적으로 수행해 1B 모델 한계를 보완.

```swift
enum LegalAnalyzer {
    enum Domain { case criminalLaw, criminalProcedure, constitutional, policeAdministrative, general }
    struct DomainResult { let domain: Domain; let confidence: Double; let runnerUp: Domain? }

    static func classify(text: String, keywords: [String]) -> DomainResult
    static func sampledTraps(for domain: Domain, count: Int) -> [String]
    static func buildDecisionHints(text: String, keywords: [String], userWeakKeywords: [String]) -> String
    static func weakKeywords(from records: [WrongQuizRecord], topK: Int) -> [String]
}
```

- 가중치 키워드 매칭 + `LegalIssueDictionary` 카테고리 부스트
- `sampledTraps` 는 매 호출마다 셔플 → 같은 판례 재학습 시 함정 종류 다양화
- `weakKeywords` 는 최근 오답 N건의 subject·keyword 빈도 기반 top-K

### 2-2. `LLMService.swift` 강화

- **응답 캐시**: `summaryCache` / `oxCache` / `ragCache` dict (capacity 32, LRU-like) — 같은 입력 재호출 시 즉시 반환
- **동적 토큰**: 요구 OX 개수에 비례 `min(360, 100+70*count)`, summary 240
- **부분 수락**: OX 생성 결과가 요구 개수 - 1 이상이면 수락 후 폴백으로 보충 (이전: 전량 실패 시 폴백)
- **도메인 hint**: `LegalAnalyzer.buildDecisionHints` 위임 (도메인 전용 프롬프트 + 함정 + 약점 키워드)
- **개인화 바인딩**: `var weakKeywordsProvider: (() -> [String])?` — 앱 부팅 시 `AISYSApp.swift .task` 에서 주입

### 2-3. `LocalIRPipeline.swift` 보강

- `extractKeyphrases` — `LegalIssueDictionary.detect` N-gram 매칭을 importance 정렬해 `topN/3` 쿼터로 우선 노출, 그 뒤 NLTagger 명사
- `inferDomain` — bestScore < 2 일 때 `LegalAnalyzer.classify` 로 폴백 (룰만으로 판단 어려운 짧은 OCR 보정)

### 2-4. `AISYSApp.swift`

```swift
.task {
    await LLMService.shared.loadModelIfNeeded()
    LLMService.shared.weakKeywordsProvider = {
        LegalAnalyzer.weakKeywords(from: store.wrongQuizRecords, topK: 3)
    }
}
```

### 2-5. `SearchFlowViews.swift`

- `MyPageView` 의 "서버 설정" 섹션 전체를 `#if DEBUG` 로 감싸고 라벨 끝에 "(개발 전용)" 표기 — App Store 심사 시 사용되지 않는 백엔드 UI 노출 방지

### 2-6. `project.yml` (XcodeGen)

- `DEVELOPMENT_TEAM: "6S5ZH3ZJ93"` (provisioning profile에서 추출)
- `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO`
- `LSSupportsOpeningDocumentsInPlace: NO`
- iOS deployment target 17.0

---

## 3. App Store 출시 준비 결과

| 항목 | 상태 |
|---|---|
| Bundle ID | `com.acertainromance401.aisys` |
| Display Name | `STACK112` |
| Privacy Policy URL | https://acertainromance401.github.io/stack112-privacy/ |
| App Privacy 신고 | **Data Not Collected** (전송 0건) |
| 암호화 신고 | ITSAppUsesNonExemptEncryption = NO (HTTPS 표준 외 사용 없음) |
| 카테고리 | Primary: Education / Secondary: Productivity |
| 연령 등급 | 4+ |
| App Review 상태 | 2026-05-14 제출 완료 (build 1.0.0 (2)) |
| AppIcon | 1024×1024 (RGB, no-alpha) 단일 사이즈 — Xcode가 나머지 사이즈 자동 생성 |
| 온디바이스 LLM 번들 | `Llama-3.2-1B-Instruct-Q4_K_M.gguf` 807MB → `.app` 내부 확인 (최종 앱 크기 783MB) |
| Backend 의존 | 없음 — 외부 네트워크 호출 0건 (디버그 서버 설정만 DEBUG-gated) |
| 중복 파일 | 24개 `* 2.*` 파일 + `AISYS 2.xcodeproj` 정리 완료 |
| 빌드 검증 | ** BUILD SUCCEEDED ** (iPhone 12 mini 실기기 설치·실행 확인) |

---

## 4. 검증 결과 (iPhone 12 mini, 2026-05-12)

| 항목 | 결과 |
|---|---|
| Release-iphoneos 빌드 | ** BUILD SUCCEEDED ** |
| 디바이스 설치/실행 (UUID `00008101-001354580206001E`) | OK |
| OCR → IR 추출 → 검색 → 요약 → OX → 복습 E2E | OK |
| 응답 캐시 hit (동일 OCR 재요청) | 즉시 반환 (LLM 호출 skip) |
| 도메인 분류 — 형사소송법 영장 케이스 | confidence 0.7+ |
| OX 함정 카탈로그 셔플 | 동일 판례 재시도 시 다른 함정 등장 확인 |
| 약점 키워드 주입 (오답 3건 후 재OX) | weak keywords 가 hint에 반영됨 (LLMService 로그) |
| 첫 다운로드 크기 | 783MB (Wi-Fi 권장 안내 필요) |

---

## 5. 알려진 한계 / 후속 과제

### P1 — 시드 판례 코퍼스 부재 (이월)
- 사용자 OCR 외 검색 대상 없음 → 유사 판례 추천이 사용자 본인 판례 한정
- 해결안: `seed_cases.json` 50~200건 번들 (대법원 공보 발췌)

### P2 — 1B 모델 한계
- 긴 비교·다단 추론 약함. 본문 생성은 룰베이스 유지, 1B는 분류·변형·OX 강화로 한정 운영 중
- 향후 Llama 3.2 3B Q4 (~1.9GB) 옵션 검토 — 다운로드 크기 trade-off

### P3 — App Store 첫 심사 리스크
- 첫 다운로드 783MB → 사용자 안내 필요 (스크린샷 캡션·릴리즈 노트에 명시)
- "AI" 키워드 사용 시 책임 고지 — Privacy Policy 에 "AI 응답은 학습 보조용, 법률 자문 아님" 명시 필요

---

## 6. 변경된 파일 (HEAD `4fe8ed3` 작업 트리)

```
신규
  code/ios/AISYSApp/Sources/LegalAnalyzer.swift           ~200 lines

수정
  code/ios/AISYSApp/Sources/LLMService.swift              +캐시/동적 토큰/개인화/hint 위임
  code/ios/AISYSApp/Sources/LocalIRPipeline.swift         +사전 N-gram 추출, 도메인 폴백
  code/ios/AISYSApp/Sources/AISYSApp.swift                +weakKeywordsProvider 바인딩
  code/ios/AISYSApp/Sources/SearchFlowViews.swift         +#if DEBUG 서버 설정
  code/ios/AISYSApp/Sources/NewMainScreens.swift          (사소)
  code/ios/project.yml                                    +DEVELOPMENT_TEAM, App Store 키
  code/ios/AISYS.xcodeproj/project.pbxproj                XcodeGen 재생성

삭제
  24개 `* 2.*` 중복 파일, `AISYS 2.xcodeproj`
```

---

## 7. 다음 마일스톤

1. 시드 판례 JSON 50건 (P1) — 사용자 큐레이션 후 번들
2. App Review 결과 대기 → 필요 시 리뷰어 코멘트 대응
3. 승인 후 수동 출시 여부 결정 및 스토어 페이지 최종 점검
4. (선택) Llama 3.2 3B Q4 빌드 변형 — 고사양 사용자 대상 옵션

---

## 8. 컨셉 재확인

- **포지셔닝**: 보조 메모장 ("메인은 책, 옆자리는 STACK112")
- **슬로건**: "공부는 당신이, 기록은 우리가."
- **차별성**: 완전 온디바이스(요금 0·데이터 미수집) × 시험 관점 요약·함정 OX × 개인화 약점 학습
- 자세한 컨셉/경쟁 분석은 [README.md §4](../README.md) 와 [APPSTORE_METADATA.md](../code/ios/APPSTORE_METADATA.md) 참조
