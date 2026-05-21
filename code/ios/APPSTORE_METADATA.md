# STACK112 — App Store 등록 메타데이터

> App Store Connect 에 등록할 때 그대로 복사해 쓰는 카피 모음.
> 코드 안에는 들어가지 않고, 심사 제출 시점에만 사용.

## 표시명 (Display Name, 30자 이하)
**STACK112**

## 현재 제출 상태
- 제출일: **2026-05-14**
- App Review 상태: **심사 제출 완료**
- 제출 빌드: **1.0.0 (2)**
- 공개 저장소에는 App Review 전용 전화번호/사적 메모를 남기지 않음

## App Store Connect 입력값
- 지원 URL: **https://acertainromance401.github.io/stack112-privacy/**
- 개인정보 처리방침 URL: **https://acertainromance401.github.io/stack112-privacy/**
- 마케팅 URL: 비워도 무방 (선택값)
- 버전: **1.0.0**
- 저작권: **2026 JaeHyun Lim**
- 라우팅 앱 적용 범위 파일: 해당 없음 (비움)
- 앱 클립: 해당 없음

## 콘텐츠 권한
- 콘텐츠 권한 정보 설정: **예 (Yes)**
- 후속 질문이 나오면: **필요한 권리를 모두 보유하고 있음 (Yes)**
- 이유 1: 사용자가 직접 선택한 판례 이미지/PDF/스크린샷을 앱이 OCR 대상으로 읽음
- 이유 2: 앱이 Meta의 **Llama 3.2 Community License** 기반 모델과 llama.cpp 계열 런타임을 사용함
- 정리: 이 항목은 "Meta 모델을 써서 무조건 예"라기보다, **앱이 제3자 콘텐츠에 접근하거나 포함하는지**를 묻는 항목이라 현재 앱은 예로 답하는 편이 안전함

## 앱 심사 정보 입력값
- 로그인 필요: **아니오** (체크 해제)
- 연락처 이름: **임재현**
- 연락처 전화번호: **ASC에 직접 입력 (국제 형식 권장, 공개 저장소 비기록)**
- 연락처 이메일: **지원용 이메일 1개로 통일 권장**
- 첨부 파일: 없음 (선택사항)

## 거절 대응 템플릿 (Guideline 2.3.1(a), 3.2.1(viii))

아래 문구를 Resolution Center 에 그대로 사용 가능.

```text
Hello App Review Team,

Thank you for the review and feedback.

For Guideline 2.3.1(a):
- We removed internal/developer-only UI paths from the shipping target.
- The app now exposes only user-facing study features described in metadata.
- We confirmed there are no hidden switches, server override inputs, or undocumented entry points in the submitted build.

For Guideline 3.2.1(viii):
- This app does not provide financial services, banking, payments, lending, investment, or account management.
- The app is an education tool for case-law study (OCR notes, AI summary, quiz, and review) and performs on-device processing only.
- No financial transactions or financial institution integrations are included.

If the app was classified as a financial-services app by mistake, we respectfully request re-evaluation under the Education category context.

Thank you.
```

만약 Apple 이 금융 서비스 분류를 유지하면, 개인 계정으로는 해결이 불가하므로 조직(Organization) 계정으로 전환 또는 조직 계정으로 앱 이전이 필요.

### 앱 심사 메모 (Review Notes)
```text
This app does not require login or account creation.

Core learning features work on-device. Users may optionally grant Photo Library access to select an image for OCR.

No user data is transmitted to external servers. The app focuses on case-law scanning, AI summary, OX quiz review, wrong-answer notes, and study analytics.

For review:
1. Open the app.
2. Optionally import an image from the photo library for OCR.
3. Check summary cards, OX quiz, wrong-answer notes, and analysis screens.

If you need assistance during review, please contact the review contact listed in App Review Information.
```

## 서브타이틀 (Subtitle, 30자 이하)
**공부 한 켠에 쌓는 경찰 수험 판례 메모**

## 프로모션 텍스트 (170자)
**판례 사진 한 장으로 요약, 핵심 쟁점 정리, OX 퀴즈 복습까지. 온디바이스 AI로 가볍게 정리하고 빠르게 복습하세요.**

