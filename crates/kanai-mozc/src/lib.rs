use std::env;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use kanai_core::{
    CandidateOrigin, CommitResult, ConversionCandidate, ConversionProvider, ConversionRequest,
    ConversionResult, PreeditSegment, ProviderCapabilities, ProviderError, ProviderHealth,
};
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, percent_decode_str, utf8_percent_encode};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;
use tokio::time::timeout;
use tracing::debug;

const REQUEST_ENCODE_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

#[derive(Debug, Clone)]
pub struct MozcBridgeConfig {
    pub binary_path: PathBuf,
    pub profile_dir: PathBuf,
    pub request_timeout: Duration,
}

impl Default for MozcBridgeConfig {
    fn default() -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."));
        let profile_dir = env::var_os("KANAI_MOZC_PROFILE")
            .map_or_else(|| root.join(".local/share/kanai/mozc"), PathBuf::from);
        let binary_path = env::var_os("KANAI_MOZC_BRIDGE")
            .map_or_else(|| find_bridge_binary(&root), PathBuf::from);
        Self {
            binary_path,
            profile_dir,
            request_timeout: Duration::from_secs(5),
        }
    }
}

#[derive(Clone)]
pub struct MozcBridge {
    config: MozcBridgeConfig,
    process: Arc<Mutex<Option<BridgeProcess>>>,
}

impl MozcBridge {
    #[must_use]
    pub fn new(config: MozcBridgeConfig) -> Self {
        Self {
            config,
            process: Arc::new(Mutex::new(None)),
        }
    }

    #[must_use]
    pub fn from_environment() -> Self {
        Self::new(MozcBridgeConfig::default())
    }

    #[must_use]
    pub fn binary_path(&self) -> &Path {
        &self.config.binary_path
    }

    async fn ensure_started(&self) -> Result<(), ProviderError> {
        let mut process = self.process.lock().await;
        if process.is_some() {
            return Ok(());
        }
        *process = Some(BridgeProcess::start(&self.config).await?);
        Ok(())
    }

    async fn call(&self, command: String) -> Result<BridgeResponse, ProviderError> {
        self.ensure_started().await?;
        let duration = self.config.request_timeout;
        let mut process = self.process.lock().await;
        let result = timeout(
            duration,
            process
                .as_mut()
                .expect("bridge process is initialized")
                .call(&command),
        )
        .await;
        match result {
            Ok(Ok(response)) if response.ok => Ok(response),
            Ok(Ok(response)) => Err(ProviderError::Protocol(response.error)),
            Ok(Err(error)) => {
                *process = None;
                Err(error)
            }
            Err(_) => {
                *process = None;
                Err(ProviderError::Timeout(duration))
            }
        }
    }
}

#[async_trait]
impl ConversionProvider for MozcBridge {
    fn name(&self) -> &'static str {
        "Mozc"
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            name: "Mozc".to_owned(),
            romaji: true,
            kana: true,
            n_best: true,
            context: true,
            user_dictionary: false,
            local: true,
        }
    }

    async fn health(&self) -> ProviderHealth {
        match self.call("ping".to_owned()).await {
            Ok(response) => ProviderHealth {
                available: true,
                provider: response.provider.unwrap_or_else(|| "Mozc".to_owned()),
                detail: response.detail.unwrap_or_else(|| "bridge ready".to_owned()),
                capabilities: self.capabilities(),
            },
            Err(error) => ProviderHealth {
                available: false,
                provider: "Mozc".to_owned(),
                detail: error.to_string(),
                capabilities: self.capabilities(),
            },
        }
    }

    async fn convert(
        &self,
        request: &ConversionRequest,
    ) -> Result<ConversionResult, ProviderError> {
        validate_request(request)?;
        let command = format!(
            "convert\t{}\t{}\t{}",
            encode(&request.romaji),
            encode(&request.context_before),
            encode(&request.context_after)
        );
        let response = self.call(command).await?;
        let candidates = response
            .candidates
            .unwrap_or_default()
            .into_iter()
            .enumerate()
            .map(|(index, candidate)| {
                let attributes = candidate.attributes.clone();
                ConversionCandidate {
                    id: candidate.id,
                    text: candidate.value,
                    reading: candidate.key,
                    provider_rank: candidate
                        .index
                        .map_or(index, |value| value.saturating_sub(1) as usize),
                    description: candidate.description,
                    origin: candidate.source.map_or_else(
                        || CandidateOrigin::from_attributes(&attributes),
                        |source| parse_origin(&source, &attributes),
                    ),
                    attributes,
                    log: if diagnostics_enabled() {
                        candidate.log.map(|value| value.chars().take(512).collect())
                    } else {
                        None
                    },
                }
            })
            .collect();

        Ok(ConversionResult {
            provider: response.provider.unwrap_or_else(|| "Mozc".to_owned()),
            reading: response.reading.unwrap_or_else(|| response.preedit.clone()),
            preedit: response.preedit,
            preedit_segments: response
                .preedit_segments
                .unwrap_or_default()
                .into_iter()
                .map(|segment| PreeditSegment {
                    value: segment.value,
                    reading: segment.key,
                    highlighted: segment.highlighted,
                })
                .collect(),
            candidates,
            focused_index: response.focused_index,
            consumed: response.consumed.unwrap_or(true),
            elapsed: Duration::from_micros(response.elapsed_micros.unwrap_or_default()),
        })
    }

    async fn commit(&self, candidate_id: i32) -> Result<CommitResult, ProviderError> {
        let response = self.call(format!("commit\t{candidate_id}")).await?;
        let text = response
            .text
            .or(response.result)
            .ok_or_else(|| ProviderError::Protocol("commit response has no text".to_owned()))?;
        Ok(CommitResult {
            text,
            elapsed_millis: response.elapsed_micros.unwrap_or_default() / 1_000,
        })
    }

    async fn reset(&self) -> Result<(), ProviderError> {
        self.call("reset".to_owned()).await.map(|_| ())
    }
}

