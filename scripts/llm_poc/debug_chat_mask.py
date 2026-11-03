#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from pathlib import Path
from datasets import load_dataset
from transformers import AutoTokenizer

train_file = Path('/Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM/scripts/llm_poc/korean_instruct_expanded_700.jsonl')
model_name_or_path = 'Qwen/Qwen2.5-0.5B-Instruct'

tokenizer = AutoTokenizer.from_pretrained(model_name_or_path, use_fast=False)
if tokenizer.pad_token_id is None:
    tokenizer.pad_token = tokenizer.eos_token

dataset = load_dataset('json', data_files={'train': str(train_file)}, split='train')
example = dataset[0]
instr = example.get('instruction', '') or ''
inp = example.get('input', '') or ''
out = example.get('output', '') or ''
user_text = instr if not inp else instr + '\n\n' + inp

prompt_messages = [
    {'role': 'system', 'content': '당신은 정확하고 간결하게 답하는 한국어 AI 어시스턴트입니다.'},
    {'role': 'user', 'content': user_text},
]
full_messages = prompt_messages + [{'role': 'assistant', 'content': out}]

prompt_text = tokenizer.apply_chat_template(prompt_messages, tokenize=False, add_generation_prompt=True)
full_text = tokenizer.apply_chat_template(full_messages, tokenize=False, add_generation_prompt=False)

prompt_enc = tokenizer(prompt_text, truncation=True, max_length=512)
full_enc = tokenizer(full_text, truncation=True, max_length=512)

labels = full_enc['input_ids'].copy()
prompt_len = min(len(prompt_enc['input_ids']), len(labels))
labels[:prompt_len] = [-100] * prompt_len

supervised_tokens = [x for x in labels if x != -100]
print('prompt_len=', prompt_len)
print('full_len=', len(full_enc['input_ids']))
print('masked_count=', sum(1 for x in labels if x == -100))
print('supervised_count=', len(supervised_tokens))
print('full_text_tail=')
print(full_text[-300:])
print('supervised_decoded=')
print(tokenizer.decode(supervised_tokens, skip_special_tokens=False))
