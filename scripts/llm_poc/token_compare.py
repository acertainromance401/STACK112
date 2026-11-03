#!/usr/bin/env python3
"""
토크나이저 비교 스크립트
사용법:
  pip install transformers sentencepiece safetensors
  python token_compare.py --model-a <hf-or-local-tokenizer-path> --model-b <hf-or-local-tokenizer-path> --text-file prompts.txt

설명: 동일 입력 텍스트에 대해 두 토크나이저의 토큰 수와 토큰 ID(선택)를 비교합니다.
"""
import argparse
from transformers import AutoTokenizer

def load_tokenizer(name_or_path):
    try:
        return AutoTokenizer.from_pretrained(name_or_path, use_fast=False)
    except Exception as e:
        print(f"Failed to load tokenizer {name_or_path}: {e}")
        raise

def compare(tokenizer_a, tokenizer_b, texts, show_examples=3):
    for i, t in enumerate(texts):
        toks_a = tokenizer_a(t, return_tensors=None, add_special_tokens=False)
        toks_b = tokenizer_b(t, return_tensors=None, add_special_tokens=False)
        ids_a = toks_a['input_ids'] if 'input_ids' in toks_a else tokenizer_a.encode(t, add_special_tokens=False)
        ids_b = toks_b['input_ids'] if 'input_ids' in toks_b else tokenizer_b.encode(t, add_special_tokens=False)

        print(f"\n--- Example {i+1} ---")
        print(f"Text: {t[:200]!r}")
        print(f"Tokenizer A tokens: {len(ids_a)}")
        print(f"Tokenizer B tokens: {len(ids_b)}")
        if i < show_examples:
            print(f"A ids: {ids_a}")
            print(f"B ids: {ids_b}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model-a', required=True)
    parser.add_argument('--model-b', required=True)
    parser.add_argument('--text-file', required=True)
    args = parser.parse_args()

    tokenizer_a = load_tokenizer(args.model_a)
    tokenizer_b = load_tokenizer(args.model_b)

    with open(args.text_file, 'r', encoding='utf-8') as f:
        texts = [l.strip() for l in f.readlines() if l.strip()][:20]

    compare(tokenizer_a, tokenizer_b, texts)

if __name__ == '__main__':
    main()
