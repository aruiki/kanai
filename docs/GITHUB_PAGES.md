# GitHub Pages 公開サイト — 運用手順（2026-10-07 改訂）

> **現在の状態: 公開済み。** <https://aruiki.github.io/kanai/> が
> `gh-pages` ブランチから配信されています（2026-10-07 にHTTP応答を確認）。
> 2026-09-26 の「製品サイトを公開しない」という決定は、その後のユーザー指示で
> **置き換えられました**。この文書は古い決定を前提に編集しないでください。

`site-assets/` が**公開ページの正本**です。`pages/` はリポジトリ内のプレビュー用ミラーで、
`node scripts/sync-site.mjs` が `site-assets/` の全ファイルをそのまま複製します。
どちらを編集する場合も、正本は `site-assets/` です。

## ページ構成

| パス | canonical | 言語 | 内容 |
| --- | --- | --- | --- |
| `/` | `https://aruiki.github.io/kanai/` | ja | ホーム。特徴、導入、FAQ、各ページへの導線 |
| `/design.html` | `.../design.html` | ja | 設計と技術。Mozcとの分担、Fast/Slow Path、AI役割の実測と棄却、モデルの階段 |
| `/privacy.html` | `.../privacy.html` | ja | プライバシー。データフロー、AIペイロード、保護フィールド、削除、脅威モデル |
| `/download.html` | `.../download.html` | ja | ダウンロード・導入。SHA-256、動作環境、導入手順、AIのON/OFF、削除 |
| `/status.html` | `.../status.html` | ja | 検証状況。receiptのある項目、未検証の項目、成果物の固定情報、残作業 |
| `/faq.html` | `.../faq.html` | ja | よくある質問（14件、FAQPage JSON-LD） |
| `/en/` | `https://aruiki.github.io/kanai/en/` | en | English overview。詳細ページは日本語のみである旨を明記 |

補助ファイル: `landing.css`、`kanai-mark.svg`、`og-card.png`、`og-card-en.png`、
`sitemap.xml`、`.nojekyll`。

`site-assets/site.css` と `site-assets/site.js` は旧ドラフトの残骸で、
現在のページからは参照されていません。配備対象に含めないでください。

## 更新と検証（コミット前）

```sh
node scripts/sync-site.mjs      # site-assets/ -> pages/ ミラー
node scripts/validate-pages.mjs # リンク・canonical・OGP・JSON-LD・文字種を検査
git diff --check                # 末尾空白・衝突マーカー
```

`validate-pages.mjs` が検査する内容:

- 本地リンク・アンカー・資産の実在（`pages/` と `site-assets/` の両ツリー）
- 外部依存（外部CSS/JS/フォント、`<script src>`、インラインイベント）の禁止
- `lang` と文字種（日本語ページに紛れ込んだ他言語の文字を、誤字ではなく破損として検出）
- title / description の長さ、canonical の一意性（公開ツリー単位）
- OG / Twitter / hreflang（`x-default` 必須）
- JSON-LD の型: ホームは `SoftwareApplication`、内部ページは `BreadcrumbList`、FAQは `FAQPage`
- ページ種別ごとの必須記載（`Mozc`、`Windows`、`v0.1.0-beta.2`、`未署名`／`unsigned`、
  `未完成`／`not a completed product`、ホームは `変換結果は変わりません`、`約1.1 GB` など）

**検査を通していないページを配備しない。** 警告も理由なく放置しない。

## ローカルプレビュー

```sh
python -m http.server 8088 --directory site-assets
```

<http://127.0.0.1:8088/> と <http://127.0.0.1:8088/en/> を開き、
ナビゲーション・表・コードブロック・フッターの導線を確認する。
`file://` では相対ディレクトリリンク（`en/`）の挙動が配信時と異なるため、HTTPで確認する。

## 配備

対象は `site-assets/` の以下を `gh-pages` ブランチのルートへ写したものです。
ソースツリーや開発用 `.env` は配備しません。

```
index.html  design.html  privacy.html  download.html  status.html  faq.html
en/index.html
landing.css  kanai-mark.svg  og-card.png  og-card-en.png
sitemap.xml  .nojekyll
```

手順:

1. `node scripts/sync-site.mjs` と `node scripts/validate-pages.mjs` を通す。
2. `gh-pages` ブランチへ上記ファイルを配置してcommit・pushする。
3. GitHub の Pages build の commit と status を確認する。
4. 公開URLのHTTP応答を確認する（`/`、`/en/`、各内部ページ、`/landing.css`、
   `/og-card.png`、`/sitemap.xml`）。
5. ページを削除・改名した場合は `sitemap.xml` とcanonical、hreflangを同時に更新する。

GitHub Pagesのプロジェクトサイトであるため `/kanai/robots.txt` はホスト全体の
robots.txtとして機能しません。効果のないファイルや架空の所有権確認タグは追加しません。

## OGカード

`scripts/make-og-card.ps1` が `scripts/og-card-text.json` の文言から
`og-card.png` / `og-card-en.png` を生成します。

- **PNG（ラスター）であること。** SVGはSNSクローラが描画しないため使用しない。
- 1200×630。`og:image:width` / `og:image:height` / `og:image:alt` を各ページに置く。
- 日本語の文言は **UTF-8 の JSON 側**に置く。PowerShell 5.1 は BOM なし UTF-8 の
  `.ps1` を ANSI として読むため、`.ps1` は ASCII のみにする。
- 文言を変えたら両カードを再生成し、`validate-pages.mjs` を通す。

## 公開文の規約（引き続き有効）

- 未署名であることを明記し、SmartScreen / Smart App Control / ウイルス対策 /
  企業ポリシーの**無効化を利用手順にしない**。
- 配布ファイルの**SHA-256**、対応ソースコミット、適用ライセンス、既知の制限を掲載する。
- **検証済みと未検証を分けて書く。** インストーラのテスト結果は実際に起きたとおり書き、
  失敗した項目を省略しない。
- beta.2 は**AIのモデルとruntimeを同梱**している（beta.1の「AI非搭載」記述は古い）。
  ただし実測で**変換結果は変わらない**ため、変換品質の改善を主張しない。
- ベータの公開は GOAL 完成ではなく、`.goal-complete` を作らない。
- 公開テキストにAPIキー、ローカルプロファイル、ユーザーの入力文を含めない。
- 新リリース時は本文・JSON-LD・`softwareVersion`・README・検証スクリプトの
  版番号と制限を一緒に更新する。

## 検索導線の継続運用

`docs/PROMOTION.md` を参照。Search Console / Bing Webmaster Tools の所有権確認と
サイトマップ送信は**Googleが発行する検証ファイルまたはタグが必要**で、
このリポジトリの変更だけでは登録済みになりません。
サイトマップ送信はインデックス登録や上位表示を保証しません。
