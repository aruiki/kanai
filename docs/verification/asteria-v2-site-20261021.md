# Asteria正式v2.0.0の公式サイト公開確認（2026-10-21）

[製品v2.0.0](https://github.com/aruiki/Asteria-Japanese-IME/releases/tag/v2.0.0)は2026-10-21T14:42:54Z公開、prerelease=false/Latest。利用者指定で未署名。MSI3.34.6442.100、1,662,754,816 bytes、SHA-256は1bc531b10b25cc46fbc60a8b7b052187f2b69c9065e8a1651acc23e89bd1b72a。[製品の対応ソース・導入・修正前後と配布物の記録](https://github.com/aruiki/Asteria-Japanese-IME/blob/main/docs/verification/release-v2.0.0-20261021.md)。

## 配備の固定

サイトPR10はmain46fb446902122e59202b489a67034350960089e2へ統合。site-assetsをpagesへ同期し、validate-pagesが成功。日英7ページの本文/配布URL/区分/JSON-LD、releases.jsと3画像を正式版へ変更した。旧評価CSV/画像、実録GIF/MP4、月アイコンと支援URLは保持した。

gh-pagesの既存21ファイル（.nojekyllを含む）だけを更新し、配備commit3f68e6c2696005c1c0ca5ebf9318d9c966aff576をpush。自動buildが始まらなかったためPages build APIで開始した。[run39620353670](https://github.com/aruiki/kanai/actions/runs/39620353670)はbuild/report/deployの全3job成功。Pages APIもstatus=built、commitが一致。

## 公開確認

配備commitのバイトから作成したmanifestと、公開20ファイルの新しいHTTP取得結果がすべて一致。全件HTTP200。改行を含め全バイトSHAで比較した。

公開7ページ（日本語トップ、download、design、privacy、status、faq、英語トップ）×1440px/390px、全14画面でv2.0.0表示、画像読込、横はみ出しなし、h1が1件、skip linkのTab focus、JavaScript例外なしを確認。全配置を画像で目視し、FAQの展開とstatusの履歴も保存した。

製品README/Release×1440px/390pxの全4画面でもHTTP200、正式版/未署名表示、実MSIリンク、全画像読込を確認した。製品PR181は全7CI成功後mainaeabb92189c59485b42bc4cfd6ba3b754c9a260aへ統合。Release本文は画像commit0dae1d19c047c18e3af9767f6a1421459903b61cの不変URLへ固定した。

原票は製品worktreeのtarget/accuracy-guide/v2-site-deploy-manifest-v1.json、v2-site-public-v1.json、v2-site-public-browser-v1/、v2-marketing-public-browser-v1/。記録統合前の総合監査55項目が成功した。

これは公開紹介の整合確認。導入済みGPU AI ON/OFF、Office等、低性能実機、保護欄内部、旧版更新、再起動、独立verifierの7未検証範囲を解決済みとはしない。過去の独立FAILを保持し、.goal-completeは作成していない。
