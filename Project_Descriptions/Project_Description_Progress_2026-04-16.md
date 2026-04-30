# AI_SYS 진행상황 상세 보고서

작성일: 2026-04-16
최종 업데이트: 2026-04-17
문서 버전: v1.1

## 1. 목적
이 문서는 현재 저장소 기준 구현 진행 상태를 코드/DB/API/앱 연동 관점에서 상세히 기록한다.
특히 다음 항목의 완료 여부를 명확히 한다.
- iOS 앱 <-> 백엔드 API <-> PostgreSQL 연결 상태
- Swift 더미 데이터의 DB 이관 여부
- llama.cpp 기반 로컬 LLM 추론 엔진 구현 상태
- OCR 및 화면 UX(소형 뒤로가기 포함) 구현 상태
- 실기기(iPhone) 테스트 준비 상태

## 2. 현재 아키텍처 상태

앱 (SwiftUI)
-> API 서버 (FastAPI)
-> DB (PostgreSQL)
-> 로컬 LLM (llama.cpp via LlamaSwift)

보조 흐름:
- OCR(Vision) 입력 -> 검색 탭 쿼리 전달 -> /search API 조회
- Home 대시보드 -> /dashboard/recommended, /dashboard/wrong-answers 조회

## 3. 백엔드 진행 상태

### 3-1. 기존 구현 확인
- /health
- /search
- /cases/{case_number}
- /cases

### 3-2. 신규 구현
대시보드 API 추가:
- GET /dashboard/recommended
  - published_cases 기반 추천 복습 카드 반환
  - case_number, case_name, subject, issue, accuracy 필드 제공
- GET /dashboard/wrong-answers
  - user_case_history + cases 조인 기반 오답 목록 반환
  - title, memo, date 필드 제공

### 3-3. 스키마 확장
pydantic 응답 모델 신규 추가:
- RecommendedCaseItem
- WrongAnswerListItem
- RecommendedCasesResponse
- WrongAnswersResponse

## 4. DB(더미 데이터 이관) 진행 상태

### 4-1. 기존 상태
- 초기 데이터는 제한된 건수로 운영되었다.

### 4-2. 신규 이관
Swift 앱 데이터 흐름을 DB 중심 구조로 정리했다.
추가 case_number 목록:
- 2021도16503
- 2022도12345
- 2021도1234
- 2020도4521
- 2018도19876
- 2023도16220
- 2021도20457
- 2017도18543

또한 오답노트 데이터를 user_case_history 기반으로 정리했다.

결과적으로 앱 더미 데이터와 DB 데이터의 정합성이 크게 개선되었고,
백엔드 연결 시 앱이 실제 DB 기반 데이터로 동작한다.

## 5. iOS 앱 진행 상태

### 5-1. NetworkService 확장
- API_BASE_URL 오버라이드 지원 (UserDefaults)
- 현재 baseURL 확인 함수 추가
- 추천/오답 대시보드 API 호출 함수 추가

### 5-2. 모델/스토어 확장
- APIRecommendedCase, APIWrongAnswerItem 추가
- ReviewStore.applyRemoteDashboard() 추가
- Home 대시보드가 원격 데이터로 갱신 가능

### 5-3. Home 화면
- 백엔드 연결 시 추천 복습/오답 노트를 DB 기반으로 로드
- 현재 연결 중인 API 주소 표시
- 실패 시 로컬 더미 폴백 메시지 표시

### 5-4. OCR
- PhotosPicker + Vision OCR 구현
- 인식 텍스트를 검색 쿼리로 전달
- OCR 탭에서 Search 탭으로 자동 이동

### 5-5. 네비게이션 UX
- 주요 상세 뷰에 소형 뒤로가기 버튼 적용

## 6. 로컬 LLM(llama.cpp) 진행 상태

### 6-1. 패키지 연결
- LlamaSwift 패키지 연결 완료
- canImport(LlamaSwift) 경로에서 컴파일됨

