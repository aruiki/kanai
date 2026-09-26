# 次の作業キュー

2026-09-26 引き継ぎ時点。統括が実物とgit差分を確認して更新する。
状態: ready / active / blocked / review / done。doneには証拠が必要。

| ID | 状態 | 担当 | 範囲・受け入れ条件 | 依存 |
|---|---|---|---|---|
| W1 | blocked | tester/W1 → coordinator | 登録済みTIPを実アプリで検証。かな/漢字/候補/確定/取消/フォーカスを記録し、手動activation probeのE_INVALIDARGを製品／probeで原因分離。machine lock内で既存導入を変更せず証拠 receipt を返す。2026-09-25のW1自動試験は登録・ファイル・プロファイル・ctfmon・GUI読取をPASS、SendInputのAPI受付はPASSしたが、共有desktopで実key/mouse deliveryが全滅した。その後operatorは現行導入済み候補で文字入力・変換・かな切替成功を報告（user report、`.local/validation/w1/manual-user-report.json`）。候補表示・Enter確定・Esc取消・focus・restart・processは未報告で、残りは今回延期。**2026-09-26 更新**: 検証対象は新候補 `.local/installer-beta-final`（固定コミット `c729da4dc8fc0df163cd449eef5c90950cfa0c81`）。desktop validation harness は一度も実走しておらず、D-2 により**実行前のユーザー事前連絡が必要** | 実機資源（専有）、残項目は手動/専用desktop、実行前のユーザー承認 |
| W2 | ready | tester/W2 → coordinator | 公開候補 `.local/installer-beta-final`（固定コミット `c729da4dc8fc0df163cd449eef5c90950cfa0c81`、MSI SHA-256 `A9619B7BFCB72C6E554B3BAF700D8EA30657DEC50296D1E999CD644B06F4DF49`、Setup SHA-256 `B37CBC20CFD2D9E5A7349D7B45CB64E27AB09111EED04F47D28817B653E0854A`、UpgradeCode は旧候補と同一 `{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}`、ProductCode `{FBDCE95B-46CA-4959-8D36-26ABEE793117}`）の install / uninstall / reinstall / rollback 検証。Setup.exe の実際の一操作導入を確認し、**旧 `C:\Program Files (x86)\KanaAI` から新 x64 `C:\Program Files\KanaAI` への移行を必ず実測**する（UpgradeCode 同一で MajorUpgrade は効く設計だが別ディレクトリ移行は未検証）。候補は clean-source（`repositoryDirty=false` / `sourceIdentity.status=verified`）でビルド済みだが**未導入・未検証**。実行には UAC 承認とユーザーへの事前連絡が必要 | machine lock（専有）、UAC 承認、実行前のユーザー承認 |
| A1 | done | researcher/A1 → coordinator | Rust brokerとWindows TSFの接続済部分とlocal model未同梱の差分を調査。TSF optional pipe seam、Rust loopback adapter、session/generation検証、installer/process起動の欠落を確認し、現行build script・README・TSF transportをcoordinatorが照合。AI process/package/native evidenceは未実装 | なし |
| A1M | done | researcher/A1M → coordinator | Windows x64 CPU-only model/runtime候補を調査。Qwen2.5-1.5B-Instruct-GGUF公式revision/weight SHAとllama.cpp b11146 asset SHA、Apache-2.0/MIT、既存broker/TSF接続境界をcoordinatorがAPI/コードで照合。Qwen weight/runtime archiveは後続coordinatorが取得・hash検証済み。品質・Windows実行・packageは未承認 | A1コード経路と並行可 |
| A2 | blocked | — | WindowsローカルAI実装・配布を作業票単位で進め、実model/runtime・license/digest・package・障害時Mozc fallbackを実測。**2026-09-26 ユーザー決定 D-1**: 公開範囲は「AI無効のMozcベータ」に変更（以前の「AI同梱版のみ」は上書き）。GOALのlocal AI要件は削除しない。**残**: A2-06（composition root、実装机ではAIが起動しない — A2-08参照）、A2-07（native TSF実測）、A2-08（下記） | A1, A1M |
| A2-08 | blocked | — | **R-AI監査が確定した実装机のAI経路欠陥。** (1) **CRITICAL**: `installed_ai.rs:180,182` は `ai/manifest-v1.json` と `ai/STAGING-RECEIPT.json` を読むが、`build-windows-installer.ps1:1349-1350` が両者をpayload fileにすることを**明示的にthrowして禁じている**ため、実装机には存在せずAIは一度も起動しない（coordinatorが実コードで再確認済み）。raw receipt/sanitized manifestをpayloadへ入れるか、planをビルド時embedするかは**セキュリティモデル再設計を伴うのでcoordinator/ユーザーと確定**する。fallbackで糊塗しない。(2) HIGH `verify_connection` のdead code と (3) HIGH Windows既定 `LocalQualityOnly` は **A2-08a で完了**。**残**: (4) **F1の残余競窓** — `verify_endpoint()` の検証ソケットと reqwest の送信ソケットが別接続で、その間のTOCTOUは `local_model.rs`（所有外）に接続層のseamが要るまで排除できない。現状は C-1 でAI経路が起動しないため到達不能だが、**AI有効化の前に必ず塞ぐ**。(5) H-2 `%TEMP%` が日本語アカウントで非ASCII→`KeyFilePathRejected` で恒久off、(6) H-3 既定deadline 250ms に対し実測 1.46s | A2-06, A2-08a |
| A2-08a | done | implementer/A2-08a → coordinator | Rust AI経路の F1〜F7 を修正。**coordinator が統合検証して緑を確認**: `fmt --all --check` / `check --workspace --all-targets --locked` / `test --workspace --locked`（**181 passed / 0 failed / 2 ignored**、開始時166から+15）/ `clippy --workspace --all-targets --locked` すべて exit 0。F1 の配線（`installed_ai.rs:130` request guard → `verify_endpoint`、`ai_runtime.rs:637` readiness probe → `verify_connection` → `connection_owned_by`）は coordinator がコードで実読して production 到達を確認。F2 の既定 `Disabled` を確認。子所有範囲外の変更なし。**残**: F1 の残余競窓（A2-08 参照）、IGNORED 2件 | A2-06 |
| A2-06 | ready | implementer/A2-06 → coordinator | `crates/kanai-broker/src/bin/kanai-broker.rs` のcomposition rootにAI backend起動を統合。`RuntimeLaunchPlan`→`WindowsRuntimeProcess`→`RuntimeSupervisor` を接続し、per-process key fileの生成・loopback port確保・health待ち・graceful/force stopを実装。secretはkey fileへ書いて権限制限し、process引数・ログ・pipe応答へ出さない | A2-04, A2-05 |
| A2-07 | blocked | tester/A2-07 → coordinator | native TSFでAI ON/OFF、model kill、timeout、malformed response、Mozc fallback、password/protected fieldのno-contextを実測。Fast Pathにdisk/network/modelを同期投入しないことを測定で示す | A2-06; 実機資源（専有） |
| A2-01 | done | implementer/A2-01 → coordinator | Qwen2.5-1.5B公式GGUF + llama.cpp b11146 Windows CPU runtimeのpinned manifest、license/notice、safe fetch/stage script、offline validation testを追加。coordinatorが両inputのsize/SHA-256、runtime 51-entry layout/closure、production plan、synthetic staging、path/Archive安全、PowerShell 5.1、公式license正文を実測し、実model/実runtimeの`.local/ai-runtime/staged-real-v2` receiptを独立再検証。KanaAI install/Windows実行・quality・transitive notice/SBOMは未実施 | A1M |
| A2-02 | done | implementer/A2-02 → coordinator | broker外でAI runtimeを起動・停止・再起動するための、依存注入可能なbounded lifecycle supervisorと12 deterministic unit testsを追加。blocked start、caller drop、late child cleanup、replacement overlap、typed stop failureをcoordinatorが再検証。抽象層のみ。A2-05で実process adapterが接続済み。broker composition root統合・model応答は未実装 | A1M; A1接続結果で統合 |
| A2-05 | done | coordinator | `crates/kanai-broker/src/runtime_process_windows.rs` に実Windows process adapterを追加。`tokio::process::Command`＋Job Object（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）で `llama-server` を起動し、broker強制終了でも孤児化させない。key値はコマンドラインに出さず、非ASCIIコマンドラインは `NonAsciiCommandPath` でfail closed。純adapter 4 testsは常時実行、実process 1 testは `#[ignore]` で1.1GB staging時に`--ignored`明示実行。実測で起動・`force_stop`後のプロセス消失・残留物ゼロを確認。`cargo test --workspace` / `fmt --check` / `clippy --all-targets` すべてexit 0 | A2-02, A2-04 |
| RV2 | done | implementer/RV2 → coordinator | RV1のHigh findingsを修正。実TSF runtimeのschema 2 provenance-bound stage、immutable snapshot、post-build source/patch/overlay identity、PE構造/export検証、negative testsをcoordinatorが再検証。実buildの`ValidateOnly`もsnapshot validation PASS。full WiX/MSI/Setup、artifactBuildLinkage、installは未実施 | RV1 |
| A2-04 | done | implementer/A2-04 → coordinator | pinned manifest/receiptからllama-serverのoffline CPU launch planを生成するRust config seamと7 testsを追加。coordinatorが現在のmanifest status/hash/notice identityへ更新し、crate全56 tests/check/clippyを再検証。実process/token file/port確保/broker接続とUnicode install-path根本対応は未実装 | A2-01, A2-02 |
| A2-03 | done | implementer/A2-03 → coordinator | staged AI receiptをbroker/model/runtime/noticeのall-or-noneでMSI/Setup payloadへ統合。immutable snapshot、PE検証、relative-only sanitized manifest、40件のAI negative case、fragmentのsource path検証をcoordinatorが再検証しinstaller test exit 0。実model/wiX full build・AI起動・installは未実施 | A2-01, RV2 |
| D1 | done | implementer/D1 → coordinator | `platform/windows-tsf/installer/package/PACKAGE_README.txt` のみを編集。現状のx64開発preview・未署名・AIモデル非同梱・実アプリ入力／削除未検証・製品未完成を正確に明記し、MSI/Setupのユーザー導線と確認中Stubを修正。SHA-256は自身へ埋め込まない。README required-content/LF/UTF-8 test PASS、coordinatorが内容とhashを確認。restage/packageは別工程 | なし、公開表現はW1/W2待ち |
| O1 | done | coordinator | `scripts/start-opencode.ps1`のredirect時UTF-16LE debug JSONをraw byte/BOM decodeで修復し、CheckOnlyを再実行。v2.0.16 / Space Bunny Free / 6 agents、exit 0 | なし |
| RV1 | done | reviewer/RV1 → coordinator | installer hardening/package README/build-testの現差分を読み取り専用レビュー。source/runtime/patch identity、mutable build input、PE構造、full-build test、submodule/junction/atomic output、strict GUID/signingの不足を報告。編集・公開・実機操作なし。RV2でHigh findingsを修正する | なし |
| R1 | blocked | — | 固定ソース/ハッシュで独立ベータ検証、SHA256・ライセンス・導入説明とGitHub prerelease公開。**D-1（2026-09-26）により対象は「AI無効のMozcベータ」**（旧「AI同梱版のみ」は上書き）。AI同梱版のlicense/model/runtime要件は製品完成側（GOAL）の要件として残る。D-3により未署名公開可（開示義務は残る）、D-5により公開サイトは作らない。**2026-09-26 進捗**: 固定コミット `c729da4dc8fc0df163cd449eef5c90950cfa0c81`（tree clean）と clean-source 候補 `.local/installer-beta-final` を生成し、SHA-256・ProductCode/UpgradeCode・AI payload 0件・MSI File table 12行・Setup の MSI verbatim 埋め込み（offset 1204 / sizeDelta 5,120 / 先頭1MB バイト一致）・`NotSigned` を実測記録済み（STATE 冒頭の表）。`gh` は aruiki で認証済み。**残る blocker は W1/W2 の実測のみ** | W1/W2 |

