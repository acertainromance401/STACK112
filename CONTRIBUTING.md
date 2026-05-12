# 협업 및 기여 가이드

## 1. 기본 원칙
- 모든 변경은 이슈 기반으로 진행하여 작업 목적과 범위를 명확히 관리함.
- `main` 브랜치에는 직접 푸시하지 않고 PR 기반으로 반영함.
- 큰 변경은 작은 단위 PR로 나누어 리뷰 효율과 안정성을 높임.

## 2. 작업 시작 절차
1. 이슈 생성 또는 기존 이슈 확인
2. 최신 main 동기화
3. 작업 브랜치 생성

```bash
git checkout main
git pull origin main
git checkout -b feature/<issue-number>-<short-topic>
```

## 3. 브랜치 네이밍
- `feature/<issue-number>-<topic>`
- `fix/<issue-number>-<topic>`
- `chore/<topic>`

예시:
- `feature/12-search-rerank`
- `fix/21-empty-response`

## 4. 커밋 규칙
Conventional Commits 규칙을 사용하여 변경 의도를 일관되게 기록함.

- feat: 사용자 기능 추가
- fix: 버그 수정
- docs: 문서 변경
- refactor: 동작 변경 없는 구조 개선
- test: 테스트 추가/수정
- chore: 설정/빌드/기타 작업

예시:
- `feat: 판례 키워드 자동완성 추가`
- `fix: 질문 길이 제한 검증 오류 수정`

## 5. PR 규칙
- 최소 1명 승인 후 머지함.
- CI 및 테스트 통과를 머지의 필수 조건으로 적용함.
- PR 본문에는 아래 내용을 포함함.
  - 변경 이유
  - 주요 변경 사항
  - 테스트 방법 및 결과
  - UI 변경 시 스크린샷

## 6. Definition of Done
- 이슈의 수용 기준을 충족함.
- 테스트를 추가하거나 기존 테스트 통과를 확인함.
- 관련 문서를 필요한 범위에서 업데이트함.
- 코드 리뷰 피드백을 반영함.

## 7. 머지 방식
- 기본 머지 전략은 Squash Merge를 권장함.
- PR 제목은 릴리즈 노트 반영을 고려해 명확하게 작성함.