fn diagnostics_enabled() -> bool {
    env::var("KANAI_DIAGNOSTICS")
        .is_ok_and(|value| value == "1" || value.eq_ignore_ascii_case("true"))
}

fn secure_profile_permissions(path: &Path) -> Result<(), ProviderError> {
    let metadata =
        std::fs::symlink_metadata(path).map_err(|error| ProviderError::Io(error.to_string()))?;
    if metadata.file_type().is_symlink() {
        return Err(ProviderError::Unavailable(
            "Mozc profile path must not be a symlink".to_owned(),
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(path, permissions)
            .map_err(|error| ProviderError::Io(error.to_string()))?;
    }
    Ok(())
}

#[derive(Debug)]
struct BridgeProcess {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl BridgeProcess {
    async fn start(config: &MozcBridgeConfig) -> Result<Self, ProviderError> {
        if !config.binary_path.is_file() {
            return Err(ProviderError::Unavailable(format!(
                "Mozc bridge not found at {}. Run scripts/build-mozc-bridge.sh.",
                config.binary_path.display()
            )));
        }
        tokio::fs::create_dir_all(&config.profile_dir)
            .await
            .map_err(|error| ProviderError::Io(error.to_string()))?;
        secure_profile_permissions(&config.profile_dir)?;
        let mut command = Command::new(&config.binary_path);
        command
            .arg(format!("--profile={}", config.profile_dir.display()))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(if diagnostics_enabled() {
                Stdio::inherit()
            } else {
                Stdio::null()
            })
            .kill_on_drop(true)
            .env_clear();
        for key in [
            "HOME",
            "PATH",
            "LANG",
            "LC_ALL",
            "TZ",
            "TMPDIR",
            "TEMP",
            "TMP",
            "XDG_RUNTIME_DIR",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "SYSTEMROOT",
            "WINDIR",
            "PATHEXT",
        ] {
            if let Some(value) = env::var_os(key) {
                command.env(key, value);
            }
        }
        let mut child = command
            .spawn()
            .map_err(|error| ProviderError::Io(error.to_string()))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| ProviderError::Protocol("bridge stdin is unavailable".to_owned()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| ProviderError::Protocol("bridge stdout is unavailable".to_owned()))?;
        debug!(binary = %config.binary_path.display(), "started Mozc bridge");
        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
        })
    }

    async fn call(&mut self, command: &str) -> Result<BridgeResponse, ProviderError> {
        self.stdin
            .write_all(command.as_bytes())
            .await
            .map_err(|error| ProviderError::Io(error.to_string()))?;
        self.stdin
            .write_all(b"\n")
            .await
            .map_err(|error| ProviderError::Io(error.to_string()))?;
        self.stdin
            .flush()
            .await
            .map_err(|error| ProviderError::Io(error.to_string()))?;
        let mut line = Vec::new();
        let bytes = self
            .stdout
            .read_until(b'\n', &mut line)
            .await
            .map_err(|error| ProviderError::Io(error.to_string()))?;
        if line.len() > 1_048_576 {
            return Err(ProviderError::Protocol(
                "Mozc bridge response exceeds 1 MiB".to_owned(),
            ));
        }
        if bytes == 0 {
            let status = self
                .child
                .try_wait()
                .map_err(|error| ProviderError::Io(error.to_string()))?;
            return Err(ProviderError::Unavailable(format!(
                "Mozc bridge exited: {status:?}"
            )));
        }
        let line = String::from_utf8(line).map_err(|error| {
            ProviderError::Protocol(format!("bridge response is not UTF-8: {error}"))
        })?;
        serde_json::from_str(line.trim_end())
            .map_err(|error| ProviderError::Protocol(format!("invalid bridge JSON ({error})")))
    }
}

impl Drop for BridgeProcess {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BridgeResponse {
    #[serde(default = "default_true")]
    ok: bool,
    #[serde(default)]
    error: String,
    #[serde(default)]
    provider: Option<String>,
    #[serde(default)]
    detail: Option<String>,
    #[serde(default)]
    reading: Option<String>,
    #[serde(default)]
    preedit: String,
    #[serde(default)]
    preedit_segments: Option<Vec<BridgePreeditSegment>>,
    #[serde(default)]
    candidates: Option<Vec<BridgeCandidate>>,
    #[serde(default)]
    focused_index: Option<usize>,
    #[serde(default)]
    consumed: Option<bool>,
    #[serde(default)]
    elapsed_micros: Option<u64>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    result: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BridgePreeditSegment {
    value: String,
    #[serde(default)]
    key: Option<String>,
    #[serde(default)]
    highlighted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BridgeCandidate {
    id: i32,
    value: String,
    #[serde(default)]
    key: Option<String>,
    #[serde(default)]
    index: Option<u32>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    source: Option<String>,
    #[serde(default)]
    attributes: Vec<String>,
    #[serde(default)]
    log: Option<String>,
}

const fn default_true() -> bool {
    true
}

fn parse_origin(source: &str, attributes: &[String]) -> CandidateOrigin {
    let normalized = source
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_lowercase();
    match normalized.as_str() {
        "prediction" => CandidateOrigin::Prediction,
        "suggestion" => CandidateOrigin::Suggestion,
        "userdictionary" => CandidateOrigin::UserDictionary,
        "userhistory" => CandidateOrigin::UserHistory,
        "typingcorrection" => CandidateOrigin::TypingCorrection,
        "spellingcorrection" => CandidateOrigin::SpellingCorrection,
        "conversion" => CandidateOrigin::from_attributes(attributes),
        _ => CandidateOrigin::Unknown(source.to_owned()),
    }
}

fn validate_request(request: &ConversionRequest) -> Result<(), ProviderError> {
    if request.romaji.is_empty() {
        return Err(ProviderError::InvalidRequest(
            "romaji input must not be empty".to_owned(),
        ));
    }
    if request.romaji.len() > 1_024 {
        return Err(ProviderError::InvalidRequest(
            "romaji input exceeds 1024 bytes".to_owned(),
        ));
    }
    if !request
        .romaji
        .bytes()
        .all(|byte| byte.is_ascii_graphic() || byte == b' ')
    {
        return Err(ProviderError::InvalidRequest(
            "romaji input contains unsupported characters".to_owned(),
        ));
    }
    if !(1..=30).contains(&request.limit) {
        return Err(ProviderError::InvalidRequest(
            "candidate limit must be between 1 and 30".to_owned(),
        ));
    }
    Ok(())
}

#[must_use]
pub fn encode(value: &str) -> String {
    utf8_percent_encode(value, REQUEST_ENCODE_SET).to_string()
}

pub fn decode(value: &str) -> Result<String, ProviderError> {
    if !has_valid_percent_escapes(value) {
        return Err(ProviderError::Protocol(
            "invalid percent encoding: malformed escape".to_owned(),
        ));
    }
    percent_decode_str(value)
        .decode_utf8()
        .map(|decoded| decoded.into_owned())
        .map_err(|error| ProviderError::Protocol(format!("invalid percent encoding: {error}")))
}

fn has_valid_percent_escapes(value: &str) -> bool {
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len()
                || !bytes[index + 1].is_ascii_hexdigit()
                || !bytes[index + 2].is_ascii_hexdigit()
            {
                return false;
            }
            index += 3;
        } else {
            index += 1;
        }
    }
    true
}

fn find_bridge_binary(root: &Path) -> PathBuf {
    let candidates = [
        root.join("third_party/mozc/src/bazel-bin/kanai/kanai_mozc_bridge"),
        root.join("third_party/mozc/src/bazel-bin/src/kanai/kanai_mozc_bridge"),
        root.join("third_party/mozc/bazel-bin/src/kanai/kanai_mozc_bridge"),
        root.join("target/release/kanai_mozc_bridge"),
    ];
    candidates
        .iter()
        .find(|path| path.is_file())
        .cloned()
        .unwrap_or_else(|| candidates[0].clone())
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use kanai_core::{ConversionProvider, ConversionRequest, ProviderError};

    use crate::{MozcBridge, decode, encode, validate_request};

    #[test]
    fn percent_round_trip_preserves_japanese_context() {
        let value = "変換 文脈\t確認";
        assert_eq!(decode(&encode(value)).expect("valid encoding"), value);
    }

    #[test]
    fn percent_encoding_escapes_protocol_separators_and_utf8() {
        assert_eq!(encode("abc-._~"), "abc-._~");
        assert_eq!(encode("100%"), "100%25");
        assert_eq!(
            encode("文脈\t確認\n"),
            "%E6%96%87%E8%84%88%09%E7%A2%BA%E8%AA%8D%0A"
        );
        assert_eq!(
            decode("%E6%97%A5%E6%9C%AC%E8%AA%9E").expect("valid UTF-8"),
            "日本語"
        );
        assert!(matches!(decode("%FF"), Err(ProviderError::Protocol(_))));
        assert!(matches!(decode("%"), Err(ProviderError::Protocol(_))));
        assert!(matches!(decode("%GG"), Err(ProviderError::Protocol(_))));
    }

    fn assert_invalid_request(request: &ConversionRequest, expected_message: &str) {
        match validate_request(request) {
            Err(ProviderError::InvalidRequest(message)) => {
                assert!(
                    message.contains(expected_message),
                    "unexpected message: {message}"
                );
            }
            other => panic!("expected invalid request, got {other:?}"),
        }
    }

    #[test]
    fn request_validation_rejects_unbounded_or_unsupported_input() {
        let mut request = ConversionRequest::new("kyou");
        assert!(validate_request(&request).is_ok());

        request.romaji.clear();
        assert_invalid_request(&request, "must not be empty");

        request.romaji = "a".repeat(1_025);
        assert_invalid_request(&request, "exceeds 1024 bytes");

        request.romaji = "日本語".to_owned();
        assert_invalid_request(&request, "unsupported characters");

        request.romaji = "kyou\n".to_owned();
        assert_invalid_request(&request, "unsupported characters");

        request.romaji = "a".repeat(1_024);
        request.limit = 0;
        assert_invalid_request(&request, "between 1 and 30");

        request.limit = 31;
        assert_invalid_request(&request, "between 1 and 30");

        request.limit = 1;
        assert!(validate_request(&request).is_ok());
    }

    #[tokio::test]
    async fn invalid_request_is_rejected_before_starting_the_bridge() {
        let profile_dir = tempfile::tempdir().expect("temporary profile directory");
        let bridge = MozcBridge::new(crate::MozcBridgeConfig {
            binary_path: "/definitely/missing/kanai_mozc_bridge".into(),
            profile_dir: profile_dir.path().to_owned(),
            request_timeout: Duration::from_millis(50),
        });
        let error = bridge
            .convert(&ConversionRequest::new(""))
            .await
            .expect_err("request should be invalid");
        assert!(matches!(error, ProviderError::InvalidRequest(_)));
    }

    #[tokio::test]
    async fn missing_bridge_has_actionable_error() {
        let profile_dir = tempfile::tempdir().expect("temporary profile directory");
        let bridge = MozcBridge::new(crate::MozcBridgeConfig {
            binary_path: "/definitely/missing/kanai_mozc_bridge".into(),
            profile_dir: profile_dir.path().to_owned(),
            request_timeout: Duration::from_millis(50),
        });
        let error = bridge
            .convert(&ConversionRequest::new("kyou"))
            .await
            .expect_err("bridge should be unavailable");
        assert!(matches!(error, ProviderError::Unavailable(_)));
    }
}
