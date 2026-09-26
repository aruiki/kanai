# KanaAI 製品要件解釈（ドラフト）

更新: 2026-09-26

## この文書の位置付け

この文書は、ユーザーと coordinator が確認した KanaAI の製品解釈を、実装・検証・公開判断の共通言語として記録する。

- 最終的な完成条件は `GOAL.md` を優先する。
- 配布段階と公開条件は `docs/PRODUCT_RELEASE_CONTRACT.md` を優先する。
- 実測結果と未検証範囲は `STATE.md` に記録する。
- この文書だけをもって、AI動作・品質・ベータ公開・製品完成を宣言しない。

## 1. 製品定義

KanaAI は、Mozc を日本語変換基盤とする Windows ネイティブ日本語 IME である。

目的は、チャット画面や別サービスではなく、通常の日本語入力の途中で、bounded なローカル AI を必要に応じて追加することである。

公開対象はユーザー決定により **AI 同梱版のみ** とする。AI 非搭載版は公開用製品にしない。開発・試験用の疑似的な AI や基準となる build は存在し得るが、公開 beta とは呼ばない。

## 2. 必須機能

### 2.1 Windows TSF

- Windows の日本語入力方法として登録できること。
- Notepad、Edge、Office 等の通常アプリで利用可能であること。
- ローマ字入力、かな preedit、漢字変換、候補表示、確定・取消を実装すること。
- Space、Enter、Esc、フォーカス喪失、入力元再起動を安全に扱うこと。
- beta では x64 TSF を最低対象とする。x86 版を installer に含める場合は x86 と同等の登録・入力・削除検証を行う。**完成版の GOAL に記載された Windows 10/11 x86/x64 条件を縮小する解釈ではない。**

### 2.2 Mozc fast path

- composition、segmentation、辞書、変換候補、preedit、commit・cancel は pinned Mozc の機能を基礎とする。
- 日本語変換エンジンを理由なく再実装しない。
- キー入力と preedit の同期経路では、model、disk I/O、外部 network を待たない。
- AI 無効、model 未導入、broker 障害時も Mozc baseline を返す。

### 2.3 bounded local AI

- AI は Mozc が返した候補の順序だけを調整する。
- 候補の追加・削除・文字列変更・未知 ID の生成を禁止する。
- 現在の reading、許可された短い context、bounded な candidate window だけを渡す。
- key入力、clipboard、URL、window title、未確定入力全文を送らない。
- candidate ID の完全 permutation、session、generation、deadline、cancellation を検証する。
- 未知 ID、重複、欠落、古い generation、不正 response、timeout は baseline へ戻す。
- AI は mode、preedit、commit、undo、学習の authoritative な状態を持たない。

### 2.4 AI 同梱と自動起動

- 公開 Setup に model と runtime を含める。
- model/runtime は revision、size、SHA-256、license、notice、SBOM、provenance を固定する。
- ユーザーがterminal、environment variable、browser、手動server setupを用意する必要はない。
- production は installed sibling directory の manifest を使い、相対 path と file identity を検証する。
- runtime は loopback 以外の bind、DNS、egress を行わない。
- process は per-process token で認証する。
- broker/model の停止、kill、timeout、malformed response 後、Mozc 入力を継続する。
- process は orphan を残さず、bounded restart、graceful shutdown を行う。
- 現在の Qwen2.5-1.5B + llama.cpp の組み合わせは実装候補であり、model 銘柄の永久的固定ではない。

## 3. プライバシーとセキュリティ

- 本番 AI は local-first とし、cloud AI、mandatory telemetry、remote sync、広告を同梱しない。
- API key、user profile、user text、raw key log を Setup に含めない。
- password/protected/UAC/Protect field では AI request、context 取得、learning、history 保存を停止する。
- learning は confirmed commit または explicit user action からのみ生成する。
- browser の localStorage は開発 Workbench の試験用であり、本番の encrypted native store としない。
- model、prompt、candidate、token、arbitrary process output を lifecycle log に出さない。

## 4. 性能・品質

- fast path は大型 model、disk I/O、network を synchronous に block しない。
- optional AI は非同期または deadline 付きで処理する。
- 実際の Windows TSF と実 model で、候補、確定、取消、fallback、privacy、CPU、RAM、latency、disk、process 数を測定する。
- Mozc baseline に対する非劣化と、定義した日本語 corpus での改善を示す。
- top-1、MRR、NDCG 等の評価対象・閾値は benchmark で固定する。
- 未実測の速度、RAM、モデル品質を製品保証にしない。

## 5. Installer と公開

公開 Setup は、起動後の manual copy や command 入力を不要にする。

- clean Windows profile に offline install できること。
- TSF/COM/profile 登録、repair、upgrade、uninstall、reinstall、rollback を検証すること。
- model/runtime と license/notice/SBOM が正しい location に置かれること。
- UAC、再起動要求、署名状態、SHA-256 を説明すること。
- 未署名 beta を公開する場合は警告と検証不能な署名を明記する。
- 公開対象 source commit、patch、成果物 hash を固定する。
- 公開ベータは独立 verifier の beta 判定を必要とする。
- beta 公開は GOAL 全条件の達成を意味せず、`.goal-complete` を作らない。

## 6. 非対象

- Workbench、CLI、HTTP API 単体 beta
- cloud AI 必須、chat 主体、full-document 無制限送信
- Mozc の再実装
- Google の proprietary code、dictionary、binary、data のコピー
- macOS/Linux/複数 shell の同時完成
- hidden telemetry、mandatory account、advertising
- 未検証 model・installer・source test の公開

## 7. 公開 beta の exit gate

- native TSF registration
- actual app input、conversion、candidate、commit、cancel、focus、restart
- AI ON/OFF、model kill、broker kill、timeout、malformed output
- protected field、privacy、no unexpected egress
- clean install、uninstall、reinstall、rollback、orphan cleanup
- pinned model/runtime digest、license、notice、SBOM、provenance
- held-out Japanese quality、resource、latency measurements
- immutable source/artifact identity
- independent verifier report

## 8. 未確定の製品判断

以下は実装結果とユーザー確認を受けて固定する。

- 最低 Windows version と x86 の beta 対象範囲
- 最低 CPU/RAM と model size の許容範囲
- beta の AI 機能を candidate rerank だけにする範囲
- native learning persistence を beta 必須にするか
- 未署名 beta の許容
- 正式対応 app と its test matrix
- beta と完成版で必要な署名範囲
