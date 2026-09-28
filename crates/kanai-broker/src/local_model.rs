//! Optional loopback OpenAI-compatible local model adapter.
//!
//! This adapter is deliberately separate from the synchronous Mozc path. The
//! broker schedules it through `EnhancementQueue`; a missing model, timeout,
//! malformed response, or cancelled request returns an error and the queue
//! preserves the Mozc baseline.
//!
//! The pinned runtime is launched with `--api-key-file`, so `/health` answers
//! without a token but `/v1/models` and `/v1/chat/completions` answer `401`
//! unless the request carries `Authorization: Bearer <key>`.  A key is
//! therefore optional here only so a caller that has no key at all (an
//! unauthenticated runtime) still constructs; when a key is supplied it is
//! validated here and sent only as a bearer token on the request.

use std::fmt;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use reqwest::{Client, Url};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::{
    CancellationToken, CandidateRerankRequest, EnhancementBackend, EnhancementError,
    EnhancementMetrics, ProviderLocality, RerankOutput, SemanticAssistOutput,
    SemanticAssistRequest,
};

const MAX_RESPONSE_BYTES: usize = 64 * 1024;
/// Bound on the response head. A server that sends an unbounded head would
/// otherwise be able to make this adapter allocate without limit.
const MAX_RESPONSE_HEAD_BYTES: usize = 16 * 1024;
/// Bound on the single write of a request. A request is one header block plus a
/// bounded JSON body, so this only catches a transport that has gone wrong.
const MAX_REQUEST_BYTES: usize = 256 * 1024;
const MAX_CONTEXT_CHARS: usize = 512;
const MAX_CANDIDATES: usize = 9;
const MAX_DEADLINE: Duration = Duration::from_secs(2);
const MAX_API_KEY_BYTES: usize = 512;
/// Longest the connect itself may take, inside [`MAX_DEADLINE`].
const CONNECT_DEADLINE: Duration = Duration::from_millis(500);

/// The prompt a warm-up sends: a fixed ASCII word, not user text and not a real
/// reading. The goal is to make the runtime execute one inference, and that is the
/// least it takes.
pub(crate) const WARM_UP_PROMPT: &str = "warm";

/// Proof that a particular connection is answered by the child this broker
/// started.
///
/// # Why this is a trait and not a callback
///
/// The production proof is a lookup in the operating system's TCP connection
/// table, which lives in `ai_runtime`. Expressing it as a trait keeps this
/// module free of that dependency and lets a test stand in a peer that is
/// *not* the child, which is the only way to show the guard actually refuses.
#[async_trait]
pub trait EndpointOwnership: Send + Sync + fmt::Debug {
    /// Prove the server end of the `local` to `peer` connection belongs to the
    /// child this broker started. `false` means refuse; it never means retry.
    async fn verify_connection(&self, local: SocketAddr, peer: SocketAddr) -> bool;
}

#[derive(Clone)]
pub struct LocalOpenAiBackend {
    client: Client,
    endpoint: Url,
    model: String,
    provider_id: String,
    /// Never printed, never logged, never placed in the URL or the payload.
    api_key: Option<String>,
    /// When present, every request is sent over a connection whose server end
    /// this proof has already accepted. When absent the backend is a plain
    /// loopback client, which is what a caller with no child of its own wants.
    ownership: Option<Arc<dyn EndpointOwnership>>,
}

/// Diagnostics expose that a key exists, never its material.
impl fmt::Debug for LocalOpenAiBackend {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LocalOpenAiBackend")
            .field("endpoint", &self.endpoint.as_str())
            .field("model", &self.model)
            .field("provider_id", &self.provider_id)
            .field(
                "api_key",
                &if self.api_key.is_some() {
                    "<redacted>"
                } else {
                    "none"
                },
            )
            .finish()
    }
}

fn is_loopback_host(host: Option<&str>) -> bool {
    let Some(host) = host else {
        return false;
    };
    if host.eq_ignore_ascii_case("localhost") {
        return true;
    }
    host.trim_start_matches('[')
        .trim_end_matches(']')
        .parse::<IpAddr>()
        .is_ok_and(|address| address.is_loopback())
}

