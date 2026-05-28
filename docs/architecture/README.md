# Architecture Documents

## 목적

- 시스템 구성요소와 데이터 흐름을 한눈에 파악할 수 있도록 정리
- 신규 팀원이 빠르게 전체 구조를 이해하도록 지원

## 참고 문서

- `code/ARCHITECTURE_AND_DEPLOYMENT.md`
- `code/PRODUCTION_DEPLOYMENT_GUIDE.md`
- `docs/images/request-sequence.mmd`
- `docs/images/run-flow.mmd`
- `docs/images/container-graph.mmd`

## 체크리스트

- 핵심 컴포넌트 책임이 명확한가?
- 입력/출력 경계(API, 저장소, 모델)가 정의되어 있는가?
- 장애 시 폴백/복구 전략이 문서화되어 있는가?
