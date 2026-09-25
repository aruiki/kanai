use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use kanai_broker::{
    BackendError, CancellationToken, Candidate, CandidateRerankRequest, ConvertRequest,
    ConvertResponse, CreateSessionRequest, EditAction, EditRequest, EditResponse,
    EnhancementBackend, EnhancementCoordinator, EnhancementError, EnhancementFeature,
    EnhancementMetrics, EnhancementPolicy, EnhancementQueue, EnhancementReason, EnhancementStatus,
    FieldClass, FocusLostRequest, GenerationResponse, KeyEvent, KeyRequest, KeyResponse,
    MemoryTransport, PrepareRerankSessionRequest, ProviderLocality, RequestCommand,
    RequestEnvelope, RerankOutput, ResponsePayload, SessionBackend, SessionBroker, SharedSecret,
    SharedSecretAuthenticator, serve_authenticated_request,
};

#[derive(Default)]
struct FakeMozc {
    calls: AtomicUsize,
    fail_next: tokio::sync::Mutex<Option<BackendError>>,
}

impl FakeMozc {
    async fn maybe_fail(&self) -> Result<(), BackendError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some(error) = self.fail_next.lock().await.take() {
            return Err(error);
        }
        Ok(())
    }
}

#[async_trait]
impl SessionBackend for FakeMozc {
    async fn execute(
        &self,
        request: &kanai_broker::BrokerRequest,
        _cancellation: &CancellationToken,
    ) -> Result<kanai_broker::BrokerResponse, BackendError> {
        self.maybe_fail().await?;
        Ok(match request {
            RequestCommand::CreateSession(command) => {
                ResponsePayload::Created(kanai_broker::SessionCreated {
                    session_id: command.session_id,
                    generation: 0,
                    fallback: kanai_broker::FallbackMode::None,
                })
            }
            RequestCommand::PrepareRerankSession(_) => {
                return Err(BackendError::Protocol(
                    "rerank-only session reached the fake Mozc backend".to_owned(),
                ));
            }
            RequestCommand::Key(command) => ResponsePayload::Key(KeyResponse {
                session_id: command.session_id,
                generation: command.generation,
                preedit: "かな".to_owned(),
                consumed: true,
                candidates: Vec::new(),
                focused_index: None,
                fallback: kanai_broker::FallbackMode::None,
            }),
            RequestCommand::Edit(command) => ResponsePayload::Edit(EditResponse {
                session_id: command.session_id,
                generation: command.generation,
                preedit: "かな".to_owned(),
                consumed: true,
                candidates: Vec::new(),
                focused_index: None,
                fallback: kanai_broker::FallbackMode::None,
            }),
            RequestCommand::Convert(command) => ResponsePayload::Convert(ConvertResponse {
                session_id: command.session_id,
                generation: command.generation,
                preedit: "かな".to_owned(),
                consumed: true,
                candidates: vec![
                    Candidate {
                        id: 1,
                        text: "彼方".to_owned(),
                        reading: Some("かれかた".to_owned()),
                        rank: 0,
                    },
                    Candidate {
                        id: 2,
                        text: "かな".to_owned(),
                        reading: Some("かな".to_owned()),
                        rank: 1,
                    },
                ],
                focused_index: Some(0),
                page: command.page,
                page_size: command.page_size,
                has_more: false,
                fallback: kanai_broker::FallbackMode::None,
            }),
            RequestCommand::Commit(command) => {
                ResponsePayload::Commit(kanai_broker::CommitResponse {
                    session_id: command.session_id,
                    generation: command.generation,
                    text: "彼方".to_owned(),
                    consumed: true,
                })
            }
            RequestCommand::Cancel(command) => {
                ResponsePayload::Cancel(kanai_broker::CancelResponse {
                    session_id: command.session_id,
                    generation: command.generation.unwrap_or_default(),
                    target_request_id: command.target_request_id,
                })
            }
            RequestCommand::FocusLost(command) => {
                ResponsePayload::FocusLost(kanai_broker::FocusLostResponse {
                    session_id: command.session_id,
                    generation: command.generation,
                })
            }
            RequestCommand::Health(_) => {
                ResponsePayload::Health(kanai_broker::HealthResponse::ready(1_048_576))
            }
            RequestCommand::Generation(command) => {
                ResponsePayload::Generation(kanai_broker::GenerationResponse {
                    session_id: command.session_id,
                    generation: 0,
                })
            }
            RequestCommand::RerankCandidates(_) | RequestCommand::SemanticAssist(_) => {
                return Err(BackendError::Protocol(
                    "optional command reached synchronous backend".to_owned(),
                ));
            }
        })
    }
}

