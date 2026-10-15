# Asteria サイト「月の余白」 — 2026-10-15

参照: 製品リポジトリの `docs/design/2026-10-asteria/generation.md` と `docs/adr/0056-asteria-brand.md`。2026-10-11に採用された「月の余白」を再確認。濃紺 #0d1624、生成り #eee7dc、墨と紙、筆の月、明朝、大きな文字と余白を使用。

## モックアップ

`mockup.png` は内蔵 image_gen によるデザイン案。初回の旧名KanaAIを訂正したAsteria案を保存した。製品UIの実画面・入力実績・実録画ではない。実装の見出し・文章・数値はHTMLで管理する。正式アイコンと月の画像は既存Asteria資産をコピーし、別製品名のアイコンは新作しない。

最終生成プロンプト（先行案への編集）:

Edit this landing page mockup. Preserve its overall midnight navy and warm ivory, crescent sumi brush texture, generous whitespace, Mincho typography, hero composition and highly legible text. Correct ALL product naming from KanaAI to Asteria, small Japanese name アステリア. This site at /kanai/ actually introduces Asteria Japanese IME (formerly Kotori); KanaAI is only the legacy URL, never the product branding. Replace hero headline with warm factual 「いつもの入力に、ローカルAIを。」. Supporting copy: 「Mozcをもとにした、Windows向けの日本語入力。変換も予測も、あなたのPCの中で。」. Main button 「Windows版をダウンロード」 secondary 「使い方を見る」. Small note 「Windows 10 / 11 · x64 · 未署名」. In cream section heading 「いつもの入力を、大切に。」 use three simple columns 「文脈に合う変換」「入力中の予測」「PCの中で動く」 with short factual Japanese copy, no personalized learning claim, no migration compatibility promises. Bottom navy heading 「公開版と、これからのこと。」 with links to release notes and verification, no unsupported quality or performance figures. Keep input candidate window caption 「入力画面のイメージ」. Do not add stars, gradients, glows or excessive pill/card UI. This is the final Asteria website concept, not KanaAI.

元の視覚参照: Asteria `docs/images/asteria-hero.png`。初回生成は1440px幅のサイト構成、右の月と候補表示、3列の機能、公開状況を指定。最終画像はデザイン検討用であり、サイト本体へ一枚画像として埋め込まない。

## 確認

- Asteria Latestはv1.1.3（2026-10-12）。GitHub Releases APIと固定版のMSI検証記録を照合。
- MSIは未署名、1,569,517,568 bytes、SHA-256 b7dbaee7e99dcea16544b169cadb7ea1e0c5b66f1225cbc01a044ad4293688d5。
- 2026-10-01のKotori beta.8実入力比較と、前の文あり変換器評価は別条件として保持。新たな品質測定は行っていない。
- Edge / Playwrightで7ページ×1440px・390pxを確認。横はみ出し・画像欠落・JS例外なし。`.local/site-refresh/browser-check.json`。
- `node scripts/sync-site.mjs`、`node scripts/validate-pages.mjs`、`git diff --check`。

## 実入力GIF・動画の残項目

[収録案と掲載手順](recording-plan.md)。Windows Computer Useは初回timeout、再接続でtrusted Node process exited unexpectedly、最終再試行もtimeout。実入力収録は未実施。生成UIや変換器の出力から実録画を作ったとは扱わない。
