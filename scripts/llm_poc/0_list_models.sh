#!/usr/bin/env bash
set -euo pipefail

# 간단한 모델 파일 검사 스크립트
# 사용: ./0_list_models.sh

echo "Searching for .gguf models in project bundle path and repo models folders..."

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE_SEARCH_PATH="$PROJECT_ROOT/code/ios/AISYSApp/Sources"
DOCUMENTS_MODELS_PATH="$PROJECT_ROOT/Documents/models"

echo "\nBundle path: $BUNDLE_SEARCH_PATH"
find "$BUNDLE_SEARCH_PATH" -maxdepth 1 -type f -name "*.gguf" -print || true

echo "\nRepo Documents/models path: $DOCUMENTS_MODELS_PATH"
if [ -d "$DOCUMENTS_MODELS_PATH" ]; then
  find "$DOCUMENTS_MODELS_PATH" -type f -name "*.gguf" -print || true
else
  echo "(not found)"
fi

echo "\nAll gguf files under project (recursively):"
find "$PROJECT_ROOT" -type f -name "*.gguf" -print || true

echo "\nDone."