初回の並列担当はW1（実機一人）、A1（読み取り専用調査）、D1（README限定実装）。
W1とW2を別々に同時インストールさせない。子にgit操作、公開、共有STATE更新を禁止する。
AI付き完成品と、Mozc主体の先行ベータを混同しない。未回答の公開範囲はSTATEに保持する。

## 2026-09-26 coordinator 区切りの状況

**引き継ぎ時のRust treeは壊れていた。** 前回の子（C-I1/C-I2/C-I3）が残した差分は
`cargo fmt --check` すら通っておらず、`Cargo.lock` が manifest より古く
`--locked` ビルドが exit 101 で全滅していた。coordinator が3件を実測で発見・修正し、
そのうえで緑chimemoした。詳細と正確な数値は STATE.md 冒頭。

- **C-I3 の欠陥を coordinator が発見・修正（CRITICAL）**: peer allowlist が
  `mozc_server_win.exe` を求めていたが実インストール名は `mozc_server.exe`
  （`build-windows-installer.ps1` のPE表と staged runtime で確認）。
  全TSF接続を拒否していた。回帰test追加済み。
- **C-I1 / C-I2**: coordinator が `cargo fmt --check` / `check --locked` /
  `test --locked`（166 passed / 0 failed / 2 ignored）/ `clippy --locked` を
  すべて exit 0 で実測。2件の ignored は 1.1GB payload 必須であり PASS ではない。
