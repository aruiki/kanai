#!/usr/bin/env bash
# Verify a user-provided GGUF file before it is used by KanaAI.
set -euo pipefail

MODEL="${1:-}"
EXPECTED_SHA="${2:-}"

if [[ -z "$MODEL" || ! -f "$MODEL" ]]; then
  printf 'Usage: %s model.gguf [sha256]\n' "$0" >&2
  exit 2
fi
if ! command -v sha256sum >/dev/null 2>&1; then
  printf '%s\n' 'sha256sum is required' >&2
  exit 127
fi

ACTUAL_SHA="$(sha256sum "$MODEL" | awk '{print $1}')"
printf 'file:   %s\n' "$MODEL"
printf 'bytes:  %s\n' "$(stat -c '%s' "$MODEL" 2>/dev/null || stat -f '%z' "$MODEL")"
printf 'sha256: %s\n' "$ACTUAL_SHA"
if [[ -n "$EXPECTED_SHA" && "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  printf '%s\n' 'SHA-256 mismatch' >&2
  exit 1
fi
printf '%s\n' 'This verifies bytes only. Verify the model license and upstream revision separately.'