fn key(id: u64, generation: u64, value: &str) -> RequestEnvelope {
    RequestEnvelope::new(
        id,
        RequestCommand::Key(KeyRequest {
            session_id: 7,
            generation,
            key: KeyEvent::Character {
                value: value.to_owned(),
            },
        }),
    )
}

fn candidates() -> Vec<Candidate> {
    vec![
        Candidate {
            id: 1,
            text: "彼方".to_owned(),
            reading: Some("かれかた".to_owned()),
            rank: 0,
        },
        Candidate {
            id: 2,
            text: "かな".to_owned(),
            reading: Some("かな".to_owned()),
            rank: 1,
        },
    ]
}

#[derive(Default)]
struct SlowEnhancer {
    calls: AtomicUsize,
}

#[async_trait]
impl EnhancementBackend for SlowEnhancer {
    fn provider_id(&self) -> &str {
        "test-local"
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
        tokio::time::sleep(Duration::from_millis(20)).await;
        if cancellation.is_cancelled() {
            return Err(EnhancementError::Cancelled);
        }
        let mut candidates = request.candidates;
        candidates.reverse();
        Ok(RerankOutput {
            candidates,
            adopted: true,
            metrics: EnhancementMetrics::baseline(
                EnhancementFeature::CandidateRerank,
                "test-local",
                ProviderLocality::Local,
                2,
                request.deadline_ms,
            ),
        })
    }

    async fn semantic_assist(
        &self,
        _request: kanai_broker::SemanticAssistRequest,
        _cancellation: CancellationToken,
    ) -> Result<kanai_broker::SemanticAssistOutput, EnhancementError> {
        Err(EnhancementError::ProviderUnavailable("not used".to_owned()))
    }
}

fn create_session(
    broker: &SessionBroker<FakeMozc>,
    runtime: &tokio::runtime::Runtime,
    field: FieldClass,
) {
    let response = runtime.block_on(broker.handle(RequestEnvelope::new(
        1,
        RequestCommand::CreateSession(CreateSessionRequest {
            session_id: 7,
            locale: "ja-JP".to_owned(),
            field_class: field,
        }),
    )));
    assert!(response.payload().is_some());
}

#[test]
fn async_session_owner_preserves_request_ids_and_fallback_shape() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let backend = FakeMozc::default();
    let broker = SessionBroker::new(backend);
    create_session(&broker, &runtime, FieldClass::Regular);

    let response = runtime.block_on(broker.handle(key(2, 0, "か")));
    assert_eq!(response.request_id, 2);
    let ResponsePayload::Key(key_response) = response.payload().expect("key") else {
        panic!("key response")
    };
    assert_eq!(key_response.generation, 1);

    let response = runtime.block_on(broker.handle(RequestEnvelope::new(
        3,
        RequestCommand::Edit(EditRequest {
            session_id: 7,
            generation: 1,
            action: EditAction::Insert {
                text: "な".to_owned(),
            },
        }),
    )));
    assert_eq!(response.request_id, 3);
    assert!(matches!(response.payload(), Some(ResponsePayload::Edit(_))));

    let response = runtime.block_on(broker.handle(RequestEnvelope::new(
        4,
        RequestCommand::Convert(ConvertRequest {
            session_id: 7,
            generation: 2,
            page: 0,
            page_size: 9,
        }),
    )));
    assert_eq!(response.request_id, 4);
    assert!(matches!(
        response.payload(),
        Some(ResponsePayload::Convert(_))
    ));

    let stale = runtime.block_on(broker.handle(key(99, 1, "れ")));
    assert_eq!(stale.request_id, 99);
    assert_eq!(
        stale.error().expect("stale").code,
        kanai_broker::ErrorCode::StaleGeneration
    );
}

