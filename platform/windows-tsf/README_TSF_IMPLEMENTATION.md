# Native Windows TSF implementation: pinned-Mozc host plan

## Status and decision boundary

This is a source-buildable development seam, **not a public beta**. The target
host is the repository's pinned upstream Mozc checkout:

- path: `third_party/mozc`
- commit: `13c98988247aa711d99db9e348ec2a597d14b5cd`
- observed version: `3.34.6239-128-g13c989882`
- license: upstream BSD 3-Clause terms in `third_party/mozc/LICENSE`

No proprietary Google code or data is copied. Mature Google Japanese Input is
a quality/convenience reference only. All new integration source is under
`platform/windows-tsf/tsf/**`, plus this implementation note.

## Existing TSF host is preserved

The pinned upstream tree already supplies the native TSF architecture:

| Upstream file | Responsibility retained |
|---|---|
| `third_party/mozc/src/win32/tip/tip_class_factory.cc` | COM `IClassFactory` and class creation |
| `third_party/mozc/src/win32/tip/mozc_tip_main.cc` | `DllMain`, `DllGetClassObject`, `DllCanUnloadNow` |
| `third_party/mozc/src/win32/tip/tip_text_service.cc` | `ITfTextInputProcessorEx` (including `ITfTextInputProcessor`), `ITfKeyEventSink`, TSF source sinks, activation, and `ITfCompositionSink` |
| `third_party/mozc/src/win32/tip/tip_edit_session_impl.cc` | edit cookies, composition, preedit ranges, commit/cancel |
| `third_party/mozc/src/win32/tip/tip_ui_handler_conventional.cc` and `tip_ui_element_conventional.cc` | candidate/suggestion windows |
| `third_party/mozc/src/win32/base/tsf_profile.cc` | current OSS GUIDs and Japanese language ID |
| `third_party/mozc/src/win32/base/tsf_registrar.cc` | COM, language profile, and category registration |
| `third_party/mozc/src/win32/custom_action/*` and `src/win32/installer/*` | installer registration and runtime layout |

No file under `third_party/mozc/src/win32/tip` is replaced. The host audit in
`tsf/tests/verify_pinned_host.py` checks these contracts on every portable test
run.

## Narrow KanaAI integration seam

Pinned upstream provides
`third_party/mozc/src/engine/supplemental_model_interface.h` as the narrow
server-side extension point. The staged patch installs
`kanai::tsf::KanaAiSupplementalModel` there rather than adding TSF/COM code.

The current model is deliberately **inert by default**:

- a freshly installed `KanaAiSupplementalModel` reports unavailable;
- `PostCorrect()` only queues work after a trusted owner explicitly starts the
  bounded worker and binds a regular session;
- `RescoreResults()` remains a no-op;
- the worker calls the Windows named-pipe transport off the Mozc callback;
- password/protected bindings invalidate the capability and retain Mozc's
  baseline; and
- no key/preedit/realtime callback performs provider I/O.

The overlay now contains a real bounded asynchronous worker, a
`MakePipeRerankTransport` factory, a process-global model factory, an exact
live-result handoff, and a trusted server-side `SessionHandler` hook. A later
matching `PostCorrect` applies only an exact permutation of unchanged Mozc
candidates. The Windows TIP, installer, model runtime, and real application
lifecycle still require host validation; the source worker is not a registered
or installable beta.

## Exact upstream patch boundary

`platform/windows-tsf/tsf/patches/0001-install-kanai-supplemental-model.patch`
changes the disposable upstream `engine` target to install the opt-in model
and worker. It also removes the absent OSS `//supplemental_model` dependency
from the Windows select path; a Windows `enable_spellchecker` query must not
fail on a package absent from pinned OSS. `0003-session-generation-binding.patch`
adds the trusted `SessionHandler` generation/field hook and the content-free
protected-context marker in the TSF key path. Neither patch replaces the
upstream TSF shell.

`prepare-pinned-mozc.ps1` verifies the exact commit and clean tracked
submodule, exports a disposable tree with `git archive`, copies the
KanaAI-owned `kanai_ai` package, and applies the patch there. It never edits the
submodule. Portable tests run `git apply --check` against the pinned files.

## KanaAI broker boundary

The semantic contract is KanaAI's existing Rust crate:

- `crates/kanai-broker/src/frame.rs`: `KBF1 | u32 big-endian length | UTF-8 JSON`
- `crates/kanai-broker/src/protocol.rs`: versioned camelCase DTOs
- `crates/kanai-broker/src/transport.rs`: authentication boundary
- `crates/kanai-broker/src/enhancement.rs`: async, local, secure-field and
  fallback policy
