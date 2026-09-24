//! Transport and authentication contracts for a private local broker pipe.
//!
//! The crate intentionally does not create a Windows named pipe, inspect a
//! Windows token, or claim that a loopback socket is equivalent to a pipe.
//! Those are adapter responsibilities.  This module supplies the platform
//! boundary: bounded frames, an explicit authenticated state, and an opaque
//! peer-authentication hook that a Windows adapter can implement with ACLs and
//! OS credentials.

use std::fmt;
use std::io::{Read, Write};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::frame::{Frame, FrameError, FramedIo, MemoryTransport};
use crate::protocol::{
    PROTOCOL_VERSION, RequestEnvelope, ResponseEnvelope, decode_request, decode_response,
    encode_request, encode_response,
};

/// Maximum size of an authentication proof accepted by the reference
/// authenticator.  Platform authenticators may impose a smaller limit.
pub const MAX_AUTH_PROOF_BYTES: usize = 512;
/// Number of bytes in the replay marker carried by an auth request.
pub const AUTH_NONCE_BYTES: usize = 32;

/// A transport failure.  Implementations should preserve the distinction
/// between a malformed frame, a rejected peer, and ordinary I/O failure.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TransportError {
    #[error("transport I/O failed: {0}")]
    Io(String),
    #[error("transport frame failed: {0}")]
    Frame(#[from] FrameError),
    #[error("transport is closed")]
    Closed,
    #[error("transport authentication is required")]
    Unauthenticated,
    #[error("transport authentication failed: {0}")]
    AuthenticationFailed(String),
    #[error("peer was rejected: {0}")]
    PeerRejected(String),
    #[error("transport protocol failed: {0}")]
    Protocol(String),
}

/// A transport moves already-bounded frames.  Framing, JSON, authentication,
/// and broker dispatch remain separate concerns so a Windows named-pipe
/// implementation can provide only the I/O adapter.
pub trait Transport {
    /// Maximum payload this transport is willing to move.  Adapters should
    /// override this when their pipe/socket has a smaller limit.
    fn max_frame_bytes(&self) -> usize {
        crate::frame::DEFAULT_MAX_FRAME_BYTES
    }

    fn send(&mut self, frame: Frame) -> Result<(), TransportError>;
    fn receive(&mut self) -> Result<Option<Frame>, TransportError>;
}

/// Encode, validate, frame, and send one request without bypassing the
/// transport's configured payload bound.
pub fn send_request<T: Transport>(
    transport: &mut T,
    request: &RequestEnvelope,
) -> Result<(), TransportError> {
    let payload =
        encode_request(request).map_err(|error| TransportError::Protocol(error.to_string()))?;
    let frame = Frame::with_limit(payload, transport.max_frame_bytes())?;
    transport.send(frame)
}

/// Receive and validate one request frame.
pub fn receive_request<T: Transport>(
    transport: &mut T,
) -> Result<Option<RequestEnvelope>, TransportError> {
    let Some(frame) = transport.receive()? else {
        return Ok(None);
    };
    decode_request(frame.payload())
        .map(Some)
        .map_err(|error| TransportError::Protocol(error.to_string()))
}

/// Encode, validate, frame, and send one response.
pub fn send_response<T: Transport>(
    transport: &mut T,
    response: &ResponseEnvelope,
) -> Result<(), TransportError> {
    let payload =
        encode_response(response).map_err(|error| TransportError::Protocol(error.to_string()))?;
    let frame = Frame::with_limit(payload, transport.max_frame_bytes())?;
    transport.send(frame)
}

/// Receive and validate one response frame.
pub fn receive_response<T: Transport>(
    transport: &mut T,
) -> Result<Option<ResponseEnvelope>, TransportError> {
    let Some(frame) = transport.receive()? else {
        return Ok(None);
    };
    decode_response(frame.payload())
        .map(Some)
        .map_err(|error| TransportError::Protocol(error.to_string()))
}

impl<T: Read + Write> Transport for FramedIo<T> {
    fn max_frame_bytes(&self) -> usize {
        FramedIo::max_frame_bytes(self)
    }

    fn send(&mut self, frame: Frame) -> Result<(), TransportError> {
        self.send_payload(frame.payload())
            .map_err(TransportError::Frame)
    }

    fn receive(&mut self) -> Result<Option<Frame>, TransportError> {
        self.receive_payload()
            .map_err(TransportError::Frame)?
            .map(|payload| Frame::with_limit(payload, self.max_frame_bytes()))
            .transpose()
            .map_err(TransportError::Frame)
    }
}

