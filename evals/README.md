# KanaAI quality evaluation harness

This directory contains a small, synthetic, **offline-first** evaluation for
the Phase 1 candidate pipeline. It is deliberately not a claim about a
production TSF, a Mozc dictionary quality result, or a model leaderboard.

The runner compares three paths over the same candidate sets:

1. **Pinned Mozc baseline** — the candidate order and runtime values recorded in
   the fixture and attributed to the repository's pinned Mozc gitlink
   (`13c98988247aa711d99db9e348ec2a597d14b5cd`, recorded as Mozc
   `3.34.6239.100 / engine 24`).
2. **Deterministic local policy** — a bounded, stable promotion policy. The
   policy only moves a declared preferred candidate at most two positions; it
   never creates text or IDs. The runner recomputes the order and rejects a
   fixture that disagrees with the declaration.
3. **Optional local-AI rerank** — recorded response fixtures by default, or a
   strict OpenAI-compatible loopback endpoint in live mode.

The default fixture corpus includes context/homophone, technical, business,
name-collision, number/punctuation, abstention, timeout, malformed-ID, and
secure-field cases. The fault cases are intentional: their expected outcome is
safe fallback, not a failed evaluation.

## Run without a model

Node.js 22 or newer is sufficient. There are no additional npm dependencies,
network requests, model weights, or native Mozc build requirements.

```bash
node scripts/run-quality-eval.mjs
node scripts/run-quality-eval.mjs --json
node scripts/run-quality-eval.mjs --ai-mode none
node scripts/run-quality-eval.mjs --strict --json
```

`--json` writes one report to stdout. Human output goes to stdout; warnings and
errors go to stderr. The default run uses only
`evals/fixtures/quality-cases.json` and therefore works in CI or a clean
checkout without a model server.

The fixture SHA-256, corpus version, pinned Mozc revision, policy version, and
AI source are included in JSON output. No wall-clock timestamp is emitted, so
fixture-mode output is reproducible. Runtime values shown in fixture mode are
reported fixture observations, not measurements made by the runner.

## What is measured

For rank-labeled, non-secure cases, the report includes:

- top-1, top-3, top-5, and any additional cutoffs supplied with `--k`;
- mean reciprocal rank (MRR), with missing gold candidates contributing zero;
- per-slice top-1/top-3/top-5/MRR values;
- raw candidate-ID validity for a reranker response; and
- effective candidate-ID validity for the list that would be displayed.

A valid rerank is a bounded permutation of the submitted candidate IDs. IDs
must be unique, known, and may move at most three positions. An abstention is
valid when it has an empty ID list, sufficient confidence, and `reasonCode:
abstain`. Invalid responses are rejected atomically and the baseline order is
retained.

Reliability counters cover `timedOut`, `unavailable`, `rejected`, `abstain`,
and fallback. An abstention keeps the baseline and is counted as a safe
fallback as well as an abstention. A fallback is considered safe only when its
effective order is identical to the pinned baseline. Runtime p50/p95 use a
documented nearest-rank calculation; if no runtime observations are reported,
both values are `null` rather than fabricated. JSON marks their source as
`fixture` or `measured` so fixture observations are not confused with live
measurements.

Secure-field cases are excluded from ordinary quality ranking because privacy
behavior, not lexical preference, is their contract. They must be skipped
before an AI request is constructed. The report checks that:

- secure cases produce no outbound AI request;
- synthetic redaction markers do not occur in request/response material; and
- a secure skip is not mislabeled as a successful model response.

Candidate text, context, secrets, API keys, and raw model responses are not
printed in the report. Only case IDs, numeric candidate IDs, statuses, and
metrics are emitted.

## Fixture format

`evals/fixtures/quality-cases.json` is versioned with `schemaVersion: 1`.
Each case has:

- `id`, `slice`, `reading`, optional synthetic `contextBefore`/`contextAfter`;
- `secureField` and, for secure cases, `fieldClass` plus
  `redactionMarkers`;
