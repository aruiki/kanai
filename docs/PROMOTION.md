# KanaAI の公開・検索導線（2026-10-07）

## 公開する説明

KanaAIはMozcを基盤にしたオープンソースのWindows日本語IMEです。
ローカルAI同梱のbeta.2を公開しています。ただしAIが起動しても変換結果は変わらず、
品質向上を実証した版ではありません。未署名・未完成の試用ベータとして案内します。

紹介ページ: https://aruiki.github.io/kanai/
リリース: https://github.com/aruiki/kanai/releases/tag/v0.1.0-beta.2

## 今回の施策

- 日本語のtitle、description、見出しと本文で「Windows日本語IME」「Mozc」「ローカルAI」を説明。
- canonical、OGP、Twitter summary、SoftwareApplication JSON-LD、sitemap.xmlを用意。
- FAQ、導入・削除手順、対応環境、ライセンス、制限、Issue報告へのリンクを掲載。
- READMEとGitHub Aboutから紹介ページへリンク。
- JavaScriptなしでも本文・導線・FAQを利用可能。外部フォント、解析タグなし。
- 既存の古い「インストーラー未公開」説明を公開beta.2の記録に合わせて訂正。
- 多ページ構成へ拡張: 設計と技術、プライバシー、ダウンロード・導入、検証状況、FAQ（FAQPage JSON-LD、14件）と英語ホーム `/en/` を追加。sitemap.xmlは7URL、各ページにcanonical・OGP・hreflang・BreadcrumbList、ページ間ナビゲーションとフッター導線を追加。

## 継続運用

1. Google Search ConsoleにURLプレフィックス `https://aruiki.github.io/kanai/` を登録。
   所有者のGoogleアカウントでログインし、HTMLファイルまたはmetaタグで所有権を確認。
   Googleから発行された検証ファイル／タグが必要。今回のコード変更だけでは登録済みとはならない。
2. 所有権確認後 `https://aruiki.github.io/kanai/sitemap.xml` を送信。
   URL検査でトップページの登録状態を確認し、必要ならインデックス登録をリクエスト。
3. Bing Webmaster Toolsも所有権を確認してサイトマップを送信。
4. 2〜4週間後、表示回数・クリック数・検索語・登録状況を確認。
   最初に記録した値と比較し、検索順位や流入増を計測前に主張しない。
5. AIの候補差分と品質改善を実証した版が公開されたら、検証環境と具体例を添えて
   Zenn/Qiitaの開発記事とSNS告知を行う。現時点では開発・検証への参加募集として紹介する。
   個別DM、メーリングリスト投稿、大量投稿は今回実施していない。

GitHub Pagesのプロジェクトサイトであるため `/kanai/robots.txt` はホスト全体の
robots.txtとして機能しない。効果のないファイルや架空の所有権確認タグは追加しない。
サイトマップ送信はインデックス登録・上位表示を保証しない。

## 告知文の下書き（未投稿）

> Mozcを基盤にしたWindows日本語IME「KanaAI」を開発しています。
> PC内で動くAIを同梱した試用ベータを公開中です。
> 現在はAIの起動を確認した段階で、変換品質の改善はこれから。
> 未署名・未完成ですが、実装や検証に関心のある方の参加を歓迎します。
> https://aruiki.github.io/kanai/

## 更新・検証・配備

`site-assets/` が紹介ページの正本。多ページ構成の一覧・canonical・検証項目は `docs/GITHUB_PAGES.md` にある。
`node scripts/sync-site.mjs` で `pages/` のプレビューミラーを `site-assets/` から複製する。
`node scripts/validate-pages.mjs` と `git diff --check` を実行する。
配備対象は以下のみ。ソースツリーや開発用.envは配備しない。

- site-assets/index.html → gh-pages:/index.html
- site-assets/design.html → gh-pages:/design.html
- site-assets/privacy.html → gh-pages:/privacy.html
- site-assets/download.html → gh-pages:/download.html
- site-assets/status.html → gh-pages:/status.html
- site-assets/faq.html → gh-pages:/faq.html
- site-assets/en/index.html → gh-pages:/en/index.html
- site-assets/landing.css → gh-pages:/landing.css
- site-assets/kanai-mark.svg → gh-pages:/kanai-mark.svg
- site-assets/og-card.png → gh-pages:/og-card.png
- site-assets/og-card-en.png → gh-pages:/og-card-en.png
- site-assets/sitemap.xml → gh-pages:/sitemap.xml
- site-assets/.nojekyll → gh-pages:/.nojekyll

`site-assets/site.css` と `site-assets/site.js` は旧ドラフトの残骸で現在のページから参照されておらず、配備対象ではない。

GitHub Pagesは既存の `gh-pages` ブランチを使用。
公開後にPages buildのcommit・statusとトップページ/CSS/サイトマップのHTTP応答を確認する。
新リリース時は本文・JSON-LD・README・検証スクリプトの版番号と制限を一緒に更新する。

参考:
- https://developers.google.com/search/docs/appearance/title-link
- https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap
