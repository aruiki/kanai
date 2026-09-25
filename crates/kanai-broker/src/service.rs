//! Authenticated, bounded broker connection adapter.
//!
//! The adapter is transport-neutral: a Windows named-pipe handle, a local
//! Unix socket, or an in-memory test transport can provide `Read + Write` via
//! `FramedIo<T>`. The function handles one request after one canonical auth
//! handshake, matching the current native TSF client. A persistent listener
//! should accept a fresh connection (or a separately framed dispatcher) for
//! each optional exchange so a slow model cannot block a key connection.

use std::sync::Arc;

use serde_json::Error as JsonError;

use crate::{
    AuthRequest, AuthResponse, EnhancementBackend, EnhancementQueue, Frame, PeerAuthenticator,
    RequestCommand, ResponseEnvelope, SessionBackend, SessionBroker, Transport, TransportError,
    decode_request, encode_response,
};

/// Serve one authenticated request on a bounded framed transport.
///
/// Authentication is completed before an application frame is interpreted. The
/// verified client ID is bound to a newly created broker session; subsequent
/// commands and optional work from a different authenticated peer are rejected
/// as an unknown session. A `Cancel` command is forwarded to the optional queue
/// only after that ownership check, so a native shell can cancel a request that
/// is still waiting behind a provider without allowing cross-peer cancellation.
/// The function returns the response after it has been encoded and sent;
/// callers can use that value for receipt/telemetry.
pub async fn serve_authenticated_request<T, B, E>(
    mut transport: T,
    broker: Arc<SessionBroker<B>>,
    queue: Arc<EnhancementQueue<E>>,
    authenticator: Arc<dyn PeerAuthenticator>,
) -> Result<ResponseEnvelope, TransportError>
where
    T: Transport,
    B: SessionBackend,
    E: EnhancementBackend + Send + Sync + 'static,
{
    let auth_frame = transport.receive()?.ok_or(TransportError::Closed)?;
    let auth_request: AuthRequest = serde_json::from_slice(auth_frame.payload())
        .map_err(|error| TransportError::Protocol(error.to_string()))?;
    let auth_result = authenticator.authenticate(&auth_request);
    let (auth_response, peer) = match auth_result {
        Ok(peer) => (AuthResponse::accepted(peer.clone()), Some(peer)),
        Err(_) => (AuthResponse::rejected("peer authentication failed"), None),
    };
    let max_frame_bytes = transport.max_frame_bytes();
    send_json(&mut transport, &auth_response, max_frame_bytes)?;
    let Some(peer) = peer else {
        return Err(TransportError::AuthenticationFailed(
            "peer authentication failed".to_owned(),
        ));
    };

    let frame = transport.receive()?.ok_or(TransportError::Closed)?;
    let request = decode_request(frame.payload())
        .map_err(|error| TransportError::Protocol(error.to_string()))?;
    if let RequestCommand::Cancel(command) = &request.command
        && let Some(target) = command.target_request_id
        && broker
            .session_owned_by(command.session_id, &peer.client_id)
            .await
    {
        queue.cancel_request(target);
    }
    let response = if matches!(
        &request.command,
        RequestCommand::RerankCandidates(_) | RequestCommand::SemanticAssist(_)
    ) {
        broker
            .submit_enhancement_for_peer(
                request.clone(),
                queue.as_ref(),
                crate::CancellationToken::new(),
                &peer.client_id,
            )
            .await
    } else {
        broker
            .handle_for_peer(request.clone(), &peer.client_id)
            .await
    };
    send_response(&mut transport, &response)?;
    Ok(response)
}

fn send_json<T: Transport>(
    transport: &mut T,
    value: &impl serde::Serialize,
    max_frame_bytes: usize,
) -> Result<(), TransportError> {
    let payload = serde_json::to_vec(value).map_err(|error: JsonError| {
        TransportError::Protocol(format!("failed to encode response JSON: {error}"))
    })?;
    let frame = Frame::with_limit(payload, max_frame_bytes)?;
    transport.send(frame)
}

fn send_response<T: Transport>(
    transport: &mut T,
    response: &ResponseEnvelope,
) -> Result<(), TransportError> {
    let payload =
        encode_response(response).map_err(|error| TransportError::Protocol(error.to_string()))?;
    let frame = Frame::with_limit(payload, transport.max_frame_bytes())?;
    transport.send(frame)
}
