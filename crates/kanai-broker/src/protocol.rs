//! Versioned, transport-neutral DTOs for the KanaAI broker protocol.
//!
//! This module deliberately contains no Windows APIs.  A future TSF adapter can
//! translate native callbacks into these values, while a broker process can
//! validate and dispatch them without knowing how the peer was connected.

use std::fmt;

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// The only protocol version understood by this crate.
pub const PROTOCOL_VERSION: u16 = 1;

/// Maximum size of a client identifier accepted by the protocol.
pub const MAX_CLIENT_ID_BYTES: usize = 128;
/// Maximum size of a locale identifier accepted by the protocol.
pub const MAX_LOCALE_BYTES: usize = 32;
/// Maximum size of a field-class label accepted by the protocol.
pub const MAX_FIELD_CLASS_BYTES: usize = 64;
/// Maximum size of a key label or character value accepted by the protocol.
pub const MAX_KEY_BYTES: usize = 64;
/// Maximum size of an edit value accepted by the protocol.
pub const MAX_EDIT_TEXT_BYTES: usize = 16 * 1024;
/// Maximum number of candidates in one response.
pub const MAX_CANDIDATES: usize = 128;
/// Maximum candidate page size accepted by the broker.
pub const MAX_PAGE_SIZE: u16 = 64;
/// Maximum page number accepted by the broker.
pub const MAX_PAGE: u32 = 16_384;
/// Maximum deadline for an optional enhancement request.
pub const MAX_ENHANCEMENT_DEADLINE_MS: u32 = 2_000;
/// Maximum policy/provider identifier length.
pub const MAX_PROVIDER_ID_BYTES: usize = 64;
/// Maximum text accepted by the optional semantic assist operation.
pub const MAX_ASSIST_TEXT_BYTES: usize = 4 * 1024;
/// Maximum instruction/context accepted by an optional enhancement.
pub const MAX_ASSIST_CONTEXT_BYTES: usize = 512;
/// Maximum aggregate candidate text accepted by one rerank request/response.
pub const MAX_RERANK_CANDIDATE_BYTES: usize = 64 * 1024;

/// Opaque identifiers are scoped to a broker process and are never assumed to
/// be meaningful across restarts.
pub type SessionId = u64;
pub type RequestId = u64;
pub type CandidateId = u64;
pub type Generation = u64;

/// The privacy class of the host field.  The broker does not inspect the
/// document; the native shell is responsible for reducing it to this enum.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FieldClass {
    Regular,
    Password,
    Protected,
    Search,
    Email,
    Number,
    Other(String),
}

impl FieldClass {
    #[must_use]
    pub fn is_secure(&self) -> bool {
        matches!(self, Self::Password | Self::Protected)
    }

    fn validate(&self) -> Result<(), ValidationError> {
        if let Self::Other(label) = self {
            validate_text("fieldClass", label, MAX_FIELD_CLASS_BYTES)?;
        }
        Ok(())
    }
}

/// A normalized key event.  Native virtual-key codes and keyboard layouts are
/// translated by the shell before they cross this boundary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum KeyEvent {
    Character { value: String },
    Enter,
    Space,
    Backspace,
    Delete,
    Escape,
    Tab,
    Left,
    Right,
    Up,
    Down,
    Function { number: u8 },
    Named { name: String },
}

impl KeyEvent {
    fn validate(&self) -> Result<(), ValidationError> {
        match self {
            Self::Character { value } => validate_text("key.value", value, MAX_KEY_BYTES),
            Self::Named { name } => validate_text("key.name", name, MAX_KEY_BYTES),
            Self::Function { .. } => Ok(()),
            Self::Enter
            | Self::Space
            | Self::Backspace
            | Self::Delete
            | Self::Escape
            | Self::Tab
            | Self::Left
            | Self::Right
            | Self::Up
            | Self::Down => Ok(()),
        }
    }
}

/// Unicode scalar indexes, not UTF-8 byte offsets.  The shell resolves native
/// replacement ranges after it receives a response.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextRange {
    pub start: u32,
    pub end: u32,
}

impl TextRange {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.start > self.end {
            return Err(ValidationError::InvalidRange {
                start: self.start,
                end: self.end,
            });
        }
        Ok(())
    }
}

/// A bounded edit operation supplied by a native text framework.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum EditAction {
    Insert { text: String },
    Replace { range: TextRange, text: String },
    Delete { range: TextRange },
    Reset,
}

impl EditAction {
    fn validate(&self) -> Result<(), ValidationError> {
        match self {
            Self::Insert { text } => validate_text("edit.text", text, MAX_EDIT_TEXT_BYTES),
            Self::Replace { range, text } => {
                range.validate()?;
                validate_text("edit.text", text, MAX_EDIT_TEXT_BYTES)
            }
            Self::Delete { range } => range.validate(),
            Self::Reset => Ok(()),
        }
    }
}

/// Create a broker-owned session for one native input context.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateSessionRequest {
    pub session_id: SessionId,
    pub locale: String,
    pub field_class: FieldClass,
}

impl CreateSessionRequest {
    #[must_use]
    pub fn new(session_id: SessionId, locale: impl Into<String>) -> Self {
        Self {
            session_id,
            locale: locale.into(),
            field_class: FieldClass::Regular,
        }
    }
}

/// Establish a broker-side generation token for a trusted native candidate
/// rerank stream. This is intentionally separate from CreateSession: the
/// supplemental model supplies an already-generated Mozc candidate snapshot
/// and must not create a second Mozc composition owner merely to ask for
/// optional ranking.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareRerankSessionRequest {
    pub session_id: SessionId,
    pub generation: Generation,
    pub field_class: FieldClass,
}

