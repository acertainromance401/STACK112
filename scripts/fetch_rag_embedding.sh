#!/bin/bash
set -euo pipefail

root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
destination="$root/code/ios/AISYSApp/Resources/multilingual-e5-base-Q8_0.gguf"
expected="1629184be879a108e16cceef62f7a0fedfff4eefb81cd734d646f8f404b85cdc"
url="https://huggingface.co/yixuan-chia/multilingual-e5-base-gguf/resolve/8a6f6cb284d54c798cc364ba497c976fbb8fe6bc/multilingual-e5-base-Q8_0.gguf"

if [[ -f "$destination" ]]; then
    printf '%s  %s\n' "$expected" "$destination" | shasum -a 256 -c -
    exit 0
fi

temporary="$(mktemp "${TMPDIR:-/tmp}/stack112-e5.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
curl --fail --location --retry 2 --proto '=https' --proto-redir '=https' \
    --output "$temporary" "$url"
printf '%s  %s\n' "$expected" "$temporary" | shasum -a 256 -c -
mv -n -- "$temporary" "$destination"
printf '%s  %s\n' "$expected" "$destination" | shasum -a 256 -c -
printf 'Verified embedding model: %s\n' "$destination"
