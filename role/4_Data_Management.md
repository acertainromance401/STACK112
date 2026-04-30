# 데이터 관리 (Data Management)

## 개요
AI_SYS의 데이터 관리는 정책(Policy) 및 판례(Case) 데이터의 수집, 정규화, 검증, 저장을 담당합니다. 데이터베이스는 PostgreSQL을 사용하며, 데이터 품질 관리가 핵심입니다.

---

## 책임사항

### 1. 데이터베이스 설계
- 스키마 정의 및 설계
- 테이블 관계 설정
- 인덱스 최적화

### 2. 데이터 수집 및 관리
- 정책/판례 데이터 수집
- 데이터 임포트/엑스포트
- 버전 관리

### 3. 데이터 표준화 및 정규화
- 데이터 형식 통일
- 메타데이터 정의
- 이상치 감지 및 처리

### 4. 데이터 무결성 관리
- 외래키 제약 조건
- 데이터 검증 규칙
- 트랜잭션 관리

### 5. 데이터 품질 모니터링
- 데이터 품질 지표
- 이상 감지
- 정기적 감사

### 6. 백업 및 복구
- 정기적 백업
- 재해 복구 계획
- 데이터 보안

---

## 기술 스택

| 항목 | 기술 |
|------|------|
| **데이터베이스** | PostgreSQL |
| **버전 관리** | 마이그레이션 스크립트 |
| **데이터 검증** | SQL 제약조건 + 애플리케이션 로직 |
| **백업** | 자동 백업 (Docker Compose) |

---

## 프로젝트 구조

```
data/
├── README.md                        # 데이터 설명 문서
├── raw/                             # 원본 데이터 (수집됨)
├── normalized/                      # 정규화된 데이터
├── reviewed/                        # 검수된 데이터 (최종)
├── failed/                          # 처리 실패 데이터
├── policy/
│   └── SCourt_Policy_Check_Guide.md # 정책 검증 가이드
└── templates/
    └── scourt_permission_request_email.md  # 이메일 템플릿

db/
├── schema.sql                       # 데이터베이스 스키마 정의
└── (운영 데이터는 외부 적재 파이프라인으로 관리)
```

---

## 데이터베이스 스키마

### 주요 테이블 / 뷰

#### 1. `cases` (판례 원본 테이블)
```sql
CREATE TABLE cases (
    id         UUID PRIMARY KEY,
    case_number   VARCHAR UNIQUE NOT NULL,
    case_name     TEXT NOT NULL,
    court_name    TEXT,
    decision_date DATE,
    subject       TEXT,
    issue_summary TEXT,
    holding_summary TEXT,
    exam_points   TEXT,
    source_url    TEXT,
    status        TEXT DEFAULT 'draft',  -- 'published' | 'draft'
    updated_at    TIMESTAMP DEFAULT now()
);
```

#### 2. `published_cases` (판례 조회 뷰)
```sql
-- status = 'published' 기준 뷰, API 조회 기준
CREATE VIEW published_cases AS
    SELECT * FROM cases WHERE status = 'published';
```

#### 3. `case_keywords` (판례 키워드)
```sql
-- 검색 JOIN 대상, 판례당 다대일 관계
CREATE TABLE case_keywords (
    id      SERIAL PRIMARY KEY,
    case_id UUID REFERENCES cases(id),
    keyword TEXT NOT NULL
);
```

#### 4. `user_case_history` (사용자 학습 이력)
```sql
-- 오답 노트, 복습 이력 저장
-- /dashboard/wrong-answers API가 이 테이블 기반 데이터 반환
CREATE TABLE user_case_history (
    id       SERIAL PRIMARY KEY,
    user_id  TEXT NOT NULL,
    case_id  UUID REFERENCES cases(id),
    memo     TEXT,
    created_at TIMESTAMP DEFAULT now()
);
```

---

## 데이터 수집 프로세스

### 1단계: 원본 데이터 수집
- 대법원 공식 데이터 수집
- 정책 문서 다운로드
- 위치: `data/raw/`

### 2단계: 데이터 정규화
- 형식 통일 (CSV → JSON → DB)
- 메타데이터 추가
- 이상치 식별
- 위치: `data/normalized/`