- `baseline.candidates`, an ordered list of `{ id, text, reading, cost }`
  objects attributed to the pinned Mozc fixture;
- `expectedAction: "rank" | "abstain"` and `goldCandidateId` for rank cases;
- `policy.preferredCandidateIds` and an optional declared
  `policy.candidateIds`; and
- optional `ai` status, candidate IDs, confidence, reason, and runtime data.

The policy algorithm is intentionally simple and deterministic: it starts
with the baseline order, promotes each preferred ID by at most
`policy.maxRankShift`, and leaves unpromoted IDs in their baseline order. The
preference is a synthetic local-feature decision, not read from
`goldCandidateId`; a production corpus should replace it with the actual local
policy output. It is a harness policy fixture, not a claim that the Rust or
native TSF policy has been changed by this directory.

The runner calculates a fixture SHA-256 (and a separate AI-fixture SHA-256
when `--ai-fixtures` is used) so a result can be tied to the exact synthetic
input. Use `--allow-unpinned-revision` only when intentionally
testing a different development capture; the default refuses to call a
non-pinned revision a pinned-Mozc baseline.

## Plugging in a local GGUF / OpenAI-compatible server later

The live adapter is optional and uses the same loopback-only boundary as the
project's local-AI design. It sends a bounded payload containing only the
reading, up to 32 normalized characters of context, and up to five existing
candidate IDs/values, matching the Phase 1 TSF rerank window. It does not send
a document, clipboard, window title, URL, history corpus, or secure-field
content.

Start a local `llama.cpp` server separately. For example, using the existing
project helper (which never downloads weights):

```bash
scripts/run-local-model.sh /absolute/path/to/model.gguf
```

Then run the evaluator in a second terminal:

```bash
KANA_AI_MODEL='my-local-model-id' \
  node scripts/run-quality-eval.mjs \
    --ai-mode live \
    --ai-endpoint http://127.0.0.1:8080/v1 \
    --model 'my-local-model-id' \
    --timeout-ms 250 \
    --json
```

The endpoint may be a base URL ending in `/v1` or a full
`/chat/completions` URL. `KANA_AI_BASE_URL` can be used instead of the option.
`KANA_AI_API_KEY` is optional and is never printed.
A non-loopback endpoint is rejected by default; `--allow-remote` is an
explicit development escape hatch and still requires HTTPS.

The server must return a JSON completion whose `choices[0].message.content`
is a JSON object with this shape:

```json
{
  "action": "rerank",
  "candidateIds": [42, 17, 99],
  "confidence": 0.91,
  "reasonCode": "semantic_context",
  "modelTier": "compact",
  "expiresAtGeneration": 7,
  "patch": null
}
```

For an uncertain case, return `action: "abstain"`, `candidateIds: []`, and
`reasonCode: "abstain"` instead of guessing. The evaluator requires a
confidence of at least `0.75`, the expected model tier and generation, and a
complete bounded permutation. Markdown fences, unknown candidate IDs,
duplicate IDs, excessive movement, malformed envelopes, oversized responses,
HTTP errors, and timeouts are rejected; the pinned baseline is used instead.
A timeout is measured at the configured deadline and is reported separately
from a model quality result.

Secure-field cases are handled before `buildRerankPayload` and before any
`fetch`, so even a live server cannot observe those synthetic markers. The
`--ai-mode none` mode is useful for checking the deterministic and fallback
reports when no model is installed.

## Interpreting the fixture faults

The fixture's timeout case should produce one timeout and one preserved
baseline fallback. Its invalid-ID case should produce one raw candidate-ID
failure and one preserved baseline fallback. Those are expected safety
observations; they do not indicate a broken fixture run. `--strict` checks
safety invariants (effective ID validity, fallback preservation, and secure
redaction), not whether a model beats Mozc.

For a release-quality claim, replace or extend the small synthetic corpus with
KanaAI-created or appropriately licensed held-out data, run the same pinned
candidate captures through the native bridge, and report the target-slice and
regression gates separately. This harness intentionally does not fabricate
those missing measurements.
