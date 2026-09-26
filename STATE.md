# 最新の引き継ぎ — 2026-09-26 W2 ハーネスの COM 経路を実測で修正 / 実機が install state を回答しない blocker を新規発見

Status: NOT COMPLETE / public beta NOT RELEASED / `.goal-complete` 未作成

基準HEAD: `940ddd3`（origin/main との分岐を解消した merge commit、**tree clean**）。
ベータ候補 `.local/installer-beta-final` は §6 のとおり内容・SHA-256 とも未変。
D-1〜D-5 の決定はそのまま有効（下の履歴区切りを参照）。

## 1. W2 ハーネスの Windows Installer 呼び出しを「実際に答える束」だけで直す（`d98771a`）

前セッションは `ProductInfo` を直接呼び出す修正を**未コミットのまま停止**していた。
その形だけでは不十分で、そのままでは W2 を再実行しても同じ箇所で落ちる。実測結果（読み取り専用）:

| 呼び出し | 実測結果 |
|---|---|
| `InvokeMember('Products', InvokeMethod)` | `0x80020003 DISP_E_MEMBERNOTFOUND` |
| `InvokeMember('Products', GetProperty)` | **182 件の GUID 文字列**（`Products` はメソッドではなく **プロパティ**） |
| `$inst.Products`（直接） | `$null`。`@($null).Count` が 1 になるのが罠 |
| `InvokeMember('ProductInfo', …)` | 全 product・全 property で `0x80020003` |
| `ProductInfo` の直接呼び出し（`ProductName` / `LocalPackage` / `InstallLocation` / `VersionString` / `InstallDate` / `InstallSource`） | 実値 |
| `ProductInfo` の直接呼び出し（`UpgradeCode` / `InstallState`） | `ProductInfo,Product,Attribute` |

修正内容:

- `Products` は **GetProperty** で読み、brace 付き GUID だけを残す reader にした。null 要素が
  後の比較に到達しないよう、GUID 形式でない要素は捨てている。
- `ProductInfo` は直接呼び出しに統一した。
- `UpgradeCode` は **cached MSI の Property テーブル**から読む。候補 identity gate が既に
  使っている reader をそのまま流用したもので、**同じ authority に対して2つ目の弱い道を
  作らない**。実測で 180 cached MSI を開いて 4.0 秒、KanaAI 2件を正しく同定した。
- `InstallState` は Property テーブルに**存在しない**ため `MsiQueryProductState` の
  out 引数形を使う。戻り値はエラーコードであり、状態は out パラメータで受け取る。
- 生の状態名からハーネス語彙への変換を、副作用のない純関数に切り出した。`found` の
  `installState` は**生のまま**を保つ。entry point が `^(DEFAULT|LOCAL)$` で判定しているため、
  ここを `installed` に広げて「導入済み」を「不在」と誤報告する事故を避ける。
- phase 間で結果をキャッシュしていないのは**意図的**。lifecycle harness が前の答えを
  再利用すると「その時点の state」を観測しなくなる。

## 2. 【新規・CRITICAL】実機が install state を回答しない。この machine では W2 が成立しない

ユーザー承認のうえ、管理権限・**読み取り専用** probe（install/uninstall/ファイル変更なし）で実測:

- `MsiQueryProductState` は**有効な全 product code** に対し `ERROR_ACCESS_DENIED`。
  P/Invoke 3 形（`out int` / `ref int` / `ExactSpelling`+`SetLastError`）すべて同一結果。
  一方 無効な製品名では `-1`、全ゼロ GUID では `-2` を返す。**呼び出しは正しく dispatch され、
  installer が回答を拒否している**ことの証拠になる。
- **管理権限あり/なしで同じ rc**。これが権限問題ではなく machine 側の問題である根拠。
- `Installer.ProductInfo('InstallState')` も全 product で例外。
- `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\Components` **キー自体が存在しない**。
  一方 `Classes\Installer\Products` 171 件、`Features` 169 件は存在。per-machine component 登録が欠落。
- OS build 26200、msiserver は Manual/Stopped、installer policy key は無し。

### これが最も危険だった理由と、その修正（`b0092f9`）

`Get-KanaAiLifecycleProductState` の docstring は "unknown is never treated as absent" と
明記している。しかし **entry point は `$targetState -eq 'installed'` のときだけ拒否**していた。
回答不能な状態はそのまま素通りし、後段の `^(DEFAULT|LOCAL)$` フィルタも一件も一致せず、
**この machine に KanaAI が2件登録されているのに「未導入」と報告して3件目を導入する**
挙動になっていた。落ちない false negative であり、記録 gate として最も危険な形である。

`-Execute` は receipt に `INSTALL-STATE-UNDETERMINED` を critical で記録し、
「回答できない状態は不在の証拠ではない」と明記し、operator の対処を示し、
**どの phase にも触れる前に exit 2** する。ゲートは意図的に pre-existing-target 判定の
**前**に置いた。そうでなければその判定は、何も拒否されないまま到達してしまう。

**これは W2 を可能にしたのではなく、machine の実条件を、根拠のない「クリーンな
ベースライン」として報告していた問題を直しただけである。**

## 3. 実機状態の記録（訂正を含む。前回の私の誤りを撤回する）

確実に言えること:

- `Installer.Products` 列挙に KanaAI が**2件**。`{307FE767-…}`（旧 x86 ビルド）と
  `{FBDCE95B-…}`（新候補 `{c729da4…}` 版）。
- 新候補は cached MSI `32193a0.msi`（18,427,904 bytes）を持つ。`ProductInfo.InstallDate = 20260926`（本日）。
- `C:\Program Files\KanaAI` は**存在しない**。`C:\Program Files (x86)\KanaAI` のみ 12 ファイル。
- Uninstall レジストリにも 2 件（`WindowsInstaller=1`）。

**撤回**: 前回「両 products とも installState=5 (installed)」と報告したが、これは
MsiQueryProductState の P/Invoke シグネチャを間違えた**私の誤り**だった。正しくは
`UINT MsiQueryProductState(LPCWSTR szProduct, INSTALLSTATE *pInstallState)` で、
戻り値はエラーコード、状態は out パラメータである。誤った形で読むと `5` は
`ERROR_ACCESS_DENIED` と `INSTALLSTATE_DEFAULT` という**同じ数字の2つの意味**を取り違える。
ST-69 がこの署名を固定し、**source 内に swap 形が存在しない**ことを検査する。

**未確定（断定しない）**: 新候補のファイルが何故無いのか。registration のみ／rollback 不完全／
手動削除 の判別は、`MsiGetComponentState` も rc=6 を返し、かつ `Installer\Components`
キーが存在しないため**この machine では取得できない**。したがって §2 の blocker が解けるまで
「partial registration」と断定せず、記録された document として扱う。

## 4. git の分岐を解消（`940ddd3`）

main が 9 ahead / 1 behind で分岐し、**両側が STATE.md を編集**していた。origin/main の
`3bf40f2` は 2026-09-25 17:30 の、当時の 523 行 STATE.md への文書整合コミット。
merge は改名済みの archive 区画に落地し、source ファイルは両側とも変更なし（STATE.md のみ）。
解決後は **0 behind / 10 ahead**。**未 push**。

## 5. 回帰テスト

`Invoke-KanaAiLifecycleValidationSelfTest.ps1`: **73 cases / 73 passed / 0 failed**、exit 0。
PowerShell 5.1 parser: 3 ファイルすべて 0 errors。
`-PlanOnly` は実候補に対して exit 0、machine interaction counter は全 0 のまま。

今回追加した regression（すべて非空虚であることを別途証明した）:

- **ST-67** `Products` は method ではなく property として束縛され、null 要素のフィルタがあること
- **ST-68** `ProductInfo` を `InvokeMember` で叩かず、`UpgradeCode` は cached MSI から読むこと
- **ST-69** `MsiQueryProductState` は out 引数形のみ・swap 形が存在しない・非 0 rc は状態を返さないこと
- **ST-70** 状態語彙の変換（機械 非接触）と、entry point が**生の名前**で判定し続けること
- **ST-71** **どの case も他の case body にネストしていないこと**／id が一意であること
- **ST-72** 回答不能時は phase に進まず拒否すること（**位置**も entry point 上で検査）

**非空虚性の証明**（実 source には触れず、`.local` の scratch copy で欠陥を再導入し、実際に落ちること）:

- `Products` を `InvokeMethod` に戻し、`ProductInfo` を `InvokeMember` に戻し、
  シグネチャを 1 引数形に戻す → **72 cases / 3 failed（ST-67, ST-68, ST-69）/ exit 1**
- 拒否ゲートを `if ($false)` にする → **73 cases / 1 failed（ST-72）/ exit 1**
- 各回とも実 source が未変更であることを併せて確認した。

**前回の session 由来の構造的欠陥も修正**: ST-63〜ST-66 が ST-62 の body に、ST-66 が
ST-65 の body にネストしていた。3 連続で修正が body を閉じずに追記した結果である。file は
parse され全て `ok` に見えたが、**外側の case は独立に失敗できず、「ST-62 ok」は ST-62 に
ついて何も言っていなかった**。ST-71 で構造的に再発防止する。

## 6. 固定コミット上の clean-source ベータ候補（`.local/installer-beta-final`、**未変更**）

再ハッシュして STATE の旧記載と一致することを確認した。

| 項目 | 実測値 |
|---|---|
| MSI SHA-256 | `A9619B7BFCB72C6E554B3BAF700D8EA30657DEC50296D1E999CD644B06F4DF49`（18,427,904 bytes） |
| Setup SHA-256 | `B37CBC20CFD2D9E5A7349D7B45CB64E27AB09111EED04F47D28817B653E0854A`（18,433,024 bytes） |
| 署名 | MSI/Setup とも `NotSigned`（D-3 で許容、開示義務は残る） |
| ProductCode / UpgradeCode | `{FBDCE95B-46CA-4959-8D36-26ABEE793117}` / `{381B4CC9-…}`（旧候補と同一） |
| AI payload | **0 件**。`localAiIncluded=false`、manifest は `verified=false` を正直に記録 |

## 未解決・未検証（隠さない）

- **W2（install / uninstall / reinstall / rollback）は、依然として 1 phase も未観測。**
  今回判明した installer 非回答のため、**この machine では W2 を成立させられない**。
- **W1（実アプリ入力）未実施**。desktop validation は新候補で一度も走っていない。
  旧試行は登録・ファイル・プロファイルは PASS したが共有 desktop 上の SendInput が全滅した。
  人が別途、文字入力・変換・かな切替成功を報告（user report のみ）。D-2 の事前連絡が必要。
- AI 経路の CRITICAL C-1 / A2-08 は残る。**実装机で AI は一度も起動しない**。
- 独立 verifier の GOAL 全条件判定は未実施。`.goal-complete` は作らない。

## 解決を待つ判断（ユーザー）

実機 §2/§3 の扱い。**どれを選ぶ場合も W2 の証跡は、その machine で取ってから公開する**。

1. **この machine の installer 登録を修復する** — `Installer\Components` 欠落の原因を特定し、
   既存 KanaAI 2件を正しい状態で再登録してから W2 を正式に開始する。
   原因不明のまま「修復」すると evidence の前提が壊れるため、まず**原因の特定**が先。
2. **回答する machine（クリーンな Windows 10/11 VM を含む）に移して W2 を取る** — W2 の
   gate としてこちらが正当である。開発機のこの状態は legitimate な証跡ではないため、
   記録に留める。
3. **W2/W1 とも未観測のまま公開を先行させる** — `docs/PRODUCT_RELEASE_CONTRACT.md` の
   「未検証のインストーラーを公開する許可ではない」に反する。**非推奨**。

## 次の具体的作業

1. 上記 1〜3 の判断をユーザーと確定する。
2. 決定後、`-Execute` を machine lock 専有・UAC 承認のもとで実行する。
3. W1 は D-2 の事前連絡 → 承認後に desktop validation。
4. 結果を STATE / `docs/PROGRESS.md` / `docs/WORK_QUEUE.md` に反映する。
5. push（main は 0 behind / 10 ahead、**未 push**）。
6. `gh release create --prerelease`。AI 非同梱・未署名・SHA-256・既知制限を Release body に明記。
   D-5 により公表面は README と Release body のみ。

