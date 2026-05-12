# AWS Free Tier로 AI_SYS 프로덕션 배포하기

**작성일**: 2026-05-07  
**목표**: 1년 무료로 프로덕션 환경 구축 (이후 월 $20-30)

**권장 리전**: 서울 (ap-northeast-2)

---

## 0️⃣ 리전 먼저 고정 (중요)

- 이 문서는 서울 리전 (ap-northeast-2) 기준이다.
- 콘솔 우상단 리전을 먼저 서울로 맞춘 뒤 진행한다.
- Free Tier는 계정 총량 기준이므로, 여러 리전을 동시에 켜두면 초과 과금 위험이 커진다.

### 이미 시드니(ap-southeast-2)로 만든 경우

1. 서울(ap-northeast-2)로 리전 변경
2. RDS/EC2를 서울에서 다시 생성
3. 앱/서버 환경변수의 DB Endpoint를 서울 Endpoint로 교체
4. 시드니 리소스 정리
  - RDS 인스턴스 삭제
  - EC2 인스턴스 종료/삭제
  - Elastic IP 해제
  - 불필요 보안 그룹 삭제

---

## 📋 배포 단계 요약

| 단계 | 내용 | 예상 시간 | 무료? |
|------|------|---------|------|
| 1️⃣ | AWS 계정 + Free Tier 가입 | 10분 | ✅ |
| 2️⃣ | RDS PostgreSQL 생성 | 15분 | ✅ |
| 3️⃣ | EC2 t2.micro 인스턴스 생성 | 5분 | ✅ |
| 4️⃣ | 도메인 구입 (선택사항) | 5분 | ❌ ~$12/년 |
| 5️⃣ | 백엔드 배포 (Docker) | 20분 | ✅ |
| 6️⃣ | iOS 앱 설정 | 10분 | ✅ |
| **합계** | | ~70분 | ✅ 무료 |

---

## 1️⃣ AWS 계정 가입 + Free Tier 활성화

### 1.1 AWS 계정 생성

1. https://aws.amazon.com/ 접속
2. **Create an AWS Account** 클릭
3. 이메일, 암호 입력
4. **AWS 계정 이름**: 입력 (예: `aisys-prod`)
5. **결제 정보** 입력 (신용카드 - 무료이므로 청구 안 됨)
6. **전화 인증** 완료

### 1.2 Free Tier 확인

1. AWS Management Console 로그인: https://console.aws.amazon.com/
2. 오른쪽 상단 사용자명 클릭 → **Billing and Cost Management**
3. **Billing Preferences** → `Free Tier usage alerts` 활성화
   - 이렇게 하면 무료 한도 초과 시 알림 받음

---

## 2️⃣ RDS PostgreSQL 생성 (데이터베이스)

### 2.1 RDS 콘솔에서 데이터베이스 생성

1. https://console.aws.amazon.com/ 로그인
2. 검색창에 **RDS** 입력 → **RDS** 클릭
3. 왼쪽 메뉴 → **Databases** → **Create database** 클릭

### 2.2 데이터베이스 설정

**Engine options**:
- ✅ **Engine type**: PostgreSQL
- ✅ **Version**: PostgreSQL 17.2

**Templates** (중요!):
- ✅ **Free tier** 선택 (아래 라디오 버튼)

**Settings**:
- **DB instance identifier**: `aisys-prod-db`
- **Master username**: `postgres`
- **Master password**: 복잡한 암호 설정
  - 예: `YOUR_STRONG_DB_PASSWORD`
  - ✅ 반드시 메모하기 (나중에 필요)

**Instance class** (자동으로 db.t3.micro 선택됨):
- ✅ `db.t3.micro` (Free Tier 한정)

**Storage**:
- ✅ **Storage type**: General Purpose (gp3)
- ✅ **Allocated storage**: 20 GB (Free Tier 한정)
- ✅ **Enable storage autoscaling**: OFF (비용 방지)

**Connectivity**:
- **VPC**: Default VPC
- **Publicly accessible**: `Yes`
  - ⚠️ EC2에서 접근하기 위해 필요
- **VPC security group**: 새로 생성 (이름: `aisys-db-sg`)
- **Database port**: 5432

**Backup**:
- ✅ **Enable automated backups**: `Yes`
- **Backup retention period**: 7 days (Free Tier 한정)
- **Enable backup encryption**: Off (비용 방지)

