# Independent Release Verification

**判定: FAIL — NOT COMPLETE**

独立した release verifier として、`GOAL.md` の全 Acceptance Criteria を
実行結果と repository inspection で検証した。製品コードは変更していない。
未達項目があるため、**`.goal-complete` は作成していない**。

検証日: 2026-09-25（WSL/Linux, JST）

> **_snapshot 注意**: 検証中、別の開発エージェントが `STATE.md`、broker の
> source/test、TSF Pipe source を変更していた。最初の clean workspace test は
> 旧 test の generation 不整合で exit 101 になったが、その後に別エージェントが
> test の generation を修正し、最終 snapshot では workspace test、release test、
> real-Mozc test を再実行して pass した。以下の記録は実際に観測した失敗を
> 消さずに残し、最終 source に対する再実行結果も分けて記載する。release 検証は
> 固定 commit/tree で再実行されなければならない。

## 1. 環境と前提

- `rustc 1.98.1`, `cargo 1.98.1`, `rustfmt`, `clippy`
- `node v24.21.0`, `npm 11.19.0`
- `cmake 4.2.3`, `ninja 1.13.2`
- Mozc submodule: `13c98988247aa711d99db9e348ec2a597d14b5cd`
- `pwsh` は未インストール（`pwsh --version` は exit 127）。Windows native
  build / registration / smoke は実行できなかった。
- `unshare -n` は権限不足で、ネットワーク namespace 隔離はできなかった。
- 検証前後とも `.goal-complete` は存在しなかった。

## 2. 実際に実行した evidence

### 2.1 Build、unit、integration

| Command | Result | 備考 |
|---|---:|---|
| `cargo clean` | PASS | 8.4 GiB の `target` を削除 |
| `cargo build --locked --workspace --all-targets` | PASS | clean debug build |
| `cargo fmt --all -- --check` | PASS | 最終再実行 |
| `cargo clippy --locked --workspace --all-targets -- -D warnings` | PASS | 最終再実行 |
| `cargo test --locked --workspace --all-targets` | PASS | Rust 71 tests。real bridge integrationを含む |
| `cargo build --locked --workspace --release` | PASS | `target/release/kanai-api`, `kanai-broker`, `kanai-cli` 生成 |
| `cargo test --locked --workspace --all-targets --release` | PASS | release profileでも71/71 |
| `cargo check --locked --target x86_64-pc-windows-msvc -p kanai-broker --all-targets` | PASS | compile checkのみ。native runtimeではない |
| Windows target broker clippy | PASS | compile lintのみ |
| `npm test` | PASS | Vitest 1 file / 3 tests |
| `npm run build` | PASS | `tsc --noEmit` + Vite production build |
| `cmake -S platform/windows-tsf/tsf -B ... -G Ninja` + build + `ctest` | PASS | 3/3。portable contract testでTIP DLL buildではない |
| `test_candidate_window_source.py` | PASS | 7 tests。UIA stub境界のstatic test |
| `test_pinned_mozc_tsf_smoke.py` | PASS | 7 tests。synthetic/static parserで実Windows smokeではない |
| `verify_pinned_host.py` | PASS | pinned commitとhost markerを検査 |
| `BAZEL=/tmp/opencode/tools/bazelisk ./scripts/build-mozc-bridge.sh` | PASS | `//kanai:kanai_mozc_bridge` Linux ELF |
| bridge patch + 2 TSF patchesの `git apply --check` | PASS | 絶対pathでpinned checkoutに適用可能 |
| `git diff --check` | PASS | 最終再確認 |

Rust testの内訳は API 8、broker contract 10、enhancement 7、real session 1、
session contract 8、core 28、Mozc unit 8、Mozc real vertical 1。実 bridgeが
存在するため、integration testをfake providerへ暗黙に置き換えていない。

### 2.2 1000回 stress と latency

実際の pinned Mozc bridge process に、検証用の一時 harness
`/tmp/opencode/verifier/stress_bridge.py` から1000回の連続 `convert` を実行した。

