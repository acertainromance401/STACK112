# iOS 앱스토어 승인 후 업데이트 가이드

**작성일**: 2026-05-07  
**목적**: 앱이 승인된 후 코드 수정/기능 추가 시 안전하게 업데이트하는 방법

---

## 📋 빠른 요약

| 작업 | 앱스토어 심사 필요? | 시간 |
|------|------------------|------|
| **내부 코드 리팩토링** | ❌ 불필요 | - |
| **성능 최적화** | ❌ 불필요 | - |
| **백엔드 수정/개선** | ❌ 불필요 | - |
| **버그 수정** | ✅ 필요 | ~24시간 |
| **기능 추가** | ✅ 필요 | ~24-48시간 |
| **UI/UX 개선** | ✅ 필요 | ~24-48시간 |
| **로컬 LLM 모델 교체** | ❌ 불필요 | - |

**핵심**: 사용자 보이지 않는 변경은 심사 불필요. 보이는 변경만 심사 필요 (대부분 통과).

---

## 1️⃣ 업데이트 유형별 프로세스

### Type A: 심사 불필요 (1시간 내 배포)

사용자에게 보이지 않는 변경:

#### A1. 내부 코드 리팩토링

```swift
// OCRView.swift에서 함수 이름 변경
// private func recognizeText() → private func performOCRRecognition()

// 또는 로직 최적화
// if a && b && c { } → if (a && b) && c { }
```

### 배포 방법

```bash
# 1) GitHub에 커밋만 하면 됨
git add code/ios/AISYSApp/Sources/OCRView.swift
git commit -m "refactor: OCR 함수명 개선"
git push origin 임재현

# 2) 앱스토어 심사 필요 ❌
# 3) 사용자에게 영향 없음 ✅
```

#### A2. 백엔드 개선

```python
# ir_pipeline.py에서 검색 알고리즘 개선
# TF-IDF 가중치 조정 등

# database.py에서 쿼리 최적화
# SQL JOIN 개선 등
```

### 배포 방법

```bash
# 1) AWS EC2에 새 코드 배포
cd /home/ubuntu/ai-sys
git pull origin main  # 또는 임재현
docker compose down
docker compose up -d --build

# 2) 앱스토어 심사 필요 ❌
# 3) 사용자는 자동으로 새 백엔드 사용 ✅
```

#### A3. 로컬 LLM 모델 교체

```swift
// LocalLLMEngines.swift에서 모델 파일만 변경
// Llama-3.2-1B → 다른 GGUF 모델로 교체

// 앱 코드는 변경 없음 (로드하는 부분만 변경)
```

### 배포 방법

```bash
# 1) 새 .gguf 파일을 번들에 포함시키고 빌드
# 2) 코드 변경 없음 (파일만 변경)
# 3) 앱스토어 심사 필요 ❌ (이미 "LLM 모델 포함" 명시했으므로)
```

---

### Type B: 심사 필요 (24-48시간 + 심사)

사용자에게 보이는 변경:

#### B1. 버그 수정

### 예시

```swift
// 버그: OCR이 가로 사진을 세로로 인식
// 수정: 이미지 회전 로직 추가

// UIImage 확장에 회전 메서드 추가
extension UIImage {
    func rotatedCorrectly() -> UIImage? {
        // 이미지 방향 자동 감지 및 회전
    }
}
```

### 버전 업데이트

```text
현재: 1.0.0
변경: 1.0.1 (Patch 버전 증가)
```

### 배포 방법

```bash

```bash
# 1) Xcode에서 버전 업데이트
# Project → AISYS → General → Version: 1.0.1

# 2) 변경사항 작성 (App Store Connect)
# Version Release Notes:
#   - OCR 가로/세로 인식 개선
#   - 한글 인식률 향상
#   - 일부 기기 호환성 개선

# 3) Archive 생성
xcodebuild archive \
  -project code/ios/AISYS.xcodeproj \
  -scheme AISYSApp \
  -archivePath ~/Desktop/AISYS.xcarchive

# 4) 앱스토어에 제출
# Xcode → Organizer → xcarchive 선택 → Distribute App → App Store

# 5) Apple 심사 대기 (~24시간)

# 6) 승인 → 자동 배포 → 사용자 자동 업데이트
```

#### B2. 기능 추가

### 예시: 북마크 기능 추가

```swift
// 새 파일: BookmarkView.swift
struct BookmarkView: View {
    @Query var bookmarks: [BookmarkedCase]
    
