# AI_SYS iOS (SwiftUI)

최종 업데이트: 2026-05-11
현재 상태: 완전 온디바이스(Backend-free) 동작. iPhone 12 mini(A14, 4GB) 실기기 검증 통과.

> **2026-05-11 변경 사항**
> - HTTP 백엔드 의존을 제거하고 모든 검색·IR·유사 판례를 단말 내부에서 처리합니다.
> - 신규 모듈: `LegalIssueDictionary`, `LocalIRPipeline`, `LocalCaseSearchEngine`, `LocalCaseStore`.
> - 복습 노트의 "자주 틀리는 영역" → 영역별 오답 OX 모음(`WeakOXListView`) 화면 신설.
> - Review 탭 진입 시 lag 해소(NLEmbedding 비동기 캐시).
> - 탭 root view 의 비활성 뒤로가기 버튼 제거.
> - **주의**: `xcodegen generate` 를 실행하면 수동으로 추가한 4개 신규 Swift 파일의 `pbxproj` 등록과 `DEVELOPMENT_TEAM` 설정이 사라질 수 있습니다. 신규 파일은 직접 `pbxproj` 에 등록되어 있으니 *필요할 때만* `xcodegen` 을 사용하세요.

이 폴더는 `xcodegen`으로 생성되는 iOS SwiftUI 프로젝트입니다.

## 빠른 실행

```bash
cd code/ios
xcodegen generate
open AISYS.xcodeproj
```

Xcode에서 `AISYSApp` 스킴을 선택한 뒤 iPhone Simulator로 실행하면 됩니다.

실기기(iPhone) 실행 시에는 Xcode에서 `Signing & Capabilities`의 Team을 본인 Apple ID 팀으로 1회 선택하면 바로 실행됩니다.

## 로컬 LLM 모델 파일 안내

- GGUF 모델 파일은 저장소에 커밋하지 않습니다.
- 앱은 우선 `Documents/models/` 경로에서 모델(`*.gguf`)을 탐색합니다.
- 필요 시 `Info.plist`의 `LLAMA_MODEL_FILE` 값을 원하는 파일명으로 지정할 수 있습니다.
- 모델이 없으면 LlamaCpp 엔진 로드가 실패하고, 앱은 Rule-based fallback 엔진으로 동작합니다.

### 실기기 모델 배치 절차

1. Xcode에서 앱을 실기기에 1회 실행해 앱 컨테이너를 생성합니다.
2. Finder에서 iPhone을 선택한 뒤 파일 공유(File Sharing)에서 `AI_SYS` 앱을 엽니다.
3. 앱 내부 `Documents/models/` 폴더를 만들고 GGUF 파일을 복사합니다.
4. 파일명이 기본값(`Llama-3.2-1B-Instruct-Q4_K_M.gguf`)과 다르면 Xcode Target Build Settings의 `LLAMA_MODEL_FILE` 값을 동일하게 맞춥니다.
5. 앱을 완전히 종료 후 재실행해 모델 로딩을 확인합니다.

### 로딩 검증 체크리스트

1. 앱 시작 직후 LLM 상태가 `loading`에서 `ready`로 전환되는지 확인
2. Search 상세 화면에서 요약 생성 시 fallback 문구가 아닌 실제 생성 응답이 나오는지 확인
3. 모델 파일명을 변경한 경우 `LLAMA_MODEL_FILE` 값과 정확히 일치하는지 확인
4. 모델 파일이 `Documents/models/` 하위에 있고 확장자가 `.gguf`인지 확인

### 트러블슈팅

- 증상: "GGUF 모델 파일을 찾을 수 없습니다"
  - 조치: `Documents/models/` 경로, 파일명, `LLAMA_MODEL_FILE` 값을 순서대로 점검
- 증상: 앱이 즉시 fallback 엔진으로 전환됨
  - 조치: 실기기 저장공간/파일 손상 여부 확인 후 모델 재복사
- 증상: 시뮬레이터에서는 동작하지만 실기기에서 실패
  - 조치: 앱 재설치 후 모델 재복사, Team/Signing 설정 재확인

## 테스트 실행

```bash
cd code/ios
xcodegen generate
xcodebuild test \
  -project AISYS.xcodeproj \
  -scheme AISYSApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

iOS 시뮬레이터가 없으면 Mac Catalyst로도 테스트할 수 있습니다.

```bash
cd code/ios
xcodegen generate
xcodebuild test \
  -project AISYS.xcodeproj \
  -scheme AISYSApp \
  -destination 'platform=macOS,variant=Mac Catalyst,name=My Mac' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

## iPhone 바로 실행 체크리스트

1. Xcode > Settings > Accounts에서 Apple ID 로그인
2. 프로젝트 타깃 `AISYSApp` 선택
3. `Signing & Capabilities`에서 Team 선택 (Automatically manage signing 체크)
4. 상단 실행 타깃을 연결된 iPhone 또는 iPhone Simulator로 선택 후 Run

디바이스 이름이 다르면, 아래로 목록을 확인 후 변경하세요.

```bash
xcrun simctl list devices
```

## 현재 알려진 테스트 이슈 (2026-05-07)

- `AISYSAppTests.testSaveWrongAnswerAddsItemToTop` 실패
- `AISYSAppTests.testRecommendedCasesExist` 실패
- 내부 시연/개발 실행은 가능하나 운영 배포 전 테스트 기대값 정비 권장
