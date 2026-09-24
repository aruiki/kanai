# KanaAI TSF beta and release contract

## Product decision

KanaAI is a Windows Japanese IME. A release candidate is not accepted merely
because it exposes a CLI, a browser page, or a local HTTP service: it must be
usable as a registered Windows text service in ordinary desktop applications.

## Beta boundary: native Windows TSF

The first public beta is a native Windows TSF TIP built on the Mozc Windows TIP
host. The beta must provide, on the supported architectures:

- COM text-service lifecycle and profile registration;
- preedit and candidate presentation;
- Space/Enter/commit/cancel and focus-teardown behavior;
- conversion through the pinned Mozc engine;
- an optional KanaAI local AI reranking path with deterministic fallback;
- crash recovery when the broker or model is unavailable;
- secure-field policy and UI Automation/accessibility coverage; and
- x86/x64 packaging, uninstall, and upgrade behavior.

The TIP may use a private broker to reach Rust, but the broker is an
implementation detail. The user-facing product is still a Windows IME.

## What is not a beta

The retired Workbench/CLI package is no longer a beta, download, or substitute
for a TSF text service. Source code and a development Workbench may remain for
testing the shared core, but they are not a release artifact and must not be
described as an IME.

## Phase 1 definition: local AI quality mode

Phase 1 is the first native Windows TSF IME alpha, based on the pinned upstream
Mozc TIP. Its quality bar is the practical input experience users associate with
Google Japanese Input—fast key handling, predictable composition, useful
candidates, stable learning, and low operational friction—improved with
modern local AI where it is measurably beneficial.

This is a quality and experience reference, not a request to reproduce
Google's proprietary dictionaries, binaries, cloud data, UI, or internal
algorithms. KanaAI must demonstrate improvements against its own pinned Mozc
baseline with reproducible evaluation cases and user-visible behavior.

The local AI model has three bounded roles:

1. **Fast local quality policy** — latency-bounded context, user/domain
   affinity, and candidate reranking on the normal key path.
2. **Local semantic assist** — ambiguity resolution, likely-error repair, and
   short continuation suggestions without blocking composition.
3. **Explicit writing assist** — repair/rewrite actions only after an explicit
   user request and preview.

A large model is never called synchronously for every key. Every AI result is
validated against the current session generation and falls back to Mozc on
timeout, failure, low confidence, or malformed output. The base Mozc result
must remain available even when no model is installed.

Phase 1 quality is measured against a pinned Mozc baseline with:

- top-1/top-k candidate agreement and rerank quality;
- Japanese composition/segmentation regression cases;
- keystroke-to-candidate latency, including p95;
- timeout and recovery rates;
- user-learning correctness across confirmed versus unconfirmed candidates;
- secure-field non-interference; and
- crash-free focus transitions and application restarts.

A model score, prompt, or attractive demo is not a Phase 1 completion criterion.
The TSF IME must remain usable and deterministic while the local model is
absent, disabled, or unavailable.


Google Japanese Input is a product and integration reference for a polished
Mozc-based Windows IME. KanaAI does not reproduce its proprietary binaries,
private dictionaries, cloud synchronization, UI, branding, or internal
implementation. The reusable technical foundation is the open-source Mozc
Windows TIP and its documented interfaces.

## Beta exit gates

Before publishing a Windows beta:

1. A clean Windows x64 build produces the TIP DLL and all required Mozc data.
2. The DLL is registered and removed in a fresh Windows user profile.
3. Notepad, Edge, and Office pass Japanese composition, conversion, candidate,
   commit, cancel, focus-loss, and restart tests.
4. Secure fields, UIA, high-DPI, x86/x64 registration, and app-container policy
   pass or are explicitly documented as unsupported.
5. A broker failure and model timeout both fall back safely without losing the
   composition or committing text unexpectedly.
6. The package contains no API keys, user profiles, model weights, or text.
7. External SHA-256, SBOM, provenance, and signing status are published
   separately and honestly.
8. The public page and installer describe the artifact as a TSF IME, not as a
   Workbench, bridge, or development preview.

These gates are intentionally stricter than a source-buildable skeleton. A
compile-only DLL is a development milestone, not a beta.
