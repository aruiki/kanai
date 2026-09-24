# KanaAI native Windows TSF integration seam

This directory defines a narrow integration over the repository's pinned
upstream Mozc checkout and KanaAI's canonical `kanai-broker` contract. It does
**not** contain a second COM/TIP shell and does not replace any file under
`third_party/mozc/src/win32/tip`.

## Runtime path

```text
Windows/TSF
  -> pinned upstream Mozc mozc_tip64.dll
  -> pinned Mozc client/broker and renderer/candidate UI
  -> patched mozc_server.exe
       -> compile-only KanaAiSupplementalModel (currently inert)
```

The pinned TIP owns COM activation, TSF sinks, composition, preedit,
conventional candidate UI, learning, secure-mode activation, and profile
registration.

KanaAI uses upstream's server-side `SupplementalModelInterface` only as an
integration location. Because that interface lacks the canonical broker's
per-context `sessionId`/`generation` and secure `FieldClass`, the installed
model reports unavailable and performs no I/O. A separate non-I/O
`ApplyRerankToResults` hunk represents the eventual async response boundary.

## Owned files

- `host_overlay/engine/kanai_ai/`: inert supplemental model, exact projection of
  KanaAI's `KBF1`/JSON/auth/rerank DTOs, Windows named-pipe client, and bounded
  rank policy.
- `patches/0001-install-kanai-supplemental-model.patch`: changes only upstream
  `engine/BUILD.bazel` and `engine/modules.cc` in a disposable staged copy.
- `scripts/prepare-pinned-mozc.ps1`: verifies the exact submodule commit,
  exports it, copies the KanaAI-owned overlay, and applies the patch without
  changing the submodule.
- `scripts/build-pinned-mozc.ps1`: invokes the pinned Bazel build for the x64
  TIP and patched server only.
- `metadata/tsf-integration.json`: machine-readable host, registration, patch,
  protocol, privacy, and readiness boundary.
- `metadata/broker-contract-v1.md`: exact native projection and unresolved
  session/auth/executor requirements.
- `PHASE1_QUALITY_GATES.md`: measurable baseline-versus-AI release gates.
- `tests/`: portable contract/policy tests and a host-contract audit.

## Portable checks

```bash
cmake -S platform/windows-tsf/tsf -B /tmp/kanai-tsf-build -G Ninja
cmake --build /tmp/kanai-tsf-build
ctest --test-dir /tmp/kanai-tsf-build --output-on-failure
```

Focused upstream test after staging:

```bash
cd <staged-mozc>/src
bazelisk test //engine/kanai_ai:kanai_supplemental_model_test \
  --test_output=errors
```

## Windows build

Run from a Visual Studio 2022 Developer PowerShell after installing the
prerequisites in `platform/windows-tsf/README_TSF_IMPLEMENTATION.md`.

```powershell
pwsh -File platform/windows-tsf/tsf/scripts/prepare-pinned-mozc.ps1 `
  -MozcRoot third_party/mozc `
  -OutputDirectory C:\build\kanai-tsf-mozc

pwsh -File platform/windows-tsf/tsf/scripts/build-pinned-mozc.ps1 `
  -StageDirectory C:\build\kanai-tsf-mozc
```

The broker server/session bridge is not included. This source slice is not
registered, signed, packaged, secure-field-validated, UIA-validated, or a
finished beta.
