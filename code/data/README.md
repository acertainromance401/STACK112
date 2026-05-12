# AI_SYS Data Folder Standard

이 폴더는 판례 데이터 수집/정제/검수 산출물을 단계별로 관리하기 위한 작업 공간이다.

## 폴더 구조
- raw/: 수집 원문(원본) 저장
- normalized/: 전처리/정규화 완료 데이터
- reviewed/: 검수 완료, 게시 후보 데이터
- failed/: 파싱 실패/검수 반려 데이터
- manifests/: 수집/적재 이력 메타 파일(CSV, JSON)

## 운영 규칙
1. raw 데이터는 용량이 크고 민감할 수 있으므로 Git에 직접 커밋하지 않는다.
2. raw 데이터는 외부 저장소(S3, Drive, NAS 등) 보관을 우선하고, 본 저장소에는 manifest만 남긴다.
3. reviewed 데이터만 게시 파이프라인 입력으로 사용한다.
4. failed 데이터는 사유 코드를 함께 기록한다.

## 파일 네이밍 권장
- 원문: {case_number}_{source}_{yyyymmdd}.txt
- 정규화: {case_number}_normalized_v{n}.json
- 검수완료: {case_number}_reviewed_v{n}.json
- 실패로그: {batch_id}_{yyyymmdd}_errors.csv

## 최소 manifest 컬럼 예시
- collection_id
- case_number
- source_url
- source_type
- collected_at
- normalized_at
- review_status
- owner
- note

## 정책 확인 및 템플릿 문서
- 정책 체크 가이드: code/data/policy/SCourt_Policy_Check_Guide.md
- 문의 메일 템플릿: code/data/templates/scourt_permission_request_email.md
- 정책 로그 템플릿: code/data/manifests/templates/policy_check_log_template.csv
- 메타 수집 템플릿: code/data/manifests/templates/metadata_collection_template.csv
