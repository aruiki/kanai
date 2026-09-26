# 開発状況の読み方

最新の状態は[STATE.md](../STATE.md)冒頭、製品完成条件は[GOAL.md](../GOAL.md)、配布条件は[リリース契約](PRODUCT_RELEASE_CONTRACT.md)を参照する。

以前の75%などの数値は、未登録のDLLを登録完了相当へ加点しており、現在の完成率として利用しない。
進捗は次の観測結果で管理する。

| 項目 | 確認状態 |
|---|---|
| x86/x64 TIP、変換サーバー、候補表示、Mozc broker | Windowsでビルド済み |
| Setup.exe / MSI | 未署名の**Mozc-only候補B1**を`.local/installer-beta-mozc`に生成済み（MSI 18,427,904 bytes / SHA-256 `1F040CE2…FA27363F`、AI payload 0件）。旧candidateのMSI実機installは終了値0。B1は未導入 |
| 本物のTSF登録・アプリ入力 | x64/x86 COM登録とJapanese profileを確認。operatorは旧candidateで文字入力・変換・かな切替成功を報告（partial）。候補・確定・取消・focus・restart・削除再導入は未検証 |
| AI接続単体テスト | 7件×100回成功。実モデルの証拠ではない |
| 同梱ローカルAIモデル | Qwen2.5-1.5B + llama.cpp pairingをA2実装候補として承認。llama.cpp runtime archiveとQwen weightは取得・hash検証、runtime 51-entry layoutと実model staging receiptも確認。KanaAI install/Windows実行、model quality、transitive notice/SBOMは未検証 |
| 公開ベータ | 未公開。**ユーザー決定D-1（2026-09-26）により公開範囲は「AI無効のMozcベータ」**（旧「AI同梱版のみ」は上書き）。署名はD-3により必須ではない。公開サイトはD-5により作らず、公表面はREADMEとRelease bodyのみ |
| 製品完成 | 未完了 |

この表は実行証拠の代用にならない。最新コマンド、失敗と次の作業はSTATE.mdに記録する。
