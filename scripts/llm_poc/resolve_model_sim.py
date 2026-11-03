#!/usr/bin/env python3
import subprocess
import os
from pathlib import Path
from datetime import datetime

PROJECT_ROOT = Path(__file__).resolve().parents[2]
BUNDLE_PATH = PROJECT_ROOT / 'code' / 'ios' / 'AISYSApp' / 'Sources'
DOCUMENTS_MODELS = PROJECT_ROOT / 'Documents' / 'models'

model1BFileNames = [
    "llama-3.2-1b-instruct-q4_k_m.gguf",
    "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
]
model3BFileNames = [
    "llama-3.2-3b-instruct-q4_k_m.gguf",
    "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
    "Llama-3.2-3B-Instruct-Q4_K_L.gguf"
]
modelLargeFileNames = [
    "llama-3.1-8b-instruct-q4_k_m.gguf",
    "Llama-3.1-8B-Instruct-Q4_K_M.gguf"
]

def device_memory_gb():
    try:
        out = subprocess.check_output(['sysctl','-n','hw.memsize'])
        b = int(out.strip())
        return b // (1024**3)
    except Exception:
        # fallback
        return int(os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES') // (1024**3))

def device_tier():
    mem = device_memory_gb()
    if mem <= 8:
        return 'low'
    if mem <= 12:
        return 'balanced'
    return 'high'

def candidate_file_names():
    tier = device_tier()
    if tier == 'low':
        tierPreferred = model1BFileNames
    elif tier == 'balanced':
        tierPreferred = model3BFileNames + model1BFileNames
    else:
        tierPreferred = model3BFileNames + modelLargeFileNames + model1BFileNames

    configured = os.environ.get('LLAMA_MODEL_FILE','')
    result = []
    seen = set()
    for name in tierPreferred + [configured]:
        t = name.strip()
        if not t or t in seen:
            continue
        seen.add(t)
        result.append(t)
    return result

def resolve_from_bundle(candidates):
    for name in candidates:
        p = BUNDLE_PATH / name
        if p.exists():
            return p
    # any gguf in bundle
    files = list(BUNDLE_PATH.glob('*.gguf'))
    return files[0] if files else None

def resolve_from_documents(candidates):
    if not DOCUMENTS_MODELS.exists():
        return None
    for name in candidates:
        p = DOCUMENTS_MODELS / name
        if p.exists():
            return p
    files = sorted(DOCUMENTS_MODELS.glob('*.gguf'))
    return files[0] if files else None

def mod_date(path: Path):
    try:
        s = path.stat()
        return datetime.fromtimestamp(s.st_mtime)
    except Exception:
        return None

def is_documents_preferred(doc, bundle):
    ddate = mod_date(doc)
    bdate = mod_date(bundle)
    if not ddate:
        return False
    if not bdate:
        return True
    return ddate > bdate

def resolve_model(ignore_documents: bool):
    candidates = candidate_file_names()
    bundle = resolve_from_bundle(candidates)
    documents = resolve_from_documents(candidates)
    tierReason = f"device={device_tier()}/{device_memory_gb()}GB"

    if ignore_documents:
        return {
            'selectedURL': str(bundle) if bundle else None,
            'selectedSource': 'bundle' if bundle else None,
            'bundleURL': str(bundle) if bundle else None,
            'documentsURL': str(documents) if documents else None,
            'configuredFileName': candidates[0] if candidates else None,
            'selectionReason': ("Documents 무시 설정이 켜져 있고 번들 모델을 찾지 못했습니다. ("+tierReason+")" if bundle is None else "Documents 무시 설정이 켜져 있어 번들 모델을 선택했습니다. ("+tierReason+")")
        }

    if bundle and documents:
        if is_documents_preferred(documents, bundle):
            return {
                'selectedURL': str(documents), 'selectedSource': 'documents',
                'bundleURL': str(bundle), 'documentsURL': str(documents),
                'configuredFileName': candidates[0] if candidates else None,
                'selectionReason': "Documents 모델이 번들 모델보다 최신이라 선택했습니다. ("+tierReason+")"
            }
        else:
            return {
                'selectedURL': str(bundle), 'selectedSource': 'bundle',
                'bundleURL': str(bundle), 'documentsURL': str(documents),
                'configuredFileName': candidates[0] if candidates else None,
                'selectionReason': "번들 모델이 더 최신이거나 동일하여 선택했습니다. ("+tierReason+")"
            }

    if bundle:
        return {
            'selectedURL': str(bundle), 'selectedSource': 'bundle',
            'bundleURL': str(bundle), 'documentsURL': str(documents) if documents else None,
            'configuredFileName': candidates[0] if candidates else None,
            'selectionReason': "번들 모델만 발견되어 선택했습니다. ("+tierReason+")"
        }

    if documents:
        return {
            'selectedURL': str(documents), 'selectedSource': 'documents',
            'bundleURL': str(bundle) if bundle else None, 'documentsURL': str(documents),
            'configuredFileName': candidates[0] if candidates else None,
            'selectionReason': "번들 모델이 없어 Documents 모델을 선택했습니다. ("+tierReason+")"
        }

    return {
        'selectedURL': None, 'selectedSource': None, 'bundleURL': str(bundle) if bundle else None,
        'documentsURL': str(documents) if documents else None, 'configuredFileName': candidates[0] if candidates else None,
        'selectionReason': "번들과 Documents 어디에서도 GGUF 모델을 찾지 못했습니다. ("+tierReason+")"
    }

def pretty_print(res):
    print('Selected URL:', res['selectedURL'])
    print('Selected Source:', res['selectedSource'])
    print('Bundle URL:', res['bundleURL'])
    print('Documents URL:', res['documentsURL'])
    print('Configured File:', res['configuredFileName'])
    print('Reason:', res['selectionReason'])

if __name__ == '__main__':
    print('Device memory (GB):', device_memory_gb())
    print('\n-- ignoreDocuments = True --')
    pretty_print(resolve_model(ignore_documents=True))
    print('\n-- ignoreDocuments = False --')
    pretty_print(resolve_model(ignore_documents=False))
