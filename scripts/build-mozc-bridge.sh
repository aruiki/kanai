#!/usr/bin/env bash
# Build the pinned Mozc bridge without downloading a language model.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOZC_DIR="$ROOT_DIR/third_party/mozc"
PATCH_FILE="$ROOT_DIR/patches/mozc-kanai-bridge.patch"
PATCH_APPLIED_HERE=0

cleanup() {
  if [[ "$PATCH_APPLIED_HERE" == 1 ]]; then
    if ! git -C "$MOZC_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
      printf '%s\n' 'Failed to verify temporary Mozc bridge patch cleanup.' >&2
      return 1
    fi
    git -C "$MOZC_DIR" apply --reverse "$PATCH_FILE" >/dev/null
  fi
}
trap cleanup EXIT

if [[ ! -d "$MOZC_DIR/.git" && ! -f "$MOZC_DIR/WORKSPACE" ]]; then
  git -C "$ROOT_DIR" submodule update --init --recursive third_party/mozc
fi

if [[ -f "$PATCH_FILE" ]]; then
  if git -C "$MOZC_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    printf '%s\n' 'Mozc bridge patch is already applied.'
  elif git -C "$MOZC_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$MOZC_DIR" apply "$PATCH_FILE"
    PATCH_APPLIED_HERE=1
  else
    printf '%s\n' 'Mozc checkout does not match the reproducible bridge patch; refusing to build local changes.' >&2
    printf '%s\n' 'Reset third_party/mozc or reconcile patches/mozc-kanai-bridge.patch first.' >&2
    exit 1
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

cleanup
trap - EXIT
printf 'Mozc bridge built at %s\n' "$MOZC_DIR/src/bazel-bin/kanai/kanai_mozc_bridge"