impl PrepareRerankSessionRequest {
    #[must_use]
    pub fn new(session_id: SessionId, generation: Generation) -> Self {
        Self {
            session_id,
            generation,
            field_class: FieldClass::Regular,
        }
    }
}

/// A state-changing key event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyRequest {
    pub session_id: SessionId,
    pub generation: Generation,
    pub key: KeyEvent,
}

/// A state-changing edit event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditRequest {
    pub session_id: SessionId,
    pub generation: Generation,
    pub action: EditAction,
}

/// Ask the backend to convert the current session composition.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConvertRequest {
    pub session_id: SessionId,
    pub generation: Generation,
    pub page: u32,
    pub page_size: u16,
}

impl Default for ConvertRequest {
    fn default() -> Self {
        Self {
            session_id: 0,
            generation: 0,
            page: 0,
            page_size: 9,
        }
    }
}

/// Commit one candidate returned for this session and generation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitRequest {
    pub session_id: SessionId,
    pub generation: Generation,
    pub candidate_id: CandidateId,
}

/// Cancel an outstanding request.  `generation = None` is a control-plane
/// cancellation that is allowed to target work from an older generation; when
/// present it is still checked against the current session generation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CancelRequest {
    pub session_id: SessionId,
    pub target_request_id: Option<RequestId>,
    pub generation: Option<Generation>,
}

impl CancelRequest {
    #[must_use]
    pub fn for_request(session_id: SessionId, target_request_id: RequestId) -> Self {
        Self {
            session_id,
            target_request_id: Some(target_request_id),
            generation: None,
        }
    }
}

/// Tear down ephemeral composition state after focus leaves a native context.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FocusLostRequest {
    pub session_id: SessionId,
    pub generation: Generation,
}

/// A deliberately content-free liveness request.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthRequest {}

/// Read the current monotonic generation without changing session state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationRequest {
    pub session_id: SessionId,
}

/// Policy used when a session is classified as a password or protected field.
/// The broker never relaxes this decision because an optional provider asks.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SecureFieldPolicy {
    #[default]
    Prohibit,
    AllowLocalOnly,
}

/// Optional enhancement policy.  `LocalQualityOnly` names a bounded local
/// provider; it is not a network opt-in and it is never used by the key path.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EnhancementPolicy {
    #[default]
    Disabled,
    LocalQualityOnly,
}

/// Serializable admission snapshot for an optional job.  It is produced from
/// broker-owned session state, never accepted as a client override.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnhancementAdmission {
    pub session_id: SessionId,
    pub generation: Generation,
    pub field_class: FieldClass,
    pub secure_field_policy: SecureFieldPolicy,
}

impl EnhancementAdmission {
    pub fn validate(&self) -> Result<(), ValidationError> {
        validate_id("sessionId", self.session_id)?;
        self.field_class.validate()?;
        if self.field_class.is_secure() && self.secure_field_policy != SecureFieldPolicy::Prohibit {
            return Err(ValidationError::InvalidSecureFieldPolicy);
        }
        Ok(())
    }
}

/// Provider locality is explicit so secure-field admission can reject a
/// remote provider before a request is dispatched.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProviderLocality {
    Local,
    Remote,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EnhancementFeature {
    CandidateRerank,
    SemanticAssist,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EnhancementStatus {
    Applied,
    Fallback,
    Skipped,
    TimedOut,
    Cancelled,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EnhancementReason {
    None,
    SecureField,
    PolicyDisabled,
    ConsentRequired,
    NoBaseline,
    NoChange,
    ProviderTimeout,
    ProviderUnavailable,
    ProviderRejected,
    InvalidResult,
    StaleGeneration,
    Cancelled,
}

/// Measurements are returned even for fallback/skip responses so a caller
/// can compare the Mozc baseline with the optional local quality stage.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnhancementMetrics {
    pub feature: EnhancementFeature,
    pub provider: String,
    pub locality: ProviderLocality,
    pub baseline_latency_micros: u64,
    pub ai_latency_micros: u64,
    pub baseline_candidate_count: u16,
    pub ai_candidate_count: u16,
    pub changed_positions: u16,
    pub adopted_count: u16,
    pub deadline_ms: u32,
}

impl EnhancementMetrics {
    #[must_use]
    pub fn baseline(
        feature: EnhancementFeature,
        provider: impl Into<String>,
        locality: ProviderLocality,
        baseline_candidate_count: u16,
        deadline_ms: u32,
    ) -> Self {
        Self {
            feature,
            provider: provider.into(),
            locality,
            baseline_latency_micros: 0,
            ai_latency_micros: 0,
            baseline_candidate_count,
            ai_candidate_count: baseline_candidate_count,
            changed_positions: 0,
            adopted_count: 0,
            deadline_ms,
        }
    }

    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.baseline_candidate_count as usize > MAX_CANDIDATES
            || self.ai_candidate_count as usize > MAX_CANDIDATES
        {
            return Err(ValidationError::TooManyCandidates {
                count: self.baseline_candidate_count.max(self.ai_candidate_count) as usize,
                max: MAX_CANDIDATES,
            });
        }
        if self.changed_positions > MAX_CANDIDATES as u16
            || self.adopted_count > self.ai_candidate_count
        {
            return Err(ValidationError::InvalidEnhancementMetrics);
        }
        if self.deadline_ms == 0 || self.deadline_ms > MAX_ENHANCEMENT_DEADLINE_MS {
            return Err(ValidationError::InvalidDeadline {
                deadline_ms: self.deadline_ms,
                max: MAX_ENHANCEMENT_DEADLINE_MS,
            });
        }
        validate_text(
            "enhancement.provider",
            &self.provider,
            MAX_PROVIDER_ID_BYTES,
        )
    }
}

