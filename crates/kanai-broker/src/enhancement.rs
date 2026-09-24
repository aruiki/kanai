//! Optional, asynchronous local quality enhancements.
//!
//! The synchronous broker path deliberately rejects these commands.  A caller
//! must schedule this executor away from the per-key path; it then applies
//! generation, cancellation, secure-field, timeout, and fallback policy before
//! publishing a result.  No model runtime or provider (including any external
//! project) is linked by this crate.

use std::time::{Duration, Instant};

use async_trait::async_trait;
use thiserror::Error;
use tokio::time::timeout;

use crate::broker::{CancellationRegistry, CancellationToken, GenerationToken};
use crate::protocol::{
    Candidate, CandidateRerankRequest, CandidateRerankResponse, EnhancementFeature,
    EnhancementMetrics, EnhancementPolicy, EnhancementReason, EnhancementStatus, ErrorCode,
    ErrorResponse, FallbackMode, Generation, MAX_ASSIST_TEXT_BYTES, MAX_ENHANCEMENT_DEADLINE_MS,
    MAX_PROVIDER_ID_BYTES, ProviderLocality, RequestCommand, RequestEnvelope, ResponseEnvelope,
    ResponsePayload, SecureFieldPolicy, SemanticAssistRequest, SemanticAssistResponse,
    ValidationError,
};

/// Errors from an optional enhancement provider or from broker admission.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum EnhancementError {
    #[error("invalid enhancement request: {0}")]
    InvalidRequest(#[from] ValidationError),
    #[error("enhancement policy is disabled")]
    Disabled,
    #[error("secure fields cannot use optional enhancement providers")]
    SecureField,
    #[error("remote enhancement providers are not enabled by this broker")]
    RemoteProvider,
    #[error("enhancement provider is unavailable: {0}")]
    ProviderUnavailable(String),
    #[error("enhancement provider timed out")]
    ProviderTimeout,
    #[error("enhancement provider was cancelled")]
    Cancelled,
    #[error("enhancement provider returned invalid output: {0}")]
    InvalidOutput(String),
    #[error("enhancement provider rejected the request: {0}")]
    Rejected(String),
    #[error("enhancement generation is stale: expected {expected}, current {current}")]
    StaleGeneration {
        expected: Generation,
        current: Generation,
    },
}

/// Normalized output from a candidate reranker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RerankOutput {
    pub candidates: Vec<Candidate>,
    pub adopted: bool,
    pub metrics: EnhancementMetrics,
}

/// Normalized output from an optional semantic assistant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SemanticAssistOutput {
    pub assist: Option<String>,
    pub applied: bool,
    pub metrics: EnhancementMetrics,
}

/// Async provider seam.  Implementations should be local, bounded, and
/// cancellation-aware, and should move any CPU work to a bounded worker rather
/// than blocking an async executor.  The coordinator—not the provider—owns
/// fallback and stale-result policy.
#[async_trait]
pub trait EnhancementBackend: Send + Sync {
    fn provider_id(&self) -> &str;
    fn locality(&self) -> ProviderLocality;

    async fn rerank(
        &self,
        request: CandidateRerankRequest,
        cancellation: CancellationToken,
    ) -> Result<RerankOutput, EnhancementError>;

    async fn semantic_assist(
        &self,
        request: SemanticAssistRequest,
        cancellation: CancellationToken,
    ) -> Result<SemanticAssistOutput, EnhancementError>;
}

/// Optional enhancement executor.  It is intentionally separate from
/// `BrokerBackend`: a per-key Mozc call must not accidentally call a model.
pub struct EnhancementCoordinator<B: EnhancementBackend> {
    backend: B,
    policy: EnhancementPolicy,
    cancellations: CancellationRegistry,
}

