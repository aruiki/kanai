# kanai-broker

`kanai-broker` is a platform-neutral Rust foundation for the broker process that
will sit behind a future Windows TSF TIP. It is deliberately **not** a TSF DLL,
a COM server, or a completed Windows named-pipe server.

## Integration contract

### Protocol

Requests and responses are JSON DTOs in `protocol.rs`, wrapped in a versioned
envelope:

```text
RequestEnvelope  { version, requestId, command }
ResponseEnvelope { version, requestId, generation?, outcome }
```

`PROTOCOL_VERSION` is currently `1`. A request is rejected before backend
dispatch when its version is different or when a bounded field is invalid.
The operation-tagged command and response DTOs are:

- `createSession`
- `key`
- `edit`
- `convert`
- `commit`
- `cancel`
- `focusLost`
- `health`
- `generation`
- `rerankCandidates`
- `semanticAssist`

Use `encode_request`/`decode_request` and `encode_response`/`decode_response`
at the JSON boundary, or the `send_request`/`receive_request` and
`send_response`/`receive_response` transport helpers. A native adapter should
not serialize its own equivalent of these DTOs.

### Framing

`FrameCodec` and `FrameDecoder` use this wire header:

```text
KBF1 | u32 big-endian payload length | UTF-8 JSON payload
```

The default payload limit is 1 MiB. A length is checked before allocating a
payload, and the streaming decoder never buffers more than one bounded header
plus payload. `FramedIo<T>` is a synchronous `Read + Write` adapter useful for
Linux tests or a future blocking named-pipe wrapper. A Windows implementation
must provide the actual pipe handles, I/O, overlapped/asynchronous policy, and
ACLs; this crate does not pretend to do that.

### Authentication and peer validation

`AuthenticatedTransport<T>` fails closed for both send and receive until one
handshake is accepted through a `PeerAuthenticator`. The reference
`SharedSecretAuthenticator` is a deterministic Linux-test adapter only. A
production Windows adapter should:

1. create a per-user private named pipe with an explicit user-only ACL;
2. validate the pipe client token/peer identity in a platform authenticator;
3. reject unsupported auth and protocol versions; and
4. keep the shared-secret fallback out of the production security boundary.

The auth proof is opaque to this crate. `AuthRequest::proof` and `SharedSecret`
are redacted from `Debug` output, but callers must still avoid logging wire
captures or handshake data.

### Generations, cancellation, and fallback

A session starts at generation `0`. `key`, `edit`, `commit`, `cancel`, and
`focusLost` reserve the next checked `u64` generation before backend work;
`convert` and `generation` are read-only with respect to the generation counter.
A request carrying an older expected generation is rejected without calling the
backend. `checked_add` prevents wraparound.

`CancellationToken` and `CancellationRegistry` provide cooperative cancellation
of in-process work. A `CancelRequest` can target a request ID and may omit its
generation so a newer shell generation can still cancel older optional work;
if a generation is supplied, it is checked. The transport adapter should route
an optional-job cancellation to `EnhancementCoordinator::cancel_request` and
use the broker registry for synchronous broker work.

### Optional local quality enhancements

`CandidateRerankRequest`/`CandidateRerankResponse` retain both the bounded
Mozc baseline order and the optional AI order, together with
`EnhancementMetrics` (candidate counts, changed positions, adoption count, and
baseline/AI latency). A rerank response must contain a complete, exact
permutation of the baseline candidates; fallback returns that baseline order
with `adopted: false`. `SemanticAssistRequest`/`SemanticAssistResponse` are explicit
user-triggered operations with bounded text/context and a consent bit. The
`EnhancementBackend` trait is asynchronous; `EnhancementCoordinator` applies
its deadline, cancellation (including request-ID cancellation through
`cancel_request`), stale-generation check, and deterministic fallback. The
provided coordinator uses Tokio's timer and must run on a Tokio runtime.
`Broker::handle` rejects these commands with `EnhancementRequiresAsync`, so a
model/provider call cannot accidentally run on the blocking per-key path. The
caller must schedule the coordinator on a bounded optional executor.

`Broker::enhancement_token` captures the session generation and field class.
Password/protected sessions use `SecureFieldPolicy::Prohibit`; the coordinator
returns a measurable skipped response before calling a provider. The default
`EnhancementPolicy` is disabled, and the coordinator rejects remote providers.
No model runtime or external provider dependency (including any project not
part of this repository) is linked here.

`FallbackPolicy` is local and deterministic:

- `LastValidPreedit` returns the last valid local composition/candidate state;
- if none exists, the result is an empty, unconsumed direct-input state;
- `DirectInput` always returns the empty/unconsumed state;
- a failed commit returns an error and never fabricates committed text; and
- a backend failure never selects a network or alternate conversion service.

The future TIP can therefore use a safe direct-input/recovery path while the
Rust broker remains the only owner of session state and generation checks.

## Current boundary

`BrokerBackend` is the integration seam for a future Mozc/local backend. The
included `DeterministicBackend` is only a small test double, not a Japanese IME
engine. No Windows API, TSF registration, candidate UI, OS secure-field
detection, or named-pipe lifecycle is implemented here; the broker only
enforces the typed privacy decision supplied by the shell.