/// Bounded candidate rerank request.  The candidate list is the Mozc/baseline
/// result; an implementation may reorder it but may not inject text from an
/// unbounded document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CandidateRerankRequest {
    pub session_id: SessionId,
    pub generation: Generation,
    pub candidates: Vec<Candidate>,
    #[serde(default)]
    pub context_before: String,
    #[serde(default)]
    pub context_after: String,
    pub policy_version: String,
    pub deadline_ms: u32,
    #[serde(default)]
    pub baseline_latency_micros: u64,
}

impl CandidateRerankRequest {
    #[must_use]
    pub fn new(session_id: SessionId, generation: Generation, candidates: Vec<Candidate>) -> Self {
        Self {
            session_id,
            generation,
            candidates,
            context_before: String::new(),
            context_after: String::new(),
            policy_version: "v1".to_owned(),
            deadline_ms: 250,
            baseline_latency_micros: 0,
        }
    }

    pub fn validate(&self) -> Result<(), ValidationError> {
        validate_id("sessionId", self.session_id)?;
        validate_candidate_list(&self.candidates)?;
        validate_text_allow_empty(
            "rerank.contextBefore",
            &self.context_before,
            MAX_ASSIST_CONTEXT_BYTES,
        )?;
        validate_text_allow_empty(
            "rerank.contextAfter",
            &self.context_after,
            MAX_ASSIST_CONTEXT_BYTES,
        )?;
        validate_text(
            "rerank.policyVersion",
            &self.policy_version,
            MAX_PROVIDER_ID_BYTES,
        )?;
        validate_deadline(self.deadline_ms)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SemanticIntent {
    Rewrite,
    Explain,
    Suggest,
    Repair,
}

/// Explicit, user-triggered semantic assist.  This is not a key callback and
/// is rejected/skipped for secure fields before any provider is called.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticAssistRequest {
    pub session_id: SessionId,
    pub generation: Generation,
    pub intent: SemanticIntent,
    pub text: String,
    #[serde(default)]
    pub instruction: String,
    #[serde(default)]
    pub context_before: String,
    #[serde(default)]
    pub context_after: String,
    pub policy_version: String,
    pub deadline_ms: u32,
    #[serde(default)]
    pub baseline_latency_micros: u64,
    pub consent: bool,
}

impl SemanticAssistRequest {
    #[must_use]
    pub fn new(
        session_id: SessionId,
        generation: Generation,
        intent: SemanticIntent,
        text: impl Into<String>,
    ) -> Self {
        Self {
            session_id,
            generation,
            intent,
            text: text.into(),
            instruction: String::new(),
            context_before: String::new(),
            context_after: String::new(),
            policy_version: "v1".to_owned(),
            deadline_ms: 500,
            baseline_latency_micros: 0,
            consent: true,
        }
    }

    pub fn validate(&self) -> Result<(), ValidationError> {
        validate_id("sessionId", self.session_id)?;
        validate_text("assist.text", &self.text, MAX_ASSIST_TEXT_BYTES)?;
        validate_text_allow_empty(
            "assist.instruction",
            &self.instruction,
            MAX_ASSIST_CONTEXT_BYTES,
        )?;
        validate_text_allow_empty(
            "assist.contextBefore",
            &self.context_before,
            MAX_ASSIST_CONTEXT_BYTES,
        )?;
        validate_text_allow_empty(
            "assist.contextAfter",
            &self.context_after,
            MAX_ASSIST_CONTEXT_BYTES,
        )?;
        validate_text(
            "assist.policyVersion",
            &self.policy_version,
            MAX_PROVIDER_ID_BYTES,
        )?;
        validate_deadline(self.deadline_ms)
    }
}

/// The command carried by a request envelope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "operation", content = "payload", rename_all = "camelCase")]
pub enum RequestCommand {
    CreateSession(CreateSessionRequest),
    PrepareRerankSession(PrepareRerankSessionRequest),
    Key(KeyRequest),
    Edit(EditRequest),
    Convert(ConvertRequest),
    Commit(CommitRequest),
    Cancel(CancelRequest),
    FocusLost(FocusLostRequest),
    Health(HealthRequest),
    Generation(GenerationRequest),
    RerankCandidates(CandidateRerankRequest),
    SemanticAssist(SemanticAssistRequest),
}

impl RequestCommand {
    #[must_use]
    pub fn operation(&self) -> &'static str {
        match self {
            Self::CreateSession(_) => "createSession",
            Self::PrepareRerankSession(_) => "prepareRerankSession",
            Self::Key(_) => "key",
            Self::Edit(_) => "edit",
            Self::Convert(_) => "convert",
            Self::Commit(_) => "commit",
            Self::Cancel(_) => "cancel",
            Self::FocusLost(_) => "focusLost",
            Self::Health(_) => "health",
            Self::Generation(_) => "generation",
            Self::RerankCandidates(_) => "rerankCandidates",
            Self::SemanticAssist(_) => "semanticAssist",
        }
    }

