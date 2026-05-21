# GitHub Discussions & Wiki 운영 가이드

비동기 협업을 위해 GitHub Issues, Discussions, Wiki의 역할을 분리해 운영합니다.

## 1) 도구별 역할

- Issues: 실행 가능한 작업(버그, 기능 구현, TODO)
- Discussions: 열린 토론(Q&A, 아이디어, 공지, 쇼케이스)
- Wiki: 정적 지식(온보딩, 아키텍처, API, 트러블슈팅)

## 2) Discussions 권장 카테고리

- Announcements: 공지
- Q&A: 질문/답변
- Ideas: 개선 아이디어
- Show and Tell: 데모 공유
- General: 기타 토론

## 3) Discussion 작성 규칙

- 제목: 주제 + 기대 결과를 포함
- 본문: 배경, 현재 상태, 질문/제안 사항 명시
- 결론: 결정되면 관련 Issue/PR/ADR/RFC 링크를 남김

## 4) Wiki 권장 구조

- Home
- Getting Started
  - Development Setup
  - Coding Standards
- Architecture
  - System Overview
  - Data Schema
- Guides
  - API Usage
  - Troubleshooting

## 5) 연결 원칙

- Discussion에서 결정된 내용은 ADR 또는 RFC로 승격
- Wiki 문서는 리포 문서(`docs/`)와 동기화
- 오래된 Discussion은 결론 링크를 남기고 종료
