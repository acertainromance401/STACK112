# 개선 계획 및 RAG 구축 상태 점검

- 점검일: 2026-11-02
- 기준: `acertainromance401/STACK112`, `main`, `2e96237`
- 범위: 현재 저장소의 iOS, 백엔드, 데이터, 테스트, CI 및 관련 문서
- 상태: 1~6절은 기준 커밋의 최초 점검 스냅샷. 이후 온디바이스 RAG 핵심 경로를 수정하고 회귀 테스트를 추가했으며, 현재 구현과 남은 제한은 [7절](#7-온디바이스-rag-개선-반영)에 기록한다.

## 약어·지표 안내

이 설명은 최초 점검 결과를 변경하지 않고, 본문과 후속 연구 확장의 기술 표기를 해설한다.

| 표기 | 의미 |
| --- | --- |
| RAG / LLM | Retrieval-Augmented Generation, 검색 증강 생성 / Large Language Model, 대규모 언어모델 |
| E0 | Evidence 0. 후속 연구 경로에서 현재 판례의 선택 청크·실제 전달 발췌에 붙이는 ID |
| E1 | Evidence 1. 첫 번째 참고 청크·전달 발췌 ID |
| E2 | Evidence 2. 두 번째 참고 청크·전달 발췌 ID. E1과 같은 참고 판례의 다른 부분일 수 있음 |
| E5 / RRF | multilingual-e5-base 검색 임베딩 모델 / Reciprocal Rank Fusion, 키워드·의미 검색의 역순위 융합 |
| L2 정규화 | 벡터의 유클리드 길이를 1로 맞추는 수학 처리. 후속 파일럿 질문 ID L2와 다름 |
| P@3 | Precision at 3. 연구 구현은 문서 ID 중복 제거 후 상위 최대 3문서에서 관련 문서 수 / 고정 분모 3 |
| R@3 / Recall@k | Recall, 상위 3개 또는 k개 문서에서 찾은 관련 문서 수 / 전체 관련 정답 문서 수 |
| MRR | Mean Reciprocal Rank, 첫 관련 문서 순위 역수의 질문 평균. 연구 구현은 상위 3문서 범위 사용 |
| OCR / E2E | Optical Character Recognition, 이미지 문자 인식 / End-to-End, 정해진 전체 경로 검사 |
| CI / DB / ID | Continuous Integration, 지속적 통합 / Database, 데이터베이스 / Identifier, 식별자 |
| GGUF / Q8_0 | 모델 저장 형식 / E5 파일의 가중치 양자화 방식 표기 |

E는 임베딩이 아닌 **근거(Evidence)**다. 검색용 숫자 벡터와 전달 텍스트의 인용 ID를 구분한다. E0·E1·E2는 실행마다 붙이고, 참고가 없거나 예산이 작으면 E1·E2가 모두 존재하지 않을 수 있다. 정답 문서가 없는 질문의 Recall·MRR는 미측정으로 두며 참고 없음 판정은 별도로 본다.

후속 실험 문서의 **B0 = 현재 판례만**, **B1 = 키워드**, **H = 하이브리드**이며 **B2 조건은 없다**. **L1~L3**는 각각 재산분할 일반 기준 / 인용 선례와 공통 기준 / 면접교섭 새 조건 질문이다. 연구 목표를 뜻하는 RQ(Research Question)와 구분한다. 실행 결과와 정확한 조건은 [분석 보고서](../research/Execution_Log_Performance_Analysis_2026-11-03.md)를 따른다.

## 1. 결론

STACK112는 iOS 앱을 출시한 온디바이스 판례 학습 프로젝트다. 다음 단계는 핵심 학습 기능의 정확성, 실행 재현성, 자동 테스트 및 릴리스 안정화다.

**RAG 판정: 검색·근거 주입 관련 코드는 일부 구현되어 있지만, 현재 저장소를 기준으로 앱의 정상 사용 경로에서 끝까지 동작하는 RAG 구축이 완료되었다고 볼 수 없다.**

- iOS에는 로컬 판례 검색 결과를 요약 프롬프트에 넣는 경로가 있다.
- 그러나 현재 화면에서 검색용 코퍼스를 동기화하는 연결이 빠져 있고, 선택적인 번들 시드 판례도 없다.
- 검색 결과가 만들어져도 요약 프롬프트를 앞에서 720/960자로 자르는 처리 때문에 뒤쪽 RAG 근거가 제거된다. 실제 Swift 템플릿으로 재현했다.
- 백엔드에는 SQL 검색, TF-IDF 유사도, 인용 응답 및 경량 검증이 있지만, 답변은 LLM 호출이 아닌 템플릿으로 구성한다.
- pgvector 확장과 임베딩 컬럼은 있으나, 이를 사용하는 적재·임베딩 생성·벡터 검색의 연결 구현은 확인되지 않았다.

RAG는 벡터 DB가 반드시 있어야 하는 기술이 아니다. 키워드 검색도 근거 검색으로 사용할 수 있다. 이번 미완료 판정은 특정 라이브러리의 부재가 아니라 **실제 코퍼스 연결, 검색 결과 보존, 생성 및 검증의 단절**에 근거한다.

## 2. 검증 범위와 한계

### 2.1 직접 확인한 항목

- Swift와 Python 구현의 호출 경로, 데이터 스키마, 시드 및 문서 대조
- 저장소 전체 iOS 소스에서 검색용 저장소 갱신과 기존 화면의 호출 지점 확인
- 실제 `PromptTemplates.swift`를 `swiftc`로 컴파일한 외부 임시 실행 코드로 프롬프트 절단 재현
- 같은 날 앞선 작업공간 분석에서 iOS Simulator 빌드 및 기존 XCTest 2개 통과
- Python 백엔드 7개 모듈의 문법 파싱 성공
- 원격 main과 로컬 main 일치 및 GitHub Actions 실행 결과 확인

### 2.2 확인하지 않은 항목

- 운영 DB 접속, 운영 판례 수 및 운영 서버의 현재 가동 상태
- 실제 GGUF 추론의 한국어 정확도, 지연, 발열 및 메모리
- 출시된 앱 바이너리와 현재 소스의 완전한 동등성
- Android 빌드 및 실기기 E2E

따라서 저장소의 시드가 비어 있다는 사실을 운영 DB도 비어 있다는 뜻으로 해석하지 않는다. 프롬프트 재현 결과 역시 모델 출력 평가가 아니라 **모델 호출 전 입력 손실 검사**다.

## 3. 개선 백로그

P0는 다음 릴리스 전 우선 해결할 정확성·배포 차단 항목, P1은 핵심 흐름 안정화, P2는 확장·정리 항목이다. 모두 미착수이며 담당자와 일정은 별도 합의가 필요하다.

| ID | 우선순위 | 개선 항목 | 현재 근거 | 완료 기준 |
| --- | --- | --- | --- | --- |
| IMP-01 | P0 | 정답과 오답을 구분한 약점 분석 | 채점은 모든 답을 저장하지만 약점 집계는 정오답을 구분하지 않음 | 정답만 반복한 영역은 약점에 잡히지 않고 오답 기반 개인화가 테스트로 검증됨 |
| IMP-02 | P0 | 본문·RAG 근거를 보존하는 프롬프트 예산 | 앞부분 절단으로 실제 사건 입력과 검색 근거가 손실됨 | 두 기기 예산 모두에서 질문·사건·필수 근거가 실제 엔진 입력까지 보존됨 |
| IMP-03 | P0 | 실패 중인 main CI 복구 | 릴리스 대상 선택, 포맷, 문서·링크 검사 실패 기록 | 동일 후보 커밋의 관련 CI 전체 통과 및 Archive 생성 확인 |
| IMP-04 | P1 | 모델 설치·선택·로드 재현성 | GGUF 미추적, 파일 공유 안내와 설정 불일치, Documents 모델 기본 무시 | 새 clone에서 문서만으로 승인 모델 복원 및 primary 엔진 추론 확인 |
| IMP-05 | P1 | 활성 화면과 RAG 코퍼스 연결 | 저장소 갱신은 현재 미연결인 기존 검색 화면에만 있음 | 생성·수정·삭제·재실행 후 코퍼스가 실제 저장 자료와 일치 |
| IMP-06 | P1 | 코퍼스·근거·인용의 데이터 계약 | 번들 시드 없음, 현재 검색은 개인 입력 자료 중심, 인용 검증 제한 | 출처·문서 ID·근거 구간·버전·근거 없음 처리가 정의되고 E2E에서 검증됨 |
| IMP-07 | P1 | 자동 테스트 및 AI 품질 평가 확대 | iOS 테스트 2개, 백엔드 테스트 디렉터리 없음 | 핵심 학습 E2E와 검색·분류·요약·OX 회귀 평가를 분리해 실행 |
| IMP-08 | P1 | 사용자 평가의 입력·표시·이동 UX 개선 | 짧은 입력, 긴 결과 잘림, 촬영 부재, 복귀 동선 불편 | 합의한 기기·글자 크기에서 학습 시나리오 재검증 |
| IMP-09 | P2 | 현재 구현과 문서·릴리스 기준 동기화 | 과거 서버형 설계·옛 탭 구성·제출/출시 정보 혼재 | 현재/과거/계획 구분, 릴리스별 기능·모델·검증 결과 일치 |
| IMP-10 | P2 | Android 최소 수직 흐름 구현 | Compose 탭과 안내 화면 단계 | 실기기에서 OCR → 분석 → OX → 저장·재실행 완료 |
| IMP-11 | P2 | 한국어 모델 후보의 재현 가능한 비교 | 미추적 실험 스크립트와 후보 파일만 확인 | 같은 평가셋의 품질·지연·메모리·라이선스 결과로 채택 여부 결정 |

### 3.1 IMP-01: 약점 분석 정합성

- 근거: [채점 및 기록 저장](../../code/ios/AISYSApp/Sources/NewMainScreens.swift), [약점 과목 집계](../../code/ios/AISYSApp/Sources/Models.swift), [약점 키워드 집계](../../code/ios/AISYSApp/Sources/LegalAnalyzer.swift).
- `PracticeView.commit`은 정답과 오답 모두 저장한다. `weakSubjects`와 `weakKeywords`는 정답 기록을 제외하지 않는다.
- 오답 목록은 별도로 정오답을 필터링하므로, 화면 목록과 약점 진단의 기준도 다르다.
- 정답이지만 메모를 남긴 기록을 복습 대상으로 포함할지는 제품 규칙으로 명시한다. 이를 자동으로 오답과 동일시하지 않는다.

완료 확인:

- [ ] 같은 과목을 두 번 맞힌 기록만으로 약점이 생기지 않는다.
- [ ] 반복 오답은 약점 순위와 개인화 입력에 반영된다.
- [ ] 정답·오답·메모 혼합 기록에 대해 목록, 집계, 프롬프트의 기준이 일치한다.

### 3.2 IMP-02: 프롬프트 예산

- 근거: [요약 템플릿](../../code/ios/AISYSApp/Sources/PromptTemplates.swift), [생성 전 절단](../../code/ios/AISYSApp/Sources/LLMService.swift).
- 단순히 문자 한도를 늘리는 대신 지시, 실제 입력, 근거, 예시의 우선순위와 모델 컨텍스트 예산을 분리한다.
- 필수 입력과 근거의 자리를 먼저 확보하고 예시·선택적 근거를 줄인다. 초과 시 본문·근거를 요약하거나 청크별로 제한한다.
- 문자 수와 토큰 수는 다르다. 채팅 템플릿과 출력 토큰을 포함한 최종 컨텍스트 한도를 검증한다.

완료 확인:

- [ ] 저메모리·일반 기기 설정 모두에서 사건번호, 질문 및 채택 근거가 실제 엔진 입력에 남는다.
- [ ] 긴 원문, 여러 근거, 한국어·영문 혼합 입력에서도 한도를 넘지 않는다.
- [ ] primary와 fallback 입력을 각각 검사하며, 캐시 적중으로 검사가 생략되지 않는다.

### 3.3 IMP-03: CI 및 릴리스

2026-11-02 조회 시 확인한 최근 main 실행:

| 검사 | 상태 | 확인된 실패 단계 또는 한계 |
| --- | --- | --- |
| Automated Checks | 성공 | 백엔드 테스트가 없으면 문법 컴파일로 대체 |
| [iOS CI](https://github.com/acertainromance401/STACK112/actions/runs/27813452244) | 성공 | 기존 빌드·단위 테스트 범위 |
| [Main Release](https://github.com/acertainromance401/STACK112/actions/runs/27813452281) | 실패 | Resolve simulator destination |
| [Code Check](https://github.com/acertainromance401/STACK112/actions/runs/27813452289) | 실패 | Ruff format check; 별도 Bandit/pip-audit 작업은 성공 |
| [Documentation](https://github.com/acertainromance401/STACK112/actions/runs/27814499964) | 실패 | Markdown 검사 |
| [Docs Lint](https://github.com/acertainromance401/STACK112/actions/runs/27814499933) / [Docs Link Check](https://github.com/acertainromance401/STACK112/actions/runs/27814499913) | 실패 | 문서 형식 및 링크 검사 |

- 성공과 실패 기록의 대상 커밋이 같다고 가정하지 않는다. 복구 후 하나의 릴리스 후보 SHA로 필요한 검사를 다시 실행한다.
- 현재 [릴리스 워크플로](../../.github/workflows/main-release-ondevice.yml)는 미서명 Archive 보관까지이며, App Store 제출 전체 자동화가 아니다.
- CI가 녹색이어도 모델 누락으로 fallback만 동작할 수 있다. 모델 로드·실제 추론은 별도 릴리스 점검 항목으로 둔다.

### 3.4 IMP-04~07: 재현성, 데이터, 테스트

- 모델: 파일명, 원본 배포처, 라이선스, 버전, 양자화, 체크섬 및 복원 위치를 기록한다.
- [iOS 안내](../../code/ios/README.md)의 Finder 파일 공유 절차와 [실제 설정](../../code/ios/project.yml)의 `UIFileSharingEnabled=NO`, Documents 모델 무시 기본값을 일치시킨다.
- 모델 준비 판정은 `ready` 상태만 보지 않고 실제 엔진이 primary인지, 채택 모델이 무엇인지와 추론 성공을 함께 확인한다.
- RAG를 개인 자료 대상으로 유지할지, 검수된 공공 판례까지 확장할지는 범위 합의 후 결정한다. 외부 서버 도입을 기본 전제로 삼지 않는다.
- 데이터 계약에는 안정적인 문서/청크 ID, 사건번호, 출처, 근거 위치, 정제·검수 상태 및 버전을 포함한다.
- 임베딩을 도입한다면 실제 모델 차원과 스키마를 맞춘다. `vector(1024)` 선언만으로 모델 선정이나 적재 완료를 간주하지 않는다.
- 테스트는 검색 관련도, 법률 신호 보존, 요약 사실성, OX 정답 정합성, 근거 없는 질문의 거절을 구분한다.
- 골든 평가셋과 목표치를 먼저 합의하고 측정한다. 기존 [성능 문서](../research/OPTIMIZATION_COMPLETE.md)의 추정치를 현재 실측 성과로 재사용하지 않는다.

### 3.5 IMP-08~11: UX 및 확장

- [사용자 평가](../research/User_Evaluation_Report.md)의 짧은 입력 안내, 긴 텍스트 스크롤, 홈 복귀, 카메라 촬영 요청을 회귀 시나리오로 전환한다.
- 시험일 입력 온보딩과 학습 흐름 튜토리얼을 구분한다. 이미 존재하는 시험일 입력 시트를 미구현으로 분류하지 않는다.
- [현재 탭](../../code/ios/AISYSApp/Sources/RootTabView.swift)은 홈/판례 스캔/문제풀이/오답노트/AI분석이다. 기존 검색·복습·마이페이지 화면과 구분해 문서화한다.
- [Android 체크리스트](../../code/android/FEATURE_PARITY_CHECKLIST.md)는 목표 목록이다. 현재 탭 골격을 기능 동등성 달성으로 표시하지 않는다.
- 미추적 `scripts/llm_poc/`와 후보 모델은 정식 구현과 분리해 검토한다. 기존 로컬 실험은 이 문서화 작업에서 수정하거나 커밋하지 않는다.

## 4. RAG 구성 요소별 판정

| 단계 | iOS 현재 상태 | 백엔드 현재 상태 | 판정 |
| --- | --- | --- | --- |
| 코퍼스 | SwiftData 자료와 로컬 검색용 풀은 별개; 선택적 시드 없음 | DB 스키마 존재, 저장소 시드는 의도적으로 비어 있음 | 운영 코퍼스 구축 완료 근거 부족 |
| 적재·색인 | 현재 화면의 저장소 동기화 연결 누락 | 청크·임베딩 스키마만 있고 생성·적재 연결 미확인 | 미완료 |
| 검색 | 키워드 점수 기반 유사 판례 검색 코드 존재 | SQL ILIKE 검색과 별도 TF-IDF 유사도 API 존재 | 부분 구현 |
| 근거 주입 | 요약 프롬프트에 유사 판례를 붙임 | 검색 자료로 응답 템플릿 구성 | 부분 구현 |
| 근거 보존 | 720/960자 절단으로 요약의 RAG 근거 제거 | 실제 LLM에 전달하는 경로 없음 | 생성 단계 연결 미완료 |
| 생성 | 로컬 LLM/규칙 기반 fallback 존재 | grounded 및 summarize 응답 모두 템플릿·규칙 기반 | 백엔드 LLM 생성 미연결 |
| 인용·검증 | 요약에 검색 근거별 구조화 인용·검증 연결 미확인 | 사건번호 집합, 짧은 문자열 겹침 등 경량 검사 | 부분 구현 |
| E2E·평가 | 기존 테스트는 저장 관련 2개 | 테스트 디렉터리 없음 | RAG 완료를 입증하는 테스트 없음 |

### 4.1 iOS의 실제 호출 경로

```text
LLMService.summarize
  -> buildRAGEvidence
  -> NetworkService.listSimilarCases
  -> LocalCaseStore에서 대상 판례 확인
  -> LocalCaseSearchEngine.similar
  -> 검색 결과를 요약 템플릿에 추가
  -> 생성 전 프롬프트 앞부분 절단
  -> 로컬 LLM 또는 규칙 기반 fallback
```

근거: [LLMService](../../code/ios/AISYSApp/Sources/LLMService.swift), [NetworkService](../../code/ios/AISYSApp/Sources/NetworkService.swift), [검색 엔진](../../code/ios/AISYSApp/Sources/LocalCaseSearchEngine.swift), [검색용 저장소](../../code/ios/AISYSApp/Sources/LocalCaseStore.swift).

연결상의 제한:

1. `buildRAGEvidence`는 사건번호가 `OCR-`로 시작하면 검색을 생략한다.
2. 검색용 풀에 현재 사건이 없으면 `listSimilarCases`는 빈 결과를 반환한다.
3. 저장소 갱신 호출은 [기존 SearchView](../../code/ios/AISYSApp/Sources/SearchFlowViews.swift)에만 있다. 현재 루트에서 해당 화면을 생성하는 호출은 확인되지 않았다.
4. `seed_cases.json`은 선택적으로 읽지만 현재 저장소에 없다. 초기 풀은 비어 있고, 현재 주 화면의 저장 동작만으로 검색용 풀이 갱신되지 않는다.
5. 요약 RAG의 실제 검색은 토큰 매칭이다. 별도 [NLEmbedding 엔진](../../code/ios/AISYSApp/Sources/LocalSimilarityEngine.swift)은 기존 복습 화면에서 사용하며, 이 호출 경로에서는 사용하지 않는다.
6. 요약 프롬프트에 붙인 근거도 뒤쪽에 있어 생성 전 절단으로 손실된다.

현재 판례 원문을 그대로 요약하거나 규칙으로 학습 카드를 만드는 동작은 가능하다. 그러나 이것만으로 별도 코퍼스 검색을 결합한 RAG가 동작한다고 판단하지 않는다.

### 4.2 프롬프트 절단 재현

소스: [LLMPromptTemplate.summarize](../../code/ios/AISYSApp/Sources/PromptTemplates.swift), [generateUsingBestAvailableEngine](../../code/ios/AISYSApp/Sources/LLMService.swift).

실제 템플릿을 임시 `main.swift`와 함께 `swiftc`로 컴파일했다. 모델이나 서버 호출은 수행하지 않았다.

| 입력 | 측정 결과 |
| --- | --- |
| 각 사건 필드를 짧은 감사용 문자열로 채운 입력 | 총 1,122자, 사건번호 표식 시작 949, RAG 표식 시작 1,077 |
| 사건 필드를 모두 비우고 RAG 표식만 제공한 최소 입력 | RAG 표식 시작 984 |
| 최소 입력에 `prefix(720)` 적용 | RAG 표식 보존 실패 |
| 최소 입력에 `prefix(960)` 적용 | RAG 표식 보존 실패 |

위치는 Swift `Character` 기준 0부터 센 값이다. 대표 입력은 960자 한도에서도 사건번호 표식 중간이 잘렸으며, 720자 한도에서는 실제 사건 본문 이전에 잘렸다. 두 경우 모두 RAG 근거가 사라졌다.

최소 재현 코드를 임시 `main.swift`로 저장하고, 저장소 루트에서 아래 명령으로 실행할 수 있다. `/path/to/`는 임시 작업 경로로 바꾼다.

```swift
import Foundation

let marker = "RAG_AUDIT_EVIDENCE"
let prompt = LLMPromptTemplate.summarize(
    caseNumber: "", caseName: "", issue: "",
    holding: "", examPoints: "", ragEvidence: marker
)
guard let range = prompt.range(of: marker) else {
    fatalError("Missing evidence marker")
}
print("evidence_offset=\(prompt.distance(from: prompt.startIndex, to: range.lowerBound))")
for limit in [720, 960] {
    let preserved = String(prompt.prefix(limit)).contains(marker)
    print("limit=\(limit) evidence_preserved=\(preserved)")
}
```

```bash
swiftc code/ios/AISYSApp/Sources/PromptTemplates.swift \
  /path/to/main.swift -o /path/to/prompt-audit
/path/to/prompt-audit
```

모델이 근거 없이 어떤 답을 출력하는지는 별도 검증 대상이다. 이번 결과로 확인한 사실은 입력 근거의 손실이며, 특정 환각 출력이나 법률 판단 오류를 재현했다고 주장하지 않는다.

### 4.3 백엔드의 실제 상태

- [grounded_answer](../../code/backend/app/main.py)는 `_retrieve_grounded_cases`로 `published_cases`를 SQL ILIKE 검색한 뒤 Python 문자열 템플릿으로 답을 만든다.
- 같은 파일의 `/llm/summarize`도 현재 규칙 기반 요약·OX 응답이며, 이름과 달리 서버 LLM을 호출하지 않는다.
- `/cases/{case_number}/similar`는 최대 700개 판례의 TF-IDF 행렬을 만들고 코사인 유사도로 검색한다. [구현](../../code/backend/app/ir_pipeline.py)은 pgvector 검색과 다르며, grounded 응답 경로에도 직접 연결되지 않는다.
- [스키마](../../code/db/schema.sql)에 `case_chunks.embedding vector(1024)`가 있지만, 애플리케이션 코드에서 해당 청크 적재·임베딩 기록·벡터 거리 질의는 확인되지 않았다.
- [seed.sql](../../code/db/seed.sql)은 의도적으로 비어 있다. 운영 DB 적재 여부는 별도 확인이 필요하다.
- iOS의 `groundedAnswer`는 온디바이스 모드에서 비지원 오류를 반환하므로 현재 앱이 이 백엔드 응답을 사용하지 않는다.

인용 검증의 한계:

- [grounding.py](../../code/backend/app/grounding.py)는 인용 사건번호가 검색 집합에 있는지와 인용문에 8자 이상 겹치는 구간이 있는지 등을 확인한다.
- `no_unsupported_numeric_facts`는 규칙 목록에는 있지만 실제 숫자 사실 검사로 구현되어 있지 않다.
- 검증 위반은 `safety_flags`에 실리며 답변 생성 자체를 차단하지 않는다.
- 이 검사는 답변의 모든 법률 주장이 근거로 입증되는지 보장하지 않는다.

## 5. RAG 구축 완료를 위한 제안 순서

기존 온디바이스 원칙을 보존하는 **개인 판례 코퍼스 RAG**를 우선 제안한다. 공공 판례 DB 확장은 범위·권리·운영 정책 합의 후 별도 단계로 둔다.

1. **필수 입력 보존**: IMP-02를 먼저 해결하고 실제 엔진 입력의 근거 보존을 검사한다.
2. **코퍼스 동기화**: 스캔·붙여넣기 자료의 생성·수정·삭제·재실행을 검색용 풀과 연결한다.
3. **검색 계약**: 대상 판례가 풀에 없거나 사건번호가 없는 경우도 처리하고 자기 자신·중복 결과를 구분한다. 키워드 검색부터 평가하며 임베딩 도입을 필수로 전제하지 않는다.
4. **근거 조립**: 문서/청크 ID와 출처를 보존하고, 관련도·길이 기준으로 근거를 선택한다. 법률 용어 사전의 연관어를 실제 판례 근거와 혼동하지 않는다.
5. **생성·인용 검증**: 검색된 근거 ID와 출력 인용을 연결하고, 근거 부족·파싱 실패·모델 실패를 사용자에게 구분해 알린다.
6. **골든셋 평가**: 검색 지표와 생성 근거성을 분리해 측정하고 릴리스 회귀 검사에 포함한다.

완료 확인:

- [ ] 새 설치의 빈 코퍼스에서는 자료 부족을 명시하고 근거 있는 답변처럼 보이는 출력을 만들지 않는다.
- [ ] 판례 A/B 저장 후 A를 분석하면 적절한 경우 B를 검색하고 실제 엔진 입력에 B의 근거와 ID가 남는다.
- [ ] 추가·수정·삭제·앱 재실행 후 결과가 코퍼스와 일치하며 오래된 캐시를 사용하지 않는다.
- [ ] 외부 네트워크 없이 검색·근거 주입·로컬 생성·인용 확인이 끝까지 동작한다.
- [ ] 관련 없는 질문, 충돌하는 판례, 짧은 입력, 모델 미존재를 포함한 E2E가 통과한다.
- [ ] 합의한 평가셋에서 Recall@k/MRR 등 검색 품질, 인용 일치율·근거 없는 주장 비율, 지연·메모리를 측정한다. 목표치는 제안 후 합의하며 현재 달성 수치로 표시하지 않는다.

## 6. 진행 관리 및 문서 사용

- 구현 순서: IMP-01~03 우선, IMP-04 및 IMP-07 병행, RAG는 IMP-02 해결 후 IMP-05~06 연결과 E2E 검증.
- 이 문서는 점검 스냅샷이며 체크박스는 향후 완료 조건이다. 코드 수정이나 테스트 추가가 끝났다는 뜻이 아니다.
- 개선 완료 시 PR/커밋, 검증 명령·결과, 대상 기기, 모델·데이터 버전 및 남은 제한을 기록한다.
- 과거 [로드맵](Project_Status_and_Roadmap_2026-05-12.md), [모델 카드](../model/MODEL_CARD.md), [운영 런북](../operations/ONDEVICE_RUNBOOK.md), [사용자 평가](../research/User_Evaluation_Report.md)와 함께 관리한다.

## 7. 온디바이스 RAG 개선 반영

사용자 요청에 따라 변경 범위를 실제 iOS 앱의 온디바이스 코드로 한정했다. 백엔드, PostgreSQL, Android 및 기존 실험 스크립트는 수정하지 않았다. 1~6절의 진단과 프롬프트 재현 수치는 변경 전 `2e96237` 기준이며 현재 구현에 그대로 적용되는 결론이 아니다.

### 7.1 수정한 경로

```text
RootTabView의 SwiftData 쿼리
  -> 저장·수정·삭제 및 초기 진입 시 LocalCaseStore 동기화
  -> 검색용/표시용 자료와 revision을 원자적 스냅샷으로 읽음
  -> 현재 APICase 본문으로 유사 판례 검색
  -> 자기 자신·사건번호 중복 제외, 표시 자료로 근거 구성
  -> 현재 판례 / 참고 판례 / 출력 구간 분리
  -> 문자 예산 및 실제 GGUF 토큰 예산에 맞춰 발췌 조절
  -> 전체 chat template와 참고 근거를 보존한 로컬 추론
  -> 원 판례 정보를 우선하는 기존 학습 카드 후처리
```

| 기존 문제 | 반영한 개선 | 관련 코드 |
| --- | --- | --- |
| 사용하지 않는 SearchView에서만 자료 동기화 | 활성 RootTabView에서 초기 진입 및 검색 필드 변경을 감시; 개수가 같은 수정도 반영 | [RootTabView](../../code/ios/AISYSApp/Sources/RootTabView.swift) |
| 검색·표시 풀을 서로 다른 시점에 읽음 | 두 풀과 revision을 잠금 한 번으로 읽는 불변 스냅샷 | [LocalCaseStore](../../code/ios/AISYSApp/Sources/LocalCaseStore.swift) |
| OCR 또는 미등록 사건 검색 제외 | APICase 전체를 직접 검색 입력으로 사용; 상세 화면 유사 판례 조회도 같은 방식 적용 | [NetworkService](../../code/ios/AISYSApp/Sources/NetworkService.swift), [CaseSummaryViewModel](../../code/ios/AISYSApp/Sources/CaseSummaryViewModel.swift) |
| 중복·동점 순서·무관한 일반 단어 매칭 | 실제 사건번호 정규화·중복 제거, ID 동점 정렬, 인식된 법률 개념이 있으면 그 개념/연관어와 겹치는 후보만 검색 | [LocalCaseSearchEngine](../../code/ios/AISYSApp/Sources/LocalCaseSearchEngine.swift) |
| 사건번호만 사용하는 요약·근거 캐시 | 전체 APICase + 코퍼스 revision + 모델 로드 revision 키; 모델 로드 시 생성 캐시 초기화 | [LLMService](../../code/ios/AISYSApp/Sources/LLMService.swift) |
| 고정 예시가 입력 예산 대부분 차지 | 예시 제거, 현재 판례와 참고 판례 역할 분리, 필드 발췌와 참고 개수 조절 | [PromptTemplates](../../code/ios/AISYSApp/Sources/PromptTemplates.swift) |
| 생성 엔진에서도 토큰 prefix 재절단 | 요약 조립 시 실제 토크나이저로 chat template 전체 검사; 실제 `llama_n_ctx`를 사용해 출력 여유를 포함한 예산 계산 | [LocalLLMEngines](../../code/ios/AISYSApp/Sources/LocalLLMEngines.swift) |
| 판례 간 KV 상태 누적·규칙 엔진의 필드 불일치 | 추론마다 KV 메모리 초기화; 규칙 엔진은 현재 판례 구간의 한국어 필드를 읽음 | [LocalLLMEngines](../../code/ios/AISYSApp/Sources/LocalLLMEngines.swift) |

참고 근거가 있다면 최소 한 건의 사건번호와 발췌를 유지한다. 가장 작은 발췌도 입력 예산에 들어가지 않으면 참고 자료를 숨겨 버리는 대신 로그 및 진단 메시지를 남기고 현재 판례의 원문 기반 카드로 복구한다. 이것은 RAG 생성 성공으로 취급하지 않는다.

### 7.2 추가한 회귀 검증

[XCTest](../../code/ios/AISYSAppTests/AISYSAppTests.swift)에 다음을 추가했다.

- 자료 추가·같은 개수의 수정·삭제·동일 갱신과 revision 동작
- 실제 RootTabView를 SwiftData 컨테이너와 함께 호스팅해 초기 진입·같은 개수의 수정·삭제 동기화 확인
- 미등록 OCR 판례 검색, 자기 자신·사건번호 중복·무관한 법률 개념 제외, 동점 정렬
- SwiftData 레코드 변환과 수정·삭제 반영, OCR 검색용 원문이 표시 결과에 섞이지 않는지 확인
- 캡처 엔진을 통한 현재 판례·참고 근거·출력 형식·chat footer 보존
- 입력 내용 및 코퍼스 변경, 빈 검색 후 자료 추가, 모델 재로드 시 캐시 재평가
- 예산 부족 시 진단과 원문 기반 복구, 규칙 엔진의 참고 판례 결론 혼입 방지
- 번들 GGUF가 있을 때 실제 토크나이저로 긴 입력 축약·예산 초과 거부를 확인하고 두 번 연속 실제 추론 실행

마지막 검증은 모델 파일이 없는 환경에서는 명시적으로 skip한다. 실제 법률 답변의 정답률을 검사하는 테스트는 아니며, 입력 전달·예산·런타임 동작을 검사한다.

실행 결과:

- Xcode 26.1.1, iPhone 17 Simulator, iOS 26.1에서 앱 및 테스트 타깃 빌드 성공.
- 1차 전체 실행: 14개 통과, 실패 0, skip 0. 실제 GGUF 검증도 통과했다.
- 2차 집중 실행: 새 루트 화면 통합 테스트 및 강화한 긴 입력 축약 테스트 2개 통과, 실패 0.
- 중복 실행 1개를 제외하면 기존 2개 + 신규 13개, 서로 다른 15개 테스트를 검증했다.
- 실제 GGUF 검증 케이스는 약 235초였다. 모델 로드·토큰 검사·2회 추론을 합한 테스트 시간이며 단일 요약의 지연 측정값이 아니다.
- 신규 전용 시뮬레이터를 사용했고 각 실행 후 종료·삭제했다.
- 새 설치에서 기존과 동일한 SwiftData 디렉터리 복구 로그가 발생했지만 자동 복구 후 테스트는 통과했다. 관련 없는 저장소 초기화 코드는 변경하지 않았다.
- `git diff --check` 통과. 본 보고서 Markdown lint는 오류 0. 루트 README의 기존 25개와 iOS README의 기존 15개 표 정렬 lint 오류는 증가하지 않았다.

### 7.3 기존 카드 경로의 남은 범위

아래는 기존 카드 경로의 한계다. 별도 연구 RAG 경로에 추가한 기능과 검증은 8절을 참조한다.

- 선택적 시드 데이터는 여전히 없다. 초기 상태에서 검색할 다른 판례가 없다면 참고 근거를 생성하지 않는다.
- OCR 검색 범위는 기존처럼 앞 1,500자 및 추출 필드다. 현재 근거는 필드 발췌이며 문장 단위 청킹과 위치 정보가 없다.
- 벡터 검색이나 새 임베딩 모델을 도입하지 않았다. 키워드 기반 검색의 Recall@k/MRR 및 근거 충분성은 별도 평가가 필요하다.
- 요약 출력의 구조화 인용·인용문 검증은 아직 없다. 유사 판례 목록과 LLM에 전달한 근거가 있다는 사실만으로 각 법률 주장이 검증되었다고 할 수 없다.
- 유효한 요약이 ViewModel에 주입되어 있고 OCR/스캔 문서 조건을 만족하면 그 요약을 보존한다. 활성 라이브러리의 기본 상세 진입은 새 ViewModel을 사용하므로 생성/캐시 경로를 탄다. 저장되어 있다는 사실만으로 요약 생략 여부가 결정되지는 않으며, 메모리 캐시 무효화가 저장 요약을 일괄 재생성하는 것도 아니다. 분기는 [RAG 동작 지도](../architecture/OnDevice_RAG_Map_2026-11-02.html)에서 확인할 수 있다.
- 원 판례 우선 후처리를 유지한다. 이번 변경은 다른 판례의 결론을 현재 판례에 섞어 출력하도록 바꾸는 기능이 아니다.
- 작은 컨텍스트에서는 발췌가 짧아진다. 4GB 실기기에서 품질·지연·발열·메모리를 다시 측정해야 하며, 이번 변경을 App Store에 배포하지는 않았다.

## 8. 논문용 별도 RAG 분석·평가 확장

사용자가 선택한 방향은 **기존 카드 보존 + 별도 근거 분석 추가**다. 원문 우선 후처리로 생성 결과가 가려지는 문제를 피하고, 원시 생성과 실패를 그대로 측정한다. 기존 카드·퀴즈·오답노트의 의미를 조용히 바꾸지 않았다.

### 8.1 반영 사항

| 연구 제안의 요구 | 반영한 구현 | 관련 코드 |
| --- | --- | --- |
| 원문·메타데이터 관리 | SwiftData 원문 전체와 추출 필드를 함께 동기화, 1,500자 이후 수정 및 같은 개수의 필드 수정 감지 | [RootTabView](../../code/ios/AISYSApp/Sources/RootTabView.swift), [ScannedCase](../../code/ios/AISYSApp/Sources/ScannedCase.swift) |
| 원문 청킹 | 320자/64자 겹침, 안정적 청크 ID, UTF-16 범위·원문 SHA-256, 실제 전달 발췌 추적 | [RAGCore](../../code/ios/AISYSApp/Sources/RAGCore.swift) |
| 사건번호·키워드·의미 검색 | 정확한 사건번호, 키워드, E5-base 벡터 검색의 RRF 융합; 자신/동일 사건 중복 제외 | [RAGCore](../../code/ios/AISYSApp/Sources/RAGCore.swift), [GGUFEmbeddingProvider](../../code/ios/AISYSApp/Sources/GGUFEmbeddingProvider.swift) |
| 실제 온디바이스 임베딩 | MIT E5-base Q8_0, 원본 호환 SentencePiece, 768차원 mean/L2, query/passage 접두사, 모델 해시 검증·벡터 캐시 | [모델 manifest](../../code/ios/AISYSApp/Resources/rag_embedding_model.json), [설치 스크립트](../../scripts/fetch_rag_embedding.sh) |
| 근거 기반 생성 | E0 현재 판례 / E1·E2 참고 판례, 실제 GGUF 토큰 예산, 분석과 별도 OX 초안 | [LLMService](../../code/ios/AISYSApp/Sources/LLMService.swift) |
| 출력 검증·실패 처리 | 모든 줄의 인용 ID, 숫자·인용문·문구 겹침 proxy, OX 3줄/O·X 검사, 실패·중단을 모델 성공으로 집계하지 않음 | [RAGCore](../../code/ios/AISYSApp/Sources/RAGCore.swift), [RAGResearch](../../code/ios/AISYSApp/Sources/RAGResearch.swift) |
| 5개 평가 항목 | P@3/R@3/MRR, 자동 proxy·사람 근거성, 실제 생성 호출 시간, 프로세스 표본 메모리, 출력 성공률 | [RAGResearch](../../code/ios/AISYSApp/Sources/RAGResearch.swift) |
| 비교·재현 | 현재 판례만/키워드/하이브리드, 단일 모드 선택, 반복/순서 회전, 원자료·집계 JSON, 두 모델 해시와 런타임 revision | [평가 화면](../../code/ios/AISYSApp/Sources/RAGResearchViews.swift), [project.yml](../../code/ios/project.yml) |
| 데이터·검수 | 합성 8문서/3질문, 검증된 JSON 가져오기, 원문 대조·검수자/지지 문장 수 기록 | [평가셋](../../code/ios/AISYSApp/Resources/rag_synthetic_v1.json), [평가 프로토콜](../research/OnDevice_RAG_Protocol.md) |

원문은 영속 저장하며 청크는 요청마다 결정적으로 재구성한다. 별도 영속 벡터 DB는 아니다. 임베딩 가중치는 빌드 준비 때만 받아 번들에 포함하며 앱 런타임에는 네트워크를 사용하지 않는다. 추가 가중치는 약 289.1 MiB이고 Git에는 포함하지 않는다. 모델 역할을 분리해 임베딩 파일이 요약용 생성 모델로 선택되지 않게 했다.

### 8.2 검증 근거와 한계

- 기존 경로 14개 + 실제 임베딩 5개 + 연구 경로 17개, **36개 회귀 검사 통과**.
- 별도 실제 E5 검색 → 실제 번들 GGUF 생성 → 인용 파싱 E2E 1개 통과. 준비/규칙 기반/가짜 엔진을 모델 생성 성공으로 취급하지 않았다.
- 앞서 통과한 실제 생성 모델 토크나이저·2회 연속 추론 검사까지 합쳐 서로 다른 38개 테스트를 실행했다. 실제 생성 검사는 기능/런타임 확인이며 법률 정답률 평가나 실기기 성능 측정이 아니다.
- 한국어 관련 문서가 무관한 음식 문서보다 높은 의미 점수를 갖는지 실제 가중치로 검사했다. 같은 입력의 캐시 재사용, 수정된 본문의 재계산, 초과 입력의 명시적 경고, 손상 모델 해시 거절, 모델 오선택 방지도 확인했다.
- 최초 선택한 소형 변환본은 이 순위 검사에서 실패해 제외했다. 기준을 완화하지 않고 원본 호환 토크나이저를 가진 base 변환본으로 교체했다.
- 최신 루트 화면 통합 검사는 OCR 앞부분을 동일하게 둔 채 1,500자 이후만 수정해 동기화를 확인한다.
- 시뮬레이터는 기능 검사에만 사용했다. 실기기 성능 배치는 시뮬레이터 UI에서 실행할 수 없고 성능 집계도 실기기만 포함한다.
- 기존 지도는 카드 경로로 유지하고 별도 연구 흐름 6단계와 코드 위치를 추가했다. 기존 51개 및 연구 8개 소스 링크를 확인했다.

**논문 실험은 아직 완료되지 않았다.** 실제 판례·검색 정답, 법률 검수, 대상 iPhone의 반복 실행이 필요하다. 자동 기초 검사는 법률적 함의·정답을 인증하지 않으며, 코사인 임계값도 실제 개발셋으로 보정해야 한다. 4GB 실기기의 모델 동시 상주 메모리·발열·지연·품질을 검증하기 전 배포 적합성이나 성능 향상을 주장하지 않는다.

실행·데이터 스키마·지표 분모·실험 통제 조건은 [논문 평가 프로토콜](../research/OnDevice_RAG_Protocol.md)에 정리했다. 백엔드/Android는 변경하지 않았고, 커밋 및 App Store 배포는 수행하지 않았다.