/// A bearer token must be a bounded, single-line, control-free value.  Anything
/// else cannot be transported as a header without ambiguity, and a control
/// character or whitespace would allow header injection into the request.
fn validate_api_key(key: &str) -> Result<(), String> {
    if key.is_empty()
        || key.len() > MAX_API_KEY_BYTES
        || key
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(
            "KANAI_AI_API_KEY must be non-empty, at most 512 bytes, and free of control characters and whitespace"
                .to_owned(),
        );
    }
    Ok(())
}

impl LocalOpenAiBackend {
    /// Construct a local backend only when an explicit loopback HTTP endpoint
    /// and model are configured. Remote endpoints and TLS endpoints are
    /// rejected by design so the broker cannot accidentally depend on a
    /// network-facing or platform TLS runtime.
    ///
    /// No API key is configured here; see [`Self::new_with_api_key`] for a
    /// runtime that was started with `--api-key-file`.
    pub fn from_environment() -> Option<Self> {
        let base = std::env::var("KANAI_AI_BASE_URL").ok()?;
        let model = std::env::var("KANAI_AI_MODEL").ok()?;
        Self::new(base, model).ok()
    }

    /// Construct a local backend that sends no `Authorization` header.
    pub fn new(base_url: impl AsRef<str>, model: impl Into<String>) -> Result<Self, String> {
        Self::build(base_url.as_ref(), model.into(), None, None)
    }

    /// Construct a local backend that authenticates with `api_key`.
    ///
    /// The key is required to be a bounded, single-line, control-free token:
    /// an empty key, a key longer than 512 bytes, or a key containing
    /// whitespace or a control character is a construction error rather than
    /// a request-time failure, because such a value cannot be transported as a
    /// header without ambiguity or injection.
    pub fn new_with_api_key(
        base_url: impl AsRef<str>,
        model: impl Into<String>,
        api_key: impl Into<String>,
    ) -> Result<Self, String> {
        Self::build(base_url.as_ref(), model.into(), Some(api_key.into()), None)
    }

    /// Construct a backend that sends every request over a connection whose
    /// server end `ownership` has already proved belongs to this broker's own
    /// child.
    ///
    /// This is the installed broker's constructor. The difference from
    /// [`Self::new_with_api_key`] is not a faster path or a nicer error: it is
    /// that the bearer token, the user's preedit, and the candidate text can only
    /// be written to a socket the operating system has already attributed to the
    /// child this process started. Verifying a *different* connection first and
    /// then letting a client open its own leaves a window in which another
    /// process can take the port and receive all of that instead.
    pub fn new_with_api_key_and_ownership(
        base_url: impl AsRef<str>,
        model: impl Into<String>,
        api_key: impl Into<String>,
        ownership: Arc<dyn EndpointOwnership>,
    ) -> Result<Self, String> {
        Self::build(
            base_url.as_ref(),
            model.into(),
            Some(api_key.into()),
            Some(ownership),
        )
    }

    fn build(
        base_url: &str,
        model: String,
        api_key: Option<String>,
        ownership: Option<Arc<dyn EndpointOwnership>>,
    ) -> Result<Self, String> {
        let base = Url::parse(base_url).map_err(|error| error.to_string())?;
        if !base.username().is_empty() || base.password().is_some() {
            return Err("KANAI_AI_BASE_URL must not contain credentials".to_owned());
        }
        if base.scheme() != "http" || !is_loopback_host(base.host_str()) {
            return Err("KANAI_AI_BASE_URL must be an HTTP loopback endpoint".to_owned());
        }
        if model.is_empty() || model.len() > 128 || model.chars().any(char::is_control) {
            return Err("KANAI_AI_MODEL must be non-empty, bounded, and control-free".to_owned());
        }
        if let Some(key) = api_key.as_deref() {
            validate_api_key(key)?;
        }
        let mut endpoint = base;
        endpoint.set_path("/v1/chat/completions");
        endpoint.set_query(None);
        endpoint.set_fragment(None);
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(MAX_DEADLINE)
            // The product promises a fully local runtime.  A machine-wide proxy
            // must never be allowed to intercept loopback model traffic, or the
            // request could leave the machine and the model could be reached
            // through a non-loopback hop.
            .no_proxy()
            .build()
            .map_err(|error| error.to_string())?;
        let provider_id = format!("openai-compatible:{}", model);
        Ok(Self {
            client,
            endpoint,
            model,
            provider_id,
            api_key,
            ownership,
        })
    }