### 3단계: 데이터 검증
- 중복 제거
- 참조 무결성 확인
- 비즈니스 규칙 검증
- 위치: `data/reviewed/`

### 4단계: 데이터베이스 로드
- SQL 쿼리 생성
- 트랜잭션 처리
- 에러 핸들링

---

## 데이터 정규화 규칙

### 날짜 형식
```
입력: "2025년 04월 28일", "2025/04/28", "2025-04-28"
출력: "2025-04-28" (ISO 8601)
```

### 텍스트 필드
- 공백 정규화 (다중 공백 → 단일 공백)
- 특수문자 처리
- 인코딩 통일 (UTF-8)

### 숫자 필드
- 범위 검증
- 유형 확인 (정수 vs 소수)
- 누락 값 처리

### 참조 일관성
- 외래키 존재 확인
- 참조 무결성 유지

---

## 데이터 검증 가이드

### 품질 지표

| 지표 | 목표 | 방법 |
|------|------|------|
| 완성도 | 95% 이상 | 누락 필드 비율 |
| 정확도 | 99% 이상 | 샘플 검증 |
| 일관성 | 100% | 중복 확인 |
| 적시성 | 1주 내 | 업데이트 주기 |

### 검증 프로세스

1. **자동 검증**
   - SQL 제약조건
   - 타입 검사
   - 범위 검사

2. **수동 검증**
   - 전문가 검토
   - 샘플 검증
   - 통계 분석

3. **주기적 감시**
   - 일일 모니터링
   - 주간 리포트
   - 월간 감사

---

## 데이터 저장소 구조

### 폴더별 용도

#### `data/raw/`
- 원본 데이터 저장
- 변환 전 상태 유지
- 추적성(Traceability) 보장

#### `data/normalized/`
- 정규화된 데이터
- 검증 전 상태
- 복구 가능한 형태

#### `data/reviewed/`
- 최종 검증된 데이터
- 프로덕션 데이터
- 사용 가능한 상태

#### `data/failed/`
- 처리 실패 데이터
- 에러 로그 포함
- 재처리 대상

---

## 데이터 마이그레이션

### 스키마 변경 절차

1. **마이그레이션 스크립트 작성**
   ```sql
   -- migration_001_create_users_table.sql
   ALTER TABLE users ADD COLUMN new_field VARCHAR(100);
   ```

2. **테스트 환경 검증**
   - 데이터 손실 확인 안 함
   - 성능 영향 평가

3. **프로덕션 배포**
   - 사전 백업 수행
   - 롤백 계획 준비
   - 실행 및 모니터링

---

## 백업 및 복구

### 백업 전략
- **빈도**: 일일 자동 백업
- **보존**: 30일분 유지
- **위치**: 로컬 + 클라우드 스토리지

### 복구 프로세스
```
데이터 손상 감지
    ↓
백업 확인
    ↓
복구 환경 준비
    ↓
데이터 복구 실행
    ↓
일관성 검증
    ↓
프로덕션 복구
```

---

## 성능 최적화

### 인덱싱 전략
```sql
-- 검색 대상 필드
CREATE INDEX idx_cases_case_number ON cases(case_number);
CREATE INDEX idx_cases_status ON cases(status);
CREATE INDEX idx_cases_updated_at ON cases(updated_at DESC);

-- 키워드 검색 JOIN
CREATE INDEX idx_case_keywords_case_id ON case_keywords(case_id);
CREATE INDEX idx_case_keywords_keyword ON case_keywords(keyword);

-- 사용자 이력
CREATE INDEX idx_user_case_history_user_id ON user_case_history(user_id);
```

### 쿼리 최적화
- 불필요한 조인 제거
- 집계 함수 최적화
- 페이지네이션 활용

---

## 데이터 보안

### 접근 제어
- 사용자별 권한 관리
- 역할 기반 접근(RBAC)
- 감사 로그 유지

### 암호화
- 저장 데이터 암호화 (컬럼 레벨)
- 전송 데이터 암호화 (TLS)
- 개인정보 마스킹

---

## 개발 워크플로우

