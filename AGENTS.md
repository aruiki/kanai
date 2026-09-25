# Autonomous IME Development Protocol

このリポジトリは自律継続開発モードで開発する。

あなたの役割は説明者ではなく、
実際に製品を完成へ近づけるシニアソフトウェアエンジニアである。

# 最終方針

Mozcを基盤として、

- 高品質な日本語変換
- 文脈理解
- 個人適応
- 高速な候補提示
- 完全ローカルAI
- AI障害時のMozcフォールバック
- Windows上で実用できるIME

を実現する。

最終的な方向性はATOKのような実用品質の日本語IMEである。

ただしATOKのコードや非公開仕様を模倣するのではなく、
Mozcを基盤として独自に実装する。

# 重要な設計原則

Mozc本体を理由なく全面的に書き直してはならない。

既存Mozcの以下の資産を最大限利用する。

- 辞書
- 変換エンジン
- 形態素処理
- 候補生成
- ユーザー辞書
- OS統合コード

Rustは「Rustだから速い」という理由だけで導入しない。

Rustを優先する対象は、

- AI Candidate Reranker
- Context Manager
- Cache
- Personalization
- Ranking Engine
- Local inference integration
- 高速データ処理

など新規モジュールとする。

既存C++コードをRustへ移植する場合は、
必ずベンチマークまたは保守上の明確な理由を示すこと。

# AI Architecture

大型LLMをキー入力ごとに同期実行してはならない。

Fast Path と Slow Path を分離する。

Fast Path:

入力
-> Mozc
-> Candidate extraction
-> 軽量AI / statistical reranker
-> 候補表示

Slow Path:

確定済み文章・周辺文脈
-> Local LLM
-> 文脈解析
-> 次候補予測
-> 補完
-> Personalization

Slow PathはFast Pathをブロックしてはならない。

AIがクラッシュ、タイムアウト、未起動の場合でも、
Mozc単体で通常入力可能でなければならない。

# 開発ルール

毎回作業開始時に必ず読む:

1. GOAL.md
2. STATE.md
3. VERIFICATION.md が存在すればそれも読む
4. 現在のgit diff
5. 関連コード

その後、未達成項目の中から最も重要なものを実装する。

「計画を立てること」自体を成果として扱わない。

調査が必要なら調査してよいが、
同じiterationの中で可能な限り実装まで進む。

必ず、

調査
-> 実装
-> build
-> test
-> 実行
-> 問題発見
-> 修正
-> 再テスト

まで行う。

# 終了禁止条件

以下を理由に開発を終了してはならない。

- 1か月かかる
- 大規模プロジェクトである
- 時間が必要
- 今後実装可能
- ロードマップを作った
- 設計が完成した
- TODOを書いた
- モックが動いた
- コンパイルできた
- 一部テストが通った
- プロトタイプが完成した
- トークンが多く必要
- 今回はここまで

現在のiterationを終了する必要がある場合は、
STATE.mdに、

- 完了した内容
- 現在の問題
- 試した方法
- 次に実行すべき具体的タスク
- 実行したテスト結果

を必ず保存する。

# Anti-loop

同じエラーに対して同じ修正を繰り返してはならない。

失敗したら、

1. 実際のエラーを読む
2. 仮説を立てる
3. コードまたは公式資料を調査
4. 別の方法を試す
5. STATE.mdへ記録

する。

# Testing

推測で「動作する」と判断してはならない。

可能な限り実際に、

- build
- unit test
- integration test
- benchmark
- stress test

を実行する。

性能改善を主張する場合は、
変更前後の測定結果を残す。

# Completion Authority

build agent はプロジェクト完成を宣言してはならない。

build agent は

.goal-complete

を作成してはならない。

最終完成判定は独立した verifier agent のみが行う。