    /// The loopback socket address this backend sends to.
    ///
    /// The constructor has already rejected any non-loopback host, and the
    /// pinned runtime binds `127.0.0.1` specifically - the port it was given is
    /// the only variable part. Resolving `localhost` through the resolver would
    /// reintroduce a name lookup this transport exists to avoid.
    fn loopback_address(&self) -> Option<SocketAddr> {
        let host = self.endpoint.host_str()?;
        if !is_loopback_host(Some(host)) {
            return None;
        }
        Some(SocketAddr::from((
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            self.endpoint.port()?,
        )))
    }

    /// Run one minimal authenticated completion, for warming the runtime.
    ///
    /// This is deliberately the same transport a real request uses - the same
    /// ownership-checked socket, the same bearer header, the same decoder - and
    /// not a lighter probe, for two reasons that are the same reason:
    ///
    /// * a warm-up on a different path would not pay the cost the first real
    ///   request pays, so it would warm nothing; and
    /// * it is the only thing that proves the key generated during startup is the
    ///   key this runtime accepts.
    ///
    /// `max_tokens` is 1 and the prompt is a fixed ASCII word. The generated text
    /// is discarded: this is a capacity probe, and nothing here is a quality
    /// observation, so returning it to a caller would invite reading one into it.
    ///
    /// A JSON response format is requested, matching the rerank path, because a
    /// runtime configured for the reranker should be warmed the way it will be
    /// used. A response that fails to decode is a failure here: a warm-up that
    /// tolerated malformed output would report success for a runtime that cannot
    /// serve.
    pub async fn warm_up(&self, cancellation: &CancellationToken) -> Result<(), EnhancementError> {
        let payload = json!({
            "model": self.model,
            "temperature": 0,
            "max_tokens": 1,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": "Return JSON only."},
                {"role": "user", "content": WARM_UP_PROMPT},
            ]
        });
        self.call_model(payload, cancellation).await.map(|_| ())
    }

    async fn call_model(
        &self,
        payload: Value,
        cancellation: &CancellationToken,
    ) -> Result<String, EnhancementError> {
        if cancellation.is_cancelled() {
            return Err(EnhancementError::Cancelled);
        }
        // With an ownership proof, the request goes out over a connection this
        // call opened and this call had proved. There is no second connection and
        // therefore no window between the proof and the bytes.
        if let Some(ownership) = &self.ownership {
            let bytes = self
                .send_over_verified_connection(ownership.as_ref(), &payload, cancellation)
                .await?;
            return decode_completion(&bytes);
        }
        let mut builder = self.client.post(self.endpoint.clone()).json(&payload);
        if let Some(api_key) = self.api_key.as_deref() {
            // The key travels only as a bearer token header.  It is never part
            // of the URL, never part of the JSON payload, and never logged.
            builder = builder.bearer_auth(api_key);
        }
        let mut response = builder.send().await.map_err(|error| {
            if error.is_timeout() {
                EnhancementError::ProviderTimeout
            } else {
                EnhancementError::ProviderUnavailable(error.to_string())
            }
        })?;
        if !response.status().is_success() {
            return Err(EnhancementError::ProviderUnavailable(format!(
                "local model returned HTTP {}",
                response.status().as_u16()
            )));
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
        {
            return Err(EnhancementError::InvalidOutput(
                "local model response is too large".to_owned(),
            ));
        }
        let mut bytes = Vec::new();
        loop {
            if cancellation.is_cancelled() {
                return Err(EnhancementError::Cancelled);
            }
            let Some(chunk) = response
                .chunk()
                .await
                .map_err(|error| EnhancementError::ProviderUnavailable(error.to_string()))?
            else {
                break;
            };
            if bytes.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
                return Err(EnhancementError::InvalidOutput(
                    "local model response is too large".to_owned(),
                ));
            }
            bytes.extend_from_slice(&chunk);
        }
        if cancellation.is_cancelled() {
            return Err(EnhancementError::Cancelled);
        }
        decode_completion(&bytes)
    }

    /// Send one request over a connection this call opened and this call proved.
    ///
    /// The order is the whole point, and it is not negotiable:
    ///
    /// 1. connect to the loopback endpoint;
    /// 2. read this socket's own `(local, peer)` pair;
    /// 3. ask `ownership` whether the server end of *that* socket is this
    ///    broker's child;
    /// 4. only then write the request, which is the first moment the bearer
    ///    token, the preedit, and the candidate text leave the process.
    ///
    /// A refusal at step 3 writes nothing at all, so a port that changed hands
    /// receives no secret and no user text - which is the property a separate
    /// verification connection could not provide.
    async fn send_over_verified_connection(
        &self,
        ownership: &dyn EndpointOwnership,
        payload: &Value,
        cancellation: &CancellationToken,
    ) -> Result<Vec<u8>, EnhancementError> {
        let address = self.loopback_address().ok_or_else(|| {
            EnhancementError::ProviderUnavailable("local AI endpoint is not loopback".to_owned())
        })?;
        let stream = tokio::time::timeout(CONNECT_DEADLINE, TcpStream::connect(address))
            .await
            .map_err(|_| EnhancementError::ProviderTimeout)?
            .map_err(|error| EnhancementError::ProviderUnavailable(error.to_string()))?;
        // Nagle would add a delayed-ACK stall to a request this small.
        let _ = stream.set_nodelay(true);
        let (Ok(local), Ok(peer)) = (stream.local_addr(), stream.peer_addr()) else {
            return Err(EnhancementError::ProviderUnavailable(
                "local AI socket has no address pair".to_owned(),
            ));
        };
        if !ownership.verify_connection(local, peer).await {
            return Err(EnhancementError::ProviderUnavailable(
                "local AI runtime is unavailable".to_owned(),
            ));
        }
        if cancellation.is_cancelled() {
            return Err(EnhancementError::Cancelled);
        }

        let body = serde_json::to_vec(payload)
            .map_err(|error| EnhancementError::InvalidOutput(error.to_string()))?;
        let request = encode_request(&self.endpoint, self.api_key.as_deref(), &body);
        if request.len() > MAX_REQUEST_BYTES {
            return Err(EnhancementError::InvalidOutput(
                "local model request is too large".to_owned(),
            ));
        }

        let exchange = async {
            let mut stream = stream;
            stream
                .write_all(&request)
                .await
                .map_err(|error| EnhancementError::ProviderUnavailable(error.to_string()))?;
            stream
                .flush()
                .await
                .map_err(|error| EnhancementError::ProviderUnavailable(error.to_string()))?;
            read_response(&mut stream, cancellation).await
        };
        tokio::time::timeout(MAX_DEADLINE, exchange)
            .await
            .map_err(|_| EnhancementError::ProviderTimeout)?
    }
}

