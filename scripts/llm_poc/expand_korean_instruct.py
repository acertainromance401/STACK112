#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Expand the Korean instruction dataset with synthetic PoC samples.

Usage:
  /opt/anaconda3/bin/python3 scripts/llm_poc/expand_korean_instruct.py \
    --input scripts/llm_poc/korean_instruct_200.jsonl \
    --output scripts/llm_poc/korean_instruct_expanded_700.jsonl \
    --target-count 700
"""
from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

SUMMARY_TOPICS = [
    "AI 모델 평가",
    "앱 업데이트 검토",
    "법률 판례 요약",
    "회의록 정리",
    "기능 요구사항 정리",
    "오류 로그 분석",
    "데이터 품질 점검",
    "배포 체크리스트",
    "사용자 문의 응대",
    "제품 소개",
]

REWRITE_PAIRS = [
    ("회의 일정이 변경 되었으니 참고 바랍니다.", "회의 일정이 변경되었으니 참고 바랍니다."),
    ("문서를 확인 후 회신 부탁드립니다.", "문서를 확인한 후 회신 부탁드립니다."),
    ("아래 내용 검토 바랍니다.", "아래 내용을 검토해 주세요."),
    ("이번주 내로 피드백 주세요.", "이번 주 안에 피드백을 주세요."),
]

QA_BANK = [
    ("한국에서 직장인이 점심으로 자주 먹는 메뉴를 하나만 말해줘.", "한국에서는 직장인이 점심으로 김치찌개나 백반을 자주 먹습니다."),
    ("LoRA를 쓰는 이유를 한 문장으로 설명해줘.", "LoRA는 전체 모델을 크게 바꾸지 않고도 적은 비용으로 특정 도메인 성능을 개선하기 위해 사용합니다."),
    ("한국어 토크나이저가 중요한 이유는?", "한국어는 조사와 어미 변화가 많아 토큰화 효율이 성능과 비용에 크게 영향을 줍니다."),
    ("모델을 교체하기 전에 먼저 확인할 것은?", "모델 라이선스, 토크나이저 호환성, 메모리 요구량, 앱 로드 경로를 먼저 확인해야 합니다."),
]

EXTRACTION_TOPICS = [
    "모델명",
    "배치 크기",
    "출력 경로",
    "학습 데이터 개수",
    "학습 목적",
    "에러 메시지",
]

PROMPT_FRAGMENTS = [
    "다음 내용을",
    "아래 문장을",
    "이 문서를",
    "다음 로그를",
    "아래 정보를",
]

def load_jsonl(path: Path):
    records = []
    with path.open('r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def write_jsonl(path: Path, records):
    with path.open('w', encoding='utf-8') as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False) + '\n')


def make_summary_example(rng: random.Random, idx: int):
    topic = rng.choice(SUMMARY_TOPICS)
    detail = rng.choice([
        "핵심만 두 문장으로 요약해줘.",
        "한 문장으로 요약해줘.",
        "세 줄 이내로 정리해줘.",
    ])
    input_text = rng.choice([
        f"{topic}: 최근 실험에서는 토크나이저 효율이 좋아질수록 같은 입력을 더 적은 토큰으로 처리할 수 있었다. 또한 LoRA는 전체 파라미터를 바꾸지 않아 학습 비용이 줄었다.",
        f"{topic}: 새로운 모델 후보를 평가할 때는 메모리 사용량, 한국어 이해력, 추론 속도를 함께 비교해야 한다. 단일 지표만 보면 잘못된 결론을 낼 수 있다.",
        f"{topic}: 여러 샘플을 검토한 결과, 지시문이 구체적일수록 모델 응답이 안정적이었다. 모호한 프롬프트는 답변 품질의 편차를 키웠다.",
    ])
    output_text = rng.choice([
        f"{topic}의 핵심은 {detail}",
        f"{topic}에서는 지시문 품질과 자원 효율을 함께 봐야 한다.",
        f"{topic}의 중요한 포인트만 추려서 간단히 설명했다.",
    ])
    return {
        'instruction': f"{rng.choice(PROMPT_FRAGMENTS)} {detail}",
        'input': input_text,
        'output': output_text,
    }


def make_rewrite_example(rng: random.Random):
    src, tgt = rng.choice(REWRITE_PAIRS)
    return {
        'instruction': '더 자연스러운 한국어로 고쳐줘.',
        'input': src,
        'output': tgt,
    }


def make_qa_example(rng: random.Random):
    question, answer = rng.choice(QA_BANK)
    return {
        'instruction': '질문에 간단명료하게 답해줘.',
        'input': question,
        'output': answer,
    }


def make_extraction_example(rng: random.Random):
    topic = rng.choice(EXTRACTION_TOPICS)
    if topic == '모델명':
        input_text = '모델명은 Qwen2.5-0.5B-Instruct이고 출력 경로는 outputs/lora-checkpoint이다.'
        output_text = '모델명: Qwen2.5-0.5B-Instruct'
    elif topic == '배치 크기':
        input_text = 'per_device_train_batch_size는 1이고 gradient_accumulation_steps는 8로 설정했다.'
        output_text = '배치 크기: 1'
    elif topic == '출력 경로':
        input_text = '학습 결과는 /Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM/scripts/llm_poc/outputs/lora-checkpoint에 저장한다.'
        output_text = '출력 경로: /Users/acertainromance401/Desktop/AI_SYS/AI_SYS_TEAM/scripts/llm_poc/outputs/lora-checkpoint'
    elif topic == '학습 데이터 개수':
        input_text = '학습 데이터는 현재 137개이며 확장을 통해 더 늘릴 수 있다.'
        output_text = '학습 데이터 개수: 137개'
    elif topic == '학습 목적':
        input_text = '목표는 한국어 추론과 요약 품질을 높이는 것이다.'
        output_text = '학습 목적: 한국어 추론과 요약 품질 향상'
    else:
        input_text = '오류 메시지: target_modules를 자동 탐지하지 못했습니다. 수동으로 지정하세요.'
        output_text = '에러 메시지: target_modules를 수동 지정해야 함'
    return {
        'instruction': '아래에서 항목만 추출해줘.',
        'input': input_text,
        'output': output_text,
    }


def make_format_example(rng: random.Random):
    return {
        'instruction': '아래 내용을 bullet 3개로 정리해줘.',
        'input': rng.choice([
            '한국어 성능을 강화하려면 데이터 품질, 토크나이저 호환성, 모델 용량을 함께 봐야 한다.',
            'LoRA 실험은 작은 베이스 모델로 먼저 확인하고, 결과가 좋으면 더 강한 베이스로 옮겨가는 것이 좋다.',
            '모바일 배포는 메모리 요구량과 응답 속도를 함께 고려해야 한다.',
        ]),
        'output': rng.choice([
            '- 데이터 품질이 중요하다.\n- 토크나이저 호환성을 확인해야 한다.\n- 모델 용량을 함께 본다.',
            '- 작은 베이스로 먼저 검증한다.\n- 결과를 비교한다.\n- 필요하면 더 강한 베이스로 옮긴다.',
            '- 메모리 요구량을 확인한다.\n- 응답 속도를 측정한다.\n- 배포 전 로드 테스트를 한다.',
        ]),
    }


def build_examples(target_count: int, seed_records):
    rng = random.Random(42)
    examples = list(seed_records)
    generators = [make_summary_example, make_rewrite_example, make_qa_example, make_extraction_example, make_format_example]

    seen = {(item.get('instruction',''), item.get('input',''), item.get('output','')) for item in examples}
    index = 0
    while len(examples) < target_count:
        generator = generators[index % len(generators)]
        index += 1
        if generator is make_summary_example:
            candidate = generator(rng, index)
        else:
            candidate = generator(rng)
        key = (candidate['instruction'], candidate['input'], candidate['output'])
        if key in seen:
            continue
        seen.add(key)
        examples.append(candidate)
    return examples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--target-count', type=int, default=700)
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    seed_records = load_jsonl(input_path)
    expanded = build_examples(args.target_count, seed_records)
    write_jsonl(output_path, expanded)

    print(f'Loaded {len(seed_records)} seed records from {input_path}')
    print(f'Wrote {len(expanded)} records to {output_path}')
    print('First example:', expanded[0])
    print('Last example:', expanded[-1])

if __name__ == '__main__':
    main()
