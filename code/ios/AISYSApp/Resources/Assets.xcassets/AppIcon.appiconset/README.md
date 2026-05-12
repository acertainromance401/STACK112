# AppIcon — 자리표시자

이 폴더에 **AppIcon-1024.png** (1024×1024, RGB, alpha 채널 없음, sRGB) 한 장만 떨궈
넣으면 됩니다. iOS 17+ 의 single-size AppIcon 슬롯 규격입니다.

준비물:
- 1024 × 1024 PNG
- 알파 채널 없음 (포토샵 저장 시 "Save As → PNG → None")
- 라운드 모서리 적용 금지 (iOS 가 자동으로 마스킹)

투입 후 절차:

1. PNG 를 이 폴더에 떨굼 (`AppIcon-1024.png` 정확한 이름)
2. `project.yml` 에 아래 추가 (이미 안내됨):
   ```yaml
   sources:
     - AISYSApp/Sources
     - AISYSApp/Resources
   ```
3. 또는 Xcode 에서 직접 드래그: `AISYSApp/Resources` 폴더를 Xcode 좌측 네비게이터로
   끌어다 놓고 **"Create folder references"** 가 아닌 **"Create groups"** 선택,
   타깃은 `AISYSApp` 체크
4. 빌드 후 시뮬레이터/실기기에서 홈 화면 아이콘 확인