**Deletion protection**:
- ✅ **Enable deletion protection**: `Yes` (실수로 삭제 방지)

**Create database** 클릭

### 2.3 RDS 인스턴스 확인

```
예상 시간: 10-15분

상태 확인:
RDS → Databases → aisys-prod-db
- Status: Available ✅
- Endpoint: aisys-prod-db.xxxxx.ap-northeast-2.rds.amazonaws.com
```

이 **Endpoint**를 메모하세요! (나중에 필요)

### 2.4 보안 그룹 설정 (PostgreSQL 접근 허용)

1. RDS → aisys-prod-db
2. **Connectivity & security** → **VPC security groups**
3. `aisys-db-sg` 클릭
4. **Inbound rules** → **Edit inbound rules**
5. **Add rule**:
   - **Type**: PostgreSQL
   - **Port**: 5432
  - **Source(권장)**: `aisys-api-sg` (EC2 보안 그룹)
  - **Source(초기화 시 임시)**: `내 공인 IP/32` 추가 후 초기화 완료 뒤 제거
   - **Save rules**

### 2.5 데이터베이스 초기화 (로컬에서)

터미널에서 실행:

```bash
# 환경 변수 설정
export DB_HOST="aisys-prod-db.xxxxx.ap-northeast-2.rds.amazonaws.com"  # 위에서 복사한 Endpoint
export DB_PORT=5432
export DB_USER="postgres"
export DB_PASSWORD="YOUR_STRONG_DB_PASSWORD"  # 위에서 설정한 암호

# PostgreSQL 클라이언트 설치 (Mac)
brew install postgresql

# 1) 데이터베이스 생성
psql -h $DB_HOST -U $DB_USER -c "CREATE DATABASE aisys;"

# 2) schema.sql 적용
psql -h $DB_HOST -U $DB_USER -d aisys -f code/db/schema.sql

# 3) seed.sql 적용 (샘플 데이터)
psql -h $DB_HOST -U $DB_USER -d aisys -f code/db/seed.sql

# 4) 확인
psql -h $DB_HOST -U $DB_USER -d aisys -c "SELECT COUNT(*) FROM published_cases;"
```

**만약 psql 명령어가 안 되면:**

```bash
# Python으로 직접 실행
pip install psycopg2-binary
python3 << 'EOF'
import psycopg2

# 1) 데이터베이스 생성
conn = psycopg2.connect(
  host="aisys-prod-db.xxxxx.ap-northeast-2.rds.amazonaws.com",
    user="postgres",
    password="YOUR_STRONG_DB_PASSWORD",
    port=5432
)
conn.autocommit = True
cur = conn.cursor()
cur.execute("CREATE DATABASE aisys;")
print("✅ Database created")
cur.close()
conn.close()

# 2) schema.sql 적용
with open('code/db/schema.sql') as f:
    schema = f.read()

conn = psycopg2.connect(
  host="aisys-prod-db.xxxxx.ap-northeast-2.rds.amazonaws.com",
    user="postgres",
    password="YOUR_STRONG_DB_PASSWORD",
    port=5432,
    database="aisys"
)
cur = conn.cursor()
cur.execute(schema)
conn.commit()
print("✅ Schema applied")
cur.close()
conn.close()
EOF
```

✅ **RDS 완성!** 이제 EC2로 진행

---

## 3️⃣ EC2 인스턴스 생성 (API 서버)

### 3.1 EC2 콘솔에서 인스턴스 생성

1. https://console.aws.amazon.com/
2. 검색창에 **EC2** 입력 → **EC2** 클릭
3. **Instances** → **Launch instances** 클릭

### 3.2 인스턴스 설정

**Name and tags**:
- **Name**: `aisys-api-server`

**Application and OS Images**:
- ✅ **AMI**: Ubuntu 24.04 LTS (Free tier eligible)
- **Architecture**: 64-bit (x86)

**Instance type** (중요!):
- ✅ `t2.micro` (Free Tier 한정, 월 750시간)

**Key pair (login)**:
- **Key pair name**: 새로 생성
  - 이름: `aisys-prod-key`
  - **Create key pair** → `.pem` 파일 **다운로드**
  - ⚠️ 절대 잃어버리지 말 것! (나중에 서버에 접속할 때 필요)

