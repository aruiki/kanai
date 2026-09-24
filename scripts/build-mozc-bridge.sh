#!/usr/bin/env bash
# Build the pinned Mozc bridge without downloading a language model.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOZC_DIR="$ROOT_DIR/third_party/mozc"
PATCH_FILE="$ROOT_DIR/patches/mozc-kanai-bridge.patch"

if [[ ! -d "$MOZC_DIR/.git" && ! -f "$MOZC_DIR/WORKSPACE" ]]; then
  git -C "$ROOT_DIR" submodule update --init --recursive third_party/mozc
fi

if [[ -f "$PATCH_FILE" ]]; then
  if git -C "$MOZC_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    printf '%s\n' 'Mozc bridge patch is already applied.'
  elif git -C "$MOZC_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$MOZC_DIR" apply "$PATCH_FILE"
  else
    printf '%s\n' 'Mozc bridge patch is already applied or the checkout has local changes.'
  fi
fi

if [[ -n "${BAZEL:-}" ]]; then
  :
elif command -v bazelisk >/dev/null 2>&1; then
  BAZEL="bazelisk"
elif [[ -x "$MOZC_DIR/bazel" ]]; then
  BAZEL="$MOZC_DIR/bazel"
elif command -v bazel >/dev/null 2>&1; then
  BAZEL="bazel"
else
  printf '%s\\n' 'Bazelisk is required. Install it or set BAZEL=/path/to/bazel.' >&2
  exit 127
fi

# The bridge target lives in the KanaAI package and uses the pinned
# SessionHandler/EngineFactory targets without changing upstream internals.
(cd "$MOZC_DIR/src" && "$BAZEL" build //kanai:kanai_mozc_bridge)

printf 'Mozc bridge built at %s\n' "$MOZC_DIR/src/bazel-bin/kanai/kanai_mozc_bridge"
