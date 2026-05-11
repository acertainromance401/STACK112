# STACK112 — App Store 스크린샷 캡처 가이드

> App Store Connect 필수: **6.7" (iPhone 15 Pro Max 등)** 스크린샷 1세트.
> 권장 추가: **6.5" (iPhone 11 Pro Max 등)** — 자동 리사이즈로 대체 가능하지만
> 직접 캡처하면 더 깔끔.

---

## 1. 필수 사양

| 디바이스 사이즈 | 해상도 (포트레이트) | 비고 |
| --- | --- | --- |
| 6.9" (iPhone 16 Pro Max) | 1320 × 2868 | 권장 |
| 6.7" (iPhone 15 Pro Max) | 1290 × 2796 | **필수** |
| 6.5" (iPhone 11 Pro Max) | 1242 × 2688 | 선택 |
| 5.5" (iPhone 8 Plus) | 1242 × 2208 | 더 이상 필수 아님 |

- 최소 3장, 최대 10장
- **권장: 5장**
- 가로 모드 미지원 (앱 자체가 포트레이트 고정)

---

## 2. 캡처할 5장 (스토리 순서)

### 1번 — 홈 화면 / STACK 게이지
- **메시지**: "공부한 만큼 쌓이는 판례 스택"
- **상태 준비**: 스캔 판례 12~25개 누적해 STACK 게이지 블록이 적당히 차오른 상태
- **캡처 위치**: 앱 최초 진입 (`HomeView` 상단 ~ STACK 카드까지 잡히게)
- **자막 카피**:
  - 한글: **공부 한 켠, 판례를 쌓아두다**
  - 영문: *Stack your case notes, one tap at a time*

### 2번 — OCR 스캔 화면
- **메시지**: "사진 한 장으로 판례 메모 자동 정리"
- **상태 준비**: OCR 결과가 표시된 상태 (텍스트 인식 완료 후 요약 카드)
- **캡처 위치**: OCR 화면, 인식 완료 직후
- **자막 카피**:
  - 한글: **사진 한 장, 판례 메모 한 장**
  - 영문: *Snap a photo, get a case memo*

### 3번 — AI 요약 결과
- **메시지**: "온디바이스 AI 가 요약을 생성"
- **상태 준비**: 판례 하나에 대해 LLM 요약이 표시된 상태
- **캡처 위치**: 사건 상세 → AI 요약 카드
- **자막 카피**:
  - 한글: **온디바이스 AI 요약 — 인터넷 없이도**
  - 영문: *On-device AI summary — even offline*

### 4번 — O/X 퀴즈 / 오답노트
- **메시지**: "틀린 문제는 자동으로 정리"
- **상태 준비**: O/X 퀴즈 화면 또는 오답노트 리스트
- **자막 카피**:
  - 한글: **틀린 건 자동으로 모아둡니다**
  - 영문: *Wrong answers, auto-collected*

### 5번 — 설정 / 데이터 관리 / 면책
- **메시지**: "데이터는 전부 기기 안에서만"
- **상태 준비**: 설정 화면을 스크롤해 "정보" + "데이터 관리" 카드가 보이도록
- **자막 카피**:
  - 한글: **데이터는 당신 기기 안에만**
  - 영문: *Your data stays on your device*

---

## 3. 캡처 절차

### Xcode 시뮬레이터 캡처 (권장)

1. Xcode → Open Developer Tool → Simulator 열기
2. 시뮬레이터에서 **File → Open Simulator → iOS 17.x → iPhone 15 Pro Max** 선택
3. 시뮬레이터 부팅 후 STACK112 빌드를 실행:
   ```bash
   cd code/ios
   xcodebuild -project AISYS.xcodeproj -scheme AISYSApp \
     -configuration Debug \
     -destination 'platform=iOS Simulator,name=iPhone 15 Pro Max' build
   ```
4. 빌드 산출물(.app)을 시뮬레이터로 드래그 또는 `xcrun simctl install booted ...`
5. 화면을 위 5개 시나리오로 준비
6. 시뮬레이터 메뉴 **File → Save Screen** (⌘S) → 자동으로 1290×2796 PNG 저장
7. 저장 위치: `~/Desktop/Simulator Screen Shot - iPhone 15 Pro Max - ...png`

### 실기기 캡처 (대안)

- 실기기에서 전원 + 볼륨업 동시 입력으로 캡처
- 단, 해상도가 1179×2556 (iPhone 15 Pro) 이라 6.7" 슬롯에 그대로 못 올림
- 6.7" 가 필요하면 **반드시 iPhone 15 Pro Max / 16 Pro Max** 또는 시뮬레이터 사용

---

## 4. 자막 / 프레임 (선택)

ASC 는 순수 스크린샷도 받지만, 보통 자막+디바이스 프레임을 합성한 마케팅 컷을 올립니다.

권장 도구:
- **Screenshots.pro** (웹, 무료)
- **Rotato** (macOS 앱)
- **Figma** + `iPhone 15 Pro Max Mockup` 커뮤니티 파일

자막 배경색:
- 다크 모드 컷 → 배경 `#0A1428` (AppColor.background) + 텍스트 `#F5C418` (AppColor.accent)
- 라이트 모드는 만들지 않습니다 (앱 자체가 다크 톤)

---

## 5. 제출 직전 체크

- [ ] 1290 × 2796 PNG 5장 준비
- [ ] 상태바에 시간 9:41 (시뮬레이터 기본값 그대로면 됨)
- [ ] 상태바 배터리 100%, 통신 5G/Wi-Fi 가득
- [ ] 데모 데이터에 실제 사건 당사자 이름 / 주민번호 / 사진 일절 없음 (가상의
      판례 번호와 키워드만 사용)
- [ ] 자막에 "1위", "보장", "합격 보장" 등 과장 표현 없음
- [ ] STACK 게이지에 블록이 약간 채워진 상태 (텅 빈 화면 캡처 금지)

---

## 6. 시뮬레이터 상태바 일괄 변경 (선택)

캡처 직전 단 한 줄로 9:41 / 배터리 100% / 5G 가득으로 통일:

```bash
xcrun simctl status_bar booted override \
  --time "9:41" \
  --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 \
  --wifiMode active --wifiBars 3
```

원복:

```bash
xcrun simctl status_bar booted clear
```