**Network settings**:
- **VPC**: Default VPC
- **Subnet**: Default subnet
- **Auto-assign Public IP**: ✅ Enable
- **Firewall (security group)**: Create security group
  - **Name**: `aisys-api-sg`
  - **Inbound rules**:
    - SSH (Port 22): My IP (본인 IP만 허용)
    - HTTP (Port 80): Anywhere (0.0.0.0/0)
    - HTTPS (Port 443): Anywhere (0.0.0.0/0)

**Storage**:
- ✅ **Size**: 30 GB (Free Tier 한정)
- **Volume type**: gp3

**Launch instance** 클릭

### 3.3 EC2 인스턴스 확인

```
예상 시간: 1-2분

상태 확인:
EC2 → Instances → aisys-api-server
- Instance State: Running ✅
- Public IPv4 address: xxx.xxx.xxx.xxx (메모하세요!)
```

이 **Public IP**를 메모하세요!

### 3.4 Elastic IP 할당 (Optional but 권장)

Public IP는 서버 재시작 시 변경되므로, 고정 IP(Elastic IP) 할당:

1. EC2 → **Elastic IPs** (왼쪽 메뉴)
2. **Allocate Elastic IP address**
3. **Allocate** 클릭
4. 생성된 Elastic IP 선택
5. **Associate Elastic IP address**
   - **Instance**: `aisys-api-server` 선택
   - **Associate** 클릭

이제 이 Elastic IP는 영구적입니다!

---

## 4️⃣ EC2에 백엔드 배포

### 4.1 EC2에 SSH로 접속

터미널에서:

```bash
# 1) .pem 파일 권한 설정
chmod 600 ~/Downloads/aisys-prod-key.pem

# 2) EC2에 접속
ssh -i ~/Downloads/aisys-prod-key.pem ubuntu@<EC2_PUBLIC_IP>
# 또는 Elastic IP 사용
ssh -i ~/Downloads/aisys-prod-key.pem ubuntu@<ELASTIC_IP>

# 예: ssh -i ~/Downloads/aisys-prod-key.pem ubuntu@54.123.45.67
```

**접속 성공하면**:
```
ubuntu@ip-172-31-xxx-xxx:~$
```

이제 EC2 인스턴스 내에서 실행합니다.

### 4.2 서버 환경 구성 (EC2 내에서)

```bash
# 1) 시스템 업데이트
sudo apt update
sudo apt upgrade -y

# 2) Docker 설치
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# 3) Docker Compose 설치
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# 4) 사용자를 docker 그룹에 추가 (sudo 없이 docker 실행)
sudo usermod -aG docker ubuntu

# 5) Git 설치
sudo apt install -y git

# 6) 로그아웃 후 다시 로그인 (docker 권한 적용)
exit
```

다시 로그인:
```bash
ssh -i ~/Downloads/aisys-prod-key.pem ubuntu@<ELASTIC_IP>
```

### 4.3 소스 코드 다운로드

```bash
cd /home/ubuntu

# GitHub에서 코드 다운로드
git clone https://github.com/acertainromance401/AI_SYS_Personal.git ai-sys
cd ai-sys

# 현재 branch 확인
git branch -a
git checkout 임재현  # 또는 main, 필요시 변경
```

### 4.4 환경 변수 파일 생성

```bash
# .env 파일 생성
cat > .env << 'EOF'
POSTGRES_DB=aisys
POSTGRES_USER=postgres
POSTGRES_PASSWORD=YOUR_STRONG_DB_PASSWORD
DATABASE_URL=postgresql://postgres:YOUR_STRONG_DB_PASSWORD@aisys-prod-db.xxxxx.ap-northeast-2.rds.amazonaws.com:5432/aisys
DB_POOL_MIN_SIZE=1
DB_POOL_MAX_SIZE=10
DB_POOL_TIMEOUT=10
DB_CONNECT_TIMEOUT=5
EOF
```

**중요**: `aisys-prod-db.xxxxx.ap-northeast-2.rds.amazonaws.com`을 실제 RDS Endpoint로 교체!

### 4.5 docker-compose.yml 수정 (RDS용)

docker-compose.yml을 RDS를 사용하도록 수정:

```bash
cat > docker-compose.yml << 'EOF'
version: '3.9'

services:
  api:
    build:
      context: ./code/backend
    container_name: aisys-api
    environment:
      DATABASE_URL: ${DATABASE_URL}
      DB_POOL_MIN_SIZE: ${DB_POOL_MIN_SIZE:-5}
      DB_POOL_MAX_SIZE: ${DB_POOL_MAX_SIZE:-10}
      DB_POOL_TIMEOUT: ${DB_POOL_TIMEOUT:-10}
      DB_CONNECT_TIMEOUT: ${DB_CONNECT_TIMEOUT:-5}
    ports:
      - "8000:8000"
    restart: always
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
EOF
```

