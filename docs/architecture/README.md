# Architecture Documents

## 목적

- 시스템 구성요소와 데이터 흐름을 한눈에 파악할 수 있도록 정리
- 신규 팀원이 빠르게 전체 구조를 이해하도록 지원

## 참고 문서

- **[온디바이스 RAG 동작 지도 — 인터랙티브 HTML](OnDevice_RAG_Map_2026-11-02.html)**: 개선 반영 후 로컬 iOS 코드 기준. 입력·저장·검색·근거 조립·생성·표시 및 주입 요약/캐시/복구 분기를 시각화한다. 각 노드에 파일명·함수·시작 줄 번호를 표시하며, 상세 설명·검색 가능한 코드 색인·VS Code 줄 이동·확대 기능을 제공한다. [로컬 CSS](ondevice-rag-map.css)와 같은 폴더에 보관하면 외부 네트워크 없이 동작한다. 줄 번호는 2026-11-02 작업 트리 기준이며 소스 수정 시 갱신해야 한다.
- [같은 지도의 정적 SVG](../images/ondevice-rag-map.svg): 이미지 뷰어·공유·인쇄용. HTML 안의 SVG가 원본이며 수정 시 함께 갱신한다.
- `code/ARCHITECTURE_AND_DEPLOYMENT.md`
- `code/PRODUCTION_DEPLOYMENT_GUIDE.md`
- `docs/images/request-sequence.mmd`
- `docs/images/run-flow.mmd`
- `docs/images/container-graph.mmd`

## 체크리스트

- 핵심 컴포넌트 책임이 명확한가?
- 입력/출력 경계(API, 저장소, 모델)가 정의되어 있는가?
- 장애 시 폴백/복구 전략이 문서화되어 있는가?
