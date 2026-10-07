# GitHub Pages 紹介サイトの運用（2026-10-07）

現在の紹介対象は **Kotori日本語入力**。
公開URL: https://aruiki.github.io/kanai/
現行製品リポジトリ: https://github.com/aruiki/KotoriIME-japanese-

ユーザーが指定した現行リポジトリを基準に全ページを更新。
URLは既存の公開先を維持する。旧KanaAIのbeta.2の結果は現行製品の説明へ流用しない。
製品コードや検証記録の書き換えは行わない。

## ページ構成

- index.html: Kotori日本語入力の特徴、変換例、条件付きの評価値。
- design.html: Mozc / zenz / TinySwallow、AI予測、GPU・CPU、品質モード。
- privacy.html: ローカル処理、設定・学習の保存先、診断情報、削除後のデータ。
- download.html: 製品版/RC、Kotori64.msi、必要な環境、版別SHA-256、導入・更新・削除。
- status.html: v1.0.0 / v1.1.0-rc.1、評価の根拠、署名・長時間試験・実機確認の残項目。
- faq.html: 12問。表示内容と一致するFAQPage JSON-LD。
- en/index.html: English overview。製品版とRC、条件付きの評価値。

## 正本と更新

site-assets/が正本。pages/は同一構造のミラー。

```
node scripts/sync-site.mjs
node scripts/validate-pages.mjs
git diff --check
```

validatorはリンク/アンカー/ローカル資産、canonical一意性、言語と文字種、OG/Twitter、
JSON-LD型、現行製品名・版・署名の記載を確認する。
旧beta.2の版・「変換結果は変わりません」・旧GitHubの製品リンク等をエラーにする。
これらは現在の公開版の状態に合わせた紹介内容の検査で、IMEの製品テストを代替しない。

## 新しい版が公開されたら

1. 現行リポジトリのREADME・リリースノート・HANDOFF・利用ガイド・評価記録を読む。
2. 製品版とRCを分けて記載。配布リンクは /releases/latest を基本とする。
3. モデル、環境、サイズ、署名、削除後のデータ、精度の条件を確認して本文とJSON-LDを更新。
4. scripts/og-card-text.jsonを更新し、make-og-card.ps1でOG画像を生成して視認する。
5. validatorのreleaseVersionと必要な記載を現行製品に合わせる。
6. sync・validator・diff確認、PC/390px幅の表示確認後に配備。

releases.jsは製品版のラベルとフッターリンクのみ公開APIから更新する。
本文の評価・機能・署名は確認時点の事実であり、自動更新しない。
OG画像はscripts/make-og-card.ps1による再現可能な生成物。

## 配備ファイル（16件）

index.html / design.html / privacy.html / download.html / status.html / faq.html /
en/index.html / landing.css / releases.js / kotori-mark.svg / og-card.png /
og-card-en.png / ime-comparison.png / ime-comparison.csv / sitemap.xml / .nojekyll

site-assets/site.css・site.js・kanai-mark.svgは旧ドラフトの資産で、配備対象に含めない。
ソースツリー、.env、開発用設定は配備しない。

既存aruiki/kanaiのgh-pagesを使用。push後にPages buildが対象commitでbuiltになることを確認。
全16ファイルでHTTP 200かつ公開バイトと正本の一致を確認する。
公開トップの見出しと現行リポジトリへのリンクもブラウザーで確認する。

## 検索登録

canonical・サイトマップの公開だけで検索への登録や順位は保証されない。
Search Consoleは所有者アカウントでの確認・サイトマップ送信が残っている。
詳しい周知・計測手順と未投稿の告知文はPROMOTION.md。

## 3製品の比較

トップとstatus.htmlはeval/imebench/README.mdの2026-10-01の実入力結果を掲載。
Kotori beta.8 / Unreal、前の文なし。前の文あり91.5%と混ぜない。全5セットを掲載。
図は現行Kotoriのdocs/images/gen_ime_comparison.pyで再生成できる。新規計測ではない。

AJIMEE例は固定commit401666cの原データから3問。fetch.shと同じSHA-256を照合。
出典とCC BY-SA 3.0を表の直下へ表示。CSVは既存集計値の転記、問ごとの出力ではない。

## 紹介文の語調

メンテナの2026-10-07の希望: オープンソースの優しいソフトとして紹介する。
決め台詞や競争を煽る見出しは避け、機能・使い方・測定結果を具体的に記載する。
配布区分は公開版・リリース候補と呼ぶ。
