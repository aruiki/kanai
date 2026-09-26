//! Rust-native foundation for a future KanaAI Windows broker.
//!
//! `kanai-broker` is intentionally a protocol and state-machine crate, not a
//! Windows named-pipe server and not a TSF TIP.  It provides versioned DTOs,
//! bounded framing, an authenticated transport boundary, cancellation and
//! stale-generation handling, and deterministic local fallback semantics that
//! a future platform adapter can reuse.

pub mod ai_runtime;
pub mod broker;
pub mod enhancement;
pub mod frame;
pub mod local_model;
pub mod local_runtime;
pub mod mozc_session;
#[cfg(windows)]
pub mod pipe_windows;
pub mod protocol;
pub mod queue;
#[cfg(windows)]
pub mod runtime_process_windows;
pub mod runtime_supervisor;
pub mod service;
pub mod session;
pub mod transport;

pub use broker::{
    BackendError, Broker, BrokerBackend, BrokerConfig, BrokerError, CancellationError,
    CancellationRegistry, CancellationToken, DeterministicBackend, FallbackPolicy, GenerationToken,
};
pub use enhancement::{
    EnhancementBackend, EnhancementCoordinator, EnhancementError, RerankOutput,
    SemanticAssistOutput,
};
pub use frame::{
    DEFAULT_MAX_FRAME_BYTES, DecodedFrame, FRAME_HEADER_BYTES, FRAME_MAGIC, Frame, FrameCodec,
    FrameDecoder, FrameError, FramedIo, MAX_FRAME_BYTES, MemoryTransport,
};
pub use local_model::LocalOpenAiBackend;
pub use local_runtime::{
    LocalRuntimeError, MAX_RUNTIME_CONFIG_BYTES, MAX_RUNTIME_CONTEXT_SIZE, MAX_RUNTIME_PATH_BYTES,
    MAX_RUNTIME_RECEIPT_ENTRIES, MAX_RUNTIME_TEXT_BYTES, PINNED_BROKER_BYTES, PINNED_BROKER_FILE,
    PINNED_BROKER_SHA256, PINNED_MANIFEST_SCHEMA, PINNED_MANIFEST_SHA256, PINNED_MANIFEST_STATUS,
    PINNED_MODEL_BYTES, PINNED_MODEL_FILE, PINNED_MODEL_ID, PINNED_MODEL_REPOSITORY,
    PINNED_MODEL_REVISION, PINNED_MODEL_SHA256, PINNED_RUNTIME_BYTES, PINNED_RUNTIME_ENTRY_COUNT,
    PINNED_RUNTIME_ENTRY_NAMES_SHA256, PINNED_RUNTIME_ID, PINNED_RUNTIME_RELEASE,
    PINNED_RUNTIME_REPOSITORY, PINNED_RUNTIME_REVISION, PINNED_RUNTIME_SHA256,
    RUNTIME_LOOPBACK_HOST, RelativeInstalledPath, RuntimeConfigError, RuntimeLaunchConfig,
    RuntimeLaunchOptions, RuntimeLaunchPlan, TokenReference, build_runtime_launch_plan,
    build_runtime_launch_plan_from_json,
};
pub use mozc_session::MozcSessionBackend;
#[cfg(windows)]
pub use pipe_windows::{WindowsPeerAuthenticator, serve_named_pipe};
pub use protocol::{
    BackendHealth, BrokerRequest, BrokerResponse, CancelRequest, CancelResponse, Candidate,
    CandidateRerankRequest, CandidateRerankResponse, CommitRequest, CommitResponse,
    CompositionState, ConvertRequest, ConvertResponse, CreateSessionRequest, EditAction,
    EditRequest, EditResponse, EnhancementAdmission, EnhancementFeature, EnhancementMetrics,
    EnhancementPolicy, EnhancementReason, EnhancementStatus, ErrorCode, ErrorResponse,
    FallbackMode, FieldClass, FocusLostRequest, FocusLostResponse, GenerationRequest,
    GenerationResponse, HealthRequest, HealthResponse, HealthStatus, KeyEvent, KeyRequest,
    KeyResponse, MAX_ASSIST_CONTEXT_BYTES, MAX_ASSIST_TEXT_BYTES, MAX_CANDIDATES,
    MAX_CLIENT_ID_BYTES, MAX_EDIT_TEXT_BYTES, MAX_ENHANCEMENT_DEADLINE_MS,
    MAX_RERANK_CANDIDATE_BYTES, OperationName, PROTOCOL_VERSION, PrepareRerankSessionRequest,
    ProtocolError, ProviderLocality, RequestCommand, RequestEnvelope, ResponseEnvelope,
    ResponseOutcome, ResponsePayload, SecureFieldPolicy, SemanticAssistRequest,
    SemanticAssistResponse, SemanticIntent, SessionCreated, TextRange, ValidationError,
    decode_request, decode_response, encode_request, encode_response, validate_ai_candidates,
};
pub use queue::{
    EnhancementQueue, EnhancementQueueError, MAX_ENHANCEMENT_QUEUE_CAPACITY,
    MAX_ENHANCEMENT_WORKERS,
};
pub use runtime_supervisor::{
    MAX_RUNTIME_BACKOFF, MAX_RUNTIME_RESTARTS, MAX_STOP_CONFIRM_TIMEOUT, RuntimeChild,
    RuntimeClock, RuntimeFailure, RuntimeProcess, RuntimeProcessError, RuntimeStateSnapshot,
    RuntimeSupervisor, RuntimeSupervisorConfig, RuntimeSupervisorConfigError,
    RuntimeSupervisorError, RuntimeSupervisorState, TokioRuntimeClock,
};
pub use service::serve_authenticated_request;
pub use session::{SessionBackend, SessionBroker, SessionBrokerError};
pub use transport::{
    AUTH_NONCE_BYTES, AuthRequest, AuthResponse, AuthenticatedPeer, AuthenticatedTransport,
    MAX_AUTH_PROOF_BYTES, PeerAuthenticator, SharedSecret, SharedSecretAuthenticator, Transport,
    TransportError, receive_request, receive_response, send_request, send_response,
};
