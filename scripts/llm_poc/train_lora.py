#!/usr/bin/env python3
"""
LoRA 학습 스크립트 (HF + PEFT)

간단 사용법 예:
  pip install -U transformers datasets accelerate peft bitsandbytes safetensors
  python train_lora.py \
    --model_name_or_path huggingface/llama-1b-base \
    --train_file scripts/llm_poc/korean_instruct_200.jsonl \
    --output_dir outputs/lora-checkpoint \
    --per_device_train_batch_size 1 \
    --gradient_accumulation_steps 8 \
    --num_train_epochs 3

주의: Colab 또는 GPU 환경을 권장합니다. 로컬 M1은 매우 느릴 수 있습니다.
"""
import argparse
import os
from datasets import load_dataset
from transformers import (
    AutoTokenizer,
    AutoModelForCausalLM,
    Trainer,
    TrainingArguments,
)
from transformers import DataCollatorWithPadding

try:
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
except Exception:
    raise RuntimeError("peft 패키지가 필요합니다. pip install peft")

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--model_name_or_path', required=True)
    p.add_argument('--train_file', required=True)
    p.add_argument('--output_dir', required=True)
    p.add_argument('--target_modules', type=str, default=None,
                   help='Comma-separated list of target module name substrings for LoRA (e.g. "q_proj,k_proj,v_proj"). If omitted the script will try to auto-detect.')
    p.add_argument('--per_device_train_batch_size', type=int, default=1)
    p.add_argument('--gradient_accumulation_steps', type=int, default=8)
    p.add_argument('--learning_rate', type=float, default=2e-4)
    p.add_argument('--num_train_epochs', type=int, default=3)
    p.add_argument('--max_length', type=int, default=512)
    p.add_argument('--lora_r', type=int, default=8)
    p.add_argument('--lora_alpha', type=int, default=32)
    p.add_argument('--lora_dropout', type=float, default=0.05)
    return p.parse_args()


def main():
    args = parse_args()

    dataset = load_dataset('json', data_files={'train': args.train_file}, split='train')

    tokenizer = AutoTokenizer.from_pretrained(args.model_name_or_path, use_fast=False)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token

    def preprocess(example):
        # Merge instruction + input -> prompt; label is output
        instr = example.get('instruction','') or ''
        inp = example.get('input','') or ''
        out = example.get('output','') or ''
        prompt = instr + "\n\n" + inp
        # We train to generate the output given prompt; simple concat: prompt + output
        full = prompt + "\n\n" + out
        tok = tokenizer(full, truncation=True, max_length=args.max_length)
        tok['labels'] = tok['input_ids'].copy()
        return tok

    tokenized = dataset.map(preprocess, remove_columns=dataset.column_names, batched=False)

    # 모델 로드: bitsandbytes 4-bit 시도, 실패하면 일반 로드
    use_4bit = False
    model = None
    try:
        model = AutoModelForCausalLM.from_pretrained(
            args.model_name_or_path,
            load_in_4bit=True,
            device_map='auto',
        )
        use_4bit = True
        # k-bit 준비
        model = prepare_model_for_kbit_training(model)
    except Exception:
        print('4-bit 로드 실패, 일반 정밀도로 로드합니다. (GPU 권장)')
        model = AutoModelForCausalLM.from_pretrained(args.model_name_or_path, device_map='auto')

    # Helper: collect module names present in the model for diagnostics
    def _collect_module_names(m):
        return [name for name, _ in m.named_modules()]

    def _auto_detect_target_modules(m):
        # Candidate substrings to look for (ordered preference)
        candidate_groups = [
            ["q_proj", "k_proj", "v_proj", "o_proj", "down_proj", "up_proj"],  # LLaMA-like
            ["c_attn", "c_proj"],  # GPT-2 / GPT-NeoX style
            ["query_key_value", "dense"],  # BLOOM / GPT-NeoX style
            ["qkv_proj", "o_proj"],
        ]

        module_names = _collect_module_names(m)
        lowered = [n.lower() for n in module_names]

        for group in candidate_groups:
            found = []
            for cand in group:
                # check if any module name contains the candidate substring
                if any(cand in n for n in lowered):
                    found.append(cand)
            if found:
                return found

        # As a fallback, try to pick any of the known primitive names that exist
        primitives = ["q_proj", "k_proj", "v_proj", "o_proj", "c_attn", "c_proj", "query_key_value", "dense"]
        found = [p for p in primitives if any(p in n for n in lowered)]
        return found

    # Decide target_modules: explicit arg > auto-detect
    if args.target_modules:
        target_modules = [s.strip() for s in args.target_modules.split(',') if s.strip()]
    else:
        detected = _auto_detect_target_modules(model)
        if not detected:
            # show a short sample of module names to help user decide
            sample = _collect_module_names(model)[:200]
            msg = (
                "LoRA target modules could not be auto-detected for this model.\n"
                "Please pass --target_modules with a comma-separated list of module name substrings to target (examples: 'q_proj,k_proj,v_proj' or 'c_attn,c_proj').\n"
                "Available module name samples (first 200):\n\n" + "\n".join(sample)
            )
            raise ValueError(msg)
        target_modules = detected

    print('Using LoRA target modules:', target_modules)

    lora_config = LoraConfig(
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        target_modules=target_modules,
        lora_dropout=args.lora_dropout,
        bias="none",
        task_type="CAUSAL_LM",
    )

    model = get_peft_model(model, lora_config)

    training_args = TrainingArguments(
        output_dir=args.output_dir,
        per_device_train_batch_size=args.per_device_train_batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        learning_rate=args.learning_rate,
        num_train_epochs=args.num_train_epochs,
        fp16=not use_4bit,
        save_total_limit=3,
        logging_steps=50,
        save_steps=200,
        remove_unused_columns=False,
    )

    # Use a data collator for dynamic padding instead of passing tokenizer to Trainer
    data_collator = DataCollatorWithPadding(tokenizer, return_tensors="pt")

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=tokenized,
        data_collator=data_collator,
    )

    trainer.train()
    # LoRA 체크포인트 저장
    model.save_pretrained(args.output_dir)
    print('LoRA checkpoint saved to', args.output_dir)


if __name__ == '__main__':
    main()
