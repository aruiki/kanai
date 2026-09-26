# 配布段階の運用規約（2026-09-25更新）

ユーザーのベータ公開・ワンクリック導入の依頼に合わせ、配布段階を整理する。
この節は本ファイルの過去のphase表現より優先する。最終製品条件はGOAL.mdに保持する。

## ビルド候補

Setup.exe/MSI生成、静的検査、単体テストまでの成果物。公開済みベータとは呼ばない。
GitHubのdraftは準備用に使用できるが、公開したと報告しない。

## GitHub prerelease（ベータ）

- 対応OS/CPU/アプリ、動作する機能、未実装機能をリリースノートと同梱文書へ明記する。
- 同じ候補を実際にインストールし、TSF登録、かな入力、漢字変換、候補表示、確定・取消、フォーカス切替、アンインストールを確認する。
- 初回導入と再導入の失敗・巻き戻しを確認する。公開範囲に該当する致命的な入力障害やデータ漏えいが残る候補は公開しない。
- ワンクリックとはSetup.exe起動後にビルド・手動コピー・コマンド操作を要しないこと。UACや再起動が必要なら説明する。
- AI非搭載の場合はその旨を明示し、AI搭載版として宣伝しない。先行版の機能範囲はユーザーの指示と一致させる。
- 署名済みを優先する。未署名ベータは署名状態とWindowsでの表示を明記し、SHA-256、対応ソース、ライセンス、既知制限を添える。署名検証やOS保護の無効化を利用手順にしない。
- 対象コミット、パッチ、依存関係、実際の配布ファイルのハッシュを固定する。GitHubのprereleaseとして公開する。
- ベータの公開はGOAL全条件の達成を意味せず、`.goal-complete` は作成しない。

## 完成版

GOAL.mdの全条件、署名、実モデル品質、プライバシー、対応環境、独立verifierによる判定を必要とする。
ベータを定義したことで完成版の要件を削除・PASS扱いしない。

## 今回の方針変更の理由と影響

従来は「ベータ」という名称にも製品完成の全条件を要求し、段階的な配布依頼と衝突していた。
今後はベータ公開条件と完成条件を別々に評価する。未検証のインストーラーを公開する許可ではない。
ビルド担当による完成宣言の禁止、実測による検証、Mozcフォールバックと入力保護は継続する。

---

以下は最終的に目指す機能範囲と過去のphase設計。現在の公開判断には上記の段階別規約を使用する。

# KanaAI TSF beta and release contract

## Product decision

KanaAI is a Windows Japanese IME. A release candidate is not accepted merely
because it exposes a CLI, a browser page, or a local HTTP service: it must be
usable as a registered Windows text service in ordinary desktop applications.

## Beta boundary: native Windows TSF

The first public beta is a native Windows TSF TIP built on the Mozc Windows TIP
host. The beta must provide, on the supported architectures:

- COM text-service lifecycle and profile registration;
- preedit and candidate presentation;
- Space/Enter/commit/cancel and focus-teardown behavior;
- conversion through the pinned Mozc engine;
- an optional KanaAI local AI reranking path with deterministic fallback;
- crash recovery when the broker or model is unavailable;
- secure-field policy and UI Automation/accessibility coverage; and
- x86/x64 packaging, uninstall, and upgrade behavior.

The TIP may use a private broker to reach Rust, but the broker is an
implementation detail. The user-facing product is still a Windows IME.

## What is not a beta

The retired Workbench/CLI package is no longer a beta, download, or substitute
for a TSF text service. Source code and a development Workbench may remain for
testing the shared core, but they are not a release artifact and must not be
described as an IME.

## Phase 1 definition: local AI quality mode

Phase 1 is the first native Windows TSF IME alpha, based on the pinned upstream
Mozc TIP. Its quality bar is the practical input experience users associate with
Google Japanese Input—fast key handling, predictable composition, useful
candidates, stable learning, and low operational friction—improved with
modern local AI where it is measurably beneficial.

This is a quality and experience reference, not a request to reproduce
Google's proprietary dictionaries, binaries, cloud data, UI, or internal
algorithms. KanaAI must demonstrate improvements against its own pinned Mozc
baseline with reproducible evaluation cases and user-visible behavior.

The local AI model has three bounded roles:

1. **Fast local quality policy** — latency-bounded context, user/domain
   affinity, and candidate reranking on the normal key path.
2. **Local semantic assist** — ambiguity resolution, likely-error repair, and
   short continuation suggestions without blocking composition.
3. **Explicit writing assist** — repair/rewrite actions only after an explicit
   user request and preview.

A large model is never called synchronously for every key. Every AI result is
validated against the current session generation and falls back to Mozc on
timeout, failure, low confidence, or malformed output. The base Mozc result
must remain available even when no model is installed.

Phase 1 quality is measured against a pinned Mozc baseline with:

- top-1/top-k candidate agreement and rerank quality;
- Japanese composition/segmentation regression cases;
- keystroke-to-candidate latency, including p95;
- timeout and recovery rates;
- user-learning correctness across confirmed versus unconfirmed candidates;
- secure-field non-interference; and
- crash-free focus transitions and application restarts.

A model score, prompt, or attractive demo is not a Phase 1 completion criterion.
The TSF IME must remain usable and deterministic while the local model is
absent, disabled, or unavailable.


Google Japanese Input is a product and integration reference for a polished
Mozc-based Windows IME. KanaAI does not reproduce its proprietary binaries,
private dictionaries, cloud synchronization, UI, branding, or internal
implementation. The reusable technical foundation is the open-source Mozc
Windows TIP and its documented interfaces.

## Niche preview scope

The immediate target is a deliberately small, unsigned developer preview for
technical Windows users, not a broadly supported commercial product.

The preview may ship with:

- Windows 10/11 x64 only;
- manual elevated PowerShell installation and uninstall;
- one supported host application for the first input-path test;
- pinned upstream Mozc conversion;
- optional local model-assisted reranking with MozcOnly fallback; and
- explicit source/build logs and known limitations.

The preview does not claim x86, broad Office/Edge compatibility, complete UIA,
secure-field coverage, signing, SmartScreen trust, enterprise management, or
ATOK-level quality. Those are later product gates, not reasons to block the
small usable preview once its narrow input path is verified.

## Beta exit gates

Before publishing a Windows beta:

1. A clean Windows x64 build produces the TIP DLL and all required Mozc data.
2. The DLL is registered and removed in a fresh Windows user profile.
3. Notepad, Edge, and Office pass Japanese composition, conversion, candidate,
   commit, cancel, focus-loss, and restart tests.
4. Secure fields, UIA, high-DPI, x86/x64 registration, and app-container policy
   pass or are explicitly documented as unsupported.
5. A broker failure and model timeout both fall back safely without losing the
   composition or committing text unexpectedly.
6. The package contains no API keys, user profiles, or user text. If the user-approved AI bundle is included, only the pinned, license-approved model/runtime and required notices are allowed; every model/runtime byte, digest, license, and SBOM entry must be recorded.
7. External SHA-256, SBOM, provenance, and signing status are published
   separately and honestly.
8. The public page and installer describe the artifact as a TSF IME, not as a
   Workbench, bridge, or development preview.

These gates are intentionally stricter than a source-buildable skeleton. A
compile-only DLL is a development milestone, not a beta.
