# KanaAI beta and release contract

## Product decision

KanaAI targets the same broad product layer as a modern Windows Japanese IME:
a reliable Japanese conversion engine, personalization, and bounded local AI
assistance. The implementation is intentionally delivered in two stages.

### Beta: Windows Workbench / CLI

The first beta is an unsigned developer preview that lets a Windows user try:

- the pinned Mozc conversion engine;
- KanaAI's explainable local ranking and learning state;
- optional local semantic reranking and explicit writing assistance; and
- the same Rust session/API contracts that the future TSF shell will consume.

It opens a local browser workbench and/or a local CLI. It does **not** register
a TSF text service, add an IME to every Windows application, or replace the
Windows keyboard. Its purpose is to make the runtime and AI behavior usable
and testable before multiplying native ABI surfaces.

### Release: Windows TSF

The public Windows IME release must use TSF TIP DLLs for the supported
architectures and provide:

- preedit and candidate presentation;
- Space/Enter/commit/cancel behavior;
- focus teardown and recovery;
- secure-field policy;
- UI Automation and accessibility;
- x86/x64 registration and installer lifecycle; and
- signed/provenanced distribution.

The TSF shell is a thin adapter. Conversion, session state, ranking, learning,
and optional model policy stay in the shared Rust/Mozc core.

## Reference positioning

Google Japanese Input is a useful **product and integration reference** for a
polished Mozc-based Windows IME. It demonstrates the target user experience,
but KanaAI does not reproduce its proprietary binaries, private dictionaries,
cloud synchronization, UI, branding, or internal implementation.

KanaAI's differentiators are deliberate:

- local-first operation and inspectable state;
- explicit, bounded AI responsibilities;
- no AI ownership of mode, preedit, commit, or learning;
- Mozc remains the deterministic foundation; and
- users can build and audit the unsigned beta from source.

## Beta exit gates

Before calling the beta a release candidate:

1. A clean Windows x64 build applies the pinned Mozc patch and dependencies.
2. Rust, web, and bridge checks pass with locked inputs.
3. The package passes API health and real Mozc conversion smoke tests.
4. Install, start, stop, restart, bridge failure, and uninstall paths pass.
5. The package contains no API keys, profiles, model files, or user text.
6. External ZIP SHA-256 and provenance are published separately from the
   package.
7. Documentation states that Workbench/CLI is not TSF.

TSF release gates remain separate and are listed in
[`PLATFORM_ROADMAP.md`](PLATFORM_ROADMAP.md).