- **R-AI（reviewer、read-only）完了。** A2-06集成とA2-02/05を監査。
  CRITICAL 1件（H-1の前提となるC-1）、HIGH 3件、MEDIUM 4件、LOW 5件。
  **C-1（manifest/receipt未ship）とH-1（verify_connectionがdead code）は
  coordinator が独립に実コードで再確認済み。** → A2-08。
  「AI統合が完了」は不正確だった。成功経路は実装机で一度も実行されていない。
- **D-DESK（implementer）**: `platform/windows-tsf/validation/desktop/` のみを排他割当。
  W1自動化のための自己検証型デスクトップ機構。**デスクトップ操作は
  coordinator が事前に連絡してから行う**（ユーザー指示 D-2）。
- **D-LIFE（implementer）**: `platform/windows-tsf/validation/lifecycle/` のみを排他割当。
  W2（Setup.exeからのclean install / MSI install / TSF登録の実在確認 /
  clean uninstall / 再導入 / rollback 方針）のパラメタ化・再開可能・
  receipt出力ハーネス。**`-Execute` は coordinator が実行**（子には実行させない）。
  exit code のみで成功を判定せず、各phaseで独立に事後状態を観測する。
- **A2-08a（implementer）**: Rust AI経路の F1〜F7。F1 は接続所有権検証
  （`verify_connection`）の dead code を解消して API key と user text が
  未認証peerへ送られないようにする security fix。F2 は Windows既定を
  `Disabled` に統一（consent）。C-1（manifest/receipt未ship）と H-2（`%TEMP%`
  非ASCII）は**設計判断待ちとして明示的に除外**。

