# AI_SYS 프로덕션 배포 가이드

**작성일**: 2026-05-07  
**목표**: AWS를 이용한 프로덕션 환경 구축 (사용자가 앱만 클릭하면 자동 동작)

---

## 목차

1. [개요](#개요)
2. [아키텍처](#아키텍처)
3. [사전 준비](#사전-준비)
4. [Step 1: 데이터베이스 호스팅](#step-1-데이터베이스-호스팅-aws-rds)
5. [Step 2: API 서버 배포](#step-2-api-서버-배포-aws-ec2--app-runner)
6. [Step 3: 도메인 + SSL](#step-3-도메인--ssl)
7. [Step 4: iOS 앱 설정](#step-4-ios-앱-설정)
8. [Step 5: CI/CD 파이프라인](#step-5-cicd-파이프라인)
9. [배포 후 관리](#배포-후-관리)
10. [예상 비용](#예상-비용)

---

## 개요

### 프로덕션 환경 특징

```
사용자 입장:
  앱 다운로드 → 실행 → "케이스 스캔" → 자동 처리 완료

백엔드 입장:
  API 서버는 자동 실행 (AWS에서 24/7 호스팅)
  데이터베이스는 자동 백업 (AWS RDS 관리)
  사용자는 WiFi 설정, Docker 관리 등 신경 쓸 필요 없음
```

### 현재 vs 프로덕션

| 항목 | 현재(개발) | 프로덕션 |
|------|----------|--------|
| 데이터베이스 | 로컬 Docker | AWS RDS (Managed) |
| API 서버 | macOS + Docker | AWS EC2 또는 App Runner |
| 도메인 | 172.27.30.76:8000 | api.aisys.com (DNS) |
| SSL 인증서 | 없음 | ACM(무료) |
| 백업 | 없음 | 자동 일일 백업 |
| 모니터링 | 없음 | CloudWatch |

---

## 아키텍처

```
┌─────────────────────────────────────────────────────┐
│ 사용자의 iPhone                                      │
│  ┌──────────────────────┐                           │
│  │ AI_SYS iOS App       │                           │
│  │ - OCR (로컬)         │                           │
│  │ - LLM (로컬, 770MB)   │                           │
│  │ - API 호출 (api.aisys.com) │                    │
│  └──────────────────────┘                           │
└─────────────────────────────────────────────────────┘
              ↓ HTTPS
┌─────────────────────────────────────────────────────┐
│ AWS 리전 (us-east-1 권장)                            │
│  ┌─────────────────────────────────────────────┐   │
│  │ Application Load Balancer (ALB)             │   │
│  │  - 도메인: api.aisys.com                     │   │
│  │  - SSL/TLS 인증서 (ACM)                      │   │
│  └──────────────┬────────────────────────────┘   │
│                 ↓                                  │
│  ┌─────────────────────────────────────────────┐   │
│  │ EC2 Instance (t3.medium)                    │   │
│  │  - FastAPI + Uvicorn                        │   │
│  │  - Python 3.13                              │   │
│  │  - Auto Scaling Group                       │   │
│  └──────────────┬────────────────────────────┘   │
│                 ↓                                  │
│  ┌─────────────────────────────────────────────┐   │
│  │ RDS PostgreSQL                              │   │
│  │  - db.t3.small                              │   │
│  │  - pgvector 확장 활성화                       │   │
│  │  - 자동 백업 (30일)                          │   │
│  │  - Multi-AZ 옵션 (고가용성)                   │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

---

## 사전 준비

### 필수 준비물

1. **AWS 계정** (없으면 [여기서 생성](https://aws.amazon.com/)) 
2. **도메인** (Route 53 또는 외부 도메인 호스팅 서비스)
   - 예: `api.aisys.com`
3. **Git** (소스 코드 버전 관리)
4. **AWS CLI** 설치
   ```bash
   # Mac
   brew install awscli

   # 또는 pip
   pip install awscli
   ```
5. **AWS 인증 정보** 설정
   ```bash
   aws configure
   # AWS Access Key ID 입력
   # AWS Secret Access Key 입력
   # Default region: us-east-1
   ```

---

## Step 1: 데이터베이스 호스팅 (AWS RDS)

### 1.1 RDS PostgreSQL 인스턴스 생성

AWS Management Console에서:

1. RDS → Databases → Create database
2. 설정:
   - **Engine**: PostgreSQL
   - **Version**: 17.2 (최신)
   - **DB instance class**: `db.t3.small` (무료 티어 아님, ~$40/월)
   - **Storage**: 20 GB
   - **DB instance identifier**: `aisys-prod`
   - **Master username**: `postgres`
   - **Master password**: 복잡한 암호 설정 (예: `Aj$x9mK@2Lp4Qw8`)
   - **VPC**: 기본값 (Default VPC)
   - **Publicly accessible**: `Yes` (필요시 특정 IP만 허용)
   - **Enable backups**: `Yes`
   - **Backup retention period**: 30 days
   - **Enable Multi-AZ deployment**: `No` (비용 절감, 나중에 필요시 활성화)

3. **Create database** 클릭 (약 10분 소요)

### 1.2 보안 그룹 설정

생성된 RDS 인스턴스에 접근할 수 있도록 보안 그룹 수정:

1. RDS → Databases → `aisys-prod`
2. **VPC security groups** → 보안 그룹 클릭
3. **Inbound rules** → **Edit inbound rules**
4. 규칙 추가:
   - **Type**: PostgreSQL
   - **Protocol**: TCP
   - **Port**: 5432
   - **Source**: 
     - EC2 보안 그룹 (Step 2에서 생성) 또는
     - `0.0.0.0/0` (모든 IP, 개발용 - 프로덕션에서는 제한)

### 1.3 데이터베이스 초기화

RDS 인스턴스 생성 후, 로컬에서 스키마 및 샘플 데이터 적용:

```bash
# RDS 엔드포인트 복사 (예: aisys-prod.xxxx.us-east-1.rds.amazonaws.com)

# 환경 변수 설정
export DB_HOST="aisys-prod.xxxx.us-east-1.rds.amazonaws.com"
export DB_PORT=5432
export DB_USER="postgres"
export DB_PASSWORD="YOUR_STRONG_DB_PASSWORD"
export DB_NAME="aisys"

# 먼저 데이터베이스 생성
psql -h $DB_HOST -U $DB_USER -c "CREATE DATABASE aisys;"

# schema.sql 적용
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f code/db/schema.sql

# seed.sql 적용 (샘플 데이터)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f code/db/seed.sql
```

**주의**: 로컬에서 psql을 실행할 수 없으면:
```bash
pip install psycopg2-binary
python3 << 'EOF'
import psycopg2
conn = psycopg2.connect(
    host="aisys-prod.xxxx.us-east-1.rds.amazonaws.com",
    user="postgres",
  password="YOUR_STRONG_DB_PASSWORD",
    port=5432
)
conn.autocommit = True
cur = conn.cursor()
cur.execute("CREATE DATABASE aisys;")
conn.close()
EOF
```

---

## Step 2: API 서버 배포 (AWS EC2 + App Runner)

### 옵션 A: EC2 (더 제어 가능, 비용 저렴)

#### A1. EC2 인스턴스 생성

1. EC2 → Instances → Launch instances
2. 설정:
   - **AMI**: Ubuntu 24.04 LTS (Free tier eligible)
   - **Instance type**: `t3.medium` (~$35/월) 또는 `t3.small` (~$17/월)
   - **VPC**: 기본값 (Default)
   - **Subnet**: 기본값
   - **Key pair**: 새로 생성 (예: `aisys-prod-key`) → `.pem` 파일 다운로드 후 안전한 곳에 보관
   - **Security group**: 새로 생성 (이름: `aisys-api-sg`)
     - **Inbound rules**:
       - SSH (포트 22): 본인 IP만 허용
       - HTTP (포트 80): 0.0.0.0/0
       - HTTPS (포트 443): 0.0.0.0/0
   - **Storage**: 30 GB (기본값 충분)
   - **Elastic IP**: 할당 (나중에 도메인과 연결)

3. **Launch instance** 클릭

#### A2. 인스턴스에 접속 및 환경 구성

```bash
# 로컬에서 EC2 접속
chmod 600 aisys-prod-key.pem
ssh -i aisys-prod-key.pem ubuntu@<EC2_PUBLIC_IP>

# EC2 인스턴스 내에서 실행:

# 1) 시스템 업데이트
sudo apt update
sudo apt upgrade -y

# 2) Docker 설치
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker ubuntu

# 3) Docker Compose 설치
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# 4) Git 설치
sudo apt install -y git

# 5) 소스 코드 다운로드 (GitHub에서)
cd /home/ubuntu
git clone https://github.com/acertainromance401/AI_SYS_Personal.git ai-sys
cd ai-sys

# 6) 환경 변수 파일 생성
cat > .env << EOF
POSTGRES_DB=aisys
POSTGRES_USER=postgres
POSTGRES_PASSWORD=YOUR_STRONG_DB_PASSWORD
DATABASE_URL=postgresql://postgres:YOUR_STRONG_DB_PASSWORD@aisys-prod.xxxx.us-east-1.rds.amazonaws.com:5432/aisys
DB_POOL_MIN_SIZE=1
DB_POOL_MAX_SIZE=20
DB_POOL_TIMEOUT=10
DB_CONNECT_TIMEOUT=5
API_HOST=0.0.0.0
API_PORT=8000
EOF

# 7) Docker Compose 수정 (RDS 사용하도록)
# docker-compose.yml을 아래처럼 수정:
```

**수정된 docker-compose.yml** (RDS용):

```yaml
version: '3.9'

services:
  api:
    build:
      context: ./code/backend
    container_name: aisys-api
    environment:
      DATABASE_URL: ${DATABASE_URL}
      DB_POOL_MIN_SIZE: ${DB_POOL_MIN_SIZE:-5}
      DB_POOL_MAX_SIZE: ${DB_POOL_MAX_SIZE:-20}
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

volumes:
  pgdata:
```

```bash
# 8) Docker 이미지 빌드 및 시작
docker compose up -d --build

# 9) 상태 확인
docker compose ps
curl http://localhost:8000/health
```

#### A3. Nginx를 리버스 프록시로 설정 (선택사항이지만 권장)

```bash
sudo apt install -y nginx

# Nginx 설정
sudo tee /etc/nginx/sites-available/aisys > /dev/null << 'EOF'
upstream aisys_api {
    server localhost:8000;
}

server {
    listen 80;
    server_name api.aisys.com;

    location / {
        proxy_pass http://aisys_api;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

# 심볼릭 링크 생성
sudo ln -s /etc/nginx/sites-available/aisys /etc/nginx/sites-enabled/

# Nginx 시작
sudo systemctl restart nginx
sudo systemctl enable nginx
```

---

### 옵션 B: AWS App Runner (더 간단, 비용 높음)

AWS App Runner은 Docker 이미지를 업로드하면 자동으로 관리해줍니다.

1. **Docker 이미지를 ECR(Elastic Container Registry)에 푸시**

```bash
# ECR 저장소 생성
aws ecr create-repository --repository-name aisys-api --region us-east-1

# Docker 로그인
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

# 이미지 빌드 및 태그
docker build -t aisys-api:latest code/backend

docker tag aisys-api:latest <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/aisys-api:latest

# ECR에 푸시
docker push <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/aisys-api:latest
```

2. **App Runner 서비스 생성** (Console 또는 CLI)

```bash
aws apprunner create-service \
  --service-name aisys-api \
  --source-configuration '{"ImageRepository":{"ImageIdentifier":"<AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/aisys-api:latest","ImageRepositoryType":"ECR"}}' \
  --instance-configuration '{"InstanceRoleArn":"arn:aws:iam::<AWS_ACCOUNT_ID>:role/AppRunnerECRAccessRole"}' \
  --region us-east-1
```

**권장**: 초기에는 **EC2**로 시작 (비용 절감), 나중에 App Runner로 마이그레이션

---

## Step 3: 도메인 + SSL

### 3.1 도메인 등록

1. **Route 53에서 도메인 등록** 또는 **외부 도메인 호스팅** 사용 (예: GoDaddy, Namecheap)
   - 예: `aisys.com` 구매

### 3.2 SSL 인증서 (ACM)

**AWS Certificate Manager (무료)**:

1. ACM → Request a certificate
2. **Certificate details**:
   - **Domain names**: `api.aisys.com`
   - **Validation method**: DNS validation (권장)
3. **DNS records** 추가 (Route 53 또는 도메인 호스팅)
4. 확인 완료 (약 15분)

### 3.3 ALB (Application Load Balancer) 설정

**EC2를 사용하는 경우**:

1. EC2 → Load Balancers → Create load balancer
2. **Application Load Balancer** 선택
3. 설정:
   - **Name**: `aisys-alb`
   - **Scheme**: Internet-facing
   - **IP address type**: IPv4
   - **Listeners**: 
     - HTTP (80) → HTTP (EC2 인스턴스)
     - HTTPS (443) → HTTP (EC2 인스턴스)
   - **SSL certificate**: ACM에서 생성한 인증서 선택
4. **Target group** 설정:
   - **Target type**: Instances
   - **Targets**: EC2 인스턴스 선택

### 3.4 도메인과 ALB 연결

Route 53:

1. **Hosted zones** → `aisys.com`
2. **Create record**:
   - **Name**: `api.aisys.com`
   - **Type**: A
   - **Alias target**: ALB 선택
3. **Create records**

---

## Step 4: iOS 앱 설정

### 4.1 프로덕션 API 엔드포인트 설정

[NetworkService.swift](code/ios/AISYSApp/Sources/NetworkService.swift) 수정:

```swift
// BEFORE:
let baseURL = "http://172.27.30.76:8000"

// AFTER (Build Configuration 분리):
#if DEBUG
let baseURL = "http://172.27.30.76:8000"  // 개발 환경
#else
let baseURL = "https://api.aisys.com"  // 프로덕션
#endif
```

### 4.2 App Transport Security (ATS) 설정

**Info.plist** 수정:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <key>NSExceptionDomains</key>
    <dict>
        <key>api.aisys.com</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSThirdPartyExceptionAllowsInsecureHTTPLoads</key>
            <false/>
        </dict>
        <!-- DEBUG용 (개발 환경) -->
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

### 4.3 자동 백엔드 감지 (선택사항)

[NetworkService.swift](code/ios/AISYSApp/Sources/NetworkService.swift)에 백엔드 가용성 체크 추가:

```swift
private func isBackendAvailable() async -> Bool {\n    let url = URL(string: "\(baseURL)/health")!
    var request = URLRequest(url: url)
    request.timeoutInterval = 2  // 2초 타임아웃
    
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
        print("Backend unavailable: \\(error)")
        return false
    }
}

// 사용:
if await isBackendAvailable() {
    // 백엔드 사용
} else {
    // 로컬 모드로 폴백 (자동)
}
```

---

## Step 5: CI/CD 파이프라인

### 5.1 GitHub Actions (자동 배포)

**.github/workflows/deploy-backend.yml** 생성:

```yaml
name: Deploy Backend to AWS EC2

on:
  push:
    branches: [main]
    paths:
      - 'code/backend/**'
      - '.github/workflows/deploy-backend.yml'

env:
  AWS_REGION: us-east-1
  EC2_INSTANCE_ID: i-xxxxx  # 실제 인스턴스 ID
  EC2_USER: ubuntu
  EC2_KEY: ${{ secrets.EC2_PRIVATE_KEY }}

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Deploy to EC2
        env:
          PRIVATE_KEY: ${{ env.EC2_KEY }}
          HOST: ${{ secrets.EC2_PUBLIC_IP }}
          USER: ${{ env.EC2_USER }}
        run: |
          mkdir -p ~/.ssh
          echo "$PRIVATE_KEY" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa
          ssh-keyscan -H $HOST >> ~/.ssh/known_hosts

          ssh -i ~/.ssh/id_rsa $USER@$HOST << 'EOF'
            cd /home/ubuntu/ai-sys
            git pull origin main
            docker compose pull
            docker compose up -d --build
            docker compose ps
          EOF
```

**GitHub Secrets 설정**:

1. GitHub Repository → Settings → Secrets and variables → Actions
2. 추가:
   - `EC2_PRIVATE_KEY`: EC2 .pem 파일 내용
   - `EC2_PUBLIC_IP`: EC2 Elastic IP

### 5.2 수동 배포 (git push 없이)

```bash
# EC2에서:
cd /home/ubuntu/ai-sys

# 1) 최신 코드 가져오기
git pull origin main

# 2) Docker 이미지 재빌드 및 재시작
docker compose down
docker compose up -d --build

# 3) 상태 확인
docker compose ps
curl https://api.aisys.com/health
```

---

## 배포 후 관리

### 모니터링 (CloudWatch)

```bash
# CloudWatch 대시보드 생성 (선택사항)
aws cloudwatch put-metric-alarm \
  --alarm-name aisys-api-cpu \
  --alarm-description "Alert if CPU > 80%" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold
```

### 로그 관리

```bash
# EC2에서 API 로그 확인
docker logs aisys-api -f

# 또는 CloudWatch에 로그 전송 (추가 설정 필요)
```

### 백업 및 복구

```bash
# RDS 스냅샷 (자동 + 수동)
aws rds create-db-snapshot \
  --db-instance-identifier aisys-prod \
  --db-snapshot-identifier aisys-prod-snapshot-2026-05-07
```

---

## 비용 옵션 비교

### 옵션 1: AWS (유료) - 권장 (프로덕션 수준)

| 서비스 | 사양 | 월간 비용 |
|--------|------|---------|
| EC2 | t3.medium (731시간) | ~$35 |
| RDS PostgreSQL | db.t3.small (731시간) | ~$45 |
| ALB | 처음 1,000시간 무료, 이후 ~$20 | ~$5 |
| Route 53 | ~0.5M 쿼리 | ~$4 |
| 데이터 전송 | 100GB/월 예상 | ~$10 |
| **합계** | | **~$100-150/월** |

**비용 절감 방법**:
- EC2를 t3.small로 변경: -$18/월
- RDS를 db.t3.micro (가능한 경우): -$20/월
- 콘텐츠 캐싱 (CloudFront): API 응답 캐시로 비용 감소

---

### 옵션 2: AWS Free Tier - 무료 (1년)

**AWS는 처음 가입하면 1년 무료 리소스 제공**:

| 리소스 | 무료 한도 |
|--------|---------|
| EC2 t2.micro | 월 750시간 |
| RDS db.t3.micro (Single-AZ) | 월 750시간 + 20GB 스토리지 |
| ALB | 처음 1,000시간 |
| 데이터 전송 | 월 1GB 무료 (이상은 유료) |
| **추가 비용** | **월 ~$0-5** (초과분만) |

**AI_SYS의 경우**:
- OCR/LLM은 로컬에서 실행 (iPhone 내)
- 백엔드는 가볍게 사용 (검색, 데이터 동기화만)
- 데이터 전송량 적음
- **예상 무료 기간: 1년, 이후 월 $20-30**

**단점**: 1년 후 유료로 전환되거나 인스턴스 다운사이징 필요

**설정 방법**: Step 2에서 EC2 인스턴스 타입을 **t2.micro** 선택, RDS를 **db.t3.micro** 선택

---

### 옵션 3: Render.com - 부분 무료

**장점**:
- 무료 Web Service (제한적)
- 무료 PostgreSQL (제한적)
- 신용카드 불필요

**단점**:
- 무료 Web Service: 15분 요청 없으면 sleep (응답 느림)
- 무료 PostgreSQL: 256MB 스토리지만 제공
- 처음 활성화 후 실제 사용 요금 발생 가능

**AI_SYS에 적합하지 않음** (pgvector 미지원, 스토리지 부족)

---

### 옵션 4: 자가 호스팅 - 완전 무료

**기존 컴퓨터 활용 (영구 무료)**:

#### 4.1 방법 A: Mac mini / 기존 Mac 활용

**장점**:
- 완전 무료 (초기 비용 없음)
- 영구 무료 (전기료 제외)
- 자유도 높음

**단점**:
- 24/7 켜야 함 (전기료 ~$30-50/월)
- 인터넷 안정성 필요
- 공인 IP 또는 Dynamic DNS 필요
- 집 인터넷으로 프로덕션 서버 운영 (권장 안 함)

**설정 (macOS)**:

```bash
# 1) 터미널에서 지속적으로 실행
cd /Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM

# 2) Docker Compose 시작
docker compose up -d --build

# 3) 백그라운드에서 실행되도록 LaunchAgent 설정
cat > ~/Library/LaunchAgents/com.aisys.backend.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.aisys.backend</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/docker-compose</string>
        <string>-f</string>
        <string>/Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM/docker-compose.yml</string>
        <string>up</string>
        <string>-d</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/aisys-backend.log</string>
    <key>StandardOutPath</key>
    <string>/tmp/aisys-backend.log</string>
</dict>
</plist>
EOF

# 4) 로드
launchctl load ~/Library/LaunchAgents/com.aisys.backend.plist

# 5) 상태 확인
launchctl list | grep aisys
```

#### 4.2 방법 B: Raspberry Pi 5 (~$60 초기 비용)

**장점**:
- 초기 비용만 ~$60
- 월 전기료 ~$5-10
- 영구 사용 가능

**단점**:
- 초기 하드웨어 비용
- 성능 제한 (동시 사용자 10-20명)

#### 4.3 방법 C: 클라우드 VPS (~$3-5/월) - Linode, DigitalOcean

**DigitalOcean Droplet** (가장 저렴):
- **가격**: 월 $5 (1GB RAM, 25GB SSD)
- **OS**: Ubuntu 24.04 LTS
- **설정**: 위의 "Step 2: EC2 배포"와 동일

**설정 방법**:
```bash
# DigitalOcean Droplet 생성 후
ssh root@<DROPLET_IP>

# EC2 명령과 동일하게 실행 (Step 2 참조)
```

---

### 옵션 비교표

| 옵션 | 초기 비용 | 월간 비용 | 1년 비용 | 사용 난이도 | 추천 |
|------|---------|---------|--------|----------|-----|
| **AWS (유료)** | $0 | ~$120 | ~$1,440 | 중간 | ⭐⭐⭐ 프로덕션 |
| **AWS Free Tier** | $0 | $0 (1년), 이후 ~$30 | $0 | 중간 | ⭐⭐⭐ 최고 |
| **Render** | $0 | $0-10 | $0-120 | 낮음 | ❌ 부족 |
| **자가 호스팅** (Mac) | $0 | ~$40 (전기) | ~$480 | 높음 | ⚠️ 테스트용 |
| **Raspberry Pi 5** | $60 | ~$8 (전기) | ~$156 | 높음 | ⚠️ 취미 프로젝트 |
| **DigitalOcean VPS** | $0 | $5 | $60 | 중간 | ⭐⭐ 예산 친화 |

---

## 무료 방법 선택 가이드

### 🏆 가장 추천: AWS Free Tier (1년 무료)

**이유**:
1. 완전 무료 (1년)
2. 프로덕션 수준의 성능
3. AI_SYS에 최적화된 리소스 (t2.micro 충분)
4. 1년 후 저렴한 옵션으로 전환 가능

**시작 방법**:
- AWS 회원가입: https://aws.amazon.com/
- 이 가이드의 **Step 1-5 따라서 EC2 t2.micro + RDS db.t3.micro 선택**
- 예상 비용: **$0/월 (1년), 이후 ~$20-30/월**

### 💰 예산 친화적: DigitalOcean ($5/월)

**이유**:
1. 저렴함 ($5/월)
2. 무제한 사용 (sleep 없음)
3. 설정 간단

**단점**:
1. AWS보다 느림
2. 자동 백업 별도 비용

**시작 방법**:
```bash
# DigitalOcean에서 $5 Droplet 생성
# 그 후 Step 2 명령어 실행 (동일함)
```

### 🔧 완전 무료 (하지만 권장 ❌): 자가 호스팅

**적합한 경우**:
- 개발/테스트용
- 사용자가 적음 (<10명)

**부적합한 경우**:
- 실제 앱 배포
- 24/7 안정성 필요
- 많은 사용자

---

## 배포 체크리스트

- [ ] AWS 계정 생성 및 AWS CLI 구성
- [ ] RDS PostgreSQL 인스턴스 생성 및 초기화
- [ ] EC2 인스턴스 생성 및 보안 그룹 설정
- [ ] 도메인 등록 (Route 53 또는 외부)
- [ ] SSL 인증서 (ACM) 발급
- [ ] ALB 또는 Nginx 설정
- [ ] 도메인과 리소스 연결 (Route 53)
- [ ] iOS 앱 NetworkService.swift 수정
- [ ] GitHub Actions CI/CD 설정
- [ ] 전체 엔드-투-엔드 테스트 (앱 → API → DB)
- [ ] 모니터링 및 로깅 설정
- [ ] 백업 및 재해복구 계획 수립

---

## 다음 단계

1. **AWS 계정 생성**: https://aws.amazon.com/
2. **도메인 구매**: Route 53 또는 외부 호스팅
3. **이 가이드의 Step 1-5를 순서대로 실행**
4. **iOS 앱 배포**: TestFlight → App Store
5. **프로덕션 모니터링 시작**

---

**문의사항?** 각 Step별로 상세 설명이 필요하면 알려주세요.
