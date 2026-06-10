# STACK112 Android

배포 완료된 iOS 앱과 기능 동등성을 맞추기 위한 Android 프로젝트 스캐폴딩입니다.

## 목표

핵심 학습 흐름의 기능 동등성을 갖춘 Android MVP를 구축합니다.
OCR -> 분석 -> 요약 -> OX 퀴즈 -> 복습

## 현재 상태

- 프로젝트 기본 골격 생성 완료
- Kotlin + Jetpack Compose 기본 설정 완료
- 다음 단계: 기능 모듈 구현 및 로컬 모델/런타임 통합

## 빠른 시작

1. Android Studio에서 이 폴더를 엽니다.
2. Gradle 동기화가 끝날 때까지 기다립니다.
3. 에뮬레이터 또는 실기기에서 `app` 모듈을 실행합니다.

## 권장 모듈 로드맵

- `feature/home`
- `feature/ocr`
- `feature/search`
- `feature/review`
- `feature/mypage`
- `core/model`
- `core/data`
- `core/llm`

## 체크리스트

이식 진행 시 기준 문서로 `FEATURE_PARITY_CHECKLIST.md`를 사용하세요.

## 문서 작성 기준

- Android 폴더의 신규 문서는 한국어를 기본 언어로 사용합니다.
- 기술 고유명사(예: Play Console, Room, DataStore)는 필요 시 영문 병기를 허용합니다.
- 신규 문서 작성 시 `DOC_TEMPLATE_KO.md`를 기본 템플릿으로 사용합니다.

## 작업 경계 규칙

- Android 관련 코드/문서/설정 변경은 `code/android` 하위에서만 수행합니다.
- iOS 또는 루트 문서를 수정해야 하는 경우에는 사전에 별도 합의 후 진행합니다.
