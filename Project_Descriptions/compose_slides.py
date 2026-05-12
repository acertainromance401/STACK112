from pathlib import Path
from PIL import Image, ImageFont, ImageDraw

base = Path('/Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM/Project_Descriptions')

W, H = 1920, 1080
bg     = (246, 248, 252)
panel  = (255, 255, 255)
navy   = (22,  37,  66)
text_c = (35,  45,  60)
accent = (39, 111, 191)

font_candidates = [
    '/System/Library/Fonts/AppleSDGothicNeo.ttc',
    '/System/Library/Fonts/Supplemental/AppleGothic.ttf',
]

def load_font(size):
    for fp in font_candidates:
        p = Path(fp)
        if p.exists():
            try:
                return ImageFont.truetype(str(fp), size=size)
            except Exception:
                pass
    return ImageFont.load_default()

title_font = load_font(50)
body_font  = load_font(30)

# 오른쪽에 폰 2개 나란히 배치할 영역
PHONE_AREA_X  = 960   # 폰 영역 시작 x (슬라이드 절반)
PHONE_AREA_W  = 900   # 두 폰 합친 폭
PHONE_GAP     = 24
PHONE_W       = (PHONE_AREA_W - PHONE_GAP) // 2   # 438
PHONE_H       = int(PHONE_W * (2622 / 1206))       # 952
PHONE_Y       = (H - PHONE_H) // 2                 # 64

def paste_phone(canvas, img_path, x):
    ph = Image.open(img_path).convert('RGBA')
    ph = ph.resize((PHONE_W, PHONE_H), Image.LANCZOS)

    # 둥근 모서리 마스크
    mask = Image.new('L', (PHONE_W, PHONE_H), 0)
    md   = ImageDraw.Draw(mask)
    r    = 40
    md.rounded_rectangle([0, 0, PHONE_W, PHONE_H], radius=r, fill=255)

    ph_rgb = Image.new('RGB', (PHONE_W, PHONE_H), (255, 255, 255))
    ph_rgb.paste(ph.convert('RGB'), mask=mask)

    canvas.paste(ph_rgb, (x, PHONE_Y))

    # 테두리
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle(
        [x, PHONE_Y, x + PHONE_W, PHONE_Y + PHONE_H],
        radius=40, outline=(200, 210, 220), width=3
    )

# 텍스트 영역 폭 (왼쪽 절반 + 여유)
TEXT_PANEL_W = PHONE_AREA_X - 40

def draw_slide(out_path, title, sections):
    img = Image.new('RGB', (W, H), color=bg)
    d   = ImageDraw.Draw(img)

    # 상단 파란 바
    d.rectangle([0, 0, W, 18], fill=accent)

    # 텍스트 패널 (왼쪽)
    margin = 50
    d.rounded_rectangle(
        [margin, 55, TEXT_PANEL_W, H - 55],
        radius=24, fill=panel, outline=(225, 230, 238), width=2
    )

    # 제목
    x, y = margin + 40, 100
    d.text((x, y), title, font=title_font, fill=navy)
    y += 72
    d.line([(x, y), (TEXT_PANEL_W - 30, y)], fill=(220, 226, 235), width=2)
    y += 26

    max_w = TEXT_PANEL_W - margin - 40 - 30

    for line in sections:
        words   = line.split(' ')
        current = ''
        wrapped = []
        for w in words:
            candidate = (current + ' ' + w).strip()
            bbox = d.textbbox((0, 0), candidate, font=body_font)
            if bbox[2] - bbox[0] <= max_w:
                current = candidate
            else:
                if current:
                    wrapped.append(current)
                current = w
        if current:
            wrapped.append(current)

        for part in wrapped:
            is_header = any(part.startswith(k) for k in [
                '핵심 구현 완료', '전략 변경 핵심', '성과',
                '진행 중 주요 변경사항', '현재 리스크', '다음 실행 계획', '한 줄 결론'
            ])
            color = navy if is_header else text_c
            d.text((x, y), part, font=body_font, fill=color)
            y += 40
        y += 6
        if y > H - 90:
            break

    return img

