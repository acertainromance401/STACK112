# API Specification Index

## 목적

- API 계약(엔드포인트, 파라미터, 응답, 오류 코드)을 일관되게 관리
- 프론트/백엔드/QA 간 인터페이스 오해를 줄임

## 현재 소스

- Swagger(OpenAPI): 백엔드 실행 후 `/docs`
- 코드 기준: `code/backend/app/main.py`, `code/backend/app/schemas.py`

## 문서화 규칙

- 엔드포인트별 요청/응답 예시 포함
- 상태 코드 및 에러 메시지 표준화
- 변경 시 버전/호환성 영향 기록

## 템플릿

```md
### [METHOD] /path
- 목적:
- 인증:
- Request:
- Response 200:
- Error:
- 비고:
```
