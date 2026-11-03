Colab 가이드: LoRA 실습 (간단)
================================

준비: Google Colab Pro 이상의 GPU 권장을 권장합니다(예: A100/TPU 불필요). 아래는 일반 GPU(T4/P100/V100/RTX)에서 동작 가능한 절차입니다.

1) 런타임 설정
- 런타임 유형: GPU
- 런타임 하드웨어 가속기: GPU

2) 필수 패키지 설치
```bash
pip install -U transformers datasets accelerate peft bitsandbytes safetensors
```

3) 리포지토리 복제 또는 파일 업로드
- GitHub에서 리포지토리를 복제하거나 `korean_instruct_200.jsonl` 파일을 업로드합니다.

4) 예시 학습 실행
```bash
python /content/AI_SYS_TEAM/scripts/llm_poc/train_lora.py \
  --model_name_or_path <hf-base-model-or-local-path> \
  --train_file /content/AI_SYS_TEAM/scripts/llm_poc/korean_instruct_200.jsonl \
  --output_dir /content/lora-checkpoint \
  --per_device_train_batch_size 1 \
  --gradient_accumulation_steps 8 \
  --num_train_epochs 3
```

5) 결과 확인
- `output_dir`에 LoRA 체크포인트가 저장됩니다. Colab에서 Google Drive를 마운트하면 드라이브로 직접 저장할 수 있습니다.

주의사항
- 모델 체크포인트 용량과 GPU 메모리에 유의하세요. 1B 모델은 보통 12~16GB GPU에서 무난히 돌아갑니다. 3B 이상은 더 큰 GPU가 필요합니다.
- 라이선스: 사용하려는 베이스 모델의 라이선스(앱 내 배포 포함)를 반드시 확인하세요.

추가 팁
- 학습 데이터가 적을 경우(수백 샘플) epoch을 늘리거나 learning_rate를 낮춰 과적합을 방지하세요.