### 4.6 Docker 시작

```bash
# 1) 이미지 빌드 및 시작
docker compose up -d --build

# 2) 상태 확인
docker compose ps

# 3) API 헬스 체크
curl http://localhost:8000/health

# 예상 출력:
# {"status":"ok"}
```

✅ **백엔드 배포 완성!**

### 4.7 (선택사항) Nginx 리버스 프록시 설정

```bash
# Nginx 설치
sudo apt install -y nginx

# Nginx 설정
sudo tee /etc/nginx/sites-available/aisys > /dev/null << 'EOF'
upstream aisys_api {
    server localhost:8000;
}

server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://aisys_api;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket 지원 (나중에 필요할 수 있음)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# 심볼릭 링크
sudo ln -sf /etc/nginx/sites-available/aisys /etc/nginx/sites-enabled/

# 기본 설정 삭제
sudo rm -f /etc/nginx/sites-enabled/default

# Nginx 시작
sudo systemctl restart nginx
sudo systemctl enable nginx

# 확인
curl http://localhost
```

---

## 5️⃣ 도메인 설정 (선택사항)

### 5.1 도메인 구매 (AWS Route 53)

1. Route 53 → Domain registration
2. **Register domain** 클릭
3. 도메인 입력 (예: `aisys.com`)
4. **Check** → **Add to cart** → **Continue**
5. **Contact details** 입력
6. 약관 동의 → **Submit Order**
7. 이메일 확인 (도메인 활성화)

**예상 비용**: 도메인에 따라 $12-15/년 (Free Tier 적용 ❌)

### 5.2 Route 53에서 DNS 레코드 생성

1. Route 53 → **Hosted zones**
2. 구매한 도메인 (`aisys.com`) 클릭
3. **Create record**:
   - **Record name**: `api` (또는 서브도메인 원하는 이름)
   - **Record type**: A
   - **Value**: Elastic IP 입력 (예: `54.123.45.67`)
   - **TTL**: 300
   - **Create records**

이제 `api.aisys.com`으로 접속 가능!

```bash
# 확인
curl http://api.aisys.com/health
# 출력: {"status":"ok"}
```

### 5.3 SSL 인증서 (ACM) - 선택사항

HTTPS를 사용하려면:

1. ACM (AWS Certificate Manager) → **Request a certificate**
2. **Domain names**: `api.aisys.com`
3. **Validation method**: DNS
4. **Request** 클릭
5. Route 53에서 자동으로 DNS 레코드 생성
6. 약 15분 후 인증서 발급

이후 ALB 설정 필요 (비용 발생 가능하므로 나중에)

---

## 6️⃣ iOS 앱 설정

### 6.1 NetworkService.swift 수정

[code/ios/AISYSApp/Sources/NetworkService.swift](code/ios/AISYSApp/Sources/NetworkService.swift) 수정:

**BEFORE**:
```swift
let baseURL = "http://172.27.30.76:8000"
```

**AFTER** (Build Configuration 분리):
```swift
#if DEBUG
// 개발 환경: 로컬 macOS Docker
let baseURL = "http://172.27.30.76:8000"
#else
// 프로덕션: AWS
let baseURL = "https://api.aisys.com"  // 또는 "http://<ELASTIC_IP>:8000"
#endif
```

### 6.2 Info.plist 수정

**AISYSApp/Info.plist** (또는 프로젝트 settings)에 ATS 예외 추가:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSExceptionDomains</key>
    <dict>
        <!-- 프로덕션: api.aisys.com (HTTPS 사용) -->
        <key>api.aisys.com</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSThirdPartyExceptionAllowsInsecureHTTPLoads</key>
            <false/>
        </dict>
        
        <!-- 개발용: 로컬 IP (HTTP 사용 가능) -->
        <key>172.27.30.76</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSThirdPartyExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
    </dict>
</dict>
```

### 6.3 iOS 앱 빌드 (RELEASE)

```bash
cd code/ios

# 1) 프로젝트 생성
xcodegen generate

# 2) RELEASE 모드로 빌드
xcodebuild build \
  -project AISYS.xcodeproj \
  -scheme AISYSApp \
  -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# 3) 테스트