#[test]
fn prepare_rerank_session_admits_a_native_generation_without_a_mozc_backend_session() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let broker = SessionBroker::new(FakeMozc::default());
    let prepared = runtime.block_on(broker.handle(RequestEnvelope::new(
        1,
        RequestCommand::PrepareRerankSession(PrepareRerankSessionRequest {
            session_id: 9,
            generation: 4,
            field_class: FieldClass::Regular,
        }),
    )));
    assert!(matches!(
        prepared.payload(),
        Some(ResponsePayload::Generation(GenerationResponse { .. }))
    ));

    let stale = runtime.block_on(broker.handle(RequestEnvelope::new(
        2,
        RequestCommand::PrepareRerankSession(PrepareRerankSessionRequest {
            session_id: 9,
            generation: 3,
            field_class: FieldClass::Regular,
        }),
    )));
    assert_eq!(
        stale.error().expect("stale prepare").code,
        kanai_broker::ErrorCode::StaleGeneration
    );

    let advanced = runtime.block_on(broker.handle(RequestEnvelope::new(
        3,
        RequestCommand::PrepareRerankSession(PrepareRerankSessionRequest {
            session_id: 9,
            generation: 7,
            field_class: FieldClass::Regular,
        }),
    )));
    assert!(matches!(
        advanced.payload(),
        Some(ResponsePayload::Generation(GenerationResponse {
            generation: 7,
            ..
        }))
    ));

    let queue = Arc::new(runtime.block_on(async {
        EnhancementQueue::start(
            SlowEnhancer::default(),
            EnhancementPolicy::LocalQualityOnly,
            2,
            1,
        )
        .expect("queue")
    }));
    let rerank = runtime.block_on(broker.submit_enhancement(
        RequestEnvelope::new(
            4,
            RequestCommand::RerankCandidates(CandidateRerankRequest::new(9, 7, candidates())),
        ),
        queue.as_ref(),
        CancellationToken::new(),
    ));
    assert!(rerank.payload().is_some());
    assert_eq!(runtime.block_on(broker.session_count()), 1);
    let released = runtime.block_on(broker.handle(RequestEnvelope::new(
        5,
        RequestCommand::FocusLost(FocusLostRequest {
            session_id: 9,
            generation: 7,
        }),
    )));
    assert!(matches!(
        released.payload(),
        Some(ResponsePayload::FocusLost(_))
    ));
    assert_eq!(runtime.block_on(broker.session_count()), 0);
}

#[test]
fn rejected_backend_request_rolls_back_generation_without_desynchronizing_next_command() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let broker = SessionBroker::new(FakeMozc::default());
    create_session(&broker, &runtime, FieldClass::Regular);

    let first = runtime.block_on(broker.handle(key(2, 0, "か")));
    assert!(matches!(first.payload(), Some(ResponsePayload::Key(_))));
    runtime.block_on(async {
        *broker.backend().fail_next.lock().await = Some(BackendError::Rejected(
            "synthetic pre-mutation rejection".to_owned(),
        ));
    });

    let rejected = runtime.block_on(broker.handle(key(3, 1, "な")));
    let Some(ResponsePayload::Key(rejected)) = rejected.payload() else {
        panic!("rejected key should retain a baseline key response")
    };
    assert_eq!(rejected.generation, 1);
    assert_eq!(
        rejected.fallback,
        kanai_broker::FallbackMode::LastValidPreedit
    );

    let recovered = runtime.block_on(broker.handle(key(4, 1, "は")));
    assert!(matches!(recovered.payload(), Some(ResponsePayload::Key(_))));
    assert_eq!(runtime.block_on(broker.generation(7)), Some(2));
}

