# AI_SYS Backend Quickstart

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