---

# 履歴（2026-09-26 前半区切り）— coordinator再開 / 引き継ぎRust treeの defective 发现と修正

Status: NOT COMPLETE / public beta NOT RELEASED / `.goal-complete` 未作成

基準HEAD: `2e0630c23ce7242d020a3c571724c7c67b336216`（未変更・未コミット多数）。
本区切りは「前回の子（C-I1/C-I2/C-I3）が残した未検証差分を coordinator が実測で検査し、
壊れていた箇所を直して緑に戻した」記録である。

## ユーザーの今区切りの決定（2026-09-26）

- **D-1: 公開範囲を「AI無効のMozcベータ」に変更。** 以前の記録にある「ユーザー決定により
  AI同梱版のみを対象とする」（この文書の下の旧区切り）は本決定で**上書き**された。
  これは `docs/PRODUCT_RELEASE_CONTRACT.md` の「GitHub prerelease（ベータ）」区分の話であり、
  GOAL.md の local AI 要件を削除・縮小したものではない。AI は完成条件として残る。
  成果物はAIを同梱せず、AI込みとして宣伝せず、その旨をrelease noteと同梱文書へ明記する。
- **D-2: デスクトップを動かす自動検証機構の構築を指示。** 許可は给出済みだが、
  **デスクトップを操作するたびに coordinator が事前連絡する**運用とする。
  今回まだデスクトップ操作は1件も行っていない（W1は依然 unverified）。
- **D-3: コード署名は必須ではない。** ユーザーが「署名はなくても良い」と決定。
  human blocker を1つ解除した。**ただし信息披露義務は残る**: 未署名であること、
  SmartScreen/publisher警告が出る可能性、SmartScreen/Smart App Control/anti-virus/
  enterprise policy を無効化しないこと、SHA-256・対応ソース・ライセンス・既知制限を
  外部に添付すること。`docs/GITHUB_PAGES.md` に規定として明記した。
- **D-4: ベータ公開可否の質問に対し、現状は「まだ公開不可」と回答。** blocker は
  実装ではなく (1) W1/W2未実施、(2) 固定コミット未作成（tree は tracking変更32・
  未追跡30、新規依存 `sha2` を含む dirty）、(3) ワンクリックInstallerの実測未了。
  `site-assets/index.html` は現在 `NO BINARY YET` と記載があり、現時点では正直。
  成果物を出す**前**に実ハッシュと実検証結果で書き換える必要あり。
- **D-5: 公開サイト（GitHub Pages）は作らない。** 「概要・インストール手順などは
  すべてgithubに書いてください」とのユーザー決定。`gh-pages` は公開しない。
  公表_surface は **README.md と GitHub Release body のみ**。
  `docs/GITHUB_PAGES.md` を「未公開・参考draft」と明記し直し、
  `site-assets/` は未使用のlocal draft として保持（polishも公開もしない）。
  併せて `docs/GITHUB_PAGES.md` が「page validatorがリンクと日本語内容を検査する」
  と主張していたのに対し**リポジトリに validator が存在しなかった**件を正直に訂正し、
  README を新決定（無署名・Mozcのみ・サイトなし）に合わせて更新した。

## 今回 coordinator が実コードで発見し、修正した欠陥（いずれも実在・実測）

1. **CRITICAL — TSF→broker の全接続を拒否していた（子 C-I3 の差分）**
   `crates/kanai-broker/src/pipe_windows.rs` の `WindowsPeerAuthenticator` が、
   接続元画像の許可リストを「broker と同ディレクトリの `mozc_server_win.exe` への完全一致」にした。
   しかし actual なインストール名は **`mozc_server.exe`** である。根拠（実測）:
   `scripts/build-windows-installer.ps1` の PE payload 表が `mozc_server.exe` を宣言し、
   `RuntimeFiles` コンポーネントグループを `INSTALLFOLDER` に生成する。
   staged runtime 実体も `.local/tsf-runtime-v5/mozc_server.exe` = 22,333,440 bytes。
   結果として**実際のMozcサーバーが全面的に拒否**され、パイプライン認証は全TSF通信をgateしている
   ためMozc baseline経路ごと落ちるaire。子のunit testは誤った名前 그대로assertしていて
   「vaquousに通っていた」。`MOZC_CLIENT_IMAGE_FILE_NAME` 定数へ切り出し、実装 names を正し、
   `mozc_server_win.exe` を明示的に拒否する回帰testを追加した。
2. **HIGH — `Cargo.lock` が manifest より古く、`--locked` ビルドが全滅**
   `crates/kanai-broker/Cargo.toml` に `sha2 = "0.10"` が追加されているのに
   `Cargo.lock` が更新されておらず、`cargo check --locked` が
   `cannot update the lock file ... because --locked was passed` で exit 101 になっていた。
   ローカル cargo cache には `sha2` 匣ファミリーが存在しなかった。index 到達性は実測.HTTP 200。
   lock を最小再生成し、**8 package 追加**: `sha2` / `digest` / `block-buffer` /
   `crypto-common` / `generic-array` / `typenum` / `cpufeatures` / `version_check`。
   既存 package の version bump は無。→ **この差分が做到的後に记录的された
   「`--locked` 系が全部緑」はすべて無効**。
3. **MEDIUM — 自分の `cargo fmt` が executable な source を壊した（管理与え方）**
   `runtime_process_windows.rs` の `verify_connection` の `unsafe {}` を先頭にした
   連鎖式に対し、rustfmt が `&&connection_owned_by(...)` という構文エラーを生成した
   （E0308 2件）。却在していたolet構文を named operand (`let alive = || ...;`) に
   書き換えて、rustfmt 再現性ありで overt 修復した。
   **教訓: `fmt --check` は「整形済み」であって「compileする」ことではない。
   整形後に必ず `cargo check` を回すこと。`fmt --check` PASS だけLeaksして accept してはいけない。**

## 検証結果（本区切りで coordinator が実測 / build lock 内）

- `cargo fmt --all --check`: exit 0
- `cargo check --workspace --all-targets --locked`: exit 0
- `cargo test --workspace --locked`: **exit 0** — 合計 **166 passed / 0 failed / 2 ignored**。
  内訳: kanai_api 8、kanai_broker lib 12、kanai_broker bin 3、ai_runtime 28(+1 ignored)、
  contract 10、enhancement 7、local_model 9、local_runtime 12、mozc_session_vertical 3、
  runtime_process_windows 9(+1 ignored)、runtime_supervisor 14、session_contract 11、
  kanai_core 28、kanai_mozc 9、bridge_vertical_slice 3。doc-tests 0。
  **ignored 2件は 1.1GB staged payload と実 `llama-server.exe` を要求するものであり、
  `#[ignore]` は PASS の証拠ではない。**
- `cargo clippy --workspace --all-targets --locked`: exit 0
- 新規/更新 test が実際に動いた証拠: `pipe_windows::tests::installed_client_image_name_matches_the_installer_payload` ok、
  `pipe_windows::tests::image_allowlist_requires_exact_sibling_or_explicit_override` ok。
- mozc submodule: `git -C third_party/mozc status` exit 0、superproject gitlink と mozc HEAD は
  ともに `13c98988247aa711d99db9e348ec2a597d14b5cd` で一致。

## 今回の確認した事実（次の一手の前提）

- **installer は既に AI オフモードを持つ。** `build-windows-installer.ps1` は
  `-BrokerExecutable / -AiRuntimeDirectory / -AiManifestPath / -AiReceiptPath` の
  4つを **all-or-none** で判定し（49-53行）、**どれも渡さなければAI payloadは入らない**。
  したがって D-1 の「AI無効ベータ」はコード改変なしで**本日ビルド可能**。
  逆.Contentious に部分指定は設定エラーとして拒否される。
- **staging manifest は依然 stale。must restage。** `.local/tsf-runtime-manifest.json` は
  `schemaVersion=1`、`runtimeFiles` 0件、README record なし。使用不可。
  最新の正しいものは `.local/tsf-runtime-manifest-v8.json`（schema 2、12 files、
  README.txt 7,879 bytes / SHA-256 `53964D0BF505F310...`）だが 02:25 生成で、
  以降のsource差分のため `sourceIdentity` が一致しない。
  → **候補ビルド前に `scripts/stage-tsf-runtime.ps1` の再実行が必須。**
  STATE の過去記録のとおり、**restage＋build を回す間は source へ一切書かない（read-only のみ）**。
- **AI同梱ビルドは broker digest の re-pin 待ちで現状ブロック。**
  `local_runtime.rs` の `PINNED_BROKER_SHA256`（`85F4930D…`）、`manifest-v1.json` の `broker` ブロック、
  `build-windows-installer.ps1` の `$aiPinned` の3箇所が同一 digest を共有する。
  Rust source を変えたので broker を rebuild すると digest が変わって3箇所とも不一致になる。
  D-1 のベータは broker/model を含まないのでこの制限を回避する。
- `sha2` 追加は privacy/sbom 義務を発生させる（MIT OR Apache-2.0、RustCrypto）。
  SBOM / `THIRD-PARTY-NOTICES.txt` / transitive notice への反映は未了。

## 委任中（子。編集範囲は排他。git/共有STATE/公開は coordinator のみ）

- **R-AI（reviewer、read-only）**: A2-06 集成（`installed_ai.rs` / `bin/kanai-broker.rs`
  windows_listener）と A2-02/05（`ai_runtime.rs` / `runtime_process_windows.rs` /
  `runtime_supervisor.rs`）の回帰・プライバシー・blocking discipline・secret 漏えい・
  fail-soft・vacuous test を監査。C-I3 の指摘1件は修正済みなので再報告しない。
- **D-DESK（implementer、排他 `platform/windows-tsf/validation/desktop/`）**:
  W1 を自動化するための **自己検証型** デスクトップ機構。
  「API が受理した」を delivery の証拠にせず、毎ステップで対象の text を独立 readback する。
  window station / desktop 名の一致を preflight で名前付き finding として出す。
  `-PlanOnly`  desktops に触れない。**child にはデスクトップを一切操作させず**、
  実 run は coordinator が連絡して行う。

## R-AI（reviewer、read-only）監査結果 — coordinator が2件を独립再確認

監査範囲: A2-06集成（`installed_ai.rs` / `bin/kanai-broker.rs` windows_listener）、
A2-02/05（`ai_runtime.rs` / `runtime_process_windows.rs` / `runtime_supervisor.rs`）。
CRITICAL 1 / HIGH 3 / MEDIUM 4 / LOW 5。**coordinator が実コードで再確認した2件のみを
確定事実として扱う**（子の報告をそのまま採用しない）。

- **C-1【確定・CRITICAL】AI経路は実装机で一度も起動しない。**
  `installed_ai.rs:180,182` は install root の `ai/manifest-v1.json` と
  `ai/STAGING-RECEIPT.json` を読む。一方 `build-windows-installer.ps1:1349-1350` は
  **raw receipt と sanitized manifest が payload file になること自体を throw で禁じている**
  （`$aiSanitizedManifestFileName = 'PACKAGE-MANIFEST.json'` が唯一のshippableなJSONだが、
  これは schema が違い `build_runtime_launch_plan` の要件を満たさない）。
  両ファイルは build input の `ai-source/` にしか存在せず、WiX fragment は
  `AIFOLDER`/`model`/`runtime`/`licenses` のみを生成する。
  → 影響: 実装机で `eprintln!("... manifest unavailable or oversized")` が1行出るだけで、
  .ptrn変換は全て無言でMozc baselineのまま。**「AI統合完了」という旧記録は誤り。**
  修正は payload に manifest/receipt を含めるか plan をビルド時embedするかの
  **セキュリティモデル再設計**を要する（`ai/` は Program Files 配下）。