#[test]
fn backend_epoch_invalidation_removes_session_and_blocks_id_reuse() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let backend = FakeMozc::default();
    let broker = SessionBroker::new(backend);
    create_session(&broker, &runtime, FieldClass::Regular);
    runtime.block_on(async {
        *broker.backend().fail_next.lock().await = Some(BackendError::SessionInvalidated);
    });

    let response = runtime.block_on(broker.handle(key(2, 0, "か")));
    let error = response.error().expect("invalidation response");
    assert_eq!(error.code, kanai_broker::ErrorCode::BackendUnavailable);
    assert_eq!(error.fallback, kanai_broker::FallbackMode::DirectInput);
    assert_eq!(runtime.block_on(broker.session_count()), 0);

    let stale = runtime.block_on(broker.handle(key(3, 1, "な")));
    assert_eq!(
        stale.error().expect("stale invalidated session").code,
        kanai_broker::ErrorCode::UnknownSession
    );

    let reused = runtime.block_on(broker.handle(RequestEnvelope::new(
        4,
        RequestCommand::CreateSession(CreateSessionRequest::new(7, "ja-JP")),
    )));
    assert_eq!(
        reused.error().expect("tombstoned session").code,
        kanai_broker::ErrorCode::BackendUnavailable
    );

    let fresh = runtime.block_on(broker.handle(RequestEnvelope::new(
        5,
        RequestCommand::CreateSession(CreateSessionRequest::new(8, "ja-JP")),
    )));
    assert!(fresh.payload().is_some());
}

#[test]
fn optional_queue_rejects_stale_results_and_times_out_to_baseline() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let broker = SessionBroker::new(FakeMozc::default());
    create_session(&broker, &runtime, FieldClass::Regular);
    runtime.block_on(broker.handle(key(2, 0, "か")));

    let queue = Arc::new(runtime.block_on(async {
        kanai_broker::EnhancementQueue::start(
            SlowEnhancer::default(),
            EnhancementPolicy::LocalQualityOnly,
            4,
            2,
        )
        .expect("queue")
    }));
    let request = RequestEnvelope::new(
        3,
        RequestCommand::RerankCandidates(CandidateRerankRequest::new(7, 1, candidates())),
    );
    let broker_for_job = broker.clone();
    let queue_for_job = Arc::clone(&queue);
    let job = runtime.spawn(async move {
        broker_for_job
            .submit_enhancement(request, queue_for_job.as_ref(), CancellationToken::new())
            .await
    });
    runtime.block_on(async {
        tokio::time::sleep(Duration::from_millis(1)).await;
    });
    runtime.block_on(broker.handle(key(4, 1, "な")));
    let stale = runtime.block_on(job).expect("job task");
    assert_eq!(stale.request_id, 3);
    assert_eq!(
        stale.error().expect("stale optional result").code,
        kanai_broker::ErrorCode::StaleGeneration
    );

    let mut timeout_request = CandidateRerankRequest::new(7, 2, candidates());
    timeout_request.deadline_ms = 1;
    let response = runtime.block_on(broker.submit_enhancement(
        RequestEnvelope::new(5, RequestCommand::RerankCandidates(timeout_request)),
        queue.as_ref(),
        CancellationToken::new(),
    ));
    let ResponsePayload::RerankCandidates(result) = response.payload().expect("timeout result")
    else {
        panic!("rerank response")
    };
    assert_eq!(result.status, EnhancementStatus::TimedOut);
    assert_eq!(result.reason, EnhancementReason::ProviderTimeout);
    assert_eq!(result.baseline, result.ai);
    assert!(!result.adopted);
}

