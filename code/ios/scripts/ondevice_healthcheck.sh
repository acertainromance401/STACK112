#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install with: brew install xcodegen"
  exit 1
fi

xcodegen generate >/dev/null

DEST_NAME=$(xcodebuild -showdestinations -project AISYS.xcodeproj -scheme AISYSApp \
  | grep "platform:iOS Simulator" \
  | head -n 1 \
  | sed -E 's/.*name:([^,}]+).*/\1/' \
  | xargs)

if [[ -z "${DEST_NAME}" ]]; then
  echo "No iOS Simulator destination found"
  exit 1
fi

echo "[HC-1] Build check"
xcodebuild build \
  -project AISYS.xcodeproj \
  -scheme AISYSApp \
  -destination "platform=iOS Simulator,name=${DEST_NAME}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >/dev/null

echo "[HC-2] Unit test check"
xcodebuild test \
  -project AISYS.xcodeproj \
  -scheme AISYSApp \
  -destination "platform=iOS Simulator,name=${DEST_NAME}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >/dev/null

echo "On-device healthcheck passed"
