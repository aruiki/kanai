# OpenCode移行ガイド

確認日: 2026-09-25（公開範囲・候補ハッシュは2026-09-26のD-1/D-3/D-5決定と候補B1へ更新）。実機のOpenCode v2.0.16で設定読込を確認。
`opencode models` に `opencode/space-bunny-free` が存在する。
モデルの実推論、多数の子の同時実行、サービス側の無制限枠は未検証。

## 開始

このリポジトリのPowerShellで実行する。

```powershell
powershell -NoProfile -File .\scripts\start-opencode.ps1 -CheckOnly
powershell -NoProfile -File .\scripts\start-opencode.ps1
```

最初のコマンドはモデル一覧・設定・6役の読み込みだけを確認し、推論を開始しない。
通常起動はモデルと初期設定を確認して開始し、debug agentsのJSON解析を実行しない。
対話ターミナルではdebug出力がJSONとして解析できないケースを観測したため、
詳細検査は非対話のPowerShellでも実施した。
2番目は開始プロンプト付きの新規セッションを専用サーバーで起動する。
既存セッションは古い担当/modelを保持するため、移行時はcontinueを使わない。
Space Bunny Freeが見つからなければ停止し、有料モデルへ自動変更しない。
既に開いているOpenCodeがある場合は編集を止めてから開始する。

| 役割 | 作業 |
|---|---|
| coordinator | 初期選択。分割・担当管理・統合・STATE更新・検証後の公開 |
| implementer | 指定ファイルの実装・対象テスト。複数起動時は別の担当範囲 |
| researcher | 読み取り専用のコード・公式資料調査 |
| reviewer | 読み取り専用の独立レビュー |
| tester | 固定状態のテスト実行。ソース修正禁止 |
| verifier | ベータ条件またはGOAL全条件の独立判定。過去の検証履歴を保持 |