### 6-2. 엔진 구현
LlamaCppEngine에서 다음이 구현됨:
- GGUF 모델 로드
- llama context 생성
- sampler chain(top-k/top-p/temp/dist) 구성
- prompt 토크나이즈
- decode + sample 루프 기반 생성
- token piece 디코딩

### 6-3. 현재 제한
- 모델/프롬프트/샘플링 파라미터 튜닝은 추가 작업 필요
- iOS 16.0 타겟에서 llama 프레임워크가 16.4로 빌드된 경고가 있음(빌드 자체는 성공)

## 7. 실기기 테스트 준비 상태

### 7-1. API 연결
- 앱 내 MyPage에서 API 서버 주소를 직접 저장 가능
- 예: http://192.168.x.x:8000
- 저장 시 API_BASE_URL 오버라이드가 즉시 반영됨

### 7-2. 모델 파일
- 앱은 Documents/models 경로에서 GGUF 탐색
- 권장 파일명:
  Llama-3.2-1B-Instruct-Q4_K_M.gguf

### 7-3. iPhone 테스트 체크포인트
- Home 대시보드가 DB 데이터로 바뀌는지
- OCR 결과가 Search로 전달되는지
- CaseSummary 진입 시 로컬 LLM 생성 경로가 동작하는지
- 오프라인/백그라운드 복귀 시 안정성

## 8. CoreML vs llama.cpp 판단

현재 결론:
- 단기: llama.cpp 유지가 가장 현실적
  - 이미 GGUF 자산과 엔진 코드가 연결됨
  - 온디바이스 추론 경로 완성도가 더 높음
- 중장기: CoreML 병행 검토
  - 분류/랭킹/태깅 같은 경량 태스크부터 CoreML 전환
  - 생성형 전체를 CoreML로 옮기려면 모델 변환/품질/메모리 검증 비용이 큼

권장 전략:
1) 지금은 llama.cpp 기반 기능 완성
2) 성능 병목 구간만 CoreML 보조 모델 도입

## 9. 남은 주요 작업
- 실기기에서 API_BASE_URL 저장 후 실제 Mac API 통신 E2E 확인
- LLM 출력 포맷 안정화(LLMSummary 파싱 실패율 감소)
- 대시보드 추천 정확도 로직 고도화(현재는 단순 점수식)
- 에러/로딩 상태 UX 세부 개선

## 10. 결론
요청한 핵심 범위(앱-API-DB-LLM 연결, 더미 데이터 이관, OCR 연결, 실기기 준비)는 코드 기준으로 대부분 완료되었다.
현재 단계는 기능 완성 1차를 통과했으며, 실기기 E2E 검증 및 성능 튜닝이 다음 단계의 중심 과제다.

## 11. 2026-04-17 추가 반영 사항

### 11-1. 백엔드/DB 운영 이슈 해결
- 증상: Home 대시보드에서 /dashboard/recommended 호출 시 404 발생
- 원인: 잘못된 compose 프로젝트(ai_sys) 인스턴스가 8000 포트를 점유
- 조치:
  - 기존 ai_sys 스택 down
  - AI_SYS_TEAM 기준 스택 재기동
  - DB init 실패("Resource deadlock avoided")는 볼륨 초기화 + 경로 재검증 후 정상화
- 검증:
  - /health 200
  - /dashboard/recommended 200 확인

### 11-2. LLM 준비 상태 개선
- 증상: 상세 화면에서 "LLM 엔진이 준비되지 않았습니다." 메시지 발생
- 조치:
  - 앱 시작 시 LLM 선로딩
  - 요약/퀴즈 실행 전 ready 상태 대기 로직 추가
- 효과:
  - 초기 진입 시 not-ready 발생 빈도 완화

### 11-3. 내비게이션 UX 정리
- 요청 반영: 주요 화면 전체에 공통 뒤로가기 버튼 적용
- 적용 대상:
  - Home, OCR, Search, Review, My Page
  - 상세/퀴즈/오답 저장 화면