- **1000/1000成功、failure 0、generation mismatch 0、final ping成功**
- candidate count: 10–174
- wall latency: p50 **21.306 ms**, p95 **24.970 ms**, mean 19.116 ms
- bridge-reported latency: p50 **20.959 ms**, p95 **24.403 ms**
- bridge RSS: 37,092 KiB → 38,536 KiB、差分 **+1,444 KiB**
- profile files: `cform.db`, `config1.db`, `kanai_mozc_bridge.log`

これは実 bridge の stress/latency evidence であり、Windows TSF、broker listener、
AI ON経路、memory leak解析、candidate-ranking benchmarkの証明ではない。RSS
差分一回だけで leakなしとは判定できない。

### 2.3 Contextual / quality evaluator

`node scripts/run-quality-eval.mjs --strict --json` は exit 0。ただし
`evals/README.md` と fixture自身が明記する **14件の synthetic corpus** であり、
実Mozc candidate captureでも実model qualityでもない。

- fixture SHA-256: `73e28db8c7c46c542ae596304e069a9c567f2d34f9ee01bbc94cef59d6965fe6`
- baseline top-1: 0.1818、MRR 0.5909
- local policy top-1: 1.0000、MRR 1.0000
- fixture local-AI top-1: 0.8182、MRR 0.9091
- fixture local-AI runtime: p50 12.4 ms、p95 250 ms（`source=fixture`）
- secure-field fixture: 2件、outbound request 0、leak 0

これは fixture safety test の PASS であり、Goal Milestone 4 の未知ケースを
含んだ品質 acceptance の PASS ではない。

### 2.4 loopback AI mock kill → Mozc fallback

実 `kanai-api` と実Mozc bridgeに対し、review用の一時OpenAI-compatible loopback
**mock**を起動した。mockは製品modelではない。

1. mock生存中: `/api/convert` HTTP 200、`ai.status=applied`、confidence 0.95、
   candidate order変更。
2. mock processを `SIGKILL`。
3. 同じAPI conversion: HTTP 200、`ai.status=unavailable` /
   `reasonCode=modelUnavailable`、provider `Mozc`、preedit `今日`、candidate 9件。

API lab経路のfallback evidenceはPASS。ただしmodel weightsはrepositoryに無く、
native supplemental modelは `IsAvailable() == false` なので、実AI process kill
／登録済みIMEでのMozc継続のacceptanceではない。

## 3. GOAL.md Acceptance Criteria 判定

`PARTIAL` は一部layer/unitのevidenceしかない状態で、Goalの全製品条件として
PASSではない。

### Milestone 0 — Baseline

| 条件 | 判定 | 根拠 |
|---|---:|---|
| repository structure理解 | PASS | pinned submodule、Rust/Node/TSF/evalをinspection |
| Mozc build | PASS | Linux bridgeを実build |
| 既存test実行 | PASS | Rust 71、Node 3、portable C++ 3/3 |
| baseline performance測定 | PARTIAL | bridge 1000回p50/p95はあるがrelease baseline/AI比較と10,000 event条件ではない |
| 開発・test手順文書化 | PASS | build/test/architecture手順はREADME/docsにある |

### Milestone 1 — Candidate Pipeline

| 条件 | 判定 | 根拠 |
|---|---:|---|
| Mozcから実候補取得 | PASS（lab） | real bridge vertical testと1000回stress |
| 外部ranking layerへ候補を渡す | PASS（lab） | Rust pipeline/broker contract tests |
| 周辺文脈取得 | PASS（lab） | bounded context tests |
| 外部rankingで順位変更 | PASS（lab） | unit/API mock、validated permutation |
| AI無効時Mozc標準順位へ戻す | PARTIAL | API/CLI fallbackは実測、native TSFは未登録・inert |

### Milestone 2 — Rust Ranking Engine

| 条件 | 判定 | 根拠 |
|---|---:|---|
| Rust module build | PASS | clean/release/cross-target compile check |
| Mozc/C++接続 | PARTIAL | Unix framed listenerは実行、Windows named pipeはsource/checkのみ |
| candidate/context API | PASS | protocol/pipeline contractsとtests |
| ranking結果をMozcへ返す | PARTIAL | Rust/lab resultは返るがnative supplemental modelは未接続 |
| Rust障害時crashしない | PARTIAL | fake timeout/API mock killはpass、native broker/Windows restartは未実行 |
| benchmarkが存在 | **FAIL** | repository-owned benchmark target/保存済みAI ranking benchmarkがない |

