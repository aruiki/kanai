# Phase 1 quality gates for the pinned-Mozc Windows TSF

This is a development acceptance plan, not evidence that the gates have passed.
The current x64 vertical slice does not attempt x86, full UIA, installer
packaging, signing, or visual polish. KanaAI does not use proprietary Google
code or data. The quality target is the
behavior and convenience of a mature Japanese IME; evaluation data must be
KanaAI-created, public-domain, or separately licensed.

## Non-negotiable architecture gates

1. The installed KanaAI supplemental model is unavailable and behaviorally
   identical to pinned upstream Mozc until a per-context broker
   session/generation bridge and async executor exist.
2. No AI call is made from a key event, preedit update, supplemental-model
   callback, or realtime prediction path. A future executor must publish an
   exact validated response for later application.
3. The broker may return ranks only for at most five candidates already emitted
   by Mozc. It cannot add, delete, rewrite, or synthesize candidate text.
4. Missing, malformed, rejected, or timed-out responses leave Mozc candidate
   order and cost unchanged.
5. AI is not allowed to write learning data. User-history commits and candidate
   selection remain owned by Mozc.

## Baseline-versus-AI corpus

Create a frozen, versioned corpus with at least 1,000 held-out Japanese
compositions, stratified by sentence length, kana/kanji/katakana mix, ASCII
input, punctuation, numbers, and edit distance. Include a separately labeled
slice of user-approved corrections. Keep the broker/model version and random
seed with every run.

For every item, run the same staged binaries twice once the session bridge is
implemented:

- **Baseline:** the patched server with the supplemental model unavailable.
- **AI:** the same binary with a valid broker session/generation token and the
  bounded local reranker executor enabled.

Record candidate-list JSON before display and after commit. Compare only the
same reading and the same upstream candidate set.

## Ranking metrics and release threshold

Report macro and micro values for top-1, top-3, top-5, mean reciprocal rank,
and normalized discounted cumulative gain. Also report the target-slice delta
and a 95% bootstrap confidence interval.

The AI build may be a public beta only if:

- candidate-set equality is 100%;
- overall top-1 is non-inferior within 1 percentage point;
- the predeclared target slice improves top-1 by at least 2 percentage points;
- no protected slice regresses top-1 by more than 2 percentage points; and
- human review finds no new high-severity mistranslation or privacy issue.

These are proposed release thresholds, not current results.

## Latency and timeout measurements

Collect at least 10,000 measured events after 1,000 warmup events on a
supported Windows release, with an idle broker and a loaded broker.

- Key-to-preedit p95 must not regress by more than 5 ms from baseline and must
  not incur any broker wait.
- Explicit conversion-to-candidate-list p95 may add at most 20 ms in the normal
  local case and must remain below the configured 100 ms hard ceiling.
- No p99 event may block longer than the configured broker deadline plus the
  measured pipe cleanup overhead.
- Record baseline, timeout, unavailable, rejected, malformed-response, and
  broker-crash cohorts separately.

Fault injection must cover absent pipe, busy pipe, delayed response, abrupt
broker termination, oversized frame, wrong request ID, duplicate rank, and
partial response. Every fault must preserve the baseline candidate list and
leave typing usable.

## Learning and state tests

1. Commit the same candidates in baseline and AI runs; compare user-history
   records byte-for-byte after the Mozc sync completes.
2. Change the broker rank, then repeat the commit; no new dictionary or history
   entry may result solely from the rank change.
3. Restart `mozc_server`, the broker, and Windows; verify the profile remains
   selected and no stale pipe handle, process, or lock remains.
4. Exercise upgrade, repair, uninstall, and reinstall with the upstream WiX
   actions. An x64-only seam does not satisfy this gate.

## Secure fields, privacy, and UIA

Instrument the broker to record connection metadata (not candidate text) and
prove no connection for:

- Mozc incognito requests;
- Windows secure-desktop activation;
- password input scopes in Notepad, Office, Chromium, and WPF smoke apps;
- elevated and UAC boundaries; and
- AppContainer or restricted-token cases that remain in scope.

Then run the UI Automation matrix for inline preedit attributes, candidate
window open/update/close, page keys, focus loss, cancellation, and screen
reader names. Secure-field and UIA support remain **unimplemented and unproven**
until this matrix passes; the current adapter fails closed for incognito data
and does not claim secure-field compatibility.