- **H-1【確定・HIGH】接続所有権検証が dead code で、key と user text を未認証peerへ送る。**
  `PinnedAiRuntime::verify_connection` (`ai_runtime.rs:656`) の**呼び出し元は無い**
  （定義3箇所、連鎖は `ai_runtime.rs:661`→`runtime_supervisor.rs:427`→
  `runtime_process_windows.rs:478` のみ）。よって TCP table で接続の所有pidを
  照合する `connection_owned_by`（約68行）が到達不能。
  `probe_once` は `127.0.0.1:<予約済port>` に接続し `200` を返す**誰_CPUFractionに**応答するかを
  見ない。予約portを奪ったlocal processが `GET /health` に 200 を返せば `Ready` になり、
  `local_model.rs` が **API key + preedit + context + Mozc candidates** をそのprocessへ送る。
  → trait doc に書かれた「secret送信前に検証しそのsocketを使う」契約が未履行。
  なお `reserve_loopback_port` のTOCTOU commentが主張する「失敗は型付きerrorになる」は
  「200应答しない勝者」の場合だけ正しい。
- **H-2【HIGH】key file root が `%TEMP%`**: 日本語アカウント名では
  `C:\Users\太郎\AppData\Local\Temp` が非ASCIIで、`ai_runtime.rs:370-373` が
  書き込む前に `KeyFilePathRejected` で拒否 → 対象ユーザーでAIが恒久off、
  診断は1行のstderrのみ。`#[ignore]` テストはASCII junctionでこれを回避している。
- **H-3【HIGH】既定ではAI結果は採用されないのに全コストだけかかる**（既知のlatency不整合）。
- **H-4【HIGH】Windows既定が `LocalQualityOnly`**（`EnhancementPolicy` の `#[default]=Disabled` と逆）。
  環境変数未設定でもpreeditをmodelへ送る意図。Unix側は逆で未設定ならoff。
- **MEDIUM**: M-1 probeの`cancellation`非反映（接続後にread timeoutが最大30s）、
  M-2 `Drop`順序でkey file削除が`closed`設定より先行し再起動窓で
  削除済みkey fileを参照しうる、M-3 runtime死後にsupervisor未再確認でdead backend残留、
  M-4 `KeyDirectory` cleanup失敗を無言破棄＋hard killで`KanaAI-*`が残留。
- **LOW**: `random_token_reference` が実際の隔離に使われていない（コメントが保証を主張）、
  key が `LocalOpenAiBackend.api_key: Option<String>` に非zero化のまま二重残存、
  key file path（アカウント名+nonce）がcommand lineに載る。
- **推奨のtest修正**: DACL test がSIDの**具体値**を検証していない、
  key非ASCII test の片方の分岐がadapterの出力ではなくplan側のvectorを検査している、
  private directory chainの保護DACLを検査していない、orphan test がprobe失敗でvacuous。
- **確認して「問題なし」と確定した点**（子の報告を鵜呑みにせず記録）:
  listener は readiness を待たない、`run()` の全失敗は `&'static str` で
  pipe listener/queue/sessionへ伝播しない、key/preedit path は model で-block しない
  （session lock を clone 後に解放）、`std::sync` guard が `.await` を跨がない、
  key は log/error/`Debug`/`Display`/pipe応答に一切出ない、key file は
  `CreateFileW` 時点で保護DACL+`CREATE_NEW`+`FILE_FLAG_OPEN_REPARSE_POINT` なので
  継承ACE露出の窓が無い、job object により早期returnでもchildは必ず終了する、
  H1の有界化（`stop_confirm_timeout`）は全経路を実際に拘束する。
- **未確定（build/実機が必要）**: `verify_connection` をwiredした際
  `windows-sys` の `Win32_NetworkManagement_IpHelper` feature が
  `GetExtendedTcpTable`/`MIB_TCPROW_OWNER_PID` を提供するか
  （現在dead codeなので静かに壊れていても看不出来）。
  coordinator が既に `--locked` ビルド可能にしてあるので、これは次のbuildで確定する。

## デスクトップ検証ハーネス（D-DESK）— coordinator が実測検証

`platform/windows-tsf/validation/desktop/`（ソース7ファイル、生成物は `runs/`）。
子の報告を鵜呑みにせず、**coordinator が自分で実行して確認した**。

- `-SelfTest` → **53 case / 53 passed / 0 failed, exit 0**
- `-PlanOnly` → plan `kanai-desktop-input-v1` **36 steps validated, exit 0**
- ゲート無しで実走 → **`refused` exit 3**（`-AllowDesktop` と `-LockConfirmed` の欠落を
  明示して拒否し `run-refused` receipt を書く）。**ハーネスは desktop に触れない**
- **核心設計をコードで実証**: `Resolve-KanaAiValidationStepVerdict` の param は
  `Assertion`/`Executed`/`ReadbackAvailable`/`Match`/`BlockedReason`/`Reason` の6個のみ。
  `apiOk`・`sentEvents`・`lastError` は**構造的に存在しない**。
  判定順序は `BlockedReason`→`record_only`→`Executed`→**`ReadbackAvailable`→`Match`** で、
  `ReadbackAvailable` を先に検査するため「API成功・readback不変」は `failed`、
  「readbackなし・Match=true」は `delivery_unconfirmed` になる。
  総合 status (`Resolve-KanaAiValidationOverallStatus`) にも
  `delivery_unconfirmed` が `passed` に昇格する経路は無い（`failed` > `incomplete` >
  `unconfirmed` > `passed`）。→ 前回の「API受理を delivery 証拠にした」欠陥が
  構造的に再発しない。
- canary は `kanaai`（6キー）→ `かなあい`。それ以外の入力は plan validator が拒否。
- 較正は対称トグル（toggle→commit→toggle→commit）で IME-on 方向を仮定せず、
  収束しなければ方向依存ステップは全て `blocked`（never passed）。
- INJ-00 で injector 自身の loopback window に 먼저送达確認し、injector 破損時は
  「IMEのせい」にせず injector 破損として記録する。

**未検証（隠さない）**
- **C# は一度も実行されていない。** P/Invoke marshalling・loopback window・probe host は
  runtime 未実証。初回実走は**ハーネス側の不具合で失敗しうる**（製品の問題ではない）
- 子報告で判明した未解決2件: **ProductCode / InstallLocation が空で返る**
  （`InstallDate` は取得できている）、W1 の OS `ProductName` が `Windows 10 Pro` という
  古い値（25H2 機では `DisplayVersion` + `CurrentBuild` + `UBR` を使う）
- `-Target notepad` プロファイルは意図的に未実装（`blocked` で記録）
- candidate window の class 名は推測チェックリスト。W1 で一度も実観測していない。
  不一致は「既知の class なし」と報告し「candidate window が存在しない」とは言わない
- cross-process の IME open/closed 状態は诚实な API が無いのでその旨を報告
- 現時点で導入済みなのは**旧候補**。新候補は未ビルド。よってこのハーネスの実走は
  「**ハーネス動作確認 ＋ 旧候補 baseline**」であり、**W1 の正式証拠ではない**。
  正式 W1 は Mozc-only 候補ビルド後、同じハーネスで固定 hash に対して実施する

**生成物の取り扱い（ coordinator が修正）**: `runs/` は実行ごとに中身が変わり
machine固有データ（window station 名・install path）を含む。`.gitignore` に
`platform/windows-tsf/validation/*/runs/` を追加し、追跡対象をソース11ファイルのみに
した。**これが無いと `git status` が実行のたびに変わり、staging manifest の
`repositoryStatusLines`（source identity の一部）を汚染して
`Runtime manifest source identity changed` で失敗する**——過去の失敗と同型の再発要因。

## W2 事前調査（coordinator が実機で実測）— 旧候補のインストール状態が W2 を左右する

- **旧候補は導入済みである。** `C:\Program Files (x86)\KanaAI` が存在し 12 entry
  （`mozc_server.exe` / `mozc_tip64.dll` / `mozc_tip32.dll` / `mozc_broker.exe` /
  `mozc_renderer.exe` / README.txt / LICENSE.txt / MOZC-LICENSE.txt / credits_en.html /
  VC runtime 3件 ほか）。ARP エントリ `KanaAI Development Preview` ver=0.1.0 も
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` に**実在する**。
  `C:\Program Files\KanaAI` は**存在しない**。
- **インストール先が新ビルドと食い違う（最重要リスク）。** `KanaAI.wxs:10-12` の
  Directory tree は `ProgramFilesFolder > INSTALLFOLDER (Name="KanaAI")` のみで
  **`TSF` サブフォルダは定義されていない**。ビルドは `wix build -arch x64`
  (`build-windows-installer.ps1:1960`) なので新候補は **`C:\Program Files\KanaAI`** に
  入る。旧候補は `Program Files (x86)` にある。
  UpgradeCode は同一 `{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}` かつ
  `MajorUpgrade Schedule="afterInstallInitialize"` なので MajorUpgrade は効くはずだが、
  **旧ファイルが別ディレクトリにある状態での移行は未検証**。移行に失敗すると
  **2つの導入が併存し、古いTIP登録が残り得る**。W2 で必ず確認する。
  （`platform/windows-tsf/installer/README.md:60-68` の `C:\Program Files\KanaAI\TSF` は
  登録 helper の `-InstallRoot` 引数の**例**であり、MSI の実レイアウトではない。
  ドキュメントの記述を MSI の Directory table と混同しないこと。）
- **昇格しないプロセスからは Windows Installer の製品列挙が空になる。**
  `Installer.Products.Count = 0` だが ARP エントリは実在する。per-machine
  (`ALLUSERS=1`) 製品のため非昇格プロセスには列挙できない。
  → **W2 の pre-flight は昇格 64-bit シェルで実行しなければならない。**
  これは lifecycle ハーネスが `elevation` を独立 gate として要求している理由でもある。
- 旧 ARP エントリは `HKLM\SOFTWARE\...\Uninstall`（64-bit view）にあるのにファイルは
  `Program Files (x86)` にある。これは GOAL が指摘する FileRedirection の不整合であり、
  記録に残す。旧候補は x86 時代の残留である可能性が高い。

## A2-08a（AI 経路の F1〜F7）完了 — coordinator が統合検証して緑を確認

子の報告を鵜呑みにせず、**coordinator が自分で全ワークスペースを実行**した。

- `cargo fmt --all --check`: **exit 0**
- `cargo check --workspace --all-targets --locked`: **exit 0**
- `cargo test --workspace --locked`: **exit 0** — **181 passed / 0 failed / 2 ignored**
  （開始時の 166 から **+15**。IGNORED 2件は 1.1 GB staged payload 必須で未実行。
  `#[ignore]` は PASS ではない）
- `cargo clippy --workspace --all-targets --locked`: **exit 0**

コード実読で coordinator が確認した点
- **F1 は production に到達した。** `installed_ai.rs:130` の request guard が
  `ownership.verify_endpoint()` を呼び、`ai_runtime.rs:637` の readiness probe が
  `verify_connection()` を呼ぶ。連鎖は `runtime_supervisor.rs:427` →
  `runtime_process_windows.rs:513` → `connection_owned_by` まで到達する。
  **死んでいた TCP table 所有権検証が実際に効く経路になった。**
  `connection_owned_by` は今回初めて**実 OS 呼出しとして実行**され、`windows-sys` の
  `Win32_NetworkManagement_IpHelper` が `GetExtendedTcpTable` / `MIB_TCPROW_OWNER_PID` を
  提供することを確認。reviewer が「dead code なので静かに壊れていても看不出來る」とした
  未確定事項が解消した。F1 の非空虚性は所有権判定を無効化すると 2件が FAILED することで
  実証済み。
- **F2**: 未設定・off・disabled・空文字・unknown・前後空白すべて `Disabled`。
  `local` / `local-only` だけが明示 opt-in。`EnhancementPolicy::default()` および
  Unix 経路との一致を test が**型側の既定値と突き合わせる**形で保証。
- 子に所有させていないファイル（`Cargo.toml` / `Cargo.lock` / `lib.rs` / `local_model.rs` /
  `local_runtime.rs` / `pipe_windows.rs` / `bin/kanai-broker.rs`）は未編集。
- F7.1 / F7.3 は「production を壊したら失敗する」ことを子が一時的に壊して実証済み。
  F7.1 では別ローカルユーザーの SID に差し替えると、旧 test では通過していたことが露見した。

### 残件（**AI 有効化の前に必ず塞ぐ**。決定 D-1 の Mozc-only ベータには無関係）
1. **F1 の残余競窓**: `verify_endpoint()` が開く検証ソケットと reqwest が実際に送る
   ソケットは**別 Connection**。その間のサブミリ秒 TOCTOU は未排除。完全な修正には
   `local_model.rs` に接続層の seam（検証済みソケットを reqwest に渡す `resolve()` フック）
   が必要。現状は C-1 で AI 経路が起動しないため**到達不能**。
