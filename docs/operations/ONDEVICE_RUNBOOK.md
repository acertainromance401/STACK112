# On-Device Runbook

## 목적
온디바이스 iOS 앱 기준으로 릴리스, 헬스체크, 롤백 절차를 표준화한다.

## 범위
- 대상: AI_SYS iOS 앱 (`code/ios`)
- 비대상: 서버/API 인프라 운영

## PR 게이트 (CI/CD)
- PR 필수 체크
  - Lint: Ruff
  - Test: Pytest 또는 iOS test
  - Security: Bandit, pip-audit
- 관련 워크플로우
  - `.github/workflows/ci.yml`
  - `.github/workflows/code-check.yml`
  - `.github/workflows/test-coverage.yml`
  - `.github/workflows/ios-ci.yml`
  - `.github/workflows/pr-validation.yml`

## Main 배포 파이프라인
1. `main`으로 머지
2. `main-release-ondevice.yml` 실행
3. iOS build/test 통과 확인
4. archive 산출물 업로드 확인
5. 태그 릴리스(`v1.0.0+`) 기준으로 배포 노트 작성

## 헬스체크 (On-device)
릴리스 전/후 동일 체크를 수행한다.

- 자동 실행 스크립트: `code/ios/scripts/ondevice_healthcheck.sh`

### 자동화 헬스체크
- HC-A1: 시뮬레이터 build 성공
- HC-A2: 시뮬레이터 unit test 성공
- 목적: PR 게이트와 main 릴리스 워크플로우가 깨지지 않았는지 빠르게 확인

### 수동 릴리스 점검

#### HC-1: 모델 로드
- 기준: 앱 시작 후 LLM 상태가 `loading -> ready` 전환
- 실패 시: 모델 경로/파일명(`LLAMA_MODEL_FILE`) 점검

#### HC-2: 추론 기능
- 기준: 요약 생성이 fallback 고정 문구가 아닌 생성 결과를 반환
- 실패 시: 엔진 전환 로그 확인 후 fallback 모드로 릴리스 허용 여부 판단

#### HC-3: 핵심 사용자 플로우
- 기준: OCR -> 요약 -> OX -> 오답 저장까지 완료
- 실패 시: 릴리스 중단, 직전 태그 유지

## 롤백 계획

### 조건
- Crash 급증
- 모델 로드 실패율 급증
- 핵심 플로우(HC-3) 실패 재현

### 절차
1. 직전 안정 태그로 즉시 롤백 (`vX.Y.Z`)
2. App Store Connect 제출 대기 중이면 새 빌드 배포 중단
3. 원인 분석 이슈 생성 (재현 조건, 로그, 디바이스 정보)
4. 핫픽스 브랜치에서 수정 후 재검증
5. `vX.Y.Z+1`로 재배포

## 릴리스 체크리스트
- [ ] PR 게이트 전부 통과
- [ ] 자동화 헬스체크(HC-A1, HC-A2) 통과
- [ ] 온디바이스 헬스체크 3종 통과
- [ ] RETROSPECTIVE 업데이트
- [ ] CHANGELOG 업데이트
- [ ] 태그 생성 (`v1.0.0` 이상)
- [ ] 3분 이내 데모 영상 링크 갱신
