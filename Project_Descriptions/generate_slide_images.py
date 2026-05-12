from pathlib import Path

out_dir = Path('/Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM/Project_Descriptions')
out_dir.mkdir(parents=True, exist_ok=True)

slides = [
    {
        'filename': 'AI_SYS_Slide_1_Status.png',
        'title': 'AI_SYS 프로젝트 진행 현황 (현재까지 완료)',
        'sections': [
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
        ],
    },
    {
        'filename': 'AI_SYS_Slide_2_Roadmap.png',
        'title': '변경사항 및 앞으로 할 일 (우선순위)',
        'sections': [
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
            '- P1: 데이터 적재/검수 운영 프로세스 정식화',
            '한 줄 결론: 기능 확장보다 안정성·정확도·운영성 우선 고도화 단계',
        ],
    },
]

# Pillow 사용
from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
bg = (246, 248, 252)
panel = (255, 255, 255)
navy = (22, 37, 66)
text = (35, 45, 60)
accent = (39, 111, 191)

font_candidates = [
    '/System/Library/Fonts/AppleSDGothicNeo.ttc',
    '/System/Library/Fonts/Supplemental/AppleGothic.ttf',
]


def load_font(size: int):
    for fp in font_candidates:
        p = Path(fp)
        if p.exists():
            try:
                return ImageFont.truetype(str(p), size=size)
            except Exception:
                pass
    return ImageFont.load_default()


title_font = load_font(56)
body_font = load_font(34)

for slide in slides:
    img = Image.new('RGB', (W, H), color=bg)
    d = ImageDraw.Draw(img)

    d.rectangle([0, 0, W, 18], fill=accent)

    margin = 70
    d.rounded_rectangle(
        [margin, 60, W - margin, H - 60],
        radius=28,
        fill=panel,
        outline=(225, 230, 238),
        width=2,
    )

    x = margin + 50
    y = 110
    d.text((x, y), slide['title'], font=title_font, fill=navy)
    y += 85
    d.line([(x, y), (W - margin - 50, y)], fill=(220, 226, 235), width=3)
    y += 30

    max_width = W - (margin + 50) * 2
    for line in slide['sections']:
        words = line.split(' ')
        current = ''
        wrapped = []
        for w in words:
            candidate = (current + ' ' + w).strip()
            bbox = d.textbbox((0, 0), candidate, font=body_font)
            if bbox[2] - bbox[0] <= max_width:
                current = candidate
            else:
                if current:
                    wrapped.append(current)
                current = w
        if current:
            wrapped.append(current)

        for part in wrapped:
            color = text
            if part.startswith('핵심 구현 완료') or part.startswith('전략 변경 핵심') or part.startswith('성과') or part.startswith('진행 중 주요 변경사항') or part.startswith('현재 리스크') or part.startswith('다음 실행 계획') or part.startswith('한 줄 결론'):
                color = navy
            d.text((x, y), part, font=body_font, fill=color)
            y += 46

        y += 8
        if y > H - 120:
            break

    img.save(out_dir / slide['filename'])

print('done')
for s in slides:
    p = out_dir / s['filename']
    print(str(p), p.exists(), p.stat().st_size if p.exists() else 0)
