# Observability (On-device)

## 목적
서버 없는 온디바이스 앱에서 로그/메트릭/대시보드 관측 기준을 정의한다.

## 로그
- 구현: `OSLog` 사용 (`LLMService`)
- 주요 이벤트
  - 모델 로드 성공/실패
  - 엔진 전환(primary -> fallback)
  - 추론 실패/파싱 실패
- 조회 방법
  - Xcode Console
  - macOS `log stream --predicate 'subsystem == "com.acertainromance401.aisys"'`

## 메트릭
- 필수 지표
  - model_load_success_rate
  - first_summary_latency_ms
  - fallback_activation_rate
  - crash_free_sessions
- 수집 소스
  - Xcode Organizer Metrics
  - TestFlight/ASC 지표

## 대시보드
- 최소 대시보드 구성
  - 안정성: crash-free sessions, ANR 유사 지표
  - 성능: cold start, first summary latency
  - 품질: fallback activation rate
- 권장 도구
  - Xcode Organizer
  - App Store Connect Analytics

## 경보 기준(권장)
- fallback_activation_rate > 15% (24h)
- first_summary_latency_ms p95 > 3000ms
- crash_free_sessions < 99.5%

## 운영 루틴
- 릴리스 후 24시간: 4시간 간격 모니터링
- 1주차: 일 1회 점검
- 이상 징후 발생 시 롤백 플랜 즉시 실행