### Milestone 3 — Local AI

| 条件 | 判定 | 根拠 |
|---|---:|---|
| 完全ローカルmodel ranking | **FAIL** | model weights/runtimeなし。loopback mockはprotocol testのみ |
| インターネットなしで動作 | **FAIL** | fixtureはnetworklessだが実AI model/local runtimeの証拠なし |
| timeout | PASS（lab unit） | 250ms pipeline、queue timeout、API fallback |
| cache | PARTIAL | bounded Rust cache testsはpass、native/model cache lifecycleは未実証 |
| AI failure fallback | PASS（lab） | queue/API/CLIのbaseline保持を確認 |
| model未起動でもMozc利用 | PARTIAL | API/CLIは実Mozcでpass、native TSF runtimeは未検証 |

### Milestone 4 — Contextual Conversion

| 条件 | 判定 | 根拠 |
|---|---:|---|
| 昨日こうえん→公園 | PASS（synthetic only） | `pipeline.rs`の3-case testは通る |
| 大学でこうえんを聞いた→講演 | PASS（synthetic only） | 同上 |
| 候補者をこうえんする→後援 | PASS（synthetic only） | 同上 |
| 3 case hard-code禁止＋未知case set | **FAIL** | `crates/kanai-core/src/pipeline.rs:994-1025` は3Contextsとexpected candidateの配列であり、未知の多数case/実Mozc fixtureがない |

### Milestone 5 — Personalization

| 条件 | 判定 | 根拠 |
|---|---:|---|
| 確定履歴学習 | PASS（lab） | Rust learning tests、API state flow |
| 学習情報永続化 | **FAIL** | browser localStorageとstateless APIのみ。native encrypted persistenceは未実装/未実証 |
| 誤学習削除/reset | PARTIAL | web/API resetはあるがnative profile保証がない |
| 個人情報を外部送信しない | PARTIAL | fixture secure testとloopback policyはpass、native secure-field matrixなし |
| 学習によるranking変化 | PASS（lab） | lab unit/API相当のtestあり |

### Milestone 6 — Fast / Slow AI Architecture

| 条件 | 判定 | 根拠 |
|---|---:|---|
| Fast Pathが大型LLMを待たない | PARTIAL | Rust `rank_fast`/no-I/O contractとtestsはpass、native経路はinert |
| Slow Path非同期 | PASS（Rust） | bounded queue/workers/timeout tests、native handoffは未接続 |
| Slow failureで入力停止なし | PARTIAL | loopback mock killとqueue testはpass、native/Windows runtimeなし |
| 文脈予測を次回候補に利用 | **FAIL** | 実装済みのlive prediction handoff/acceptance evidenceなし |
| cache strategy | PARTIAL | bounded Rust cacheはpass、native lifecycle/容量実測なし |

### Milestone 7 — Reliability / Performance

| 条件 | 判定 | 根拠 |
|---|---:|---|
| 1000回連続stress | PARTIAL | 実Mozc bridgeで1000/1000成功。broker/TSF/AI ON経路ではない |
| memory leak測定 | **FAIL** | RSS差分+1,444 KiBを1回記録しただけでleak解析/複数cohortがない |
| candidate ranking latency測定 | **FAIL** | 実測したのはMozc conversion latencyで、AI ranking benchmarkではない |
| p50/p95記録 | PARTIAL | bridge値は記録、Goalのrelease/key-to-preedit/10,000 events条件ではない |
| AI OFF baseline比較 | PARTIAL | API/CLIとmock比較は可能、native同一binaryの比較なし |
| AI ON長時間blockなし | PARTIAL | mock AIのlab evidence、native runtimeなし |
| crash recovery | **FAIL** | broker/model/Windows abrupt termination、restart、orphan processを実測していない |

### Milestone 8 — Windows IME Integration

