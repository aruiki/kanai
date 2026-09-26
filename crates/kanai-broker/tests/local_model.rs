//! Byte-level coverage for the optional loopback model adapter.
//!
//! The pinned `llama-server` release is launched with `--api-key-file`, so a
//! request without `Authorization: Bearer <key>` is answered `401` and the
//! enhancement queue silently keeps the Mozc baseline.  These tests therefore
//! assert on the exact bytes the client writes, and they also pin the negative
//! invariants: the key never reaches the URL, the payload, or `Debug`, and the
//! endpoint, size, and output rules are unchanged.
//!
//! Every test speaks minimal HTTP by hand over a `std::net::TcpListener` bound
//! to `127.0.0.1:0`.  No model weight, no real runtime, and no network access
//! beyond loopback are required.  The server side always drains the request and
//! always sends a complete response, and it gives up on its own deadline, so a
//! broken client cannot hang the test.

use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::mpsc::{self, Receiver};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use kanai_broker::{
    CancellationToken, Candidate, CandidateRerankRequest, EnhancementBackend, EnhancementError,
    LocalOpenAiBackend,
};

/// Upper bound for the whole test: the client deadline is 2s and the scripted
/// server gives up on its own `ACCEPT_DEADLINE`, which also bounds the join in
/// `Drop` for a stub whose client never connected.
const CLIENT_DEADLINE: Duration = Duration::from_secs(5);
const ACCEPT_DEADLINE: Duration = Duration::from_secs(4);
const SERVER_READ_TIMEOUT: Duration = Duration::from_millis(3_000);
const SERVER_WRITE_TIMEOUT: Duration = Duration::from_millis(500);
/// Matches the adapter's declared response bound; the tests only need to be on
/// the same side of it, never on the exact byte.
const OVERSIZE_RESPONSE_BYTES: usize = 96 * 1024;
const API_KEY: &str = "local-smoke-key-0f3a9c";

const DECISION: &str = r#"{"action":"rerank","candidateIds":[11,10],"confidence":0.9,"reasonCode":"semantic_context"}"#;

/// The complete request the client wrote, kept as text so the assertions can
/// look at the raw bytes instead of a parsed abstraction.
#[derive(Clone, Debug)]
struct CapturedRequest {
    raw: String,
    head: String,
    body: String,
}

impl CapturedRequest {
    fn request_line(&self) -> &str {
        self.head.lines().next().unwrap_or_default()
    }

    fn header_lines(&self) -> impl Iterator<Item = &str> + '_ {
        self.head
            .lines()
            .skip(1)
            .take_while(|line| !line.is_empty())
    }

    /// Trimmed value of the first matching header, in any capitalization.
    fn header(&self, name: &str) -> Option<String> {
        self.header_lines().find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.trim()
                .eq_ignore_ascii_case(name)
                .then(|| value.trim().to_owned())
        })
    }

    fn header_count(&self, name: &str) -> usize {
        self.header_lines()
            .filter(|line| {
                line.split_once(':')
                    .is_some_and(|(key, _)| key.trim().eq_ignore_ascii_case(name))
            })
            .count()
    }

    fn head_lines_containing(&self, needle: &str) -> Vec<String> {
        self.head
            .lines()
            .filter(|line| line.contains(needle))
            .map(ToOwned::to_owned)
            .collect()
    }

    fn occurrences(&self, needle: &str) -> usize {
        self.raw.matches(needle).count()
    }
}

