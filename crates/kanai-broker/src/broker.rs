//! Deterministic session/generation orchestration for broker requests.
//!
//! `Broker` owns request validation, session lifetime, generation checks, and
//! fallback decisions.  A backend implements only normalized request handling;
//! it does not get to accept stale requests or silently select another service.

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use thiserror::Error;

use crate::protocol::{
    BackendHealth, BrokerRequest, BrokerResponse, CancelRequest, Candidate, CommitRequest,
    CompositionState, ConvertRequest, ConvertResponse, CreateSessionRequest, EditAction,
    EditRequest, EditResponse, EnhancementAdmission, ErrorCode, ErrorResponse, FallbackMode,
    FieldClass, FocusLostRequest, FocusLostResponse, GenerationRequest, GenerationResponse,
    HealthResponse, HealthStatus, KeyEvent, KeyRequest, KeyResponse, PROTOCOL_VERSION,
    RequestCommand, RequestEnvelope, ResponseEnvelope, ResponsePayload, SecureFieldPolicy,
    SessionCreated, ValidationError,
};

/// A cooperative cancellation token.  Backends should check it before and
/// after expensive work and must not mutate broker state after returning
/// `Cancelled`.
#[derive(Clone, Default)]
pub struct CancellationToken {
    cancelled: Arc<AtomicBool>,
}

impl CancellationToken {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }
}

impl fmt::Debug for CancellationToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CancellationToken")
            .field("cancelled", &self.is_cancelled())
            .finish()
    }
}

/// An in-process registry for cancellation across a broker executor and a
/// transport-facing cancel command.  The wire adapter can call
/// [`CancellationRegistry::cancel`] when it receives a cancel request.
#[derive(Clone, Default)]
pub struct CancellationRegistry {
    tokens: Arc<Mutex<HashMap<u64, CancellationToken>>>,
}

impl CancellationRegistry {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(
        &self,
        request_id: u64,
        token: CancellationToken,
    ) -> Result<(), CancellationError> {
        let mut tokens = lock_unpoisoned(&self.tokens);
        if tokens.contains_key(&request_id) {
            return Err(CancellationError::DuplicateRequest(request_id));
        }
        tokens.insert(request_id, token);
        Ok(())
    }

    pub fn finish(&self, request_id: u64) {
        let mut tokens = lock_unpoisoned(&self.tokens);
        tokens.remove(&request_id);
    }

    pub fn cancel(&self, request_id: u64) -> bool {
        let token = lock_unpoisoned(&self.tokens).get(&request_id).cloned();
        if let Some(token) = token {
            token.cancel();
            true
        } else {
            false
        }
    }

    #[must_use]
    pub fn active_requests(&self) -> usize {
        lock_unpoisoned(&self.tokens).len()
    }
}

impl fmt::Debug for CancellationRegistry {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CancellationRegistry")
            .field("active_requests", &self.active_requests())
            .finish()
    }
}

/// A generation snapshot that can be held by an optional enhancement job.
/// The broker updates the shared clock before it starts each state-changing
/// operation, so a model result is discarded even if the job finishes after a
/// newer key/edit or after focus teardown.
#[derive(Clone)]
pub struct GenerationToken {
    session_id: u64,
    generation: u64,
    clock: Arc<AtomicU64>,
    active: Arc<AtomicBool>,
    field_class: FieldClass,
    secure_field_policy: SecureFieldPolicy,
}

impl GenerationToken {
    #[must_use]
    pub fn session_id(&self) -> u64 {
        self.session_id
    }

    #[must_use]
    pub fn generation(&self) -> u64 {
        self.generation
    }

    #[must_use]
    pub fn current_generation(&self) -> u64 {
        self.clock.load(Ordering::Acquire)
    }

    #[must_use]
    pub fn is_current(&self) -> bool {
        self.active.load(Ordering::Acquire) && self.current_generation() == self.generation
    }

    #[must_use]
    pub fn field_class(&self) -> &FieldClass {
        &self.field_class
    }

    #[must_use]
    pub fn secure_field_policy(&self) -> SecureFieldPolicy {
        self.secure_field_policy
    }

    #[must_use]
    pub fn admission(&self) -> EnhancementAdmission {
        EnhancementAdmission {
            session_id: self.session_id,
            generation: self.generation,
            field_class: self.field_class.clone(),
            secure_field_policy: self.secure_field_policy,
        }
    }
}

impl fmt::Debug for GenerationToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GenerationToken")
            .field("session_id", &self.session_id)
            .field("generation", &self.generation)
            .field("current_generation", &self.current_generation())
            .field("active", &self.active.load(Ordering::Acquire))
            .field("field_class", &self.field_class)
            .field("secure_field_policy", &self.secure_field_policy)
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CancellationError {
    #[error("request {0} is already active")]
    DuplicateRequest(u64),
}

