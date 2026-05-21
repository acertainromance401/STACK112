# RFC 0001: Discussions & Wiki 운영 롤아웃

- Status: Reviewing
- Date: 2026-05-22
- Author: @acertainromance401
- Discussion: (작성 예정) GitHub Discussions 링크

## Summary
- 팀의 비동기 협업 품질을 높이기 위해 Discussions/Wiki/ADR/RFC 연계 운영을 도입한다.

## Motivation
- 실행 가능한 작업과 열린 토론이 섞여 이슈 추적 효율이 낮아졌다.
- 구두 합의가 문서로 남지 않아 반복 논의가 발생했다.

## Proposal
- Questions/Ideas/Announcements는 Discussions 우선 사용
- 확정 지식은 Wiki 또는 `docs/` 문서로 승격
- 구조/정책 변경은 RFC를 통해 사전 합의 후 구현
- 확정된 기술 결정은 ADR로 기록

## Alternatives
- Issues만으로 토론과 작업을 모두 처리
- Wiki만 사용하고 리포 문서는 최소화

## Rollout Plan
1. Discussions 카테고리 생성(Announcements, Q&A, Ideas, Show and Tell, General)
2. Wiki 기본 페이지 배포(Home, Getting Started, Architecture, API, Troubleshooting)
3. ADR/RFC 템플릿 공지 및 첫 사례 적용
4. 2주 후 운영 회고 및 규칙 보정

## Risks and Mitigations
- 리스크: 운영 도구 증가로 초기 혼란
- 대응: CONTRIBUTING 및 docs/governance에 단일 운영 규칙 제공

## Success Metrics
- PR당 문서 링크 포함 비율
- 중복 질문 감소율
- 신규 기여자 첫 PR 리드타임

## Open Questions
- Wiki를 리포 문서와 자동 동기화할지 여부
- Discussion 템플릿 고정 여부
