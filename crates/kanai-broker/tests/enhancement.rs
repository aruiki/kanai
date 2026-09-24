use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use kanai_broker::{
    Broker, CancellationToken, Candidate, CandidateRerankRequest, CreateSessionRequest,
    DeterministicBackend, EnhancementBackend, EnhancementCoordinator, EnhancementError,
    EnhancementFeature, EnhancementMetrics, EnhancementPolicy, EnhancementReason,
    EnhancementStatus, ErrorCode, FieldClass, GenerationToken, KeyEvent, KeyRequest,
    ProviderLocality, RequestCommand, RequestEnvelope, RerankOutput, ResponsePayload,
    SemanticAssistOutput, SemanticAssistRequest, SemanticIntent,
};

#[derive(Default)]
struct FakeBackend {
    calls: AtomicUsize,
    delay_ms: u64,
}

impl FakeBackend {
    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }

    fn metrics(feature: EnhancementFeature, count: u16) -> EnhancementMetrics {
        EnhancementMetrics::baseline(feature, "fake-local", ProviderLocality::Local, count, 250)
    }
}

#[async_trait]
impl EnhancementBackend for FakeBackend {
    fn provider_id(&self) -> &str {
        "fake-local"
    }

    fn locality(&self) -> ProviderLocality {
        ProviderLocality::Local
    }

    async fn rerank(
        &self,
        request: CandidateRerankRequest,
        cancellation: CancellationToken,
    ) -> Result<RerankOutput, EnhancementError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.delay_ms > 0 {
            tokio::time::sleep(Duration::from_millis(self.delay_ms)).await;
        }
        if cancellation.is_cancelled() {
            return Err(EnhancementError::Cancelled);
        }
        let mut candidates = request.candidates;
        candidates.reverse();
        Ok(RerankOutput {
            adopted: true,
            metrics: Self::metrics(EnhancementFeature::CandidateRerank, 2),
            candidates,
        })
    }

    async fn semantic_assist(
        &self,
        request: SemanticAssistRequest,
        cancellation: CancellationToken,
    ) -> Result<SemanticAssistOutput, EnhancementError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if cancellation.is_cancelled() {
            return Err(EnhancementError::Cancelled);
        }
        Ok(SemanticAssistOutput {
            assist: Some(format!("{}: ok", request.text)),
            applied: true,
            metrics: Self::metrics(EnhancementFeature::SemanticAssist, 0),
        })
    }
}

fn create(field_class: FieldClass) -> (Broker<DeterministicBackend>, GenerationToken) {
    let mut broker = Broker::new(DeterministicBackend::new());
    broker.handle(RequestEnvelope::new(
        1,
        RequestCommand::CreateSession(CreateSessionRequest {
            session_id: 9,
            locale: "ja-JP".to_owned(),
            field_class,
        }),
    ));
    let token = broker.enhancement_token(9).expect("session token");
    (broker, token)
}

fn candidates() -> Vec<Candidate> {
    vec![
        Candidate {
            id: 1,
            text: "かな".to_owned(),
            reading: None,
            rank: 0,
        },
        Candidate {
            id: 2,
            text: "彼方".to_owned(),
            reading: None,
            rank: 1,
        },
    ]
}

#[test]
fn local_rerank_returns_baseline_and_ai_orders_with_metrics() {
    let (_broker, token) = create(FieldClass::Regular);
    let backend = FakeBackend::default();
    let coordinator =
        EnhancementCoordinator::with_policy(backend, EnhancementPolicy::LocalQualityOnly);
    let request = RequestEnvelope::new(
        2,
        RequestCommand::RerankCandidates(CandidateRerankRequest::new(9, 0, candidates())),
    );
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let response = runtime.block_on(coordinator.handle(request, token, CancellationToken::new()));
    assert!(response.validate().is_ok());
    let encoded = kanai_broker::encode_response(&response).expect("response encodes");
    assert_eq!(
        kanai_broker::decode_response(&encoded).expect("response decodes"),
        response
    );
    let payload = response.payload().expect("rerank response");
    let ResponsePayload::RerankCandidates(result) = payload else {
        panic!("expected rerank");
    };
    assert_eq!(result.status, EnhancementStatus::Applied);
    assert!(result.adopted);
    assert_eq!(result.baseline[0].id, 1);
    assert_eq!(result.ai[0].id, 2);
    assert_eq!(result.metrics.baseline_candidate_count, 2);
    assert_eq!(result.metrics.ai_candidate_count, 2);
    assert_eq!(result.metrics.changed_positions, 2);
    assert_eq!(coordinator.backend().calls(), 1);
}

#[test]
fn stale_enhancement_is_rejected_after_a_key_generation_change() {
    let (mut broker, token) = create(FieldClass::Regular);
    broker.handle(RequestEnvelope::new(
        3,
        RequestCommand::Key(KeyRequest {
            session_id: 9,
            generation: 0,
            key: KeyEvent::Character {
                value: "か".to_owned(),
            },
        }),
    ));
    let backend = FakeBackend::default();
    let coordinator =
        EnhancementCoordinator::with_policy(backend, EnhancementPolicy::LocalQualityOnly);
    let request = RequestEnvelope::new(
        4,
        RequestCommand::RerankCandidates(CandidateRerankRequest::new(9, 0, candidates())),
    );
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let response = runtime.block_on(coordinator.handle(request, token, CancellationToken::new()));
    assert_eq!(
        response.error().expect("stale response").code,
        ErrorCode::StaleGeneration
    );
    assert_eq!(coordinator.backend().calls(), 0);
}

