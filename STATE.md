# Autonomous Development State

Status: NOT COMPLETE

検証日: 2026-09-25（WSL/Linux）。build agent は最終完成判定権限を持たない。
`.goal-complete` は作成していない。

## Current milestone

Rust broker と Mozc bridge の Linux lab vertical slice は、単一の supervised
bridge process で複数の独立 session を扱えるまで進んだ。broker の
session/generation owner、C++ の bounded `SessionHandler` owner、optional
enhancement queue の correlation が実プロセスで接続されている。

一方、staged Windows source path には、trusted server-side session/generation
binding、bounded async worker、exact live-candidate apply、passive broker
session preparation/release が実装された。`IsAvailable()` は worker 開始と
regular trusted binding がない初期状態では false で、source path としては
binding 後に true になる。しかし Windows TIP は未登録・未実行であり、
`IsAvailable()` の実機挙動・AI quality・installer/runtime は未証明である。

## Verified completed work

- iteration 開始時に `AGENTS.md`、`GOAL.md`、`STATE.md`、`VERIFICATION.md`、
  現在の root/submodule diff、関連 Rust/C++/TSF code を確認した。
- `crates/kanai-mozc` に `MozcBridgePool` と `MozcSessionClient` を追加した。
  - one child process / one bounded pool
  - explicit `open`, `key`, `edit`, `convert`, `commit`, `cancel`, `close`
  - UTF-8/percent-encoded bounded line fields
  - per-session operation ordering plus pool-level synchronous handler ordering
  - generation response validation and positive request-scoped candidate IDs
  - child PID diagnostic for proving that sessions share one process
- `patches/mozc-kanai-bridge.patch` を更新し、pinned Mozc へ replay できる
  C++ bridge target を提供した。
  - hard cap of 64 total upstream sessions
  - incognito/no-history request configuration
  - private candidate snapshot, duplicate/unknown/stale/replay rejection
  - strict generation/close/reset/cancel checks
  - ASCII romaji and valid UTF-8 composition conversion
  - bounded command/field/context sizes
  - legacy `ping/reset/convert/commit/shutdown` compatibility facade
  - upstream `special_romanji_table` API typoを修正
  - oversized candidate snapshotを安全にfallbackできるよう上限を追加
- `MozcSessionBackend` を per-session process から shared pool へ変更した。
  - broker owner is still authoritative for session ID, generation, fallback,
    candidate correlation, and commit
  - key/edit/cancel/close/reset state is no longer only local bookkeeping
  - legacy `MozcBridge` API and CLI/API compatibility remain available
- optional queue とは別の fast/slow path を維持した。key/convert/bridge process
  failure は baseline/direct fallback に閉じ、optional model は同期 key pathへ
  呼び込まれない。
- real integration coverageを追加/更新した。
  - two broker sessions on one child PID
  - interleaved key/convert/commit/focus-loss
  - stale/unknown/replayed commit and stale close rejection
  - legacy one-shot pipeline and incognito history isolation
- `crates/kanai-core/benches/fast_rank.rs` を追加し、local deterministic
  fast-rankの10,000 iteration benchmarkを再現可能にした。AI ranking
  benchmarkそのものはまだない。
- `scripts/benchmark-mozc-bridge.py` と
  `docs/benchmarks/mozc-bridge-linux-wsl.json` を追加した。これは real bridge
  child I/O の benchmark であり、AI quality、Windows TSF、release p95 の
  代替ではない。
- broker/Mozc/architecture/TSF metadata の記述を multi-session lab reality と
  staged native source path に更新した。Windows runtime はまだ未登録である。
- TSF host audit markerを新 API（`MozcBridgePool`, `close_at`, `.commit(`）に
  更新した。
- TSF supplemental-model overlayに、trusted server-side
  `SessionBindingOwner`/opaque `SessionBinding`、bounded async worker、
  `prepareRerankSession`/release handoff、`ApplyRerankToResults` exact apply を
  追加した。binding epoch/generation/focus-loss、password/protected marker、
  stale response、worker exception、bounded queueを検証した。Windows実TIP、
  model runtime、installer は未検証である。
- `LocalOpenAiBackend` を追加し、明示的なHTTP loopback modelだけを
  `KANAI_BROKER_ENHANCEMENT=local` / `local-only` で選択できるようにした。
  model weightsはbundleせず、response streaming/request/response size、control-free
  model、credential-free URL、exact permutationを検証する。loopback mockを
  実際にHTTPで呼ぶunit testも追加したが、AI qualityのevidenceではない。