# ── Slide 1 ──────────────────────────────────────────────────────────────
s1 = draw_slide(
    base / 'AI_SYS_Slide_1_Status.png',
    'AI_SYS 프로젝트 진행 현황 (현재까지 완료)',
    [
        '프로젝트명: AI_SYS (경찰 공무원 시험 판례 학습 플랫폼)',
        '현재 단계: 동작 가능한 베타 완성 (앱-서버-DB-로컬 LLM 연동 완료)',
        '핵심 구현 완료',
        '- iOS 5탭: Home / OCR / Search / Review / My Page',
        '- OCR 인식 결과 자동 검색 연결 (스캔 -> 검색 -> 요약)',
        '- FastAPI API 구현 (health, search, case detail, dashboard)',
        '- PostgreSQL 시드 확장 + 앱 더미 데이터 DB 이관',
        '- 대시보드 추천/오답 API 연동',
        '전략 변경 핵심',
        '- 서버형 LLM 검토에서 로컬 LLM 우선 전략으로 전환',
        '- 이유: 오프라인 대응, 데이터 외부 전송 최소화, 지연/비용 리스크 완화',
        '- 안정화: 앱 선로딩 + ready 대기 + 실패 시 fallback',
        '성과',
        '- 핵심 사용자 경로 E2E 동작 가능, 발표 가능한 통합 상태 확보',
    ]
)
# 오른쪽에 폰 2개: Review, 판례요약
px1 = PHONE_AREA_X + 20
px2 = px1 + PHONE_W + PHONE_GAP
paste_phone(s1, base / 'Simulator Screenshot - iPhone 17 - 2026-04-24 at 12.33.51.png', px1)
paste_phone(s1, base / 'Simulator Screenshot - iPhone 17 - 2026-04-24 at 12.33.56.png', px2)
s1.save(base / 'AI_SYS_Slide_1_Status.png')
print('Slide 1 saved')

# ── Slide 2 ──────────────────────────────────────────────────────────────
s2 = draw_slide(
    base / 'AI_SYS_Slide_2_Roadmap.png',
    '변경사항 및 앞으로 할 일 (우선순위)',
    [
        '진행 중 주요 변경사항',
        '- 운영 이슈 해결: compose 혼선 정리, 404 원인 제거',
        '- 데이터 전환: 앱 더미 중심 -> DB 중심 조회 구조',
        '- LLM 운영 전환: 서버 중심 검토 -> 로컬 추론 우선',
        '- UX 일관화: 공통 뒤로가기/오류 폴백 패턴 적용',
        '현재 리스크',
        '- LLM 출력 파싱 실패 가능성',
        '- 추천/검색 정확도 고도화 필요',
        '- 자동 테스트 부족으로 회귀 위험 존재',
        '다음 실행 계획 (P0 -> P1)',
        '- P0: 실기기 E2E 안정화 (크래시 0, 핵심 경로 성공률 관리)',
        '- P0: LLM 파싱 안정화 (포맷 고정, 파서 보강, 실패 로그 수집)',
        '- P0: 추천/검색 1차 품질 개선 (오답 가중치, 쿼리 정규화)',
        '- P1: 백엔드/iOS 자동 테스트 기본 세트 구축',
        '한 줄 결론: 기능 확장보다 안정성·정확도·운영성 우선 고도화 단계',
    ]
)
# 오른쪽에 폰 2개: OCR, Home 대시보드
paste_phone(s2, base / 'Simulator Screenshot - iPhone 17 - 2026-04-24 at 12.34.10.png', px1)
paste_phone(s2, base / 'Simulator Screenshot - iPhone 17 - 2026-04-24 at 12.34.16.png', px2)
s2.save(base / 'AI_SYS_Slide_2_Roadmap.png')
print('Slide 2 saved')
print('Done')
