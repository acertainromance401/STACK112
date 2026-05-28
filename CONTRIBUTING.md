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

## 8. 자동화 및 거버넌스 설정
- PR 템플릿 파일: `.github/pull_request_template.md`
- 코드 오너 파일: `.github/CODEOWNERS`
- 기본 CI 워크플로우: `.github/workflows/ci.yml`
- iOS CI 워크플로우: `.github/workflows/ios-ci.yml` (macOS runner)

현재 기본 정책은 아래와 같음.
- CODEOWNERS: 저장소 전체 경로(`*`)를 오너 1명으로 지정
- CI: PR/Push 시 Lint(Ruff), Test(Pytest 또는 Smoke compile) 실행
- iOS 변경 시 macOS 기반 Xcode Build/Test 실행
- PR 리뷰: 최소 승인 1명 필수
- 코드 오너 리뷰: 필수
- 상태 체크: 필수 (Lint, Test)
- 대화 해결(Conversation resolution): 필수
- 강제 푸시/브랜치 삭제: 금지

## 9. 브랜치 보호 규칙 적용 기준
대상 브랜치: `main`

GitHub 저장소 설정에서 아래 항목을 활성화함.
- Require a pull request before merging
- Require approvals (1)
- Require review from Code Owners
- Dismiss stale pull request approvals when new commits are pushed
- Require status checks to pass before merging
  - Lint (Ruff)
  - Test (Pytest or Smoke)
- Require conversation resolution before merging
- Do not allow force pushes
- Do not allow deletions

## 10. Discussions / Wiki / RFC 운영
- 열린 질문, 아이디어, 공지는 GitHub Discussions를 우선 사용함.
- 확정된 지식은 Wiki 또는 `docs/` 문서로 승격해 영구 보관함.
- 구조/정책/대규모 변경은 RFC를 작성해 합의 후 구현함.

참고 문서:
- `docs/governance/DISCUSSIONS_AND_WIKI.md`
- `docs/rfc/README.md`
- `docs/rfc/template.md`
