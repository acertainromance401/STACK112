# 세 판례 검색·생성 파일럿

## 실험 전 고정한 입력

사용자가 제시한 판례 관계를 질문별 잠정 정답으로 구성했다. 사용자 제공 공개 비실명 재판문서이며, 법률 전문가의 독립 관련성·정답 주석은 아니다.

| 문서 | 역할 | 원문 |
| --- | --- | --- |
| 2024므16033, 16040 | 비상장주식 재산분할의 현재 판례 | [기존 보존본](../sc-2024me16033-v1/source.txt) |
| 97므1486, 1493 | 재산 형성 기여도·쌍방 사정을 참작하는 일반 법리 선례 | [사용자 제공 전문](reference-97me1486.txt) |
| 2026으552 | 같은 가사 분야이나 재산분할과 다른 쟁점의 자료. L3에서는 현재 결정 | [사용자 제공 전문](distractor-2026eu552.txt) |

첫 문서의 [공식 출처](https://lx.scourt.go.kr/search/detail/precedent/0/2026000041679)는 확인했다. 추가 두 전문은 사용자 제공 전사를 보존했으며 개별 공식 URL을 아직 대조하지 않았다. ‘비관련’은 전역적인 속성이 아니라 해당 질문에 대한 직접 근거 여부다.

| 질문 | 현재 판례 | 참고 정답 | 목적 |
| --- | --- | --- | --- |
| L1 | 2024므16033 | 97므1486 | 사건번호 없는 일반 법리 질문에서 관련 선례를 찾고 면접교섭 결정을 제외하는지 |
| L2 | 2024므16033 | 97므1486 | 인용 사건번호가 명시된 검색의 양성 대조. 순수 의미 검색 시험 아님 |
| L3 | 2026으552 | 없음 | 참고 후보가 재산분할 판례뿐일 때 관련 없는 참고를 붙이지 않는지 |

질문·관련 문서·정답 초안은 [manifest.json](manifest.json)에 있고 **모델 출력을 보기 전에 고정했다.** 입력 [family_law_retrieval_v1.json](family_law_retrieval_v1.json)은 앱 스키마 v1이며 정답 초안은 모델에 제공하지 않는다.

## 실행 조건과 주장의 범위

- B0(`currentOnly`), B1(`keyword`), H(`hybrid`) 각각 실행: 3질문 × 3모드 × 1회 = **9개 요청**.
- 실제 E5-base Q8_0와 Llama-3.2-1B-Instruct Q4_K_M을 기존 앱 코드로 실행한다. 검색 기준·프롬프트·문맥·샘플링은 바꾸지 않는다.
- 테스트 번들에서 읽은 코퍼스를 앱 서비스의 문서 인자로 전달한다. OCR·SwiftData 저장·UI 조작까지 포함하는 신규 등록 E2E를 수행한 것으로 해석하지 않는다.
- 질문 순서대로 B0 → B1 → H를 실행하며 seed 고정·순서 무작위화·반복은 없다. 순서·모델 상주·캐시가 달라 지연 우열의 대조 실험이 아니다.
- 전체 요청과 원시 출력·실패·실제 전달 발췌·모델 해시를 남긴다. 검사의 통과는 기록 수집 완료를 뜻하며 답변이 모두 정답이라는 뜻은 아니다.
- 네이티브 코사인 진단은 생성 배치 후 같은 provider에서 별도 계산한다. 진단 결과로 앞선 검색 결과를 수정하거나 재선택하지 않는다.
- 기존 앱은 참고 상위 청크 최대 2개를 생성에 제공한다. 원문과 전달 발췌를 구분하고 잘린 조건·예외를 확인한다.
- 시뮬레이터 기능·출력 품질 파일럿이며 실기기 지연·메모리·발열·배터리 측정이 아니다. 세 판례의 결과를 한국어 법률 전반의 정확도나 최고 모델 근거로 일반화하지 않는다.

## 재현

프로젝트 루트에서 입력을 재생성한다.

```bash
cd docs/research/datasets/family-law-retrieval-v1
jq --rawfile current ../sc-2024me16033-v1/source.txt \
   --rawfile reference reference-97me1486.txt \
   --rawfile distractor distractor-2026eu552.txt \
   '{schemaVersion,id,kind,provenance,annotator,
     documents:[.sources | to_entries[] | .value.document +
       {text: ([$current,$reference,$distractor][.key])}],queries}' \
   manifest.json > family_law_retrieval_v1.json
```

그다음 프로젝트 루트에서 실제 모델 파일이 준비된 상태로 실행한다. 이미 설치된 대상 시뮬레이터의 UDID를 지정하며 다른 사용자의 시뮬레이터를 종료하지 않는다.

```bash
xcodegen generate --spec code/ios/project.yml
xcodebuild test -project code/ios/AISYS.xcodeproj -scheme AISYSApp \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:AISYSAppTests/LegalCasePilotTests/testRealThreeJudgmentRetrievalAndGenerationPilot \
  -parallel-testing-enabled NO -disableAutomaticPackageResolution -skipPackageUpdates \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 1800 \
  -maximum-test-execution-time-allowance 1800 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

[실험 검사 코드](../../../../code/ios/AISYSAppTests/LegalCasePilotTests.swift)는 앱 Documents의 `legal-case-pilot-v1`에 개별 실행·전체 보고서·코사인을 저장한다. 이 파일은 새 기본 앱 데이터가 아닌 **테스트 번들 리소스**다. 느린 실제 모델 검사이므로 빠른 회귀만 실행할 때는 해당 클래스를 제외한다.

분석·출력 품질 판정과 결과는 [성능·안정성 보고서](../../Execution_Log_Performance_Analysis_2026-11-03.md)에 별도로 기록한다.