- real bridge recovery testでchildを3回killし、epoch failure→全session
  invalidation→explicit bounded restart→new PIDまで通過した。Windows named-pipe
  reconnectのevidenceではない。
- TSF rank policyでbaseline candidateのtext/reading/rank mutationもAI order
  と同様に拒否し、rank-policy testを追加した。

## Current blockers and known gaps

- `KanaAiSupplementalModel::IsAvailable()` は初期状態で false であり、staged
  trusted SessionHandler binding + worker 開始後には source path で true に
  なる設計だが、Windows TIP 実機では未確認である。
- C++ bridge は source-built Linux lab target であり、Windows named-pipe
  process、server-side binding、TSF application からの session open/key/edit/
  rerank/apply/release の実機動作、ACL/reconnect は未実行。
- bridge process kill後のLinux lab recovery（3 cycleのkill/restart/epoch
  invalidation）は実測済みだが、Windows named-pipeのACL/reconnect、orphan
  cleanup、長時間restart stress、loaded broker recovery はまだ release gate。
- Windows x64 TIP build、registration、Notepad/Edge/Office相当の入力、
  secure field/UIA、restricted token/AppContainer、repair/uninstall/upgrade
  matrix がない。WSLにはMSVC/Windows hostがない。
- optional local model weights/runtime は repository にない。loopback HTTP
  adapterのprotocol/fallback testは通るが、networkless AI quality、実 model
  kill recovery、Windows trusted TSF live-result適用は未実証である。
- browser/API learning state は lab 実装で、native encrypted persistence、
  crash recovery、誤学習削除の host proof は未実装。
- quality corpus はまだ synthetic。実 Mozc candidate fixture、未知 homophone
  set、modelなし/ありの top-k/MRR/NDCG、confidence interval は不足。
- AI ON/OFF、key-to-preedit、loaded broker、Windows release 10,000-event
  benchmark と memory-leak analyzer は未実施。fast deterministic rank bench
  のみ実装済みで、AI ranking benchmarkのacceptance evidenceではない。

## Failed approaches and resolutions

- 初期のMozc bridge source適用は `git diff` だけで生成すると、untrackedな
  `src/kanai/*` とBUILD変更が欠落した。`git add -N` を明示してから
  `git diff HEAD --binary` を生成し、clean submoduleで `git apply --check`
  と実buildを再確認した。
- TSF overlay patchの旧 hunk は実ソースの indentation と一桁ずれていて、
  archive再現で `git apply` が失敗した。pinned baselineからrelative diffを
  再生成し、`prepare-pinned-mozc.ps1`相当の`engine/...` pathで
  `git apply --check`と実buildを再確認した。
- Windows `enable_spellchecker` query initially failed because the pinned OSS
  tree has no `//supplemental_model` package. The 0001 patch now selects only
  the KanaAI model/pipe targets on Windows; the same query resolves cleanly.
- The static host audit initially treated the helper name `DropPendingRerank`
  as a synchronous `Rerank(` call and failed after the async worker landed.
  The audit now rejects actual pipe/model construction markers instead; the
  portable CTest and patch checks were rerun successfully.
- 初期のcandidate snapshot cap 128は、実Mozc candidate列（174件程度）を
  検出したため real integrationで安全なfallbackになりました。最大256に
  修正し、未知/重複IDをsnapshot登録してcommit前に再検証するようにした。
- C++ compileで `set_special_romaji_table` が未定義APIとして失敗した。
  pinned protoの正しい `set_special_romanji_table` に修正し、再buildした。
- TSF host auditが旧marker `commit_at` を要求して失敗した。実際の新境界
  (`MozcBridgePool`, `close_at`, `.commit(`) へmarkerを更新した。
- Unix KBF1 probeの最初のassertionは `outcome.success.payload` のJSON形を
  読み違えて失敗した。実装の応答は正しく、probeのassertionを修正して
  authenticated create/key/convert exchangeを再実行しPASSした。
- 以前記録したBazelisk PATH問題、async session ownerのdeadlock/lock問題、
  TSF patchの壊れたhunk、overlapped event未設定、Unix listenerのruntime寿命
  問題は同じ方法で再試行していない。
- release buildの初回は `kanai-core/Cargo.toml` の `fast_rank` bench targetに
  実ファイルがなくmanifest parseで失敗した。`benches/fast_rank.rs` を追加し、
  debug/release buildとbenchを再実行して解消した。