- `crates/kanai-broker/src/broker.rs`: session/generation ownership

The TSF-owned C++ files project only the native framing/auth/
`rerankCandidates` boundary. They do not define a competing semantic protocol.
The exact details are in `tsf/metadata/broker-contract-v1.md`.

Key properties:

- default pipe: `\\.\pipe\KanaAI.TsfBroker.v1.<windows-session-id>`;
- same-session/current-user ACL and `PIPE_REJECT_REMOTE_CLIENTS` required;
- canonical auth handshake with a 32-byte `BCryptGenRandom` nonce;
- the public proof marker is not a secret; the server must validate the actual
  pipe client token/user/elevation;
- at most five existing Mozc candidates;
- no surrounding document/history text;
- 1 MiB canonical frame limit and 1..2000 ms native client deadline; and
- only `applied + adopted` exact-permutation responses may be applied.

The C++ pipe client is called only by the explicitly-started worker, never by
`PostCorrect` or another key/preedit callback. It is a bounded optional
transport, not a per-key LLM path.

## Files added under the owned TSF boundary

- `platform/windows-tsf/tsf/CMakeLists.txt`
- `platform/windows-tsf/tsf/README.md`
- `platform/windows-tsf/tsf/PHASE1_QUALITY_GATES.md`
- `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/BUILD.bazel`
- `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/broker_contract.h`
- `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/broker_contract.cc`
- `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/rank_policy.h`
- `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/rank_policy.cc`
- `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/pipe_broker_client.h`
- `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/pipe_broker_client.cc`
- `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/kanai_supplemental_model.h`
- `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/kanai_supplemental_model.cc`
- `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/kanai_supplemental_model_test.cc`
- `platform/windows-tsf/tsf/patches/0001-install-kanai-supplemental-model.patch`
- `platform/windows-tsf/tsf/patches/0003-session-generation-binding.patch`
- `platform/windows-tsf/tsf/scripts/prepare-pinned-mozc.ps1`
- `platform/windows-tsf/tsf/scripts/build-pinned-mozc.ps1`
- `platform/windows-tsf/tsf/metadata/broker-contract-v1.md`
- `platform/windows-tsf/tsf/metadata/tsf-integration.json`
- `platform/windows-tsf/tsf/tests/broker_contract_test.cc`
- `platform/windows-tsf/tsf/tests/rank_policy_test.cc`
- `platform/windows-tsf/tsf/tests/verify_pinned_host.py`

No Rust, package template, UI, Pages, workflow, or existing documentation file
is changed by this slice.

## Build prerequisites and commands

### Portable checks (Linux/WSL)

- CMake 3.24+
- C++20 compiler
- Python 3.10+
- initialized pinned Mozc submodule

```bash
cmake -S platform/windows-tsf/tsf -B /tmp/kanai-tsf-build -G Ninja \
  -DKANAI_TSF_BUILD_TESTS=ON
cmake --build /tmp/kanai-tsf-build
ctest --test-dir /tmp/kanai-tsf-build --output-on-failure
```

After preparing the disposable source tree, the focused upstream integration
test is:

```bash
cd <staged-mozc>/src
bazelisk test //engine/kanai_ai:kanai_supplemental_model_test \
  --test_output=errors
```

### x64 MSVC/Bazel host

Use 64-bit Windows 10/11, Visual Studio 2022 with MSVC v143 x64, Windows 11
SDK, ATL where required by pinned Bazel rules, Python 3.12+, Git, Bazelisk, and
`build_tools/update_deps.py` dependencies. Qt/WiX, installer packaging, x86,
signing, and full UIA work are explicitly deferred from this vertical slice.

Build the Rust broker executable separately on the Windows host:

```powershell
cargo build --release --locked --target x86_64-pc-windows-msvc -p kanai-broker
```

The resulting `kanai-broker.exe` owns the private pipe endpoint. The staged
server model now starts its bounded worker and obtains a generation binding
from `SessionHandler`, but do not copy the executable beside a registered TIP
and call that an end-user beta until the real Windows input, model, installer,
and recovery gates pass.

```powershell
# Visual Studio 2022 Developer PowerShell
pwsh -File platform/windows-tsf/tsf/scripts/prepare-pinned-mozc.ps1 `
  -MozcRoot third_party/mozc `
  -OutputDirectory C:\build\kanai-tsf-mozc

pwsh -File platform/windows-tsf/tsf/scripts/build-pinned-mozc.ps1 `
  -StageDirectory C:\build\kanai-tsf-mozc
