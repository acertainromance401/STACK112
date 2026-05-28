# ADR 0002: 협업 거버넌스 문서 체계 표준화

- Status: Accepted
- Date: 2026-05-22
- Deciders: @acertainromance401

## Context
- 팀 문서가 여러 폴더에 분산되어 있어 신규 참여자가 시작점을 찾기 어려웠다.
- Discussions/Wiki/ADR/RFC 역할 분리가 명확하지 않아 비동기 협업 지식이 소실될 위험이 있었다.

## Decision
- 문서 루트를 `docs/` 허브 중심으로 통합한다.
- 프로젝트 산출물은 `docs/project/`, 역할 문서는 `docs/roles/`, 운영 규칙은 `docs/governance/`에 배치한다.
- 의사결정은 ADR, 변경 제안은 RFC로 관리한다.

## Alternatives Considered
- 기존 루트 구조 유지 + README 링크만 보강
- 모든 문서를 GitHub Wiki 전용으로 이관

## Consequences
- 장점: 탐색성 향상, 문서 책임 경계 명확화, 온보딩 속도 개선
- 단점: 초기 대량 경로 이동 비용, 기존 링크 수정 작업 필요

## Follow-up
- 신규 문서 생성 시 `docs/` 하위 표준 구조 준수
- 분기별 문서 링크 무결성 점검