- workspace clippyの初回は新增された `BackendError::SessionInvalidated` が
  async session error mappingで未網羅だった。`BackendUnavailable`へ明示的に
  mapしてclippyと全testを再実行した。
- TSF secure-field binding testの初回は、secure bindがactive bindingを
  意図的にclearした後のlower-generation bindをstaleと誤って期待した
  ため失敗した。secure transition後のregular rebindを挟むテストへ修正し、
  Bazel testを再実行してPASSした。

## Benchmarks and measurements

- Pinned Mozc commit: `13c98988247aa711d99db9e348ec2a597d14b5cd`.
- Bazel 9.0.2 `//kanai:kanai_mozc_bridge`: Linux build PASS。生成binaryは
  ローカルに存在し、source patchはclean submoduleへreplayできる。
- `cargo bench --locked -p kanai-core --bench fast_rank`: repository receipt
  は10,000 iterations, p50 **1,210 ns**, p95 **1,230 ns**, p99 **1,270 ns**,
  32 bounded cache entries。最新のrelease test内 smokeは p50 **1,210 ns** /
  p95 **1,240 ns** / p99 **2,200 ns** で、shared-machine loadによるばらつきを示す。
  local deterministic fast-rankだけを示し、AI latency/qualityの代替ではない。
- 8 sessions / 20 iterations/session = 160 real interleaved conversions:
  - latest non-ASCII (`きょう`) receipt: p50 **13.770 ms**, p95 **14.097 ms**,
    p99 **14.350 ms**, max **16.045 ms**, one child process, end RSS
    **39,532 KiB** (`docs/benchmarks/mozc-bridge-linux-wsl.json`).
  - 1,000-conversion same-input stress after the AS_IS key-event optimization:
    p50 **13.816 ms**, p95 **14.361 ms**, p99 **14.670 ms**, max **21.066 ms**,
    end RSS **38,796 KiB**. This is a Linux bridge-only observation, not a
    Windows release threshold or AI ranking benchmark.
  - Before that optimization, the same non-ASCII path measured p50 **407.254 ms**,
    p95 **446.780 ms**, p99 **467.732 ms** over 1,000 conversions; the comparison
    is recorded in the benchmark receipt.
- 以前の20 sequential real Mozc requests、API/mock fallback測定は STATE/VERIFICATION
  の記録に残っている。今回のpool/bridge benchmarkをAI ranking benchmarkや
  10,000-event release evidenceとして扱わない。

## Last test results

- `BAZEL=/home/aruiki/.cache/bazelisk/downloads/sha256/422e7a1690b76d7e615c29091d3aca28d0bd3a93fe3c93cbefb8f72d774926d5/bin/bazel ./scripts/build-mozc-bridge.sh`: PASS (temporary patch applied,
  built, reversed, and clean checkout rechecked)
- `cargo fmt --all -- --check`: PASS
- `cargo clippy --locked --workspace --all-targets -- -D warnings`: PASS
- `cargo test --locked --workspace --all-targets` with the real bridge and
  `KANAI_REQUIRE_MOZC_BRIDGE=1`: PASS, **85 Rust tests**
- `cargo build --locked --workspace --release`: PASS
- `cargo test --locked --workspace --all-targets --release` with the real
  bridge: PASS, **85 Rust tests**
- `cargo check --locked --target x86_64-pc-windows-msvc -p kanai-broker
  --all-targets`: PASS (compile check only)
- Windows-target broker clippy with `-D warnings`: PASS (compile lint only;
  broker's local adapter uses JSON-only reqwest so this check does not pull
  the unavailable MSVC `ring` toolchain)
- `npm test`: PASS, 3 tests
- `npm run build`: PASS (`tsc --noEmit` + Vite production build)
- `node scripts/run-quality-eval.mjs --strict --json`: PASS; 14-case synthetic
  corpus only, not held-out/real-model quality evidence
- CMake/Ninja portable TSF contract build and `ctest`: PASS, 3/3
- isolated staged Bazel `//engine/kanai_ai:kanai_supplemental_model_test`: PASS,
  **8 C++ tests** (Linux host compile/test only, including async worker,
  stale-generation rejection, secure-field invalidation, release, and exact
  baseline mutation rejection; not a Windows TSF runtime)
