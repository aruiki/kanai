# Contributing to KanaAI

Thanks for helping improve KanaAI. Contributions are welcome, especially
those that make Japanese conversion more correct, explainable, private,
accessible, and reliable.

By participating, you agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Do not submit exploit details, secrets,
or private user data in a public issue; use [SECURITY.md](SECURITY.md).

## Before you start

1. Search existing issues and pull requests.
2. Open an issue or discussion for substantial architecture, native-ABI, privacy,
   dependency, model, data, or packaging changes before writing a large patch.
3. Keep each pull request focused enough for a meaningful review.
4. Do not begin from a branch that contains unrelated generated files, local
   profiles, credentials, or dependency churn.

KanaAI is currently an engineering preview. Please do not describe the project
as a released native IME, claim that a model is bundled, or publish binaries
from an ordinary pull request.

## Development Certificate of Origin

All contributors must certify the origin of their contribution under the
[Developer Certificate of Origin 1.1](https://developercertificate.org/).
Add a `Signed-off-by:` trailer to each commit:

```sh
git commit -s
```

For multiple commits, sign each one. A `Signed-off-by:` line certifies the
Developer Certificate of Origin; it is not an Authenticode signature and does
not transfer copyright.

## Source setup

```sh
git clone --recurse-submodules https://github.com/aruiki/kanai.git
cd kanai
git submodule update --init --recursive
npm ci
```

The workspace declares Rust 1.88 or newer and Node.js 20.19 or newer. Install
`rustfmt` and `clippy`. Building the C++ bridge additionally requires
Bazelisk, a C++ toolchain, and the native packages required by the pinned Mozc
revision.

The submodule pins a specific Mozc revision and
`third_party/mozc/src/.bazeliskrc` pins Bazel 9.0.2. Do not update either as
part of an unrelated change. Review the exact gitlink, generated outputs,
dictionary/data changes, behavior, and notices together when proposing a Mozc
update.

## Build the development bridge

From a POSIX shell:

```sh
cd third_party/mozc/src
bazelisk build //kanai:kanai_mozc_bridge
cd ../../..

export KANAI_MOZC_BRIDGE="$PWD/third_party/mozc/src/bazel-bin/kanai/kanai_mozc_bridge"
cargo run -p kanai-cli -- health
```

On Windows, set `KANAI_MOZC_BRIDGE` to the generated `kanai_mozc_bridge.exe`.
The Rust tests and the web build do not require this large C++ target.

The default Mozc profile in a source checkout is
`.local/share/kanai/mozc`. Use `KANAI_MOZC_PROFILE` for a separate test
profile and delete test profiles after use. Never include a real profile in a
bug report or commit.

## Run the workbench

```sh
npm run dev
```

Open <http://127.0.0.1:5173>. The current Rust developer API is
unauthenticated and loopback-bound. Run it only on a trusted development
machine; loopback binding is not authentication, so never expose or port-forward
it.

For a production-like local bundle:

```sh
npm run build
cargo run -p kanai-api --release
```

Then open <http://127.0.0.1:8787>. This is still a developer service, not a
native IME release.

For the native Windows direction, see
[`docs/PLATFORM_ROADMAP.md`](docs/PLATFORM_ROADMAP.md) and
[`platform/windows-tsf/README.md`](platform/windows-tsf/README.md). The retired
Workbench/CLI package is not a Windows beta or IME; the first beta must be a
registered TSF TIP based on the pinned upstream Mozc Windows TIP.

## Required checks

Run the checks relevant to your change. A complete source check is:

```sh
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace --all-targets
npm test
npm run build
```

The repository's `npm run check` script aggregates the Rust and web checks. Use
the explicit commands above when you need to run or diagnose each stage
separately.

Formatting fixes may be produced with:

```sh
cargo fmt --all
```

Do not hide a test by weakening an assertion, adding an unexplained broad
ignore, or making a test depend on a developer machine. Explain any required
`#[allow(...)]`, Clippy exception, or skipped test in the pull request.

Changes to the Mozc bridge should also run the pinned target and relevant
conversion conformance fixtures. Native changes must include keyboard,
preedit, candidate selection, focus teardown, secure-input, accessibility, and
process-recovery coverage for the affected platform.

## Contribution requirements

A useful pull request:

- explains the user or maintainer problem and the chosen tradeoff;
- stays within one reviewable concern;
- adds or updates tests, fixtures, and relevant documentation;
- preserves deterministic conversion and never learns from a candidate merely
  because it was displayed;
- keeps raw key streams, compositions, document context, API keys, model
  prompts, logs, and real dictionaries out of source, fixtures, and CI logs;
- does not silently change lockfiles, toolchains, submodules, or generated
  data;
- discloses generated or AI-assisted material when it cannot be independently
  verified; and
- explains compatibility, privacy, security, and licensing impact when
  relevant.

Use synthetic or license-clean test content. Do not submit prompts, output,
logs, or user histories from a model service. Use canary strings rather than
real personal text when testing redaction.

## Third-party code, data, and models

New dependencies, submodules, dictionaries, models, prompts, fonts, icons, and
other data require explicit review. For each, record as applicable:

- exact source and version/commit;
- why it is needed and the alternative considered;
- code and data licenses, notices, attribution, and source-offer requirements;
- whether it is built, bundled, downloaded at runtime, or user-supplied;
- integrity/reproducibility mechanism;
- model training/data provenance when known;
- network, telemetry, update, and user-content behavior; and
- impact on the release SBOM and threat model.

A permissive code license does not automatically make a model or dictionary
redistributable. Do not add a model to source control or an artifact by default.

`third_party/mozc` is upstream and carries mixed component terms, including
NAIST/ICOT and Okinawa dictionary notices. Preserve them. Do not imply that
Google or Mozc endorses KanaAI.

## Privacy, networking, and security changes

Changes involving context capture, learning, user dictionaries, network
requests, subprocesses, IPC, file permissions, serialization, native loading,
updates, or packaging require a threat-model review. In particular:

- never put a network operation on the synchronous input path;
- fail closed for secure fields and missing key storage;
- keep local conversion available when a model or provider fails;
- make each network feature independently visible and opt-in;
- preview the data that would leave the machine;
- never print API keys or content-bearing requests; and
- add canary tests for logs, metrics, crash output, bundles, DNS, and packets.

## Commits and pull requests

Use small, descriptive commits with a conventional subject where practical,
for example `api: reject invalid Mozc candidates` or `docs: clarify model
setup`. Explain why the change is needed, not only what changed.

Before requesting review, ensure:

- [ ] the change is scoped and documented;
- [ ] required format, lint, type-check, and test commands pass;
- [ ] no secret, user data, profile, model, or unreviewed binary was added;
- [ ] dependency, data, license, and privacy impacts are recorded;
- [ ] compatibility and failure behavior are explicit; and
- [ ] every commit has a `Signed-off-by:` trailer.

Maintainers may ask for changes, additional tests, or a smaller design before
approval. Reviews focus on correctness, user safety, maintainability, and
project scope—not on whether a contribution was written by a person or an AI
tool.

## Security reports

Do not use a pull request or public issue for an undisclosed vulnerability.
Follow the private reporting and disclosure process in
[SECURITY.md](SECURITY.md).

## License

KanaAI-owned contributions are accepted under the
[MIT License](LICENSE-MIT) or [Apache License 2.0](LICENSE-APACHE), at your
option, subject to the Developer Certificate of Origin. Third-party material
retains its original license or terms.
