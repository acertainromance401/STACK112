#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_DIR="$ROOT_DIR/docs/wiki/pages"
OUT_DIR="$ROOT_DIR/docs/wiki/wiki-bundle"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cp "$SRC_DIR"/*.md "$OUT_DIR"/

cat <<EOF
Wiki bundle generated:
  $OUT_DIR
Files:
$(ls -1 "$OUT_DIR")
EOF
