# 変換精度を中心にした公式サイトの紹介（2026-10-22）

利用者の指摘に従い、紹介の主見出しを「変換精度の高い日本語IME」へ変更した。GPU・AI・文脈は仕組みとして説明し、実装手段をそのまま価値の見出しへ使わない。

## 変更と固定した範囲

main db61204から専用枝codex/quality-copy-20261022で作業。日英7ページの主見出し、説明、OG/JSON-LD、共通footer、3画像を更新し、pages鏡像へ同期した。紹介画像は製品commit ab1fad2aad39325e481488ea2ccf7aadb844d3f5の原稿/PNGに対応し、月の既存意匠を保持した。

公開中のv2.0.0、配布URL、MSI3.34.6442.100のSHA、動作環境、評価条件、未検証範囲は変えていない。短文の辞書補強は開発中であり、未採用候補の語数・評価結果を公開版の新機能へ加えていない。前文あり94%を単語・短文・実アプリの一般精度へ読み替えない。

旧比較CSV/画像、実入力GIF/MP4/ポスター、月アイコン、releases.jsは変更前後の全バイトSHAが一致。支援URLと履歴を保持した。

## ローカル確認

- `node scripts/sync-site.mjs`: 24ファイル同期、削除0。
- `node scripts/validate-pages.mjs`: 14 HTML（鏡像込み）、参照/画像/版/構造化情報の検査成功。
- Edge headlessで全7ページ×1440px/390pxの14配置を検査。横はみ出しなし、画像破損なし、h1が1件、skip linkのTab focus、例外なし、版と新コピー、旧見出しの不在が全件成功。
- 日英トップ×PC/390pxの4配置と、製品紹介画像3種を目視。原稿の範囲内に収まり、月と文字の重なりなし。

原票は製品worktreeのtarget/accuracy-guide/quality-site-draft-v1.json、quality-site-qa-v1/、quality-marketing-render-v1.json。これは紹介の整合確認であり、本体の精度改善・実アプリの受入れ・製品完成の証拠ではない。

## 公開確認

[PR12](https://github.com/aruiki/kanai/pull/12)をmain387018abd57cd011bbdab52624d9999111abafe1へ統合。サイトmainにはPR用Actions workflowがないことをGitの.githubツリーとチェック一覧から確認し、ローカル検証を適用した。

gh-pagesへ33a823f9e40995567d2d999058f8a736aaa9150bを配備し、[Pages run39693693438](https://github.com/aruiki/kanai/actions/runs/39693693438)のbuild/deploy/report全3job成功、Pages API built/同commitを確認した。

公開20ファイルを新規取得して全HTTP200/配備commitの全バイトSHA一致。公式7ページ×PC/390pxの14配置で、版/新コピー、画像、横はみ出し、h1、skip link、例外の全検査が成功。原票quality-site-deploy-manifest-v1.json、quality-site-public-v1.json、quality-site-public-browser-v1/を保存した。

最初の配備前検査は、Windows checkoutのCRLFをそのまま写した差で停止し、pushしていない。全21ファイルが期待したコピーと一致し、保存blobとの差は改行だけと確認してquality-site-deploy-line-endings-v1.jsonへ記録。Gitの保存blobを取り出す方法へ修正して配備した。SHA検査は緩めていない。

公式サイトの紹介方針変更と公開確認は完了。製品本体の辞書/順位改善、実アプリ検証、製品全体の未検証7範囲、過去の独立FAILは別であり、完了扱いにしない。