### 데이터 임포트
```bash
# 1. CSV 파일 준비
# 2. 정규화 스크립트 실행
python normalize_data.py data/raw/policies.csv

# 3. 데이터 로드
psql -h localhost -U user -d aisys -f db/schema.sql
psql -h localhost -U user -d aisys -f data/normalized/policies.sql
```

### 데이터 검증
```bash
# 품질 검사 실행
python validate_data.py
```

### 백업 수행
```bash
# 데이터베이스 백업
pg_dump -h localhost -U user aisys > backup.sql
```

---

## 상호작용

### 백엔드와의 상호작용
- 데이터 쿼리 제공
- API를 통한 CRUD 작업
- 트랜잭션 관리

### 프론트엔드와의 상호작용
- 검색 데이터 제공
- 로컬 캐시 동기화
- 오프라인 데이터 지원

### AI 모델 설계와의 상호작용
- 학습 데이터 제공
- 추론용 컨텍스트 데이터
- 피드백 데이터 수집

---

## 참고 문서
- [데이터베이스 스키마](../db/schema.sql)
- [데이터 빌드 가이드](../code/Data_Build_Guide_AI_SYS.md)
- [정책 검증 가이드](../data/policy/SCourt_Policy_Check_Guide.md)

---

## 참고 코드 및 추가 작성 항목

### 참고 코드 (현재 기준)
- `code/db/schema.sql` - DB 스키마 정의
- `code/data/README.md` - 데이터 운영 구조 및 가이드
- `code/data/policy/SCourt_Policy_Check_Guide.md` - 정책 검증 기준
- `code/backend/app/main.py` - 검색/대시보드 SQL 사용처

### 추가 작성 항목 (다음 단계)
1. 임베딩 저장 컬럼/인덱스 설계 (pgvector 기반)
2. 유사도 Top-K 검색 SQL/뷰 설계 및 API 연동
3. OCR 텍스트 정제/키워드/임베딩 적재 배치 파이프라인 구축 (`code/data/pipelines/`)
4. 데이터 품질 자동 점검 스크립트(누락/중복/최신성) 추가

---

## 현재 진행 상황 (기준: 2026-04-28)

### 완료 사항 ✅

| 항목 | 상세 |
|------|------|
| DB 스키마 확립 | `schema.sql`로 초기화 체계 완료 (pgvector 포함) |
| 초기 데이터 정책 | 더미/샘플 데이터 제거, 실데이터 적재 중심으로 전환 |
| 이관된 판례 | 2021도16503, 2022도12345, 2021도1234, 2020도4521, 2018도19876, 2023도16220, 2021도20457, 2017도18543 등 |
| 오답 데이터 운영 | 사용자별 실사용 이력(`user_case_history`) 기반 조회 |
| 게시 상태 뷰 | `published_cases` 뷰 기준으로 API 조회 정리 |
| 데이터 단계 구조 | `raw/normalized/reviewed/failed/manifests` 폴더 구조 정의 완료 |
| 운영 문서 확보 | 정책 체크 가이드, 메일 템플릿, manifest 템플릿 등 문서 확보 |

### 현재 제한 사항 ⚠️

- **배치 파이프라인 미자동화**: 대규모 최신 판례 데이터 수집/적재 자동화 미완료
- **품질 대시보드 부재**: 데이터 정확도, 누락률, 최신성 모니터링 대시보드 없음
- **업데이트 주기 미명시**: 데이터 최신성 유지 주기 및 절차 미확정
- **실패 데이터 재처리 미정의**: `data/failed/` 데이터 재처리 절차 미수립

### 다음 작업 (우선순위 순)

1. **[P1]** 데이터 적재/검수 배치 프로세스 정리
2. **[P1]** 실패 데이터(`data/failed/`) 재처리 절차 정의
3. **[P1]** 데이터 최신성 업데이트 주기 명시
4. **[P2]** 데이터 품질 지표 대시보드 구축 (정확도, 누락률, 최신성)
5. **[P2]** 대규모 판례 배치 파이프라인 자동화
6. **[P2]** 백업/복구 운영 점검 문서 강화

---

**마지막 업데이트**: 2026-04-28