/// How the scripted model answers.  `Framed` declares its length, which is what
/// reqwest reports through `Content-Length`.  `Unframed` ends the body at
/// connection close, so no length is declared and the size bound is enforced
/// only while streaming.
enum ScriptedResponse {
    Framed { status: &'static str, body: Vec<u8> },
    Unframed { status: &'static str, body: Vec<u8> },
}

impl ScriptedResponse {
    fn json(status: &'static str, body: &str) -> Self {
        Self::Framed {
            status,
            body: body.as_bytes().to_vec(),
        }
    }

    fn unframed(status: &'static str, body: Vec<u8>) -> Self {
        Self::Unframed { status, body }
    }
}

/// A single-connection loopback model stub plus the request it observed.
struct ScriptedModel {
    address: SocketAddr,
    requests: Receiver<CapturedRequest>,
    handle: Option<JoinHandle<()>>,
}

impl ScriptedModel {
    fn start(response: ScriptedResponse) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind scripted model");
        listener
            .set_nonblocking(true)
            .expect("non-blocking scripted model");
        let address = listener.local_addr().expect("scripted model address");
        let (sender, requests) = mpsc::channel();
        let handle = thread::spawn(move || {
            let stream = accept_with_deadline(&listener);
            if let Some(mut stream) = stream {
                let _ = stream.set_read_timeout(Some(SERVER_READ_TIMEOUT));
                let _ = stream.set_write_timeout(Some(SERVER_WRITE_TIMEOUT));
                if let Some(captured) = read_request(&mut stream) {
                    // The capture is best effort: the assertions that need it
                    // fail loudly on a closed channel.
                    let _ = sender.send(captured);
                }
                write_response(&mut stream, &response);
                let _ = stream.shutdown(Shutdown::Both);
            }
        });
        Self {
            address,
            requests,
            handle: Some(handle),
        }
    }

    fn base_url(&self) -> String {
        format!("http://{}", self.address)
    }

    /// Wait for the observed request.  The stub's own deadline bounds the wait.
    fn take_request(&self) -> CapturedRequest {
        self.requests
            .recv_timeout(ACCEPT_DEADLINE + CLIENT_DEADLINE)
            .expect("the client must have written one request")
    }

    /// Assert that the client never connected, without waiting for the stub's
    /// own deadline.
    fn expect_no_request(&self) {
        assert!(
            matches!(
                self.requests.recv_timeout(Duration::from_millis(200)),
                Err(mpsc::RecvTimeoutError::Timeout)
            ),
            "the client must not have opened a connection"
        );
    }
}

impl Drop for ScriptedModel {
    fn drop(&mut self) {
        // The stub thread is deadline-bounded, so this join cannot hang.
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

fn accept_with_deadline(listener: &TcpListener) -> Option<TcpStream> {
    let deadline = Instant::now() + ACCEPT_DEADLINE;
    while Instant::now() < deadline {
        match listener.accept() {
            Ok((stream, _)) => return Some(stream),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(5));
            }
            Err(_) => return None,
        }
    }
    None
}

fn declared_body_length(head: &str) -> usize {
    head.lines()
        .find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.trim()
                .eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().ok())
                .flatten()
        })
        .unwrap_or(0)
}

/// Drain the whole request head and body, or give up without hanging.
fn read_request(stream: &mut TcpStream) -> Option<CapturedRequest> {
    let mut raw = Vec::new();
    let mut chunk = [0_u8; 4096];
    let (head_end, body_length) = loop {
        let read = stream.read(&mut chunk).ok()?;
        if read == 0 {
            return None;
        }
        raw.extend_from_slice(&chunk[..read]);
        if raw.len() > 256 * 1024 {
            return None;
        }
        if let Some(position) = raw.windows(4).position(|window| window == b"\r\n\r\n") {
            let head_end = position + 4;
            let head = String::from_utf8_lossy(&raw[..head_end]);
            break (head_end, declared_body_length(&head));
        }
    };
    while raw.len() < head_end + body_length {
        let read = stream.read(&mut chunk).ok()?;
        if read == 0 {
            break;
        }
        raw.extend_from_slice(&chunk[..read]);
    }
    let raw = String::from_utf8_lossy(&raw).into_owned();
    Some(CapturedRequest {
        head: raw[..head_end].to_owned(),
        body: raw[head_end..].to_owned(),
        raw,
    })
}

/// Always send a complete response, even to a client that already gave up.
fn write_response(stream: &mut TcpStream, response: &ScriptedResponse) {
    match response {
        ScriptedResponse::Framed { status, body } => {
            let head = format!(
                "HTTP/1.1 {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                status,
                body.len()
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(body);
        }
        ScriptedResponse::Unframed { status, body } => {
            let head = format!(
                "HTTP/1.1 {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
                status
            );
            let _ = stream.write_all(head.as_bytes());
            for part in body.chunks(8 * 1024) {
                if stream.write_all(part).is_err() {
                    return;
                }
            }
        }
    }
    let _ = stream.flush();
}

fn completion_body() -> String {
    serde_json::json!({
        "choices": [{"message": {"content": DECISION}}]
    })
    .to_string()
}

fn rerank_request() -> CandidateRerankRequest {
    CandidateRerankRequest::new(
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
                reading: Some("にほんご".to_owned()),
                rank: 1,
            },
        ],
    )
}