/// Backend failures are deliberately separate from wire validation failures.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BackendError {
    #[error("conversion backend is unavailable: {0}")]
    Unavailable(String),
    #[error("conversion backend timed out")]
    Timeout,
    #[error("conversion backend was cancelled")]
    Cancelled,
    #[error("conversion backend returned an invalid response: {0}")]
    Protocol(String),
}

impl BackendError {
    fn error_code(&self) -> ErrorCode {
        match self {
            Self::Unavailable(_) => ErrorCode::BackendUnavailable,
            Self::Timeout => ErrorCode::BackendTimeout,
            Self::Cancelled => ErrorCode::Cancelled,
            Self::Protocol(_) => ErrorCode::BackendProtocol,
        }
    }
}

/// The backend seam is platform-neutral.  A future broker process can adapt
/// Mozc or another local provider to this trait without exposing its protocol
/// to a TSF DLL.
pub trait BrokerBackend: Send {
    fn execute(
        &mut self,
        request: &BrokerRequest,
        cancellation: &CancellationToken,
    ) -> Result<BrokerResponse, BackendError>;

    fn health(&self) -> BackendHealth {
        BackendHealth::ready(crate::frame::DEFAULT_MAX_FRAME_BYTES)
    }
}

/// Fallback policy for backend failures.  It never selects a network or
/// alternate conversion provider.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum FallbackPolicy {
    /// Return an empty, unconsumed composition and let the native shell enter
    /// direct-input mode.
    DirectInput,
    /// Reuse the last valid local composition/candidate state.  If none exists,
    /// the broker deterministically falls back to direct input.
    #[default]
    LastValidPreedit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrokerConfig {
    pub fallback: FallbackPolicy,
    pub max_sessions: usize,
}

