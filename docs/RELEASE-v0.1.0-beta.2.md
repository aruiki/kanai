# KanaAI 0.1.0-beta.2 — ローカル AI 同梱版（unsigned / 完全オフライン / 既定 ON）

> [!WARNING]
> **未署名・未完成のベータです。** Windows SmartScreen / publisher 警告が出ます。
> 警告を避けるために SmartScreen、Smart App Control、ウイルス対策、企業ポリシーを
> **無効化しないでください**。日常利用の安定性は保証されません。
> ダウンロードは **約 1.1 GB**（モデル同梱）、導入後の使用メモリは AI 有効時に
> **子プロセスで約 1.6 GB** です。
>
> **重要**: この版の AI は**起動しますが、変換結果を変えません**（§4.3 に実測）。
> 「AI が動く経路を作った」版であって、「変換が良くなった」版ではありません。

## 1. beta.1 から何が変わったか

beta.1 は「AI 非搭載の Mozc ベータ」でした。beta.2 は **ローカル AI を同梱し、
製品経路で実際に起動する**最初の版です。変更は 4 点で、3 つは実測した欠陥の修正、
1 つは挙動変更です（どれかを「修正」と偽らないよう、区別して書きます）。

### (1) 製品が AI の opt-in を渡していなかった（AI が一度も起動しなかった原因）

AI のコード・モデル・runtime は以前から存在し、手動で opt-in を渡せば
**起動して応答していました**。しかし製品は opt-in をどこにも記録しておらず、
ブローカーは設計どおり fail-closed で停止し、しかも**その事実を誰も言わなかった**ため、
1.1 GB のモデルを同梱した MSI を導入しても AI は常に off でした。

beta.2 のパッケージは opt-in を自分で記録します。

| 場所 | 意味 | 実測 |
|---|---|---|
| `HKLM\Software\KanaAI` `Enhancement` = `local` | この PC の既定値 | **書けている** |
| `HKCU\Software\KanaAI` `Enhancement` = `local` | 導入したユーザー自身の設定（既定値より優先） | per-machine 導入では**書けない**（§6） |

MSI には両方のコンポーネントが入っていますが、**per-machine インストールでは HKCU 側が
導入ユーザーの hive に着地しない**ことを実測しました。ブローカーは HKCU → HKLM の順に
読むため、**HKLM 側だけで既定 ON として機能します**。どちらもアンインストールで削除されます。

### (2) 導入直後の IME を既定で ON にする（**欠陥修正ではなく挙動変更**）

Mozc の `TipStatus::IsOpen` は open/close compartment が存在しないとき false を返し、
新規プロファイルはそれを持ちません。patch `0007-kanai-ime-open-by-default` は、
conversion mode が既に使っていたのと同じ `GetAndEnsureDataExists` 経路で、
activation 時に既定値を書き込みます。**保存済みの値は必ず勝つ**ので、自分で IME を
閉じたユーザーが毎回開かされることはありません。影響は実質的に初回だけです。

**この項目について、開発中の誤りを訂正して記録します。** 作業の初期段階では、これを
「導入直後は日本語が入力できない欠陥の修正」と位置づけていました。**それは誤りです。**
IME の ON/OFF と、かな／半角英数の入力モードは別の状態です。新しいアプリで IME が OFF
から始まり、そのまま打つと英字が出るのは Microsoft IME でも ATOK でも通常の挙動であり、
欠陥ではありません。したがって patch 0007 は利便性のための**挙動変更**であって、
欠陥修正ではありません。Windows の慣例に沿っているとも言い切れません。

この patch は 64bit と 32bit の両方の TIP に入っています（object のシンボル表で
`TipStatus::GetAndEnsureIMEOpen` の定義と参照を両方のビルドで確認済み）。

### (2b) AI が製品経路で起動しなかった本当の原因（低整合性）

(1) の opt-in を入れてもなお、**実際の入力時には AI が起動しませんでした**。実測:

