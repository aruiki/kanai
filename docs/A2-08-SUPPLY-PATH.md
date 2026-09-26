# A2-08 の供給経路 — コード実読による前提の訂正（2026-09-26, coordinator）

対象コミット: `df052cb`（tree clean）。これは STATE.md §8 / §9 が「未確認」と明記していた
3 点を**実コードで解決した**記録であり、**実装済みの記録ではない**。

判定: **A2-08 は公開 beta の主経路に blocker ではない**（ユーザー決定 D-1 により公開範囲は
「AI 無効の Mozc ベータ」）。本ファイルは AI 経路を有効化する前に必ず読むこと。

---

## 1. 確認対象だった 3 点とその回答

### 1-1. `start_pinned_ai_runtime` は plan のどの項目を JSON から取るか

**回答: 2 項目が JSON 由来である。他の plan 項目は定数か `options` 由来である。**

呼び出し経路:

- `ai_runtime.rs:1112` `start_pinned_ai_runtime(manifest_json, receipt_json, ...)`
- -> `ai_runtime.rs:1130` `build_runtime_launch_plan(manifest_json, receipt_json, options)`
- -> `local_runtime.rs:520-528` `build_runtime_launch_plan`（両 JSON を `parse_bounded_value`）
- -> `local_runtime.rs:564-577` `build_from_values`
  （`PINNED_BROKER_BYTES` / `PINNED_BROKER_SHA256` / `PINNED_MANIFEST_SHA256` を渡す）
- -> `local_runtime.rs:607-644` `build_from_values_with_identity`

plan の各項目の出所（`local_runtime.rs:631-643`）:

| plan 項目 | 出所 | 行 |
|---|---|---|
| `model_path` | **JSON manifest 由来** `validated_manifest.model_relative` | 621 |
| `server_path` | **JSON manifest 由来** `validated_manifest.server_relative` | 622 |
| `api_key_file_path` | `options.api_key_file` | 623 |
| `api_key_token_reference` | `options.token_reference` | 629 |
| `host` | 定数 `RUNTIME_LOOPBACK_HOST` = `127.0.0.1` | 636 |
| `port` | `options.port`（呼び出し側が `reserve_loopback_port()` で決定） | 637 |
| `context_size` | `options.context_size` | 638 |
| `parallel` = 1 | ハードコード | 639 |
| `device` = `"none"` | ハードコード | 640 |
| `gpu_layers` = 0 | ハードコード | 641 |
| `no_ui` = true | ハードコード | 642 |

`model_relative` / `server_relative` は `local_runtime.rs:1227-1228` で**JSON の directory/file
フィールドから合成**される:

    let model_relative  = join_relative(&model_directory, &model_file)?;
    let server_relative = join_relative(&runtime_directory, "llama-server.exe")?;

**したがって STATE §9 の「定数だけで組む」は、文字どおりでは成立しない。** JSON 由来の項目が
2 つ，而且是 plan の本質的な 2 パス（モデル本体と llama-server）である。

ただし結論は「不可能」ではない。この 2 パスは pinned staging レイアウト定数から一意に決まる。

- `PINNED_STAGING_MODEL_DIRECTORY` = `"model"`（`local_runtime.rs:85`）
- `PINNED_STAGING_RUNTIME_DIRECTORY` = `"runtime"`（`local_runtime.rs:86`）
- `PINNED_MODEL_FILE` = `"qwen2.5-1.5b-instruct-q4_k_m.gguf"`（`local_runtime.rs:50`）
- サーバ実行ファイル名は literal `"llama-server.exe"`（`local_runtime.rs:1228`）

つまり `join_relative` の**入力が定数である**。必要なのは 1227-1228 と同じ導出を定数側から
行うことだけである。

### 1-2. plan 構築関数の責務は「検証」か「生成」か

**回答: 両者が 1 つの関数に融合している。分離されていない。**

`local_runtime.rs:607-644` の `build_from_values_with_identity` は、615-619 で
`validate_manifest` と `validate_receipt` を呼び、**その直後の 631-643 で plan を構築する**。

    validate_embedded_host(&manifest)?;                       // 615
    validate_embedded_host(&receipt)?;                        // 616
    let validated_manifest = validate_manifest(...)?;         // 617  検証
    validate_receipt(&receipt, &validated_manifest, ...)?;    // 618  検証
    options.validate()?;                                      // 619
    ...
    Ok(RuntimeLaunchPlan { ... })                             // 631-643  生成