    #[must_use]
    pub fn session_id(&self) -> Option<SessionId> {
        match self {
            Self::CreateSession(request) => Some(request.session_id),
            Self::PrepareRerankSession(request) => Some(request.session_id),
            Self::Key(request) => Some(request.session_id),
            Self::Edit(request) => Some(request.session_id),
            Self::Convert(request) => Some(request.session_id),
            Self::Commit(request) => Some(request.session_id),
            Self::Cancel(request) => Some(request.session_id),
            Self::FocusLost(request) => Some(request.session_id),
            Self::Health(_) => None,
            Self::Generation(request) => Some(request.session_id),
            Self::RerankCandidates(request) => Some(request.session_id),
            Self::SemanticAssist(request) => Some(request.session_id),
        }
    }

    #[must_use]
    pub fn expected_generation(&self) -> Option<Generation> {
        match self {
            Self::PrepareRerankSession(request) => Some(request.generation),
            Self::Key(request) => Some(request.generation),
            Self::Edit(request) => Some(request.generation),
            Self::Convert(request) => Some(request.generation),
            Self::Commit(request) => Some(request.generation),
            Self::Cancel(request) => request.generation,
            Self::FocusLost(request) => Some(request.generation),
            Self::RerankCandidates(request) => Some(request.generation),
            Self::SemanticAssist(request) => Some(request.generation),
            Self::CreateSession(_) | Self::Health(_) | Self::Generation(_) => None,
        }
    }

    /// Validate all request-local limits before a backend is called.
    pub fn validate(&self) -> Result<(), ValidationError> {
        match self {
            Self::CreateSession(request) => {
                validate_id("sessionId", request.session_id)?;
                validate_text("locale", &request.locale, MAX_LOCALE_BYTES)?;
                request.field_class.validate()
            }
            Self::PrepareRerankSession(request) => {
                validate_id("sessionId", request.session_id)?;
                request.field_class.validate()
            }
            Self::Key(request) => {
                validate_id("sessionId", request.session_id)?;
                request.key.validate()
            }
            Self::Edit(request) => {
                validate_id("sessionId", request.session_id)?;
                request.action.validate()
            }
            Self::Convert(request) => {
                validate_id("sessionId", request.session_id)?;
                if request.page > MAX_PAGE {
                    return Err(ValidationError::PageOutOfRange {
                        page: request.page,
                        max: MAX_PAGE,
                    });
                }
                if request.page_size == 0 || request.page_size > MAX_PAGE_SIZE {
                    return Err(ValidationError::PageSizeOutOfRange {
                        page_size: request.page_size,
                        max: MAX_PAGE_SIZE,
                    });
                }
                Ok(())
            }
            Self::Commit(request) => {
                validate_id("sessionId", request.session_id)?;
                validate_id("candidateId", request.candidate_id)
            }
            Self::Cancel(request) => {
                validate_id("sessionId", request.session_id)?;
                if let Some(target) = request.target_request_id {
                    validate_id("targetRequestId", target)?;
                }
                Ok(())
            }
            Self::FocusLost(request) => validate_id("sessionId", request.session_id),
            Self::Health(_) => Ok(()),
            Self::Generation(request) => validate_id("sessionId", request.session_id),
            Self::RerankCandidates(request) => request.validate(),
            Self::SemanticAssist(request) => request.validate(),
        }
    }
}

/// Versioned request envelope.  The broker rejects unknown versions before it
/// interprets the command payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestEnvelope {
    pub version: u16,
    pub request_id: RequestId,
    pub command: RequestCommand,
}

impl RequestEnvelope {
    #[must_use]
    pub fn new(request_id: RequestId, command: RequestCommand) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id,
            command,
        }
    }

    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.version != PROTOCOL_VERSION {
            return Err(ValidationError::UnsupportedVersion {
                expected: PROTOCOL_VERSION,
                actual: self.version,
            });
        }
        validate_id("requestId", self.request_id)?;
        self.command.validate()
    }
}

/// A candidate is scoped to the generation in which it was returned.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub id: CandidateId,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reading: Option<String>,
    pub rank: u16,
}

impl Candidate {
    pub fn validate(&self) -> Result<(), ValidationError> {
        validate_id("candidate.id", self.id)?;
        validate_text("candidate.text", &self.text, MAX_EDIT_TEXT_BYTES)?;
        if let Some(reading) = &self.reading {
            validate_text("candidate.reading", reading, MAX_EDIT_TEXT_BYTES)?;
        }
        Ok(())
    }
}

/// The normalized composition state returned by a backend.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompositionState {
    pub preedit: String,
    pub consumed: bool,
    #[serde(default)]
    pub candidates: Vec<Candidate>,
    #[serde(default)]
    pub focused_index: Option<usize>,
}

impl CompositionState {
    pub fn validate(&self) -> Result<(), ValidationError> {
        validate_text_allow_empty("preedit", &self.preedit, MAX_EDIT_TEXT_BYTES)?;
        if self.candidates.len() > MAX_CANDIDATES {
            return Err(ValidationError::TooManyCandidates {
                count: self.candidates.len(),
                max: MAX_CANDIDATES,
            });
        }
        for candidate in &self.candidates {
            candidate.validate()?;
        }
        if self
            .focused_index
            .is_some_and(|index| index >= self.candidates.len())
        {
            return Err(ValidationError::InvalidFocusedIndex {
                index: self.focused_index.unwrap_or_default(),
                count: self.candidates.len(),
            });
        }
        Ok(())
    }
}

/// Fallback is explicit in every operation response so a shell never has to
/// infer a degraded mode from a timeout or a provider-specific error.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FallbackMode {
    None,
    DirectInput,
    #[default]
    LastValidPreedit,
}