```
broker(28616) startedBy=mozc_server  ws=7MB   children=[conhost]          ← AI なし
broker(21412) startedBy=powershell   ws=8MB   children=[conhost, llama-server] 1664MB
```

同じバイナリ・同じ PC・同じアカウントで、違いは親プロセスだけでした。
Mozc は IME サーバーを**低整合性**（integrity SID `S-1-16-4096`）で動かし、
そこから起動されるブローカーも低整合性を継承します。低整合性プロセスは
`%TEMP%`（中整合性ラベル）にディレクトリを作れません。鍵ルートの候補が `%TEMP%`
だけだったため、probe が失敗し、AI 経路は放棄されていました。

**しかも、その理由はどこにも残りませんでした。** テキストサービスはブローカーに
コンソールもリダイレクト先も与えないので、ブローカーが出力した診断はすべて捨てられ、
外からは「設計どおり AI が無効」と「AI の起動に失敗した」が区別できませんでした。

修正は 2 点です。

- 鍵ルートの候補に `AppData\LocalLow\KanaAI` を追加（Windows が低整合性向けに
  用意している場所）。`%TEMP%` が第1候補のままなので、通常のブローカーの挙動は不変です。
- 起動診断を `broker-startup.log` に記録し、`%LOCALAPPDATA%` に書けなければ
  `LocalLow` へフォールバック。中整合性でしか記録できない診断は、診断が必要な実行では
  必ず欠落するからです。

鍵ファイルの保護は弱まりません。鍵の書き手が自分でディレクトリを作り、
所有者のみの `CREATE_NEW` ファイルを書き、既存のディレクトリは拒否します。

### (3) 導入ユーザーに入力方式が有効化されていなかった

`EnableTipProfile` カスタムアクションの書き込みが `HKU\S-1-5-18` と `HKU\.DEFAULT`
に落ちており、対話ユーザーの hive には入っていませんでした。MSI が HKCU コンポーネントとして
自分で書くようにしました。

## 2. ローカル AI について（完全オフライン）

- モデル: Qwen2.5-1.5B-Instruct (Q4_K_M GGUF, Apache-2.0)、1,117,320,736 bytes
- runtime: llama.cpp CPU ビルド (build 11146, MIT)、51 ファイル
- **ネットワークアクセスは一切ありません。** runtime は loopback
  (`127.0.0.1`) のみで listen し、プロセスごとの鍵で保護されます。
  テキストがこの PC の外へ出ることはありません。
- 起動時に同梱バイトのハッシュ検証を行います。
- AI が未起動・タイムアウト・異常応答・停止のいずれでも、変換は Mozc baseline が
  そのまま使えます。AI はキー入力の同期処理には入りません。

**AI を止める / 戻す**（コマンドプロンプト）:

```
"C:\Program Files\KanaAI\kanai-broker.exe" --disable-local-ai
"C:\Program Files\KanaAI\kanai-broker.exe" --enable-local-ai
"C:\Program Files\KanaAI\kanai-broker.exe" --ai-status
```

自分のユーザー設定だけを書き換えます。反映は次に入力方式が起動したときです。

## 3. 配布ファイルと SHA-256（固定）

| ファイル | bytes | SHA-256 |
|---|---:|---|
| `KanaAI-0.1.0-Setup.exe` | 1,124,611,072 | `F61D86BF95AC97723D733A76B33BE6BB8FF6FFED6E9A3973BDC1FADB641A17A0` |
| `KanaAI-0.1.0-x64.msi` | 1,124,605,952 | `608F1B6A6D8ADBCF63B9CCAD49E19333D69175DF5E1EB90EB8350DF93CF1C288` |

```powershell
Get-FileHash .\KanaAI-0.1.0-Setup.exe -Algorithm SHA256
Get-FileHash .\KanaAI-0.1.0-x64.msi   -Algorithm SHA256
```

**名前の注意**: パッケージ内部の `ProductVersion` とファイル名は `0.1.0` です
（tag / release 名は `v0.1.0-beta.2`）。同一物かどうかは**必ず SHA-256 で照合**してください。
`Setup.exe` は埋め込み MSI を一時フォルダへ展開して Windows Installer を起動する launcher で、
MSI 単体でも導入できます。両者は同一候補です。

