use std::sync::Arc;

use kanai_broker::{
    AuthenticatedTransport, BackendError, Broker, BrokerConfig, CancellationRegistry,
    CancellationToken, DeterministicBackend, ErrorCode, FallbackMode, Frame, FrameCodec,
    FrameDecoder, FrameError, MemoryTransport, PROTOCOL_VERSION, RequestCommand, RequestEnvelope,
    SharedSecret, SharedSecretAuthenticator, Transport, TransportError,
};
use kanai_broker::{
    ConvertRequest, CreateSessionRequest, EditAction, EditRequest, FocusLostRequest, KeyEvent,
    KeyRequest, SessionCreated,
};

fn create_request(id: u64) -> RequestEnvelope {
    RequestEnvelope::new(
        id,
        RequestCommand::CreateSession(CreateSessionRequest::new(7, "ja-JP")),
    )
}

fn key_request(id: u64, generation: u64, value: &str) -> RequestEnvelope {
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

#[test]
fn protocol_round_trip_is_versioned_and_validated() {
    let request = create_request(1);
    let bytes = kanai_broker::encode_request(&request).expect("request encodes");
    assert!(bytes.windows(4).any(|window| window == b"\"ver"));
    let decoded = kanai_broker::decode_request(&bytes).expect("request decodes");
    assert_eq!(decoded, request);
    assert_eq!(decoded.version, PROTOCOL_VERSION);

    let mut unsupported = request;
    unsupported.version = PROTOCOL_VERSION + 1;
    let error = kanai_broker::decode_request(
        &serde_json::to_vec(&unsupported).expect("unsupported request serializes"),
    )
    .expect_err("newer protocol must fail closed");
    assert!(error.to_string().contains("unsupported protocol version"));
}

#[test]
fn protocol_rejects_unbounded_or_ambiguous_input() {
    let mut request = RequestEnvelope::new(
        2,
        RequestCommand::Edit(EditRequest {
            session_id: 7,
            generation: 0,
            action: EditAction::Insert {
                text: "x".repeat(16 * 1024 + 1),
            },
        }),
    );
    assert!(kanai_broker::encode_request(&request).is_err());

    request.command = RequestCommand::CreateSession(CreateSessionRequest {
        session_id: 0,
        ..CreateSessionRequest::new(0, "ja-JP")
    });
    assert!(kanai_broker::encode_request(&request).is_err());
}

#[test]
fn framing_is_bounded_and_streaming_decoder_handles_splits() {
    let codec = FrameCodec::new(32).expect("codec");
    let encoded = codec.encode(b"hello").expect("frame encodes");
    let decoded = codec.decode(&encoded).expect("frame decodes");
    assert_eq!(decoded.payload, b"hello");
    assert_eq!(decoded.consumed, encoded.len());

    let mut oversized = vec![b'K', b'B', b'F', b'1'];
    oversized.extend_from_slice(&33_u32.to_be_bytes());
    assert_eq!(
        codec.decode(&oversized),
        Err(FrameError::PayloadTooLarge { size: 33, max: 32 })
    );

    let mut decoder = FrameDecoder::new(32).expect("decoder");
    let mut frames = Vec::new();
    for byte in &encoded {
        frames.extend(
            decoder
                .push(std::slice::from_ref(byte))
                .expect("partial frame"),
        );
    }
    assert_eq!(frames, vec![b"hello".to_vec()]);
    assert!(decoder.finish().is_ok());

    let mut concatenated = encoded.clone();
    concatenated.extend_from_slice(&encoded);
    let frames = decoder.push(&concatenated).expect("concatenated frames");
    assert_eq!(frames.len(), 2);
    assert!(decoder.finish().is_ok());
}

#[test]
fn transport_helpers_keep_json_inside_the_frame_bound() {
    let mut memory = MemoryTransport::new(256).expect("memory transport");
    let request = create_request(50);
    kanai_broker::send_request(&mut memory, &request).expect("request sends");
    let encoded = memory
        .take_outgoing()
        .pop()
        .expect("outgoing frame payload");
    assert!(encoded.len() <= 256);
    assert_eq!(
        kanai_broker::decode_request(&encoded).expect("outgoing request"),
        request
    );
}

#[test]
fn authenticated_transport_fails_closed_before_handshake() {
    let memory = MemoryTransport::new(64).expect("memory transport");
    let secret = SharedSecret::new(b"test-only-secret".to_vec()).expect("secret");
    let authenticator = SharedSecretAuthenticator::new(secret, Some("tip-32".to_owned()));
    let request = authenticator.make_request("tip-32").expect("auth request");
    let mut transport = AuthenticatedTransport::new(memory, Arc::new(authenticator));

    let frame = Frame::new(b"request".to_vec()).expect("frame");
    assert!(matches!(
        transport.send(frame),
        Err(TransportError::Unauthenticated)
    ));
    assert!(matches!(
        transport.receive(),
        Err(TransportError::Unauthenticated)
    ));

    let mut wrong = request.clone();
    wrong.proof = b"wrong".to_vec();
    assert!(transport.accept(&wrong).is_err());
    assert!(!transport.is_authenticated());

    let auth_json = serde_json::to_vec(&request).expect("auth serializes");
    let auth_response = transport
        .accept_json(&auth_json)
        .expect("valid auth response");
    assert!(auth_response.accepted);
    assert_eq!(
        auth_response.peer.expect("authenticated peer").client_id,
        "tip-32"
    );
    assert!(transport.is_authenticated());
    let frame = Frame::new(b"request".to_vec()).expect("frame");
    transport.send(frame).expect("authenticated send");
    assert_eq!(
        transport.get_mut().take_outgoing(),
        vec![b"request".to_vec()]
    );
}

#[test]
fn broker_advances_generation_and_rejects_stale_results() {
    let mut broker = Broker::new(DeterministicBackend::new());
    let created = broker.handle(create_request(10));
    let created_payload = created.payload().expect("create succeeds");
    assert!(matches!(
        created_payload,
        kanai_broker::ResponsePayload::Created(SessionCreated { generation: 0, .. })
    ));

    let key = broker.handle(key_request(11, 0, "か"));
    let key_payload = key.payload().expect("key succeeds");
    assert!(matches!(
        key_payload,
        kanai_broker::ResponsePayload::Key(kanai_broker::KeyResponse { generation: 1, .. })
    ));

    let stale = broker.handle(key_request(12, 0, "な"));
    assert_eq!(
        stale.error().expect("stale error").code,
        ErrorCode::StaleGeneration
    );
    assert_eq!(stale.generation, Some(1));
    assert_eq!(broker.generation(7), Some(1));
}

#[test]
fn broker_fallback_is_local_deterministic_and_never_fabricates_commit() {
    let backend = DeterministicBackend::new();
    let mut broker = Broker::with_config(
        backend,
        BrokerConfig {
            fallback: kanai_broker::FallbackPolicy::LastValidPreedit,
            max_sessions: 8,
        },
    );
    broker.handle(create_request(20));
    broker.handle(key_request(21, 0, "かな"));

    broker.backend_mut().fail_next(BackendError::Timeout);
    let fallback = broker.handle(key_request(22, 1, "漢字"));
    let payload = fallback.payload().expect("fallback is a response");
    let kanai_broker::ResponsePayload::Key(response) = payload else {
        panic!("expected key fallback");
    };
    assert_eq!(response.generation, 2);
    assert_eq!(response.preedit, "かな");
    assert!(!response.consumed);
    assert_eq!(response.fallback, FallbackMode::LastValidPreedit);

    broker
        .backend_mut()
        .fail_next(BackendError::Unavailable("offline".to_owned()));
    let commit = broker.handle(RequestEnvelope::new(
        23,
        RequestCommand::Commit(kanai_broker::CommitRequest {
            session_id: 7,
            generation: 2,
            candidate_id: 1,
        }),
    ));
    let error = commit.error().expect("commit fails closed");
    assert_eq!(error.code, ErrorCode::BackendUnavailable);
    assert_eq!(error.fallback, FallbackMode::DirectInput);
}

#[test]
fn cancellation_focus_loss_and_health_are_explicit() {
    let mut broker = Broker::new(DeterministicBackend::new());
    broker.handle(create_request(30));
    let registry = broker.cancellations().clone();
    let token = CancellationToken::new();
    registry
        .register(77, token.clone())
        .expect("register target");
    let cancel = broker.handle(RequestEnvelope::new(
        31,
        RequestCommand::Cancel(kanai_broker::CancelRequest::for_request(7, 77)),
    ));
    assert!(cancel.payload().is_some());
    assert!(token.is_cancelled());
    registry.finish(77);

    let focus = broker.handle(RequestEnvelope::new(
        32,
        RequestCommand::FocusLost(FocusLostRequest {
            session_id: 7,
            generation: 1,
        }),
    ));
    assert!(focus.payload().is_some());
    assert_eq!(broker.session_count(), 0);

    let health = broker.handle(RequestEnvelope::new(
        33,
        RequestCommand::Health(kanai_broker::HealthRequest {}),
    ));
    let payload = health.payload().expect("health succeeds");
    assert!(matches!(
        payload,
        kanai_broker::ResponsePayload::Health(kanai_broker::HealthResponse {
            max_frame_bytes: 1_048_576,
            ..
        })
    ));
}

#[test]
fn cancellation_registry_rejects_duplicate_live_request_ids() {
    let registry = CancellationRegistry::new();
    let token = CancellationToken::new();
    registry
        .register(1, token.clone())
        .expect("first registration");
    assert!(registry.register(1, CancellationToken::new()).is_err());
    assert!(registry.cancel(1));
    assert!(token.is_cancelled());
    registry.finish(1);
    assert!(!registry.cancel(1));
}

#[test]
fn edit_and_convert_round_trip_through_protocol_helpers() {
    let mut broker = Broker::new(DeterministicBackend::new());
    broker.handle(create_request(40));
    let edit = broker.handle(RequestEnvelope::new(
        41,
        RequestCommand::Edit(EditRequest {
            session_id: 7,
            generation: 0,
            action: EditAction::Insert {
                text: "かな".to_owned(),
            },
        }),
    ));
    assert!(edit.payload().is_some());
    let convert = broker.handle(RequestEnvelope::new(
        42,
        RequestCommand::Convert(ConvertRequest {
            session_id: 7,
            generation: 1,
            page: 0,
            page_size: 9,
        }),
    ));
    let payload = convert.payload().expect("convert succeeds");
    let kanai_broker::ResponsePayload::Convert(response) = payload else {
        panic!("expected conversion");
    };
    assert_eq!(response.generation, 1);
    assert_eq!(response.candidates.len(), 1);
    assert_eq!(response.candidates[0].text, "かな");
}
