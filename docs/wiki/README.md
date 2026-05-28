# Wiki Bundle Guide

GitHub Wiki에 업로드할 페이지를 리포 내부에서 관리하기 위한 번들입니다.

## 구조

- `docs/wiki/pages/`: Wiki로 게시할 마크다운 원본
- `scripts/wiki/build_wiki_bundle.sh`: Wiki 업로드용 번들 생성 스크립트
- `docs/wiki/wiki-bundle/`: 생성 결과물(스크립트 실행 후 생성)

## 사용 방법

```bash
bash scripts/wiki/build_wiki_bundle.sh
```

실행 후 `docs/wiki/wiki-bundle/` 아래 파일들을 GitHub Wiki에 업로드하면 됩니다.

## 권장 페이지

- Home.md
- Getting-Started.md
- Architecture.md
- API-Guide.md
- Troubleshooting.md
- ADR-Index.md
- RFC-Index.md
