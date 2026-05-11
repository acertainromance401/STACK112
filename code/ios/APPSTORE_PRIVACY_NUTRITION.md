# App Store Connect — App Privacy 답변지 (STACK112)

> ASC 웹의 **App Privacy** 섹션에서 그대로 따라 체크하면 됩니다.
> 본 앱은 어떤 데이터도 수집·전송하지 않으므로 거의 모든 항목이 "No" 입니다.

---

## 1. Data Collection 첫 질문

> **Do you or your third-party partners collect data from this app?**

→ **No**, we do not collect data from this app.

(이 한 번의 답변만으로 끝납니다. "Yes" 를 누를 경우 아래 카테고리별 상세 질문이
열리지만, STACK112 는 아무것도 수집하지 않으므로 No 로 종료.)

---

## 2. 근거 (왜 "수집하지 않음" 인가)

Apple 의 "Data Collection" 정의:
> Data is "collected" when transmitted off the device and/or stored in a manner that
> is not ephemeral.

STACK112 는:

| 항목 | off-device 전송 | 영구 저장 위치 | 수집 여부 |
| --- | --- | --- | --- |
| 사진 (OCR 입력) | ❌ 없음 | 사용자 기기 SwiftData | 수집 아님 (기기 내부) |
| OCR 텍스트 | ❌ 없음 | 사용자 기기 SwiftData | 수집 아님 |
| 학습 기록 | ❌ 없음 | 사용자 기기 SwiftData | 수집 아님 |
| LLM 생성 결과 | ❌ 없음 | 메모리 (휘발성) | 수집 아님 |
| 광고 식별자 | ❌ 사용 안 함 | — | — |
| 분석/크래시 | ❌ SDK 없음 | — | — |

번들된 LLM(Llama 3.2 1B) 은 **온디바이스**에서 실행되며, 어떤 API 호출도 외부로
나가지 않습니다.

---

## 3. 만약 ASC 가 자동 감지 경고를 띄울 경우

ASC 가 "이 앱이 IDFA 를 사용하는 것 같습니다" 등의 경고를 자동으로 띄울 수 있습니다.
원인:
- 광고 프레임워크 미사용에도 시스템 라이브러리에 흔적이 남는 경우

해결:
1. **Tracking → Does this app use the Advertising Identifier (IDFA)?** → **No**
2. 빌드에 `AdSupport.framework` 가 링크되어 있지 않은지 확인 (STACK112 는 링크 없음)

---

## 4. Export Compliance (별도 항목)

> **Does your app use encryption?**

→ **Yes, but exempt** 를 선택.

근거: 본 앱은 iOS 표준 HTTPS / TLS 만 사용 (그것마저 현재는 네트워크 호출이 없음).
ITSAppUsesNonExemptEncryption 키를 Info.plist 에 `NO` 로 박아두면 매 빌드마다
ASC 가 묻지 않습니다.

→ `project.yml` 에 추가 권장 (현재 아직 미적용):

```yaml
INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
```

---

## 5. Content Rights

> **Does your app contain, show, or access third-party content?**

→ **Yes**.

근거: 사용자가 직접 선택한 이미지(판례 PDF/스크린샷 등)를 OCR 로 처리. 다만 본 앱은
사용자 본인이 합법적으로 보유한 자료를 처리하는 것을 전제로 하며, 콘텐츠 자체를
앱이 배포하지 않습니다.

ASC 후속 질문:
- **Do you have all necessary rights to that content...?** → **Yes** (사용자 책임 모델)

---

## 6. Age Rating

| 카테고리 | 빈도 |
| --- | --- |
| Cartoon/Fantasy Violence | None |
| Realistic Violence | None |
| Sexual Content / Nudity | None |
| Profanity | None |
| Alcohol/Tobacco/Drugs | None |
| Mature/Suggestive Themes | None |
| Horror/Fear Themes | None |
| Medical/Treatment Info | None |
| Gambling | None |
| Unrestricted Web Access | **No** |
| User Generated Content | **No** (사용자가 만든 메모는 본인 기기에만 저장됨, 외부 공유 기능 없음) |

→ 결과 등급: **4+**

---

## 7. 체크리스트

ASC 제출 직전 확인:

- [ ] App Privacy → **No data collected**
- [ ] IDFA → **No**
- [ ] Encryption → **Exempt**
- [ ] Content Rights → **Yes, all necessary rights**
- [ ] Age Rating → 4+
- [ ] Privacy Policy URL 등록 (PRIVACY_POLICY.md 를 GitHub Pages 등에 배포한 URL)
- [ ] App Tracking Transparency (ATT) 프롬프트 → **표시하지 않음** (추적 안 하므로)
