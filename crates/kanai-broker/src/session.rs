//! Async session owner for the Rust broker.
//!
//! `broker::Broker` remains the small synchronous state machine used by
//! embedders and deterministic tests. This module adds the process-facing
//! shape needed by a real Mozc adapter: the session owner lives in an async
//! runtime, the provider call is awaited without holding the session map, and
//! an optional enhancement is admitted only with a shared generation token.
//!
//! The owner deliberately does not turn a model result into committed text.
//! It returns the canonical response envelope; a native shell must apply only
//! an exact candidate permutation and must still use Mozc's own commit path.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use async_trait::async_trait;
use thiserror::Error;
use tokio::sync::Mutex;

use crate::enhancement::EnhancementBackend;
use crate::queue::{EnhancementQueue, EnhancementQueueError};
use crate::{
    BackendError, BackendHealth, BrokerConfig, BrokerRequest, BrokerResponse, CancelRequest,
    CancelResponse, CancellationRegistry, CancellationToken, CommitRequest, CompositionState,
    ConvertRequest, ConvertResponse, CreateSessionRequest, EditRequest, EditResponse, ErrorCode,
    ErrorResponse, FallbackMode, FieldClass, FocusLostRequest, FocusLostResponse,
    GenerationRequest, GenerationResponse, GenerationToken, HealthStatus, KeyRequest, KeyResponse,
    PROTOCOL_VERSION, PrepareRerankSessionRequest, RequestCommand, RequestEnvelope,
    ResponseEnvelope, ResponsePayload, SessionCreated, ValidationError,
};

/// Async provider seam used by [`SessionBroker`].
///
/// A real implementation may own one Mozc process per session, route to a
/// supervised Mozc server, or use a test double. The session owner handles
/// validation, generations, lifecycle, and fallback before a response is
/// exposed to a transport.
#[async_trait]
pub trait SessionBackend: Send + Sync {
    async fn execute(
        &self,
        request: &BrokerRequest,
        cancellation: &CancellationToken,
    ) -> Result<BrokerResponse, BackendError>;

    async fn health(&self) -> BackendHealth {
        BackendHealth::ready(crate::frame::DEFAULT_MAX_FRAME_BYTES)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum SessionBrokerError {
    #[error("session limit reached: {0}")]
    SessionLimitReached(usize),
    #[error("request id is already active: {0}")]
    DuplicateRequest(u64),
    #[error("optional enhancement queue is unavailable")]
    QueueUnavailable,
}

struct SessionData {
    last_valid: Option<CompositionState>,
    owner: Option<String>,
}

struct SessionEntry {
    data: Mutex<SessionData>,
    clock: Arc<AtomicU64>,
    epoch: Arc<AtomicU64>,
    active: Arc<AtomicBool>,
    field_class: FieldClass,
    /// Serializes Mozc operations for this session. Optional model work never
    /// acquires this lock.
    operation: Mutex<()>,
    /// True only for the lightweight native candidate-rerank stream. Such an
    /// entry owns a generation token but must never be used as a Mozc
    /// composition backend.
    rerank_only: bool,
}

impl SessionEntry {
    fn new(field_class: FieldClass) -> Self {
        Self {
            data: Mutex::new(SessionData {
                last_valid: None,
                owner: None,
            }),
            clock: Arc::new(AtomicU64::new(0)),
            epoch: Arc::new(AtomicU64::new(0)),
            active: Arc::new(AtomicBool::new(true)),
            field_class,
            operation: Mutex::new(()),
            rerank_only: false,
        }
    }

    fn new_rerank_only(field_class: FieldClass) -> Self {
        Self {
            rerank_only: true,
            ..Self::new(field_class)
        }
    }

    fn token(&self, session_id: u64) -> GenerationToken {
        GenerationToken::from_shared(
            session_id,
            self.clock.load(Ordering::Acquire),
            Arc::clone(&self.clock),
            Arc::clone(&self.epoch),
            Arc::clone(&self.active),
            self.field_class.clone(),
        )
    }
}

/// Async, session-aware broker state owner.
pub struct SessionBroker<B: SessionBackend> {
    backend: Arc<B>,
    config: BrokerConfig,
    sessions: Arc<Mutex<HashMap<u64, Arc<SessionEntry>>>>,
    /// Session IDs invalidated by a backend epoch change are tombstoned for
    /// this broker process. A stale host command must not accidentally bind to
    /// a newly-created session that reuses the same numeric ID.
    invalidated_sessions: Arc<Mutex<HashSet<u64>>>,
    cancellations: CancellationRegistry,
}

impl<B: SessionBackend> Clone for SessionBroker<B> {
    fn clone(&self) -> Self {
        Self {
            backend: Arc::clone(&self.backend),
            config: self.config,
            sessions: Arc::clone(&self.sessions),
            invalidated_sessions: Arc::clone(&self.invalidated_sessions),
            cancellations: self.cancellations.clone(),
        }
    }
}

impl<B: SessionBackend> std::fmt::Debug for SessionBroker<B> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SessionBroker")
            .field("config", &self.config)
            .field("backend", &std::any::type_name::<B>())
            .finish()
    }
}