/// The message content out of a completion response body.
fn decode_completion(bytes: &[u8]) -> Result<String, EnhancementError> {
    let envelope: Value = serde_json::from_slice(bytes)
        .map_err(|error| EnhancementError::InvalidOutput(error.to_string()))?;
    envelope
        .pointer("/choices/0/message/content")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            EnhancementError::InvalidOutput("model response has no message content".to_owned())
        })
}

/// The exact bytes of one HTTP/1.1 request.
///
/// Written by hand rather than delegated, because the property that matters here
/// is that nothing is written before the ownership proof, and a helper that
/// "might" add a cookie jar, a redirect, or a proxy hop is not something this
/// path can reason about. `Connection: close` is deliberate: the proof is per
/// connection, so the socket is not reused for a request that was not proved.
fn encode_request(endpoint: &Url, api_key: Option<&str>, body: &[u8]) -> Vec<u8> {
    let authority = format!(
        "{}:{}",
        endpoint.host_str().unwrap_or("127.0.0.1"),
        endpoint.port().unwrap_or(80)
    );
    let path = endpoint.path();
    let mut head = String::with_capacity(256);
    head.push_str(&format!("POST {path} HTTP/1.1\r\n"));
    head.push_str(&format!("Host: {authority}\r\n"));
    head.push_str("Content-Type: application/json\r\n");
    head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    head.push_str("Connection: close\r\n");
    if let Some(key) = api_key {
        // The key appears in exactly one place, as a bearer token header. It is
        // not in the URL, not in the body, and never logged.
        head.push_str(&format!("Authorization: Bearer {key}\r\n"));
    }
    head.push_str("\r\n");
    let mut request = Vec::with_capacity(head.len() + body.len());
    request.extend_from_slice(head.as_bytes());
    request.extend_from_slice(body);
    request
}

