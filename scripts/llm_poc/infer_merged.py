#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from pathlib import Path
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

merged_dir = Path('/Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM/scripts/llm_poc/outputs/merged-model')
base_model_name = 'gpt2'

print('Loading merged model...')
torch.set_num_threads(1)
torch.set_num_interop_threads(1)
model = AutoModelForCausalLM.from_pretrained(str(merged_dir), device_map='cpu')
model.eval()

tokenizer = AutoTokenizer.from_pretrained(str(merged_dir), use_fast=False)
if tokenizer.pad_token_id is None:
    tokenizer.pad_token = tokenizer.eos_token

prompt = '다음 판례를 한 문장으로 요약해줘.\n\n사건번호: 2021가합12345. 피고인이 슈퍼마켓에서 물건을 몰래 가져가서 소지하다가 적발되었다. 피고인은 도난 의도가 있었음을 인정했다.'
inputs = tokenizer(prompt, return_tensors='pt')

with torch.no_grad():
    output_ids = model.generate(
        **inputs,
        max_new_tokens=24,
        do_sample=False,
        temperature=0.0,
        pad_token_id=tokenizer.eos_token_id,
        use_cache=False,
    )

print('\n=== Inference Result ===')
print(tokenizer.decode(output_ids[0], skip_special_tokens=True))