curl http://localhost:8000/health  # ← 로컬 Docker (개발)
curl http://api.aisys.com/health   # ← AWS (프로덕션)
```

---

## ✅ 배포 완료 확인

### 체크리스트

- [ ] AWS 계정 가입 + Free Tier 활성화
- [ ] RDS PostgreSQL 생성 (db.t3.micro)
- [ ] RDS 데이터베이스 초기화 (schema.sql + seed.sql)
- [ ] EC2 인스턴스 생성 (t2.micro)
- [ ] EC2에 SSH 접속 확인
- [ ] Docker + Docker Compose 설치
- [ ] 소스 코드 다운로드 (GitHub)
- [ ] 환경 변수 파일 (.env) 생성
- [ ] Docker Compose 시작
- [ ] API 헬스 체크: `curl http://<ELASTIC_IP>:8000/health`
- [ ] 도메인 구매 (선택사항)
- [ ] Route 53 DNS 레코드 설정 (선택사항)
- [ ] iOS 앱 NetworkService.swift 수정
- [ ] iOS 앱 빌드 (RELEASE)
- [ ] 최종 테스트: 실기기에서 앱 실행

### 예상 결과

```
iPhone 사용자가 앱을 실행하면:
1. OCR로 케이스 사진 스캔 (로컬, 즉시)
2. 백엔드에서 IR 검색 (AWS, 2-3초)
   - 백엔드 실패 시 자동으로 로컬 검색
3. 로컬 LLM에서 요약 생성 (로컬, 5-10초)
4. 퀴즈 생성 (로컬, 1초)
5. 저장 (로컬 SwiftData)

모든 과정이 투명하게 작동 ✅
```

---

## 💰 무료 기간 모니터링

1. AWS 콘솔 → **Billing and Cost Management**
2. **Free Tier Usage** 확인
3. 월 말에 이메일로 사용량 리포트 받음

**1년 후 비용**:
- EC2 t2.micro: ~$8-10/월
- RDS db.t3.micro: 초과 시 ~$20-30/월
- 합계: ~$30-40/월 (프로덕션 수준으로는 매우 저렴)

---

## 🆘 문제 해결

### RDS 연결 안 됨

```bash
# 1) RDS 보안 그룹 확인
# AWS Console → RDS → aisys-prod-db → Security

# 2) Inbound 규칙에 PostgreSQL (5432)이 있는지 확인

# 3) 로컬에서 직접 테스트
psql -h aisys-prod-db.xxxxx.ap-northeast-2.rds.amazonaws.com \
     -U postgres -d aisys -c "SELECT 1"
```

### EC2 Docker 시작 안 됨

```bash
# 1) 로그 확인
docker logs aisys-api

# 2) 환경 변수 확인
cat .env

# 3) Docker Compose 재시작
docker compose down
docker compose up -d --build
```

### API 응답 없음

```bash
# 1) EC2 보안 그룹 확인
# AWS Console → EC2 → Security Groups → aisys-api-sg
# Inbound: HTTP (80), HTTPS (443) 확인

# 2) 로컬 테스트
curl http://localhost:8000/health

# 3) 외부에서 테스트
curl http://<ELASTIC_IP>:8000/health
```

---

## 다음 단계 (선택사항)

1. **HTTPS 활성화**: ACM + ALB 설정
2. **자동 배포**: GitHub Actions CI/CD
3. **모니터링**: CloudWatch 로그 + 알림
4. **스케일링**: Auto Scaling Group
5. **백업**: RDS 자동 스냅샷 (이미 활성화)

---

## 부록: 시드니에서 서울로 10분 정리 절차

### A. 시드니 리소스 삭제 (비용 방지)

1. 리전: ap-southeast-2 선택
2. RDS: aisys-prod-db 삭제 (Delete automated backups는 필요 시 Off)
3. EC2: 인스턴스 종료 후 삭제
4. Elastic IP: Disassociate 후 Release
5. Security Group: 사용 안 하는 그룹 삭제

### B. 서울에서 재시작

1. 리전: ap-northeast-2 선택
2. RDS 재생성 (db.t3.micro)
3. EC2 재생성 (t2.micro)
4. 보안 그룹 연동
  - DB SG inbound: PostgreSQL 5432 from aisys-api-sg
5. .env와 초기화 명령의 Endpoint를 서울 것으로 교체

---

**질문이 있으면 각 단계별로 더 상세히 설명해 드리겠습니다!**