impl<B: SessionBackend> SessionBroker<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self::with_config(backend, BrokerConfig::default())
    }

    #[must_use]
    pub fn with_config(backend: B, config: BrokerConfig) -> Self {
        Self {
            backend: Arc::new(backend),
            config,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            invalidated_sessions: Arc::new(Mutex::new(HashSet::new())),
            cancellations: CancellationRegistry::new(),
        }
    }

    #[must_use]
    pub fn from_shared(backend: Arc<B>, config: BrokerConfig) -> Self {
        Self {
            backend,
            config,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            invalidated_sessions: Arc::new(Mutex::new(HashSet::new())),
            cancellations: CancellationRegistry::new(),
        }
    }

    #[must_use]
    pub fn config(&self) -> BrokerConfig {
        self.config
    }

    #[must_use]
    pub fn backend(&self) -> &Arc<B> {
        &self.backend
    }

    #[must_use]
    pub fn cancellations(&self) -> &CancellationRegistry {
        &self.cancellations
    }

    pub async fn session_count(&self) -> usize {
        self.sessions.lock().await.len()
    }

    pub async fn generation(&self, session_id: u64) -> Option<u64> {
        let entry = self.sessions.lock().await.get(&session_id).cloned()?;
        Some(entry.clock.load(Ordering::Acquire))
    }

    /// Capture a token from the owner, not from a client-supplied policy.
    pub async fn enhancement_token(&self, session_id: u64) -> Option<GenerationToken> {
        let entry = self.sessions.lock().await.get(&session_id).cloned()?;
        Some(entry.token(session_id))
    }

    /// Bind a newly-created session to the authenticated peer that created it.
    /// Direct in-process callers may leave the owner unset; transport adapters
    /// should always use the authenticated wrapper below.
    pub async fn bind_session_owner(&self, session_id: u64, owner: &str) -> bool {
        if owner.is_empty() {
            return false;
        }
        let Some(entry) = self.sessions.lock().await.get(&session_id).cloned() else {
            return false;
        };
        let mut data = entry.data.lock().await;
        if data.owner.is_some() {
            return false;
        }
        data.owner = Some(owner.to_owned());
        true
    }

    #[must_use]
    pub async fn session_owned_by(&self, session_id: u64, owner: &str) -> bool {
        let Some(entry) = self.sessions.lock().await.get(&session_id).cloned() else {
            return false;
        };
        entry.data.lock().await.owner.as_deref() == Some(owner)
    }

    /// Handle a request after checking the authenticated session owner. A
    /// mismatched peer receives the same content-free unknown-session response
    /// as a nonexistent session, avoiding session enumeration.
    pub async fn handle_for_peer(
        &self,
        envelope: RequestEnvelope,
        owner: &str,
    ) -> ResponseEnvelope {
        let request_id = envelope.request_id;
        if !matches!(
            &envelope.command,
            RequestCommand::CreateSession(_) | RequestCommand::PrepareRerankSession(_)
        ) && let Some(session_id) = envelope.command.session_id()
            && !self.session_owned_by(session_id, owner).await
        {
            return failure(
                request_id,
                envelope.command.expected_generation(),
                ErrorCode::UnknownSession,
                "session does not exist for this authenticated peer",
                FallbackMode::None,
            );
        }
        let response = self.handle(envelope).await;
        match response.payload() {
            Some(ResponsePayload::Created(created)) => {
                self.bind_session_owner(created.session_id, owner).await;
            }
            Some(ResponsePayload::Generation(generation)) => {
                self.bind_session_owner(generation.session_id, owner).await;
            }
            _ => {}
        }
        response
    }

    /// Submit optional work only after the same peer ownership check used by
    /// synchronous commands.
    pub async fn submit_enhancement_for_peer<E>(
        &self,
        envelope: RequestEnvelope,
        queue: &EnhancementQueue<E>,
        cancellation: CancellationToken,
        owner: &str,
    ) -> ResponseEnvelope
    where
        E: EnhancementBackend + Send + Sync + 'static,
    {
        if let Some(session_id) = envelope.command.session_id()
            && !self.session_owned_by(session_id, owner).await
        {
            return failure(
                envelope.request_id,
                envelope.command.expected_generation(),
                ErrorCode::UnknownSession,
                "session does not exist for this authenticated peer",
                FallbackMode::None,
            );
        }
        self.submit_enhancement(envelope, queue, cancellation).await
    }

    /// Submit an optional request to a bounded asynchronous queue. The fast
    /// broker path never calls this method; a transport/optional executor does.
    pub async fn submit_enhancement<E>(
        &self,
        envelope: RequestEnvelope,
        queue: &EnhancementQueue<E>,
        cancellation: CancellationToken,
    ) -> ResponseEnvelope
    where
        E: EnhancementBackend + Send + Sync + 'static,
    {
        let request_id = envelope.request_id;
        if let Err(error) = envelope.validate() {
            return validation_failure(request_id, envelope.command.expected_generation(), &error);
        }
        if !matches!(
            &envelope.command,
            RequestCommand::RerankCandidates(_) | RequestCommand::SemanticAssist(_)
        ) {
            return failure(
                request_id,
                None,
                ErrorCode::InvalidRequest,
                "request is not an optional enhancement",
                FallbackMode::None,
            );
        }
        let Some(session_id) = envelope.command.session_id() else {
            return failure(
                request_id,
                None,
                ErrorCode::InvalidRequest,
                "optional enhancement has no session",
                FallbackMode::None,
            );
        };
        let Some(token) = self.enhancement_token(session_id).await else {
            return failure(
                request_id,
                None,
                ErrorCode::UnknownSession,
                "enhancement session does not exist",
                FallbackMode::None,
            );
        };
        match queue
            .submit(envelope.clone(), token.clone(), cancellation)
            .await
        {
            Ok(response) => response,
            Err(EnhancementQueueError::Full | EnhancementQueueError::Closed) => {
                queue.overflow_response(request_id, &token, &envelope.command)
            }
            Err(EnhancementQueueError::InvalidCapacity)
            | Err(EnhancementQueueError::InvalidWorkers)
            | Err(EnhancementQueueError::NoRuntime) => failure(
                request_id,
                Some(token.generation()),
                ErrorCode::Internal,
                "optional enhancement queue is not configured",
                FallbackMode::LastValidPreedit,
            ),
        }
    }

    /// Handle one synchronous protocol operation. Optional commands are
    /// rejected here so a key/preedit caller cannot accidentally await a
    /// model; use [`Self::submit_enhancement`] from an optional executor.
    pub async fn handle(&self, envelope: RequestEnvelope) -> ResponseEnvelope {
        let request_id = envelope.request_id;
        let generation_hint = envelope.command.expected_generation();
        if let Err(error) = envelope.validate() {
            return validation_failure(request_id, generation_hint, &error);
        }
        match envelope.command {
            RequestCommand::CreateSession(command) => {
                self.create_session(request_id, command).await
            }
            RequestCommand::PrepareRerankSession(command) => {
                self.prepare_rerank_session(request_id, command).await
            }
            RequestCommand::Key(command) => self.key(request_id, command).await,
            RequestCommand::Edit(command) => self.edit(request_id, command).await,
            RequestCommand::Convert(command) => self.convert(request_id, command).await,
            RequestCommand::Commit(command) => self.commit(request_id, command).await,
            RequestCommand::Cancel(command) => self.cancel(request_id, command).await,
            RequestCommand::FocusLost(command) => self.focus_lost(request_id, command).await,
            RequestCommand::Health(_) => self.health(request_id).await,
            RequestCommand::Generation(command) => {
                self.generation_response(request_id, command).await
            }
            RequestCommand::RerankCandidates(_) | RequestCommand::SemanticAssist(_) => failure(
                request_id,
                generation_hint,
                ErrorCode::EnhancementRequiresAsync,
                "optional enhancements require the async queue",
                FallbackMode::None,
            ),
        }
    }

    async fn prepare_rerank_session(
        &self,
        request_id: u64,
        command: PrepareRerankSessionRequest,
    ) -> ResponseEnvelope {
        if self
            .invalidated_sessions
            .lock()
            .await
            .contains(&command.session_id)
        {
            return failure(
                request_id,
                Some(command.generation),
                ErrorCode::BackendUnavailable,
                "session id was invalidated; create a new session id",
                FallbackMode::DirectInput,
            );
        }
        let entry = {
            let mut sessions = self.sessions.lock().await;
            if let Some(entry) = sessions.get(&command.session_id).cloned() {
                entry
            } else {
                if sessions.len() >= self.config.max_sessions {
                    return failure(
                        request_id,
                        Some(command.generation),
                        ErrorCode::BackendUnavailable,
                        "session limit reached",
                        FallbackMode::None,
                    );
                }
                let entry = Arc::new(SessionEntry::new_rerank_only(command.field_class.clone()));
                sessions.insert(command.session_id, Arc::clone(&entry));
                entry
            }
        };
        let _operation = entry.operation.lock().await;
        if !entry.rerank_only {
            return failure(
                request_id,
                Some(command.generation),
                ErrorCode::InvalidRequest,
                "a full Mozc session cannot be adopted as a rerank-only session",
                FallbackMode::None,
            );
        }
        if entry.field_class != command.field_class {
            return failure(
                request_id,
                Some(command.generation),
                ErrorCode::InvalidRequest,
                "field class cannot change for a rerank session",
                FallbackMode::None,
            );
        }
        let cancellation = CancellationToken::new();
        if !self.register(request_id, cancellation) {
            return duplicate_request(request_id);
        }
        self.cancellations.finish(request_id);
        let current = entry.clock.load(Ordering::Acquire);
        if command.generation < current {
            return stale_failure(request_id, command.session_id, command.generation, current);
        }
        if command.generation > current {
            entry.active.store(false, Ordering::Release);
            entry.clock.store(command.generation, Ordering::Release);
            entry.epoch.fetch_add(1, Ordering::AcqRel);
            entry.active.store(true, Ordering::Release);
        }
        ResponseEnvelope::success(
            request_id,
            ResponsePayload::Generation(GenerationResponse {
                session_id: command.session_id,
                generation: entry.clock.load(Ordering::Acquire),
            }),
        )
    }

    async fn create_session(
        &self,
        request_id: u64,
        command: CreateSessionRequest,
    ) -> ResponseEnvelope {
        if self
            .invalidated_sessions
            .lock()
            .await
            .contains(&command.session_id)
        {
            return failure(
                request_id,
                Some(0),
                ErrorCode::BackendUnavailable,
                "session id was invalidated; create a new session id",
                FallbackMode::DirectInput,
            );
        }
        let entry = Arc::new(SessionEntry::new(command.field_class.clone()));
        {
            let mut sessions = self.sessions.lock().await;
            if sessions.contains_key(&command.session_id) {
                return failure(
                    request_id,
                    Some(0),
                    ErrorCode::AlreadyExists,
                    "session already exists",
                    FallbackMode::None,
                );
            }
            if sessions.len() >= self.config.max_sessions {
                return failure(
                    request_id,
                    None,
                    ErrorCode::BackendUnavailable,
                    "session limit reached",
                    FallbackMode::None,
                );
            }
            sessions.insert(command.session_id, Arc::clone(&entry));
        }

        let cancellation = CancellationToken::new();
        if self
            .cancellations
            .register(request_id, cancellation.clone())
            .is_err()
        {
            self.sessions.lock().await.remove(&command.session_id);
            return failure(
                request_id,
                Some(0),
                ErrorCode::InvalidRequest,
                "request id is already active",
                FallbackMode::None,
            );
        }
        let result = self
            .backend
            .execute(
                &RequestCommand::CreateSession(command.clone()),
                &cancellation,
            )
            .await;
        self.cancellations.finish(request_id);

        let payload = match result {
            Ok(ResponsePayload::Created(response)) if response.session_id == command.session_id => {
                ResponsePayload::Created(SessionCreated {
                    session_id: response.session_id,
                    generation: 0,
                    fallback: FallbackMode::None,
                })
            }
            Err(BackendError::SessionInvalidated) => {
                return self
                    .invalidate_session(request_id, command.session_id, &entry, 0)
                    .await;
            }
            _ => ResponsePayload::Created(SessionCreated {
                session_id: command.session_id,
                generation: 0,
                fallback: FallbackMode::DirectInput,
            }),
        };
        ResponseEnvelope::success(request_id, payload)
    }

    async fn key(&self, request_id: u64, command: KeyRequest) -> ResponseEnvelope {
        let Some(entry) = self.entry(command.session_id).await else {
            return unknown_session(request_id, command.session_id, command.generation);
        };
        let _operation = entry.operation.lock().await;
        let cancellation = CancellationToken::new();
        if !self.register(request_id, cancellation.clone()) {
            return duplicate_request(request_id);
        }
        let next = match self
            .begin_state_change(request_id, command.session_id, &entry, command.generation)
            .await
        {
            Ok(value) => value,
            Err(response) => {
                self.cancellations.finish(request_id);
                return response;
            }
        };
        let result = self
            .backend
            .execute(&RequestCommand::Key(command.clone()), &cancellation)
            .await;
        self.cancellations.finish(request_id);
        let fallback = self.fallback_state(command.session_id).await;
        match result {
            Ok(ResponsePayload::Key(mut response)) if response.session_id == command.session_id => {
                response.generation = next;
                response.fallback = FallbackMode::None;
                if ResponsePayload::Key(response.clone()).validate().is_ok() {
                    self.remember_state(command.session_id, state_from_key(&response))
                        .await;
                    ResponseEnvelope::success(request_id, ResponsePayload::Key(response))
                } else {
                    return self
                        .invalidate_session(request_id, command.session_id, &entry, next)
                        .await;
                }
            }
            Ok(_) => {
                return self
                    .invalidate_session(request_id, command.session_id, &entry, next)
                    .await;
            }
            Err(BackendError::Cancelled | BackendError::Rejected(_)) => {
                self.rollback_state_change(&entry, command.generation, next);
                fallback_key(request_id, command.session_id, command.generation, fallback)
            }
            Err(BackendError::SessionInvalidated) => {
                self.invalidate_session(request_id, command.session_id, &entry, next)
                    .await
            }
            Err(_) => {
                self.invalidate_session(request_id, command.session_id, &entry, next)
                    .await
            }
        }
    }

    async fn edit(&self, request_id: u64, command: EditRequest) -> ResponseEnvelope {
        let Some(entry) = self.entry(command.session_id).await else {
            return unknown_session(request_id, command.session_id, command.generation);
        };
        let _operation = entry.operation.lock().await;
        let cancellation = CancellationToken::new();
        if !self.register(request_id, cancellation.clone()) {
            return duplicate_request(request_id);
        }
        let next = match self
            .begin_state_change(request_id, command.session_id, &entry, command.generation)
            .await
        {
            Ok(value) => value,
            Err(response) => {
                self.cancellations.finish(request_id);
                return response;
            }
        };
        let result = self
            .backend
            .execute(&RequestCommand::Edit(command.clone()), &cancellation)
            .await;
        self.cancellations.finish(request_id);
        let fallback = self.fallback_state(command.session_id).await;
        match result {
            Ok(ResponsePayload::Edit(mut response))
                if response.session_id == command.session_id =>
            {
                response.generation = next;
                response.fallback = FallbackMode::None;
                if ResponsePayload::Edit(response.clone()).validate().is_ok() {
                    self.remember_state(command.session_id, state_from_edit(&response))
                        .await;
                    ResponseEnvelope::success(request_id, ResponsePayload::Edit(response))
                } else {
                    return self
                        .invalidate_session(request_id, command.session_id, &entry, next)
                        .await;
                }
            }
            Ok(_) => {
                return self
                    .invalidate_session(request_id, command.session_id, &entry, next)
                    .await;
            }
            Err(BackendError::Cancelled | BackendError::Rejected(_)) => {
                self.rollback_state_change(&entry, command.generation, next);
                fallback_edit(request_id, command.session_id, command.generation, fallback)
            }
            Err(BackendError::SessionInvalidated) => {
                self.invalidate_session(request_id, command.session_id, &entry, next)
                    .await
            }
            Err(_) => {
                self.invalidate_session(request_id, command.session_id, &entry, next)
                    .await
            }
        }
    }

    async fn convert(&self, request_id: u64, command: ConvertRequest) -> ResponseEnvelope {
        let Some(entry) = self.entry(command.session_id).await else {
            return unknown_session(request_id, command.session_id, command.generation);
        };
        let _operation = entry.operation.lock().await;
        let cancellation = CancellationToken::new();
        if !self.register(request_id, cancellation.clone()) {
            return duplicate_request(request_id);
        }
        // A conversion produces a new candidate snapshot. Advance the async
        // owner's generation before provider work so a second page/convert
        // cannot make an older optional result look current.
        let next = match self
            .begin_state_change(request_id, command.session_id, &entry, command.generation)
            .await
        {
            Ok(value) => value,
            Err(response) => {
                self.cancellations.finish(request_id);
                return response;
            }
        };
        let backend_command = ConvertRequest {
            generation: next,
            ..command.clone()
        };
        let result = self
            .backend
            .execute(&RequestCommand::Convert(backend_command), &cancellation)
            .await;
        self.cancellations.finish(request_id);
        match result {
            Ok(ResponsePayload::Convert(mut response))
                if response.session_id == command.session_id =>
            {
                response.generation = next;
                response.fallback = FallbackMode::None;
                if ResponsePayload::Convert(response.clone())
                    .validate()
                    .is_ok()
                {
                    self.remember_state(command.session_id, state_from_convert(&response))
                        .await;
                    ResponseEnvelope::success(request_id, ResponsePayload::Convert(response))
                } else {
                    return self
                        .invalidate_session(request_id, command.session_id, &entry, next)
                        .await;
                }
            }
            Ok(_) => {
                return self
                    .invalidate_session(request_id, command.session_id, &entry, next)
                    .await;
            }
            Err(BackendError::Cancelled | BackendError::Rejected(_)) => {
                self.rollback_state_change(&entry, command.generation, next);
                self.fallback_convert(request_id, &command, command.generation)
                    .await
            }
            Err(BackendError::SessionInvalidated) => {
                self.invalidate_session(request_id, command.session_id, &entry, next)
                    .await
            }
            Err(_) => {
                self.invalidate_session(request_id, command.session_id, &entry, next)
                    .await
            }
        }
    }

    async fn commit(&self, request_id: u64, command: CommitRequest) -> ResponseEnvelope {
        let Some(entry) = self.entry(command.session_id).await else {
            return unknown_session(request_id, command.session_id, command.generation);
        };
        let _operation = entry.operation.lock().await;
        let cancellation = CancellationToken::new();
        if !self.register(request_id, cancellation.clone()) {
            return duplicate_request(request_id);
        }
        let next = match self
            .begin_state_change(request_id, command.session_id, &entry, command.generation)
            .await
        {
            Ok(value) => value,
            Err(response) => {
                self.cancellations.finish(request_id);
                return response;
            }
        };
        let result = self
            .backend
            .execute(&RequestCommand::Commit(command.clone()), &cancellation)
            .await;
        self.cancellations.finish(request_id);
        match result {
            Ok(ResponsePayload::Commit(mut response))
                if response.session_id == command.session_id =>
            {
                response.generation = next;
                if ResponsePayload::Commit(response.clone())
                    .validate()
                    .is_err()
                {
                    return self
                        .invalidate_session(request_id, command.session_id, &entry, next)
                        .await;
                }
                self.clear_state(command.session_id, &entry).await;
                ResponseEnvelope::success(request_id, ResponsePayload::Commit(response))
            }
            Ok(_) => {
                return self
                    .invalidate_session(request_id, command.session_id, &entry, next)
                    .await;
            }
            Err(error @ (BackendError::Cancelled | BackendError::Rejected(_))) => {
                self.rollback_state_change(&entry, command.generation, next);
                let code = backend_error_code(&error);
                failure(
                    request_id,
                    Some(command.generation),
                    code,
                    public_backend_message(code),
                    FallbackMode::DirectInput,
                )
            }
            Err(BackendError::SessionInvalidated) => {
                self.invalidate_session(request_id, command.session_id, &entry, next)
                    .await
            }
            Err(_) => {
                self.invalidate_session(request_id, command.session_id, &entry, next)
                    .await
            }
        }
    }

    async fn cancel(&self, request_id: u64, command: CancelRequest) -> ResponseEnvelope {
        let Some(entry) = self.entry(command.session_id).await else {
            return unknown_session(
                request_id,
                command.session_id,
                command.generation.unwrap_or(0),
            );
        };
        let _operation = entry.operation.lock().await;
        let expected_generation = command
            .generation
            .unwrap_or_else(|| entry.clock.load(Ordering::Acquire));
        let cancellation = CancellationToken::new();
        if !self.register(request_id, cancellation.clone()) {
            return duplicate_request(request_id);
        }
        let next = match self
            .begin_cancel(request_id, command.session_id, &entry, command.generation)
            .await
        {
            Ok(value) => value,
            Err(response) => {
                self.cancellations.finish(request_id);
                return response;
            }
        };
        if let Some(target) = command.target_request_id {
            self.cancellations.cancel(target);
        }
        let result = self
            .backend
            .execute(&RequestCommand::Cancel(command.clone()), &cancellation)
            .await;
        self.cancellations.finish(request_id);
        match result {
            Err(BackendError::SessionInvalidated) => {
                self.invalidate_session(request_id, command.session_id, &entry, next)
                    .await
            }
            Err(error @ (BackendError::Cancelled | BackendError::Rejected(_))) => {
                self.rollback_state_change(&entry, expected_generation, next);
                let code = backend_error_code(&error);
                failure(
                    request_id,
                    Some(expected_generation),
                    code,
                    public_backend_message(code),
                    FallbackMode::DirectInput,
                )
            }
            Err(_) => {
                self.invalidate_session(request_id, command.session_id, &entry, next)
                    .await
            }
            Ok(_) => ResponseEnvelope::success(
                request_id,
                ResponsePayload::Cancel(CancelResponse {
                    session_id: command.session_id,
                    generation: next,
                    target_request_id: command.target_request_id,
                }),
            ),
        }
    }

    async fn focus_lost(&self, request_id: u64, command: FocusLostRequest) -> ResponseEnvelope {
        let Some(entry) = self.entry(command.session_id).await else {
            return unknown_session(request_id, command.session_id, command.generation);
        };
        let _operation = entry.operation.lock().await;
        if entry.rerank_only {
            let current = entry.clock.load(Ordering::Acquire);
            if command.generation != current {
                return stale_failure(request_id, command.session_id, command.generation, current);
            }
            entry.active.store(false, Ordering::Release);
            let mut sessions = self.sessions.lock().await;
            if sessions
                .get(&command.session_id)
                .is_some_and(|current| Arc::ptr_eq(current, &entry))
            {
                sessions.remove(&command.session_id);
            }
            return ResponseEnvelope::success(
                request_id,
                ResponsePayload::FocusLost(FocusLostResponse {
                    session_id: command.session_id,
                    generation: current,
                }),
            );
        }
        let cancellation = CancellationToken::new();
        if !self.register(request_id, cancellation.clone()) {
            return duplicate_request(request_id);
        }
        let next = match self
            .begin_state_change(request_id, command.session_id, &entry, command.generation)
            .await
        {
            Ok(value) => value,
            Err(response) => {
                self.cancellations.finish(request_id);
                return response;
            }
        };
        // Invalidate optional work before awaiting backend teardown.
        entry.active.store(false, Ordering::Release);
        let result = self
            .backend
            .execute(&RequestCommand::FocusLost(command.clone()), &cancellation)
            .await;
        self.cancellations.finish(request_id);
        if matches!(result, Err(BackendError::SessionInvalidated)) {
            return self
                .invalidate_session(request_id, command.session_id, &entry, next)
                .await;
        }
        self.sessions.lock().await.remove(&command.session_id);
        ResponseEnvelope::success(
            request_id,
            ResponsePayload::FocusLost(FocusLostResponse {
                session_id: command.session_id,
                generation: next,
            }),
        )
    }

    async fn health(&self, request_id: u64) -> ResponseEnvelope {
        let mut health = self.backend.health().await;
        health.protocol_version = PROTOCOL_VERSION;
        if health.max_frame_bytes == 0 {
            health.status = HealthStatus::Unavailable;
            health.detail = "backend returned an invalid frame limit".to_owned();
        }
        if health.status == HealthStatus::Unavailable {
            self.invalidate_all_sessions().await;
        }
        if health.detail.is_empty() {
            health.detail = "ready".to_owned();
        }
        if health.detail.chars().any(char::is_control) {
            health.status = HealthStatus::Unavailable;
            health.detail = "backend returned invalid health details".to_owned();
        }
        if health.detail.len() > 512 {
            health.detail.truncate(
                (0..=512)
                    .rev()
                    .find(|end| health.detail.is_char_boundary(*end))
                    .unwrap_or(0),
            );
        }
        ResponseEnvelope::success(request_id, ResponsePayload::Health(health))
    }

    async fn generation_response(
        &self,
        request_id: u64,
        command: GenerationRequest,
    ) -> ResponseEnvelope {
        let Some(generation) = self.generation(command.session_id).await else {
            return failure(
                request_id,
                None,
                ErrorCode::UnknownSession,
                "session does not exist",
                FallbackMode::None,
            );
        };
        ResponseEnvelope::success(
            request_id,
            ResponsePayload::Generation(GenerationResponse {
                session_id: command.session_id,
                generation,
            }),
        )
    }

    async fn entry(&self, session_id: u64) -> Option<Arc<SessionEntry>> {
        self.sessions.lock().await.get(&session_id).cloned()
    }

    fn register(&self, request_id: u64, token: CancellationToken) -> bool {
        self.cancellations.register(request_id, token).is_ok()
    }

    #[allow(clippy::result_large_err)]
    async fn begin_state_change(
        &self,
        request_id: u64,
        session_id: u64,
        entry: &Arc<SessionEntry>,
        expected: u64,
    ) -> Result<u64, ResponseEnvelope> {
        self.ensure_entry(request_id, session_id, entry).await?;
        if entry.rerank_only {
            return Err(failure(
                request_id,
                Some(expected),
                ErrorCode::InvalidRequest,
                "rerank-only session cannot execute composition operations",
                FallbackMode::None,
            ));
        }
        if !entry.active.load(Ordering::Acquire) {
            return Err(unknown_session(request_id, session_id, expected));
        }
        let current = entry.clock.load(Ordering::Acquire);
        if current != expected {
            return Err(stale_failure(request_id, session_id, expected, current));
        }
        let next = current.checked_add(1).ok_or_else(|| {
            failure(
                request_id,
                Some(current),
                ErrorCode::GenerationExhausted,
                "session generation is exhausted",
                FallbackMode::None,
            )
        })?;
        entry.clock.store(next, Ordering::Release);
        entry.epoch.fetch_add(1, Ordering::AcqRel);
        Ok(next)
    }

    #[allow(clippy::result_large_err)]
    async fn begin_cancel(
        &self,
        request_id: u64,
        session_id: u64,
        entry: &Arc<SessionEntry>,
        expected: Option<u64>,
    ) -> Result<u64, ResponseEnvelope> {
        self.ensure_entry(request_id, session_id, entry).await?;
        if entry.rerank_only {
            return Err(failure(
                request_id,
                expected,
                ErrorCode::InvalidRequest,
                "rerank-only session cannot execute composition operations",
                FallbackMode::None,
            ));
        }
        if !entry.active.load(Ordering::Acquire) {
            return Err(unknown_session(
                request_id,
                session_id,
                expected.unwrap_or(0),
            ));
        }
        let current = entry.clock.load(Ordering::Acquire);
        if let Some(expected) = expected
            && expected != current
        {
            return Err(stale_failure(request_id, session_id, expected, current));
        }
        let next = current.checked_add(1).ok_or_else(|| {
            failure(
                request_id,
                Some(current),
                ErrorCode::GenerationExhausted,
                "session generation is exhausted",
                FallbackMode::None,
            )
        })?;
        entry.clock.store(next, Ordering::Release);
        entry.epoch.fetch_add(1, Ordering::AcqRel);
        Ok(next)
    }

    #[allow(clippy::result_large_err)]
    async fn ensure_entry(
        &self,
        request_id: u64,
        session_id: u64,
        entry: &Arc<SessionEntry>,
    ) -> Result<(), ResponseEnvelope> {
        let sessions = self.sessions.lock().await;
        let Some(current) = sessions.get(&session_id) else {
            return Err(unknown_session(request_id, session_id, 0));
        };
        if !Arc::ptr_eq(current, entry) {
            return Err(unknown_session(request_id, session_id, 0));
        }
        Ok(())
    }

    fn rollback_state_change(&self, entry: &Arc<SessionEntry>, expected: u64, attempted: u64) {
        let _ =
            entry
                .clock
                .compare_exchange(attempted, expected, Ordering::AcqRel, Ordering::Acquire);
        // The epoch remains advanced, so optional work created before the
        // rejected operation cannot become current again after rollback.
    }

    async fn remember_state(&self, session_id: u64, state: CompositionState) {
        if let Some(entry) = self.sessions.lock().await.get(&session_id).cloned() {
            entry.data.lock().await.last_valid = Some(state);
        }
    }

    async fn clear_state(&self, session_id: u64, entry: &Arc<SessionEntry>) {
        if self
            .sessions
            .lock()
            .await
            .get(&session_id)
            .is_some_and(|current| Arc::ptr_eq(current, entry))
        {
            entry.data.lock().await.last_valid = None;
        }
    }

    async fn invalidate_all_sessions(&self) {
        let entries = {
            let mut sessions = self.sessions.lock().await;
            sessions.drain().collect::<Vec<_>>()
        };
        for (_, entry) in &entries {
            entry.active.store(false, Ordering::Release);
            entry.data.lock().await.last_valid = None;
        }
        let mut invalidated = self.invalidated_sessions.lock().await;
        invalidated.extend(entries.into_iter().map(|(session_id, _)| session_id));
    }

    async fn invalidate_session(
        &self,
        request_id: u64,
        _session_id: u64,
        _entry: &Arc<SessionEntry>,
        generation: u64,
    ) -> ResponseEnvelope {
        // A bridge epoch loss invalidates every live Mozc session, not only the
        // request that happened to observe EOF. This also invalidates queued
        // optional tokens through each entry's active flag.
        self.invalidate_all_sessions().await;
        failure(
            request_id,
            Some(generation),
            ErrorCode::BackendUnavailable,
            "Mozc session invalidated after backend failure",
            FallbackMode::DirectInput,
        )
    }

    async fn fallback_state(&self, session_id: u64) -> Option<CompositionState> {
        if self.config.fallback != crate::FallbackPolicy::LastValidPreedit {
            return None;
        }
        let entry = self.sessions.lock().await.get(&session_id).cloned()?;
        entry.data.lock().await.last_valid.clone()
    }

    async fn fallback_convert(
        &self,
        request_id: u64,
        command: &ConvertRequest,
        generation: u64,
    ) -> ResponseEnvelope {
        let state = self.fallback_state(command.session_id).await;
        let (state, fallback) = fallback_state_owned(state);
        ResponseEnvelope::success(
            request_id,
            ResponsePayload::Convert(ConvertResponse {
                session_id: command.session_id,
                generation,
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
}

fn state_from_key(response: &KeyResponse) -> CompositionState {
    CompositionState {
        preedit: response.preedit.clone(),
        consumed: response.consumed,
        candidates: response.candidates.clone(),
        focused_index: response.focused_index,
    }
}

fn state_from_edit(response: &EditResponse) -> CompositionState {
    CompositionState {
        preedit: response.preedit.clone(),
        consumed: response.consumed,
        candidates: response.candidates.clone(),
        focused_index: response.focused_index,
    }
}

fn state_from_convert(response: &ConvertResponse) -> CompositionState {
    CompositionState {
        preedit: response.preedit.clone(),
        consumed: response.consumed,
        candidates: response.candidates.clone(),
        focused_index: response.focused_index,
    }
}

fn backend_error_code(error: &BackendError) -> ErrorCode {
    match error {
        BackendError::Unavailable(_) => ErrorCode::BackendUnavailable,
        BackendError::Timeout => ErrorCode::BackendTimeout,
        BackendError::Cancelled => ErrorCode::Cancelled,
        BackendError::Protocol(_) => ErrorCode::BackendProtocol,
        BackendError::Rejected(_) => ErrorCode::InvalidRequest,
        BackendError::SessionInvalidated => ErrorCode::BackendUnavailable,
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

fn fallback_state_owned(state: Option<CompositionState>) -> (CompositionState, FallbackMode) {
    match state {
        Some(state) => (state, FallbackMode::LastValidPreedit),
        None => (CompositionState::default(), FallbackMode::DirectInput),
    }
}

fn fallback_key(
    request_id: u64,
    session_id: u64,
    generation: u64,
    state: Option<CompositionState>,
) -> ResponseEnvelope {
    let (state, fallback) = fallback_state_owned(state);
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

fn fallback_edit(
    request_id: u64,
    session_id: u64,
    generation: u64,
    state: Option<CompositionState>,
) -> ResponseEnvelope {
    let (state, fallback) = fallback_state_owned(state);
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

fn duplicate_request(request_id: u64) -> ResponseEnvelope {
    failure(
        request_id,
        None,
        ErrorCode::InvalidRequest,
        format!("request {request_id} is already active"),
        FallbackMode::None,
    )
}

fn unknown_session(request_id: u64, session_id: u64, generation: u64) -> ResponseEnvelope {
    failure(
        request_id,
        Some(generation),
        ErrorCode::UnknownSession,
        format!("session {session_id} does not exist"),
        FallbackMode::None,
    )
}

fn stale_failure(
    request_id: u64,
    session_id: u64,
    expected: u64,
    current: u64,
) -> ResponseEnvelope {
    failure(
        request_id,
        Some(current),
        ErrorCode::StaleGeneration,
        format!(
            "stale generation {expected} for session {session_id}; current generation is {current}"
        ),
        FallbackMode::None,
    )
}

fn validation_failure(
    request_id: u64,
    generation: Option<u64>,
    error: &ValidationError,
) -> ResponseEnvelope {
    let code = match error {
        ValidationError::UnsupportedVersion { .. } => ErrorCode::UnsupportedVersion,
        _ => ErrorCode::InvalidRequest,
    };
    failure(
        request_id,
        generation,
        code,
        error.to_string(),
        FallbackMode::None,
    )
}

fn failure(
    request_id: u64,
    generation: Option<u64>,
    code: ErrorCode,
    message: impl Into<String>,
    fallback: FallbackMode,
) -> ResponseEnvelope {
    ResponseEnvelope::failure(
        request_id,
        generation,
        ErrorResponse::new(code, message, false)
            .with_fallback(fallback)
            .with_generation(generation),
    )
}