/// Public, content-free error categories suitable for a native shell.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ErrorCode {
    InvalidRequest,
    UnsupportedVersion,
    Unauthenticated,
    UnknownSession,
    AlreadyExists,
    StaleGeneration,
    GenerationExhausted,
    Cancelled,
    BackendUnavailable,
    BackendTimeout,
    BackendProtocol,
    EnhancementRequiresAsync,
    Internal,
}

/// Error details intentionally contain no composition text or backend secret.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorResponse {
    pub code: ErrorCode,
    pub message: String,
    pub retryable: bool,
    pub fallback: FallbackMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_generation: Option<Generation>,
}

impl ErrorResponse {
    #[must_use]
    pub fn new(code: ErrorCode, message: impl Into<String>, retryable: bool) -> Self {
        Self {
            code,
            message: message.into(),
            retryable,
            fallback: FallbackMode::None,
            current_generation: None,
        }
    }

    #[must_use]
    pub fn with_fallback(mut self, fallback: FallbackMode) -> Self {
        self.fallback = fallback;
        self
    }

    #[must_use]
    pub fn with_generation(mut self, generation: Option<Generation>) -> Self {
        self.current_generation = generation;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCreated {
    pub session_id: SessionId,
    pub generation: Generation,
    pub fallback: FallbackMode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyResponse {
    pub session_id: SessionId,
    pub generation: Generation,
    pub preedit: String,
    pub consumed: bool,
    #[serde(default)]
    pub candidates: Vec<Candidate>,
    #[serde(default)]
    pub focused_index: Option<usize>,
    pub fallback: FallbackMode,
}

impl KeyResponse {
    pub(crate) fn state(&self) -> CompositionState {
        CompositionState {
            preedit: self.preedit.clone(),
            consumed: self.consumed,
            candidates: self.candidates.clone(),
            focused_index: self.focused_index,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditResponse {
    pub session_id: SessionId,
    pub generation: Generation,
    pub preedit: String,
    pub consumed: bool,
    #[serde(default)]
    pub candidates: Vec<Candidate>,
    #[serde(default)]
    pub focused_index: Option<usize>,
    pub fallback: FallbackMode,
}

impl EditResponse {
    pub(crate) fn state(&self) -> CompositionState {
        CompositionState {
            preedit: self.preedit.clone(),
            consumed: self.consumed,
            candidates: self.candidates.clone(),
            focused_index: self.focused_index,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConvertResponse {
    pub session_id: SessionId,
    pub generation: Generation,
    pub preedit: String,
    pub consumed: bool,
    #[serde(default)]
    pub candidates: Vec<Candidate>,
    #[serde(default)]
    pub focused_index: Option<usize>,
    pub page: u32,
    pub page_size: u16,
    pub has_more: bool,
    pub fallback: FallbackMode,
}

impl ConvertResponse {
    pub(crate) fn state(&self) -> CompositionState {
        CompositionState {
            preedit: self.preedit.clone(),
            consumed: self.consumed,
            candidates: self.candidates.clone(),
            focused_index: self.focused_index,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitResponse {
    pub session_id: SessionId,
    pub generation: Generation,
    pub text: String,
    pub consumed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CancelResponse {
    pub session_id: SessionId,
    pub generation: Generation,
    pub target_request_id: Option<RequestId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FocusLostResponse {
    pub session_id: SessionId,
    pub generation: Generation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HealthStatus {
    Ready,
    Degraded,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthResponse {
    pub status: HealthStatus,
    pub protocol_version: u16,
    pub max_frame_bytes: u32,
    pub fallback: FallbackMode,
    pub detail: String,
}

impl HealthResponse {
    #[must_use]
    pub fn ready(max_frame_bytes: usize) -> Self {
        Self {
            status: HealthStatus::Ready,
            protocol_version: PROTOCOL_VERSION,
            max_frame_bytes: u32::try_from(max_frame_bytes).unwrap_or(u32::MAX),
            fallback: FallbackMode::None,
            detail: "ready".to_owned(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationResponse {
    pub session_id: SessionId,
    pub generation: Generation,
}

/// Baseline and optional-AI candidate orders are both retained so a caller
/// can measure quality/latency without trusting an opaque model decision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CandidateRerankResponse {
    pub session_id: SessionId,
    pub generation: Generation,
    pub status: EnhancementStatus,
    pub baseline: Vec<Candidate>,
    pub ai: Vec<Candidate>,
    pub adopted: bool,
    pub metrics: EnhancementMetrics,
    pub fallback: FallbackMode,
    pub reason: EnhancementReason,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticAssistResponse {
    pub session_id: SessionId,
    pub generation: Generation,
    pub status: EnhancementStatus,
    pub baseline_text: String,
    pub assist: Option<String>,
    pub applied: bool,
    pub metrics: EnhancementMetrics,
    pub fallback: FallbackMode,
    pub reason: EnhancementReason,
}

/// A successful operation payload.  The operation tag mirrors the request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "operation", content = "payload", rename_all = "camelCase")]
pub enum ResponsePayload {
    Created(SessionCreated),
    Key(KeyResponse),
    Edit(EditResponse),
    Convert(ConvertResponse),
    Commit(CommitResponse),
    Cancel(CancelResponse),
    FocusLost(FocusLostResponse),
    Health(HealthResponse),
    Generation(GenerationResponse),
    RerankCandidates(CandidateRerankResponse),
    SemanticAssist(SemanticAssistResponse),
}

impl ResponsePayload {
    #[must_use]
    pub fn operation(&self) -> &'static str {
        match self {
            Self::Created(_) => "createSession",
            Self::Key(_) => "key",
            Self::Edit(_) => "edit",
            Self::Convert(_) => "convert",
            Self::Commit(_) => "commit",
            Self::Cancel(_) => "cancel",
            Self::FocusLost(_) => "focusLost",
            Self::Health(_) => "health",
            Self::Generation(_) => "generation",
            Self::RerankCandidates(_) => "rerankCandidates",
            Self::SemanticAssist(_) => "semanticAssist",
        }
    }

    #[must_use]
    pub fn session_id(&self) -> Option<SessionId> {
        match self {
            Self::Created(response) => Some(response.session_id),
            Self::Key(response) => Some(response.session_id),
            Self::Edit(response) => Some(response.session_id),
            Self::Convert(response) => Some(response.session_id),
            Self::Commit(response) => Some(response.session_id),
            Self::Cancel(response) => Some(response.session_id),
            Self::FocusLost(response) => Some(response.session_id),
            Self::Health(_) => None,
            Self::Generation(response) => Some(response.session_id),
            Self::RerankCandidates(response) => Some(response.session_id),
            Self::SemanticAssist(response) => Some(response.session_id),
        }
    }

    #[must_use]
    pub fn generation(&self) -> Option<Generation> {
        match self {
            Self::Created(response) => Some(response.generation),
            Self::Key(response) => Some(response.generation),
            Self::Edit(response) => Some(response.generation),
            Self::Convert(response) => Some(response.generation),
            Self::Commit(response) => Some(response.generation),
            Self::Cancel(response) => Some(response.generation),
            Self::FocusLost(response) => Some(response.generation),
            Self::Health(_) => None,
            Self::Generation(response) => Some(response.generation),
            Self::RerankCandidates(response) => Some(response.generation),
            Self::SemanticAssist(response) => Some(response.generation),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ResponseOutcome {
    Success(ResponsePayload),
    Failure(ErrorResponse),
}

/// Versioned response envelope.  `generation` is included at the envelope
/// level so a shell can discard a response even when it does not inspect the
/// operation-specific payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResponseEnvelope {
    pub version: u16,
    pub request_id: RequestId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation: Option<Generation>,
    pub outcome: ResponseOutcome,
}

impl ResponseEnvelope {
    #[must_use]
    pub fn success(request_id: RequestId, payload: ResponsePayload) -> Self {
        let generation = payload.generation();
        Self {
            version: PROTOCOL_VERSION,
            request_id,
            generation,
            outcome: ResponseOutcome::Success(payload),
        }
    }

    #[must_use]
    pub fn failure(
        request_id: RequestId,
        generation: Option<Generation>,
        error: ErrorResponse,
    ) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id,
            generation,
            outcome: ResponseOutcome::Failure(error),
        }
    }

    #[must_use]
    pub fn payload(&self) -> Option<&ResponsePayload> {
        match &self.outcome {
            ResponseOutcome::Success(payload) => Some(payload),
            ResponseOutcome::Failure(_) => None,
        }
    }

    #[must_use]
    pub fn error(&self) -> Option<&ErrorResponse> {
        match &self.outcome {
            ResponseOutcome::Success(_) => None,
            ResponseOutcome::Failure(error) => Some(error),
        }
    }

    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.version != PROTOCOL_VERSION {
            return Err(ValidationError::UnsupportedVersion {
                expected: PROTOCOL_VERSION,
                actual: self.version,
            });
        }
        match &self.outcome {
            ResponseOutcome::Success(payload) => {
                validate_id("requestId", self.request_id)?;
                if let (Some(envelope), Some(payload)) = (self.generation, payload.generation())
                    && envelope != payload
                {
                    return Err(ValidationError::GenerationMismatch { envelope, payload });
                }
                payload.validate()
            }
            ResponseOutcome::Failure(error) => {
                validate_text("error.message", &error.message, 512)?;
                if let (Some(envelope), Some(current)) = (self.generation, error.current_generation)
                    && envelope != current
                {
                    return Err(ValidationError::GenerationMismatch {
                        envelope,
                        payload: current,
                    });
                }
                Ok(())
            }
        }
    }
}

/// Names used by backend adapters so they do not need to depend on the
/// transport envelope types directly.
pub type BrokerRequest = RequestCommand;
pub type BrokerResponse = ResponsePayload;
/// Health is kept as an alias for backend implementors that expose it outside
/// the wire response enum.
pub type BackendHealth = HealthResponse;

impl ResponsePayload {
    pub fn validate(&self) -> Result<(), ValidationError> {
        match self {
            Self::Created(response) => {
                validate_id("sessionId", response.session_id)?;
                Ok(())
            }
            Self::Key(response) => {
                validate_id("sessionId", response.session_id)?;
                validate_composition_response(
                    &response.preedit,
                    &response.candidates,
                    response.focused_index,
                )
            }
            Self::Edit(response) => {
                validate_id("sessionId", response.session_id)?;
                validate_composition_response(
                    &response.preedit,
                    &response.candidates,
                    response.focused_index,
                )
            }
            Self::Convert(response) => {
                validate_id("sessionId", response.session_id)?;
                validate_composition_response(
                    &response.preedit,
                    &response.candidates,
                    response.focused_index,
                )?;
                if response.page > MAX_PAGE {
                    return Err(ValidationError::PageOutOfRange {
                        page: response.page,
                        max: MAX_PAGE,
                    });
                }
                if response.page_size == 0 || response.page_size > MAX_PAGE_SIZE {
                    return Err(ValidationError::PageSizeOutOfRange {
                        page_size: response.page_size,
                        max: MAX_PAGE_SIZE,
                    });
                }
                Ok(())
            }
            Self::Commit(response) => {
                validate_id("sessionId", response.session_id)?;
                validate_text("commit.text", &response.text, MAX_EDIT_TEXT_BYTES)
            }
            Self::Cancel(response) => {
                validate_id("sessionId", response.session_id)?;
                if let Some(target) = response.target_request_id {
                    validate_id("targetRequestId", target)?;
                }
                Ok(())
            }
            Self::FocusLost(response) => validate_id("sessionId", response.session_id),
            Self::Health(response) => {
                if response.protocol_version != PROTOCOL_VERSION {
                    return Err(ValidationError::UnsupportedVersion {
                        expected: PROTOCOL_VERSION,
                        actual: response.protocol_version,
                    });
                }
                if response.max_frame_bytes == 0 {
                    return Err(ValidationError::InvalidFrameLimit {
                        max: response.max_frame_bytes,
                    });
                }
                validate_text("health.detail", &response.detail, 512)
            }
            Self::Generation(response) => validate_id("sessionId", response.session_id),
            Self::RerankCandidates(response) => {
                validate_id("sessionId", response.session_id)?;
                validate_candidate_list(&response.baseline)?;
                validate_candidate_list(&response.ai)?;
                validate_ai_candidates(&response.baseline, &response.ai)?;
                if response.metrics.feature != EnhancementFeature::CandidateRerank
                    || response.metrics.baseline_candidate_count as usize != response.baseline.len()
                    || response.metrics.ai_candidate_count as usize != response.ai.len()
                {
                    return Err(ValidationError::InvalidEnhancementMetrics);
                }
                response.metrics.validate()
            }
            Self::SemanticAssist(response) => {
                validate_id("sessionId", response.session_id)?;
                validate_text_allow_empty(
                    "assist.baselineText",
                    &response.baseline_text,
                    MAX_ASSIST_TEXT_BYTES,
                )?;
                if let Some(assist) = &response.assist {
                    validate_text("assist.assist", assist, MAX_ASSIST_TEXT_BYTES)?;
                }
                if response.applied && response.assist.is_none() {
                    return Err(ValidationError::MissingAssistText);
                }
                if response.metrics.feature != EnhancementFeature::SemanticAssist
                    || response.metrics.baseline_candidate_count != 0
                    || response.metrics.ai_candidate_count != 0
                {
                    return Err(ValidationError::InvalidEnhancementMetrics);
                }
                response.metrics.validate()
            }
        }
    }
}

fn validate_composition_response(
    preedit: &str,
    candidates: &[Candidate],
    focused_index: Option<usize>,
) -> Result<(), ValidationError> {
    validate_text_allow_empty("preedit", preedit, MAX_EDIT_TEXT_BYTES)?;
    if candidates.len() > MAX_CANDIDATES {
        return Err(ValidationError::TooManyCandidates {
            count: candidates.len(),
            max: MAX_CANDIDATES,
        });
    }
    for candidate in candidates {
        candidate.validate()?;
    }
    if focused_index.is_some_and(|index| index >= candidates.len()) {
        return Err(ValidationError::InvalidFocusedIndex {
            index: focused_index.unwrap_or_default(),
            count: candidates.len(),
        });
    }
    Ok(())
}

fn validate_deadline(deadline_ms: u32) -> Result<(), ValidationError> {
    if deadline_ms == 0 || deadline_ms > MAX_ENHANCEMENT_DEADLINE_MS {
        return Err(ValidationError::InvalidDeadline {
            deadline_ms,
            max: MAX_ENHANCEMENT_DEADLINE_MS,
        });
    }
    Ok(())
}

fn validate_candidate_list(candidates: &[Candidate]) -> Result<(), ValidationError> {
    if candidates.len() > MAX_CANDIDATES {
        return Err(ValidationError::TooManyCandidates {
            count: candidates.len(),
            max: MAX_CANDIDATES,
        });
    }
    let mut total_bytes = 0_usize;
    for (index, candidate) in candidates.iter().enumerate() {
        candidate.validate()?;
        total_bytes = total_bytes
            .checked_add(candidate.text.len())
            .and_then(|size| size.checked_add(candidate.reading.as_ref().map_or(0, String::len)))
            .ok_or(ValidationError::RerankCandidateBytesTooLarge {
                size: usize::MAX,
                max: MAX_RERANK_CANDIDATE_BYTES,
            })?;
        if total_bytes > MAX_RERANK_CANDIDATE_BYTES {
            return Err(ValidationError::RerankCandidateBytesTooLarge {
                size: total_bytes,
                max: MAX_RERANK_CANDIDATE_BYTES,
            });
        }
        if candidates[..index]
            .iter()
            .any(|prior| prior.id == candidate.id)
        {
            return Err(ValidationError::DuplicateCandidateId(candidate.id));
        }
    }
    Ok(())
}

/// Validate that an AI order is a complete permutation of the exact baseline
/// candidates; a provider may reorder candidates but may not edit or inject
/// candidate content.
pub fn validate_ai_candidates(
    baseline: &[Candidate],
    ai: &[Candidate],
) -> Result<(), ValidationError> {
    if baseline.len() != ai.len() {
        return Err(ValidationError::RerankMustBePermutation {
            baseline: baseline.len(),
            ai: ai.len(),
        });
    }
    let mut seen = vec![false; baseline.len()];
    for candidate in ai {
        let Some(index) = baseline.iter().position(|prior| prior == candidate) else {
            if baseline.iter().any(|prior| prior.id == candidate.id) {
                return Err(ValidationError::RerankCandidateMutated(candidate.id));
            }
            return Err(ValidationError::UnknownEnhancementCandidate(candidate.id));
        };
        if seen[index] {
            return Err(ValidationError::DuplicateCandidateId(candidate.id));
        }
        seen[index] = true;
    }
    Ok(())
}

fn validate_id(field: &'static str, value: u64) -> Result<(), ValidationError> {
    if value == 0 {
        return Err(ValidationError::InvalidId { field });
    }
    Ok(())
}

fn validate_text(
    field: &'static str,
    value: &str,
    max_bytes: usize,
) -> Result<(), ValidationError> {
    if value.is_empty() {
        return Err(ValidationError::EmptyText { field });
    }
    validate_text_allow_empty(field, value, max_bytes)
}

fn validate_text_allow_empty(
    field: &'static str,
    value: &str,
    max_bytes: usize,
) -> Result<(), ValidationError> {
    if value.len() > max_bytes {
        return Err(ValidationError::TextTooLong {
            field,
            length: value.len(),
            max: max_bytes,
        });
    }
    if value.chars().any(|character| character.is_control()) {
        return Err(ValidationError::ControlCharacter { field });
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ValidationError {
    #[error("unsupported protocol version {actual}; expected {expected}")]
    UnsupportedVersion { expected: u16, actual: u16 },
    #[error("{field} must be greater than zero")]
    InvalidId { field: &'static str },
    #[error("{field} must not be empty")]
    EmptyText { field: &'static str },
    #[error("{field} is too long ({length} bytes; maximum {max})")]
    TextTooLong {
        field: &'static str,
        length: usize,
        max: usize,
    },
    #[error("{field} contains a control character")]
    ControlCharacter { field: &'static str },
    #[error("invalid text range {start}..{end}")]
    InvalidRange { start: u32, end: u32 },
    #[error("candidate page {page} exceeds maximum {max}")]
    PageOutOfRange { page: u32, max: u32 },
    #[error("candidate page size {page_size} is outside 1..={max}")]
    PageSizeOutOfRange { page_size: u16, max: u16 },
    #[error("response contains {count} candidates; maximum is {max}")]
    TooManyCandidates { count: usize, max: usize },
    #[error("focused candidate index {index} is outside {count} candidates")]
    InvalidFocusedIndex { index: usize, count: usize },
    #[error("invalid frame limit {max}")]
    InvalidFrameLimit { max: u32 },
    #[error("response generation {envelope} does not match payload generation {payload}")]
    GenerationMismatch { envelope: u64, payload: u64 },
    #[error("candidate id {0} occurs more than once")]
    DuplicateCandidateId(u64),
    #[error("AI candidate id {0} was not present in the baseline")]
    UnknownEnhancementCandidate(u64),
    #[error("AI candidate id {0} changed a baseline field")]
    RerankCandidateMutated(u64),
    #[error("AI candidates must be a complete permutation ({baseline} baseline, {ai} AI)")]
    RerankMustBePermutation { baseline: usize, ai: usize },
    #[error("rerank candidate payload is too large ({size} bytes; maximum {max})")]
    RerankCandidateBytesTooLarge { size: usize, max: usize },
    #[error("enhancement deadline {deadline_ms} ms is outside 1..={max}")]
    InvalidDeadline { deadline_ms: u32, max: u32 },
    #[error("enhancement metrics are outside bounded limits")]
    InvalidEnhancementMetrics,
    #[error("secure field admission must prohibit optional enhancement")]
    InvalidSecureFieldPolicy,
    #[error("semantic assist response has no assist text")]
    MissingAssistText,
}

/// Errors produced while converting a DTO to or from its bounded wire frame.
#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("failed to encode protocol JSON: {0}")]
    Encode(serde_json::Error),
    #[error("failed to decode protocol JSON: {0}")]
    Decode(serde_json::Error),
    #[error("protocol validation failed: {0}")]
    Validation(#[from] ValidationError),
    #[error("frame error: {0}")]
    Frame(#[from] crate::frame::FrameError),
}

/// Encode a request after validating its version and bounded fields.
pub fn encode_request(request: &RequestEnvelope) -> Result<Vec<u8>, ProtocolError> {
    request.validate()?;
    serde_json::to_vec(request).map_err(ProtocolError::Encode)
}

/// Decode and validate a request payload.  Framing must be handled by
/// [`crate::frame::FrameCodec`] or a [`crate::transport::Transport`] adapter.
pub fn decode_request(bytes: &[u8]) -> Result<RequestEnvelope, ProtocolError> {
    let request: RequestEnvelope = serde_json::from_slice(bytes).map_err(ProtocolError::Decode)?;
    request.validate()?;
    Ok(request)
}

/// Encode a response after validating its version and bounded fields.
pub fn encode_response(response: &ResponseEnvelope) -> Result<Vec<u8>, ProtocolError> {
    response.validate()?;
    serde_json::to_vec(response).map_err(ProtocolError::Encode)
}

/// Decode and validate a response payload.
pub fn decode_response(bytes: &[u8]) -> Result<ResponseEnvelope, ProtocolError> {
    let response: ResponseEnvelope =
        serde_json::from_slice(bytes).map_err(ProtocolError::Decode)?;
    response.validate()?;
    Ok(response)
}

/// A small display helper for native adapters that want a stable operation
/// name without matching the enum again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OperationName(pub &'static str);

impl fmt::Display for OperationName {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.0)
    }
}