| 条件 | 判定 | 根拠 |
|---|---:|---|
| Windows build成功 | **FAIL** | Rust cross-target compile checkは一部passしたがMSVC linker/TIP buildは未実行 |
| IME登録可能成果物 | **FAIL** | registration metadataが `unimplemented`、`dllIncluded=false`、installer/ZIPなし |
| 通常Mozc入力維持 | **FAIL** | 実Windows applicationでpreedit/candidate/commitを未実行 |
| AI ON/OFF | **FAIL** | supplemental modelは `IsAvailable=false`、native token handoffなし |
| AI OFFでも通常IME | **FAIL** | 登録済みTIPが存在しない |
| debug/release build再現手順 | PARTIAL | Rust releaseとportable scriptsは実実行、native release手順は未実行 |

## 4. Final Automated Acceptance

| Final criterion | 判定 | 実際の証拠/不足 |
|---|---:|---|
| clean build成功 | PARTIAL | Rust clean buildはPASS、Mozc/TSF/Windows release全体は未完 |
| unit tests全PASS | PASS（source） | Rust 71/71、Node 3/3。native C++/Windows runtimeは別条件 |
| integration tests全PASS | PARTIAL | real Mozc verticalとUnix broker probeはPASS、TSF/Windows integrationなし |
| contextual conversion tests全PASS | **FAIL** | 3 hard-coded synthetic casesは通るが未知case/実fixture条件を満たさない |
| stress tests全PASS | **FAIL** | bridge stressは1000回成功、Goalの製品経路stressは未実装/未実行 |
| benchmark結果を保存 | **FAIL** | 今回の数値はreport/一時ログに記載できるが、repository-owned AI ranking benchmark resultがない |
| networkなしでAI機能が動作 | **FAIL** | offline fixtureは動作するが実model/local AI runtimeがない |
| AI process kill後もMozc入力継続 | PARTIAL | loopback mock killでAPI labのMozc継続は確認。実AI process/登録IMEではない |
| Release成果物生成成功 | **FAIL** | Rust release binariesは成功、Windows TIP/install/package/registration成果物はなし |
| critical/high bugなし | **FAIL** | native AI非動作、登録不能、未知 contextual corpus/benchmark/Windows recovery未実証という高影響gapが残る |
| READMEにbuild/install/test/architecture | PARTIAL | build/test/architectureはあるが、検証済みinstall成果物・install/uninstall/upgrade手順がない |

## 5. 失敗項目・再現方法・原因候補・developerへの具体的 corrective work

### F-01: Native Windows TSF が製品として成立しない（Critical）

- **証拠**:
  - `platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/kanai_supplemental_model.cc:14-18` は `IsAvailable()` で `false`。
  - `platform/windows-tsf/registration/registration.json:4-13,21-31` は `source-only`、`unimplemented`、`tipDllPresent=false`、`runtimeVerified=false`。
  - `platform/windows-tsf/tsf/metadata/tsf-integration.json:75-89` はsession bridge、timeout/crash、secure field、UIA、registration等をfalse/open。
  - artifact inventoryに `KanaAI.TsfTip.dll`、installer、ZIP、registration receiptはない。
- **再現**:
  ```sh
  grep -RIn 'IsAvailable\|status\|dllIncluded\|registered' \
    platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/kanai_supplemental_model.cc \
    platform/windows-tsf/registration/registration.json \
    platform/windows-tsf/tsf/metadata/tsf-integration.json
  find .release dist target -type f \( -iname '*.dll' -o -iname '*.msi' -o -iname '*.zip' \)
  ```
- **原因候補**: pinned `SupplementalModelInterface` にtrusted session/generation/FieldClassとlive-result適用点がないため、意図的にinertなsource seamに留まっている。
- **次の一手**: upstream interfaceを安全に拡張するかTSF callbackからtrusted tokenを受け取るnative handoffを実装する。session open/key/edit/convert/rerank/commit/cancel/close、generation stale判定、exact permutationのlive candidate適用を実装し、Windows x64で `KanaAI.TsfTip.dll` を実buildしてNotepad/Edge/Office相当で登録・入力・commit・focus loss・restart・repair/uninstallを測定する。UIA/secure-field matrixも同時に閉じる。

