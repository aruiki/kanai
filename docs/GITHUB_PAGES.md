# GitHub Pages 紹介サイトの運用（2026-10-15）

紹介対象は **Asteria — アステリア**。公開URLは既存の https://aruiki.github.io/kanai/ を維持する。
製品リポジトリ: https://github.com/aruiki/Asteria-Japanese-IME 。旧Kotoriの後継で、旧KanaAI betaとは別の製品系統。

- 正本: `site-assets/`。`node scripts/sync-site.mjs` で `pages/` へ同期する。
- 検証: `node scripts/validate-pages.mjs`、`git diff --check`、PC/390pxで全7ページの表示。
- 公開先: `aruiki/kanai` の `gh-pages` ブランチ。配備後にPages build、HTTP200、正本とのバイト一致を確認する。
- 配備対象: index.html / design.html / privacy.html / download.html / status.html / faq.html / en/index.html / landing.css / releases.js / asteria-icon.png / asteria-hero.png / og-card.png / og-card-en.png / ime-comparison.png / ime-comparison.csv / sitemap.xml / typing-demo.mp4 / typing-demo-poster.png / .nojekyll。
- `site.css` / `site.js` / `kanai-mark.svg` / `kotori-mark.svg` は過去の資産。新規ページの配備には含めない。

## 現在の確認済み内容

2026-10-15にGitHub Releases API、Asteria README、固定版v1.1.3の検証記録を確認。公開版はv1.1.3（2026-10-12）、Asteria64.msi、未署名。サイズ・SHA・実機確認範囲はdownload.html / status.htmlと固定版の検証記録へ。

2026-10-01の実入力比較はKotori beta.8 / Unreal / 前の文なし。Standard 91.5%等の変換器評価とは別の条件。過去の測定版・数値・出典・CSVは保持し、現行版の新規測定値としない。

ブランドはAsteriaで採用された「月の余白」。正式アイコン、濃紺・生成り、明朝、紙と墨を使用。制作プロンプトとモックアップは `docs/design/2026-10-asteria-site/`。

`releases.js` は公開APIから版ラベルと最新リンクのみ更新する。本文の評価・署名・機能・構造化データは自動更新しない。新しい版の公開後は本文・JSON-LD・SHA・OG・sitemap・validatorのreleaseVersionを一次資料に合わせて更新する。

実入力GIF・動画は収録済み。READMEはGIF、日本語・英語サイトは操作できるMP4で掲載。収録条件と原票は `docs/design/2026-10-asteria-site/recording-plan.md`。

Search Consoleの所有権確認・サイトマップ送信は所有者アカウントでの作業。canonicalやサイトマップの公開は検索掲載・順位を保証しない。