- bridge patch + three TSF patches `git apply --check`: PASS
- `git diff --check`: PASS
- real `bridge_vertical_slice`: PASS, legacy and multiplexed invalid/stale/replay cases
- real `mozc_session_vertical`: PASS, two sessions, stale optional work, and
  three kill/restart recovery cycles
- local loopback HTTP model adapter test: PASS (real bounded HTTP exchange,
  exact permutation; mock is not a bundled model)
- `python3 -m py_compile scripts/benchmark-mozc-bridge.py`: PASS
- benchmark script smoke and checked-in JSON parse: PASS
- `npm run check` (Cargo fmt/clippy/test + Vitest 3 tests + TypeScript/Vite
  build): PASS. The first standalone test attempt used unsupported Jest flag
  `--runInBand`; the corrected package-native command was rerun successfully.

## Continuation iteration — native async/session bridge (2026-09-25)

### Completed in this iteration

- `crates/kanai-mozc` now accepts valid UTF-8 composition/kana text as well as
  ASCII romaji, while rejecting control characters and preserving the bounded
  request contract. `open`/`close`/`key`/`edit`/`cancel` responses are now
  correlated to the requested session/generation. Real bridge tests cover a
  rendered Japanese edit (`きょう` -> `ょう`) and direct rendered conversion
  through the AS_IS key-event path.
- `crates/kanai-broker/src/pipe_windows.rs` now services up to eight named-pipe
  instances concurrently. A slow optional exchange no longer head-of-line
  blocks later TSF connections; per-session operation locking and bounded
  deadlines remain authoritative.
- Added the authenticated `prepareRerankSession` protocol operation. It creates
  or advances a generation-only broker session without opening a second Mozc
  composition owner, rejects lower generations, binds the authenticated peer,
  and releases the passive session on `focusLost`. State-changing key/edit/
  convert/commit/cancel operations reject passive sessions.
- Added the matching C++ `KBF1` projection and `PipeBrokerClient` prepare/
  rerank exchange plus asynchronous focus-loss release. The client and Rust
  authenticator also check the connected process image (or explicit image
  path) before accepting the public proof marker. The real Unix broker harness
  completed prepare -> rerank (disabled local baseline fallback) -> focusLost
  release over two authenticated connections.
- Async broker state now advances an admission epoch as well as the generation
  clock. `BackendError::Rejected`/pre-mutation cancellation rolls the clock
  back without resurrecting old optional tokens; indeterminate timeout,
  protocol, transport, and wrong-response failures invalidate all sessions
  instead of leaving Rust and C++ generations desynchronized.
- Reworked `KanaAiSupplementalModel` from an inert no-op into an opt-in,
  process-global, bounded async worker. `PostCorrect` snapshots at most five
  unchanged Mozc candidates and context (32 Unicode scalars), performs only a
  bounded in-memory enqueue, and a later matching call applies only an exact
  current permutation. Worker/provider exceptions fail closed to Mozc baseline;
  stale generation/epoch, secure field, and queued release paths are bounded.
- Added `KanaAiSupplementalModel::Create/Global`,
  `BeginMozcCommand`/`EndMozcSession`, and `0003-session-generation-binding.patch`.
  The staged Windows `Modules` owner starts the real named-pipe worker, and the
  trusted server-side `SessionHandler` advances the opaque generation before
  `SEND_KEY`/`SEND_COMMAND`. Disabled TSF contexts add the content-free
  `kanai.protected` marker; password contexts are classified secure.
- Optimized the real bridge's non-ASCII `convert` path: feeding rendered UTF-8
  through Mozc `AS_IS` key events instead of `UPDATE_COMPOSITION` reduced the
  same-input 1,000-conversion smoke from p50 **407.254 ms** / p95 **446.780 ms**
  to p50 **13.816 ms** / p95 **14.361 ms**. This is Linux bridge evidence only,
  not a Windows release threshold or AI-quality result.
- Corrected the Windows `engine:modules` select so it no longer references the
  absent OSS `//supplemental_model` package when `enable_spellchecker` is set;
  `bazel query --config=windows --define enable_spellchecker=1` now resolves
  the KanaAI model, pipe client, and `SessionHandler` dependency closure.
- Updated the TSF overlay, portable contract tests, host audit, preparation
  script, and metadata/docs to reflect the new source/runtime path. The product
  is still not registered, signed, packaged, or proven on Windows.

### Verification added in this iteration