公開 API 3 つ（`build_runtime_launch_plan` / `build_runtime_launch_plan_from_json` /
`runtime_launch_plan_from_manifest_receipt`）はいずれも生成を返す。**「検証だけ、plan を
返さない」という入口は存在しない。** よって JSON を外すなら、この関数を
「検証（別 artifact に対して）」と「生成（pinned 定数から）」に分ける作業が必ず要る。

### 1-3. `PINNED_MANIFEST_SHA256` は manifest 実体の digest を照合しているか

**回答: 照合していない。`receipt` 内の 1 フィールドと照合している。STATE §9 の前提は誤り。**

`local_runtime.rs:41-44` の doc comment が明示している:

    /// Digest recorded by the reviewed A2-01 staging receipt.  This seam compares
    /// that receipt field; it does not hash the manifest bytes or any model bytes.
    pub const PINNED_MANIFEST_SHA256: &str = "9fab0f80...";

実際の照合先は `local_runtime.rs:1476-1479`:

    let manifest_hash = canonical_sha(receipt_manifest.sha256, "receipt.manifest.sha256")?;
    if manifest_hash != expected_manifest_sha256 {
        return Err(RuntimeConfigError::HashMismatch);
    }

つまり `expected_manifest_sha256 = PINNED_MANIFEST_SHA256` は **receipt が自己申告した
manifest digest と定数が一致するか**を検査している。**manifest 実体をハッシュしていない。**

なお manifest **実体**をハッシュする経路は別にある。`local_runtime.rs:582-605` の
`build_installed_runtime_launch_plan` だけが `&sha256_hex(manifest_json)` を使う。これは
**packaging / 検証側の入口**であって、broker の起動経路（`start_pinned_ai_runtime`）は使わない。
コメント 579-581 も、埋め込むと hash fixed point になるため packaging 側が外から bind する
設計だと書いている。

**帰結**: 「manifest を payload に載せないと `PINNED_MANIFEST_SHA256` の照合が成立しない」
という STATE §9 の懸念は**該当しない**。照合は receipt 側にあり、**receipt を載せない**ことで
消える。**manifest ではなく receipt 側が欠落の直接の原因である。**

---

## 2. 需要側と供給側の矛盾（再確認した根本原因）

需要側 `crates/kanai-broker/src/bin/kanai-broker/installed_ai.rs:439-452`:

    let root = exe.parent()...join("ai");
    let manifest = read_config(&root.join("manifest-v1.json"))
        .map_err(|_| "manifest unavailable or oversized")?;
    let receipt  = read_config(&root.join("STAGING-RECEIPT.json"))
        .map_err(|_| "receipt unavailable or oversized")?;

供給側 `scripts/build-windows-installer.ps1:1367-1368`:

    if ($installPaths -ccontains $aiPayloadRootDirectory + '/' + $ManifestInfo.ReceiptRelative)
        { throw 'The raw local AI staging receipt must never become an MSI payload file.' }
    if ($installPaths -ccontains $aiPayloadRootDirectory + '/' + $aiSanitizedManifestFileName)
        { throw 'The sanitized local AI package manifest must never become an MSI payload file.' }

需要側は 2 ファイルを**必須**として失敗させ、供給側は **throw で payload から禁じる**。
**実在する AI 同梱 MSI（`.local/installer-ai-beta/KanaAI-0.1.0-x64.msi`、1,124,446,208 bytes）の
File table 68 行に `manifest-v1.json` / `STAGING-RECEIPT.json` / `PACKAGE-MANIFEST.json` は
1 件も含まれない**（STATE §8 の実測値）。したがって再ビルドしても AI 経路は起動しない。

---

## 3. ユーザー決定 D-7（2026-09-26）: 「起動 plan をビルド時にバイナリへ embed」

ユーザーは「推奨案 (a)」を選択した。**本ファイルの実読により、その選択の費用構造が確定した。**

選択の intent（STATE §9 の提案）は次の 3 点だった。

1. JSON 由来の項目があるか -> **ある。2 つ、plan の本質部分。** ただし pinned staging 定数から
   再導出可能。
2. 構築関数が検証と生成のどちらの責務を持つか -> **両者を融合している。分離作業が要る。**
3. `PINNED_MANIFEST_SHA256` が manifest 実体を照合しているか -> **照合していない。receipt
   フィールドを照合している。したがって manifest 非同梱の懸念は誤りで、receipt 非同梱が真の
   問題。**

