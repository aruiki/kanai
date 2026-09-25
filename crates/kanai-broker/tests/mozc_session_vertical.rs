//! Real-process coverage for the session-aware broker adapter.
//!
//! This test uses the pinned Mozc bridge when it has been built. It is kept
//! separate from the synthetic contract tests so a missing optional C++
//! artifact is visible in the verification log rather than silently replaced
//! by a fake provider.

use std::path::PathBuf;
#[cfg(unix)]
use std::process::Command as StdCommand;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use kanai_broker::{
    CancellationToken, CandidateRerankRequest, CommitRequest, ConvertRequest, CreateSessionRequest,
    EditAction, EditRequest, EnhancementBackend, EnhancementError, EnhancementFeature,
    EnhancementMetrics, EnhancementPolicy, FieldClass, FocusLostRequest, KeyEvent, KeyRequest,
    MozcSessionBackend, ProviderLocality, RequestCommand, RequestEnvelope, RerankOutput,
    ResponsePayload, SessionBroker,
};
use kanai_mozc::MozcBridgeConfig;

struct DelayedLocal;

#[async_trait]
impl EnhancementBackend for DelayedLocal {
    fn provider_id(&self) -> &str {
        "real-bridge-test-local"
    }

    fn locality(&self) -> ProviderLocality {
        ProviderLocality::Local
    }

