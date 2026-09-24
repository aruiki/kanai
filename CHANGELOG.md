# Changelog

All notable changes to KanaAI are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once public
releases begin.

There are **no published KanaAI releases yet**. The `0.1.0` value in source
manifests identifies the current development line; it is not a release tag or a
claim that a binary is available.

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