## 설명 (Description)
**STACK112는 경찰 수험생이 판례를 더 가볍게 정리하고, 더 짧게 복습할 수 있도록 돕는 학습 보조 앱입니다.**

책으로 공부하다가 중요한 판례를 만나면 사진 한 장으로 남겨두세요. STACK112는 스캔한 판례를 AI로 요약하고, 핵심 쟁점, 판결 결론, 시험 포인트를 한눈에 정리해 줍니다. 흩어지기 쉬운 판례 메모를 한 곳에 모아두고, 필요한 순간마다 다시 꺼내 볼 수 있습니다.

핵심 학습 기능은 온디바이스 AI를 중심으로 동작해, 네트워크 연결이 어려운 상황에서도 판례 정리와 복습을 이어가기 좋습니다. 스캔한 내용은 기기 안에서 빠르게 정리되어 이동 중에도 부담 없이 활용할 수 있습니다.

정리에서 끝나지 않습니다. OX 퀴즈로 빠르게 확인하고, 오답노트와 AI 분석으로 자주 틀리는 포인트를 반복 복습할 수 있습니다. 공부의 흐름은 끊지 않고, 복습은 더 가볍게 이어가도록 설계했습니다.

주요 기능
- 판례 스캔 및 저장
- AI 요약, 핵심 쟁점, 판결 결론, 시험 포인트 정리
- OX 퀴즈 기반 빠른 확인 학습
- 오답노트와 AI 분석으로 약점 복습
- 수험 판례를 한 곳에 쌓아두는 학습 메모

메인은 책으로 공부하고, STACK112는 옆에서 기록과 복습을 돕습니다. 부담 없이 켜고, 틈틈이 쌓아두는 경찰 수험 판례 메모 앱입니다.

## 공식 슬로건 (홈 헤더 · 마케팅 카피)
**공부는 당신이, 기록은 우리가.**

## 짧은 한 줄 설명 (Promotional Text 후보)
- 메인은 책, 옆자리는 STACK112.
- 판례 사진 한 장을 온디바이스 AI로 가볍게 정리하세요.
- 부담 없이 켜고, 한 켠에 쌓아두세요.
- 스캔부터 OX 복습까지, 판례 공부를 더 짧고 가볍게.

## 키워드 (콤마 구분, 100자)
경찰공무원,경찰공채,경찰간부,오답노트,문제풀이,온디바이스,오프라인,AI요약,스캔,암기,복습

## 카테고리
- 1차: 교육 (Education)
- 2차: 생산성 (Productivity)

## 연령 등급
4+

## 출시 옵션 권장
- 첫 출시라면 **수동으로 버전 출시** 권장
- 이유: 심사 통과 직후 바로 공개되지 않고, App Store 페이지를 마지막으로 점검한 뒤 직접 출시 가능
- 자동으로 버전 출시는 지금 당장 공개되어도 괜찮을 때만 선택

## 심사 제출 체크리스트
- iPhone 스크린샷 업로드 완료 (6.5 또는 6.7 규격)
- 프로모션 텍스트, 설명, 키워드, 서브타이틀 입력 완료
- 앱 심사 정보의 연락처, 이메일, 전화번호 입력 완료
- 개인정보 처리방침 URL 및 지원 URL 입력 완료
- 앱 개인정보 수집 항목 / 추적 여부 설정 확인 완료
- 가격 및 배포 가능 지역 설정 완료
- 심사용 빌드 선택 완료 (현재 빌드 1.0.0 (2))
- Export Compliance 질문 응답 완료
- 저장 후 심사에 추가 버튼으로 제출 진행 또는 심사 중 보완

## 톤 가이드
- "메인 도구가 아니라 보조 메모장" 이라는 입장을 일관되게 유지
- "합격을 보장" "AI가 모든 걸 해결" 류 과장 금지
- 사용자 부담을 낮추는 어휘: 가볍게 / 한 켠에 / 부담 없이 / 틈틈이 / 짧게