impl Transport for MemoryTransport {
    fn max_frame_bytes(&self) -> usize {
        MemoryTransport::max_frame_bytes(self)
    }

    fn send(&mut self, frame: Frame) -> Result<(), TransportError> {
        if self.is_closed() {
            return Err(TransportError::Closed);
        }
        if frame.len() > self.max_frame_bytes() {
            return Err(TransportError::Frame(FrameError::PayloadTooLarge {
                size: frame.len(),
                max: self.max_frame_bytes(),
            }));
        }
        self.push_frame_out(frame)
    }

    fn receive(&mut self) -> Result<Option<Frame>, TransportError> {
        if self.is_closed() && self.incoming_is_empty() {
            return Ok(None);
        }
        Ok(self.pop_frame_in())
    }
}

/// Authenticated peer identity established before any application frame is
/// accepted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthenticatedPeer {
    pub client_id: String,
}

/// A handshake request.  `proof` is opaque to this crate.  A Windows adapter
/// should bind its proof to the named-pipe client token/ACL; the reference
/// shared-secret authenticator exists only to make the contract executable in
/// Linux tests.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthRequest {
    pub version: u16,
    pub client_id: String,
    #[serde(with = "nonce_serde")]
    pub nonce: [u8; AUTH_NONCE_BYTES],
    pub proof: Vec<u8>,
}

impl fmt::Debug for AuthRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AuthRequest")
            .field("version", &self.version)
            .field("client_id", &self.client_id)
            .field("nonce", &"<redacted>")
            .field("proof", &"<redacted>")
            .finish()
    }
}

impl AuthRequest {
    pub fn validate(&self) -> Result<(), TransportError> {
        if self.version != PROTOCOL_VERSION {
            return Err(TransportError::AuthenticationFailed(format!(
                "unsupported auth version {}",
                self.version
            )));
        }
        validate_client_id(&self.client_id)?;
        if self.nonce.iter().all(|byte| *byte == 0) {
            return Err(TransportError::AuthenticationFailed(
                "auth nonce must not be all zero".to_owned(),
            ));
        }
        if self.proof.is_empty() || self.proof.len() > MAX_AUTH_PROOF_BYTES {
            return Err(TransportError::AuthenticationFailed(
                "auth proof has an invalid length".to_owned(),
            ));
        }
        Ok(())
    }
}

/// A response to an authentication attempt.  It carries no secret and can be
/// sent as the first ordinary frame after the transport has accepted it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthResponse {
    pub version: u16,
    pub accepted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer: Option<AuthenticatedPeer>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl AuthResponse {
    #[must_use]
    pub fn accepted(peer: AuthenticatedPeer) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            accepted: true,
            peer: Some(peer),
            error: None,
        }
    }

    #[must_use]
    pub fn rejected(error: impl Into<String>) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            accepted: false,
            peer: None,
            error: Some(error.into()),
        }
    }

    pub fn validate(&self) -> Result<(), TransportError> {
        if self.version != PROTOCOL_VERSION {
            return Err(TransportError::Protocol(format!(
                "unsupported auth response version {}",
                self.version
            )));
        }
        if self.accepted && self.peer.is_none() {
            return Err(TransportError::Protocol(
                "accepted auth response has no peer".to_owned(),
            ));
        }
        if let Some(peer) = &self.peer {
            validate_client_id(&peer.client_id)?;
        }
        if !self.accepted && self.error.is_none() {
            return Err(TransportError::Protocol(
                "rejected auth response has no reason".to_owned(),
            ));
        }
        if self
            .error
            .as_ref()
            .is_some_and(|error| error.len() > 512 || error.chars().any(char::is_control))
        {
            return Err(TransportError::Protocol(
                "auth response error is not bounded".to_owned(),
            ));
        }
        Ok(())
    }
}

/// Platform adapter hook.  The request contains an opaque proof; a Windows
/// implementation can verify the pipe's client token and per-user ACL here.
pub trait PeerAuthenticator: Send + Sync {
    fn authenticate(&self, request: &AuthRequest) -> Result<AuthenticatedPeer, TransportError>;
}

/// A non-empty local secret used by the deterministic test authenticator.
/// Its `Debug` implementation intentionally does not reveal the bytes.
#[derive(Clone, PartialEq, Eq)]
pub struct SharedSecret {
    bytes: Vec<u8>,
}