2. **IGNORED 2件**が未実行（1.1 GB payload 必要）。
3. **H-2**: key file root が `%TEMP%` のため日本語アカウント名では非 ASCII になり恒久 off。
4. **H-3**: 既定 deadline 250 ms に対し実測 1.46 s。
## Mozc-only ベータ候補 B1 を生成（coordinator が実測）— 正式 W1/W2 の入力

build script の publish retry 修正（下記）後、**stage → build が exit 0**。
出力は `.local\installer-beta-mozc/`（`.local` は gitignore 済みで source identity を汚さない）。

### 成果物（実測 SHA-256）
| ファイル | サイズ | SHA-256 |
|---|---|---|
| `KanaAI-0.1.0-x64.msi` | **18,427,904** | `1F040CE215C5EEEBCBD500F8C95ED43BE34EE55248DDF4999256C714FA27363F` |
| `KanaAI-0.1.0-Setup.exe` | **18,433,024** | `260BADEA04F71D11D8B52B5782FDB78FCF5DB632486BA4BD22F0AFA6E5124135` |
| `build-manifest.json` | 33,830 | `53EC2D05B4D43F0614782DE0FF4D3D03BC16B19C32F53712AF47F28F94B56C84` |

- staging manifest（再生成）SHA-256 `1E453D256D442972638BA7870F60DF92C682BA1C00FBAE6ED744E75F43AB0C0B`、FileCount 12
- **AI同梱版 1,124,446,208 bytes → Mozc-only 18,427,904 bytes**（約1/61）
- ProductCode `{C64F7C8B-BF74-459F-A593-22CA2656EA09}` / UpgradeCode `{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}`
  / ProductVersion `0.1.0` / `ALLUSERS=1`（per-machine）/ architecture `x64` / WiX `5.0.2+aa65968c`
- **UpgradeCode は現機の旧候補と同一**なので MajorUpgrade が効く設計。ただし旧候補は
  `C:\Program Files (x86)\KanaAI`、新候補は `C:\Program Files\KanaAI` に**別ディレクトリで**入るため、
  移行の成否は W2 で必ず実測する（未検証）