    var body: some View {
        List {
            ForEach(bookmarks) { bookmark in
                CaseRow(case: bookmark.case)
            }
        }
    }
}

// Models.swift에 추가
@Model
final class BookmarkedCase {
    var caseId: String
    var createdAt: Date
}

// RootTabView.swift에 새 탭 추가
.tabItem {
    Label("Bookmarks", systemImage: "bookmark.fill")
}
```

### 버전 업데이트

```text
현재: 1.0.0
변경: 1.1.0 (Minor 버전 증가, 기능 추가)
```

### 배포 방법

```bash

```bash
# 1) Xcode에서 버전 업데이트
# Project → AISYS → General → Version: 1.1.0

# 2) 변경사항 작성
# Version Release Notes:
#   - 새로운 북마크 기능 추가
#   - 즐겨찾기 판례 저장 및 관리
#   - 빠른 검색 개선

# 3) Archive & 제출
xcodebuild archive -project code/ios/AISYS.xcodeproj \
  -scheme AISYSApp \
  -archivePath ~/Desktop/AISYS.xcarchive

# 4) App Store Connect에 업로드
# Xcode → Organizer → Distribute App

# 5) Apple 심사 대기 (~24-48시간)
# Apple이 새 기능 동작 확인

# 6) 승인 시 배포, 반려 시 수정 후 재심사
```

#### B3. UI/UX 개선

### 예시: 다크 모드 추가

```swift
// 모든 View에서 @Environment(\.colorScheme) 사용
// Light/Dark 모드 대응 색상 정의

.background(Color(UIColor { traitCollection in
    traitCollection.userInterfaceStyle == .dark ?
    UIColor.black : UIColor.white
}))
```

### 버전 업데이트

```text
현재: 1.0.0
변경: 1.1.0 (Minor 버전 증가)
```

**배포 프로세스**: B2와 동일

---

## 2️⃣ 실제 시나리오별 체크리스트

### 시나리오 1: 버그 수정 (OCR 한글 인식 개선)

```
Day 1: 버그 감지 및 수정
  ☐ OCRView.swift 수정
  ☐ 로컬 테스트 (Simulator)
  ☐ 실기기 테스트 (iPhone)
  ☐ Git commit & push
  ☐ 버전 업데이트: 1.0.0 → 1.0.1
  
Day 2: 앱스토어 제출
  ☐ Archive 생성
  ☐ "What's New" 작성: "OCR 한글 인식률 개선"
  ☐ App Store Connect에 업로드
  ☐ 심사 대기
  
Day 3: Apple 심사
  ☐ Apple이 OCR 테스트
  ☐ 승인 또는 반려 결과
  
Day 4 (승인 시):
  ☐ 자동 배포
  ☐ 사용자 자동 업데이트 가능
```

**총 소요 시간**: 2-3일

### 시나리오 2: 백엔드 알고리즘 개선

```
Day 1: 백엔드 수정 및 배포
  ☐ ir_pipeline.py 개선
  ☐ 로컬에서 테스트
  ☐ EC2에 배포 (docker compose up -d --build)
  ☐ Git commit & push
  
Day 2: 모니터링
  ☐ AWS CloudWatch 로그 확인
  ☐ 사용자 피드백 수집
  ☐ 필요시 롤백
  
결과:
  ☐ 앱스토어 심사 필요 ❌
  ☐ 사용자는 자동으로 새 알고리즘 사용 ✅
```

**총 소요 시간**: 1일 (배포 즉시)

### 시나리오 3: 새 기능 추가 (기능 A + 기능 B)

```
Week 1: 기능 개발
  ☐ BookmarkView.swift 작성
  ☐ SearchFilterView.swift 작성
  ☐ Models.swift에 새 모델 추가
  ☐ 로컬 테스트 (2-3일)
  ☐ Git commit & push
  
Week 2: 앱스토어 준비
  ☐ 모든 화면 스크린샷 촬영
  ☐ App Store 설명 업데이트
  ☐ 버전 업데이트: 1.1.0
  ☐ "What's New" 작성:
    - 북마크 기능
    - 고급 검색 필터
    - 성능 개선
  
Week 3: 제출 및 심사
  ☐ Archive 생성
  ☐ App Store Connect 업로드
  ☐ Apple 심사 대기 (24-48시간)
  
Week 4: 배포
  ☐ 승인 또는 반려
  ☐ 승인 시 자동 배포
```

**총 소요 시간**: 3-4주

---

## 3️⃣ 버전 관리 규칙

