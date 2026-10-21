# 2026-10-21の紹介刷新

GPUで考える日本語入力を軸に全7ページとOG画像を更新。紹介先は未署名のv1.1.4-rc.4（リリース候補）を明示URLで固定する。GitHub LatestはRC2を指すため使用せず、実行時の版ラベル更新も停止した。正式版や2.0への区分変更ではない。

正本site-assets/とpages/を同期し、既存validatorのreleaseVersionを1.1.4-rc.4へ更新。14 HTML・264ローカル参照・16アンカーが解決。外部178リンクは構文確認。Edgeで7ページ×1440/390pxの14条件を検査し、画像欠落・横はみ出し・例外0、h1各1、スキップリンクのキーボード到達を確認。スマートフォンでの不自然な見出し改行を修正した。FAQと過去評価の開閉も撮影した。

現行94.0%は条件付きのオフライン評価。旧比較・CSV・ライセンス出典は過去記録へ保持した。MSI SHAは2b37f6fbdcb069251e820e2009b096111cc2253e79ffac65d973fa11ce18e301、サイズ1,662,828,544 bytes。アプリ・モデル・本体ビルド入力は変更しない。

公開結果: [PR8](https://github.com/aruiki/kanai/pull/8)をmain05befd9a4900cc1680b48333e114125e5f4eefa5へ統合。gh-pages6afbd5a2487a8c660e6c26a280d1aa7bdca55d97、[Pages run39535159315](https://github.com/aruiki/kanai/actions/runs/39535159315)がsuccess、Pages buildも同commitでbuilt。全20配備ファイルを公開URLから実取得し、HTTP200・配備元SHA-256と全一致を確認した。

公開サイトも7ページ×1440/390pxの14条件で、画像欠落・横はみ出し・ページ例外0、h1各1、RC4表示、スキップリンクのキーボード到達を確認。公開トップをPC・スマートフォン幅で目視した。[製品リポジトリの公開検証記録](https://github.com/aruiki/Asteria-Japanese-IME/blob/main/docs/verification/marketing-refresh-20261021.md)に原票SHAを保存。これはサイトの確認であり、実アプリの製品検証を代替しない。

---

以下は2026-10-15時点の履歴。v1.1.3の版情報・ハッシュ・版ラベルの動的更新は当時の記録であり、現在の案内ではない。

# GitHub Pages 紹介サイトの運用（2026-10-15）

紹介対象は **Asteria — アステリア**。公開URLは既存の https://aruiki.github.io/kanai/ を維持する。
製品リポジトリ: https://github.com/aruiki/Asteria-Japanese-IME 。旧Kotoriの後継で、旧KanaAI betaとは別の製品系統。

- 正本: `site-assets/`。`node scripts/sync-site.mjs` で `pages/` へ同期する。
- 検証: `node scripts/validate-pages.mjs`、`git diff --check`、PC/390pxで全7ページの表示。
- 公開先: `aruiki/kanai` の `gh-pages` ブランチ。配備後にPages build、HTTP200、正本とのバイト一致を確認する。
- 配備対象: index.html / design.html / privacy.html / download.html / status.html / faq.html / en/index.html / landing.css / releases.js / asteria-icon.png / asteria-hero.png / og-card.png / og-card-en.png / ime-comparison.png / ime-comparison.csv / sitemap.xml / typing-demo.gif / typing-demo.mp4 / typing-demo-poster.png / .nojekyll。
- `site.css` / `site.js` / `kanai-mark.svg` / `kotori-mark.svg` は過去の資産。新規ページの配備には含めない。

## 現在の確認済み内容

2026-10-15にGitHub Releases API、Asteria README、固定版v1.1.3の検証記録を確認。公開版はv1.1.3（2026-10-12）、Asteria64.msi、未署名。サイズ・SHA・実機確認範囲はdownload.html / status.htmlと固定版の検証記録へ。

2026-10-01の実入力比較はKotori beta.8 / Unreal / 前の文なし。Standard 91.5%等の変換器評価とは別の条件。過去の測定版・数値・出典・CSVは保持し、現行版の新規測定値としない。

ブランドはAsteriaで採用された「月の余白」。正式アイコン、濃紺・生成り、明朝、紙と墨を使用。制作プロンプトとモックアップは `docs/design/2026-10-asteria-site/`。

`releases.js` は公開APIから版ラベルと最新リンクのみ更新する。本文の評価・署名・機能・構造化データは自動更新しない。新しい版の公開後は本文・JSON-LD・SHA・OG・sitemap・validatorのreleaseVersionを一次資料に合わせて更新する。

実入力GIF・動画は収録済み。READMEと日本語・英語サイトは、変換画面だけを大きく切り出した自動ループGIFで掲載。収録条件と原票は `docs/design/2026-10-asteria-site/recording-plan.md`。

Search Consoleの所有権確認・サイトマップ送信は所有者アカウントでの作業。canonicalやサイトマップの公開は検索掲載・順位を保証しない。