/// Read one HTTP/1.1 response, bounded in head, body, and time.
///
/// Three framings are accepted, because a loopback server may use any of them
/// and refusing two of them would be a transport bug rather than a safety
/// property: `Transfer-Encoding: chunked`, an explicit `Content-Length`, and end
/// of stream.
async fn read_response(
    stream: &mut TcpStream,
    cancellation: &CancellationToken,
) -> Result<Vec<u8>, EnhancementError> {
    let mut raw: Vec<u8> = Vec::with_capacity(4096);
    let mut chunk = [0_u8; 8192];
    let separator = loop {
        if let Some(index) = find_head_end(&raw) {
            break index;
        }
        if raw.len() > MAX_RESPONSE_HEAD_BYTES {
            return Err(EnhancementError::InvalidOutput(
                "local model response head is too large".to_owned(),
            ));
        }
        if cancellation.is_cancelled() {
            return Err(EnhancementError::Cancelled);
        }
        let read = stream
            .read(&mut chunk)
            .await
            .map_err(|error| EnhancementError::ProviderUnavailable(error.to_string()))?;
        if read == 0 {
            return Err(EnhancementError::ProviderUnavailable(
                "local model closed the connection before responding".to_owned(),
            ));
        }
        raw.extend_from_slice(&chunk[..read]);
    };

    let head = String::from_utf8_lossy(&raw[..separator]).into_owned();
    let mut lines = head.split("\r\n");
    let status_line = lines.next().unwrap_or_default();
    let Some(code) = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|value| value.parse::<u16>().ok())
    else {
        return Err(EnhancementError::InvalidOutput(
            "local model sent no HTTP status".to_owned(),
        ));
    };
    if !(200..300).contains(&code) {
        return Err(EnhancementError::ProviderUnavailable(format!(
            "local model returned HTTP {code}"
        )));
    }

    let mut content_length: Option<usize> = None;
    let mut chunked = false;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        match name.as_str() {
            "content-length" => {
                content_length = value.parse::<usize>().ok();
            }
            "transfer-encoding" => {
                chunked = value.to_ascii_lowercase().contains("chunked");
            }
            _ => {}
        }
    }

    let mut body = raw[separator + 4..].to_vec();
    if chunked {
        decode_chunked(&mut body, stream, cancellation).await?;
    } else if let Some(expected) = content_length {
        while body.len() < expected {
            if cancellation.is_cancelled() {
                return Err(EnhancementError::Cancelled);
            }
            let read = stream
                .read(&mut chunk)
                .await
                .map_err(|error| EnhancementError::ProviderUnavailable(error.to_string()))?;
            if read == 0 {
                break;
            }
            body.extend_from_slice(&chunk[..read]);
        }
        body.truncate(expected);
    } else {
        // No framing header: the body ends when the peer closes.
        loop {
            if cancellation.is_cancelled() {
                return Err(EnhancementError::Cancelled);
            }
            let read = stream
                .read(&mut chunk)
                .await
                .map_err(|error| EnhancementError::ProviderUnavailable(error.to_string()))?;
            if read == 0 {
                break;
            }
            body.extend_from_slice(&chunk[..read]);
            if body.len() > MAX_RESPONSE_BYTES {
                return Err(EnhancementError::InvalidOutput(
                    "local model response is too large".to_owned(),
                ));
            }
        }
    }
    if body.len() > MAX_RESPONSE_BYTES {
        return Err(EnhancementError::InvalidOutput(
            "local model response is too large".to_owned(),
        ));
    }
    Ok(body)
}

/// The index of the `\r\n\r\n` that ends the response head, if it has arrived.
fn find_head_end(raw: &[u8]) -> Option<usize> {
    raw.windows(4).position(|window| window == b"\r\n\r\n")
}

