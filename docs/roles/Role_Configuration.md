# AI_SYS 역할 구성 (Role Configuration)

AI_SYS 프로젝트는 다음 4가지 핵심 역할로 구성됩니다.

---

## 1. 백엔드 (Backend)

### 책임사항
- REST API 설계 및 구현
- 비즈니스 로직 개발
- 데이터베이스 상호작용 및 쿼리 최적화
- 시스템 인프라 및 배포 관리
- 보안 및 인증 처리

### 주요 기술 스택
- **언어**: Python
- **프레임워크**: FastAPI
- **데이터베이스**: PostgreSQL
- **배포**: Docker
- **문서**: `code/backend/README.md`

### 주요 파일
- `code/backend/app/main.py` - API 엔드포인트
- `code/backend/app/database.py` - DB 연결 관리
- `code/backend/requirements.txt` - 의존성 패키지

### 산출물
- API 스펙 문서
- 백엔드 코드
- 배포 가이드

### 상호작용
- **프론트엔드**: REST API 제공
- **AI 모델 설계**: 모델 추론 요청 처리
- **데이터 관리**: DB 스키마 구현 및 쿼리 실행

---

## 2. 프론트엔드 (Frontend)

### 책임사항
- 사용자 인터페이스 설계 및 구현
- 사용자 경험(UX) 개선
- 로컬 LLM 통합 (오프라인 기능)
- 이미지 인식(OCR) 기능 구현
- 백엔드 API 통신

### 주요 기술 스택
- **플랫폼**: iOS
- **언어**: Swift
- **로컬 LLM**: LlamaSwift + 외부 GGUF(`Documents/models`, 저장소 미포함)
- **문서**: `code/ios/README.md`

### 주요 파일
- `code/ios/AISYSApp/Sources/AISYSApp.swift` - 앱 진입점
- `code/ios/AISYSApp/Sources/LLMService.swift` - 로컬 LLM 통합
- `code/ios/AISYSApp/Sources/OCRView.swift` - 이미지 처리
- `code/ios/AISYSApp/Sources/NetworkService.swift` - 백엔드 통신

### 산출물
- iOS 앱 빌드
- UI/UX 가이드
- 사용자 문서

### 상호작용
- **백엔드**: API를 통한 데이터 조회/전송
- **AI 모델 설계**: 로컬 모델 추론 결과 표시
- **데이터 관리**: 로컬 캐시 및 데이터 저장

---

## 3. AI 모델 설계 (AI Model Design)

### 책임사항
- 정보 검색 모델(Information Retrieval) 개발
- 프롬프트 엔지니어링 및 템플릿 작성
- LLM 통합 및 최적화
- 모델 성능 평가 및 개선
- 로컬 모델과 서버 모델 조율

### 주요 기술 스택
- **로컬 모델**: GGUF(기기 외부 배치)
- **프롬프트 엔지니어링**: 템플릿 기반 설계
- **정보검색**: 정책 및 판례 검색 최적화

### 주요 파일
- `code/stitch_prompts_ai_sys.txt` - 프롬프트 템플릿
- `code/backend/app/grounding.py` - 모델 기반 응답 생성
- `code/ios/AISYSApp/Sources/PromptTemplates.swift` - iOS 프롬프트

### 산출물
- 프롬프트 라이브러리
- 모델 성능 평가 보고서
- 정보검색 알고리즘

### 상호작용
- **백엔드**: 모델 추론 요청 처리
- **프론트엔드**: 사용자 입력에 따른 프롬프트 최적화
- **데이터 관리**: 정책 및 판례 데이터 활용

---

## 4. 데이터 관리 (Data Management)

### 책임사항
- 데이터베이스 설계 및 스키마 관리
- 정책(Policy) 및 판례(Case) 데이터 관리
- 데이터 표준화 및 정규화
- 데이터 무결성 및 백업 관리
- 데이터 품질 모니터링

### 주요 기술 스택
- **데이터베이스**: PostgreSQL
- **데이터 형식**: 구조화된 메타데이터
- **저장소**: `data/` 폴더

### 주요 파일
- `db/schema.sql` - DB 스키마 정의
- `data/raw/` - 원본 데이터
- `data/normalized/` - 정규화된 데이터
- `data/reviewed/` - 검수된 데이터

### 산출물
- DB 스키마 문서
- 데이터 정규화 가이드
- 데이터 품질 보고서

### 상호작용
- **백엔드**: 데이터 쿼리 및 저장
- **프론트엔드**: 데이터 캐시 제공
- **AI 모델 설계**: 학습 및 추론용 데이터 제공

---

## 역할 간 의존성 및 워크플로우

```
┌─────────────┐
│   데이터    │ ← 정책/판례 원본 데이터
│   관리      │
└──────┬──────┘
       │
       ├──→ ┌───────────────┐
       │    │  AI 모델      │ ← 프롬프트 및 정보검색
       │    │  설계         │
       │    └───────┬───────┘
       │            │
       ├──→ ┌──────┴───────┐
       │    │  백엔드       │ ← REST API 제공
       │    │  (데이터 쿼리)│
       │    └────────┬──────┘
       │             │
       └──→ ┌────────┴──────┐
            │  프론트엔드    │ ← 최종 사용자 인터페이스
            │  (iOS 앱)     │
            └────────────────┘
```

---

## 담당자 및 연락처

(프로젝트별로 업데이트 필요)

| 역할 | 담당자 | 연락처 |
|------|--------|--------|
| 백엔드 | - | - |
| 프론트엔드 | - | - |
| AI 모델 설계 | - | - |
| 데이터 관리 | - | - |

---

## 개발 환경 세팅

각 역할별 개발 환경 설정은 다음 문서를 참고하세요:
- 백엔드: `code/backend/README.md`
- 프론트엔드: `code/ios/README.md`
- 데이터 관리: `data/README.md`
- 전체 실행 가이드: `code/Run_Guide_AI_SYS.md`

---

**마지막 업데이트**: 2026-04-28