- `cargo fmt --all -- --check`: PASS.
- `cargo clippy --locked --workspace --all-targets -- -D warnings`: PASS.
- `cargo test --locked --workspace --all-targets`: PASS, **85 tests**,
  including real Mozc bridge/session/edit/queue coverage and a pre-mutation
  backend rejection rollback/desynchronization regression test.
- `cargo check --locked --target x86_64-pc-windows-msvc -p kanai-broker
  --all-targets`: PASS; Windows-target Clippy with `-D warnings`: PASS.
- Portable TSF CMake clean rebuild and CTest: PASS, **3/3**.
- Fresh staged pinned-Mozc Bazel
  `//engine/kanai_ai:kanai_supplemental_model_test`: PASS, **8 C++ tests**,
  including async apply, stale-generation rejection, secure binding, and
  asynchronous release.
- `verify_pinned_host.py`, JSON parsing, `git apply --check` for all three TSF
  patches, and `git diff --check`: PASS.
- Fresh staged Bazel query with `--config=windows --define enable_spellchecker=1`
  resolved the KanaAI model/pipe/`SessionHandler` closure without the absent OSS
  `//supplemental_model` package.
- `bazel query --config=windows` dependency resolution: PASS; an actual
  `bazel build --config=windows //engine:modules` remains blocked in this WSL
  image by the missing `cc-toolchain-x64_x86_windows-clang-cl` target, before
  C++ compilation. This is an environment/toolchain blocker, not a source
  pass.
- Real Unix `kanai-broker` process harness: authenticated
  `prepareRerankSession` response correlated; rerank returned the unchanged
  baseline with `policyDisabled`; `focusLost` released the passive session.
- Final post-edit rerun: Rust fmt/Clippy/debug+release tests, Windows-target
  check/Clippy, staged Bazel model tests, portable TSF CTest, static host audit,
  patch replay checks, `npm run check`, and `git diff --check` all PASS.
  `.goal-complete` remains absent.

### Remaining blockers after this iteration

- The Windows TIP/server has not been built or registered on a real Windows
  host, and no Notepad/Edge/Office/32-bit/64-bit/UIA/secure-field run exists.
- The broker still has no bundled real local model/runtime; the current default
  path is deliberately Mozc baseline fallback.
- The native C++ pipe client and Rust Windows authenticator now perform
  process-image checks (with optional exact image paths) in addition to
  same-user/session checks. Windows ACL/token execution, Authenticode policy,
  and same-user impostor tests remain required.
- Passive rerank session lifetime, native model packaging/signing, installer,
  encrypted confirmed-commit learning, 1,000+ held-out quality corpus, and
  10,000-event Windows performance/resource evidence remain incomplete.
- The C++ Windows-only transport code could not be executed in this WSL
  environment; portable C++ tests and staged host Bazel tests do not substitute
  for that runtime evidence.


次は Windows x86/x64 host で patched TIP/server を実際に build/register して、
server-side trusted binding、named-pipe prepare/rerank/release、AI OFF/ON、
Notepad/Edge/Office相当、secure-field/UIA、model kill、focus/reconnectを観測する。
`IsAvailable()` は regular trusted session worker開始後にだけ true になる
source pathとして実装済みだが、Windows runtime/installed acceptance は未証明。

Windows named-pipe ACL/identity mutual proof、real local model/runtime
packaging、confirmed-commit encrypted learning、1,000+ held-out Mozc quality
corpus、10,000-event loaded benchmarkを同じ immutable sourceで自動化する。
human-onlyの署名/CLSID/Windows operator権限を取得できない項目は、結果を
推測せず blockerとして記録する。

## Directory inspection — current iteration

- `VERIFICATION.md` remains `FAIL — NOT COMPLETE`; `.goal-complete` is absent.
- The worktree contains the current uncommitted broker/Mozc/TSF implementation
  changes; they must not be discarded.
- Fresh Rust debug/release tests, workspace Clippy, Windows-target compile/lint,
  bridge replay/build, portable TSF CTest, and isolated staged Bazel tests pass.
- Native TSF source path is now connected through the staged server hook and
  async worker, but `KanaAiSupplementalModel::IsAvailable()` is still false in
  an unstarted/unbound process and true-at-runtime behavior is unverified on
  Windows.
- Windows registration probe returned `E_FAIL` in the non-admin session and
  left no registry keys.
- Immediate implementation task remains: prove the Windows x86/x64 TIP/server
  build/register/application path, then add a real local model runtime and
  held-out Mozc quality corpus.
