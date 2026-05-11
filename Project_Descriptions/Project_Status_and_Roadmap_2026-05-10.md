# AI_SYS 프로젝트 진행 현황 및 향후 실행 로드맵

작성일: 2026-05-10
기준 브랜치: `임재현` (HEAD a57f579 + Phase I/J/K 패치)
문서 목적: 2026-04-23 스냅샷 이후 진행된 OCR · LLM 품질 개선, 데드코드 정리, 1B Llama 분류기 도입까지의 변경을 정리하고 다음 단계를 명확히 한다.

---

## 1. 프로젝트 한 줄 요약

AI_SYS는 경찰 공무원 시험 준비를 위한 판례 학습 iOS 앱이다. OCR로 판례 본문을 읽어 자동으로 분류·요약·OX 퀴즈를 만들고, 외부 API 키나 토큰 비용 없이 단말 내 1B Llama Q4 모델 + 룰베이스 파이프라인으로 동작한다.

---

## 2. 2026-04-23 이후 추가된 변경 (Phase I / J / K)

### 2-1. OCR 학습카드 품질 개선 (OCRView.swift)

- 핵심 쟁점 / 판결 결론 분리 정확도 개선
  - `pickIssueSentence` 와 `pickHoldingSentence` 우선순위 분리
  - `(적극)` / `(소극)` 마커가 쟁점에 포함된 경우 합성 결론을 **최우선**으로 생성
    - "관련 쟁점 모두 적극적으로 인정(적극)되었다." / "...소극적으로 부정(소극)되었다."
  - 다른 판례 인용에서 동일 마커가 끼어들어 결론 자리에 잘못 들어가는 문제 차단
- OCR 후처리 강화
  - `stripBracketNoise` 길이 제한 제거 → 사건명 누출 차단
  - `sanitizeKeywords` 로 "00경부터" 등 시간 표기 제거
  - 인용 표기 단독 줄, 어미 조각 시작 라인, `공YYYY` 헤더 거부
- 결과
  - 판결 결론 placeholder("정보가 부족합니다") 출현 빈도 대폭 감소
  - 시험 포인트의 "제○조" 나열이 깔끔하게 유지

### 2-2. 1B Llama 분류기 / 변형기 도입 (LLMService.swift)

1B 모델은 **분류기·짧은 변형기**로만 활용한다 (생성기 아님). 계산 비용·환각 위험 최소화.

| 함수 | 역할 | max_tokens |
|------|------|-----------|
| `classifyByTaxonomy` / `classifyOneLevel` | 4과목(형법·형소법·헌법·경찰학) 3-level 분류 | 라벨 1개 |
| `classifyVerdictWithLLM` | 15개 판결 결론 라벨 분류 | 8 |
| `composeStudyCardOneLineAsync` | 한 줄 요약 hint 합성 (분류기 결과 활용) | 짧음 |
| `generateOXVariantWithLLM` | 룰베이스 OX의 첫 X 문항 1개를 자연스러운 변형으로 교체 | 80 |

- `taxonomyTree` 정적 트리: 4과목 × 3-5 카테고리 × 3-7 리프 노드. `police_exam_classification_tree.md` 기반.
- 각 레벨에 3초 timeout, 룰베이스 키워드 fallback 보장.
- OCR 결과의 `subject` 필드에 분류 경로(예: `"형사소송법 > 증거능력 > 위법수집증거배제"`) 프리픽스로 주입.

### 2-3. OX 퀴즈 폴백 개선

- `buildFallbackOXQuiz` 의 메타 placeholder(extras) 완전 제거
  - 이전: 후보 부족 시 "...핵심 판례이다", "...자주 출제된다" 자동 주입
  - 현재: `min(count, workingSentences.count)` 만큼만 생성
- `enhanceOXQuizWithLLM`: source 문장에 `>` 기호 / 메타 문구가 있으면 LLM 변형 스킵 → taxonomy 경로 누출 차단

