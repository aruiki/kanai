# KanaAI Phase 1 progress

**Last updated:** 2026-09-25
**Phase 1:** native Windows TSF Local AI Quality Alpha
**Overall technical progress:** **75%**
**Public beta readiness:** **0%** until a real TSF TIP is built, registered, and tested in desktop applications.

Progress is gate-based, not a count of source lines. A source skeleton, a
compile-only DLL, or a Workbench does not count as a usable beta.

## Gates

| Gate | Weight | Current | Evidence / next condition |
|---|---:|---:|---|
| Product contract and TSF/AI boundaries | 10% | 10% | Phase 1 is explicitly native TSF + bounded local AI |
| Pinned Mozc Windows x64 baseline | 20% | 20% | `//win32/tip:mozc_tip64` built successfully; PE32+ x64 DLL and SHA-256 recorded |
| Native TSF integration and registration | 20% | 20% | Patched server/TIP artifacts build and DLL load; PE-valid registration dry-run passes; real API/app tests remain |
| Rust broker and local AI quality path | 20% | 20% | Core fast policy/cache, broker framing/auth/generation, and async enhancement contracts pass; TSF wiring remains |
| Evaluation, recovery, and security tests | 20% | 5% | Offline quality/fallback harness exists; real TSF/app and model evaluation remain |
| Distribution and user-facing release contract | 10% | 0% | No artifact exists; packaging follows native test gates |
| **Total technical progress** | **100%** | **75%** | Next milestone: real Windows registration and application input smoke |

## Latest verified build evidence

- Target: `//win32/tip:mozc_tip64`
- Host: Windows x64, Visual Studio 2022 MSVC 19.44, Bazel 9.0.2
- Result: successful upstream pinned build, 802 actions, 156 seconds
- Artifact type: PE32+ DLL, x86-64
- SHA-256: `e1c60179607da5c135e1eac0bde6ffe24d61bad31349086cf86ffe896b92452f`
- KanaAI patched `mozc_server_win`: build completed successfully, 1270 actions, 304.9 seconds
- Patched server artifact: PE32+ x86-64 executable
- Patched server SHA-256: `e57a2df3c6f3cd6a518f38aafede130ea13129deb6667286af98b23617b26018`
- Registration/application smoke: DLL `LoadLibraryW` passed; PE32+ x64 and dependency dump passed
- Registration projection: x64 per-user dry-run passed with `TipDllValid=true`; no registry write performed
- Real `ITfInputProcessorProfiles::Register` probe: returned `E_FAIL` under the current non-admin WSL/Windows session; no keys retained
- A temporary KanaAI-GUID identity build also returned the same result, isolating the blocker to TSF registration authority/host policy rather than the DLL loader
- Remaining gate: approved KanaAI identity/resource patch, elevated or supported per-user TSF API/profile registration, and desktop input tests


The current two-hour target is a **Windows x64 technical alpha**, not a public
beta claim. The time-boxed critical path is:

- **T+0–30 min:** finish the pinned Mozc Windows x64 build and record the
  concrete artifact or blocker;
- **T+30–60 min:** load/register the TIP in a controlled Windows smoke host;
- **T+60–90 min:** connect the Rust bounded-quality hook with Mozc fallback;
- **T+90–120 min:** run preedit/candidate/commit, timeout, and unload smoke
  tests, then publish the evidence and remaining blockers.

If the TSF DLL cannot be built and exercised in this environment, the result
is reported as a blocker rather than being called a beta. x86, full UIA,
installer/signing, exhaustive Office/Edge tests, and ATOK-level quality remain
post-checkpoint gates.
## Reporting rule

Development follows [`DEVELOPMENT_DIRECTIVE.md`](DEVELOPMENT_DIRECTIVE.md):
full-power continuous work, direct integration of completed agent results, and
no source-only success claims. Progress updates are posted at meaningful
checkpoints, not on a false real-time timer. Each update includes the
percentage, evidence, blockers, and next action. Percentages separate technical
progress from release readiness so a source scaffold cannot be mistaken for a
usable IME.

## After Phase 1

Phase 1 completion is the start of the quality loop, not the end of the
project. The continuing loop is:

1. collect Mozc baseline and KanaAI quality metrics;
2. analyze misses and regressions by composition, segmentation, candidate,
   learning, and latency class;
3. improve the local ranker/policy or permitted Mozc configuration;
4. rerun the fixed evaluation and real-application tests; and
5. promote only measured improvements.

No ATOK proprietary data or implementation is used. The long-term quality
reference is a mature Japanese IME experience, evaluated against reproducible
KanaAI baselines.