#[test]
fn secure_field_optional_work_is_skipped_before_provider_call() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let broker = SessionBroker::new(FakeMozc::default());
    create_session(&broker, &runtime, FieldClass::Password);
    let coordinator = Arc::new(EnhancementCoordinator::with_policy(
        SlowEnhancer::default(),
        EnhancementPolicy::LocalQualityOnly,
    ));
    let queue = runtime.block_on(async {
        kanai_broker::EnhancementQueue::from_coordinator(coordinator, 2, 1).expect("queue")
    });
    let token = runtime
        .block_on(broker.enhancement_token(7))
        .expect("token");
    assert_eq!(
        token.secure_field_policy(),
        kanai_broker::SecureFieldPolicy::Prohibit
    );
    let response = runtime.block_on(broker.submit_enhancement(
        RequestEnvelope::new(
            2,
            RequestCommand::RerankCandidates(CandidateRerankRequest::new(7, 0, candidates())),
        ),
        &queue,
        CancellationToken::new(),
    ));
    let ResponsePayload::RerankCandidates(result) = response.payload().expect("secure result")
    else {
        panic!("rerank response")
    };
    assert_eq!(result.status, EnhancementStatus::Skipped);
    assert_eq!(result.reason, EnhancementReason::SecureField);
}

#[test]
fn a_new_convert_snapshot_invalidates_an_older_optional_result() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let broker = SessionBroker::new(FakeMozc::default());
    create_session(&broker, &runtime, FieldClass::Regular);
    runtime.block_on(broker.handle(key(2, 0, "か")));
    let first_convert = runtime.block_on(broker.handle(RequestEnvelope::new(
        3,
        RequestCommand::Convert(kanai_broker::ConvertRequest {
            session_id: 7,
            generation: 1,
            page: 0,
            page_size: 9,
        }),
    )));
    let first_generation = first_convert.generation.expect("first generation");
    assert_eq!(first_generation, 2);
    let ResponsePayload::Convert(first) = first_convert.payload().expect("first convert") else {
        panic!("first convert response")
    };
    let queue = Arc::new(runtime.block_on(async {
        kanai_broker::EnhancementQueue::start(
            SlowEnhancer::default(),
            EnhancementPolicy::LocalQualityOnly,
            4,
            1,
        )
        .expect("queue")
    }));
    let request = RequestEnvelope::new(
        4,
        RequestCommand::RerankCandidates(CandidateRerankRequest::new(
            7,
            first_generation,
            first.candidates.clone(),
        )),
    );
    let broker_for_job = broker.clone();
    let queue_for_job = Arc::clone(&queue);
    let job = runtime.spawn(async move {
        broker_for_job
            .submit_enhancement(request, queue_for_job.as_ref(), CancellationToken::new())
            .await
    });
    runtime.block_on(async {
        tokio::time::sleep(Duration::from_millis(1)).await;
    });
    let second_convert = runtime.block_on(broker.handle(RequestEnvelope::new(
        5,
        RequestCommand::Convert(kanai_broker::ConvertRequest {
            session_id: 7,
            generation: first_generation,
            page: 0,
            page_size: 9,
        }),
    )));
    assert_eq!(second_convert.generation, Some(first_generation + 1));
    let stale = runtime.block_on(job).expect("optional task");
    assert_eq!(
        stale.error().expect("stale optional result").code,
        kanai_broker::ErrorCode::StaleGeneration
    );
}

#[test]
fn authenticated_owner_is_required_for_session_commands() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let broker = SessionBroker::new(FakeMozc::default());
    runtime.block_on(broker.handle_for_peer(
        RequestEnvelope::new(
            1,
            RequestCommand::CreateSession(CreateSessionRequest::new(7, "ja-JP")),
        ),
        "peer-a",
    ));
    let foreign = runtime.block_on(broker.handle_for_peer(key(2, 0, "か"), "peer-b"));
    assert_eq!(
        foreign.error().expect("foreign session").code,
        kanai_broker::ErrorCode::UnknownSession
    );
    let owner = runtime.block_on(broker.handle_for_peer(key(3, 0, "か"), "peer-a"));
    assert!(matches!(owner.payload(), Some(ResponsePayload::Key(_))));
}