子の再委任を禁止し、統括へ集約した。設定はOpenCode V2形式。
仕様参照: [公式Agents文書](https://opencode.ai/v2/docs/agents)。
具体的な運用と返却書式は [並列開発規約](PARALLEL_DEVELOPMENT.md)、
最初の担当候補は [作業キュー](WORK_QUEUE.md)。

## 既存成果物と実機状態

- 基準HEAD: `2e0630c`。多数の未コミット変更がある。git diffと未追跡ファイルを必ず確認。
- Mozc: `13c98988247aa711d99db9e348ec2a597d14b5cd`。patch 0001～0006をstageへ適用。
- Windowsのserver、x86/x64 TIP、renderer、Mozc broker、custom_actionをビルド済み。
- 現行候補は `.local/installer-beta-mozc/KanaAI-0.1.0-Setup.exe` と `KanaAI-0.1.0-x64.msi`
  （**Mozc-only候補B1**、AI payload 0件、未署名）。旧 `.local/installer/` は空。
- **KanaAI Development Preview 0.1.0はこのPCへ導入済みのまま**。
  最新MSIのinstall終了値0、x64 COM登録先を確認。
  `C:\Program Files (x86)\KanaAI` に配置される。
  ProductCode: `{307FE767-2B88-4915-8337-6E35423976B7}`。
  再ビルドするとProductCodeが変わり得るため、削除前は現在の登録を照合する。
- 実機を変更したログは `.local/installer/install-test.log`。
  アンインストール・再導入・rollback・Setup.exeの操作試験は未完了。
- 手動COM activation probeはDLL/class factory生成まで成功、
  Activate/AdviseKeyEventSinkが `0x80070057`。
  Microsoft対照でも同様の失敗があり、probe側の使い方と製品側を切り分ける。
  Windowsアプリでの実入力成功・失敗をまだ判定していない。
- モデルは同梱されていない。Mozc broker exeとRustのkanai-brokerは別物。
- GitHubベータは未公開。製品完成ではない。VERIFICATIONの過去FAILは改変しない。

## ビルドの再利用

キャッシュは `$env:LOCALAPPDATA\KanaAI\tsf-build-cache`。
stageはその下の `KanaAI-tsf-stage-13c98988247aa711d99db9e348ec2a597d14b5cd\src`。
VS2022 Community v143、SDK10.0.26100、Python3.13、Bazelisk9.0.2で実行した。
既存stageやキャッシュを子ごとに破棄しない。patch変更時はprepare手順で反映する。
ビルド環境とfingerprintは `platform/windows-tsf/build/TsfBuild.Common.ps1` にある。

```powershell
# 重い処理の例。nativeコマンドの失敗は明示的に伝播させる。
& .\scripts\with-development-lock.ps1 -Name build -Action {
    & .\scripts\stage-tsf-runtime.ps1
    & .\scripts\build-windows-installer.ps1 -RuntimeDirectory .local/tsf-runtime -InstallerHelper .local/tsf-installer-helper/mozc_installer_helper.dll
}
```

上の処理は現在のビルド出力を再梱包するだけで、ソース変更を再ビルドしない。
各スクリプトのパラメータと出力を確認すること。
ソース・成果物・ハッシュが揃わない状態を公開検証へ渡さない。

## 直近の検証

- Windows TSF build harness: static 38、path 9、fingerprint 7 checks成功。
- pinned host検査成功。Windows AI接続unit test 7件×100回成功（実モデル検証ではない）。
- runtime stage、WiX5.0.2 MSI/Setup作成成功。
- MSI実機install終了値0。**W1 receipt** (`.local/validation/w1/W1-RESULTS.json`) は登録/profile/file/GUI readをPASSとしたが、共有desktopへのSendInput key/mouse deliveryが全滅し、実アプリのかな・変換・候補・確定・取消・focus・restartはNOT OBSERVED。KanaAI DLLはNotepadへロードされていない。別途operatorは旧candidateで文字入力・変換・かな切替成功を報告（`.local/validation/w1/manual-user-report.json`、partial user statement）。W1の自動入力失敗を製品失敗とは扱わない。
- installer build scriptはruntime/patch/source identity、Setup埋込みMSI hash、MSI product identity、署名状態をmanifestへ記録する。`-RequireCleanSource`はdirty treeを拒否する。dirty treeで作成した一時成果物は公開候補ではない。
- Mozc-only候補B1を`.local/installer-beta-mozc`に生成済み（2026-09-26 12:33、coordinatorが実測）。MSI 18,427,904 bytes / SHA-256 `1F040CE215C5EEEBCBD500F8C95ED43BE34EE55248DDF4999256C714FA27363F`、Setup 18,433,024 bytes / SHA-256 `260BADEA04F71D11D8B52B5782FDB78FCF5DB632486BA4BD22F0AFA6E5124135`、build-manifest SHA-256 `53EC2D05B4D43F0614782DE0FF4D3D03BC16B19C32F53712AF47F28F94B56C84`、ProductCode `{C64F7C8B-BF74-459F-A593-22CA2656EA09}`、UpgradeCode `{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}`。manifestは`verified=false`/`sourceTreeDirty=true`/`signing=NotSigned`を正直に記録する。実機は旧ProductCode `{307FE767-2B88-4915-8337-6E35423976B7}`（`C:\Program Files (x86)\KanaAI`）のまま。B1はx64ビルドのため`C:\Program Files\KanaAI`へ入り、**別ディレクトリ間の移行は未検証**（W2で実測する）。
- **ユーザー公開範囲はD-1（2026-09-26）により「AI無効のMozcベータ」**。旧記録の「AI同梱版のみ」は上書きされた。GOALのlocal AI要件は削除されておらず、A2で実model/runtime・license/digest・package・fallback/qualityの実装・検証を継続する。**modelを同梱済み・AI動作済みと記載するのはA2の実測後だけ。**
- OpenCode開始前検査: v2.0.16 / Space Bunny Free / 6 agents成功。redirectされたdebug agentsのUTF-16LE BOMをraw bytesでdecodeする修正もCheckOnlyでexit 0。
- 開発ロック: 同時取得拒否、例外後の再取得成功。

W1は手動operator入力または専用sessionが入力deliveryを解除するまでW2へ進まない。公開範囲はD-1によりAI無効のMozcベータであり、成果物はAIを同梱せず・AI込みと宣伝せず、その旨をRelease noteと同梱文書へ明記する。署名はD-3により必須ではないが、未署名である旨・SmartScreen/publisher警告・「SmartScreen等を無効化しないこと」・SHA-256/対応ソース/ライセンス/既知制限の添付は義務として残る。公開サイトはD-5により作らず、公表面はREADME.mdとGitHub Release bodyのみ。
