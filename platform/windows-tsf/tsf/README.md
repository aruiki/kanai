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
       -> KanaAiSupplementalModel (inert until a trusted TSF owner binds)
```

The pinned TIP owns COM activation, TSF sinks, composition, preedit,
conventional candidate UI, learning, secure-mode activation, and profile
registration.

KanaAI uses upstream's server-side `SupplementalModelInterface` as the
integration location. The installed model is inert by default: a trusted TSF
session owner must obtain the process-global model, start the bounded worker
with `MakePipeRerankTransport`, and bind a regular `SessionBinding` carrying
`sessionId`, `generation`, and `FieldClass`. `PostCorrect` then only enqueues a
bounded candidate snapshot; the worker performs the named-pipe I/O and a later
matching `PostCorrect` applies only an exact, still-current permutation.
Password/protected bindings invalidate the capability and produce baseline
behavior. The server-side `SessionHandler` hook now supplies the binding and
starts the worker, but the real TIP registration, model runtime, and Windows
application journey are still unverified; this source worker is not a
registered or installable Windows beta by itself.

The staged Windows path configures the model in `Modules::Init` with
`MakePipeRerankTransport(250)`. The trusted `SessionHandler` advances a
per-session generation before `SEND_KEY`/`SEND_COMMAND`; a disabled TSF context
adds the content-free `kanai.protected` marker. `PostCorrect` is the only path
that submits candidate work, and it performs no I/O. `PipeBrokerClient` is a
separate Windows-only target so a key/preedit callback cannot accidentally call
the synchronous pipe methods. It verifies the broker process image by default;
installations with a different executable name must set
`KANAI_AI_TSF_SERVER_IMAGE`, and the broker can pin the client with
`KANAI_AI_TSF_CLIENT_IMAGE`.

## Owned files

- `host_overlay/engine/kanai_ai/`: opt-in supplemental model worker, exact
  projection of KanaAI's `KBF1`/JSON/auth/rerank DTOs, Windows named-pipe
  client, and bounded rank policy.
- `patches/0001-install-kanai-supplemental-model.patch`: installs the opt-in
  model/worker in the disposable upstream `engine` target.
- `patches/0002-kanai-tsf-identity.patch`: assigns the provisional KanaAI
  text-service/profile GUIDs in the disposable staged copy; it is not approval
  to publish or register the identity.
- `patches/0003-session-generation-binding.patch`: connects the trusted
  server-side session/generation/field marker before Mozc invokes the model.
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

The Rust `kanai-broker` source target now includes a concurrent Windows
named-pipe listener, authenticated peer checks, a rerank-only session
preparation operation, and a session/generation/privacy queue, with a Unix
local integration listener for WSL. Its Linux/Mozc lab backend uses one bounded
multi-session bridge process and retains the old one-shot compatibility facade.
The native server hook and live candidate-result source path are included, but
registration, model/runtime packaging, real Windows input, UIA, signing, and
release evidence remain incomplete. This source slice is not a finished beta.