#[test]
fn queue_keeps_only_the_latest_job_for_a_session() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let broker = SessionBroker::new(FakeMozc::default());
    create_session(&broker, &runtime, FieldClass::Regular);
    let queue = Arc::new(runtime.block_on(async {
        kanai_broker::EnhancementQueue::start(
            SlowEnhancer::default(),
            EnhancementPolicy::LocalQualityOnly,
            4,
            1,
        )
        .expect("queue")
    }));
    let first = RequestEnvelope::new(
        2,
        RequestCommand::RerankCandidates(CandidateRerankRequest::new(7, 0, candidates())),
    );
    let broker_for_first = broker.clone();
    let queue_for_first = Arc::clone(&queue);
    let first_job = runtime.spawn(async move {
        broker_for_first
            .submit_enhancement(first, queue_for_first.as_ref(), CancellationToken::new())
            .await
    });
    runtime.block_on(async {
        tokio::time::sleep(Duration::from_millis(1)).await;
    });
    let second = runtime.block_on(broker.submit_enhancement(
        RequestEnvelope::new(
            3,
            RequestCommand::RerankCandidates(CandidateRerankRequest::new(7, 0, candidates())),
        ),
        queue.as_ref(),
        CancellationToken::new(),
    ));
    let first_response = runtime.block_on(first_job).expect("first job");
    let ResponsePayload::RerankCandidates(first_result) =
        first_response.payload().expect("first result")
    else {
        panic!("first rerank result")
    };
    assert_eq!(first_result.status, EnhancementStatus::Cancelled);
    assert!(!first_result.adopted);
    assert!(matches!(
        second.payload(),
        Some(ResponsePayload::RerankCandidates(_))
    ));
}

#[test]
fn focus_loss_invalidates_a_token_before_backend_teardown() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let broker = SessionBroker::new(FakeMozc::default());
    create_session(&broker, &runtime, FieldClass::Regular);
    let token = runtime
        .block_on(broker.enhancement_token(7))
        .expect("token");
    runtime.block_on(broker.handle(RequestEnvelope::new(
        2,
        RequestCommand::FocusLost(FocusLostRequest {
            session_id: 7,
            generation: 0,
        }),
    )));
    assert!(!token.is_current());
    assert_eq!(runtime.block_on(broker.session_count()), 0);
}

#[test]
fn authenticated_transport_completes_handshake_before_dispatch() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let broker = Arc::new(SessionBroker::new(FakeMozc::default()));
    let queue = Arc::new(runtime.block_on(async {
        kanai_broker::EnhancementQueue::start(
            SlowEnhancer::default(),
            EnhancementPolicy::Disabled,
            2,
            1,
        )
        .expect("queue")
    }));
    let secret = SharedSecret::new(b"test-secret".to_vec()).expect("secret");
    let authenticator = Arc::new(SharedSecretAuthenticator::new(
        secret,
        Some("tip-test".to_owned()),
    ));
    let auth = authenticator
        .make_request("tip-test")
        .expect("auth request");
    let request = RequestEnvelope::new(
        10,
        RequestCommand::CreateSession(CreateSessionRequest::new(7, "ja-JP")),
    );
    let mut transport = MemoryTransport::new(64 * 1024).expect("transport");
    transport
        .push_incoming(serde_json::to_vec(&auth).expect("auth json"))
        .expect("auth frame");
    transport
        .push_incoming(serde_json::to_vec(&request).expect("request json"))
        .expect("request frame");

    let response = runtime.block_on(serve_authenticated_request(
        &mut transport,
        Arc::clone(&broker),
        queue,
        authenticator,
    ));
    assert!(response.is_ok());
    let outgoing = transport.take_outgoing();
    assert_eq!(outgoing.len(), 2);
    let auth_response: kanai_broker::AuthResponse =
        serde_json::from_slice(&outgoing[0]).expect("auth response");
    assert!(auth_response.accepted);
    let response: kanai_broker::ResponseEnvelope =
        serde_json::from_slice(&outgoing[1]).expect("broker response");
    assert!(matches!(
        response.payload(),
        Some(ResponsePayload::Created(_))
    ));
}
