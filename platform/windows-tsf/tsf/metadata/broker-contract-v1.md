# KanaAI TSF use of the kanai-broker v1 contract

Status: **native client projection plus integration seam; no broker executable
or active AI reranking claim**. The semantic source of truth is KanaAI's Rust
crate, not this document and not a TSF-local protocol.

Canonical files:

- `crates/kanai-broker/src/frame.rs`
- `crates/kanai-broker/src/protocol.rs`
- `crates/kanai-broker/src/transport.rs`
- `crates/kanai-broker/src/enhancement.rs`
- `crates/kanai-broker/src/broker.rs`

`platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/broker_contract.*` is only the
C++ projection needed at the native boundary. A change to the Rust DTOs or
framing must update/fail this projection; the TSF must not grow a second
semantic protocol.

## Why the installed supplemental model is currently inert

The pinned Mozc `SupplementalModelInterface` provides a conversion request and
candidate results, but no KanaAI broker `sessionId` or monotonic `generation`.
The canonical `rerankCandidates` request requires both and the async
coordinator rejects stale or unauthorized generations. `SupplementalModel`
also has no secure `FieldClass` token.

The installed `KanaAiSupplementalModel` therefore reports unavailable and is a
no-op. It does not guess identifiers, read documents, call a provider, or
publish work. A future session owner must provide a token-aware asynchronous
handoff before AI can be enabled. `ApplyRerankToResults` is the non-I/O seam
for an already validated exact response.

## Transport boundary

- Default pipe: `\\.\pipe\KanaAI.TsfBroker.v1.<windows-session-id>`.
- `KANAI_AI_TSF_PIPE` may select another suffix only when the name retains the
  exact KanaAI prefix.
- Client and broker must run in the same interactive Windows session.
- The server must use a current-user-only DACL,
  `PIPE_REJECT_REMOTE_CLIENTS`, and no network fallback.
- `KBF1` frames use an 8-byte header: four magic bytes followed by a
  network-order, nonzero `u32` payload length of at most 1 MiB. The payload is
  one UTF-8 JSON value.
- The client deadline defaults to 250 ms and is bounded to 1..2000 ms.
- The client never starts I/O from a Mozc key, preedit, or supplemental-model
  callback. A future optional executor must own the call and cancellation.

The C++ pipe client sends the canonical `AuthRequest` first, requires an
`AuthResponse` for the same client ID, and then sends one rerank request. The
32-byte nonce comes from `BCryptGenRandom`. Its proof field is a public
capability marker, **not a shared secret**. The server's platform
`PeerAuthenticator` must validate the actual pipe client process token/user and
elevation; relying on the marker as authentication is forbidden.

## Canonical rerank request

The native projection emits the same camelCase DTO as Rust Serde:

```json
{
  "version": 1,
  "requestId": 42,
  "command": {
    "operation": "rerankCandidates",
    "payload": {
      "sessionId": 7,
      "generation": 3,
      "candidates": [
        {"id": 1, "text": "かな", "reading": "かな", "rank": 0},
        {"id": 2, "text": "彼方", "reading": "かれかた", "rank": 1}
      ],
      "contextBefore": "",
      "contextAfter": "",
      "policyVersion": "v1",
      "deadlineMs": 20,
      "baselineLatencyMicros": 125
    }
  }
}
```

The TSF slice submits at most five existing Mozc candidates. It sends no
surrounding text. IDs and ranks are request-scoped correlation values, not
persistent user data.

## Canonical response handling

`DecodeRerankResponseJson` accepts either the canonical success payload or
content-free failure outcome. For success it requires:

- protocol/request/session/generation correlation;
- `operation: "rerankCandidates"`;
- the exact baseline candidates sent by this adapter;
- an AI list that is a complete permutation with unchanged ID, text, reading,
  and candidate rank fields;
- local `candidateRerank` metrics and bounded counts; and
- `status`, `adopted`, `fallback`, and `reason` fields.

Only an `applied` response with `adopted: true` is eligible for
`ApplyRerankToResults`. Every timeout, skip, rejection, cancellation, malformed
field, unknown candidate, duplicate, or text mutation leaves Mozc untouched.

## Privacy and secure fields

The current model sends nothing because it has no broker session token. Before
activation, a bridge must carry both:

1. the broker's session/generation token; and
2. a field classification with `Prohibit` for password/protected sessions.

No document text is needed for the first reranker. Semantic assist and
surrounding context remain disabled. Full secure-field, UIA, restricted-token,
and AppContainer matrices are release gates, not assumptions.

## Required next integration work

1. Identify the narrow upstream owner of Mozc's session ID and generation.
2. Add a token handoff to an optional asynchronous executor without changing
   the TIP's key/preedit callbacks.
3. Implement the Windows named-pipe server with ACL plus client-token
   `PeerAuthenticator` validation.
4. Add wire fixtures generated by the Rust crate and cancellation/timeout
   integration tests.
5. Prove fallback, learning isolation, p95, secure fields, UIA, and restart
   behavior before enabling any model.