impl Default for BrokerConfig {
    fn default() -> Self {
        Self {
            fallback: FallbackPolicy::default(),
            max_sessions: 128,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BrokerError {
    #[error("request validation failed: {0}")]
    Validation(#[from] ValidationError),
    #[error("session {session_id} does not exist")]
    UnknownSession { session_id: u64 },
    #[error("session {session_id} already exists")]
    AlreadyExists { session_id: u64 },
    #[error("stale generation {expected}; current generation is {current}")]
    StaleGeneration {
        session_id: u64,
        expected: u64,
        current: u64,
    },
    #[error("session generation is exhausted")]
    GenerationExhausted,
    #[error("request is already active: {0}")]
    DuplicateRequest(u64),
    #[error("session limit reached: {0}")]
    SessionLimitReached(usize),
    #[error("optional enhancements must be dispatched by the async enhancement executor")]
    EnhancementRequiresAsync,
}

impl BrokerError {
    fn error_code(&self) -> ErrorCode {
        match self {
            Self::Validation(ValidationError::UnsupportedVersion { .. }) => {
                ErrorCode::UnsupportedVersion
            }
            Self::Validation(_) => ErrorCode::InvalidRequest,
            Self::UnknownSession { .. } => ErrorCode::UnknownSession,
            Self::AlreadyExists { .. } => ErrorCode::AlreadyExists,
            Self::StaleGeneration { .. } => ErrorCode::StaleGeneration,
            Self::GenerationExhausted => ErrorCode::GenerationExhausted,
            Self::DuplicateRequest(_) => ErrorCode::InvalidRequest,
            Self::SessionLimitReached(_) => ErrorCode::BackendUnavailable,
            Self::EnhancementRequiresAsync => ErrorCode::EnhancementRequiresAsync,
        }
    }

    fn current_generation(&self) -> Option<u64> {
        match self {
            Self::StaleGeneration { current, .. } => Some(*current),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
struct SessionRecord {
    generation: u64,
    clock: Arc<AtomicU64>,
    active: Arc<AtomicBool>,
    field_class: FieldClass,
    last_valid: Option<CompositionState>,
}

/// A small, deterministic broker state machine suitable for unit tests and for
/// embedding in a future process entry point.
#[derive(Debug)]
pub struct Broker<B: BrokerBackend> {
    backend: B,
    config: BrokerConfig,
    sessions: HashMap<u64, SessionRecord>,
    cancellations: CancellationRegistry,
}

impl<B: BrokerBackend> Drop for Broker<B> {
    fn drop(&mut self) {
        for session in self.sessions.values() {
            session.active.store(false, Ordering::Release);
        }
    }
}

impl<B: BrokerBackend> Broker<B> {
    pub fn new(backend: B) -> Self {
        Self::with_config(backend, BrokerConfig::default())
    }

    pub fn with_config(backend: B, config: BrokerConfig) -> Self {
        Self {
            backend,
            config,
            sessions: HashMap::new(),
            cancellations: CancellationRegistry::new(),
        }
    }

    #[must_use]
    pub fn backend(&self) -> &B {
        &self.backend
    }

    pub fn backend_mut(&mut self) -> &mut B {
        &mut self.backend
    }

    #[must_use]
    pub fn config(&self) -> BrokerConfig {
        self.config
    }

    #[must_use]
    pub fn cancellations(&self) -> &CancellationRegistry {
        &self.cancellations
    }

    #[must_use]
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }

    #[must_use]
    pub fn generation(&self, session_id: u64) -> Option<u64> {
        self.sessions
            .get(&session_id)
            .map(|session| session.generation)
    }

    /// Capture the current generation and privacy class for an optional
    /// enhancement job.  The returned token is invalidated by any later
    /// state transition or by focus loss.
    #[must_use]
    pub fn enhancement_token(&self, session_id: u64) -> Option<GenerationToken> {
        self.sessions
            .get(&session_id)
            .map(|session| GenerationToken {
                session_id,
                generation: session.generation,
                clock: Arc::clone(&session.clock),
                active: Arc::clone(&session.active),
                field_class: session.field_class.clone(),
                secure_field_policy: if session.field_class.is_secure() {
                    SecureFieldPolicy::Prohibit
                } else {
                    SecureFieldPolicy::AllowLocalOnly
                },
            })
    }

    /// Handle a request and turn validation/state errors into the same wire
    /// response shape used for backend failures.
    pub fn handle(&mut self, request: RequestEnvelope) -> ResponseEnvelope {
        let request_id = request.request_id;
        let hint = request.command.expected_generation();
        match self.dispatch(request) {
            Ok(response) => response,
            Err(error) => {
                let generation = error.current_generation().or(hint);
                let response_error =
                    ErrorResponse::new(error.error_code(), error.to_string(), false)
                        .with_generation(generation);
                ResponseEnvelope::failure(request_id, generation, response_error)
            }
        }
    }

    /// Dispatch a validated request.  Backend failures are handled according
    /// to the configured fallback policy and therefore return a response;
    /// `Err` is reserved for wire/session generation errors.
    pub fn dispatch(&mut self, request: RequestEnvelope) -> Result<ResponseEnvelope, BrokerError> {
        request.validate()?;
        let request_id = request.request_id;
        match request.command {
            RequestCommand::CreateSession(command) => self.create_session(request_id, command),
            RequestCommand::Key(command) => self.key(request_id, command),
            RequestCommand::Edit(command) => self.edit(request_id, command),
            RequestCommand::Convert(command) => self.convert(request_id, command),
            RequestCommand::Commit(command) => self.commit(request_id, command),
            RequestCommand::Cancel(command) => self.cancel(request_id, command),
            RequestCommand::FocusLost(command) => self.focus_lost(request_id, command),
            RequestCommand::Health(_) => Ok(self.health(request_id)),
            RequestCommand::Generation(command) => self.generation_response(request_id, command),
            RequestCommand::RerankCandidates(command) => {
                self.check_generation(command.session_id, command.generation)?;
                Err(BrokerError::EnhancementRequiresAsync)
            }
            RequestCommand::SemanticAssist(command) => {
                self.check_generation(command.session_id, command.generation)?;
                Err(BrokerError::EnhancementRequiresAsync)
            }
        }
    }

    /// Cooperative cancellation hook for an executor that owns a request
    /// outside this synchronous dispatcher.
    pub fn cancel_request(&self, request_id: u64) -> bool {
        self.cancellations.cancel(request_id)
    }

    fn create_session(
        &mut self,
        request_id: u64,
        command: CreateSessionRequest,
    ) -> Result<ResponseEnvelope, BrokerError> {
        if self.sessions.contains_key(&command.session_id) {
            return Err(BrokerError::AlreadyExists {
                session_id: command.session_id,
            });
        }
        if self.sessions.len() >= self.config.max_sessions {
            return Err(BrokerError::SessionLimitReached(self.config.max_sessions));
        }

        let token = CancellationToken::new();
        self.register(request_id, token.clone())?;
        let request = RequestCommand::CreateSession(command.clone());
        let result = self.backend.execute(&request, &token);
        self.cancellations.finish(request_id);

        let payload = match result {
            Ok(ResponsePayload::Created(mut response))
                if response.session_id == command.session_id =>
            {
                response.generation = 0;
                response.fallback = FallbackMode::None;
                ResponsePayload::Created(response)
            }
            Ok(_) => ResponsePayload::Created(SessionCreated {
                session_id: command.session_id,
                generation: 0,
                fallback: FallbackMode::DirectInput,
            }),
            Err(BackendError::Cancelled) => {
                return Ok(ResponseEnvelope::failure(
                    request_id,
                    Some(0),
                    ErrorResponse::new(ErrorCode::Cancelled, "session creation cancelled", false)
                        .with_fallback(FallbackMode::DirectInput)
                        .with_generation(Some(0)),
                ));
            }
            Err(_) => ResponsePayload::Created(SessionCreated {
                session_id: command.session_id,
                generation: 0,
                fallback: FallbackMode::DirectInput,
            }),
        };
        self.sessions.insert(
            command.session_id,
            SessionRecord {
                generation: 0,
                clock: Arc::new(AtomicU64::new(0)),
                active: Arc::new(AtomicBool::new(true)),
                field_class: command.field_class,
                last_valid: None,
            },
        );
        Ok(ResponseEnvelope::success(request_id, payload))
    }

    fn key(
        &mut self,
        request_id: u64,
        command: KeyRequest,
    ) -> Result<ResponseEnvelope, BrokerError> {
        let current = self.check_generation(command.session_id, command.generation)?;
        let next = self.next_generation(current)?;
        self.set_generation(command.session_id, next);
        let token = self.register(request_id, CancellationToken::new())?;
        let result = self
            .backend
            .execute(&RequestCommand::Key(command.clone()), &token);
        self.cancellations.finish(request_id);
        let fallback = self.fallback_state(command.session_id, current);
        match result {
            Ok(ResponsePayload::Key(mut response)) if response.session_id == command.session_id => {
                if normalize_key_response(&mut response, next).is_ok() {
                    self.remember_state(command.session_id, response.state());
                    Ok(ResponseEnvelope::success(
                        request_id,
                        ResponsePayload::Key(response),
                    ))
                } else {
                    Ok(self.fallback_key_response(request_id, command.session_id, next, fallback))
                }
            }
            Ok(_) => Ok(self.fallback_key_response(request_id, command.session_id, next, fallback)),
            Err(BackendError::Cancelled) => Ok(ResponseEnvelope::failure(
                request_id,
                Some(next),
                ErrorResponse::new(ErrorCode::Cancelled, "key request cancelled", true)
                    .with_fallback(FallbackMode::None)
                    .with_generation(Some(next)),
            )),
            Err(error) => {
                let _ = error;
                Ok(self.fallback_key_response(request_id, command.session_id, next, fallback))
            }
        }
    }

    fn edit(
        &mut self,
        request_id: u64,
        command: EditRequest,
    ) -> Result<ResponseEnvelope, BrokerError> {
        let current = self.check_generation(command.session_id, command.generation)?;
        let next = self.next_generation(current)?;
        self.set_generation(command.session_id, next);
        let token = self.register(request_id, CancellationToken::new())?;
        let result = self
            .backend
            .execute(&RequestCommand::Edit(command.clone()), &token);
        self.cancellations.finish(request_id);
        let fallback = self.fallback_state(command.session_id, current);
        match result {
            Ok(ResponsePayload::Edit(mut response))
                if response.session_id == command.session_id =>
            {
                if normalize_edit_response(&mut response, next).is_ok() {
                    self.remember_state(command.session_id, response.state());
                    Ok(ResponseEnvelope::success(
                        request_id,
                        ResponsePayload::Edit(response),
                    ))
                } else {
                    Ok(self.fallback_edit_response(request_id, command.session_id, next, fallback))
                }
            }
            Ok(_) => {
                Ok(self.fallback_edit_response(request_id, command.session_id, next, fallback))
            }
            Err(BackendError::Cancelled) => Ok(ResponseEnvelope::failure(
                request_id,
                Some(next),
                ErrorResponse::new(ErrorCode::Cancelled, "edit request cancelled", true)
                    .with_fallback(FallbackMode::None)
                    .with_generation(Some(next)),
            )),
            Err(error) => {
                let _ = error;
                Ok(self.fallback_edit_response(request_id, command.session_id, next, fallback))
            }
        }
    }

    fn convert(
        &mut self,
        request_id: u64,
        command: ConvertRequest,
    ) -> Result<ResponseEnvelope, BrokerError> {
        self.check_generation(command.session_id, command.generation)?;
        let token = self.register(request_id, CancellationToken::new())?;
        let result = self
            .backend
            .execute(&RequestCommand::Convert(command.clone()), &token);
        self.cancellations.finish(request_id);
        match result {
            Ok(ResponsePayload::Convert(mut response))
                if response.session_id == command.session_id =>
            {
                response.generation = command.generation;
                response.fallback = FallbackMode::None;
                if validate_response_payload(&ResponsePayload::Convert(response.clone())).is_ok() {
                    self.remember_state(command.session_id, response.state());
                    Ok(ResponseEnvelope::success(
                        request_id,
                        ResponsePayload::Convert(response),
                    ))
                } else {
                    Ok(self.fallback_convert_response(request_id, &command))
                }
            }
            Ok(_) => Ok(self.fallback_convert_response(request_id, &command)),
            Err(BackendError::Cancelled) => Ok(ResponseEnvelope::failure(
                request_id,
                Some(command.generation),
                ErrorResponse::new(ErrorCode::Cancelled, "conversion request cancelled", true)
                    .with_fallback(FallbackMode::None)
                    .with_generation(Some(command.generation)),
            )),
            Err(error) => {
                let _ = error;
                Ok(self.fallback_convert_response(request_id, &command))
            }
        }
    }

    fn commit(
        &mut self,
        request_id: u64,
        command: CommitRequest,
    ) -> Result<ResponseEnvelope, BrokerError> {
        let current = self.check_generation(command.session_id, command.generation)?;
        let next = self.next_generation(current)?;
        self.set_generation(command.session_id, next);
        let token = self.register(request_id, CancellationToken::new())?;
        let result = self
            .backend
            .execute(&RequestCommand::Commit(command.clone()), &token);
        self.cancellations.finish(request_id);
        match result {
            Ok(ResponsePayload::Commit(mut response))
                if response.session_id == command.session_id =>
            {
                response.generation = next;
                if validate_response_payload(&ResponsePayload::Commit(response.clone())).is_err() {
                    return Ok(self.commit_failure(
                        request_id,
                        command.session_id,
                        next,
                        ErrorCode::BackendProtocol,
                        "backend returned an invalid commit response",
                    ));
                }
                if let Some(session) = self.sessions.get_mut(&command.session_id) {
                    session.last_valid = None;
                }
                Ok(ResponseEnvelope::success(
                    request_id,
                    ResponsePayload::Commit(response),
                ))
            }
            Ok(_) => Ok(self.commit_failure(
                request_id,
                command.session_id,
                next,
                ErrorCode::BackendProtocol,
                "backend returned the wrong response type",
            )),
            Err(BackendError::Cancelled) => {
                if let Some(session) = self.sessions.get_mut(&command.session_id) {
                    session.last_valid = None;
                }
                Ok(ResponseEnvelope::failure(
                    request_id,
                    Some(next),
                    ErrorResponse::new(ErrorCode::Cancelled, "commit request cancelled", false)
                        .with_fallback(FallbackMode::DirectInput)
                        .with_generation(Some(next)),
                ))
            }
            Err(error) => {
                if let Some(session) = self.sessions.get_mut(&command.session_id) {
                    session.last_valid = None;
                }
                Ok(self.commit_failure(
                    request_id,
                    command.session_id,
                    next,
                    error.error_code(),
                    public_backend_message(error.error_code()),
                ))
            }
        }
    }

    fn cancel(
        &mut self,
        request_id: u64,
        command: CancelRequest,
    ) -> Result<ResponseEnvelope, BrokerError> {
        let current = self
            .sessions
            .get(&command.session_id)
            .map(|session| session.generation)
            .ok_or(BrokerError::UnknownSession {
                session_id: command.session_id,
            })?;
        if let Some(expected) = command.generation
            && expected != current
        {
            return Err(BrokerError::StaleGeneration {
                session_id: command.session_id,
                expected,
                current,
            });
        }
        let next = self.next_generation(current)?;
        self.set_generation(command.session_id, next);
        if let Some(target) = command.target_request_id {
            self.cancellations.cancel(target);
        }
        let token = self.register(request_id, CancellationToken::new())?;
        let _ = self
            .backend
            .execute(&RequestCommand::Cancel(command.clone()), &token);
        self.cancellations.finish(request_id);
        Ok(ResponseEnvelope::success(
            request_id,
            ResponsePayload::Cancel(crate::protocol::CancelResponse {
                session_id: command.session_id,
                generation: next,
                target_request_id: command.target_request_id,
            }),
        ))
    }

    fn focus_lost(
        &mut self,
        request_id: u64,
        command: FocusLostRequest,
    ) -> Result<ResponseEnvelope, BrokerError> {
        let current = self.check_generation(command.session_id, command.generation)?;
        let next = self.next_generation(current)?;
        self.set_generation(command.session_id, next);
        let token = self.register(request_id, CancellationToken::new())?;
        let _ = self
            .backend
            .execute(&RequestCommand::FocusLost(command.clone()), &token);
        self.cancellations.finish(request_id);
        if let Some(session) = self.sessions.remove(&command.session_id) {
            session.active.store(false, Ordering::Release);
        }
        Ok(ResponseEnvelope::success(
            request_id,
            ResponsePayload::FocusLost(FocusLostResponse {
                session_id: command.session_id,
                generation: next,
            }),
        ))
    }

    fn generation_response(
        &mut self,
        request_id: u64,
        command: GenerationRequest,
    ) -> Result<ResponseEnvelope, BrokerError> {
        let generation = self
            .sessions
            .get(&command.session_id)
            .map(|session| session.generation)
            .ok_or(BrokerError::UnknownSession {
                session_id: command.session_id,
            })?;
        Ok(ResponseEnvelope::success(
            request_id,
            ResponsePayload::Generation(GenerationResponse {
                session_id: command.session_id,
                generation,
            }),
        ))
    }

    fn health(&mut self, request_id: u64) -> ResponseEnvelope {
        let mut health = self.backend.health();
        health.protocol_version = PROTOCOL_VERSION;
        if health.max_frame_bytes == 0 {
            health.status = HealthStatus::Unavailable;
            health.detail = "backend returned an invalid frame limit".to_owned();
        }
        if health.detail.is_empty() {
            health.detail = "ready".to_owned();
        }
        if health.detail.chars().any(char::is_control) {
            health.status = HealthStatus::Unavailable;
            health.detail = "backend returned invalid health details".to_owned();
        }
        if health.detail.len() > 512 {
            let mut end = 512;
            while !health.detail.is_char_boundary(end) {
                end -= 1;
            }
            health.detail.truncate(end);
        }
        ResponseEnvelope::success(request_id, ResponsePayload::Health(health))
    }

    fn check_generation(&self, session_id: u64, expected: u64) -> Result<u64, BrokerError> {
        let current = self
            .sessions
            .get(&session_id)
            .map(|session| session.generation)
            .ok_or(BrokerError::UnknownSession { session_id })?;
        if expected != current {
            return Err(BrokerError::StaleGeneration {
                session_id,
                expected,
                current,
            });
        }
        Ok(current)
    }

    fn next_generation(&self, current: u64) -> Result<u64, BrokerError> {
        current
            .checked_add(1)
            .ok_or(BrokerError::GenerationExhausted)
    }

    fn set_generation(&mut self, session_id: u64, generation: u64) {
        if let Some(session) = self.sessions.get_mut(&session_id) {
            session.generation = generation;
            session.clock.store(generation, Ordering::Release);
        }
    }

    fn register(
        &self,
        request_id: u64,
        token: CancellationToken,
    ) -> Result<CancellationToken, BrokerError> {
        self.cancellations
            .register(request_id, token.clone())
            .map_err(|_| BrokerError::DuplicateRequest(request_id))?;
        Ok(token)
    }

    fn fallback_state(&self, session_id: u64, _current: u64) -> Option<CompositionState> {
        if self.config.fallback == FallbackPolicy::LastValidPreedit {
            self.sessions
                .get(&session_id)
                .and_then(|session| session.last_valid.clone())
        } else {
            None
        }
    }

    fn remember_state(&mut self, session_id: u64, state: CompositionState) {
        if let Some(session) = self.sessions.get_mut(&session_id) {
            session.last_valid = Some(state);
        }
    }

    fn fallback_key_response(
        &self,
        request_id: u64,
        session_id: u64,
        generation: u64,
        state: Option<CompositionState>,
    ) -> ResponseEnvelope {
        let (state, fallback) = fallback_state(state);
        ResponseEnvelope::success(
            request_id,
            ResponsePayload::Key(KeyResponse {
                session_id,
                generation,
                preedit: state.preedit,
                consumed: false,
                candidates: state.candidates,
                focused_index: state.focused_index,
                fallback,
            }),
        )
    }

    fn fallback_edit_response(
        &self,
        request_id: u64,
        session_id: u64,
        generation: u64,
        state: Option<CompositionState>,
    ) -> ResponseEnvelope {
        let (state, fallback) = fallback_state(state);
        ResponseEnvelope::success(
            request_id,
            ResponsePayload::Edit(EditResponse {
                session_id,
                generation,
                preedit: state.preedit,
                consumed: false,
                candidates: state.candidates,
                focused_index: state.focused_index,
                fallback,
            }),
        )
    }

    fn fallback_convert_response(
        &self,
        request_id: u64,
        command: &ConvertRequest,
    ) -> ResponseEnvelope {
        let state = self.fallback_state(command.session_id, command.generation);
        let (state, fallback) = fallback_state(state);
        ResponseEnvelope::success(
            request_id,
            ResponsePayload::Convert(ConvertResponse {
                session_id: command.session_id,
                generation: command.generation,
                preedit: state.preedit,
                consumed: false,
                candidates: state.candidates,
                focused_index: state.focused_index,
                page: command.page,
                page_size: command.page_size,
                has_more: false,
                fallback,
            }),
        )
    }

    fn commit_failure(
        &self,
        request_id: u64,
        session_id: u64,
        generation: u64,
        code: ErrorCode,
        message: impl Into<String>,
    ) -> ResponseEnvelope {
        let _ = session_id;
        ResponseEnvelope::failure(
            request_id,
            Some(generation),
            ErrorResponse::new(code, message, false)
                .with_fallback(FallbackMode::DirectInput)
                .with_generation(Some(generation)),
        )
    }
}

fn public_backend_message(code: ErrorCode) -> &'static str {
    match code {
        ErrorCode::BackendUnavailable => "conversion backend is unavailable",
        ErrorCode::BackendTimeout => "conversion backend timed out",
        ErrorCode::BackendProtocol => "conversion backend returned an invalid response",
        ErrorCode::Cancelled => "conversion backend was cancelled",
        _ => "conversion backend failed",
    }
}

fn fallback_state(state: Option<CompositionState>) -> (CompositionState, FallbackMode) {
    match state {
        Some(state) => (state, FallbackMode::LastValidPreedit),
        None => (CompositionState::default(), FallbackMode::DirectInput),
    }
}

fn normalize_key_response(response: &mut KeyResponse, generation: u64) -> Result<(), BackendError> {
    if response.generation != generation {
        response.generation = generation;
    }
    response.fallback = FallbackMode::None;
    validate_response_payload(&ResponsePayload::Key(response.clone()))
        .map_err(|error| BackendError::Protocol(error.to_string()))
}

fn normalize_edit_response(
    response: &mut EditResponse,
    generation: u64,
) -> Result<(), BackendError> {
    response.generation = generation;
    response.fallback = FallbackMode::None;
    validate_response_payload(&ResponsePayload::Edit(response.clone()))
        .map_err(|error| BackendError::Protocol(error.to_string()))
}

fn validate_response_payload(payload: &ResponsePayload) -> Result<(), ValidationError> {
    payload.validate()
}

fn lock_unpoisoned<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A deterministic backend useful for tests and examples.  It is not a
/// Japanese conversion implementation; it only exercises the broker contract
/// with a small direct-input state machine.
#[derive(Debug, Default)]
pub struct DeterministicBackend {
    sessions: HashMap<u64, DeterministicSession>,
    fail_next: Option<BackendError>,
}

#[derive(Debug, Default)]
struct DeterministicSession {
    preedit: String,
}

impl DeterministicBackend {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn fail_next(&mut self, error: BackendError) {
        self.fail_next = Some(error);
    }

    fn take_failure(&mut self) -> Option<BackendError> {
        self.fail_next.take()
    }
}

impl BrokerBackend for DeterministicBackend {
    fn execute(
        &mut self,
        request: &BrokerRequest,
        cancellation: &CancellationToken,
    ) -> Result<BrokerResponse, BackendError> {
        if cancellation.is_cancelled() {
            return Err(BackendError::Cancelled);
        }
        if let Some(error) = self.take_failure() {
            return Err(error);
        }
        let result = match request {
            RequestCommand::CreateSession(command) => {
                self.sessions
                    .insert(command.session_id, DeterministicSession::default());
                Ok(ResponsePayload::Created(SessionCreated {
                    session_id: command.session_id,
                    generation: 0,
                    fallback: FallbackMode::None,
                }))
            }
            RequestCommand::Key(command) => {
                let session = self.sessions.get_mut(&command.session_id).ok_or_else(|| {
                    BackendError::Protocol("unknown deterministic session".to_owned())
                })?;
                match &command.key {
                    KeyEvent::Character { value } => session.preedit.push_str(value),
                    KeyEvent::Backspace => {
                        session.preedit.pop();
                    }
                    KeyEvent::Delete | KeyEvent::Escape | KeyEvent::Tab => {
                        session.preedit.clear();
                    }
                    KeyEvent::Space => session.preedit.push(' '),
                    KeyEvent::Enter
                    | KeyEvent::Left
                    | KeyEvent::Right
                    | KeyEvent::Up
                    | KeyEvent::Down
                    | KeyEvent::Function { .. }
                    | KeyEvent::Named { .. } => {}
                }
                Ok(ResponsePayload::Key(KeyResponse {
                    session_id: command.session_id,
                    generation: 0,
                    preedit: session.preedit.clone(),
                    consumed: true,
                    candidates: Vec::new(),
                    focused_index: None,
                    fallback: FallbackMode::None,
                }))
            }
            RequestCommand::Edit(command) => {
                let session = self.sessions.get_mut(&command.session_id).ok_or_else(|| {
                    BackendError::Protocol("unknown deterministic session".to_owned())
                })?;
                match &command.action {
                    EditAction::Insert { text } => session.preedit.push_str(text),
                    EditAction::Replace { range, text } => {
                        replace_range(&mut session.preedit, *range, text)?;
                    }
                    EditAction::Delete { range } => {
                        delete_range(&mut session.preedit, *range)?;
                    }
                    EditAction::Reset => session.preedit.clear(),
                }
                Ok(ResponsePayload::Edit(EditResponse {
                    session_id: command.session_id,
                    generation: 0,
                    preedit: session.preedit.clone(),
                    consumed: true,
                    candidates: Vec::new(),
                    focused_index: None,
                    fallback: FallbackMode::None,
                }))
            }
            RequestCommand::Convert(command) => {
                let session = self.sessions.get(&command.session_id).ok_or_else(|| {
                    BackendError::Protocol("unknown deterministic session".to_owned())
                })?;
                let candidates = if session.preedit.is_empty() {
                    Vec::new()
                } else {
                    vec![Candidate {
                        id: 1,
                        text: session.preedit.clone(),
                        reading: Some(session.preedit.clone()),
                        rank: 0,
                    }]
                };
                Ok(ResponsePayload::Convert(ConvertResponse {
                    session_id: command.session_id,
                    generation: command.generation,
                    preedit: session.preedit.clone(),
                    consumed: true,
                    candidates,
                    focused_index: (!session.preedit.is_empty()).then_some(0),
                    page: command.page,
                    page_size: command.page_size,
                    has_more: false,
                    fallback: FallbackMode::None,
                }))
            }
            RequestCommand::Commit(command) => {
                let session = self.sessions.get_mut(&command.session_id).ok_or_else(|| {
                    BackendError::Protocol("unknown deterministic session".to_owned())
                })?;
                if command.candidate_id != 1 || session.preedit.is_empty() {
                    return Err(BackendError::Protocol(
                        "candidate is not available".to_owned(),
                    ));
                }
                let text = std::mem::take(&mut session.preedit);
                Ok(ResponsePayload::Commit(crate::protocol::CommitResponse {
                    session_id: command.session_id,
                    generation: command.generation,
                    text,
                    consumed: true,
                }))
            }
            RequestCommand::Cancel(command) => {
                Ok(ResponsePayload::Cancel(crate::protocol::CancelResponse {
                    session_id: command.session_id,
                    generation: command.generation.unwrap_or_default(),
                    target_request_id: command.target_request_id,
                }))
            }
            RequestCommand::FocusLost(command) => {
                self.sessions.remove(&command.session_id);
                Ok(ResponsePayload::FocusLost(FocusLostResponse {
                    session_id: command.session_id,
                    generation: command.generation,
                }))
            }
            RequestCommand::Health(_) => Ok(ResponsePayload::Health(HealthResponse::ready(
                crate::frame::DEFAULT_MAX_FRAME_BYTES,
            ))),
            RequestCommand::Generation(command) => {
                Ok(ResponsePayload::Generation(GenerationResponse {
                    session_id: command.session_id,
                    generation: 0,
                }))
            }
            RequestCommand::RerankCandidates(_) | RequestCommand::SemanticAssist(_) => Err(
                BackendError::Protocol("optional enhancements use the async executor".to_owned()),
            ),
        };
        if cancellation.is_cancelled() {
            Err(BackendError::Cancelled)
        } else {
            result
        }
    }
}

fn replace_range(
    text: &mut String,
    range: crate::protocol::TextRange,
    replacement: &str,
) -> Result<(), BackendError> {
    let start = scalar_index(
        text,
        usize::try_from(range.start).map_err(|_| {
            BackendError::Protocol("edit range is outside the composition".to_owned())
        })?,
    )?;
    let end = scalar_index(
        text,
        usize::try_from(range.end).map_err(|_| {
            BackendError::Protocol("edit range is outside the composition".to_owned())
        })?,
    )?;
    text.replace_range(start..end, replacement);
    Ok(())
}

fn delete_range(text: &mut String, range: crate::protocol::TextRange) -> Result<(), BackendError> {
    let start = scalar_index(
        text,
        usize::try_from(range.start).map_err(|_| {
            BackendError::Protocol("edit range is outside the composition".to_owned())
        })?,
    )?;
    let end = scalar_index(
        text,
        usize::try_from(range.end).map_err(|_| {
            BackendError::Protocol("edit range is outside the composition".to_owned())
        })?,
    )?;
    if start != end {
        text.replace_range(start..end, "");
    }
    Ok(())
}

fn scalar_index(text: &str, index: usize) -> Result<usize, BackendError> {
    text.char_indices()
        .nth(index)
        .map(|(offset, _)| offset)
        .or_else(|| (index == text.chars().count()).then_some(text.len()))
        .ok_or_else(|| BackendError::Protocol("edit range is outside the composition".to_owned()))
}
