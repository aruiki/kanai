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
use std::net::IpAddr;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use reqwest::{Client, Url};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    CancellationToken, CandidateRerankRequest, EnhancementBackend, EnhancementError,
    EnhancementMetrics, ProviderLocality, RerankOutput, SemanticAssistOutput,
    SemanticAssistRequest,
};

const MAX_RESPONSE_BYTES: usize = 64 * 1024;
const MAX_CONTEXT_CHARS: usize = 512;
const MAX_CANDIDATES: usize = 9;
const MAX_DEADLINE: Duration = Duration::from_secs(2);
const MAX_API_KEY_BYTES: usize = 512;

#[derive(Clone)]
pub struct LocalOpenAiBackend {
    client: Client,
    endpoint: Url,
    model: String,
    provider_id: String,
    /// Never printed, never logged, never placed in the URL or the payload.
    api_key: Option<String>,
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
        Self::build(base_url.as_ref(), model.into(), None)
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
        Self::build(base_url.as_ref(), model.into(), Some(api_key.into()))
    }

    fn build(base_url: &str, model: String, api_key: Option<String>) -> Result<Self, String> {
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
        })
    }

    async fn call_model(
        &self,
        payload: Value,
        cancellation: &CancellationToken,
    ) -> Result<String, EnhancementError> {
        if cancellation.is_cancelled() {
            return Err(EnhancementError::Cancelled);
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
        let envelope: Value = serde_json::from_slice(&bytes)
            .map_err(|error| EnhancementError::InvalidOutput(error.to_string()))?;
        envelope
            .pointer("/choices/0/message/content")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .ok_or_else(|| {
                EnhancementError::InvalidOutput("model response has no message content".to_owned())
            })
    }
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