    async fn rerank(
        &self,
        request: CandidateRerankRequest,
        cancellation: CancellationToken,
    ) -> Result<RerankOutput, EnhancementError> {
        tokio::time::sleep(Duration::from_millis(25)).await;
        if cancellation.is_cancelled() {
            return Err(EnhancementError::Cancelled);
        }
        let mut candidates = request.candidates;
        candidates.reverse();
        Ok(RerankOutput {
            adopted: true,
            metrics: EnhancementMetrics::baseline(
                EnhancementFeature::CandidateRerank,
                "real-bridge-test-local",
                ProviderLocality::Local,
                candidates.len() as u16,
                request.deadline_ms,
            ),
            candidates,
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

fn bridge_path() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("KANAI_MOZC_BRIDGE") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Some(path);
        }
    }
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../third_party/mozc/src/bazel-bin/kanai/kanai_mozc_bridge");
    path.is_file().then_some(path)
}

#[cfg(unix)]
async fn wait_for_pid_exit(pid: u32) -> bool {
    let path = format!("/proc/{pid}");
    for _ in 0..100 {
        if !std::path::Path::new(&path).exists() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    false
}

#[tokio::test]
async fn real_mozc_session_survives_stale_optional_work_and_generation_checked_commit() {
    let Some(binary_path) = bridge_path() else {
        if std::env::var("KANAI_REQUIRE_MOZC_BRIDGE").is_ok() {
            panic!("KANAI_MOZC_BRIDGE is required for this integration test");
        }
        eprintln!("skipping real Mozc session test: build //kanai:kanai_mozc_bridge first");
        return;
    };
    let profile = tempfile::tempdir().expect("profile");
    let broker = SessionBroker::new(MozcSessionBackend::new(MozcBridgeConfig {
        binary_path,
        profile_dir: profile.path().join("mozc"),
        request_timeout: Duration::from_secs(10),
    }));
    let created = broker
        .handle(RequestEnvelope::new(
            1,
            RequestCommand::CreateSession(CreateSessionRequest {
                session_id: 7,
                locale: "ja-JP".to_owned(),
                field_class: FieldClass::Regular,
            }),
        ))
        .await;
    assert!(created.payload().is_some());
    let key = broker
        .handle(RequestEnvelope::new(
            2,
            RequestCommand::Key(KeyRequest {
                session_id: 7,
                generation: 0,
                key: KeyEvent::Character {
                    value: "kyou".to_owned(),
                },
            }),
        ))
        .await;
    assert!(matches!(key.payload(), Some(ResponsePayload::Key(_))));
    let converted = broker
        .handle(RequestEnvelope::new(
            3,
            RequestCommand::Convert(ConvertRequest {
                session_id: 7,
                generation: 1,
                page: 0,
                page_size: 9,
            }),
        ))
        .await;
    let ResponsePayload::Convert(converted) = converted.payload().expect("real candidates") else {
        panic!("convert response")
    };
    assert!(!converted.candidates.is_empty());
    assert!(converted.candidates.len() >= 2);

    let queue = Arc::new(
        kanai_broker::EnhancementQueue::start(
            DelayedLocal,
            EnhancementPolicy::LocalQualityOnly,
            4,
            1,
        )
        .expect("queue"),
    );
    let rerank = RequestEnvelope::new(
        4,
        RequestCommand::RerankCandidates(CandidateRerankRequest::new(
            7,
            2,
            converted.candidates.clone(),
        )),
    );
    let broker_for_job = broker.clone();
    let queue_for_job = Arc::clone(&queue);
    let job = tokio::spawn(async move {
        broker_for_job
            .submit_enhancement(rerank, queue_for_job.as_ref(), CancellationToken::new())
            .await
    });
    tokio::time::sleep(Duration::from_millis(1)).await;
    // A later key invalidates the captured generation before the model returns.
    let stale_key = broker
        .handle(RequestEnvelope::new(
            5,
            RequestCommand::Key(KeyRequest {
                session_id: 7,
                generation: 2,
                key: KeyEvent::Character {
                    value: "!".to_owned(),
                },
            }),
        ))
        .await;
    assert!(stale_key.payload().is_some());
    let stale = job.await.expect("optional task");
    assert_eq!(
        stale.error().expect("stale optional response").code,
        kanai_broker::ErrorCode::StaleGeneration
    );

    // Start a fresh generation and prove the real Mozc bridge still enforces
    // the commit correlation rather than accepting the old candidate list.
    let edit = broker
        .handle(RequestEnvelope::new(
            6,
            RequestCommand::Edit(EditRequest {
                session_id: 7,
                generation: 3,
                action: EditAction::Reset,
            }),
        ))
        .await;
    assert!(edit.payload().is_some());
    let key = broker
        .handle(RequestEnvelope::new(
            7,
            RequestCommand::Key(KeyRequest {
                session_id: 7,
                generation: 4,
                key: KeyEvent::Character {
                    value: "kyou".to_owned(),
                },
            }),
        ))
        .await;
    assert!(key.payload().is_some());
    let converted = broker
        .handle(RequestEnvelope::new(
            8,
            RequestCommand::Convert(ConvertRequest {
                session_id: 7,
                generation: 5,
                page: 0,
                page_size: 9,
            }),
        ))
        .await;
    let ResponsePayload::Convert(converted) = converted.payload().expect("fresh candidates") else {
        panic!("fresh convert response")
    };
    let selected = converted.candidates[0].id;
    let commit = broker
        .handle(RequestEnvelope::new(
            9,
            RequestCommand::Commit(kanai_broker::CommitRequest {
                session_id: 7,
                generation: 6,
                candidate_id: selected,
            }),
        ))
        .await;
    assert!(matches!(commit.payload(), Some(ResponsePayload::Commit(_))));
    assert!(!profile.path().join("mozc/session-7/.history.db").exists());
    assert!(!profile.path().join("mozc/.history.db").exists());
}

#[tokio::test]
async fn real_mozc_edit_uses_rendered_composition_coordinates() {
    let Some(binary_path) = bridge_path() else {
        if std::env::var("KANAI_REQUIRE_MOZC_BRIDGE").is_ok() {
            panic!("KANAI_MOZC_BRIDGE is required for this integration test");
        }
        eprintln!("skipping real Mozc edit-coordinate test: build //kanai:kanai_mozc_bridge first");
        return;
    };
    let profile = tempfile::tempdir().expect("profile");
    let broker = SessionBroker::new(MozcSessionBackend::new(MozcBridgeConfig {
        binary_path,
        profile_dir: profile.path().join("mozc"),
        request_timeout: Duration::from_secs(10),
    }));
    let created = broker
        .handle(RequestEnvelope::new(
            1,
            RequestCommand::CreateSession(CreateSessionRequest::new(77, "ja-JP")),
        ))
        .await;
    assert!(matches!(
        created.payload(),
        Some(ResponsePayload::Created(_))
    ));

    let key = broker
        .handle(RequestEnvelope::new(
            2,
            RequestCommand::Key(KeyRequest {
                session_id: 77,
                generation: 0,
                key: KeyEvent::Character {
                    value: "kyou".to_owned(),
                },
            }),
        ))
        .await;
    let Some(ResponsePayload::Key(key)) = key.payload() else {
        panic!("key response");
    };
    assert_eq!(key.preedit, "きょう");

    // The host range is expressed in rendered Unicode scalars, not in the
    // raw ASCII string "kyou". This must stay aligned with the C++ owner.
    let edit = broker
        .handle(RequestEnvelope::new(
            3,
            RequestCommand::Edit(EditRequest {
                session_id: 77,
                generation: 1,
                action: EditAction::Delete {
                    range: kanai_broker::TextRange { start: 0, end: 1 },
                },
            }),
        ))
        .await;
    let Some(ResponsePayload::Edit(edit)) = edit.payload() else {
        panic!("edit response");
    };
    assert_eq!(edit.preedit, "ょう");
}

#[tokio::test]
async fn real_mozc_pool_keeps_sessions_independent_and_closes_them() {
    let Some(binary_path) = bridge_path() else {
        if std::env::var("KANAI_REQUIRE_MOZC_BRIDGE").is_ok() {
            panic!("KANAI_MOZC_BRIDGE is required for this integration test");
        }
        eprintln!("skipping real Mozc pool test: build //kanai:kanai_mozc_bridge first");
        return;
    };
    let profile = tempfile::tempdir().expect("profile");
    let broker = SessionBroker::new(MozcSessionBackend::new(MozcBridgeConfig {
        binary_path,
        profile_dir: profile.path().join("mozc"),
        request_timeout: Duration::from_secs(10),
    }));

    for (request_id, session_id) in [(1, 21), (2, 22)] {
        let created = broker
            .handle(RequestEnvelope::new(
                request_id,
                RequestCommand::CreateSession(CreateSessionRequest::new(session_id, "ja-JP")),
            ))
            .await;
        assert!(matches!(
            created.payload(),
            Some(ResponsePayload::Created(_))
        ));
    }

    let shared_pid = broker
        .backend()
        .process_id()
        .await
        .expect("multiplexed bridge process");
    assert!(shared_pid > 0);

    for (request_id, session_id, text) in [(3, 21, "kyou"), (4, 22, "asa")] {
        let key = broker
            .handle(RequestEnvelope::new(
                request_id,
                RequestCommand::Key(KeyRequest {
                    session_id,
                    generation: 0,
                    key: KeyEvent::Character {
                        value: text.to_owned(),
                    },
                }),
            ))
            .await;
        assert!(matches!(key.payload(), Some(ResponsePayload::Key(_))));
    }

    let first = broker
        .handle(RequestEnvelope::new(
            5,
            RequestCommand::Convert(ConvertRequest {
                session_id: 21,
                generation: 1,
                page: 0,
                page_size: 9,
            }),
        ))
        .await;
    let ResponsePayload::Convert(first) = first.payload().expect("session 21 conversion") else {
        panic!("session 21 conversion response")
    };
    assert!(!first.candidates.is_empty());

    let selected_21 = first.candidates[0].id;
    let commit_21 = broker
        .handle(RequestEnvelope::new(
            8,
            RequestCommand::Commit(CommitRequest {
                session_id: 21,
                generation: 2,
                candidate_id: selected_21,
            }),
        ))
        .await;
    assert!(matches!(
        commit_21.payload(),
        Some(ResponsePayload::Commit(_))
    ));

    // Mutate only session 21. Session 22 must retain its own conversion
    // snapshot while the shared process serializes the upstream handler.
    let key = broker
        .handle(RequestEnvelope::new(
            6,
            RequestCommand::Key(KeyRequest {
                session_id: 21,
                generation: 3,
                key: KeyEvent::Character {
                    value: "kyou".to_owned(),
                },
            }),
        ))
        .await;
    assert!(matches!(key.payload(), Some(ResponsePayload::Key(_))));
    let second = broker
        .handle(RequestEnvelope::new(
            7,
            RequestCommand::Convert(ConvertRequest {
                session_id: 22,
                generation: 1,
                page: 0,
                page_size: 9,
            }),
        ))
        .await;
    let ResponsePayload::Convert(second) = second.payload().expect("session 22 conversion") else {
        panic!("session 22 conversion response")
    };
    assert!(!second.candidates.is_empty());

    let selected_22 = second.candidates[0].id;
    let commit_22 = broker
        .handle(RequestEnvelope::new(
            9,
            RequestCommand::Commit(CommitRequest {
                session_id: 22,
                generation: 2,
                candidate_id: selected_22,
            }),
        ))
        .await;
    assert!(matches!(
        commit_22.payload(),
        Some(ResponsePayload::Commit(_))
    ));

    for (request_id, session_id, generation) in [(10, 21, 4), (11, 22, 3)] {
        let focus = broker
            .handle(RequestEnvelope::new(
                request_id,
                RequestCommand::FocusLost(FocusLostRequest {
                    session_id,
                    generation,
                }),
            ))
            .await;
        assert!(matches!(
            focus.payload(),
            Some(ResponsePayload::FocusLost(_))
        ));
    }
    assert_eq!(broker.session_count().await, 0);
}

#[cfg(unix)]
#[tokio::test]
async fn real_mozc_bridge_kill_invalidates_sessions_and_restarts_safely() {
    let Some(binary_path) = bridge_path() else {
        if std::env::var("KANAI_REQUIRE_MOZC_BRIDGE").is_ok() {
            panic!("KANAI_MOZC_BRIDGE is required for this integration test");
        }
        eprintln!("skipping real Mozc recovery test: build //kanai:kanai_mozc_bridge first");
        return;
    };
    let profile = tempfile::tempdir().expect("profile");
    let broker = SessionBroker::new(MozcSessionBackend::new(MozcBridgeConfig {
        binary_path,
        profile_dir: profile.path().join("mozc"),
        request_timeout: Duration::from_secs(10),
    }));
    let mut last_pid = None;
    let mut first_candidate = None;
    let mut first_generation = 0;

    for cycle in 0..3_u64 {
        let session_id = 40 + cycle;
        let created = broker
            .handle(RequestEnvelope::new(
                100 + cycle * 10,
                RequestCommand::CreateSession(CreateSessionRequest::new(session_id, "ja-JP")),
            ))
            .await;
        assert!(matches!(
            created.payload(),
            Some(ResponsePayload::Created(_))
        ));

        let key = broker
            .handle(RequestEnvelope::new(
                101 + cycle * 10,
                RequestCommand::Key(KeyRequest {
                    session_id,
                    generation: 0,
                    key: KeyEvent::Character {
                        value: "kyou".to_owned(),
                    },
                }),
            ))
            .await;
        assert!(matches!(key.payload(), Some(ResponsePayload::Key(_))));
        let converted = broker
            .handle(RequestEnvelope::new(
                102 + cycle * 10,
                RequestCommand::Convert(ConvertRequest {
                    session_id,
                    generation: 1,
                    page: 0,
                    page_size: 9,
                }),
            ))
            .await;
        let ResponsePayload::Convert(converted) = converted.payload().expect("recovery candidates")
        else {
            panic!("recovery conversion response")
        };
        assert!(!converted.candidates.is_empty());
        if cycle == 0 {
            first_candidate = Some(converted.candidates[0].id);
            first_generation = converted.generation;
        }

        let pid = broker
            .backend()
            .process_id()
            .await
            .expect("bridge pid before kill");
        assert!(pid > 0);
        let status = StdCommand::new("kill")
            .args(["-KILL", &pid.to_string()])
            .status()
            .expect("kill bridge child");
        assert!(status.success());

        // The next operation observes EOF, fails closed, and invalidates every
        // broker session that shared the old child epoch.
        let interrupted = broker
            .handle(RequestEnvelope::new(
                103 + cycle * 10,
                RequestCommand::Key(KeyRequest {
                    session_id,
                    generation: 2,
                    key: KeyEvent::Character {
                        value: "!".to_owned(),
                    },
                }),
            ))
            .await;
        let error = interrupted.error().expect("interrupted operation");
        assert_eq!(error.code, kanai_broker::ErrorCode::BackendUnavailable);
        assert_eq!(error.fallback, kanai_broker::FallbackMode::DirectInput);
        assert_eq!(broker.session_count().await, 0);
        assert!(wait_for_pid_exit(pid).await);

        if cycle == 0 {
            let stale_commit = broker
                .handle(RequestEnvelope::new(
                    104,
                    RequestCommand::Commit(CommitRequest {
                        session_id,
                        generation: first_generation,
                        candidate_id: first_candidate.expect("pre-crash candidate"),
                    }),
                ))
                .await;
            assert_eq!(
                stale_commit.error().expect("stale commit").code,
                kanai_broker::ErrorCode::UnknownSession
            );
        }

        broker
            .backend()
            .restart_bridge()
            .await
            .expect("explicit bounded bridge restart");
        let new_pid = broker
            .backend()
            .process_id()
            .await
            .expect("replacement bridge pid");
        assert_ne!(new_pid, pid);
        last_pid = Some(new_pid);
    }

    drop(broker);
    if let Some(pid) = last_pid {
        assert!(wait_for_pid_exit(pid).await);
    }
}