## 4. 検証済み / 未検証

この節は宣伝ではなく証拠の記載です。

### 4.1 機械検証済み: W2 インストーラ lifecycle（receipt あり）

- receipt: `runId=20260928-135204-f13105be` / `mode=execute` / **`overall=passed`** / `exitCode=0`
- **11 phase すべて pass**（pass 以外の outcome は 1 件もありません）:
  `PF-01`, `PF-02`, `IS-01`, `UC-01`, `IM-01`, `RS-01`, `UF-01`, `DR-01`, `UC-02`, `OB-01`, `CL-01`
- 内容: Setup.exe ダブルクリックでのクリーン導入 / TSF 登録 / クリーンアンインストール /
  MSI 直接導入 / 同一 ProductCode への再インストール（repair 偽装でないことの証明）/
  上位版での上書き（MajorUpgrade）/ 下位版の拒否 / 最終アンインストール /
  独立した不在確認 / cleanup の冪等性
- 対象: §3 と**同一 SHA-256** の MSI / Setup（receipt に digest で固定。
  receipt が記録する MSI digest は `608f1b6a...` = §3 の公開ファイルと同一）
- **上書き・ダウングレードの検証も AI 同梱パッケージで実施**しました
  （0.0.9 / 0.1.1 を同じ payload で別途ビルド。Mozc のみの代用品は使っていません）。
  この 2 本は公開物ではなく、上書き・拒否の挙動は ProductVersion と UpgradeCode で
  決まるため、低整合性修正の前のブローカーを含むビルドのまま使っています
- 環境: Windows `10.0.26200.0` x64 / PowerShell 5.1 / elevated administrator / **1 台のみ**
- 実行前に、この機械に残っていた**過去セッションの KanaAI 3 製品をすべて削除**して
  ベースラインへ戻しています（3 件とも uninstall exit 0、インストール先ディレクトリも消滅）。
  そうしないと「初回導入」も「アンインストール後に何も残らない」も測れません。
- receipt 自身が宣言する**範囲外**（`scopeLimits`）:
  実アプリでのローマ字→かな変換の証明、**AI payload が動作すること**、
  失敗した upgrade のロールバック、意図的に破損させたファイルの repair、
  署名済み / GA 製品であること。

### 4.2 実機で確認済み: 日本語入力と AI の起動

**日本語入力（オペレータ確認 + 客観的裏付け）**

公開する MSI から導入した状態で、製品所有者が実機で確認しました:
`Win`+`Space` で KanaAI を選択 → 半角/全角で IME を ON → ローマ字入力・変換・候補表示・
確定・取消・フォーカス切替が**動作する**。

同じセッションでの客観的な裏付け（機械が読んだ値。入力内容は読んでいません）:

- `mozc_tip64.dll` が **11 個の実プロセス**にロードされていることを確認
  （`Notepad`、`chrome`、`explorer`、`msedge`、`Cubase15`、`SearchHost`、
  `msedgewebview2`、`PowerToys.Peek.UI` ほか）
- テキストサービスが `mozc_server` を起動し、そこから `kanai-broker` が起動していること

**AI の起動（この版の中心的な主張）**

公開する MSI から導入したバイナリ（`kanai-broker.exe` = `9CAFE054…`）で、
**環境変数を一切設定せずに**、実際の入力操作によって:

```
LocalLow\KanaAIroker-startup.log:
  pid 34412  kanai-broker: local AI is enabled; starting the runtime
kanai-broker 34412     8 MB
llama-server 29088  1678 MB   ← 1.1 GB のモデルがロードされている
```

つまり**パッケージが書いた opt-in だけで AI が起動しています**。
同じバイナリを手動起動したときの内訳（実測）:

```
pinned local AI bytes verified (2 files hashed, 1117324349 bytes, 51 runtime entries, 0.650s)
runtime warm after one completion (0.094s, bound 30s, prompt "warm")
```

