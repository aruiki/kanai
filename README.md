# KanaAI

<!-- markdownlint-disable MD013 -->

<div align="center">

# 日本語入力を、遅らせずにAIで整える。

**A local-first Windows Japanese IME built on Mozc, Rust, and bounded local AI.**

`Windows TSF` · `Mozc baseline` · `Local AI` · `No cloud dependency`

</div>

> [!IMPORTANT]
> **Status: development candidate — not a public beta.**
>
> This repository is the public source and engineering record for KanaAI, and
> this README plus the GitHub Release body are the only published product
> surface. There is no product website.
> The product is a native Windows TSF text service, not the retired
> Workbench/CLI demo. No installer has been published yet. Do not treat a local
> build, a DLL load, a source test, or a loopback model mock as proof that the
> end-user IME is ready.
>
> Two scope decisions are already fixed for the first beta (2026-09-26):
> it will be **Mozc-baseline only, with no local AI model or runtime included**,
> and it will be **unsigned**. Neither changes the product requirements in
> [docs/PRODUCT_REQUIREMENTS.md](docs/PRODUCT_REQUIREMENTS.md); local AI remains
> a completion requirement, it is simply not in the first beta.

[Windows release contract](docs/PRODUCT_RELEASE_CONTRACT.md) ·
[Product requirements](docs/PRODUCT_REQUIREMENTS.md) ·
[Current engineering state](STATE.md) ·
[Open work and release checklist](https://github.com/aruiki/kanai/issues) ·
[Local AI runtime plan](docs/LOCAL_AI.md) ·
[Security](SECURITY.md) ·
[Contributing](CONTRIBUTING.md)

## What KanaAI is

KanaAI is being built as a practical Japanese input method for Windows:

1. **Mozc owns everyday input.** Romaji composition, segmentation, conversion,
   dictionary behavior, candidates, preedit, and commit remain owned by the
   pinned Mozc engine.
2. **Rust owns bounded orchestration.** A private broker tracks sessions and
   generations, validates results, and keeps optional AI work away from the
   synchronous key path.
3. **Local AI improves candidates when it is safe.** The intended first bundle
   uses a pinned Qwen GGUF and a CPU-only `llama.cpp` runtime. A model result can
   only reorder a bounded, unchanged candidate set; it cannot invent text or
   take ownership of commit.
4. **Mozc remains the fallback.** Missing model, timeout, malformed output,
   process failure, protected field, or low resources must leave normal input
   usable.

The current implementation target is a **Windows x64 native TSF TIP**. A
browser Workbench, HTTP API, CLI, or source bridge is development tooling—not
the product.

## Product principles

| Principle | What it means |
| --- | --- |
| **Native first** | The release target is a registered Windows TSF text service used in ordinary desktop applications. |
| **Fast path stays fast** | Key and preedit callbacks do not wait for a model, disk I/O, or network I/O. |
| **AI is bounded** | At most a small candidate window is reranked; IDs, text, and commit authority are validated. |
| **Local by default** | The intended release runs its model/runtime locally and does not require a cloud account or remote endpoint. |
| **Explainable fallback** | A missing or rejected AI result returns the Mozc baseline instead of silently rewriting text. |
| **Privacy is a release gate** | Protected/password contexts, bounded context, no user-data logging, and no hidden telemetry are required. |

## Current status

This table describes evidence, not marketing claims.

| Area | Current state |
| --- | --- |
| Mozc/TIP and Windows runtime build | Windows x64 TIP/server/renderer artifacts have been built and statically checked. |
| Installer | An unsigned MSI/Setup candidate has been built locally. It is not uploaded or public. The first beta is being built as **Mozc-baseline only, with no AI bundle**. |
| Windows registration | The installed development candidate has x64/x86 COM registration and a Japanese profile. |
| Real app input | The operator partially reported successful Notepad typing, conversion, and kana switching. Candidate, commit, cancel, focus, restart, and process checks remain pending. |
| AI bundle | Qwen2.5-1.5B official GGUF + `llama.cpp` CPU runtime were selected for implementation. Both pinned inputs have been downloaded and hash-verified in local staging, but have not been installed into KanaAI, executed as the product runtime, or quality-tested on Windows. **The AI bundle is not part of the first beta.** |
| W1/W2 | Full native input and installer lifecycle gates are not complete. |
| Public release | No GitHub Release, tag, Setup.exe, or MSI has been published. There is no product website; everything is published here and in the Release body. |
| Code signing | Not required for the beta by user decision. The beta will be **unsigned**, and the Release body must say so and explain the resulting Windows warning. |
| Product completion | Not complete. `.goal-complete` has not been created. |

The authoritative current record is [STATE.md](STATE.md). Historical Linux/WSL
milestones are retained there for provenance and are not current Windows
release evidence.

## First AI bundle candidate

The user approved this pairing for the first implementation pass:

| Component | Pinned identity | License / digest |
| --- | --- | --- |
| Model | `Qwen/Qwen2.5-1.5B-Instruct-GGUF` @ `91cad51170dc346986eccefdc2dd33a9da36ead9` | Apache-2.0; `qwen2.5-1.5b-instruct-q4_k_m.gguf`; 1,117,320,736 bytes; SHA-256 `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` |
| Runtime | `ggml-org/llama.cpp` release `b11146` @ `7fe450e19305b828c199d602c23a8337aaa1f03b` | MIT; `llama-b11146-bin-win-cpu-x64.zip`; 18,560,055 bytes; SHA-256 `14cf1303ca9ac3abd94816850532f9f9a69ac66fbaca3776fc6f9061c2fac1d1` |

The complete package is expected to be roughly 1.1 GB. These are **approved
implementation inputs**, not evidence of Japanese IME quality, latency, memory
use, crash recovery, or completed legal review. The full license, notices,
SBOM, model provenance, and runtime closure must be present in the eventual
release. See [docs/LOCAL_AI.md](docs/LOCAL_AI.md).

## Architecture

```text
              Windows applications
                      │
             Windows TSF TIP (x64)
                      │
       authenticated private named pipe
                      │
             Rust broker / session owner
          ┌───────────┴───────────┐
          │                       │
  bounded Mozc conversion   local AI queue
          │                       │
   pinned Mozc engine       llama-server.exe
                                  │
                    pinned Qwen GGUF + CPU runtime
```

### Repository map

| Path | Responsibility |
| --- | --- |
| `platform/windows-tsf/` | Native TSF integration, reviewed Mozc patches, registration, installer, and smoke contracts. |
| `crates/kanai-broker/` | Authenticated protocol, session/generation ownership, bounded enhancement queue, and local model adapter. |
| `crates/kanai-mozc/` | Supervised Mozc bridge and bounded session pool used by the broker. |
| `crates/kanai-core/` | Conversion contracts, ranking policy, cache/learning interfaces, and model metadata. |
| `crates/kanai-api/` / `crates/kanai-cli/` | Development lab and health tooling; not the end-user IME. |
| `evals/` | Development fixtures and evaluation tooling; synthetic fixtures are not release quality evidence. |
| `third_party/mozc/` | Pinned upstream Mozc source; not KanaAI-owned code. |

## Try the source checkout

This is a developer checkout, not an end-user installation. Native Windows
builds require the pinned Visual Studio/Bazel/Mozc toolchain described in the
[handoff guide](docs/OPENCODE_HANDOFF.md).

```sh
git clone --recurse-submodules https://github.com/aruiki/kanai.git
cd kanai
npm ci
```

Run the source-only checks:

```sh
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace --all-targets
npm test
npm run build
```

For Windows-specific build and validation notes, see the [Windows roadmap](docs/PLATFORM_ROADMAP.md). The developer Workbench can then be started with:

```sh
npm run dev
```

The Workbench is loopback-only development software. It is not the Windows
IME, and its API must not be exposed to a network.

## Windows product path

The intended user experience is a one-click `Setup.exe` flow:

1. Download the release asset from the GitHub Release page and verify its
   SHA-256 against the value published in the Release body. The beta is
   **unsigned**, so Windows may show a SmartScreen or publisher warning — do not
   disable SmartScreen, Smart App Control, antivirus, or enterprise policy to
   get past it.
2. Start `Setup.exe` and follow Windows UAC prompts. It writes an embedded MSI
   to a temporary folder and starts Windows Installer; it does not build,
   download, or require manual file placement.
3. Select KanaAI from the Windows Japanese input-method list, restarting the
   target application if it does not appear.
4. Use Mozc composition and conversion immediately. **This beta contains no
   local AI model or runtime**; no AI feature is active, and none is claimed.
5. Remove KanaAI from **Settings → Apps → Installed apps** when no longer
   needed.

**There is no public download link yet.** Do not use a local `.local` build as
a release URL. The release must first pass native installation, input,
candidate, commit/cancel, focus, uninstall/reinstall, rollback,
privacy, performance, and independent-verifier gates.

## Privacy and failure behavior

The release target is local-only. The intended production path does not send
raw keys, full documents, clipboard contents, learning corpora, or model
prompts to a remote provider. AI requests are bounded to the current reading,
approved short context, and a small candidate set. Password/protected fields
must skip AI, history, and learning.

These are release requirements, not claims that every current source slice is
already complete. The current browser lab uses transparent `localStorage`; it
is not the future encrypted native profile store. See [SECURITY.md](SECURITY.md)
and [docs/LOCAL_AI.md](docs/LOCAL_AI.md).

## Release gates

Before a GitHub prerelease can be published, the same immutable source and
artifacts must have receipts for:

- native Windows x64 TIP registration and ordinary application input;
- kana, conversion, candidate, commit, cancel, focus, and restart behavior;
- install, repair/upgrade, uninstall/reinstall, and rollback;
- bundled model/runtime size, SHA-256, SBOM, licenses, notices, and provenance;
- AI OFF/ON, model kill, timeout, malformed output, and Mozc fallback;
- secure/password fields, no user-data logs, and no unexpected network egress;
- CPU/memory/latency measurements and held-out Japanese quality evaluation;
- an independent verifier report tied to the source commit and artifact hashes.

A prerelease is not the same as a completed product. Passing a beta gate does
not create `.goal-complete`.

## Roadmap

The first beta is deliberately narrow: **Mozc baseline, x64, unsigned, no AI
bundle**, with the limitations stated in the Release body. The AI work below is
still required for product completion; it is simply not what the first beta ships.

- [x] Pin and stage the reviewed Mozc/TSF source path.
- [x] Build Windows x64 TIP/server and unsigned installer candidates.
- [x] Add bounded Rust broker/session/generation contracts.
- [ ] Complete W1 native input and W2 installer lifecycle evidence.
- [ ] Freeze a clean source commit and publish the unsigned, Mozc-only GitHub
      prerelease with real hashes and real verified/unverified results.
- [ ] Bundle the approved Qwen GGUF and `llama.cpp` runtime.
- [ ] Add automatic runtime supervision and offline installer staging.
- [ ] Run real AI quality, privacy, resource, and failure-injection tests.
- [ ] Independently verify full product completion.

## License and third-party notices

KanaAI-owned source is offered under either [MIT](LICENSE-MIT) or
[Apache-2.0](LICENSE-APACHE), at the user's option. Mozc and every bundled
runtime/model retain their own notices and license terms. The eventual release
must include the exact third-party notices and SBOM; loading an asset does not
relicense it.

KanaAI is not affiliated with or supported by Google. Mozc is an independent
open-source project.

## Contributing and support

Read [AGENTS.md](AGENTS.md), [CONTRIBUTING.md](CONTRIBUTING.md),
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and [SECURITY.md](SECURITY.md)
before contributing. Please redact API keys, model files, user dictionaries,
private text, and personal paths from issues and support reports.