async fn rerank(backend: &LocalOpenAiBackend) -> Result<(), EnhancementError> {
    let output = tokio::time::timeout(
        CLIENT_DEADLINE,
        backend.rerank(rerank_request(), CancellationToken::new()),
    )
    .await
    .expect("local model request must finish inside the test deadline")
    .expect("local model request must succeed");
    assert!(output.adopted, "the scripted decision must be adopted");
    assert_eq!(
        output
            .candidates
            .iter()
            .map(|candidate| candidate.id)
            .collect::<Vec<_>>(),
        vec![11, 10]
    );
    Ok(())
}

#[tokio::test]
async fn a_configured_key_is_sent_as_a_bearer_token() {
    let model = ScriptedModel::start(ScriptedResponse::json("200 OK", &completion_body()));
    let backend = LocalOpenAiBackend::new_with_api_key(model.base_url(), "test-model", API_KEY)
        .expect("backend with a key");
    rerank(&backend).await.expect("rerank with a key");
    let request = model.take_request();
    assert_eq!(request.header_count("authorization"), 1);
    assert_eq!(
        request.header("authorization").as_deref(),
        Some(format!("Bearer {API_KEY}").as_str())
    );
}

#[tokio::test]
async fn no_authorization_header_is_sent_without_a_key() {
    let model = ScriptedModel::start(ScriptedResponse::json("200 OK", &completion_body()));
    let backend =
        LocalOpenAiBackend::new(model.base_url(), "test-model").expect("backend without a key");
    rerank(&backend).await.expect("rerank without a key");
    let request = model.take_request();
    assert_eq!(request.header_count("authorization"), 0);
    assert_eq!(request.header("authorization"), None);
    // Not an empty header and not a malformed one: the name never appears.
    assert!(
        !request.head.to_ascii_lowercase().contains("authorization"),
        "no Authorization header may be present at all"
    );
}

#[tokio::test]
async fn the_key_never_leaves_the_authorization_header() {
    let model = ScriptedModel::start(ScriptedResponse::json("200 OK", &completion_body()));
    let backend = LocalOpenAiBackend::new_with_api_key(model.base_url(), "test-model", API_KEY)
        .expect("backend with a key");
    rerank(&backend).await.expect("rerank with a key");
    let request = model.take_request();

    // The key appears exactly once in the whole request.
    assert_eq!(
        request.occurrences(API_KEY),
        1,
        "raw request was: {}",
        request.raw
    );
    // Not in the request line, so not in the URL, and not in the payload.
    assert!(
        !request.request_line().contains(API_KEY),
        "request line was {}",
        request.request_line()
    );
    assert!(
        !request.body.contains(API_KEY),
        "request body was {}",
        request.body
    );
    // The single occurrence is the Authorization line, and nothing else in the
    // head repeats the secret.
    let carriers = request.head_lines_containing(API_KEY);
    assert_eq!(carriers.len(), 1, "carriers were {carriers:?}");
    let (name, value) = carriers[0].split_once(':').expect("header separator");
    assert_eq!(name.trim(), "authorization");
    assert_eq!(value.trim(), format!("Bearer {API_KEY}"));
    // The transport is still the pinned loopback endpoint and nothing else.
    assert_eq!(request.request_line(), "POST /v1/chat/completions HTTP/1.1");
    assert!(
        request
            .header("host")
            .is_some_and(|host| host == model.address.to_string()),
        "unexpected Host header"
    );
}

#[test]
fn debug_output_reports_but_never_prints_the_key() {
    let with_key =
        LocalOpenAiBackend::new_with_api_key("http://127.0.0.1:18080", "test-model", API_KEY)
            .expect("backend with a key");
    let rendered = format!("{with_key:?}");
    assert!(
        !rendered.contains(API_KEY),
        "Debug leaked the key: {rendered}"
    );
    assert!(rendered.contains("<redacted>"), "Debug was {rendered}");
    assert!(rendered.contains("api_key"), "Debug was {rendered}");
    assert!(rendered.contains("test-model"), "Debug was {rendered}");
    assert!(
        rendered.contains("openai-compatible:test-model"),
        "Debug was {rendered}"
    );
    assert!(
        rendered.contains("http://127.0.0.1:18080/v1/chat/completions"),
        "Debug was {rendered}"
    );

    let without_key = LocalOpenAiBackend::new("http://127.0.0.1:18080", "test-model")
        .expect("backend without a key");
    let rendered = format!("{without_key:?}");
    assert!(!rendered.contains("<redacted>"), "Debug was {rendered}");
    assert!(rendered.contains("none"), "Debug was {rendered}");
}

