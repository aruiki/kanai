# KanaAI TSF use of the kanai-broker v1 contract

Status: **native client projection, bounded async worker, and trusted
server-side session-generation bridge; no registered TSF AI reranking claim**.
The semantic source of truth is KanaAI's Rust crate, not this document and not a
TSF-local protocol.

Canonical files:

- `crates/kanai-broker/src/frame.rs`
- `crates/kanai-broker/src/protocol.rs`
- `crates/kanai-broker/src/transport.rs`
- `crates/kanai-broker/src/enhancement.rs`
- `crates/kanai-broker/src/queue.rs`
- `crates/kanai-broker/src/session.rs`
- `crates/kanai-broker/src/mozc_session.rs`
- `crates/kanai-broker/src/broker.rs`

`platform/windows-tsf/tsf/host_overlay/engine/kanai_ai/broker_contract.*` is only the
C++ projection needed at the native boundary. A change to the Rust DTOs or
framing must update/fail this projection; the TSF must not grow a second
semantic protocol.

## Session/generation bridge

The pinned Mozc `SupplementalModelInterface` itself still has no
`sessionId`/generation field. The staged `0003` patch therefore adds a
server-side hook in `session/session_handler.cc`: immediately before each
`SEND_KEY` or `SEND_COMMAND`, the trusted handler advances a per-Mozc-session
counter and calls `KanaAiSupplementalModel::BeginMozcCommand`. `DELETE_SESSION`
invalidates the counter and opaque binding. A password `Context` advances the
counter but leaves the model unavailable.

The model starts a bounded worker at module initialization on Windows, obtains
its process-global instance, and `PostCorrect` only snapshots at most five
Mozc candidates into a latest-per-session in-memory queue. The worker uses the
real named-pipe transport; it never performs I/O from a key/preedit callback.
`ApplyRerankToResults` consumes only a later response whose binding, generation,
baseline text/readings/IDs, and exact permutation still match.

This is a native source/runtime path, not yet a registered product: the real
Windows TIP lifecycle, installer, model runtime, and application evidence are
still release blockers.

## Transport boundary

- Default pipe: `\\.\pipe\KanaAI.TsfBroker.v1.<windows-session-id>`.
- `KANAI_AI_TSF_PIPE` may select another suffix only when the name retains the
  exact KanaAI prefix.
- Client and broker must run in the same interactive Windows session.
- The server must use a protected owner/System/Administrators DACL,
  `PIPE_REJECT_REMOTE_CLIENTS`, and no network fallback; the connected client
  token must still match the broker owner's user and Windows session.
- `KBF1` frames use an 8-byte header: four magic bytes followed by a
  network-order, nonzero `u32` payload length of at most 1 MiB. The payload is
  one UTF-8 JSON value.
- The client deadline defaults to 250 ms and is bounded to 1..2000 ms.
- The client never starts I/O from a Mozc key, preedit, or supplemental-model
  callback. The bounded worker owns the call and cancellation.

The C++ pipe client sends the canonical `AuthRequest` first, requires an
`AuthResponse` for the same client ID, then sends a
`prepareRerankSession` control request and the rerank request on a fresh
bounded connection. The prepare operation creates/advances a broker-side
candidate-rerank generation without opening a second Mozc composition owner.
The 32-byte nonce comes from `BCryptGenRandom`. Its proof field is a public
capability marker, **not a shared secret**. The C++ client now verifies the
connected broker process image (or exact `KANAI_AI_TSF_SERVER_IMAGE` path), and
the Rust Windows server verifies the client process image (or exact
`KANAI_AI_TSF_CLIENT_IMAGE` path), Windows session, and user token through
`WindowsPeerAuthenticator`; relying on the marker alone is forbidden. An
Authenticode/signature policy and same-user impostor tests remain release
requirements.

The Rust `kanai-broker` executable has a concurrent bounded named-pipe listener
and a latest-per-session enhancement queue. The async session owner advances
its generation for each conversion snapshot, so a later page cannot adopt an
older optional result. The Unix listener is only a private local integration
endpoint. The Linux/Mozc lab path uses one bounded multi-session bridge process
with an explicit `open`/`key`/`edit`/`convert`/`commit`/`cancel`/`close`
protocol and a compatibility facade.

## Native rerank-session preparation

Before the optional exchange, the client sends this control payload on its own
authenticated connection:

```json
{
  "version": 1,
  "requestId": 42,
  "command": {
    "operation": "prepareRerankSession",
    "payload": {
      "sessionId": 7,
      "generation": 3,
      "fieldClass": "regular"
    }
  }
}
```

The broker replies with a `generation` response carrying the same session and
generation. This is a rerank-only session: it carries an admission/generation
token but cannot be used as a Mozc key/edit/commit owner. A lower generation
is rejected; a higher generation invalidates older optional tokens. Secure
fields never send this request.

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

The model sends only the bounded candidate snapshot and at most 32 Unicode
scalars of local context after a trusted regular-field binding. Password and
protected `Context` values advance/invalidate the binding without submitting a
request. No full document, clipboard, raw key log, or unbounded history is
sent. Semantic assist remains disabled. Full secure-field, UIA,
restricted-token, and AppContainer matrices are release gates, not assumptions.

## Required next integration work

The native overlay now has a process-local `SessionBindingOwner` capability
boundary, a server-side `BeginMozcCommand`/`EndMozcSession` hook, a bounded
latest-per-session worker, and an exact live-result apply path. The remaining
release work is integration and evidence, not a source-only placeholder:

1. Build the staged Windows x86/x64 TIP/server with the three patches and prove
   the model is loaded and `IsAvailable()` becomes true only for a bound
   regular session.
2. Run the real named-pipe auth/ACL/reconnect/concurrency tests and verify
   `prepareRerankSession` ownership, timeout, malformed, stale, and model-kill
   fallback.
3. Connect confirmed commit/undo/learning and the canonical encrypted native
   profile; the current rerank-only prepare session is not a full composition
   owner.
4. Add the installer, model/runtime packaging, quality corpus, secure/UIA
   matrix, performance stress, and daily-use evidence required by `GOAL.md`.

Do not enable a public model or call this a beta until those real Windows
release gates pass.