### 独立検証（coordinator が実施）
- **MSI の File table を Windows Installer COM で直接検査 → 13行すべて
  Mozc / VC redist / README / LICENSE 系。`kanai-broker.exe` も `ai\` 配下も1つも含まれない。**
  build manifest の `localAiIncluded=false` / `ai.payloadFileCount=0` / `payloadRelativePaths=[]` と一致
- **Setup.exe は MSI を verbatim 埋め込み**（OLE magic を offset **1204** で検出、
  先頭 1,048,576 バイトがバイト一致、サイズ差 **5,120 bytes** = Setup.exe 側 overhead）。
  Setup 単体を配っても MSI を取り違えない
- manifest の正直な記録: `status=unverified-installer-candidate` / `verified=false` /
  `sourceTreeDirty=true` / `aiOperationVerified=false` / `aiStartupTested=false` /
  `signing={"declared":"unsigned","msiAuthenticode":"NotSigned","setupAuthenticode":"NotSigned"}`

### この候補がまだ公開候補ではない理由
`verified=false`・`sourceTreeDirty=true`・**W1/W2 未実施**・未署名。
公開前に (1) W1 をこの hash に対して実測、(2) W2 で導入/削除/再導入/rollback、
(3) source を clean にして固定コミット化し再ビルド、(4) 独立 verifier の判定が必要。

### 修正した publish retry（build script の実バグ）
`build-windows-installer.ps1:1757` の publish retry が **5回・合計2秒固定**で、
**Windows Defender が新規 MSI を非同期スキャンしている間**にファイルがロックされて失敗した。
18MB の Mozc-only MSI で 2回連続して再現した（`Move-Item : The process cannot access the file
because it is being used by another process`）。`Get-Sha256` は `finally` で stream を
Dispose しており**ハンドル漏れではなかった**。失敗直後の手動 `Move-Item` は成功したので、
ロックはビルドプロセス実行中のみ存在する（スキャナ説と整合）。
修正: retry を **60回・1回5秒上限の線形バックオフ**（約85秒窓口）へ拡張し、
`-PublishRetryCount` / `-PublishRetryDelayMilliseconds` で**上書き可能**にした
（1.1GB の AI 版は走査時間がさらに長いため）。値検証（1..1000 / 0..60000）を追加し、
0 / -1 / 1001 / 60001 の拒否と 60 / 500 の受理を実測。PowerShell 5.1 parse 0 エラー。
**このスクリプトは staging の `buildInputs` に含まれるため、修正後は再 stagingが必須だった**
（manifest SHA-256 が `0F9C4A4E…` → `1E453D25…` に変化）。
## 未解決・次の一手（この順）

1. **W1 bring-up を旧候補で実行**（ユーザー事前連絡を確認济みか。画面が1つ開き canary を自動入力する）
   - harness の実動作（Desktop/C# の P/Invoke、probe window、IME 切替）を確認する
   - **正式な W1 証拠ではない**（現機の導入済みは旧候補）
2. **W1 を新候補 B1（`1F040CE2…`）に対して実行** — これが正式な W1 証拠になる
3. **W2 を新候補 B1 に対して実行**（昇格 64-bit シェル、`machine` lock 専有）
   - 特に **旧 `C:\Program Files (x86)\KanaAI` から新 `C:\Program Files\KanaAI` への移行**を確かめる
   - 失敗時に2つの導入が併存し、古い TIP 登録が残らないことを確認する
4. source を clean にして固定コミット化し、**再 stage・再 build** する。その hash を W1/W2 の対象にする
5. README と GitHub Release body に実ハッシュ・実検証結果・未署名の SmartScreen 警告を記載する
6. 独立 verifier に固定コミットと成果物ハッシュで beta 判定を依頼する。`.goal-complete` は作らない

### 既に完了した項目（2026-09-26）

- R-AI 監査を実施し、C-1（AI manifest/receipt が未ship）と H-1（`verify_connection` が dead code）を
  coordinator が実コードで独立再確認した
- D-DESK（W1 harness）と D-LIFE（W2 harness）の納品を coordinator が自分で実行して検証した
  （self-test / plan-only / ゲート無しでの拒否動作）
- A2-08a: F1〜F7 の修正を coordinator が統合検証して緑にした（181 passed / 0 failed / 2 ignored）
- C-I3 の peer allowlist 欠陥（`mozc_server_win.exe` を要求 → 実名は `mozc_server.exe`）を修正した
- `Cargo.lock` の stale 状態を最小再生成した（sha2 ファミリー 8 package 追加）
- `runs/` を `.gitignore` に追加し、staging の source identity 汚染を防いだ
- publish retry の実バグ（Defender による MSI ロックに2秒窓口では短すぎる）を修正し、
  Mozc-only 候補 B1 を生成した

---

# 最新の引き継ぎ — 2026-09-26 Windows / OpenCode移行 / 実装・W1 receipts

Status: NOT COMPLETE / public beta NOT RELEASED

## この区切りの完了

- OpenCode Space Bunny Freeのcoordinatorとして、W1（tester）、A1（researcher）、D1（implementer）を`docs/WORK_QUEUE.md`で排他割当した。子にgit統合、共有STATE、公開操作はさせていない。
- D1の`platform/windows-tsf/installer/package/PACKAGE_README.txt`をレビューした。x64開発preview、未署名、実AIモデル非同梱、実アプリ入力・clean uninstall/reinstall未検証、製品未完成を明記し、Setup.exeの埋め込みMSI/UAC/ SmartScreen注意を過不足なく記載。LF/UTF-8無BOMに正規化。git diff外の未追跡ファイルとして扱う。
- `scripts/build-windows-installer.ps1`を候補固定用へ強化した。runtime manifestのファイルハッシュ、helperハッシュ、pinned Mozc gitlink、全reviewed patch SHA-256、HEAD/dirty状態を検証し、`-RequireCleanSource`と`-ValidateOnly`を追加。Setup.exeに埋め込まれたMSIが同一ハッシュか、MSI ProductCode/UpgradeCode/ProductVersion、Authenticode状態をmanifestへ記録する。dirty treeは公開候補にしない。
- `scripts/stage-tsf-runtime.ps1`とTSFのSHA-256 helperから、このWindows PowerShell環境に存在しない`Get-FileHash` cmdletへの依存を除去した。対象: `TsfBuild.Common.ps1`、`Smoke.Common.ps1`、`Common-TsfRegistration.ps1`。
- `platform/windows-tsf/installer/package/tests/Test-InstallerBuildScript.ps1`を追加。12 runtime files、payload/helper改ざん拒否、dirty-tree guard、source/patch identityを検証する。
- `scripts/start-opencode.ps1`のCheckOnlyを実測で再検証。redirectされた`opencode debug agents`がUTF-16LE BOMを出力し`ConvertFrom-Json`が失敗する実バグを特定し、raw bytes/BOM-aware decode（8MiB post-read sanity limit、同時stdout/stderr drain）へ修正。修正後`v2.0.16 / Space Bunny Free / 6 project agents: OK`、exit 0。OpenCode models APIも`opencode/space-bunny-free` activeを確認。
- A1Mの候補をcoordinatorが照合し、ユーザーはQwen2.5-1.5B公式GGUF + llama.cpp b11146 CPU runtime pairingでA2を進めることを承認した。Qwen公式 `Qwen/Qwen2.5-1.5B-Instruct-GGUF` revision `91cad51170dc346986eccefdc2dd33a9da36ead9`、Apache-2.0、Q4_K_M weight 1,117,320,736 bytes、LFS SHA-256 `6A1A2EB6D15622BF3C96857206351BA97E1AF16C30D7A74EE38970E434E9407E`、weight commit `dd26da440ef0330c47919d1ecae0966d24022222`。llama.cpp release `b11146`/commit `7fe450e19305b828c199d602c23a8337aaa1f03b`、Windows CPU asset 18,560,055 bytes、GitHub digest `14CF1303CA9AC3ABD94816850532F9F9A69AC66FBACA3776FC6F9061C2FAC1D1`、MIT。公式license/APIでpairingのredistribution条件に明白な矛盾なしと確認した。**Qwen weightとllama.cpp runtime archiveは取得・hash検証済み、owner/legal・品質・CPU性能・Windows native evidenceは未承認**。A2-01はpinned manifest/notice/safe stagingのoffline実装を開始。
- A1の接続経路調査をcoordinatorが実コードと照合した。現状はTSF optional pipe seam、Rust authenticated broker/queue、loopback adapterまでで、`IsAvailable()`はworker/bindingのみを判定し、llama-server/model/brokerの自動起動・random port・token・installer AI payloadは未実装。AI processを起動するTSF transportのCreateProcess相当も未確認。
- A2-01の6ファイルはcoordinatorが再検証した。PowerShell 5.1 parse、production `-PlanOnly`、synthetic staging、hash/size/traversal/absolute/duplicate/unexpected/unmanaged/symlink検査、network primitive禁止がPASS。公式pinned Qwen LICENSE正文（`Copyright 2024 Alibaba Cloud`）とllama.cpp LICENSE正文（`Copyright (c) 2023-2026 The ggml authors`）を反映し、manifestのlicense/notice hashも再計算済み。Qwen weight 1,117,320,736 bytesとruntime archive 18,560,055 bytesは取得・hash検証済み。runtime 51-entry layout・`LICENSE-LLVM-OpenMP`/closureを実測し、fixture modelでstage receiptまで確認した。実modelのKanaAI install/Windows実行、model quality、transitive notice/SBOMは未検証。
- 2026-09-26にllama.cpp runtime archiveを実取得し、`.local/validation/ai-runtime/runtime-inspection.json`に相対path・51 file hashes・PE x64/DLL/EXE判定・`llama-server --help/--version` exit 0を記録した。runtime closureのSBOM/transitive noticeとmodelのKanaAI install/Windows実行は未完了。
- 2026-09-26の現在manifestに再bindした実model stagingは`.local/ai-runtime/staged-real-v2`で完了し、receipt status `staged-verified-local-ai-runtime`、model 1,117,320,736 bytes、runtime 51 entries、全staged fileのsize/SHA-256、networkUsed=falseをcoordinatorが独立再検証した。`.local/ai-runtime/staged-real`は旧manifest hashのreceiptでありA2-03入力にしない。
- 初回のstaging wrapperは成果物生成後のPowerShell 5.1 StrictModeで未定義`$LASTEXITCODE`を参照しexit 1となったため、wrapper全体をPASSとは記録しない。直接scriptのv2 receiptはexit 0で独立再検証済み。
- A2-03入力候補として絶対pathを含まない`.local/ai-runtime/staged-real-v2/PACKAGE-MANIFEST.json`を生成し、51 runtime entries/model bytes/hashを記録した。raw receipt自体はpackage payloadにしない。
- **A2-03後のstale manifest（実害あり）**: `.local/tsf-runtime-manifest.json` は依然 **schemaVersion 1**（RV2のschema 2ではない）、AI無し時代の12ファイルで、現在の`PACKAGE_README.txt`（7,879 bytes / SHA-256 `53964D0BF505F310AE6692E4C49E8E7DA1419C5450479241F72145ED7DB12779`）のレコードを含まない。実candidateの`build-windows-installer.ps1`/`-ValidateOnly`を走らせる前に`scripts/stage-tsf-runtime.ps1`の再実行が必須。このstale manifestを実検証証拠として引用しない。
- 2026-09-26のisolated ASCII-path runtime smokeは`.local/validation/ai-runtime/llama-smoke-ascii.json`に、health 200、tokenなしmodels 401、token付きsynthetic chat 200、model load/inference約1.54秒と記録した。loopback以外・prompt/secret保存なし。Unicode staging pathでllama-serverが`--api-key-file`を開けない問題も確認し、product launcherのASCII-safe token path設計が必要。IME quality/TSF/packageの証拠ではない。
- 同じisolated runtimeでsynthetic candidate rerankを1回だけ実行し、`.local/validation/ai-runtime/rerank-smoke.json`にhealth 200、chat 200、約1.89秒、decision keys `action/candidateIds/confidence/reasonCode`、ID 1/2/3のexact permutation PASSを記録した。これはruntime/formatのsmokeであり、3-case品質評価・GOAL PASS・TSF登録の証拠ではない。
- A2-02のruntime supervisor差分をcoordinatorが再検証した。`cargo fmt --check`、targeted 12 tests、crate全49 tests、`cargo check`、targeted clippyがexit 0。`Starting`状態、start futureのmutex非保持、caller drop/force stop、late child cleanup、replacement overlap防止、typed stop failureを確認する抽象層のみ。実process adapter、llama-server起動、broker/TSF統合は未実装。
- A2-04のpinned launch plan config seamをcoordinatorが再検証した。現在のmanifest status/hash/notice identityへ更新し、targeted 7 tests、crate全56 tests、check、clippyがexit 0。model/runtime/port/token/processの実接続は未実装。
- **incident 2026-09-26 00:51-00:55（OS/サーバ再起動起因）**: `.git/index`と6ファイルがnull byte/ゼロクリアで破損。`0001-install-kanai-supplemental-model.patch`・`rank_policy.h`・`KanaAI.wxs`は全NUL、`local_runtime.rs`・`tests/local_runtime.rs`・`Test-InstallerBuildScript.ps1`は末尾NUL run（コード内容は無傷）。復旧: バックアップを`%LOCALAPPDATA%\Temp\opencode\corrupt-backup-20260926-0055`へ保全、3ファイルは`git show HEAD:`で復元、`KanaAI.wxs`はHEAD+`SetProperty` 2行（patch 0006のCustomActionData要件）を再適用して3021 bytesに一致、末尾NUL3ファイルは末尾runを切り詰め、`git read-tree HEAD`でindexを再構築、`target/`のcorrupt incremental cacheを削除。**`rank_policy.h`の残存リスクは解消済み**: 当初「HEAD 1567B vs 破損前 1606Bで+39 bytes差分喪失」と記録したが、LF正規化するとHEAD blobと完全一致することを確認した（1,606 Bは全39行CRLFの作業ツリー形式、blobはLF。`git hash-object`もHEADと同一blobを返す）。未コミット差分は存在しなかった。対象ファイルのNUL/非UTF8残存ゼロ、全60 Rust tests・staging test・installer testがexit 0で再確認。
- A2-03の子はEz分も独立に破損を検出し復旧した。mozilla submoduleの欠落object 2件（`c7621efce7…`=MODULE.bazel、`49801e8ed8…`=.gitmodules config）を`git hash-object -w`で再投入し、`git -C third_party/mozc status`はexit 0 clean、superproject gitlink `13c98988247aa711d99db9e348ec2a597d14b5cd` == mozc HEAD == pinで一致を確認した（coordinatorが再検証）。
- RV2の installer hardening差分（schema 2 provenance、immutable snapshot、PE構造/export検証、negative tests）をcoordinatorが実TFS runtimeの`ValidateOnly`で再検証。synthetic offline suiteとreal stage/ValidateOnlyはPASS。full WiX/MSI/Setup、artifactBuildLinkage、signature/installは未実施。
- 固定Windows x64 Rust broker release buildをbuild lock内で完了。`target/x86_64-pc-windows-msvc/release/kanai-broker.exe` 2,817,024 bytes、SHA-256 `85F4930D5976B5339DE10216D53C20BEA4D68D3BAE6D25E2668ED24DE101DAC4`、PE32+ x64 EXE。process起動・pipe接続・AI接続は未実施。
- RV1 read-only reviewでinstaller hardeningのHigh findingを確認した。現行staging manifestは生成元source/overlay/patch identityをbindingせず、buildはmutableな元pathをWiXへ渡し、PE validatorはMZ/signature/machineだけでacceptする。full-build test、submodule dirty guard、reparse root、atomic output、strict GUID/signing derivationも未十分である。RV1は編集/テスト/公開を行わず、RV2で修正する。AI package統合A2-03はRV2検証後に開始。サイトファイルは変更していない。
- `docs/LOCAL_AI.md`と`docs/PRODUCT_RELEASE_CONTRACT.md`を、承認済み候補のexact identityと「AI同梱時はlicense/digest/notice/SBOM必須、未同梱/未検証をAI動作としない」境界に更新。modelのUNTIME実装や品質を完了扱いにはしていない。
- GitHub確認（2026-09-25）: `aruiki/kanai`はpublic repositoryだが、GitHub Releases APIは`[]`、latest releaseは404、tagsも`[]`。draft/prerelease/Setup/MSIの公開は行われていない。`git fetch --no-tags origin main`後にremote `main`は`3bf40f2fad319886b0e7e0da9bd5017949e98b9f`、ローカルHEAD/追跡refは`2e0630c`。ユーザーはpush・Release作成・Setup/MSI upload・prerelease公開を明示要求したが、公開契約のW1/W2/fixed-source/verifier gateを先行して満たす。リポジトリ説明文は`KanaAI: a local-first Windows Japanese IME. Native TSF on Mozc, with bounded local AI in development.`へ、topicsは`windows`, `tsf`, `japanese-ime`, `local-ai`等を追加済み。README|source pushは未実施。

## 検証結果

- W1 receipt: `.local/validation/w1/W1-RESULTS.json`、artifact manifest `.local/validation/w1/ARTIFACTS.tsv`。W1はWindows 11 25H2 x64、MSI ProductCode `{307FE767-2B88-4915-8337-6E35423976B7}`、x64/x86 InprocServer32、Japanese profile enabled、ctfmon稼働を実測した。`SendInput`はAPI countを返すが、共有interactive desktopでNotepad/InputBox/IME indicatorへのkey・mouse deliveryが全滅し、`mozc_tip64.dll`はNotepadにロードされなかった。自動試験のT-01〜T-07は**NOT OBSERVED**。製品PASS/FAILでもbeta判定でもはない。W1はmachine lock内で終了し、Notepad/補助process/canaryを後始末した。
- operatorの手動続行報告（user statement、independent captureではない）: `.local/validation/w1/manual-user-report.json`、SHA-256 `2D9472BCE36868CE86BB9A91B99B7935535E29C4CB334B3C40A92C2EFDDE8307`。現行導入済み旧candidateでNotepadの文字入力・変換・かな切替は成功と報告。候補表示、Enter確定、Esc取消、focus、restart、runtime processは未報告。operatorは残りのW1確認を今回は延期すると決定。このpartial reportだけではW1完了・beta PASSとは判定しない。
- `platform/windows-tsf/registration/tests/Test-RegistrationSlice.ps1`: PASS（source-only registration readiness、X64 view、x86 blocked）。
- `platform/windows-tsf/build/tests/Test-TsfWindowsBuildHarness.ps1 -SkipPeUnit`: PASS（static38、path9、fingerprint7）。PE unitありでもPASS。`Test-PinnedMozcTsfSmoke.ps1`: PASS（source/static、runtime hostはnot-run）。
- `Test-InstallerBuildScript.ps1`: PASS（runtime12、tamper reject、dirty guard）。`build-windows-installer.ps1 -ValidateOnly`: PASS、HEAD `2e0630c23ce7242d020a3c571724c7c67b336216`、Mozc `13c98988247aa711d99db9e348ec2a597d14b5cd`、patch6。
- build lock内で一時full packageを実行し、Setup/MSI生成、MSIプロパティ、Setup埋込みMSI hash、NotSigned記録、derived signing state、build後のsource/patch/runtime manifest再確認までPASS。只是一時test outputで、公開候補ではない: `.local/test-results/final-installer-candidate-d6324a8cf51e494080397ba3b6c11e22/`、MSI SHA-256 `F77D6CC8F6FFB1EA9331973B8092759B51C54863A868A23392BB7F8D6592DED7`、Setup SHA-256 `6C42DA099AE5F96974B7F4DF5A1AB41F9666BB908B7EEAD3BB3356580FE6123A`、ProductCode `{635C3391-76FA-4900-9B3A-A53642CBA6C4}`。同じ検証で一時stageもPASSし、D1 README hash `01036A0599BD0A01C5B64460BFBC3C71474C984290D4405D079EB3BA3E261D9F`。
- 2026-09-25のoperator partial W1後、D1 READMEを現在のruntimeへrestageし、build lockで新しい未導入candidate `.local/installer`を生成した。MSI SHA-256 `3CDDA1355387BC1DF6F5DC65D241841CB478FF6D8AAD9E34425DE62BC1264E39`、Setup SHA-256 `D539A0DF9E5DB093FA4CE0F403B2D1CF32134794EFC24BE4E868648379969366`、ProductCode `{26885A9F-0689-4561-AA38-D30F25CE7349}`、runtime manifest SHA-256 `C2464216050E0EEF178F3D12CAEAE0D93828A3E58DA6335F38AB86EAB0D3A661`、README SHA-256 `01036A0599BD0A01C5B64460BFBC3C71474C984290D4405D079EB3BA3E261D9F`。source dirty、unsigned、W1/W2未適用のため公開候補ではない。
- 現在の実機は旧candidate ProductCode `{307FE767-2B88-4915-8337-6E35423976B7}`、導入先`C:\\Program Files (x86)\\KanaAI`のまま。新candidateは未インストール。repositoryはdirtyで未コミット多数。`.local`の一時test outputは公開候補・製品入力の証拠にしない。

## 未解決・次の一手

- W1はoperatorが文字入力・変換・かな切替成功を報告したが、候補表示・Enter確定・Esc取消・focus切替・Notepad restart・runtime processは未確認。operatorは残りを今回延期すると決定。自動SendInputを同じdesktopで再試行せず、結果を保持する。
- ユーザー公開範囲の決定: **AI同梱版のみ**。A1/A1Mは完了し、A2-01 metadata/stagingとA2-02 lifecycle abstractionも検証済み。Qwen weight/runtimeの実inputsとstaging receiptも独立検証済み。RV2 installer hardening、A2-03 MSI/Setup統合、broker/llama-server自動起動、native fallback/quality検証へ進む。W1/W2/独立verifierのgateも引き続き必要。AI非搭載candidateは公開しない。
- D1 README restageと新しいMSI/Setup生成は完了した。次はW2で新candidateのインストール・削除・再導入・rollback/Setup操作を検証し、同じ固定hashでW1の残り実アプリ項目を再実施する。operatorは今回の一手動残項目を延期したため、W2前に別途入力確認の operator decision が必要。
- **1.1GB CAB制約は解決（2026-09-26実測）**: 実Qwen weight（1,117,320,736 bytes）＋llama.cpp runtime closure（51 entries）＋Rust brokerを含むAI同梱 MSIが **1,124,446,208 bytes で正常に生成された**。`MediaTemplate EmbedCab="yes" CompressionLevel="high"` のままで1.1GB級payloadは成立する。Setup.exe/resource埋め込みと最終publishは継続作業。
- **broker digestをpin（残存risk #2解消）**: 実broker 2,817,024 bytes / SHA-256 `85F4930D5976B5339DE10216D53C20BEA4D68D3BAE6D25E2668ED24DE101DAC4` を `manifest-v1.json` の `broker` ブロック、`build-windows-installer.ps1` の `$aiPinned`、Rust `local_runtime` の `PINNED_BROKER_*` の3箇所に固定。builderはproductionモードでmanifestとbuilderのdigest一致を強制し、不一致は「再buildして両方を更新せよ」としてfail closedする。fixture modeはsynthetic PEにbindする。installer testのAI negative caseは40→**42件**（`broker-pinned-size` / `broker-pinned-digest` 追加）。
- **A2-01 staging receiptの欠陥を修正**: 最初の実receiptは (a) `manifest.path` に PowerShell `FileInfo` オブジェクトグラフ（`PSDrive`/`Credential`/`Password`/`MetadataToken`）が展開され、(b) 絶対pathを含んでいたため、launch-plan seamが `SecretField` で拒否していた。`Get-PortableRelativePath` / `ConvertTo-PortableRelativeString` を追加し、receipt は相対path・forward-slash・`/区切りのみ` になるよう修正。`Write-Utf8Json` の `ConvertTo-Json -Depth 4` は `broker`/`runtime` ブロックを**静かに切り捨てていた**ため 12 に修正（round-trip losslessness を回帰テストで固定）。
- **残存risk（beta公開前）**: (1) broker composition rootがAI backend起動を統合していない（process adapter自体は実装済み）、(2) native TSF での AI ON/OFF・kill・timeout・Mozc fallback が未実測、(3) W1/W2（実インストール／アプリ入力／アンインストール）が未実施、(4) 署名・SBOM/transitive notice 完成・(5) 非ASCII導入DirはAI slow pathが fail closed する既知の制約。
- **Windows実process adapterを実装（`crates/kanai-broker/src/runtime_process_windows.rs`）**: A2-02の `RuntimeProcess`/`RuntimeChild` を実Windows processで実装した。`tokio::process::Command`（stdin/stdout/stderr=`Stdio::null`、`kill_on_drop(true)`、作業ディレクトリはruntimeディレクトリ）で起動し、**Job Object（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）** に割当てるためbrokerが強制終了されてもmodel processが孤児化しない。key値はコマンドラインに出さず`--api-key-file` のパスだけを渡す。`Cargo.toml` に `Win32_System_JobObjects` featureを追加。**実測で裏付けたfail-closed**: リポジトリが日本語パス下にあるため `from_plan` は `WindowsProcessError::NonAsciiCommandPath` で拒否する（b11146は非ASCIIパスで `--api-key-file` を開けない既知の実測結果に基づく。導入先は既定で `Program Files` のASCIIなので既定導入は満たす）。graceful stopはこのwindowless buildに協調的shutdownが無いためjob terminateで代用し、supervisor側の状態機械は区別を維持する。
- **A2-05相当のテスト結果（2026-09-26実測）**: `crates/kanai-broker/tests/runtime_process_windows.rs`。純adapter 4件（missing executable拒否／非ASCII拒否／token非露出・loopback限定・no-ui・CPU-only・`--api-key` なし／caller指定port）は1.1GB非依存で常に走る。実process 1件は1.1GB stagingが必要なため `#[ignore]` にして `cargo test -p kanai-broker --test runtime_process_windows --locked -- --ignored` で明示実行（ignoredはPASSの証拠ではない）。**実測でPASS**: ASCII directory junction経由で実Qwen weight＋実llama-server	b11146を起動し、OSがプロセスを報告することを確認し、supervisorの`force_stop`後に`llama-server.exe`が残らない（job objectが殺す）ことを確認。orphan process・残留key file・残留junctionはゼロ。`cargo test --workspace --locked` 全suite exit 0、`cargo fmt --check` exit 0、`cargo clippy --workspace --all-targets --locked` exit 0。**これは「起動と終了の所有」を示すだけで、AI の応答品質・TSF統合・GoToMozcRanker接続は未検証**。
- **build中のsource identity競合（実害の教訓）**: `stage-tsf-runtime.ps1` がmanifestに記す `sourceIdentity` は `buildInputs`（buildスクリプト自身のSHA-256）と `repositoryStatus*`（`git status` の結果）を含む。**restageとbuildの間に1ファイルでもsourceを書くと必ず `Runtime manifest source identity changed (...)` で失敗する**。今回はRust作業（`cargo fmt`/`cargo test`/新規ファイル）をbuildと並行して走らせ、`buildInputs` → `repositoryStatusLines, repositoryStatusSha256, repositoryMutationSha256` と順に食い違い、2回続けて失敗した。**以降の規則: restage＋buildはbackgroundで回し、その間はsourceへ一切書かない（read-only作業のみ）**。buildInputsは `scripts/build-windows-installer.ps1` を含み、**このスクリプトを編集したら再 staging が必須**。
- **reviewerが指摘した修正と新規発見（2026-09-26）**: read-only reviewerが adapter 1 High / 7 Medium を報告し、coordinatorが各項目を実コードで照合した。
  - **H1（supervisor既存バグ・修正済み）**: `runtime_supervisor.rs` の `wait_for_stop` に上限がなく、`watch::Sender` は `Shared`（supervisor所有）なので `changed()` は `Err` になりえない。monitor task が panic/死すると `Running` のまま状態遷移が永久に発生せず、`force_stop`/`stop_gracefully`/`cancel` が**無限ハング**した（既存のA2-02コード）。`RuntimeSupervisorConfig` に検証付き `stop_confirm_timeout`（0と300秒超を拒否、既定30秒）を追加して有界化。**回帰テストが非vacuousであることを実証**: 修正を外すと30秒でFAIL、戻すと14/14 PASS。
  - **M1（find→修正）**: `from_plan` が引数を**値**で照合していたため、caller指定の `api_key_file` が同じベクタ内のliteralと衝突し `--api-key-file` flag自体や `--host 127.0.0.1` を書き換えた（認証なしloopback serverを起動しうる）。位置ベース置換＋後置条件（各解決パスがちょうど1回、各flagがちょうど1回残存）に変更。
  - **M2/M4/L1/Nit（修正）**: key file と model の存在検査を追加（`MissingKeyFile`/`MissingModel`。「b11146はkey無しで拒否する」という未検証仮定に依存しなくなった）、構築不能な3つの死んだerror variantを削除、`#[derive(Debug)]` を手書き赤action化（絶対パス＝Windows account名を含むため）、`Send`/`Sync` の理由コメントの事実誤りを訂正、`CREATE_NO_WINDOW` 付与、nested job の「全Windows版でサポート」は不正確（Windows 8+が必要）なので文言を訂正。
  - **M3（既知の未修正制約として明記）**: process生成と `AssignProcessToJobObject` の間に窓があり、**unwindingしないbroker死**（abort/`TerminateProcess`/電源断）では孤児化する。解消には `PROC_THREAD_ATTRIBUTE_JOB_LIST` または `CREATE_SUSPENDED` による直接 `CreateProcessW` が必要で、本チケットは明示的に除外。module docの「Known limitation」に記載。
  - **新規実バグ（testが発見）**: stricter な test にputed結果、**`RelativeInstalledPath` は可搬性のためforward slashで正規化されるが `Path::join` が把它残す**ため、adapterの解決パスは `…\kanai-ai/runtime/llama-server.exe`（混在スラッシュ）になり、OSが報告する `…\kanai-ai\runtime\llama-server.exe` と**等値比較が永不成立**していた。`installed_under` で native separator に正規化し、`resolved_installed_paths_use_native_separators` を追加。