impl SharedSecret {
    pub fn new(bytes: impl Into<Vec<u8>>) -> Result<Self, TransportError> {
        let bytes = bytes.into();
        if bytes.is_empty() {
            return Err(TransportError::AuthenticationFailed(
                "shared secret must not be empty".to_owned(),
            ));
        }
        if bytes.len() > MAX_AUTH_PROOF_BYTES {
            return Err(TransportError::AuthenticationFailed(format!(
                "shared secret exceeds {MAX_AUTH_PROOF_BYTES} bytes"
            )));
        }
        Ok(Self { bytes })
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.bytes.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }

    fn matches(&self, proof: &[u8]) -> bool {
        constant_time_eq(self.bytes.as_slice(), proof)
    }
}

impl fmt::Debug for SharedSecret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SharedSecret")
            .field("len", &self.bytes.len())
            .finish()
    }
}

/// Reference authenticator for platform-neutral tests.  It is not a Windows
/// security boundary: production code must also configure a private named
/// pipe ACL and use a platform authenticator that validates the peer token.
pub struct SharedSecretAuthenticator {
    secret: SharedSecret,
    expected_client_id: Option<String>,
}

impl SharedSecretAuthenticator {
    pub fn new(secret: SharedSecret, expected_client_id: Option<String>) -> Self {
        Self {
            secret,
            expected_client_id,
        }
    }

    pub fn make_request(
        &self,
        client_id: impl Into<String>,
    ) -> Result<AuthRequest, TransportError> {
        self.make_request_with_nonce(client_id, [1_u8; AUTH_NONCE_BYTES])
    }

    pub fn make_request_with_nonce(
        &self,
        client_id: impl Into<String>,
        nonce: [u8; AUTH_NONCE_BYTES],
    ) -> Result<AuthRequest, TransportError> {
        let client_id = client_id.into();
        validate_client_id(&client_id)?;
        if nonce.iter().all(|byte| *byte == 0) {
            return Err(TransportError::AuthenticationFailed(
                "auth nonce must not be all zero".to_owned(),
            ));
        }
        Ok(AuthRequest {
            version: PROTOCOL_VERSION,
            client_id,
            nonce,
            proof: self.secret.bytes.clone(),
        })
    }
}

impl PeerAuthenticator for SharedSecretAuthenticator {
    fn authenticate(&self, request: &AuthRequest) -> Result<AuthenticatedPeer, TransportError> {
        request.validate()?;
        if let Some(expected) = &self.expected_client_id
            && request.client_id != *expected
        {
            return Err(TransportError::PeerRejected(
                "client id is not allowed".to_owned(),
            ));
        }
        if !self.secret.matches(&request.proof) {
            return Err(TransportError::AuthenticationFailed(
                "auth proof did not match".to_owned(),
            ));
        }
        Ok(AuthenticatedPeer {
            client_id: request.client_id.clone(),
        })
    }
}

/// A transport wrapper that fails closed until an authenticator accepts one
/// handshake.  It does not provide Windows ACLs itself; those belong in the
/// future named-pipe adapter.
pub struct AuthenticatedTransport<T> {
    inner: T,
    authenticator: Arc<dyn PeerAuthenticator>,
    peer: Option<AuthenticatedPeer>,
}

impl<T> AuthenticatedTransport<T> {
    pub fn new(inner: T, authenticator: Arc<dyn PeerAuthenticator>) -> Self {
        Self {
            inner,
            authenticator,
            peer: None,
        }
    }

    pub fn from_shared_secret(
        inner: T,
        secret: SharedSecret,
        expected_client_id: Option<String>,
    ) -> Self {
        Self::new(
            inner,
            Arc::new(SharedSecretAuthenticator::new(secret, expected_client_id)),
        )
    }

    #[must_use]
    pub fn peer(&self) -> Option<&AuthenticatedPeer> {
        self.peer.as_ref()
    }

    #[must_use]
    pub fn is_authenticated(&self) -> bool {
        self.peer.is_some()
    }

    /// Accept exactly one handshake.  Re-authentication requires a fresh
    /// transport instance, which avoids accidentally changing the peer on an
    /// established connection.
    pub fn accept(&mut self, request: &AuthRequest) -> Result<AuthenticatedPeer, TransportError> {
        if self.peer.is_some() {
            return Err(TransportError::AuthenticationFailed(
                "transport is already authenticated".to_owned(),
            ));
        }
        request.validate()?;
        let peer = self.authenticator.authenticate(request)?;
        self.peer = Some(peer.clone());
        Ok(peer)
    }