### 公開範囲の決定（2026-09-26）
- **D-1**: 公開は **AI無効のMozcベータ**（旧的「AI同梱版のみ」記録は上書き）。
- **D-3**: **署名は必須ではない**。未署名で公開可。ただし SmartScreen/publisher
  警告と「SmartScreen等を無効化しないこと」を README・Release body・同梱README に明記。
- **D-5**: **公開サイト（GitHub Pages）は作らない**。概要・インストール手順・
  制限・既知の未検証項目は **README.md と GitHub Release body** に集約する。
  `site-assets/` は未使用draft。`docs/GITHUB_PAGES.md` の「validatorが存在する」
  という虚偽の主張は訂正済み（リポジトリに validator は存在しない）。
- **D-6: プロジェクトの追跡を GitHub 上に置く（完了）。** ユーザー指示「プロジェクトとして
  GitHub に登録」。リポジトリは 2026-09-24 に public 作成済みで description と topics（10個）も
  設定済みだった。`homepage` が未公開の GitHub Pages URL を指していたので空にクリアした。
  ユーザーが `project` スコープの認証を承認したため、**public な ProjectsV2 ボードを
  作成して実体を登録済み**: <https://github.com/users/aruiki/projects/1>
  - 名前: `KanaAI delivery plan` / **public** / readme と shortDescription 設定済み
  - `Status`（Todo / In Progress / **Blocked** / Done）と `Priority`（P0/P1/P2）フィールド
  - **GitHub Issue 7件**（W1 / W2 / A2-08a / A2-08b / A2-07 / SBOM / ベータ公開チェックリスト）と
    label 9個（`gate` `w1-input` `w2-lifecycle` `ai-path` `security` `build` `release` `blocked` `verified`）を
    ボードに追加し、Status と Priority を設定済み
  - 現状: **P0 のブロッカーは #1（W1 実アプリ入力）と #2（W2 ライフサイクル）で、どちらも未実行**。
    W1 は desktop 実行の事前連絡待ち、W2 は W1 完了と昇格権限が必要
  - 参考: `gh project item-edit` は `--project-id` に**プロジェクト番号ではなくグローバル node ID**を
     요구する（`PVT_...`）。番号を渡すと GraphQL が global id を解決できず失敗する