### 2-4. Documents 모델 무시 기본 ON

- `LLMService.ignoreDocumentsModel = true` (CaseSummaryViewModel 동기화)
- 사용자가 매번 토글하지 않아도 항상 번들 1B 모델 사용
- iPhone 12 mini(4GB RAM)에서 안정성 확보

### 2-5. 데드코드 / 더미 데이터 제거 (~140 lines)

- Models.swift: `APIRecommendedCase`, `CaseStudy`, `applyRemoteDashboard`, 미사용 `@Published` 제거
- NetworkService.swift: `currentBaseURLString`, `listRecommendedCases`, `listWrongAnswers`, 관련 응답 구조 제거
- CaseSummaryViewModel.swift: `loadInitialCasesIfNeeded`, `hasLoadedInitialCases` 제거
- ir_pipeline.py: 사용되지 않던 `count_legal_signals` 제거
- 결과: 7066 → 6929 라인

---

## 3. 2026-05-10 시점 검증 결과 (실기기 iPhone 12 mini)

| 검증 항목 | 결과 |
|----------|------|
| 빌드 / 설치 / 실행 (디바이스 `8B1BD1BC...`) | OK |
| 분류 트리 (1B Llama) | OK — 예: "형사소송법 > 증거능력 > 위법수집증거배제" |
| 한 줄 요약 | OK — 자연스러운 한국어 문장 |
| 핵심 쟁점 | OK — 사건명 누출 없음 |
| 판결 결론 | OK — `(적극)/(소극)` 합성 정상 작동 |
| 시험 포인트 | OK — 조문/판례번호 정렬 |
| OX O 문항 | OK — 원문 기반 |
| OX X 문항 (룰베이스 부정) | 부분적 한계 — `negateStatement` 가 "정반대이다" 류 부자연 어미 생성 가능 |

---

## 4. 알려진 한계 / 후속 과제

### P1 — 사용자 체감 우선순위

- OX X 문항 룰베이스 부정의 자연스러움
  - 현재 `negateStatement` 패턴이 명백한 단방향 결론에서만 안전. 그 외엔 "정반대이다" 류로 끝남
  - 해결안: 1B 변형 트리거 조건을 완화하거나, X 문항 템플릿 후보를 2-3종으로 다양화

### P2 — 데이터 / 분류 품질

- taxonomy 경로 일치도 평가 — 시험 분류 트리 라벨 정합성 정량 검증 필요
- 룰베이스 폴백 분류 키워드 사전 확장 (현재 형사소송법 위주)

### P3 — 백엔드 / 운영

- 배포된 백엔드의 OX 서버 폴백 경로(`serverGenerateOXQuiz`)는 룰베이스만 응답. LLM 활용 여지 남음 (단, 보안·비용 정책상 보류)
- 유사 판례 검색은 OCR 임시 케이스에서 비활성 — 사용자 저장 흐름 확정 후 활성화

---

## 5. 변경된 파일 (HEAD 대비)

```
code/backend/app/ir_pipeline.py                     -21 lines
code/ios/AISYSApp/Sources/CaseSummaryViewModel.swift  ~28 lines
code/ios/AISYSApp/Sources/LLMService.swift          +421 lines
code/ios/AISYSApp/Sources/LocalLLMEngines.swift     ~2 lines
code/ios/AISYSApp/Sources/Models.swift              -43 lines
code/ios/AISYSApp/Sources/NetworkService.swift      -43 lines
code/ios/AISYSApp/Sources/OCRView.swift             +92 lines
```

총 +483 / -167 (순증 +316 라인, 신규 트리·분류기 코드 포함)

---

## 6. 다음 마일스톤

1. OX X 문항 자연스러움 개선 (P1)
2. 분류 트리 정합성 평가 데이터셋 구축 (P2)
3. 운영 모니터링 — 분류 실패 / placeholder 폴백 빈도 로깅 (P3)
4. 릴리스 태깅: 본 작업 commit 후 `release-2026-05-11` 후보