/// Decode `Transfer-Encoding: chunked` in place, appending whatever the peer
/// sends after the last chunk.
///
/// A malformed chunk is an `InvalidOutput` rather than a best-effort guess: a
/// body this adapter cannot frame exactly is a body it must not hand to a JSON
/// parser as if it were complete.
async fn decode_chunked(
    body: &mut Vec<u8>,
    stream: &mut TcpStream,
    cancellation: &CancellationToken,
) -> Result<(), EnhancementError> {
    let mut decoded: Vec<u8> = Vec::with_capacity(body.len());
    let mut buffer = std::mem::take(body);
    let mut chunk = [0_u8; 8192];
    let mut cursor = 0_usize;
    loop {
        let Some(line_end) = find_crlf(&buffer, cursor) else {
            if !fill(stream, &mut buffer, &mut chunk, cancellation).await? {
                return Err(EnhancementError::InvalidOutput(
                    "local model chunked body ended mid-header".to_owned(),
                ));
            }
            continue;
        };
        let size_text = String::from_utf8_lossy(&buffer[cursor..line_end]).into_owned();
        let size_text = size_text.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_text, 16).map_err(|_| {
            EnhancementError::InvalidOutput("local model chunk size is not hexadecimal".to_owned())
        })?;
        cursor = line_end + 2;
        if size == 0 {
            decoded.shrink_to_fit();
            *body = decoded;
            return Ok(());
        }
        if decoded.len().saturating_add(size) > MAX_RESPONSE_BYTES {
            return Err(EnhancementError::InvalidOutput(
                "local model response is too large".to_owned(),
            ));
        }
        while buffer.len() < cursor + size + 2 {
            if !fill(stream, &mut buffer, &mut chunk, cancellation).await? {
                return Err(EnhancementError::InvalidOutput(
                    "local model chunked body ended mid-chunk".to_owned(),
                ));
            }
        }
        decoded.extend_from_slice(&buffer[cursor..cursor + size]);
        cursor += size + 2;
    }
}

/// Read more into `buffer`. `false` means the peer closed.
async fn fill(
    stream: &mut TcpStream,
    buffer: &mut Vec<u8>,
    chunk: &mut [u8],
    cancellation: &CancellationToken,
) -> Result<bool, EnhancementError> {
    if cancellation.is_cancelled() {
        return Err(EnhancementError::Cancelled);
    }
    let read = stream
        .read(chunk)
        .await
        .map_err(|error| EnhancementError::ProviderUnavailable(error.to_string()))?;
    if read == 0 {
        return Ok(false);
    }
    buffer.extend_from_slice(&chunk[..read]);
    Ok(true)
}