### 公開範囲の変更（ユーザー決定 D-1 / D-2、2026-09-26）

- **D-1**: 公開は **AI無効のMozcベータ**。旧的「AI同梱版のみ」記録は上書き。
  installer は既に AI 4入力の all-or-none で **AI オフビルド即日可能**
  （`build-windows-installer.ps1:43-53`）。GOAL の local AI 要件は残る。
- **D-2**: デスクトップ自動検証機構の構築。許可済みだが、**操作前に必ず事前連絡**。

### ベータ公開までの確定順序（coordinator が直列で実行）
1. 本区切りのドキュメント更新（source 書込はここで終了）。
2. `stage-tsf-runtime.ps1` で schema 2 manifest を作り直す
   （現行 `.local/tsf-runtime-manifest.json` は schema 1 / files 0件で**使用不可**）。
   **この間 source へ一切書かない。** 旧記録のとおり並行 source 書込で必ず失敗する。
3. AI 入力4つを渡さない **Mozc-only 候補**を WiX/Setup までフルビルド。
4. `PACKAGE_README.txt` が D1 決定（AIモデル非同梱の明記）と整合するか確認。
5. D-DESK の harness で W1（実アプリ入力）。**その前にユーザーへ事前連絡**。
6. W2（導入・削除・再導入・rollback）。machine lock 専有。
7. source を clean にして commit/push → 独立 verifier → prerelease 公開。
   `.goal-complete` は作らない。

---

## Codex release audit 2026-09-26
- C-R1 active: reviewer agent; read-only audit of native TSF to broker startup and AI binding. No source edits, builds, machine operations, git mutations, or publication.
- C-R2 active: reviewer agent; read-only audit of AI runtime composition/security and installer payload contract. No source edits, builds, machine operations, git mutations, or publication.
- C-I1 active: composition implementer; exclusive crates/kanai-broker/src/bin/kanai-broker.rs and new sibling module(s) under src/bin/kanai-broker/. Integrate background AI startup, retain lifetime, fail-soft queue, bounded installed config. No other edits/builds/machine/git operations; parent runs tests.
- C-I2 active: runtime reviewer becomes implementer; exclusive crates/kanai-broker/src/ai_runtime.rs, runtime_process_windows.rs, runtime_supervisor.rs and their tests. Fix key CREATE_NEW, child ownership/readiness port-race fail-closed, no builds until parent schedules. Parent owns Cargo.toml and local_runtime.rs.
- C-I3 active: native implementer; exclusive platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/pipe_broker_client.cc/.h and crates/kanai-broker/src/pipe_windows.rs. Implement worker-only bounded hidden broker launch and exact installed peer path validation. No stage/build/machine/git actions; parent verifies.