    pub fn accept_json(&mut self, payload: &[u8]) -> Result<AuthResponse, TransportError> {
        let request: AuthRequest = serde_json::from_slice(payload)
            .map_err(|error| TransportError::Protocol(error.to_string()))?;
        match self.accept(&request) {
            Ok(peer) => {
                let response = AuthResponse::accepted(peer);
                response.validate()?;
                Ok(response)
            }
            Err(error) => Ok(AuthResponse::rejected(error.to_string())),
        }
    }

    pub fn get_ref(&self) -> &T {
        &self.inner
    }

    pub fn get_mut(&mut self) -> &mut T {
        &mut self.inner
    }

    pub fn into_inner(self) -> T {
        self.inner
    }

    fn require_authenticated(&self) -> Result<(), TransportError> {
        if self.peer.is_some() {
            Ok(())
        } else {
            Err(TransportError::Unauthenticated)
        }
    }
}

impl<T: Transport> Transport for AuthenticatedTransport<T> {
    fn max_frame_bytes(&self) -> usize {
        self.inner.max_frame_bytes()
    }

    fn send(&mut self, frame: Frame) -> Result<(), TransportError> {
        self.require_authenticated()?;
        if frame.len() > self.inner.max_frame_bytes() {
            return Err(TransportError::Frame(FrameError::PayloadTooLarge {
                size: frame.len(),
                max: self.inner.max_frame_bytes(),
            }));
        }
        self.inner.send(frame)
    }

    fn receive(&mut self) -> Result<Option<Frame>, TransportError> {
        self.require_authenticated()?;
        let frame = self.inner.receive()?;
        if let Some(frame) = &frame
            && frame.len() > self.inner.max_frame_bytes()
        {
            return Err(TransportError::Frame(FrameError::PayloadTooLarge {
                size: frame.len(),
                max: self.inner.max_frame_bytes(),
            }));
        }
        Ok(frame)
    }
}

fn validate_client_id(client_id: &str) -> Result<(), TransportError> {
    if client_id.is_empty() {
        return Err(TransportError::AuthenticationFailed(
            "client id must not be empty".to_owned(),
        ));
    }
    if client_id.len() > crate::protocol::MAX_CLIENT_ID_BYTES {
        return Err(TransportError::AuthenticationFailed(
            "client id is too long".to_owned(),
        ));
    }
    if client_id.chars().any(char::is_control) {
        return Err(TransportError::AuthenticationFailed(
            "client id contains a control character".to_owned(),
        ));
    }
    Ok(())
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    let common_len = left.len().max(right.len());
    for index in 0..common_len {
        let left_byte = left.get(index).copied().unwrap_or_default();
        let right_byte = right.get(index).copied().unwrap_or_default();
        difference |= usize::from(left_byte ^ right_byte);
    }
    difference == 0
}

mod nonce_serde {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S>(value: &[u8; 32], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        value.serialize(serializer)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<[u8; 32], D::Error>
    where
        D: Deserializer<'de>,
    {
        let bytes = Vec::<u8>::deserialize(deserializer)?;
        bytes
            .try_into()
            .map_err(|_| serde::de::Error::custom("auth nonce must contain 32 bytes"))
    }
}

impl MemoryTransport {
    fn is_closed(&self) -> bool {
        self.closed
    }

    fn incoming_is_empty(&self) -> bool {
        self.incoming.is_empty()
    }

    fn max_frame_bytes(&self) -> usize {
        self.max_frame_bytes
    }

    fn push_frame_out(&mut self, frame: Frame) -> Result<(), TransportError> {
        self.enqueue_out(frame).map_err(TransportError::Frame)
    }

    fn pop_frame_in(&mut self) -> Option<Frame> {
        self.pop_incoming()
    }

    fn enqueue_out(&mut self, frame: Frame) -> Result<(), FrameError> {
        if self.closed {
            return Err(FrameError::Io("transport is closed".to_owned()));
        }
        let next_len = self
            .queued_bytes
            .checked_add(frame.len())
            .ok_or(FrameError::BufferOverflow)?;
        if next_len > self.max_queued_bytes {
            return Err(FrameError::BufferOverflow);
        }
        self.queued_bytes = next_len;
        self.outgoing.push(frame);
        Ok(())
    }

    fn pop_incoming(&mut self) -> Option<Frame> {
        let frame = self.incoming.pop_front()?;
        self.queued_bytes = self.queued_bytes.saturating_sub(frame.len());
        Some(frame)
    }
}
