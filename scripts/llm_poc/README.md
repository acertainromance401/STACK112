LLM PoC: 후보 모델 목록 및 변환 가이드
=====================================

> 보관용 PoC 자료입니다. 이 디렉터리의 학습·병합·추론 실험은 현재 iOS 앱의 RAG 파일럿과 별개이며, 아래 후보 목록은 모델의 존재·호환성·한국어 우월성을 검증한 목록이 아닙니다.

## 저장소 포함 범위와 실행 상태

- 포함: 학습·병합·추론·토크나이저 점검 스크립트, 한국어 instruction JSONL, 평가 프롬프트, Colab 노트북과 안내 문서.
- 제외: `outputs/`의 모델 가중치, LoRA adapter, optimizer 상태와 체크포인트. 로컬 파일은 유지하며 [디렉터리별 ignore 규칙](.gitignore)으로 Git 추적에서 제외합니다.
- `korean_instruct_200.jsonl`의 실제 레코드는 **137개**입니다. 파일명의 200을 샘플 수로 보고하지 않습니다. `korean_instruct_expanded_700.jsonl`은 **700개**이며, 확장 스크립트는 합성 PoC 샘플을 생성합니다. 두 파일은 법률 전문가 검증 정답셋이 아닙니다.
- 일부 스크립트에는 과거 로컬 절대 경로가 남아 있습니다. 실행 전 데이터·adapter·병합 모델 경로를 현재 환경에 맞게 확인해야 합니다. 의존성 버전이 고정된 재현 패키지는 아닙니다.
- 저장된 노트북 출력은 과거 PoC 기록입니다. 이번 저장소 반영 과정에서는 Python·쉘 문법, JSONL 구조, 노트북 형식을 확인하며 모델 학습·다운로드·추론을 재실행하지 않습니다.
- 현재 앱의 실제 사용 모델과 판례 3건·9개 요청 결과는 [RAG 분석 보고서](../../docs/research/Execution_Log_Performance_Analysis_2026-11-03.md)에 있습니다. 이 디렉터리의 모델을 해당 실험에서 사용한 것으로 혼동하지 않습니다.

## 기존 후보·변환 작업 메모

목표: 현재 `Llama-3.2-1B-Instruct-Q4_K_M.gguf`(앱 번들 사용)와 유사한 용량대(약 1B)에서 한국어 성능이 더 우수한 후보를 조사하고, gguf 변환·양자화 후 앱에 배포하는 절차를 정리합니다.

1) 후보 모델(검토 대상으로 권장)
- Llama 2 (1B) 계열 — 기준선
- Vicuna/Alpaca 계열의 1B 파생 모델(한국어 파인튜닝된 커뮤니티 체크포인트가 있으면 우선 검토)
- KoLLaMA / 한국어 파인튜닝 커뮤니티 모델(가능하면 1B 변형)
- Mistral/Mixtral 소형(7B는 크나 1B 유사 파생체가 있으면 검토)
- Qwen 소형(공식 소형 버전 존재 시) — 한국어 성능 보고 다수

2) 변환·양자화 일반 절차 (요약)
- 1) HF checkpoint 다운로드: `git lfs` 또는 `huggingface-cli`로 모델을 로컬에 확보
- 2) (필요 시) 토크나이저 동봉 확인: `tokenizer.json`/`tokenizer.model`이 있는지 확인
- 3) HF -> gguf 변환: 여러 도구가 존재함
  - `llama.cpp` 툴(또는 gguf 프로젝트)의 변환 스크립트 사용: 예) `python convert-hf-to-gguf.py --model` (프로젝트별 사용법 상이)
  - oobabooga/gguf 변환 도구 사용 가능
- 4) 양자화: convert 단계에서 Q4_K_M 같은 옵션 설정하거나 `ggml_quantize` 도구로 양자화
- 5) 앱 교체 테스트: `Llama-3.2-1B...gguf` 파일을 백업하고 새 gguf 파일로 교체 후 앱에서 로드 테스트

3) 유의사항
- 라이선스: 모델 사용 허가(상업적/앱 번들 포함) 확인 필수
- 토크나이저 호환성: 베이스 토크나이저와 다르면 출력 문제가 발생할 수 있음
- 모바일 메모리: 양자화 수준에 따라 메모리 요구량이 달라짐(Q4_K_M 권장)

4) 참고 명령 예시
```bash
# HF 모델 다운로드 (예)
git lfs install
git clone https://huggingface.co/<model-repo>

# 변환(예, 툴에 따라 옵션이 다름)
python tools/convert-hf-to-gguf.py --model-dir ./model-repo --out ./model.gguf --quantize q4_k_m
```

5) 다음 단계 제안
- (자동화) `scripts/llm_poc/0_list_models.sh`로 프로젝트 내 gguf 파일 확인
- `token_compare.py`로 후보 토크나이저와 현재(또는 HF 기준 베이스) 토크나이저 비교
- 후보 모델 2~3개 선정 후 PoC: 변환 -> 양자화 -> 앱에서 로드 테스트 -> 품질 벤치