### F-02: Contextual acceptanceが3 caseのsynthetic testに限定（High）

- **証拠**:
  - `crates/kanai-core/src/pipeline.rs:994-1025` は `昨日公園...`、`大学...講演...`、`候補者...後援...` の3-entry arrayとexpected candidateを使う。
  - `evals/README.md:3-5,185-189` と `evals/fixtures/quality-cases.json` はsyntheticであることを明示。
  - evaluatorのtop-1数値はfixture propertyであり、実Mozc candidate setの品質結果ではない。
- **再現**:
  ```sh
  cargo test --locked -p kanai-core pipeline::tests::bounded_context_disambiguates_multiple_homophones_without_keyword_tables -- --nocapture
  node scripts/run-quality-eval.mjs --strict --json
  ```
- **原因候補**: 実Mozc candidate fixtureのcapture/固定corpus、未知caseのheld-out set、finite local policyのground truthがない。
- **次の一手**: pinned Mozcから公園/講演/後援を含む実candidate JSONを再現可能にcaptureし、未知のhomophone/文脈/編集/数字/固有名詞を多数追加する。3 caseだけの期待値、goldからのpolicy生成、synthetic fixtureをacceptance resultとして扱わない。macro/micro top-k、MRR、NDCG、confidence intervalを同一candidate setで保存する。

### F-03: 実AI modelがなく、networkless local AIを証明できない（Critical）

- **証拠**:
  - repository内に `.gguf`, `.onnx`, `.safetensors` 等のmodel assetは0。
  - `target/release/kanai-broker` のdefault enhancement backendは disabled/provider unavailable。
  - `README.md:186-243` もmodelをbundle/downloadしない外部server前提と記載。
  - loopback mockはAI protocol testでありmodel quality/crash testではない。
- **再現**:
  ```sh
  find . -type f \( -iname '*.gguf' -o -iname '*.onnx' -o -iname '*.safetensors' \)
  env KANA_AI_MODEL=... KANA_AI_BASE_URL=... target/release/kanai-broker
  ```
- **原因候補**: 実装が「model runtimeを別reviewで導入する」seamに限定されている。
- **次の一手**: release support対象のlocal runtime/model digestを固定し、loopback以外への接続を拒否した実行可能adapterを統合する。model load、timeout、cache、kill/unavailable、candidate-set equality、secure field、native TSF token handoffをWindows release hostで実測する。用户在loopback serverを別途用意する状態を「AI機能動作」としない。

### F-04: Windows build/registration/runtime/stressの証拠がない（Critical）

- **証拠**:
  - `pwsh`なし。native Windows build/smoke未実行。
  - `cargo check --locked --target x86_64-pc-windows-msvc --workspace --all-targets` は `ring` custom buildで `lib.exe` not found、exit 101。
  - `cargo build --locked --release --target x86_64-pc-windows-msvc -p kanai-broker` は `link.exe` not found、exit 101。
  - brokerだけのcross-target check/passはcompile proofにすぎない。
  - `docs/PHASE1_QUALITY_GATES.md:59-76,102-103` は10,000 events、crash fault matrix、secure/UIAが必要と記載。
- **再現**: Windows runnerで `pwsh -File scripts/build-tsf-windows.ps1`、TSF smoke plan、registration scriptsを実行する。現在のWSL環境では `pwsh --version` が exit 127、Linux cross-linkも `link.exe` 不足でexit 101。
- **原因候補**: Windows SDK/MSVC/ATL/runtime hostがWSL環境にない。build harnessはregistrationを意図的に拒否している。
- **次の一手**: Windows 10/11 x64実機/CIを準備し、同一pinned sourceからTIP DLLとMozc dataを生成する。別user profileでregister/unregister、Notepad/Edge/Office、x64 host、focus/crash/restart、pipe ACL/reconnect、UIA、secure fieldを全件実行しreceiptをartifactに添付する。Linux portable testを代替にしない。

### F-05: benchmark/性能/memory gateが未定義（High）