fn find_crlf(buffer: &[u8], from: usize) -> Option<usize> {
    buffer
        .get(from..)
        .and_then(|tail| tail.windows(2).position(|window| window == b"\r\n"))
        .map(|offset| from + offset)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Decision {
    action: String,
    candidate_ids: Vec<u64>,
    confidence: f64,
    reason_code: String,
}

fn bounded_text(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn prompt_payload(request: &CandidateRerankRequest, model: &str) -> Value {
    let candidates: Vec<Value> = request
        .candidates
        .iter()
        .take(MAX_CANDIDATES)
        .map(|candidate| {
            json!({
                "id": candidate.id,
                "text": bounded_text(&candidate.text, 96),
                "reading": candidate.reading.as_deref().map(|value| bounded_text(value, 64)),
            })
        })
        .collect();
    json!({
        "model": model,
        "temperature": 0,
        "response_format": {"type": "json_object"},
        "messages": [
            {
                "role": "system",
                "content": "You are a local Japanese IME reranker. Return JSON only with action (rerank or abstain), candidateIds as a permutation of the supplied IDs, confidence from 0 to 1, and reasonCode. Never invent candidate IDs or text."
            },
            {
                "role": "user",
                "content": serde_json::to_string(&json!({
                    "contextBefore": bounded_text(&request.context_before, MAX_CONTEXT_CHARS),
                    "contextAfter": bounded_text(&request.context_after, MAX_CONTEXT_CHARS),
                    "candidates": candidates,
                })).unwrap_or_else(|_| "{}".to_owned())
            }
        ]
    })
}

fn map_decision(
    request: &CandidateRerankRequest,
    content: &str,
    elapsed: Duration,
) -> Result<RerankOutput, EnhancementError> {
    let decision: Decision = serde_json::from_str(content)
        .map_err(|error| EnhancementError::InvalidOutput(error.to_string()))?;
    if !matches!(decision.action.as_str(), "rerank" | "abstain") {
        return Err(EnhancementError::InvalidOutput("unknown action".to_owned()));
    }
    if !decision.confidence.is_finite() || !(0.0..=1.0).contains(&decision.confidence) {
        return Err(EnhancementError::InvalidOutput(
            "confidence is out of range".to_owned(),
        ));
    }
    if decision.reason_code.is_empty() || decision.reason_code.len() > 64 {
        return Err(EnhancementError::InvalidOutput(
            "reasonCode is out of range".to_owned(),
        ));
    }
    if decision.candidate_ids.len() != request.candidates.len()
        || decision.candidate_ids.len() > MAX_CANDIDATES
    {
        return Err(EnhancementError::InvalidOutput(
            "candidateIds is not a bounded permutation".to_owned(),
        ));
    }
    let mut seen = vec![false; request.candidates.len()];
    let mut ordered = Vec::with_capacity(request.candidates.len());
    for id in decision.candidate_ids {
        let Some(index) = request
            .candidates
            .iter()
            .position(|candidate| candidate.id == id)
        else {
            return Err(EnhancementError::InvalidOutput(
                "candidateIds contains an unknown ID".to_owned(),
            ));
        };
        if std::mem::replace(&mut seen[index], true) {
            return Err(EnhancementError::InvalidOutput(
                "candidateIds contains duplicates".to_owned(),
            ));
        }
        ordered.push(request.candidates[index].clone());
    }
    if seen.iter().any(|value| !*value) {
        return Err(EnhancementError::InvalidOutput(
            "candidateIds omits a baseline candidate".to_owned(),
        ));
    }
    let adopted = decision.action == "rerank"
        && decision.confidence >= 0.75
        && ordered
            .iter()
            .zip(&request.candidates)
            .any(|(left, right)| left.id != right.id);
    let mut metrics = EnhancementMetrics::baseline(
        crate::EnhancementFeature::CandidateRerank,
        "openai-compatible",
        ProviderLocality::Local,
        request.candidates.len() as u16,
        request.deadline_ms,
    );
    metrics.ai_latency_micros = elapsed.as_micros().min(u128::from(u64::MAX)) as u64;
    if decision.action == "abstain" || decision.confidence < 0.75 {
        return Ok(RerankOutput {
            candidates: request.candidates.clone(),
            adopted: false,
            metrics,
        });
    }
    Ok(RerankOutput {
        candidates: ordered,
        adopted,
        metrics,
    })
}

#[async_trait]
impl EnhancementBackend for LocalOpenAiBackend {
    fn provider_id(&self) -> &str {
        &self.provider_id
    }

    fn locality(&self) -> ProviderLocality {
        ProviderLocality::Local
    }

    async fn rerank(
        &self,
        request: CandidateRerankRequest,
        cancellation: CancellationToken,
    ) -> Result<RerankOutput, EnhancementError> {
        request
            .validate()
            .map_err(EnhancementError::InvalidRequest)?;
        if request.candidates.len() > MAX_CANDIDATES {
            return Err(EnhancementError::InvalidRequest(
                crate::ValidationError::TooManyCandidates {
                    count: request.candidates.len(),
                    max: MAX_CANDIDATES,
                },
            ));
        }
        let started = Instant::now();
        let content = self
            .call_model(prompt_payload(&request, &self.model), &cancellation)
            .await?;
        map_decision(&request, &content, started.elapsed())
    }

    async fn semantic_assist(
        &self,
        _request: SemanticAssistRequest,
        _cancellation: CancellationToken,
    ) -> Result<SemanticAssistOutput, EnhancementError> {
        Err(EnhancementError::ProviderUnavailable(
            "semantic assist is not enabled for the local reranker".to_owned(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Candidate, CandidateRerankRequest};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio::time::timeout;

    #[test]
    fn remote_and_tls_endpoints_are_rejected() {
        assert!(LocalOpenAiBackend::new("https://example.com", "model").is_err());
        assert!(LocalOpenAiBackend::new("https://127.0.0.1:1234", "model").is_err());
        assert!(LocalOpenAiBackend::new("http://example.com", "model").is_err());
        assert!(LocalOpenAiBackend::new("http://[::1]:1234", "model").is_ok());
        assert!(LocalOpenAiBackend::new("http://user:pass@127.0.0.1:1234", "model").is_err());
        assert!(LocalOpenAiBackend::new("http://127.0.0.1:1234", "model\nname").is_err());
    }

    #[tokio::test]
    async fn loopback_http_model_applies_only_a_valid_permutation() {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind loopback model");
        let address = listener.local_addr().expect("model address");
        let decision = r#"{"action":"rerank","candidateIds":[11,10],"confidence":0.9,"reasonCode":"semantic_context"}"#;
        let server = tokio::spawn(async move {
            let (mut stream, _) = timeout(Duration::from_secs(2), listener.accept())
                .await
                .expect("model connection timeout")
                .expect("model connection");
            let mut request = Vec::new();
            let mut chunk = [0_u8; 1024];
            let expected_length = loop {
                let read = stream.read(&mut chunk).await.expect("read model request");
                if read == 0 {
                    break 0;
                }
                request.extend_from_slice(&chunk[..read]);
                assert!(request.len() <= 64 * 1024, "model request is bounded");
                let Some(header_end) = request.windows(4).position(|window| window == b"\r\n\r\n")
                else {
                    continue;
                };
                let header_end = header_end + 4;
                let headers = String::from_utf8_lossy(&request[..header_end]);
                let length = headers
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .map(str::trim)
                            .and_then(|value| value.parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                if request.len() >= header_end + length {
                    break length;
                }
            };
            assert!(expected_length > 0, "model request has a JSON body");
            let envelope = json!({
                "choices": [{"message": {"content": decision}}]
            });
            let body = serde_json::to_vec(&envelope).expect("model response");
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream
                .write_all(response.as_bytes())
                .await
                .expect("write model headers");
            stream.write_all(&body).await.expect("write model body");
        });

        let backend =
            LocalOpenAiBackend::new(format!("http://127.0.0.1:{}", address.port()), "test-model")
                .expect("local model endpoint");
        let request = CandidateRerankRequest::new(
            1,
            1,
            vec![
                Candidate {
                    id: 10,
                    text: "日本".to_owned(),
                    reading: None,
                    rank: 0,
                },
                Candidate {
                    id: 11,
                    text: "日本語".to_owned(),
                    reading: None,
                    rank: 1,
                },
            ],
        );
        let output = timeout(
            Duration::from_secs(2),
            backend.rerank(request, CancellationToken::new()),
        )
        .await
        .expect("model request timeout")
        .expect("model response");
        assert!(output.adopted);
        assert_eq!(
            output
                .candidates
                .iter()
                .map(|candidate| candidate.id)
                .collect::<Vec<_>>(),
            vec![11, 10]
        );
        timeout(Duration::from_secs(2), server)
            .await
            .expect("model server timeout")
            .expect("model server task");
    }

    #[test]
    fn decision_requires_an_exact_permutation() {
        let request = CandidateRerankRequest::new(
            1,
            2,
            vec![
                Candidate {
                    id: 10,
                    text: "日本".to_owned(),
                    reading: None,
                    rank: 0,
                },
                Candidate {
                    id: 11,
                    text: "日本語".to_owned(),
                    reading: None,
                    rank: 1,
                },
            ],
        );
        let output = map_decision(
            &request,
            r#"{"action":"rerank","candidateIds":[11,10],"confidence":0.9,"reasonCode":"semantic_context"}"#,
            Duration::from_millis(1),
        )
        .expect("valid permutation");
        assert!(output.adopted);
        assert_eq!(output.candidates[0].id, 11);
        assert!(map_decision(
            &request,
            r#"{"action":"rerank","candidateIds":[10],"confidence":0.9,"reasonCode":"semantic_context"}"#,
            Duration::from_millis(1),
        )
        .is_err());
    }
}
