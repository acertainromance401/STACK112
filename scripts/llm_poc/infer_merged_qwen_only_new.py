#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from pathlib import Path
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

merged_dir = Path('/Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM/scripts/llm_poc/outputs/qwen25-05b-merged')

print('Loading merged model...')
torch.set_num_threads(1)
torch.set_num_interop_threads(1)
model = AutoModelForCausalLM.from_pretrained(str(merged_dir), device_map='cpu')
model.eval()

tokenizer = AutoTokenizer.from_pretrained(str(merged_dir), use_fast=False)
if tokenizer.pad_token_id is None:
    tokenizer.pad_token = tokenizer.eos_token

prompt = '다음 판례를 한 문장으로 요약해줘.\n\n사건번호: 2021가합12345. 피고인이 슈퍼마켓에서 물건을 몰래 가져가서 소지하다가 적발되었다. 피고인은 도난 의도가 있었음을 인정했다.'
messages = [
    {'role': 'system', 'content': '당신은 정확하고 간결하게 답하는 한국어 AI 어시스턴트입니다.'},
    {'role': 'user', 'content': prompt},
]
chat_prompt = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
inputs = tokenizer(chat_prompt, return_tensors='pt')
source_length = inputs['input_ids'].shape[1]

with torch.no_grad():
    output_ids = model.generate(
        **inputs,
        max_new_tokens=48,
        do_sample=False,
        pad_token_id=tokenizer.eos_token_id,
        use_cache=False,
    )

new_tokens = output_ids[0][source_length:]
print('\n=== Generated Continuation ===')
print(tokenizer.decode(new_tokens, skip_special_tokens=True))