- **G2（最重大・修正済み）**: researcher が報告した `local_model.rs` の欠陥を coordinator がコードで独立確認した。当該ファイルは `Authorization: Bearer` を**一切送っておらず**、`reqwest::Client::builder()` に `.no_proxy()` もなかった。pinned plan は必ず `--api-key-file` を使うため、**AI rerankが常に401→Mozc fallback＝AI slow pathが事実上無効**であり、システムproxy有効機ではloopbackが非loopbackへ流出していた。`new_with_api_key` と `validate_api_key`（空/512字超/制御文字・空白を拒否）、bearer header送出、手書き赤action `Debug`、`.no_proxy()` を追加。`tests/local_model.rs` を新規作成（9 tests、`TcpListener` で実HTTPを観測）。**未接続**: `bin/kanai-broker.rs` は `from_environment()` のみで `KANAI_AI_API_KEY` を読まないため、**実プロセスは依然401**。G2の配線はA2-06に含む。
- **publish修正（2026-09-26）**: `Publish-BuildOutput` の `Move-Item` が「`-Force` 無しで既存宛先を拒否」していたのが真因で、1.1GB特有の問題ではなかった（当初copy+hash+削除で置き換えたが、巨大MSIがAV/スキャンに一時ロックされ `Remove-Item` が失敗）。`-Force` 付きrename＋5段階の短いretry＋hash照合に修正し、copy/削除を回避して原子性を維持。
- **残存risk（beta公開前・更新）**: (1) **A2-06**: broker composition rootがAI backendを統合していない＝key file生成・free port確保・readiness待ち・`new_with_api_key` 配線・`kanai-broker.exe` 自動起動がすべて未実装で、**現状AI slow pathは製品で到達不能**。(2) 非ASCII導入DirはAI slow pathがfail closedする既知制約。(3) process生成↔job割当の窓（unwindingしないbroker死で孤児化）未修正。(4) native TSFのAI ON/OFF・kill・timeout・malformed response・Mozc fallback・secure field が未実測。(5) W1/W2・署名・SBOM/transitive notice 完成。
- **AI-beta installer full build 成功（2026-09-26）**: 新broker digestで restage＋build を一続きで実行し、`.local/installer-ai-beta` に3成果物が生成された。MSI `KanaAI-0.1.0-x64.msi` **1,124,446,208 bytes** / SHA-256 `317BDDF558027CE60CE68B252FB4122A3B33A5B108E90DE6534327EB40A084F2`、Setup.exe `KanaAI-0.1.0-Setup.exe` **1,124,451,328 bytes** / SHA-256 `424A82BA6659DB189C0BBE0CE89330FB6B4BFFF79F7A81EFECC41DCD52F3751E`、`build-manifest.json` 108,920 bytes / SHA-256 `59098C9991163ECE8AB251C66B40BA7C1AA1A81A0370408845370BE227E0A78`（末尾は実測値を必ず再確認すること）。
  - **Setup.exe は MSI をバイト単位で verbatim 埋め込みしている**（Python で `msi in setup` が True、サイズ差 5,120 bytes）。 Setup 単体を配って MSI を取り違えない。
  - **1.1GB AI payload が MSI 内部に実在することを Windows Installer COM で直接確認**（File/Component/Directory を辿る実測）: `ai/model/qwen2.5-1.5b-instruct-q4_k_m.gguf` **1,117,320,736 bytes**、`ai/runtime/*`（`llama-server-impl.dll` 8,916,992 bytes、`llama-common.dll` 7,824,896 bytes 等）、`ai/THIRD-PARTY-NOTICES.txt`、`kanai-broker.exe` 2,817,024 bytes（新digestと一致）、Mozc `mozc_server.exe` 22,333,440 bytes 等。File table 70行の FileSize 合計 **1,203,529,373 bytes**。
  - `build-manifest.json` の AI 記録は 56件（model 1＋broker 1＋runtime closure 51＋licenses/notice 3）で、絶対path 0、`containsAbsolutePaths=false`。`immutableInput.aiPostBuildRevalidated=true`。
  - **この候補は公開候補ではない**（manifest自身が `status=unverified-installer-candidate` / `verified=false` / `source.treeDirty=true`・dirty 53件を正直に記録）。`aiOperationVerified=false`・`aiStartupTested=false`・`sbomStatus=not-generated`・`dependencyNoticeStatus=unverified-incomplete`・`windowsExecution=not-performed` はいずれも**実測していないことを示す正しい記録**であり、隠さない。導入してAIを1度も動かしていない。
  - build終了後に残った input snapshot 1.12 GB は成果物と無関係なので削除した（候補本体は2.09 GB）。
