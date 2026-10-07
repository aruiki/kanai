# Kotori日本語入力の紹介・検索導線（2026-10-07）

## 現在の紹介対象

現行製品: Kotori日本語入力
リポジトリ: https://github.com/aruiki/KotoriIME-japanese-
紹介サイト: https://aruiki.github.io/kanai/

URLは既存のものを維持し、本文・全7ページ・OG画像・JSON-LD・配布導線をKotoriへ更新する。
旧KanaAI beta.2の状態と現行Kotoriの製品情報を混ぜない。旧リポジトリのREADMEは履歴と明記。
公開情報の基準はv1.0.0（Latest / 製品版）とv1.1.0-rc.1（リリース候補）。両版とも未署名。

## 本文の根拠

2026-10-07に確認した現行main: 642bd515f7a057902eb80abeab7b74fe84173843。
README、docs/HANDOFF.md、docs/USER_GUIDE.md、eval/README.mdと公開リリースノートを参照。

- モデル: zenz-v2.5 small / medium、TinySwallow-1.5B。実行環境はllama.cpp / ggml。
- AIは文脈に応じて候補を選び直し、入力中の文の続きを予測する。
- Standard: AJIMEE-Bench 200問で91.5%、最終評価用300問で96.3%。前の文あり、RTX 3060。
  プロジェクトの公開測定値であり、サイト更新で再測定したものではない。
- 専用GPU・Vulkan・VRAM 3 GB以上。GPUなしはCPU向けLow。内蔵GPUは使わない。
- Windows 10 1809以降 / Windows 11 x64、メモリ8 GB、ディスク1.7 GB。
- MSIにモデルと実行環境を同梱。ユーザーデータはアンインストール後も残る。
- 署名、長時間試験、実機確認等の残項目も現行HANDOFFに基づいて記載。
- v1.1のアイドル時の候補表示はRCの機能。製品版v1.0.0の機能として紹介しない。

## 古くしないための導線

製品版のダウンロードリンクは現行リポジトリの /releases/latest へ進む。
releases.jsがGitHubの公開APIから最新stable版のラベルだけを取得する。
APIが失敗しても静的本文と /releases/latest リンクは使える。
評価・機能・署名の記載は確認日を添え、次の版が出たらリリースノートを読み直して更新する。
自動で新しい版へ過去の精度・署名状態を流用しない。

## 告知文の下書き（未投稿）

> Windows向け日本語IME「Kotori日本語入力」を公開しています。
> Mozcの操作と辞書を土台に、PC内のAIが文脈に合う候補を選び直し、文の続きを予測します。
> モデルと実行環境を同梱したMSIで導入でき、GPUなしのPCでも利用できます。
> 製品版v1.0.0と、手を止めたときの候補表示を加えたv1.1リリース候補を公開中。
> 対応環境・導入方法: https://aruiki.github.io/kanai/
> ※上記2版は未署名です。詳しい条件と評価記録は紹介サイトから確認できます。

## 検索登録と効果測定の残作業

Google Search ConsoleでURLプレフィックス https://aruiki.github.io/kanai/ の所有権を確認し、
https://aruiki.github.io/kanai/sitemap.xml を送信する。所有者アカウントでのログインと検証タグ/ファイルが必要。
Bing Webmaster Toolsでも所有権確認後に送信する。登録済み・順位上昇とはまだ報告しない。
2〜4週間後に表示回数、クリック数、検索語、登録状態を比較する。
個別DM、SNS投稿、コミュニティ投稿は今回実施していない。

## 配備

site-assets/が正本。node scripts/sync-site.mjsでpages/へ同期し、
node scripts/validate-pages.mjsとgit diff --checkを実施する。
配備対象はdocs/GITHUB_PAGES.mdの14ファイル。既存gh-pagesへ配備し、
Pages buildのcommit/statusと公開ファイルのバイト一致を確認する。