同梱バイトのハッシュ検証が 0.650 秒で完了し、**推論が実際に返っています**。

**off スイッチ**: `--disable-local-ai` を実行したブローカーは 0.42 秒で
「起動しない」と報告し、runtime 子プロセスを作りません（実測）。

### 4.3 未検証・未実施（重要）

**この版が達成したのは「AI が起動する経路を作ったこと」であって、
「変換が良くなること」ではありません。** 以下は未検証です。

- **AI ON / OFF で確定テキストは変わりません（測定済み）。**
  公開バイナリで、同じローマ字 5 ケースを AI 有効・無効の 2 回打ち比べた結果、
  **差分 0**（receipt: `ai-candidate-difference-20260928-233520.json`、
  verdict `ai-does-not-change-output`）。
  測定が有効であることの根拠: 打鍵前にプローブホストへ `mozc_tip` がロードされている
  ことを確認するゲートを通過（本製品を測っている）、`brokerSha256` が公開ビルドと一致、
  そしてブローカー自身の起動ログが 2 つの腕で
  `local AI is enabled; starting the runtime` と
  `local AI not started (no opt-in recorded…)` を記録（**切り替えが実際に効いていた**）。

  **したがって、この版の AI は起動するが変換結果に関与していません。**
  体感される変換品質は Mozc baseline のものです。
- **日本語変換品質の評価は未実施**です。`STATE.md` には過去のモデル品質評価で
  **6 ロールとも出荷不可**という記録が残っています。AI が動いても変換が改善する保証は
  ありません。
- **入力の自動ハーネスによる W1 receipt は取得していません。** 今回の実行では
  ハーネスが `TIP-DLL-NOT-LOADED` を正しく critical finding として報告しました
  （KanaAI ではなく既定の入力方式を測っていたため）。ハーネスは正しく、
  測定の組み立てが誤っていました。修正は次回に持ち越します。
- **per-user の入力方式有効化レコードは書けていません**（§6 参照）。
- secure/password field、UIA、high-DPI、app-container policy
- 性能測定（変換レイテンシ、CPU、メモリ）、privacy の機械検証（egress 検査など）
- 検証は **1 台・1 ユーザー・x64・Windows 11 build 26200 のみ**
- build manifest 自身の宣言: `status=unverified-installer-candidate`、`verified=false`、
  `installedInputVerified=false`、`aiOperationVerified=false`、`aiStartupTested=false`
  （これはビルド時点の宣言で、上記の実機結果を否定するものではありません）
- 独立 verifier による GOAL 全条件の判定は**未実施**。`VERIFICATION.md` の最新独立記録は
  2026-09-25 の **FAIL / NOT COMPLETE** のままで、本公開はそれを書き換えません。
  **`.goal-complete` は作成していません。**

## 5. 成果物の由来（固定情報）

| 項目 | 値 |
|---|---|
| source commit | `b5c1e242f78a6026876b263436a0c03865c0d304`（`treeDirty=false`、`-RequireCleanSource`） |
| Mozc gitlink | `13c98988247aa711d99db9e348ec2a597d14b5cd`（clean） |
| patch 数 | **7**（beta.1 の 6 件 + `0007-kanai-ime-open-by-default`） |
| patchSetSha256 | `DFB5A675E324FFC34BFBDF7E2B4031424B83149C3CC9537FCFA6C965A9D87D6A` |
| host overlay fingerprint | `0CFE6D85991A68A77F6DC2BA9CEC2D65B6FF277C0819979FE2D958267B9B8605` |
| toolchain | Bazel `9.0.2` / Visual Studio 17 2022 / `Release` / `x86_64-pc-windows-msvc` |
| toolchain.json SHA-256 | `F792B723A1EC14BE1309D53207CF0A3FDAEFB08E0ADC1FD030E1AB215F211425` |
| WiX | `5.0.2+aa65968c` |
| ProductCode | `{AF1CE62F-55ED-436D-A52B-89F7AB1A01DF}` |
| UpgradeCode | `{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}` |
| runtimeManifestSha256 | `2E86FE809875AFBCF0DD3AE44D9C388CA0485C2B1327AA09B9F0048641FE8712` |
| installerHelperSha256 | `23D3E293A74EB6BD05CC4DA5EEAE5D1F1BA4252786904676584017CA8C2EF654` |
| 署名 | `unsigned` / MSI `NotSigned` / Setup `NotSigned` |
| AI payload | `localAiIncluded=true` / 56 ファイル |
| `mozc_tip64.dll` | 4,874,240 bytes / `CFD9A4DE6FBA3092B61679930D5116CC4D61CC1AAD8B7A200B4A124017EDD909` |
| `mozc_tip32.dll` | 4,596,736 bytes / `FA46FF66FC66DCB51AE04D39FCE0E3A746E92CF5A04D1496BE5B139144257770` |
| `kanai-broker.exe` | 3,371,008 bytes / `9CAFE0542F115B9E7276723691447DE444A88D7CF8939A523EE28200D0E8E726` |