#[test]
fn secure_field_and_consent_skips_never_reach_provider() {
    let (_broker, token) = create(FieldClass::Password);
    let backend = FakeBackend::default();
    let coordinator =
        EnhancementCoordinator::with_policy(backend, EnhancementPolicy::LocalQualityOnly);
    let rerank = RequestEnvelope::new(
        5,
        RequestCommand::RerankCandidates(CandidateRerankRequest::new(9, 0, candidates())),
    );
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let response =
        runtime.block_on(coordinator.handle(rerank, token.clone(), CancellationToken::new()));
    let payload = response.payload().expect("secure response");
    let ResponsePayload::RerankCandidates(result) = payload else {
        panic!("expected rerank");
    };
    assert_eq!(result.status, EnhancementStatus::Skipped);
    assert_eq!(result.reason, EnhancementReason::SecureField);
    assert_eq!(coordinator.backend().calls(), 0);

    let (_normal_broker, normal_token) = create(FieldClass::Regular);
    let semantic = RequestEnvelope::new(
        6,
        RequestCommand::SemanticAssist(SemanticAssistRequest {
            consent: false,
            ..SemanticAssistRequest::new(9, 0, SemanticIntent::Suggest, "text")
        }),
    );
    let response =
        runtime.block_on(coordinator.handle(semantic, normal_token, CancellationToken::new()));
    let payload = response.payload().expect("consent response");
    let ResponsePayload::SemanticAssist(result) = payload else {
        panic!("expected semantic assist");
    };
    assert_eq!(result.status, EnhancementStatus::Skipped);
    assert_eq!(result.reason, EnhancementReason::ConsentRequired);
    assert_eq!(coordinator.backend().calls(), 0);
}

#[test]
fn optional_job_can_be_cancelled_by_request_id() {
    let (_broker, token) = create(FieldClass::Regular);
    let backend = FakeBackend {
        calls: AtomicUsize::new(0),
        delay_ms: 100,
    };
    let coordinator = std::sync::Arc::new(EnhancementCoordinator::with_policy(
        backend,
        EnhancementPolicy::LocalQualityOnly,
    ));
    let request = RequestEnvelope::new(
        70,
        RequestCommand::RerankCandidates(CandidateRerankRequest::new(9, 0, candidates())),
    );
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let response = runtime.block_on(async {
        let task = tokio::spawn({
            let coordinator = std::sync::Arc::clone(&coordinator);
            async move {
                coordinator
                    .handle(request, token, CancellationToken::new())
                    .await
            }
        });
        for _ in 0..10 {
            if coordinator.cancellations().active_requests() > 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        assert!(coordinator.cancel_request(70));
        task.await.expect("job task")
    });
    let payload = response.payload().expect("cancelled response");
    let ResponsePayload::RerankCandidates(result) = payload else {
        panic!("expected rerank");
    };
    assert_eq!(result.status, EnhancementStatus::Cancelled);
    assert_eq!(result.reason, EnhancementReason::Cancelled);
}

#[test]
fn enhancement_timeout_returns_baseline_instead_of_blocking_the_key_path() {
    let (_broker, token) = create(FieldClass::Regular);
    let backend = FakeBackend {
        calls: AtomicUsize::new(0),
        delay_ms: 100,
    };
    let coordinator =
        EnhancementCoordinator::with_policy(backend, EnhancementPolicy::LocalQualityOnly);
    let mut request = CandidateRerankRequest::new(9, 0, candidates());
    request.deadline_ms = 1;
    let envelope = RequestEnvelope::new(7, RequestCommand::RerankCandidates(request));
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let response = runtime.block_on(coordinator.handle(envelope, token, CancellationToken::new()));
    let payload = response.payload().expect("timeout response");
    let ResponsePayload::RerankCandidates(result) = payload else {
        panic!("expected rerank");
    };
    assert_eq!(result.status, EnhancementStatus::TimedOut);
    assert_eq!(result.reason, EnhancementReason::ProviderTimeout);
    assert_eq!(result.baseline, result.ai);
    assert!(!result.adopted);
}

#[test]
fn enhancement_requests_reject_unbounded_deadlines_and_candidate_ids() {
    let mut request = CandidateRerankRequest::new(9, 0, candidates());
    request.deadline_ms = 0;
    assert!(request.validate().is_err());

    let duplicate = vec![
        Candidate {
            id: 1,
            text: "one".to_owned(),
            reading: None,
            rank: 0,
        },
        Candidate {
            id: 1,
            text: "two".to_owned(),
            reading: None,
            rank: 1,
        },
    ];
    assert!(
        CandidateRerankRequest::new(9, 0, duplicate)
            .validate()
            .is_err()
    );
}

#[test]
fn synchronous_broker_rejects_optional_commands_before_backend_dispatch() {
    let mut broker = Broker::new(DeterministicBackend::new());
    broker.handle(RequestEnvelope::new(
        8,
        RequestCommand::CreateSession(CreateSessionRequest::new(9, "ja-JP")),
    ));
    let response = broker.handle(RequestEnvelope::new(
        9,
        RequestCommand::RerankCandidates(CandidateRerankRequest::new(9, 0, candidates())),
    ));
    assert_eq!(
        response.error().expect("async boundary").code,
        ErrorCode::EnhancementRequiresAsync
    );
}