impl<B: EnhancementBackend> EnhancementCoordinator<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self {
            backend,
            policy: EnhancementPolicy::Disabled,
            cancellations: CancellationRegistry::new(),
        }
    }

    #[must_use]
    pub fn with_policy(backend: B, policy: EnhancementPolicy) -> Self {
        Self {
            backend,
            policy,
            cancellations: CancellationRegistry::new(),
        }
    }

    #[must_use]
    pub fn policy(&self) -> EnhancementPolicy {
        self.policy
    }

    #[must_use]
    pub fn backend(&self) -> &B {
        &self.backend
    }

    #[must_use]
    pub fn cancellations(&self) -> &CancellationRegistry {
        &self.cancellations
    }

    pub fn cancel_request(&self, request_id: u64) -> bool {
        self.cancellations.cancel(request_id)
    }

    /// Handle only the two optional enhancement commands.  Callers should
    /// spawn this future on a bounded optional executor, not await it from a
    /// synchronous key callback.
    pub async fn handle(
        &self,
        envelope: RequestEnvelope,
        token: GenerationToken,
        cancellation: CancellationToken,
    ) -> ResponseEnvelope {
        let request_id = envelope.request_id;
        if envelope.version != crate::protocol::PROTOCOL_VERSION {
            return failure(
                request_id,
                Some(token.current_generation()),
                ErrorCode::UnsupportedVersion,
                "unsupported enhancement protocol version",
                FallbackMode::None,
            );
        }
        if let Err(error) = envelope.validate() {
            return failure(
                request_id,
                token.current_generation().into(),
                ErrorCode::InvalidRequest,
                error.to_string(),
                FallbackMode::None,
            );
        }
        if self
            .cancellations
            .register(request_id, cancellation.clone())
            .is_err()
        {
            return failure(
                request_id,
                token.current_generation().into(),
                ErrorCode::InvalidRequest,
                "enhancement request id is already active",
                FallbackMode::None,
            );
        }
        let _registration = CancellationRegistration {
            registry: self.cancellations.clone(),
            request_id,
            token: cancellation.clone(),
        };
        if let Err(error) = self.admit(&token, &envelope.command) {
            return match error {
                AdmissionError::Stale { current } => failure(
                    request_id,
                    Some(current),
                    ErrorCode::StaleGeneration,
                    "enhancement result belongs to an old session generation",
                    FallbackMode::None,
                ),
                AdmissionError::Invalid(message) => failure(
                    request_id,
                    token.current_generation().into(),
                    ErrorCode::InvalidRequest,
                    message,
                    FallbackMode::None,
                ),
                AdmissionError::SecureField => self.skip_response(
                    request_id,
                    &token,
                    &envelope.command,
                    EnhancementReason::SecureField,
                ),
            };
        }
        if cancellation.is_cancelled() {
            return self.cancelled_response(request_id, &token, &envelope.command);
        }
        if self.policy == EnhancementPolicy::Disabled {
            return self.skip_response(
                request_id,
                &token,
                &envelope.command,
                EnhancementReason::PolicyDisabled,
            );
        }
        if self.backend.locality() != ProviderLocality::Local {
            return self.skip_response(
                request_id,
                &token,
                &envelope.command,
                EnhancementReason::ProviderRejected,
            );
        }

        match envelope.command {
            RequestCommand::RerankCandidates(request) => {
                self.rerank(request_id, request, token, cancellation).await
            }
            RequestCommand::SemanticAssist(request) => {
                self.semantic_assist(request_id, request, token, cancellation)
                    .await
            }
            _ => failure(
                request_id,
                token.current_generation().into(),
                ErrorCode::InvalidRequest,
                "request is not an optional enhancement command",
                FallbackMode::None,
            ),
        }
    }

    fn admit(
        &self,
        token: &GenerationToken,
        command: &RequestCommand,
    ) -> Result<(), AdmissionError> {
        let (session_id, generation) = match command {
            RequestCommand::RerankCandidates(request) => (request.session_id, request.generation),
            RequestCommand::SemanticAssist(request) => (request.session_id, request.generation),
            _ => {
                return Err(AdmissionError::Invalid(
                    "not an enhancement command".to_owned(),
                ));
            }
        };
        if session_id != token.session_id()
            || generation != token.generation()
            || !token.is_current()
        {
            return Err(AdmissionError::Stale {
                current: token.current_generation(),
            });
        }
        if token.secure_field_policy() == SecureFieldPolicy::Prohibit
            || token.field_class().is_secure()
        {
            return Err(AdmissionError::SecureField);
        }
        Ok(())
    }

    async fn rerank(
        &self,
        request_id: u64,
        request: CandidateRerankRequest,
        token: GenerationToken,
        cancellation: CancellationToken,
    ) -> ResponseEnvelope {
        let baseline_latency_micros = request.baseline_latency_micros;
        let baseline = request.candidates.clone();
        if baseline.is_empty() {
            return self.rerank_fallback(
                request_id,
                &token,
                baseline,
                EnhancementStatus::Skipped,
                EnhancementReason::NoBaseline,
                request.deadline_ms,
                Duration::ZERO,
            );
        }
        let started = Instant::now();
        let job_token = cancellation.clone();
        let result = timeout(
            Duration::from_millis(u64::from(request.deadline_ms)),
            self.backend.rerank(request.clone(), job_token.clone()),
        )
        .await;
        let elapsed = started.elapsed();
        if cancellation.is_cancelled() || job_token.is_cancelled() {
            return self.cancelled_response(
                request_id,
                &token,
                &RequestCommand::RerankCandidates(request.clone()),
            );
        }
        if !token.is_current() {
            return stale_failure(request_id, &token);
        }
        match result {
            Ok(Ok(output)) => match self.valid_rerank_output(&baseline, &output) {
                Ok(()) => {
                    let mut metrics = output.metrics;
                    metrics.feature = EnhancementFeature::CandidateRerank;
                    metrics.provider = self.provider_id();
                    metrics.locality = ProviderLocality::Local;
                    metrics.baseline_candidate_count = baseline.len() as u16;
                    metrics.ai_candidate_count = output.candidates.len() as u16;
                    metrics.baseline_latency_micros = baseline_latency_micros;
                    metrics.deadline_ms = request.deadline_ms;
                    metrics.ai_latency_micros =
                        elapsed.as_micros().min(u128::from(u64::MAX)) as u64;
                    metrics.changed_positions = changed_positions(&baseline, &output.candidates);
                    metrics.adopted_count = if output.adopted {
                        metrics.changed_positions
                    } else {
                        0
                    };
                    let status = EnhancementStatus::Applied;
                    let reason = if output.adopted {
                        EnhancementReason::None
                    } else {
                        EnhancementReason::NoChange
                    };
                    ResponseEnvelope::success(
                        request_id,
                        ResponsePayload::RerankCandidates(CandidateRerankResponse {
                            session_id: token.session_id(),
                            generation: token.generation(),
                            status,
                            baseline,
                            ai: output.candidates,
                            adopted: output.adopted,
                            metrics,
                            fallback: if output.adopted {
                                FallbackMode::None
                            } else {
                                FallbackMode::LastValidPreedit
                            },
                            reason,
                        }),
                    )
                }
                Err(()) => self.rerank_fallback(
                    request_id,
                    &token,
                    baseline,
                    EnhancementStatus::Fallback,
                    EnhancementReason::InvalidResult,
                    request.deadline_ms,
                    elapsed,
                ),
            },
            Ok(Err(EnhancementError::StaleGeneration { .. })) => stale_failure(request_id, &token),
            Ok(Err(EnhancementError::ProviderTimeout)) => self.rerank_fallback(
                request_id,
                &token,
                baseline,
                EnhancementStatus::TimedOut,
                EnhancementReason::ProviderTimeout,
                request.deadline_ms,
                elapsed,
            ),
            Ok(Err(EnhancementError::Cancelled)) => self.cancelled_response(
                request_id,
                &token,
                &RequestCommand::RerankCandidates(request.clone()),
            ),
            Ok(Err(error)) => self.rerank_fallback(
                request_id,
                &token,
                baseline,
                EnhancementStatus::Fallback,
                reason_for_error(&error),
                request.deadline_ms,
                elapsed,
            ),
            Err(_) => {
                job_token.cancel();
                self.rerank_fallback(
                    request_id,
                    &token,
                    baseline,
                    EnhancementStatus::TimedOut,
                    EnhancementReason::ProviderTimeout,
                    request.deadline_ms,
                    elapsed,
                )
            }
        }
    }

    async fn semantic_assist(
        &self,
        request_id: u64,
        request: SemanticAssistRequest,
        token: GenerationToken,
        cancellation: CancellationToken,
    ) -> ResponseEnvelope {
        let baseline_latency_micros = request.baseline_latency_micros;
        let baseline = request.text.clone();
        if !request.consent {
            return self.semantic_fallback(
                request_id,
                &token,
                baseline,
                EnhancementStatus::Skipped,
                EnhancementReason::ConsentRequired,
                request.deadline_ms,
                Duration::ZERO,
            );
        }
        let started = Instant::now();
        let job_token = cancellation.clone();
        let result = timeout(
            Duration::from_millis(u64::from(request.deadline_ms)),
            self.backend
                .semantic_assist(request.clone(), job_token.clone()),
        )
        .await;
        let elapsed = started.elapsed();
        if cancellation.is_cancelled() || job_token.is_cancelled() {
            return self.cancelled_response(
                request_id,
                &token,
                &RequestCommand::SemanticAssist(request.clone()),
            );
        }
        if !token.is_current() {
            return stale_failure(request_id, &token);
        }
        match result {
            Ok(Ok(output)) => {
                let assist_valid = output.assist.as_deref().is_none_or(|assist| {
                    !assist.is_empty()
                        && assist.len() <= MAX_ASSIST_TEXT_BYTES
                        && !assist.chars().any(char::is_control)
                });
                if (output.applied && output.assist.is_none()) || !assist_valid {
                    return self.semantic_fallback(
                        request_id,
                        &token,
                        baseline,
                        EnhancementStatus::Fallback,
                        EnhancementReason::InvalidResult,
                        request.deadline_ms,
                        elapsed,
                    );
                }
                let mut metrics = output.metrics;
                metrics.feature = EnhancementFeature::SemanticAssist;
                metrics.provider = self.provider_id();
                metrics.locality = ProviderLocality::Local;
                metrics.baseline_candidate_count = 0;
                metrics.ai_candidate_count = 0;
                metrics.changed_positions = 0;
                metrics.adopted_count = 0;
                metrics.baseline_latency_micros = baseline_latency_micros;
                metrics.deadline_ms = request.deadline_ms;
                metrics.ai_latency_micros = elapsed.as_micros().min(u128::from(u64::MAX)) as u64;
                ResponseEnvelope::success(
                    request_id,
                    ResponsePayload::SemanticAssist(SemanticAssistResponse {
                        session_id: token.session_id(),
                        generation: token.generation(),
                        status: EnhancementStatus::Applied,
                        baseline_text: baseline,
                        assist: output.assist,
                        applied: output.applied,
                        metrics,
                        fallback: if output.applied {
                            FallbackMode::None
                        } else {
                            FallbackMode::LastValidPreedit
                        },
                        reason: if output.applied {
                            EnhancementReason::None
                        } else {
                            EnhancementReason::NoChange
                        },
                    }),
                )
            }
            Ok(Err(EnhancementError::StaleGeneration { .. })) => stale_failure(request_id, &token),
            Ok(Err(EnhancementError::ProviderTimeout)) => self.semantic_fallback(
                request_id,
                &token,
                baseline,
                EnhancementStatus::TimedOut,
                EnhancementReason::ProviderTimeout,
                request.deadline_ms,
                elapsed,
            ),
            Ok(Err(EnhancementError::Cancelled)) => self.cancelled_response(
                request_id,
                &token,
                &RequestCommand::SemanticAssist(request.clone()),
            ),
            Ok(Err(error)) => self.semantic_fallback(
                request_id,
                &token,
                baseline,
                EnhancementStatus::Fallback,
                reason_for_error(&error),
                request.deadline_ms,
                elapsed,
            ),
            Err(_) => {
                job_token.cancel();
                self.semantic_fallback(
                    request_id,
                    &token,
                    baseline,
                    EnhancementStatus::TimedOut,
                    EnhancementReason::ProviderTimeout,
                    request.deadline_ms,
                    elapsed,
                )
            }
        }
    }

    fn provider_id(&self) -> String {
        let provider_id = self.backend.provider_id();
        if provider_id.is_empty()
            || provider_id.len() > MAX_PROVIDER_ID_BYTES
            || provider_id.chars().any(char::is_control)
        {
            "local".to_owned()
        } else {
            provider_id.to_owned()
        }
    }

    fn valid_rerank_output(&self, baseline: &[Candidate], output: &RerankOutput) -> Result<(), ()> {
        if output.candidates.len() > crate::protocol::MAX_CANDIDATES {
            return Err(());
        }
        for candidate in &output.candidates {
            if candidate.validate().is_err() {
                return Err(());
            }
        }
        if crate::protocol::validate_ai_candidates(baseline, &output.candidates).is_err() {
            return Err(());
        }
        if output.metrics.feature != EnhancementFeature::CandidateRerank
            || output.metrics.provider.is_empty()
            || output.metrics.deadline_ms == 0
            || output.metrics.deadline_ms > MAX_ENHANCEMENT_DEADLINE_MS
        {
            return Err(());
        }
        Ok(())
    }

    fn skip_response(
        &self,
        request_id: u64,
        token: &GenerationToken,
        command: &RequestCommand,
        reason: EnhancementReason,
    ) -> ResponseEnvelope {
        let status = if reason == EnhancementReason::ProviderRejected {
            EnhancementStatus::Rejected
        } else {
            EnhancementStatus::Skipped
        };
        match command {
            RequestCommand::RerankCandidates(request) => self.rerank_fallback(
                request_id,
                token,
                request.candidates.clone(),
                status,
                reason,
                request.deadline_ms,
                Duration::ZERO,
            ),
            RequestCommand::SemanticAssist(request) => self.semantic_fallback(
                request_id,
                token,
                request.text.clone(),
                status,
                reason,
                request.deadline_ms,
                Duration::ZERO,
            ),
            _ => failure(
                request_id,
                token.current_generation().into(),
                ErrorCode::InvalidRequest,
                "not an enhancement command",
                FallbackMode::None,
            ),
        }
    }

    fn cancelled_response(
        &self,
        request_id: u64,
        token: &GenerationToken,
        command: &RequestCommand,
    ) -> ResponseEnvelope {
        match command {
            RequestCommand::RerankCandidates(request) => self.rerank_fallback(
                request_id,
                token,
                request.candidates.clone(),
                EnhancementStatus::Cancelled,
                EnhancementReason::Cancelled,
                request.deadline_ms,
                Duration::ZERO,
            ),
            RequestCommand::SemanticAssist(request) => self.semantic_fallback(
                request_id,
                token,
                request.text.clone(),
                EnhancementStatus::Cancelled,
                EnhancementReason::Cancelled,
                request.deadline_ms,
                Duration::ZERO,
            ),
            _ => failure(
                request_id,
                token.current_generation().into(),
                ErrorCode::Cancelled,
                "enhancement request was cancelled",
                FallbackMode::None,
            ),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn rerank_fallback(
        &self,
        request_id: u64,
        token: &GenerationToken,
        baseline: Vec<Candidate>,
        status: EnhancementStatus,
        reason: EnhancementReason,
        deadline_ms: u32,
        elapsed: Duration,
    ) -> ResponseEnvelope {
        let provider =
            if status == EnhancementStatus::Skipped && reason == EnhancementReason::SecureField {
                "none".to_owned()
            } else {
                self.provider_id()
            };
        let mut metrics = EnhancementMetrics::baseline(
            EnhancementFeature::CandidateRerank,
            provider,
            ProviderLocality::Local,
            baseline.len() as u16,
            deadline_ms,
        );
        metrics.ai_latency_micros = elapsed.as_micros().min(u128::from(u64::MAX)) as u64;
        ResponseEnvelope::success(
            request_id,
            ResponsePayload::RerankCandidates(CandidateRerankResponse {
                session_id: token.session_id(),
                generation: token.generation(),
                status,
                ai: baseline.clone(),
                baseline,
                adopted: false,
                metrics,
                fallback: FallbackMode::LastValidPreedit,
                reason,
            }),
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn semantic_fallback(
        &self,
        request_id: u64,
        token: &GenerationToken,
        baseline: String,
        status: EnhancementStatus,
        reason: EnhancementReason,
        deadline_ms: u32,
        elapsed: Duration,
    ) -> ResponseEnvelope {
        let provider =
            if status == EnhancementStatus::Skipped && reason == EnhancementReason::SecureField {
                "none".to_owned()
            } else {
                self.provider_id()
            };
        let mut metrics = EnhancementMetrics::baseline(
            EnhancementFeature::SemanticAssist,
            provider,
            ProviderLocality::Local,
            0,
            deadline_ms,
        );
        metrics.ai_latency_micros = elapsed.as_micros().min(u128::from(u64::MAX)) as u64;
        ResponseEnvelope::success(
            request_id,
            ResponsePayload::SemanticAssist(SemanticAssistResponse {
                session_id: token.session_id(),
                generation: token.generation(),
                status,
                baseline_text: baseline,
                assist: None,
                applied: false,
                metrics,
                fallback: FallbackMode::LastValidPreedit,
                reason,
            }),
        )
    }
}

struct CancellationRegistration {
    registry: CancellationRegistry,
    request_id: u64,
    token: CancellationToken,
}

impl Drop for CancellationRegistration {
    fn drop(&mut self) {
        self.token.cancel();
        self.registry.finish(self.request_id);
    }
}

#[derive(Debug)]
enum AdmissionError {
    Stale { current: Generation },
    SecureField,
    Invalid(String),
}

fn failure(
    request_id: u64,
    generation: Option<Generation>,
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

fn stale_failure(request_id: u64, token: &GenerationToken) -> ResponseEnvelope {
    failure(
        request_id,
        Some(token.current_generation()),
        ErrorCode::StaleGeneration,
        "enhancement result belongs to an old session generation",
        FallbackMode::None,
    )
}

fn reason_for_error(error: &EnhancementError) -> EnhancementReason {
    match error {
        EnhancementError::ProviderTimeout => EnhancementReason::ProviderTimeout,
        EnhancementError::ProviderUnavailable(_) | EnhancementError::RemoteProvider => {
            EnhancementReason::ProviderUnavailable
        }
        EnhancementError::Rejected(_) => EnhancementReason::ProviderRejected,
        EnhancementError::InvalidOutput(_) => EnhancementReason::InvalidResult,
        EnhancementError::Cancelled => EnhancementReason::Cancelled,
        EnhancementError::StaleGeneration { .. } => EnhancementReason::StaleGeneration,
        EnhancementError::InvalidRequest(_) | EnhancementError::Disabled => {
            EnhancementReason::ProviderRejected
        }
        EnhancementError::SecureField => EnhancementReason::SecureField,
    }
}

fn changed_positions(baseline: &[Candidate], ai: &[Candidate]) -> u16 {
    baseline
        .iter()
        .enumerate()
        .filter(|(index, candidate)| {
            ai.get(*index)
                .is_none_or(|ai_candidate| ai_candidate.id != candidate.id)
        })
        .count() as u16
}