- **証拠**: repository-owned benchmark target/保存済みAI ranking resultがない。実測した1000回Mozc bridge latencyは候補conversionであり、AI ranking、key-to-preedit、loaded brokerの性能ではない。RSSは単発の+1,444 KiBだけ。
- **再現**: benchmark targetを`find`/grepで確認。実bridge stressは `/tmp/opencode/verifier/stress-1000.json`。Windows releaseの10,000 event計画は未実行。
- **原因候補**: benchmarkがone-shot lab harnessに依存し、Goalのrelease threshold、固定環境、baseline/AI比較、memory toolが未定義。
- **次の一手**: benchmark binary/targetをrepositoryに追加し、warmup後のAI OFF/ON、loaded/idle broker、Mozc baseline、timeout、model unavailable、malformed responseを同一binary/candidate setで計測する。p50/p95/p99、RSS/heap、process/file descriptor countをCSV/JSONで保存しWindows release結果と紐づける。

### F-06: 学習のnative永続化・secure-field・UIAが未実装（High）

- **証拠**: browser stateはlocalStorage、APIはrequest stateを受け渡すstateless実装。docs/Release Contractはencrypted canonical store、native learning isolation、UIAを未実証と明記。`platform/windows-tsf/ui/candidate_window_uia.cpp:217-218` はtechnical provider stub。
- **再現**:
  ```sh
  grep -RIn 'localStorage\|encrypted\|stub\|not implemented' src docs platform/windows-tsf
  ```
- **原因候補**: lab learning state/browser workbenchと、native TSF hostのtrusted context/secure storage/UI provider実装が分離されている。
- **次の一手**: native profile store、誤学習reset/delete、crash recovery、secure desktop/password/protected/elevated/restricted token、UIA candidate/preedit matrixを実装し、encrypted-at-rest policyと実機テストをrelease gateとして自動化する。

### F-07: READMEのinstall条件が未達（Medium/High）

- **証拠**: `README.md:14-19,48-51,318-335` はno public TSF installer/ZIP/AI modelを明記。build/test/architectureはあるが、検証済みinstall成果物・install/uninstall/upgrade手順はない。
- **原因候補**: source seamとrelease artifactのstatusを正直に文書化したが、Goalの最終acceptance installsをまだ実装していない。
- **次の一手**: 実TIP/成果物が通った後、READMEへpinned toolchain、build、artifact hash、install、uninstall、upgrade、test、architecture、既知制限をREVで一致させて追記する。templateを実物と表記しない。

### F-08: 検証中に real broker test が一度失敗した（Process/High risk）

- **証拠**: clean workspace testの初回実行は `crates/kanai-broker/tests/mozc_session_vertical.rs` のgeneration assertionでexit 101。旧testはconvert後のgenerationを1のままとexpectedしており、broker probeでは `convert` がgeneration 2を返した。検証中に別エージェントがtestをgeneration 2/3/4/5/6へ修正し、最終現在のtestは20/20 passした。
- **再現**: 旧snapshotでは `KANAI_REQUIRE_MOZC_BRIDGE=1 cargo test --locked -p kanai-broker --test mozc_session_vertical -- --nocapture`。現行snapshotでは同コマンドを20回連続実行して20/20 pass。
- **原因候補**: 実装のconvert generation advancementとtest fixtureの期待値が不一致。別エージェントの並行編集により検証対象が途中から変わった。
- **次の一手**: 安定したcommit/treeでclean checkoutから全acceptanceを一度再実行し、testのgeneration期待値をprotocol的single sourceから生成する。release検証はdeveloper processと並行してsourceが変わらない固定snapshotで行う。

## 6. 結論

実Mozc bridge、lab Rust pipeline、bounded queue、portable contract、fixture
fallback、mock AI killの部分経路にはevidenceがある。しかしGoalの中心は
Windows実TIPとして登録・入力・AI ON/OFF・recoveryまで成立することである。
現状は `README.md`、`STATE.md`、registration metadata、Windows TSF docsが示す
通り development seam/inert状態である。

Final Automated Acceptance に未達項目があるため、**`.goal-complete` は
作成しない**。
