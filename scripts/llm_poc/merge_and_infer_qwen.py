#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from pathlib import Path
import os
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel

base_model_name = 'Qwen/Qwen2.5-0.5B-Instruct'
adapter_dir = Path('/Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM/scripts/llm_poc/outputs/qwen25-05b-lora')
merged_dir = Path('/Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM/scripts/llm_poc/outputs/qwen25-05b-merged')
merged_dir.mkdir(parents=True, exist_ok=True)

torch.set_num_threads(1)
torch.set_num_interop_threads(1)

print('Loading base model...')
base_model = AutoModelForCausalLM.from_pretrained(base_model_name, device_map='cpu')
print('Loading adapter...')
adapter_model = PeftModel.from_pretrained(base_model, str(adapter_dir), device_map='cpu')
print('Merging...')
merged_model = adapter_model.merge_and_unload()
merged_model.save_pretrained(str(merged_dir))

tokenizer = AutoTokenizer.from_pretrained(base_model_name, use_fast=False)
if tokenizer.pad_token_id is None:
    tokenizer.pad_token = tokenizer.eos_token
tokenizer.save_pretrained(str(merged_dir))
print('Merged files:', sorted(os.listdir(merged_dir)))

prompt = '다음 판례를 한 문장으로 요약해줘.\n\n사건번호: 2021가합12345. 피고인이 슈퍼마켓에서 물건을 몰래 가져가서 소지하다가 적발되었다. 피고인은 도난 의도가 있었음을 인정했다.'
inputs = tokenizer(prompt, return_tensors='pt')
with torch.no_grad():
    output_ids = merged_model.generate(
        **inputs,
        max_new_tokens=48,
        do_sample=False,
        temperature=0.0,
        pad_token_id=tokenizer.eos_token_id,
        use_cache=False,
    )
result = tokenizer.decode(output_ids[0], skip_special_tokens=True)
print('\n=== Inference Result ===')
print(result)