- **A2-06 完了 + AIが実際に応答することを実測（2026-09-26）**: `crates/kanai-broker/src/ai_runtime.rs`（1295行）と `tests/ai_runtime.rs`（28 tests）を追加。`BCryptGenRandom`（`BCryptGenRandom` + `BCRYPT_USE_SYSTEM_PREFERRED_RNG`）でper-process keyを生成し、`D:P(A;;FA;;;<current user SID>)` の保護DACLでfileへ書き、free loopback portを確保し、`/health` 200を待つreadiness probe（tokenは**送らない**）で、plan→key→process→supervisor→readiness の一連を組み立てる。`Cargo.toml` に `Win32_Security_Cryptography` featureを1行追加（CSPRNGに必須。`getrandom`/`rand`は新しいdependency、`RandomState`はCSPRNGでないので採らない）。**key file は install root ではなく別rootに置く**: 既定導入先の `C:\Program Files` は非elevatedプロセス月刊なので、そこへ書くとAI経路が恒久的にoffになる。`WindowsRuntimeProcess::from_plan` と `start_pinned_ai_runtime` に `key_file_root` を追加し、実行ファイルとmodelだけが install root、key file だけが per-user writable root から解決されるようにした。親ディレクトリは保護DACL付きで自動作成する（per-user rootは誰も作らないため）。既存test「親が無いと失敗」は旧挙動の前提だったので、既存fileがディレクトリを塞ぐケースに差し替え、新挙動は別testで固定した。
- **【最重要な実測】AIは応答するが、deadlineを5.8倍超過する**: 実Qwen2.5-1.5B Q4_K_M ＋ 実llama.cpp b11146 に対して、**認証付きcompletion（`/v1/chat/completions`）が実際に成功**した。計測値: `adopted=true`、`candidates=3`、`changed_positions=0`、`adopted_count=0`、**`ai_latency_micros=1,457,520`（約1.46秒）**、`deadline_ms=250`。modelは既にwarm（読込済み）での1回の推論であり、これがCPU実機の最良ケース。**帰結**: `enhancement.rs` のcoordinatorは `deadline_ms`（TSFが `kanai_supplemental_model.cc:528` で250ms固定）で `timeout` するため、**productionではこのリクエストは250msで必ずキャンセルされ、Mozc baselineにfallbackする**。つまり現状の hardware 上では AI 自動reorder は作用しない。`changed_positions=0` はAIが順序を変えて_return しなかった（またはadoptされなかった）ことも示す。**これは品質問題ではなく、CPU-only 1.5Bモデルと250msという対話convert deadlineの物理的な不整合**であり、隠さず記録する。選択肢: (a) deadlineを大幅に緩める（でも対話変換には意味が薄い）、(b) より小さいmodel/量子に替える、(c) AIをcandidate reorderではなく**ユーザー明示操作のslow-path assist**に限定する。ユーザー判断が必要。
- **その他の実測**: process adapter 9 tests + 実process 1 test（PID基準・`automatic_restarts==0`・`last_error`無し・`Running`→`Idle`・そのPID消失）をPASS。`ai_runtime` 27 tests（key非露出・Debug非露出・key file生成/削除・port非loopback拒否・readiness deadline・全失敗がtyped error）PASS。実runtime readiness+completion 1 test PASS（2.92秒）。`cargo test --workspace` 全suite・`fmt --check`・`clippy --workspace --all-targets` すべてexit 0。orphan `llama-server.exe` ゼロ、残留key fileゼロ。
- **次の実装工程**: (1) 上記の latency 判断をユーザーと確定し、`ai_runtime` の module doc と `docs/PRODUCT_RELEASE_CONTRACT.md` に「現状CPU実機ではAIはdeadline内に応答しない」ことを明記、(2) **composition root配線**: `bin/kanai-broker.rs` で `ConfiguredBackend` の不変enumを overcome し、listenerを `Disabled` backendで即座に開いてから `start_pinned_ai_runtime` を `tokio::spawn` し、readiness後にlocal backendへ差し替える（`windows_listener::run` にshutdown pathとinterior mutabilityが無いのが実装上の制約）、(3) **W2**: 固定hashの候補で実インストール・日本語入力・AI起動・アンインストール・再導入・rollback（machine lock専有・実機操作）、(4) sourceをcleanにしてcommit/push、独立verifierのbeta判定、prerelease公開。
- Qwen weightは公式pinned URLから取得し、1,117,320,736 bytesとSHA-256 `6A1A2EB6D15622BF3C96857206351BA97E1AF16C30D7A74EE38970E434E9407E`を確認した。実model/llama runtime installerへのstage、package、Windows実行は未了。
- W2はW1完了後に同じmachine lockで直列実行する。公開、GitHub prerelease、`.goal-complete`は未実施。独立verifierのGOAL判定も未実施。

---

# 最新の引き継ぎ — 2026-09-25 Windows / OpenCode移行

Status: NOT COMPLETE / public beta NOT RELEASED

最新依頼: OpenCode Space Bunny Freeへ移行して並列開発できる土台を整備する。
ユーザーの追加依頼で、表示されるWindows TerminalにOpenCodeを起動。
専用サーバー・新規セッション・開始プロンプト付きプロセスの起動を確認した。
起動時のdebug JSON解析失敗を回避するため、通常起動と詳細検査を分離した。
起動は `powershell -NoProfile -File .\\scripts\\start-opencode.ps1`。
まず [移行ガイド](docs/OPENCODE_HANDOFF.md) と [作業キュー](docs/WORK_QUEUE.md) を読む。
この下の旧WSL記録を最新のWindows状態として扱わない。

## 今回完了

- AI向け指示の優先順位・現状記録・ベータ条件と最終完成条件を整理。
- OpenCode v2.0.16、Space Bunny FreeのモデルIDと6役の設定読込を実CLIで確認。
  統括を初期担当にし、子の再委任を禁止。担当票・共有資源排他・開始スクリプトを追加。
- Windows installer custom actionのdeferred実行でINSTALLFOLDERを直接取得できない問題を修正。
  MSI CustomActionData経由のpatch 0006を作成、helperを再ビルド。
- Runtime stage・MSI/Setup生成に成功。最新MSIを実機installして終了値0、
  x64 COM DLL登録先を確認した。**テスト用KanaAIは現在も導入済み**。

## 現在の問題と試した方法

- 実アプリでのかな/漢字/候補/確定/取消/フォーカス試験が未完了。
- 手動TipActivationProbeはロードとclass factory成功、ActivateがE_INVALIDARG。
  対照のMicrosoft TIPでもsink登録に失敗するため、probeのlifecycleも原因候補。
  DLLがロードできたことを入力成功としない。次は登録済みTIPを実アプリで検証する。
- 削除・再導入・rollback、Setup.exe操作試験は未完了。W1/W2の実機担当は一人。
- 本物のローカルモデルは未同梱。AI無し先行ベータの可否は未確定、公開は未実施。
- HEADは2e0630c、未コミット/未追跡ファイル多数。既存変更を消さない。
  ベータ検証前に統合した固定ソースと成果物ハッシュを作る。

## 実行した検証と次の作業

- TSF build harness: static38/path9/fingerprint7成功。pinned host検査成功。
- Windows AI接続unit test: 7件×100回成功。実モデルや実アプリ試験の代用ではない。
- stage/package成功、MSI install終了値0。詳細とログは移行ガイド参照。
- `scripts/start-opencode.ps1 -CheckOnly`: v2.0.16/model/6 agents成功（推論未実行）。
- 開発ロック: 競合拒否・成功後/例外後の再取得成功。
- 次: W1実機入力、A1 AI接続調査、D1公開資料調査を分担し、W2ライフサイクル試験へ進む。
  統括は結果を統合してSTATEとキューを更新する。最終判定は独立verifierのみ。

---

# 以下は過去の開発履歴（最新状態ではない）

# Autonomous Development State

Status: NOT COMPLETE

検証日: 2026-09-25（WSL/Linux）。build agent は最終完成判定権限を持たない。
`.goal-complete` は作成していない。

## Current milestone

Rust broker と Mozc bridge の Linux lab vertical slice は、単一の supervised
bridge process で複数の独立 session を扱えるまで進んだ。broker の
session/generation owner、C++ の bounded `SessionHandler` owner、optional
enhancement queue の correlation が実プロセスで接続されている。

一方、Windows x64 development iteration では patched `mozc_tip64` と
`mozc_server_win` の native MSVC/Bazel build、PE/export/load validation、
supplemental-model native testまで進んだ。ただし artifacts は未インストール・
未登録であり、Notepad/Edge/Office実入力、named-pipe実接続、x86、installer、
AI quality は未証明である。`IsAvailable()` のWindows runtime挙動も未確認。

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
  なる設計。Windows x64 native supplemental-model test は通ったが、実TIP
  runtimeでの値とAI適用は未確認である。
- C++ bridge は source-built Linux lab target であり、Windows x64 TIP/server
  のbuild・PE/load検証までは進んだ。Windows named-pipe process、server-side
  binding、TSF application からの session open/key/edit/rerank/apply/release、
  ACL/reconnect は未実行。
- bridge process kill後のLinux lab recovery（3 cycleのkill/restart/epoch
  invalidation）は実測済みだが、Windows named-pipeのACL/reconnect、orphan
  cleanup、長時間restart stress、loaded broker recovery はまだ release gate。
- Windows x64 TIP は build/load/export validation 済みだが、登録・Notepad/
  Edge/Office相当入力・secure field/UIA・restricted token/AppContainer・
  repair/uninstall/upgrade matrixはない。x86 TIP も未実装。
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
- The worktree is clean; the broker/Mozc/TSF implementation was committed and
  published at `2e0630c23ce7242d020a3c571724c7c67b336216`, and ten further local
  commits sit on top of it (see the handoff at the top of this file). Nothing
  after `2e0630c` has been pushed yet.
- Fresh Rust debug/release tests, workspace Clippy, Windows-target compile/lint,
  bridge replay/build, portable TSF CTest, and isolated staged Bazel tests pass.
- Windows x64 TIP/server source build、PE/load/export validation、native
  supplemental-model testsは通過したが、registration/application runtimeは未証明。
- Windows registration probe returned `E_FAIL` in the non-admin session and
  left no registry keys.
- Immediate implementation task remains: prove installed Windows application
  behavior, x86 coverage, real local model/runtime, learning persistence,
  installer lifecycle, signing, and held-out quality gates.

## Windows x64 development iteration (2026-09-25)

### Completed in this iteration

- Cloned `aruiki/kanai` into an empty workspace, initialized the exact Mozc
  submodule commit `13c98988247aa711d99db9e348ec2a597d14b5cd`, installed the
  locked npm dependencies, and verified the installed Windows toolchain:
  Visual Studio 2022 v143, MSVC 19.44, Windows SDK 10.0.26100.0,
  CMake 3.31.6, Bazel/Bazelisk 9.0.2, Rust 1.98.1, Node 24.19.0, and
  Python 3.13.15.
- Added repository LF checkout policy in `.gitattributes` so a Windows Git
  installation with `core.autocrlf=true` cannot turn Rust sources or replayable
  patches into CRLF. A synthetic clean checkout with autocrlf explicitly
  enabled retained LF for `.gitattributes`, Rust, and the TSF patches and
  passed `cargo fmt --check`.
- Fixed the Windows-only image allowlist regression assertion (`KanaAI` was
  misspelled as `kanai`) and added case-insensitive exact-image acceptance plus
  a sibling-prefix rejection case.
- Removed the POSIX-only `NODE_ENV=production` prefix from `npm run start`.
  A bounded Windows integration run now starts the release Rust API, receives
  `/api/health`, and terminates the complete npm/cargo process tree. The health
  response correctly reports Mozc fallback/unavailable because the optional
  `kanai-mozc-bridge.exe` has not been built in this Windows iteration.