### Semantic Versioning (권장)

```
MAJOR.MINOR.PATCH

예:
  1.0.0 - 초기 출시
  1.0.1 - 버그 수정
  1.0.2 - 또 다른 버그 수정
  1.1.0 - 새 기능 (북마크)
  1.1.1 - 북마크 기능 버그 수정
  2.0.0 - 대규모 변경 (UI 완전 재설계, 레거시 제거 등)
```

### Xcode에서 버전 수정

```
Project → AISYS → Targets → AISYSApp → General

- Version: 1.0.0
  - MAJOR.MINOR.PATCH

- Build: 1
  - 매번 Archive할 때마다 증가 (자동 또는 수동)
```

---

## 4️⃣ App Store Connect에서 업로드

### Step 1: Archive 생성

```bash
cd code/ios

# 프로젝트 생성 (필요시)
xcodegen generate

# Release 빌드로 Archive
xcodebuild archive \
  -project AISYS.xcodeproj \
  -scheme AISYSApp \
  -archivePath ~/Desktop/AISYS.xcarchive \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

### Step 2: Xcode Organizer에서 제출

```
1. Xcode → Window → Organizer
2. Archives 탭
3. AISYS.xcarchive 선택
4. "Distribute App" 버튼
5. "App Store Connect" 선택
6. 다음 단계 따라서 제출
```

또는 **App Store Connect 웹사이트**에서 직접 업로드:

```
1. https://appstoreconnect.apple.com 접속
2. 앱 선택 → "Prepare for Submission"
3. "Build" 추가
4. 버전 정보 입력
5. "Add for Review" 클릭
```

### Step 3: 심사 대기

```
상태 확인:
App Store Connect → TestFlight → Builds

- Processing: 업로드 처리 중
- Waiting For Review: 심사 대기 중
- In Review: 심사 중
- Approved: 승인됨 ✅
- Rejected: 반려됨 ❌
```

### Step 4: 거절 시 대응

**거절 이유 확인**:

```
App Store Connect → Resolution Center → Communication
```

**일반적인 거절 사유와 해결**:

| 거절 사유 | 해결 방법 |
|----------|---------|
| "앱이 자주 크래시" | 버그 수정 후 재심사 |
| "프라이버시 위반" | Privacy Policy 명확히 작성 |
| "부정확한 설명" | App Store 설명과 기능 일치 |
| "성인 콘텐츠" | 나이 등급 조정 또는 콘텐츠 제거 |
| "법적 문제" | 라이선스 확인 (판례 데이터 저작권) |

**재심사**:

```
1. 거절 사유 해결
2. 버전 업데이트 (1.0.1 → 1.0.2)
3. 다시 Archive & 업로드
4. "Add for Review" 다시 클릭
```

---

## 5️⃣ 승인 후 배포 전략

### 권장: 정기 업데이트 사이클

```
월-수: 내부 리팩토링 & 백엔드 개선 (심사 ❌)
├─ 코드 정리, 성능 최적화
├─ 알고리즘 개선, 버그 수정 (사용자 안 보이는)
└─ GitHub에 커밋만

목-금: 기능 추가 & UI 개선 (심사 필요 ✅)
├─ 새 기능 테스트
├─ Archive 생성 & 제출
└─ Apple 심사 대기

다음주: 심사 결과 대응
├─ 승인 → 배포
└─ 거절 → 수정 후 재심사
```

### 실제 로드맵 예시

```
v1.0.0 (2026-05-15) - 초기 출시
├─ OCR + 로컬 LLM + 퀴즈 생성
└─ 소요: 1개월 개발 + 1주 심사

v1.0.1 (2026-05-25) - 첫 버그 수정
├─ OCR 한글 인식 개선
├─ 소요: 3일 개발 + 1일 심사
└─ 내부 리팩토링 동시 진행

v1.1.0 (2026-06-08) - 첫 기능 추가
├─ 북마크 기능
├─ 검색 필터 개선
└─ 소요: 2주 개발 + 1주 심사

v1.2.0 (2026-07-01) - 대규모 업데이트
├─ 다크 모드
├─ 클라우드 동기화 (선택사항)
├─ 백엔드 검색 알고리즘 개선
└─ 소요: 3주 개발 + 1주 심사

v1.3.0 (2026-08-15) - 지속적 개선
├─ 사용자 피드백 반영
├─ 성능 최적화
└─ 소요: 계속...
```

---

## 6️⃣ 주의사항

### ⚠️ 심사에서 거절될 수 있는 위험한 변경

```swift
// ❌ 위험: 사용자 데이터 몰래 수집
if isConnected {
    uploadUserCaseDataToServer()  // Privacy Policy에 없음
}

