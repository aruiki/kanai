あなたはこのプロジェクトのリードエンジニアです。

このプロジェクトを「アイデア・設計段階」ではなく、
実際に使用可能なAI強化Mozc IMEへ進めてください。

まず AGENTS.md、GOAL.md、STATE.md を完全に読んでください。

次にリポジトリ全体を調査し、

- 現在実装済みのもの
- Mozcの配置
- build system
- Rustの有無
- AI関連実装
- テスト
- 現在壊れているもの

を実際のファイルから把握してください。

ただし調査レポートを書いて終了してはいけません。

現在のコードをbuildし、
可能なテストを実行し、
その結果を確認した後、
最も重要な未実装部分の実装に直ちに着手してください。

最初の技術的優先順位は、

Mozc candidate generation
→ candidate extraction
→ context extraction
→ ranking interface
→ local AI reranking
→ reordered candidate output

という実際に動作するVertical Sliceです。

Mozc全体のRust書き換えから始めないでください。

Rustは新しいranking/context/AI layerを中心に利用してください。

大型LLMを各キーストロークで同期実行する設計は禁止です。

Fast PathとSlow Pathを分離してください。

実装後は必ずbuild/testを実行してください。

今回のiterationでプロジェクト全体が完成しなくても構いませんが、
「時間がかかるので終了」という判断は禁止です。

iteration終了時は必ずSTATE.mdを更新し、
次のagentが迷わず作業を続行できる具体的状態を残してください。

.goal-complete は作成しないでください。

今すぐ調査と実装を開始してください。