- Fixed the native TSF harness rejecting its own documented default output
  (`windows-beta/tsf`). Dedicated repository siblings are now allowed, while
  the repository root and any output that is a child or ancestor of source,
  build, `third_party`, or Cargo `target` remains rejected.
- Moved the TSF build-cache helper into the shared PowerShell helper module and
  changed the default Bazel cache to
  `%LOCALAPPDATA%\KanaAI\tsf-build-cache`. This avoids MSVC response-file paths
  exceeding the legacy Windows path limit.
- Extended prepared-stage fingerprints to cover the host overlay and all three
  reviewed patches (`0001`, `0002`, and `0003`), preventing reuse of a stage
  after an identity/session patch changes.
- Fixed the registration source test's Windows-only Program Files regex so
  both `Program Files (x86)` and the non-Windows fallback spelling pass while
  the x86 plan remains blocked and source-only.
- Built the patched, pinned Mozc `//win32/tip:mozc_tip64` target on native
  Windows x64 with MSVC/Bazel. The build completed all 1,447 actions and the
  harness passed PE32+ machine `0x8664` plus
  `DllGetClassObject`/`DllCanUnloadNow` export gates.
  - DLL:
    `C:\Users\aruik\AppData\Local\KanaAI\tsf-build-cache\bazel-output-user-root\jbhltpfs\execroot\_main\bazel-out\x64-opt-ST-1d3326959c70\bin\win32\tip\mozc_tip64.dll`
  - size: 4,873,216 bytes
  - SHA-256:
    `0402923F8D8F37A0E8FEA219B2715368ED9AC7066C1F590F8F4DA2F186BE1EDC`
  - imports: `msctf.dll`, `GDI32.dll`, `USER32.dll`, `SHELL32.dll`,
    `ADVAPI32.dll`, `ole32.dll`, `OLEAUT32.dll`, and `KERNEL32.dll`
  - isolated 64-bit `LoadLibraryExW`, both `GetProcAddress` lookups, and
    `FreeLibrary` passed.
  - Authenticode status is `NotSigned`, as expected for this internal build.
  - This is `mozc-tip-validation-only`; no KanaAI artifact was staged, no TIP
    was registered, and no native beta/runtime claim is made.

### Test results in this iteration

- `npm run check`: PASS (Cargo format/Clippy/tests, 85 Rust tests including
  real bridge fallback paths, 3 Vitest tests, and the Vite/TypeScript build).
- `cargo clippy --locked --workspace --all-targets -- -D warnings`: PASS.
- `cargo test --locked --workspace --all-targets`: PASS after the Windows
  allowlist regression fix.
- `powershell.exe -File platform/windows-tsf/build/tests/Test-TsfWindowsBuildHarness.ps1`:
  PASS (3 PowerShell files parsed, 38 static checks, 9 safe-output cases,
  default cache outside the repository, and 4 overlay/patch fingerprint
  records).
- Windows registration, smoke, candidate UI, and pinned-host source suites:
  PASS. The registration suite continues to report `RegistrationComplete`,
  `TipDllPresent`, and `WindowsTestsPassed` as false.
- `python platform/windows-tsf/ui/tests/test_candidate_window_source.py`:
  PASS (7 tests).
- `python platform/windows-tsf/smoke/tests/test_pinned_mozc_tsf_smoke.py`:
  PASS (7 tests).
- `python platform/windows-tsf/tsf/tests/verify_pinned_host.py --repo-root .`:
  PASS for the exact gitlink and patch/host markers.
- Windows x64 Bazel TIP build and PE/export/load checks: PASS as recorded
  above.
- `git diff --check`: PASS.

### Failed approaches and resolutions

- A default Windows Git checkout converted tracked files to CRLF, causing every
  Rust file to fail `cargo fmt` and causing the TSF patch context to fail
  `git apply`. The repository LF policy plus clean-checkout validation fixed
  both without rewriting Mozc or disabling whitespace checks.
- The first native TSF build was rejected because the safe-output helper
  treated the whole repository as protected and therefore rejected its own
  default child output. The boundary now distinguishes safe siblings from
  protected source/build trees.
- A long explicit cache produced a 262-character MSVC `.obj.params` path and
  `cl D8022`. A `K:` `subst` mapping did not help because Bazel canonicalized
  it back to the physical path. The shorter default LocalAppData cache reduced
  the same path to 249 characters and completed the TIP build.
- `//server:mozc_server_win` progressed through C++ compilation but host tools
  such as `gen_pos_matcher_code`, `gen_pos_cost_map`, and `mozc_version` failed
  because their cached Windows `py_binary` launchers embedded the relative
  value `python` and could not locate `python.exe` inside Bazel actions. The
  system interpreter and generated zip work directly, and even a clean probe
  with `--python_path` still embedded `python`; this indicates missing
  `rules_python` toolchain registration in the staged module, not a missing
  interpreter. A clean server build remains blocked until that toolchain is
  registered and pinned.
- The prepared stage applies the provisional identity patch, while the older
  pinned-Mozc smoke preflight is intentionally hard-coded to upstream identity
  metadata. Do not run or interpret that preflight against a KanaAI-identity
  stage until an explicit identity mode/source-output contract is added.

### Current blockers and next concrete task

- The patched x64 TIP now compiles and loads, but it remains unregistered and
  has not typed in Notepad/Edge/Office. There is still no installer, x86 TIP,
  UIA/secure-field matrix, signing identity, or native-beta receipt.
- Add a reviewed, pinned `rules_python` Windows toolchain registration (or an
  equivalent local-interpreter toolchain) to the disposable Mozc stage, then
  clean-build `//server:mozc_server_win` with the same short cache and record
  its hash/dependencies. Do not copy Python DLLs into the output tree or change
  global Windows security policy.
- Separate the `mozc_tip64.dll` source output name from any provisional
  `KanaAI.TsfTip.dll` staging name with an explicit identity mode and atomic
  non-registration manifest. Resolve the identity mismatch with the older
  pinned-Mozc smoke harness before attempting registration.
- After a real TIP/server pair exists, perform a non-destructive registration
  preflight, then obtain explicit operator approval for machine/user TSF
  registration and execute the real Windows host journey. AI ON/OFF, broker
  named-pipe reconnect, model kill, UIA, secure fields, x86/x64, repair,
  upgrade, and uninstall remain release gates.
- `.goal-complete` remains absent; this iteration does not declare project
  completion.


## Codex Windows server build iteration (2026-09-25)

### Completed

- Preserved all changes present at handoff. The user confirmed that opencode
  is stopped/not editing this repository.
- Added Windows-only patch `0004-windows-python-toolchain.patch`, using the
  pinned rules_python 1.9.0 local runtime API to resolve the inspected Python
  executable to an absolute path. Python host actions and real Mozc dictionary
  generation now complete on Windows. No upstream submodule changes.
- Fixed the server session patch referencing nonexistent
  `KanaAiSessionFieldClass`: the actual adapter type is `SessionFieldClass`.
  This was a real Windows server compile failure, previously hidden behind
  the Python build failure.
- Added `-BuildMozcServer` to the existing Bazel TIP build harness. Reproduction:
  `powershell -NoProfile -File scripts/build-tsf-windows.ps1 -BuildSystem Bazel -MozcValidationOnly -BuildMozcServer`.
  It builds both targets; it does not install/register/package them.
- Changed Bazel PATH arguments to inherit the environment already set by the
  harness. This avoids duplicating PATH in the Java process command line.
- Fixed command resolution when two Git installations are on PATH: select
  the first executable, rather than concatenate both executable paths.
  Added a two-directory executable-resolution regression test.
- Windows stage preparation now applies patches with `core.autocrlf=false`;
  fresh replay byte-matches final staged MODULE.bazel and session_handler.cc.
  The Python patch is part of stage invalidation and patch replay verification.

### Actual verification results

- Full documented TIP+server harness above: PASS, exit 0. Fresh stage preparation,
  native MSVC/Bazel build, and TIP PE32+/x64/export checks completed. Final Bazel
  invocation: 42.429 seconds, 2 targets. This timing includes cache reuse and is
  not a clean-build or IME latency benchmark.
- Windows server artifact (not installed):
  `%LOCALAPPDATA%\KanaAI\tsf-build-cache\bazel-output-user-root\jbhltpfs\execroot\_main\bazel-out\x64-opt-ST-908940cc2e23\bin\server\mozc_server_win.exe`.
  SHA-256 `59FDD536D4DC9A24971CC66E54160DE1E0B46FA7A5A62082CAE7C9E2E9E94443`;
  22,333,440 bytes; dumpbin confirms x64 machine 8664 and PE32+ 20B.
  Imports include Windows system DLLs and MSVC/UCRT runtimes; Python is not an
  imported runtime dependency. Server startup through Mozc's sandbox/client
  launcher has NOT yet been exercised.
- Built and executed `//engine/kanai_ai:kanai_supplemental_model_test` natively
  on Windows: 7/7 pass. Then ran `--gtest_repeat=100`: exit 0, 100 successful
  iterations, 700 tests total. Covers inert/unbound behavior, trusted binding,
  nonblocking async publication, generation invalidation, stale binding,
  exact permutation, and mutated-candidate rejection. Uses test transports,
  not an installed TIP, named-pipe integration, or a real model.
- `Test-TsfWindowsBuildHarness.ps1`: PASS, 38 static checks, PE unit checks,
  9 path safety cases, duplicate-command regression, 5 fingerprint records.
- `verify_pinned_host.py --repo-root .`: PASS, all four patches replay.
- `git diff --check`: PASS. No Rust production code changed in this iteration;
  previously existing Rust changes were preserved.
- `scripts/register-tsf-dev.ps1 -DryRun`: executed; CanApply=false. Reports
  provisional identity, missing installed KanaAI.TsfTip.dll, and missing Windows
  registration/application receipt. No registration was performed.
- Logs retained under `%LOCALAPPDATA%\KanaAI\tsf-build-cache`:
  `server-build.log`, `server-build-retest.log`, `tip-server-harness.log`,
  `native-model-tests.log`. These are developer evidence from a dirty worktree,
  not immutable release acceptance.

### Failed approaches and resolutions

- Repeating the entire inherited PATH twice in Bazel flags exceeded Windows'
  32,767-character CreateProcess limit. A short diagnostic action PATH allowed
  diagnosis; the permanent harness fix inherits PATH instead of embedding it.
- After fixing Python, MSVC reported C3083/C2039/C2065 in session_handler.cc.
  Reading the adapter header identified the wrong enum name; corrected patch
  0003 and rebuilt successfully.
- The first final-harness run failed because Get-Command returned two git.exe
  installations and the helper joined their paths. Selecting the first command
  fixed it; the full harness and a duplicate-PATH regression test pass.
- Initial replay hash comparisons failed due solely to CRLF/LF differences.
  An ignore-EOL diff confirmed identical code. With autocrlf disabled in the
  preparation script and the harness regenerating the stage, byte comparisons
  for both changed upstream files passed.

### Remaining problems / next concrete work

1. Build a coherent development runtime layout containing TIP, server, renderer,
   broker and required data/runtimes. Reconcile upstream executable/path/IPC
   identity with KanaAI staging identity before installing anything. The current
   identity patch changes TSF GUIDs but does not establish a complete product
   installation layout. Verify sandboxed server launch and real IPC sessions.
2. Replace registration projection-only handling with actual TSF registration
   and rollback, and resolve provisional identity approval. Prepare a reviewable
   install/uninstall artifact before requesting the operator's registration
   approval. Do not bypass receipt guards or mark metadata true prematurely.
3. Execute Notepad/Edge/Office input, focus, cancel/commit, AI OFF/unavailable,
   broker lifecycle, password/protected fields and UIA tests using installed
   binaries. x86 support and Windows 10/11 coverage remain open.
4. Real local model/runtime packaging, encrypted confirmed-commit learning,
   held-out quality corpus, installer lifecycle, signing and release performance
   gates remain open. The native unit tests do not satisfy these gates.
5. Freeze a source snapshot for independent verification after implementation.
   VERIFICATION.md remains the prior independent FAIL report; `.goal-complete`
   remains absent. This iteration does not declare product completion.