// ✅ 안전: 명시된 용도로만 사용
// Privacy Policy에 "동기화를 위해 데이터 전송" 명시
```

```swift
// ❌ 위험: 불법 콘텐츠
// 판례가 저작권 침해 가능성

// ✅ 안전: 공개 판례 데이터만 사용
// "대법원 공개 판례" 명시
```

```swift
// ❌ 위험: 숨겨진 구독/게임
// 앱 설명에는 무료라고 했는데
// 실제로는 구독 강요

// ✅ 안전: 명확한 가격 정책
// "완전 무료" 또는 "구독: $X/월" 명시
```

### ✅ 심사에서 안전한 변경

- 버그 수정 (성능, 안정성)
- 성능 최적화 (CPU, 메모리)
- UI 개선 (다크 모드, 새 레이아웃)
- 기능 추가 (정당한 기능)
- 번역/로컬화
- 문서 업데이트

---

## 7️⃣ AI_SYS 앱의 업데이트 계획 (참고)

### Phase 1: 초기 출시 후 (1개월)

```
v1.0.1 ~ v1.0.3: 버그 수정
  - OCR 정확도 개선
  - LLM 응답 속도 개선
  - UI 반응성 개선

빈도: 주 1회
심사: 각 24시간
```

### Phase 2: 기능 확장 (2-3개월)

```
v1.1.0: 북마크 & 즐겨찾기
v1.2.0: 검색 필터 & 정렬
v1.3.0: 퀴즈 난이도 조정

빈도: 월 1-2회
심사: 각 24-48시간
```

### Phase 3: 고급 기능 (6개월+)

```
v2.0.0: 클라우드 동기화
v2.1.0: 사용자 커뮤니티
v2.2.0: AI 학습 기능

빈도: 월 1회
심사: 각 48시간 (복잡도 증가)
```

---

## 📞 FAQ

### Q: 매주 업데이트해도 되나?

**A**: 기술적으로 가능하지만 비추천.
- Apple은 "장난스러운 업데이트" 거절 가능
- 한 달에 2-3회 정도가 적절
- 충분한 변경사항이 있을 때만 업데이트

### Q: 버그 수정은 어떻게?

**A**: 미시적 버그면 모아서 주기적으로 배포.
- 1-2개 버그: 모아서 v1.0.1
- 3-5개 버그: 모아서 v1.0.2
- 긴급 버그: 즉시 배포 (v1.0.1)

### Q: 백엔드만 수정해도 버전 올려야 하나?

**A**: 아니오. iOS 앱 코드 변경 없으면 버전 유지.
- iOS: v1.0.0 유지
- Backend: ir_pipeline.py 개선
- 사용자: 자동으로 새 알고리즘 사용

### Q: 롤백은?

**A**: App Store에서는 자동 롤백 불가.
- 이전 버전 배포: 새 버전 출시로 대체
- v1.0.1 문제 → v1.0.2 배포로 해결
- 심사: 약 24시간

### Q: 테스트 비용?

**A**: 무료. TestFlight 무제한 테스트 가능.
- Xcode → TestFlight
- 최대 100명 테스터 초대
- 실제 기기에서 테스트

---

## 체크리스트: 업데이트 전 확인

```
코드 변경 전:
  ☐ GitHub 브랜치 확인 (main vs 임재현)
  ☐ 최신 코드 풀 받음 (git pull)
  ☐ Xcode 최신 버전 확인

코드 변경 후:
  ☐ 로컬 Simulator에서 테스트
  ☐ 실기기(iPhone)에서 테스트
  ☐ 부작용 확인 (다른 기능 동작)
  ☐ Git commit & push

앱스토어 제출 전:
  ☐ 버전 번호 업데이트 (Xcode)
  ☐ 변경사항 작성 (한글 또는 영문)
  ☐ 스크린샷 업데이트 (필요시)
  ☐ 설명문 업데이트 (필요시)
  ☐ 나이 등급 확인
  ☐ 가격 정책 확인 (무료)

제출 후:
  ☐ App Store Connect에 업로드 성공 확인
  ☐ 심사 상태 모니터링
  ☐ 심사 완료 알림 확인
  ☐ 배포 상태 모니터링
```

---

**이 가이드를 따르면 안전하고 효율적으로 앱을 지속 개선할 수 있습니다.**