build manifest 自身の宣言: `status=unverified-installer-candidate`、`verified=false`、
`installedInputVerified=false`、`aiOperationVerified=false`、`aiStartupTested=false`。
これはビルド時点の宣言であり、実機での検証結果は §4 に記載します。

## 6. 既知の制限

- **未署名**です。Windows の SmartScreen / publisher 警告が出ます。
  警告を回避するために保護機能を無効化しないでください。
- **ダウンロード約 1.1 GB、AI 有効時のメモリ約 1.6 GB**（別プロセス）。
- **変換品質の改善は主張していません**（§4.3）。AI は起動しますが、候補への影響は未測定で、
  モデル品質の過去評価は出荷不可でした。
- **導入ユーザーへの入力方式の有効化レコードが書けていません。**
  MSI には該当の HKCU コンポーネントが含まれていますが、**per-machine インストールでは
  導入ユーザーの hive に着地しない**ことを実測しました（Setup.exe 経由・MSI 直接の
  いずれでも `userActivationEnable` が空）。入力自体は TSF 登録経由で動作しますが、
  導入直後に `Win`+`Space` で KanaAI を選ぶ操作が必要です。
- patch 0007 により**導入直後の IME は既定で ON** になります。Windows の慣例とは異なります
  （§1-(2)）。一度自分で OFF にすれば、その設定が優先されます。
- x64 のみ検証。ARM64 未検証。1 台の Windows 11 build 26200 でのみ検証。
- 同梱 AI は CPU 実行です。GPU は使用しません。

## 7. 導入と削除

**導入**

1. `KanaAI-0.1.0-Setup.exe` をダウンロードし、§3 の SHA-256 と照合する。
2. `Setup.exe` を起動し、UAC を承認する。ビルド・手動コピー・コマンド入力は不要です。
3. `Win`+`Space` で **KanaAI** を選ぶ（導入直後は自動で既定になりません。§6 参照）。
4. 半角/全角キーで IME を ON にして入力します。

**削除**: 設定 → アプリ → インストール済みアプリ から「KanaAI Development Preview」を
アンインストール。§4.1 の receipt でクリーンな削除を確認しています。

## 8. ライセンス

- KanaAI 自身のソース: **MIT OR Apache-2.0**
- Mozc: 同梱の `MOZC-LICENSE.txt`
- モデル Qwen2.5-1.5B-Instruct: Apache-2.0（`ai\licenses\`）
- 推論 runtime llama.cpp: MIT（`ai\licenses\`）
- KanaAI は Google と提携しておらず、サポートも受けていません。

## 9. 不具合の報告

GitHub Issues へ。AI が起動しない場合は
`%LOCALAPPDATA%\KanaAIroker-startup.log` または
`%USERPROFILE%\AppData\LocalLow\KanaAIroker-startup.log` の内容を添えてください
（このログは設定値・パス・入力テキスト・トークンを含みません）。
個人情報・辞書・API キーは redact してください。