#[test]
fn unusable_api_keys_are_rejected_at_construction() {
    let base = "http://127.0.0.1:18080";
    let too_long = "k".repeat(513);
    let longest_accepted = "k".repeat(512);
    for rejected in [
        String::new(),
        too_long,
        "has space".to_owned(),
        "tab\there".to_owned(),
        "line\nbreak".to_owned(),
        "carriage\rreturn".to_owned(),
        "nul\0byte".to_owned(),
    ] {
        assert!(
            LocalOpenAiBackend::new_with_api_key(base, "test-model", rejected.clone()).is_err(),
            "{rejected:?} must be rejected"
        );
    }
    assert!(
        LocalOpenAiBackend::new_with_api_key(base, "test-model", longest_accepted).is_ok(),
        "a 512 byte key is within the bound"
    );
    assert!(LocalOpenAiBackend::new_with_api_key(base, "test-model", "sk-abc_123.XYZ").is_ok());
}

#[tokio::test]
async fn a_non_success_status_stays_provider_unavailable() {
    // The pinned runtime answers exactly this when the bearer token is missing
    // or wrong, so the Mozc baseline must survive it unchanged.
    for (status, expected) in [
        ("401 Unauthorized", "local model returned HTTP 401"),
        ("403 Forbidden", "local model returned HTTP 403"),
        ("500 Internal Server Error", "local model returned HTTP 500"),
    ] {
        let model = ScriptedModel::start(ScriptedResponse::json(
            status,
            r#"{"error":{"message":"invalid api key"}}"#,
        ));
        let backend = LocalOpenAiBackend::new_with_api_key(model.base_url(), "test-model", API_KEY)
            .expect("backend with a key");
        let error = tokio::time::timeout(
            CLIENT_DEADLINE,
            backend.rerank(rerank_request(), CancellationToken::new()),
        )
        .await
        .expect("local model request must finish inside the test deadline")
        .expect_err("a non-2xx response must fail");
        assert_eq!(
            error,
            EnhancementError::ProviderUnavailable(expected.to_owned())
        );
        model.take_request();
    }
}

