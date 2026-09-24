#!/usr/bin/env bash
# Verify the third-party source boundary before publishing an artifact.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOZC_DIR="$ROOT_DIR/third_party/mozc"

if [[ ! -f "$MOZC_DIR/LICENSE" || ! -f "$MOZC_DIR/src/data/dictionary_oss/README.txt" ]]; then
  printf '%s\n' 'Mozc submodule or its license/dictionary notice is missing.' >&2
  exit 1
fi

PATCH_FILE="$ROOT_DIR/patches/mozc-kanai-bridge.patch"
if [[ ! -f "$PATCH_FILE" ]]; then
  printf '%s\n' 'Mozc bridge patch is missing.' >&2
  exit 1
fi
if ! git -C "$MOZC_DIR" apply --check "$PATCH_FILE" 2>/dev/null \
  && ! git -C "$MOZC_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
  printf '%s\n' 'Mozc bridge patch does not match the pinned checkout.' >&2
  exit 1
fi

MOZC_COMMIT="$(git -C "$MOZC_DIR" rev-parse HEAD)"
if GITLINK="$(git ls-tree HEAD third_party/mozc 2>/dev/null | awk '{print $3}')" \
  && [[ -n "$GITLINK" && "$GITLINK" != "$MOZC_COMMIT" ]]; then
  printf 'Mozc gitlink mismatch: expected %s, found %s\n' "$GITLINK" "$MOZC_COMMIT" >&2
  exit 1
fi

printf 'Mozc commit: %s\n' "$MOZC_COMMIT"
printf '%s\n' 'Mozc bridge patch: verified'
printf '%s\n' 'Mozc code license: BSD-3-Clause (upstream Google-authored code)'
printf '%s\n' 'Mozc dictionary/data: mixed; preserve the upstream notices.'
printf '%s\n' 'No model weights are bundled by this repository.'
