#!/usr/bin/env bash
# Start a loopback-only OpenAI-compatible llama.cpp server for KanaAI.
# This script never downloads a model.
set -euo pipefail

MODEL_PATH="${1:-${KANA_AI_MODEL_FILE:-}}"
HOST="127.0.0.1"
PORT="${KANA_AI_PORT:-8080}"
CONTEXT="${KANA_AI_CONTEXT:-2048}"
THREADS="${KANA_AI_THREADS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

if [[ -z "$MODEL_PATH" ]]; then
  cat >&2 <<'EOF'
Usage: scripts/run-local-model.sh /path/to/model.gguf
Set KANA_AI_MODEL_FILE to avoid passing the path.
KanaAI does not download model weights automatically.
EOF
  exit 2
fi
if [[ ! -f "$MODEL_PATH" ]]; then
  printf 'Model file not found: %s\n' "$MODEL_PATH" >&2
  exit 2
fi
if ! command -v llama-server >/dev/null 2>&1; then
  printf '%s\n' 'llama-server was not found. Install/build llama.cpp separately.' >&2
  exit 127
fi

exec llama-server \
  -m "$MODEL_PATH" \
  --host "$HOST" \
  --port "$PORT" \
  -c "$CONTEXT" \
  -np 1 \
  -t "$THREADS" \
  --jinja \
  --reasoning off