#[tokio::test]
async fn response_size_and_output_bounds_are_unchanged() {
    // A declared length above the bound is rejected before any body is read.
    let declared = ScriptedModel::start(ScriptedResponse::json(
        "200 OK",
        &format!("{{\"pad\":\"{}\"}}", "a".repeat(OVERSIZE_RESPONSE_BYTES)),
    ));
    let backend = LocalOpenAiBackend::new_with_api_key(declared.base_url(), "test-model", API_KEY)
        .expect("backend with a key");
    let error = tokio::time::timeout(
        CLIENT_DEADLINE,
        backend.rerank(rerank_request(), CancellationToken::new()),
    )
    .await
    .expect("local model request must finish inside the test deadline")
    .expect_err("an oversized response must fail");
    assert_eq!(
        error,
        EnhancementError::InvalidOutput("local model response is too large".to_owned())
    );
    declared.take_request();

    // An undeclared length is caught while streaming, past the same bound.
    let streamed = ScriptedModel::start(ScriptedResponse::unframed(
        "200 OK",
        vec![b'a'; OVERSIZE_RESPONSE_BYTES],
    ));
    let backend = LocalOpenAiBackend::new_with_api_key(streamed.base_url(), "test-model", API_KEY)
        .expect("backend with a key");
    let error = tokio::time::timeout(
        CLIENT_DEADLINE,
        backend.rerank(rerank_request(), CancellationToken::new()),
    )
    .await
    .expect("local model request must finish inside the test deadline")
    .expect_err("an oversized streamed response must fail");
    assert_eq!(
        error,
        EnhancementError::InvalidOutput("local model response is too large".to_owned())
    );
    streamed.take_request();

    // A 200 that is not JSON at all.
    let malformed = ScriptedModel::start(ScriptedResponse::json("200 OK", "not json at all"));
    let backend = LocalOpenAiBackend::new_with_api_key(malformed.base_url(), "test-model", API_KEY)
        .expect("backend with a key");
    let error = tokio::time::timeout(
        CLIENT_DEADLINE,
        backend.rerank(rerank_request(), CancellationToken::new()),
    )
    .await
    .expect("local model request must finish inside the test deadline")
    .expect_err("a malformed response must fail");
    assert!(
        matches!(error, EnhancementError::InvalidOutput(_)),
        "unexpected error: {error:?}"
    );
    malformed.take_request();

    // A 200 that is JSON without message content.
    let no_content = ScriptedModel::start(ScriptedResponse::json("200 OK", r#"{"choices":[]}"#));
    let backend =
        LocalOpenAiBackend::new_with_api_key(no_content.base_url(), "test-model", API_KEY)
            .expect("backend with a key");
    let error = tokio::time::timeout(
        CLIENT_DEADLINE,
        backend.rerank(rerank_request(), CancellationToken::new()),
    )
    .await
    .expect("local model request must finish inside the test deadline")
    .expect_err("a response without content must fail");
    assert_eq!(
        error,
        EnhancementError::InvalidOutput("model response has no message content".to_owned())
    );
    no_content.take_request();
}

#[tokio::test]
async fn semantic_assist_stays_unavailable() {
    let model = ScriptedModel::start(ScriptedResponse::json("200 OK", &completion_body()));
    let backend = LocalOpenAiBackend::new_with_api_key(model.base_url(), "test-model", API_KEY)
        .expect("backend with a key");
    let error = tokio::time::timeout(
        CLIENT_DEADLINE,
        backend.semantic_assist(
            kanai_broker::SemanticAssistRequest::new(
                1,
                1,
                kanai_broker::SemanticIntent::Rewrite,
                "文".to_owned(),
            ),
            CancellationToken::new(),
        ),
    )
    .await
    .expect("semantic assist must answer inside the test deadline")
    .expect_err("semantic assist is not enabled here");
    assert_eq!(
        error,
        EnhancementError::ProviderUnavailable(
            "semantic assist is not enabled for the local reranker".to_owned()
        )
    );
    model.expect_no_request();
}

#[test]
fn endpoint_and_credential_rules_are_unchanged_with_a_key() {
    for rejected in [
        "https://example.com",
        "https://127.0.0.1:1234",
        "http://example.com",
        "http://10.0.0.1:1234",
        "http://user:pass@127.0.0.1:1234",
    ] {
        assert!(
            LocalOpenAiBackend::new_with_api_key(rejected, "test-model", API_KEY).is_err(),
            "{rejected} must be rejected"
        );
    }
    assert!(
        LocalOpenAiBackend::new_with_api_key("http://[::1]:1234", "test-model", API_KEY).is_ok()
    );
    assert!(
        LocalOpenAiBackend::new_with_api_key("http://localhost:1234", "test-model", API_KEY)
            .is_ok()
    );
    // An empty base URL, an unparsable one, and a bad model stay rejected.
    assert!(LocalOpenAiBackend::new_with_api_key("", "test-model", API_KEY).is_err());
    assert!(LocalOpenAiBackend::new_with_api_key("not a url", "test-model", API_KEY).is_err());
    assert!(
        LocalOpenAiBackend::new_with_api_key("http://127.0.0.1:1234", "model\nname", API_KEY)
            .is_err()
    );
    // A path, query, and fragment in the base URL are replaced by the fixed
    // loopback endpoint, so a key smuggled through the URL cannot survive.
    let backend = LocalOpenAiBackend::new_with_api_key(
        "http://127.0.0.1:1234/ignored?api_key=url-secret#frag",
        "m",
        API_KEY,
    )
    .expect("bounded endpoint");
    let rendered = format!("{backend:?}");
    assert!(
        rendered.contains("http://127.0.0.1:1234/v1/chat/completions"),
        "the endpoint must be fixed: {rendered}"
    );
    assert!(
        !rendered.contains("url-secret") && !rendered.contains("api_key="),
        "the query must be stripped: {rendered}"
    );
}