```

Equivalent core commands in staged `src`:

```powershell
python build_tools/update_deps.py
bazelisk build //win32/tip:mozc_tip64 //server:mozc_server_win `
  --config=release_build --platforms=//:windows-x86_64
```

The slice intentionally stops at `//win32/tip:mozc_tip64` and
`//server:mozc_server_win`. Qt renderer packaging, `//win32/installer:installer`,
and KanaAI registration are deferred. A two-target compile is necessary but is
not proof of a runnable/installable TSF.

## Registration boundary

The staged upstream OSS build currently registers:

- text service `{10A67BC8-22FA-4A59-90DC-2546652C56BF}`
- profile `{186F700C-71CF-43FE-A00E-AACB1D9E6D3D}`
- Japanese `0x0411`

The separate current registration projection proposes KanaAI IDs:

- text service `{7E7B5C1E-6D3A-4F2C-9A0E-3F4B5D6C7E81}`
- profile `{F3C2B7A1-6D54-4E8B-9A10-2C7D8E9F0A12}`

Those IDs remain provisional. This patch does **not** replace upstream
`tsf_profile.cc` or display resources, so a source build must not be registered
as KanaAI until identity approval and coexistence/upgrade tests pass.

## Measurable Phase 1 gates

`platform/windows-tsf/tsf/PHASE1_QUALITY_GATES.md` defines baseline and AI runs
over the same corpus/candidate set. Required evidence:

- top-1/top-3/top-5, MRR, NDCG, and confidence intervals;
- candidate-set equality and target-slice improvement;
- key-to-preedit p95 with no broker call;
- explicit conversion p95 under a hard deadline;
- absent/busy/crashed/malformed/cancel broker fallback;
- learning isolation across AI rank changes;
- restart, repair, upgrade, and uninstall; and
- secure-field, privacy, and UIA matrices.

No measurements are claimed by this slice.

## Validation performed for this slice

- Portable CMake build plus all three CTest tests pass.
- The pinned-host audit and `git apply --check` pass against commit
  `13c98988247aa711d99db9e348ec2a597d14b5cd`.
- In a disposable pinned tree, Bazel 9.0.2 builds
  `//engine/kanai_ai:broker_contract`, `//engine/kanai_ai:rank_policy`, and
  upstream `//engine:modules`.
- `//engine/kanai_ai:kanai_supplemental_model_test` passes all three focused
  tests on Linux.
- MSVC 19.44 x64 with `/W4 /WX /permissive- /utf-8` compiles the broker
  contract and Windows named-pipe client. Only temporary CMake/MSBuild
  UNC/temp-directory warnings were emitted.
- Both PowerShell scripts pass the Windows PowerShell parser.

The Windows x64 Bazel targets themselves were not run in this WSL session.

## Blockers before a public beta

1. **Session/generation bridge:** the Rust broker now owns session/generation
   and secure-field admission in a bounded queue, but upstream
   `SupplementalModelInterface` still does not provide the trusted token or a
   live-result application point.
2. **Async executor:** a bounded latest-per-session queue and cancellation
   path exist in the Rust broker; a TSF handoff and cache lifecycle are not
   wired, so the installed model intentionally remains unavailable.
3. **Windows pipe server:** a source-built Tokio named-pipe listener with a
   protected DACL and OS process/session/user-token authenticator now exists;
   Windows runtime, ACL, reconnect, and application tests remain open.
4. **No Bazel host build evidence:** the x64 TIP/server build and full runtime
   still need a Windows runner with pinned dependencies.
5. **Model/backend:** no local bounded reranker or measured provider backend is
   included.
6. **KanaAI registration identity:** the staged TIP still carries upstream OSS
   GUIDs/resources; proposed KanaAI IDs are not approved or patched.
7. **Secure fields:** no complete password/secure-desktop/elevated/
   restricted-token/AppContainer matrix. No secure capability claim.
8. **UIA/candidate UI:** upstream UI is retained, but no KanaAI accessibility
   run has passed.
9. **Restart/lifecycle:** broker/server/Windows restart, repair, upgrade,
   uninstall, and orphan-process tests are pending.
10. **Architecture breadth:** this seam targets x64; x86 and mixed-process
    application coverage remain required for a mature beta.
11. **Quality/performance:** no top-k, p95, timeout/fallback, or learning
    corpus has met the proposed thresholds.
12. **Distribution:** signing, final identity, upgrades, uninstall, and publisher
    reputation remain unresolved.
