# Changelog

All notable changes to KanaAI are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once public
releases begin.

Two prereleases are published. The `0.1.0` value inside the package manifests
identifies the development line and is **not** the release name: the artifacts of
both prereleases are called `KanaAI-0.1.0-*`, and the tags are what tell them
apart. Verify which one you have by SHA-256, never by filename.

## [0.1.0-beta.2] - 2026-09-28

The first prerelease that carries a local AI **and actually starts it**, and the
first in which a freshly installed profile can type Japanese without first
pressing a key to open the IME.

### Added

- The product now supplies the local-AI opt-in itself. The AI package records
  `Enhancement = local` under `HKLM\Software\KanaAI` (the machine default) and
  `HKCU\Software\KanaAI` (the installing user's own setting, which wins over the
  machine default). Both are component key paths, so an uninstall removes them,
  and a Mozc-only package never records them.
- `kanai-broker.exe --enable-local-ai` / `--disable-local-ai` /
  `--reset-local-ai` / `--ai-status`, so the bundled AI can be turned off
  without a registry editor. They write only the calling user's own record.
- The bundled local AI itself: Qwen2.5-1.5B-Instruct (Q4_K_M GGUF, Apache-2.0)
  and a llama.cpp CPU runtime (build 11146, MIT), verified by hash at startup,
  reachable only over loopback behind a per-process key, with no network access
  of any kind.

### Fixed

- **A freshly installed KanaAI started with the IME closed**, so romaji
  committed as ASCII and no Japanese could be typed until the user pressed
  Alt+`` ` ``. Mozc's `TipStatus::IsOpen` returns false when the TSF open/close
  compartment is absent, and a new profile has none. Patch
  `0007-kanai-ime-open-by-default` seeds it at activation through the same
  `GetAndEnsureDataExists` path the conversion mode already used, so a stored
  value still wins and a user who closed the IME keeps it closed. The patch is
  compiled into both the 64-bit and the 32-bit text service.
- **The installer never enabled the input method for the account that installed
  it.** The `EnableTipProfile` custom action's record landed under
  `HKU\S-1-5-18` and `HKU\.DEFAULT`; the package now writes it as an HKCU
  component from the installing user's own client process.
- **The shipped AI could never start.** Nothing in the product set
  `KANAI_BROKER_ENHANCEMENT`, the text service starts the broker with an
  inherited environment, and the policy correctly resolved an unset setting to
  disabled - so an AI-bundled install ran with the AI off and said nothing. The
  broker now also reads the two registry records above, and when no opt-in is
  recorded anywhere it says so on startup instead of staying silent.
- `Invoke-GitCapture @(...) -split "`n"` in `stage-tsf-runtime.ps1` and
  `build-windows-installer.ps1` was parsed as a command invocation, so `-split`
  and its separator were swallowed as arguments. Source identity came back
  `unverified` and release-candidate validation failed closed; in the other
  branch the repository mutation fingerprint silently hashed no file bytes at
  all while still producing a hash.

### Changed

- The broker digest re-pin procedure. Two builds from identical source produce
  different bytes, so the "fixed point" the previous procedure described does
  not exist. The pinned digest now names one built executable, which is the one
  that is packaged, and is not re-derived by rebuilding.

## [0.1.0-beta.1] - 2026-09-26

The first public prerelease: a native Windows x64 TSF text service on the
pinned Mozc engine, unsigned, with **no local AI bundled**. Its known deviation
from the release contract - real-application Japanese input was operator-
confirmed without a machine-verified receipt - is recorded in its Release body
and is not restated as passed here.

## [Unreleased]

### Added

- Rust workspace with platform-neutral conversion contracts, explainable
  deterministic personalization, local learning-state prototypes, and model
  capacity-tier metadata.
- Supervised Rust adapter for an isolated line-protocol Mozc bridge, plus
  conversion and health commands in `kanai-cli`.
- Local HTTP service with conversion, commit, user-word, hardware guidance, and
  explicit optional assistant operations.
- Optional OpenAI-compatible assistant client. Local endpoints are the default;
  remote endpoints require an explicit environment opt-in.
- Experimental constrained semantic reranking for bounded local candidate
  lists. It is opt-in, loopback-only, generation-checked, and falls back to
  deterministic ordering; no model weights are bundled.
- TypeScript/Vite development workbench for inspecting conversion and ranking
  behavior. It is not a native IME runtime.
- Pinned Mozc source submodule and KanaAI bridge target for local C++ builds.
- Architecture, privacy, platform-roadmap, Mozc-integration, distribution, and
  open-source design documentation.
- Rust formatting, Clippy, and test commands; locked web dependency, test, and
  build checks.
- Public issue forms, pull-request checklist, security policy, contribution
  guide, and Code of Conduct.
- MIT and Apache-2.0 project license texts.
- Native Windows TSF integration work is based on the pinned upstream Mozc
  Windows TIP; no TSF DLL, installer, or public beta artifact exists yet.

### Changed

- Aligned public naming, links, and package metadata around KanaAI at
  <https://github.com/aruiki/kanai>.
- Made deterministic ranking contributions and explanations inspectable in the
  CLI and API instead of presenting a result as an unexplained AI score.

### Security and privacy

- No KanaAI telemetry or bundled model is included.
- External AI endpoints are rejected unless remote use is explicitly enabled.
- Documented that the developer API is loopback-only and currently unauthenticated; it must not be exposed to an untrusted network.
- Documented that the current Mozc profile is isolated but is not the planned
  encrypted KanaAI persistence layer.

## Known limitations

- No Fcitx5, Windows TSF, or macOS InputMethodKit native shell ships yet.
- The local semantic reranker is an experimental workbench/API path, not a
  native key-path feature; no model weights or native integration ship yet.
- Encrypted canonical storage, password/secure-field enforcement, Protect Mode,
  sync, and crash recovery remain release work.
- No published Windows TSF TIP, ZIP, installer, Scoop package, or code-signed
  binary is available yet; the retired Workbench/CLI path is not a beta.
- Mozc has no stable upstream release channel; KanaAI therefore builds against
  the exact pinned submodule revision and requires explicit review for updates.