### 3-1. この選択で**失われる**検証（STATE §9 には書かれていなかった費用）

現在の検証は「**pinned 定数と、JSON が自己申告する値の比較**」である。JSON があれば
`validate_manifest` / `validate_receipt` が以下を検査する。

- schema / version / status が pinned 値か
- model の `bytes` / `sha256` が `PINNED_MODEL_BYTES` / `PINNED_MODEL_SHA256` か
- runtime の `bytes` / `sha256` が `PINNED_RUNTIME_*` か
- broker 自体の `bytes` / `sha256` が `PINNED_BROKER_*` か
- staging layout（`model/` `runtime/` `licenses/` の相対パス）が承認 layout か
- archive の entry policy（`PINNED_ARCHIVE_POLICY_*`、`PINNED_RUNTIME_ENTRY_NAMES_SHA256`）か

**この検査は「JSON の値を定数と比べるだけ」で、起動時に実バイトを読み込まない。**
つまり現状でも「起動した機械の model バイトが pinned digest に一致すること」は
**保証されていない**。保証しているのは「pinned 値に紐づいた**一連の自己申告**が一貫する
こと」だけである。

したがって embed 案の真の費用は次の 2 点であり、STATE §9 の想定より大きい。

**(A) 検証の空白が生じる**: JSON なしで `validate_manifest` / `validate_receipt` を通す方法は
「検証を丸ごと省略」になる。GOAL の `unknown is never treated as absent` と同じ方向に反する
（**検証していないのに検証済みと書かない**）。

**(B) 起動時に実バイトをハッシュする必要が生じる**: 保証を強化するには、起動時に
`ai/model/...gguf`（`PINNED_MODEL_BYTES` = 1,117,320,736 = 約 1.04 GiB）と runtime 51 ファイルの
実 digest を計算する必要がある。これは **Fast Path ではなく非同期の起動時**なので GOAL の
「キー入力の同期処理に投入しない」は満たすが、**起動時間と 1 GiB 読み込みという実費用**が生じる。
起動時ハッシュを省略すれば (A) の空白に戻り、記載すれば AI 有効化時の起動が数秒遅くなる。

### 3-2. 現時点で**実装してはならない**こと

以下を実装済みと書かない。**未実装である。**

- `installed_ai.rs` は **変更していない**。まだ `manifest-v1.json` と `STAGING-RECEIPT.json` を
  必須として失敗させる。AI 経路は実装机で**一度も起動していない**。
- `build_runtime_launch_plan` の**検証と生成の分離**は**未着手**。
- 起動時ハッシュ、起動時間測定、起動失敗時の fallback 実測は**すべて未実施**。

---

## 4. 次の作業（AI 有効化の前に必ず順どおり）

1. `build_from_values_with_identity` を「検証」「生成」に分離する API 境界を作る。
   既存 3 公開 API は**挙動を変えず**残す（呼び出し元が broker tests に存在する）。
2. pinned staging 定数から `model_relative` / `server_relative` を導出する**純関数**を追加し、
   1227-1228 の JSON 経路と**同一の値**になることを unit test で固定する。
3. 「payload に manifest/receipt を載せる / 載せない」の**実測**を、供給側スクリプトの throw を
   改动せずに求める。**現行方針を改訂する場合は改訂方針を書面で固定してから**実装する。
4. 起動時ハッシュを採るか否かを**製品判断として**決める（費用 (B)）。採るなら 1 GiB 読み込みの
   実測（起動秒数・失敗時 fallback・Mozc ベースライン保持）を A2-07 と 함께測定する。
5. AI negative case と「payload と broker の要求するファイル名が一致すること」の
   回帰テスト（STATE §8 が「finding」とした未整備項目）を先に整備する。**これが無いと欠陥が
   再発してもテストは黙って green を返す。**

## 5. 参照

- 実装: `crates/kanai-broker/src/bin/kanai-broker/installed_ai.rs`、
  `crates/kanai-broker/src/local_runtime.rs`、`crates/kanai-broker/src/ai_runtime.rs`
- 供給: `scripts/build-windows-installer.ps1:1367-1368`、`:1714-1716`
- 履歴: `STATE.md` §8 / §9、`docs/WORK_QUEUE.md` の A2-08 行
