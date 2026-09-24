# KanaAI product contract

## Product thesis

KanaAI is **a local Japanese language runtime embedded in an IME**. It is not an ATOK clone and it is not a chat window attached to a converter.

Mozc remains the deterministic Japanese input engine. KanaAI adds a bounded local intelligence layer that understands the user's likely intent, improves candidates, repairs likely mistakes, and helps the user write without taking control of the input state machine.

The product promise is:

> **「変換の速さ」と「LOCAL AIの理解」を、モード破壊なしに一つにつなぐ。**

## Windows beta boundary

The first Windows deliverable is a native TSF TIP, not a Workbench/CLI package.
The existing Mozc Windows TIP is the host; KanaAI adds a narrow AI/broker
integration without replacing Mozc's conversion or Windows text-service
lifecycle. A source bridge, HTTP API, browser page, or command-line tool is not
an IME beta.

A beta is publishable only after the TIP is registered and tested in ordinary
desktop applications, including preedit/candidate behavior, commit/cancel,
focus recovery, secure fields, UIA, and x86/x64 packaging. The complete gate is
in [`PRODUCT_RELEASE_CONTRACT.md`](PRODUCT_RELEASE_CONTRACT.md) and the native
implementation plan is in [`PLATFORM_ROADMAP.md`](PLATFORM_ROADMAP.md).


```text
physical key
  -> native IME shell
  -> deterministic composition mode
  -> Mozc preedit / conversion
  -> KanaAI fast policy
  -> optional local semantic assist
  -> candidate window
  -> explicit commit
  -> local learning event
```

The user should feel the system becoming more personal, not feel that an AI chatbot has been inserted into the keyboard.

## Phase 1 local AI quality model

Phase 1 is a native Windows TSF IME built on pinned upstream Mozc. The target
is the practical quality and convenience users expect from a mature Japanese
IME, with modern local AI added only where it improves the measured result.
Google Japanese Input is a product-quality reference; its proprietary
implementation and data are not copied.

The normal path is:

```text
Mozc composition/conversion
  → bounded fast local policy and candidate rerank
  → optional asynchronous local semantic assist
  → TSF candidate presentation
  → explicit commit and learning
```

The first AI mode must optimize for useful quality and low latency rather than
model size. A per-key LLM call is out of scope for the normal path. Timeout,
model absence, malformed output, and stale generations all fall back to Mozc.
The quality gate is a reproducible comparison against the pinned Mozc baseline,
not a subjective claim of Google Japanese Input parity.


AI never owns:

- direct/hiragana/katakana/full-width mode transitions;
- preedit insertion or deletion;
- cursor position;
- commit replacement ranges;
- password/direct-mode bypass;
- learning persistence;
- network permission;
- model loading or cancellation.

The native shell and Rust session FSM remain authoritative. AI returns a bounded suggestion or ranking decision for the current generation and can always be ignored or timed out.

## AI responsibility matrix

| Responsibility | Fast neural ranker | Local LLM | Default behavior |
|---|---:|---:|---|
| Re-rank existing Mozc candidates | yes | on ambiguity | enabled when a local model is available |
| Detect likely wrong kanji | yes | on explicit repair | show an alternative, never silently rewrite |
| Predict a short continuation | yes | optional | suggest only, never auto-commit |
| User/domain affinity | yes | no need | local deterministic policy |
| Generate a candidate absent from Mozc | no by default | constrained mode only | disabled until explicitly enabled |
| Rewrite selected text | no | yes | explicit action and preview |
| Summarize / bulletize | no | yes | explicit action and preview |
| Switch input mode | no | no | never |
| Learn from an unconfirmed candidate | no | no | never |

## Safe AI output contract

Every AI result is structured and bounded:

```json
{
  "action": "rerank | repair | continuation | assist | abstain",
  "candidateIds": [12, 3, 8],
  "patch": null,
  "confidence": 0.0,
  "reasonCode": "ambiguous_homophone",
  "modelTier": "compact",
  "expiresAtGeneration": 42
}
```

A model may reorder existing candidate IDs. It may create a new surface only in an explicitly enabled constrained mode, where the value must be validated against a local lexicon. Malformed, unknown, low-confidence, or late results are discarded.

## Why the AI is second-stage

A small local language model is not a good universal replacement for a tested kana-kanji converter. Calling a large model on every key also makes low-end machines slow, hot, and unpredictable.

KanaAI therefore uses two neural speeds:

1. **Fast ranker** — small classifier, embedding, or lightweight neural model for the normal candidate path.
2. **Local LLM** — 0.6B–1.7B for ambiguity, repair, and explicit writing actions; larger models are opt-in.

The deterministic Mozc result is always available before the LLM is called.

## Internal behavior, not a side assistant

AI actions appear in the native candidate window as ordinary candidates with an origin label such as:

- `文脈再順位`
- `誤変換修復`
- `学習履歴`
- `個人語彙`
- `ローカルAI`

The normal shortcut flow remains Space/Enter/Tab. AI does not open a separate conversation. A dedicated writing hotkey may open a preview, but it uses the same local policy and undo contract.

## Personalization without hidden training

KanaAI learns from a successful commit, not from merely showing a candidate. The local profile contains bounded semantic records and style summaries. Automatic model fine-tuning is a future opt-in feature, never a side effect of typing.

The user can inspect, export, disable, reset, or delete the profile. A password/protected field disables all content-derived learning and optional assist.

## Definition of “high specification”

High specification does not mean always using the largest model. It means the system is complete at every level:

- deterministic and useful without a model;
- fast neural reranking on modest hardware;
- local LLM ambiguity resolution on capable hardware;
- optional larger local LLM for explicit writing;
- bounded memory, cancellation, fallback, and diagnostics;
- identical native mode semantics on Linux, Windows, and macOS.
