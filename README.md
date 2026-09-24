# KanaAI

<!-- markdownlint-disable MD013 -->

**日本語入力を、説明できる AI へ。**

A local-first Japanese IME project built on Mozc, with Rust orchestration,
explainable personalization, and optional local AI.

[Source](https://github.com/aruiki/kanai) · [Roadmap](docs/PLATFORM_ROADMAP.md) ·
[Architecture](docs/ARCHITECTURE.md) · [Contributing](CONTRIBUTING.md) ·
[Security](SECURITY.md)

> [!IMPORTANT]
> **KanaAI is an engineering preview, not a released input method yet.** The
> repository contains a Rust workbench, an optional web lab, and an isolated
> bridge to the pinned Mozc source tree. It does **not** yet ship an Fcitx5
> add-on, Windows TSF IME, macOS InputMethodKit app, installer, portable ZIP,
> Scoop package, or AI model. Source metadata uses version `0.1.0` as a
> development version; no public `v0.1.0` release is claimed.

KanaAI is an open-source effort to put a mature Japanese conversion engine
first and add a small, visible policy layer around it:

- **Mozc is the baseline.** Romaji composition, segmentation, conversion,
  rewriters, and dictionary behavior stay in the pinned Mozc project.
- **Rust owns orchestration.** Platform-neutral conversion contracts,
  explainable ranking, learning state, the Mozc adapter, API, and CLI live in
  Rust.
- **AI is optional.** The base path does not require a model. A user may point
  the workbench at a local OpenAI-compatible server for a constrained,
  opt-in semantic rerank or an explicit writing-assist action.
- **Privacy controls are a release requirement.** Conversion is intended to
  remain local; network providers must be explicit and separately enabled.

KanaAI is not affiliated with or supported by Google. Mozc is an independent
open-source project and does not provide a stable release channel.

## Current status

| Capability | Status in this repository |
| --- | --- |
| Rust conversion and personalization contracts | Implemented as a developer workbench |
| Isolated Mozc line-protocol bridge | Implemented and source-buildable; requires building the pinned Mozc target |
| Explainable deterministic ranking | Implemented in the workbench; not yet a production persistence policy |
| Local model tier catalog | Implemented as hardware/capacity guidance; no model is included |
| OpenAI-compatible local assistant | Implemented as an optional `/api/assist` path; not required for conversion |
| Constrained local semantic reranker | Experimental API path: opt-in, loopback-only, bounded, and fallback-safe; no model is included and it is not a native key-path feature |
| Native Linux/Windows/macOS IME shells | **Roadmap only** |
| Encrypted profile store, sync, and secure-field enforcement | Target architecture; not a current end-user feature |
| Windows portable ZIP and Scoop manifest | Release contract/template only; **no artifact is available yet** |

The current web TypeScript application is a development workbench, not an IME
runtime. Native shells are planned to call the shared Rust core through thin
platform adapters.

## Architecture

```text
Production target (roadmap):

Fcitx5 / TSF / InputMethodKit
            │
     thin native shell
            │
   Rust session core ───► pinned Mozc conversion backend
            │
  local policy + state   ───► optional local/approved AI service

Current developer path:

Web workbench ──loopback intended──► local Rust API
                                      │
                               Rust core
                                      │
                                 Mozc bridge
```

Core repository areas:

| Path | Purpose |
| --- | --- |
| `crates/kanai-core` | Conversion contracts, transparent ranking, learning state, and model-tier metadata |
| `crates/kanai-mozc` | Process supervision and line-protocol adapter for the isolated Mozc bridge |
| `crates/kanai-api` | Local HTTP API, hardware guidance, optional constrained reranking, and optional assistant client |
| `crates/kanai-cli` | Small conversion and health CLI |
| `src/` | TypeScript development workbench |
| `third_party/mozc` | Pinned upstream Mozc submodule; not KanaAI-owned code |
| `docs/` | Architecture, privacy, integration, distribution, and platform roadmap |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for layer boundaries and
[docs/PLATFORM_ROADMAP.md](docs/PLATFORM_ROADMAP.md) for the proposed native
sequence: Linux/Fcitx5 first, Windows/TSF second, macOS/InputMethodKit third.
There is no promised release calendar.

## Quick start

### Prerequisites

- Git with submodule support
- Rust and `rustfmt`/`clippy` 1.88 or newer
- Node.js 22.14 or newer and npm
- A C++ toolchain and [Bazelisk](https://github.com/bazelbuild/bazelisk) for
  the Mozc bridge
- The native packages required by the pinned Mozc revision
  ([Linux build guide](https://github.com/google/mozc/blob/master/docs/build_mozc_for_linux.md),
  [Windows build guide](https://github.com/google/mozc/blob/master/docs/build_mozc_in_windows.md),
  or [macOS build guide](https://github.com/google/mozc/blob/master/docs/build_mozc_in_osx.md))

Bazelisk selects Bazel `9.0.2` from the pinned
`third_party/mozc/src/.bazeliskrc`. A different floating Mozc or Bazel version
is not a reproducible substitute.

### 1. Fetch the source and install web dependencies

```sh
git clone --recurse-submodules https://github.com/aruiki/kanai.git
cd kanai
npm ci
```

If the submodule was not initialized during cloning:

```sh
git submodule update --init --recursive
```

### 2. Run the source-only checks

```sh
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace --all-targets
npm test
npm run build
```

These checks do not require the large Mozc C++ build.

### 3. Build the KanaAI Mozc bridge

From a POSIX shell:

```sh
cd third_party/mozc/src
bazelisk build //kanai:kanai_mozc_bridge
cd ../../..

export KANAI_MOZC_BRIDGE="$PWD/third_party/mozc/src/bazel-bin/kanai/kanai_mozc_bridge"
cargo run -p kanai-cli -- health
cargo run -p kanai-cli -- kyou --explain
```

On Windows PowerShell, use the generated `.exe` path:

```powershell
$env:KANAI_MOZC_BRIDGE = "$PWD\third_party\mozc\src\bazel-bin\kanai\kanai_mozc_bridge.exe"
cargo run -p kanai-cli -- health
cargo run -p kanai-cli -- kyou --explain
```

The bridge uses an isolated Mozc profile. By default, the source checkout
uses `.local/share/kanai/mozc`; override it with `KANAI_MOZC_PROFILE` when a
separate location is preferable.

### 4. Start the developer workbench

```sh
npm run dev
```

Open <http://127.0.0.1:5173>. Vite proxies `/api` to the Rust service on port
`8787`.

To build the web bundle and serve it from the Rust process instead:

```sh
npm run build
cargo run -p kanai-api --release
```

Then open <http://127.0.0.1:8787>.

> **Developer-service warning:** the current API is loopback-only but still
> unauthenticated. Use it only on a trusted development machine. Do not
> expose it to the internet, port-forward it, or treat it as a production
> service. Authentication, peer validation, and release hardening remain
> native-release gates.

## Optional local AI setup

**KanaAI does not bundle, download, or endorse an AI model.** Mozc conversion
works without one. The current tier profiles are capacity hints for optional
local reranking/writing assist, not shipped model identifiers:

| Tier | Example size class | Approximate model file | Recommended RAM | Context / max output |
| --- | ---: | ---: | ---: | ---: |
| Mozc only | No model | 0 | 0 | 0 / 0 |
| Tiny | ~0.6B, Q4 | ~500 MiB | 4 GiB | 2,048 / 192 |
| Compact | ~1.7B, Q4 | ~1.2 GiB | 6 GiB | 4,096 / 384 |
| Balanced | ~4B, Q4 | ~2.7 GiB | 12 GiB | 8,192 / 768 |

These values are approximate, not quality, speed, or compatibility claims.
Quantization, context use, and runtime overhead vary by model and backend.

1. Start a model server yourself and bind it to loopback. For example, with a
   GGUF model and `llama.cpp`:

   ```sh
   llama-server --model /absolute/path/to/model.gguf --host 127.0.0.1 --port 8080
   ```

   On POSIX systems, the repository helper starts a single-slot loopback server
   and never downloads weights:

   ```sh
   scripts/run-local-model.sh /absolute/path/to/model.gguf
   ```

2. Export the identifier that your server advertises before starting KanaAI:

   ```sh
   export KANA_AI_BASE_URL="http://127.0.0.1:8080/v1"
   export KANA_AI_MODEL="your-server-model-id"
   export KANA_AI_API_KEY=""             # only if the local server requires one
   export KANA_AI_ALLOW_REMOTE=0
   npm run dev
   ```

   In another shell, inspect the server-side readiness report without sending
   text:

   ```sh
   curl http://127.0.0.1:8787/api/model/health
   ```

Remote endpoints remain disabled unless `KANA_AI_ALLOW_REMOTE` is explicitly
set to `1` or `true`. Enabling that flag can send the selected text and user
instruction from the explicit assist operation to the configured provider; if
personalization is enabled, profile domain terms can also influence the prompt.
The experimental reranker is stricter: it permits only a valid loopback model
endpoint even when remote assist is enabled. Do not use a real key in a
committed `.env` file, command transcript, issue, or web bundle.

[model-manifest.example.json](model-manifest.example.json) records an
illustrative tier catalog. It is not downloaded or loaded automatically, does
not grant redistribution rights, and does not endorse the named model
families. Verify the selected GGUF/model license, revision, digest, context
support, and structured-output behavior yourself.

`.env.example` is a reference for environment names, not an automatically
loaded or secure distribution file.

### Local reranker and LLM boundaries

The developer quality pipeline is:

1. Mozc produces baseline candidates.
2. KanaAI applies bounded, inspectable deterministic ranking.
3. An optional local semantic reranker may reorder a bounded candidate window.
4. A generative LLM is reserved for an explicit, previewable writing action.

The current `/api/convert` contract accepts `aiMode: "off"`, `"auto"`, or
`"onDemand"`. Reranking is off by default, skipped for the `mozcOnly` tier,
and never calls a non-loopback endpoint. The implementation limits the model
request to a short reading, a 32-character context tail, at most nine
candidates, a 250 ms deadline, and a small response envelope. It validates the
complete candidate-ID permutation, tier, generation, confidence, and maximum
rank movement before applying an order change. Timeout, malformed output,
privacy limits, or an unavailable model keep the deterministic ordering.

This is an experimental workbench/API path—not a shipped model, a native IME
feature, or a guarantee of quality. It must never block basic composition or
be placed on a native synchronous key path. Writing assist and reranking have
different consent and data boundaries.

## Privacy and security posture

The long-term design is documented in [docs/PRIVACY.md](docs/PRIVACY.md). The
current source snapshot must not be confused with a completed production
privacy implementation:

- Conversion is local through the user-built Mozc bridge.
- The project does not include KanaAI telemetry or an analytics service.
- The optional semantic reranker sends only a bounded reading/context tail and
  candidate window to a valid loopback model when `/api/convert` explicitly
  requests `aiMode`; it is off by default and revalidates model output.
- The explicit writing-assist operation sends the selected text and instruction
  when invoked. Remote assist endpoints are disabled by default and require
  `KANA_AI_ALLOW_REMOTE=1`; domain terms can affect that prompt only when the
  user enables personalization.
- The web workbench stores its current learning/profile state in browser
  `localStorage`. That is transparent developer behavior, not an encrypted
  KanaAI store, and scripts on the same origin can access it.
- The current developer API is unauthenticated and all-interface bound, as
  noted above.
- The current isolated Mozc profile is not KanaAI's future encrypted canonical
  store. Review the profile location and remove it explicitly when no longer
  needed.
- Native secure-field behavior, Protect Mode, encrypted persistence, deletion
  guarantees, and sync are architecture/release requirements, not claims about
  this preview.

Do not report suspected vulnerabilities with user text, API keys, model files,
or real dictionaries in a public issue. Follow [SECURITY.md](SECURITY.md).

## Build and test commands

| Command | Purpose |
| --- | --- |
| `cargo fmt --all -- --check` | Check Rust formatting |
| `cargo clippy --locked --workspace --all-targets -- -D warnings` | Reject Rust lint warnings |
| `cargo test --locked --workspace --all-targets` | Run Rust unit/integration targets |
| `npm test` | Run Vitest tests |
| `npm run build` | Type-check and build the web workbench |
| `bazelisk build //kanai:kanai_mozc_bridge` | Build the pinned C++ bridge from `third_party/mozc/src` |

CI currently checks the Rust workspace and the web workbench separately. It
does not build or certify the large Mozc target or publish a native IME.

## Windows portable ZIP and Scoop plan

There is **no official binary or Scoop package to install today**. The first
planned Windows distribution is a versioned, **unsigned**, x64 portable ZIP,
followed by a hash-pinned Scoop manifest in a project-controlled bucket. A
release is expected to include the tested payload, project license files,
required third-party notices, `SHA256SUMS`, an SBOM, a build manifest, and a
GitHub artifact attestation where available.

A future Scoop manifest verifies that the downloaded ZIP matches a reviewed
hash. It is not an Authenticode signature, does not establish publisher trust,
and does not suppress SmartScreen or Smart App Control. Users must not be told
to disable those protections.

The non-negotiable release details and a deliberately incomplete manifest
template are in [.release/README.md](.release/README.md). They are release
planning material, not a release.

## License and third-party notices

KanaAI-owned source is offered under either of the following licenses, at your
option:

- [MIT License](LICENSE-MIT)
- [Apache License 2.0](LICENSE-APACHE)

Third-party components retain their own terms. In particular, Google-authored
Mozc code is BSD-3-Clause, while Mozc dictionary data and other dependencies
have mixed or component-specific notices. Preserve
`third_party/mozc/LICENSE`, applicable dictionary terms, and all required
notices in any binary distribution. KanaAI makes no Google endorsement claim.

Models, dictionaries, domain packs, and fonts are not relicensed merely because
a tool can load them. Review the license, notices, privacy behavior, and
redistribution rights of every model or data file you use or package.

## Contributing

KanaAI is developed in the open. Read [CONTRIBUTING.md](CONTRIBUTING.md),
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and [SECURITY.md](SECURITY.md)
before submitting a change. Contributions involving Mozc, dependencies,
models, data, native ABI code, networking, or privacy behavior receive extra
review.
