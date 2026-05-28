# FAQ & Onboarding

## 1. 처음 시작할 때 무엇을 보면 되나요?

1. `README.md`
2. `CONTRIBUTING.md`
3. `docs/README.md`
4. `code/Run_Guide_AI_SYS.md`

## 2. 브랜치/PR 규칙은 무엇인가요?

- 직접 `main` 푸시 금지
- PR 리뷰 승인 후 머지
- CI 상태 체크 통과 필수
- CODEOWNERS 리뷰 정책 준수

## 3. 필수 자동화 파일은 어디에 있나요?

- `.github/pull_request_template.md`
- `.github/CODEOWNERS`
- `.github/workflows/ci.yml`

## 4. 자주 막히는 지점은?

- Python 환경 불일치
- 의존성 버전 충돌
- 로컬 실행 경로 오류

문제 발생 시 `docs/troubleshooting/README.md` 템플릿으로 이슈를 기록하고 공유합니다.

## 5. 신규 기여자 체크리스트

- [ ] 로컬 실행 확인
- [ ] PR 템플릿 작성
- [ ] 관련 문서 업데이트
- [ ] 테스트/검증 결과 첨부
