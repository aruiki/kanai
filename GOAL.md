# /goal — ローカル AI 実装（KanaAI）

> このファイルは**作業モデルへ渡す指示の原本**。コピペして渡す。
> 他のマークダウンの改訂が途中で止まっても、この 1 本だけで作業を再開できる自己完結型にしてある。
> 更新: 2026-09-27 夜。

## 任務

Windows 日本語 IME「KanaAI」の**ローカル AI 経路を実装机で実際に起動させ、機械検証可能な証拠を残す**こと。

AI のコード・実 model・実 runtime・1.1 GB の AI 同梱 MSI は**既に存在する**。
しかし**実装机では AI が一度も起動していない**。
あなたの仕事は新しい AI を書くことではなく、**供給経路の設計矛盾を解消し、AI が起動し、
IME を壊さず、品質・遅延・fallback・privacy を実測で示す**こと。

## 絶対の前提（実測で確定済み。疑ったら再実測して確かめる）

- HEAD `bffc502`（tree clean、`origin/main` と同一）。
  公開済み = GitHub prerelease **`v0.1.0-beta.1`**（AI 無効の Mozc ベータ、未署名）。tag → `2dda3d9`。
- `.goal-complete` は**存在しない。作成禁止**（完成判定は独立 verifier の仕事）。
- `VERIFICATION.md` は 2026-09-25 の独立検証 **FAIL 記録**。**PASS へ書き換え禁止**。
  新しい検証は別の固定コミットに対する別記録として追記する。
- **AI を止めている欠陥（唯一の主因）**
  - 需要側: `crates/kanai-broker/src/bin/kanai-broker/installed_ai.rs:439-449` が
    `<exe>\ai\manifest-v1.json` と `<exe>\ai\STAGING-RECEIPT.json` を必須として `?` で失敗する。
  - 供給側: `scripts/build-windows-installer.ps1:1367-1368` がこの 2 ファイルを
    **MSI payload にすることを throw で禁止**（`:1714-1716` は staging へコピーするだけ）。
  - 実測: 既存 AI 同梱 MSI（`.local/installer-ai-beta/KanaAI-0.1.0-x64.msi`、
    1,124,446,208 bytes）の File table 68 行に `manifest-v1.json` / `STAGING-RECEIPT.json` /
    `PACKAGE-MANIFEST.json` は **1 件も無い**。
  - 帰結: 実装机では `manifest unavailable or oversized` が 1 行出て、以後ずっと Mozc baseline。
    過去の「AI 統合完了」という記録は**誤り**。
- **ユーザー決定 D-7**: 起動 plan を**ビルド時にバイナリへ embed** する。
  manifest/receipt を payload に載せて回避しない。
  起動時のバイトハッシュ検証を**行うか行わないか**を、実測した起動秒数とともに
  **code と文書の両方**へ明記する。省略するなら「起動機械のバイト一致は検証していない」と書く。

## 読む順序（存在すれば。無くても本プロンプトだけで進められる）

1. `docs/AI_IMPLEMENTATION_PLAN.md` — AI 実装の権威文書（作業順序・排他範囲・証拠・コマンド）
2. `AGENTS.md` — 作業規約＋「AI 実装 phase の追加規約」
3. `STATE.md` 冒頭 — 最新の引き継ぎと「次の具体的作業」
4. `docs/A2-08-SUPPLY-PATH.md` — 欠陥のコード実読記録
5. `GOAL.md` / `docs/PRODUCT_RELEASE_CONTRACT.md` — 完成・公開条件（**弱めない**）

## 作業順序（直列。飛ばさない）

AI-0 現在地の再実測 → AI-1 red 回帰テスト → AI-2 検証と生成の分離 → AI-3 D-7 実装 →
AI-4 残欠陥 → AI-5 digest re-pin と AI 同梱ビルド → AI-6 実機証拠 → AI-7 品質評価と公開更新。

**AI-0** source を変更せず、次を走らせて exit code と test 件数を `STATE.md` 冒頭へ記録する。

```
cargo test -p kanai-broker --lib
cargo test -p kanai-broker --bins
cargo test --workspace
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
powershell -NoProfile -ExecutionPolicy Bypass -File platform/windows-tsf/installer/package/tests/Test-AIRuntimeStaging.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File platform/windows-tsf/installer/package/tests/Test-InstallerBuildScript.ps1
```

記録（181 passed / 0 failed / 2 ignored）と食い違ったら、先に緑を取り戻す。

**AI-1** 「MSI payload が broker の要求ファイル名を供給する」回帰テストを**先に**作る。
**現行 code で red になるログを必ず保存する**（非空虚性の証明）。
red を実証していないテストは、欠陥が再発しても黙って green を返す。

**AI-2** `crates/kanai-broker/src/local_runtime.rs` の「検証」と「生成」を分離し、
pinned 定数からの純関数で起動 plan を導出する。unit test は既存 JSON 経路（`:1227-1228`）と
同一値を主張する。

**AI-3** **D-7 実装**。manifest/receipt が無くても起動 plan が組めることを test で示す。
起動時ハッシュの有無と理由、実測起動秒数を記録する。

**AI-4** 残欠陥を閉じる: F1 残余 TOCTOU / H-2（非 ASCII `%TEMP%` で AI 恒久 off）/
H-3（想定 250 ms vs 実測 1.46 s）/ `#[ignore]` 2 件。各欠陥 red→green、H-3 は前後比較。

**AI-5** broker digest を **3 箇所**で re-pin → restage → AI 同梱ビルド。
新 MSI/Setup の SHA-256 を記録し、AI-1 が green になることを確認する。

**AI-6** 実機検証。**実行前にユーザーへ事前連絡**し machine lock を取得する。
AI 起動 receipt（process・model load・loopback port・token・起動秒数）/
native TSF で AI ON と OFF の候補差分 / runtime kill・timeout・malformed output・
model 未導入・broker 障害のそれぞれで Mozc baseline が継続したこと /
secure field での停止 / p50・p95・p99 と working set / loopback 以外の egress が無いこと。

**AI-7** held-out corpus で品質測定（top-1/top-5、MRR、同音語、typo 修復、
catastrophic rewrite 率）→ AI 同梱候補で W1/W2 → 公開更新。
W1 harness の観測欠陥（`error 87` の module 列挙、preedit 未観測、空虚な pass）を先に直す。
