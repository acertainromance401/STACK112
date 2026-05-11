# AI_SYS Backend Quickstart

최종 업데이트: 2026-05-07
현재 상태: 백엔드 컨테이너 실행 및 `/health` 검증 통과

## 1) 가상환경 및 의존성 설치
```bash
cd backend
/opt/homebrew/bin/python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 2) DB 스키마 적용
```bash
cd ..
brew services start postgresql@17
/opt/homebrew/opt/postgresql@17/bin/createdb aisys
/opt/homebrew/opt/postgresql@17/bin/psql -d aisys -f code/db/schema.sql
```

## 3) 실행
```bash
cd backend
export DATABASE_URL=postgresql://localhost:5432/aisys
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

## 4) 확인
- Health: http://127.0.0.1:8000/health
- Docs: http://127.0.0.1:8000/docs
- Case 조회 예시: http://127.0.0.1:8000/cases/2019도12345
- 검색 예시: http://127.0.0.1:8000/search?q=위법수집증거

## 5) Docker Compose 실행 (권장)
```bash
cd ..
docker compose up -d --build
```

### 로그 확인
```bash
docker compose logs -f api
docker compose logs -f db
```

### 종료
```bash
docker compose down
```

### 데이터까지 초기화
```bash
docker compose down -v
```

## 6) Docker Compose 기준 접속 정보
- API: http://127.0.0.1:8000
- Docs: http://127.0.0.1:8000/docs
- DB: postgresql://postgres:postgres@127.0.0.1:5432/aisys

참고: 스키마는 DB 볼륨이 처음 생성될 때 자동 적용됩니다. 이미 볼륨이 있으면 `docker compose down -v` 후 다시 시작하세요.

## 7) IR 추출 품질 평가 (법률 신호 보존율)
입력 JSONL 예시:
```json
{"id":"sample-1","text":"대법원 2021도12345 판결은 형법 제314조 제1항 적용 여부를 판단하였다."}
{"id":"sample-2","text":"헌법재판소 2020헌가1 결정은 기본권 제한의 비례성 심사를 다루었다."}
```

실행:
```bash
cd backend
PYTHONPATH=. python scripts/evaluate_ir.py \
	--input /path/to/legal_samples.jsonl \
	--output /tmp/ir_eval_summary.json \
	--per-sample /tmp/ir_eval_per_sample.jsonl
```

주요 지표:
- `avg_signal_retention`: 핵심문장 축약 뒤 조문/사건번호/법원명/날짜 등 법률 신호 보존 비율
- `avg_keyword_count`: 샘플당 추출된 법률 키워드 평균 개수
- `avg_key_sentence_length`: LLM 입력 핵심문장 길이 평균

## 8) 최신 스모크 체크 (2026-05-07)

```bash
docker compose up -d --build
curl -i http://127.0.0.1:8000/health
docker compose down
```

기대 결과:
- HTTP/1.1 200 OK
