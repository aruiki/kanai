# kanai-broker

`kanai-broker` is a platform-neutral Rust foundation for the broker process that
sits behind the Windows TSF integration. It is not a TSF DLL or a COM server,
but it now includes a bounded authenticated connection adapter, a Windows
named-pipe server target, and a real session-aware Mozc lab adapter.

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
- `prepareRerankSession`
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
Linux tests and local sockets. The Windows target uses Tokio overlapped named
pipes, rejects remote clients, creates the pipe with a protected owner/system
DACL, and validates the connected process/session/user token before accepting
application frames.

### Authentication and peer validation

`AuthenticatedTransport<T>` fails closed for both send and receive until one
handshake is accepted through a `PeerAuthenticator`. The reference
`SharedSecretAuthenticator` is a deterministic Linux-test/local-socket adapter
only. The Windows `WindowsPeerAuthenticator` additionally checks the pipe
client process, Windows session, and user token; its public capability marker
is not a secret. Production packaging must still keep the shared-secret
fallback out of the Windows boundary.

The auth proof is opaque to this crate. `AuthRequest::proof` and `SharedSecret`
are redacted from `Debug` output, but callers must still avoid logging wire
captures or handshake data.

### Generations, cancellation, and fallback

A session starts at generation `0`. In the synchronous compatibility
`Broker`, `key`, `edit`, `commit`, `cancel`, and `focusLost` reserve the next
checked `u64` generation before backend work; `convert` remains read-only for
existing embedders. The async `SessionBroker` additionally advances the
checked generation for every conversion/page snapshot, so a later conversion
invalidates an older optional candidate result. A request carrying an older
expected generation is rejected without calling the backend. `checked_add`
prevents wraparound.

`CancellationToken` and `CancellationRegistry` provide cooperative cancellation
of in-process work. A `CancelRequest` can target a request ID and may omit its
generation so a newer shell generation can still cancel older optional work;
if a generation is supplied, it is checked. The transport adapter should route
an optional-job cancellation to `EnhancementCoordinator::cancel_request` and
use the broker registry for synchronous broker work.

### Async session owner and optional queue

`SessionBroker` is the process-facing owner used by the executable. It stores
per-session generation/lifecycle/privacy state behind a per-session operation
lock, binds each transport-created session to the authenticated client ID,
and invalidates captured tokens on focus loss. `prepareRerankSession` is a
lightweight, authenticated candidate-rerank admission path: it creates or
advances a generation-only session without opening a second Mozc composition
backend, and `focusLost` releases it. Cross-peer session access and
cancellation are rejected; the OS authenticator still must be paired with a
private pipe ACL.
`MozcSessionBackend` now shares one bounded bridge process across broker
sessions. The C++ side retains a compatibility facade while adding explicit
`open`, `key`, `edit`, `convert`, `commit`, `cancel`, and `close` commands. The
bridge caps total upstream sessions at 64 (including the legacy compatibility
session), keeps them incognito, and serializes the
pinned synchronous `SessionHandler`; internal negative/zero Mozc IDs are
remapped to positive request-scoped IDs before commit.

`EnhancementQueue` is a bounded multi-worker queue. Admission is non-blocking;
a full queue returns the unmodified baseline without calling a provider. The
implementation caps queued jobs at 64 and workers at 8; configuration outside
those bounds is rejected before allocation. Only the latest queued job for a
session is retained: admitting a newer job cancels the previous token, while
the generation token still provides the final stale-result check. The queue and all model work are separate from the
synchronous key/preedit dispatcher.

The executable is `src/bin/kanai-broker.rs`. On Unix it exposes a private
`KANAI_BROKER_SOCKET`; on Windows it binds
`\\.\pipe\KanaAI.TsfBroker.v1.<windows-session-id>`. The Unix listener requires
`KANAI_BROKER_SECRET` for its test-only shared-secret handshake. The Windows
listener uses the OS-token authenticator and does not use that secret. No model
weights or inference runtime are bundled; the default policy is disabled and
returns the Mozc baseline unless an explicitly configured loopback provider is
selected.

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

The optional `LocalOpenAiBackend` is a deliberately narrow integration seam for
a separately operated local OpenAI-compatible server. It is enabled only with
`KANAI_BROKER_ENHANCEMENT=local`, `KANAI_AI_BASE_URL`, and `KANAI_AI_MODEL`.
The URL must be an HTTP loopback address (remote and TLS endpoints are rejected),
the request is bounded to nine candidates and short context, and the response
must be a strict JSON decision containing an exact candidate permutation. HTTP
failure, timeout, cancellation, oversized output, or malformed output falls back
to the unchanged Mozc order. This adapter does not bundle model weights and is
not a remote-service integration.

`Broker::enhancement_token` captures the session generation and field class.
Password/protected sessions use `SecureFieldPolicy::Prohibit`; the coordinator
returns a measurable skipped response before calling a provider. The default
`EnhancementPolicy` is disabled, and the coordinator rejects remote providers.
No model weights or external service dependency (including any project not
part of this repository) is bundled here; the optional adapter only talks to
an explicitly configured loopback provider.

`FallbackPolicy` is local and deterministic:

- `LastValidPreedit` returns the last valid local composition/candidate state;
- if none exists, the result is an empty, unconsumed direct-input state;
- `DirectInput` always returns the empty/unconsumed state;
- a failed commit returns an error and never fabricates committed text; and
- a backend failure never selects a network or alternate conversion service.

The future TIP can therefore use a safe direct-input/recovery path while the
Rust broker remains the only owner of session state and generation checks.

## Current boundary

`SessionBackend` is the async integration seam for a real Mozc/local backend.
`MozcSessionBackend` now uses one bounded, incognito bridge process for all
broker sessions. The C++ protocol retains the legacy one-shot commands while
adding explicit session lifecycle/state commands; the pinned synchronous
`SessionHandler` is serialized inside that process, and Rust remains the
authority for session ownership, generation checks, and commit correlation.
The Windows named-pipe server is source-built and cross-target checked, but a
real Windows TIP registration/application run, secure-field matrix, model
runtime, and native application evidence remain release gates. The Windows
client/server boundary also checks the connected process image (configurable
with `KANAI_AI_TSF_CLIENT_IMAGE`/`KANAI_AI_TSF_SERVER_IMAGE`); Authenticode
and same-user impostor evidence remain required. The staged TSF server hook
supplies a trusted session/generation token; a client-fabricated token is still
never accepted.
