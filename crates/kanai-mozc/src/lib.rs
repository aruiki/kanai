use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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

const BRIDGE_BINARY_STEMS: [&str; 2] = ["kanai-mozc-bridge", "kanai_mozc_bridge"];

// Keep the child process deliberately small and non-secret-bearing. In
// particular, KANA_AI_* values belong to the API's optional assistant and
// must never be inherited by the native Mozc process.
const BRIDGE_ENV_KEYS: &[&str] = &[
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
];

#[derive(Debug, Clone)]
pub struct MozcBridgeConfig {
    pub binary_path: PathBuf,
    pub profile_dir: PathBuf,
    pub request_timeout: Duration,
}

fn default_profile_dir(root: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        if let Some(local_app_data) = env::var_os("LOCALAPPDATA") {
            return PathBuf::from(local_app_data).join("KanaAI").join("Mozc");
        }
        if let Some(user_profile) = env::var_os("USERPROFILE") {
            return PathBuf::from(user_profile)
                .join("AppData/Local")
                .join("KanaAI")
                .join("Mozc");
        }
    }
    root.join(".local/share/kanai/mozc")
}

fn non_empty_path(value: Option<OsString>) -> Option<PathBuf> {
    value
        .filter(|value| !value.as_os_str().is_empty())
        .map(PathBuf::from)
}

fn configured_bridge_path<F>(lookup: F, executable: Option<&Path>) -> Option<PathBuf>
where
    F: Fn(&str) -> Option<OsString>,
{
    let path = non_empty_path(lookup("KANAI_MOZC_BRIDGE"))?;
    if path.is_absolute() || path.is_file() {
        return Some(path);
    }

    // A package launcher normally supplies an absolute path, but accepting a
    // path relative to the executable makes direct `bin\\kanai.exe` and
    // `bin\\kanai-api.exe` launches behave like the packaged launchers.
    if let Some(executable) = executable {
        for directory in executable_search_directories(executable) {
            let candidate = directory.join(&path);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    Some(path)
}

impl MozcBridgeConfig {
    /// Reads local Mozc process settings only; optional `KANA_AI_*` settings
    /// remain owned by the API's explicit assistant path.
    #[must_use]
    pub fn from_environment() -> Self {
        Self::default()
    }
}

impl Default for MozcBridgeConfig {
    fn default() -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."));
        let executable = env::current_exe().ok();
        let profile_dir = non_empty_path(env::var_os("KANAI_MOZC_PROFILE"))
            .unwrap_or_else(|| default_profile_dir(&root));
        let binary_path = configured_bridge_path(|key| env::var_os(key), executable.as_deref())
            .unwrap_or_else(|| find_bridge_binary(&root));
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
    /// Serializes conversion/commit operations so a late response cannot
    /// overwrite the generation recorded by a newer conversion.
    operation: Arc<Mutex<()>>,
    last_revision: Arc<Mutex<Option<u64>>>,
}

impl MozcBridge {
    #[must_use]
    pub fn new(config: MozcBridgeConfig) -> Self {
        Self {
            config,
            process: Arc::new(Mutex::new(None)),
            operation: Arc::new(Mutex::new(())),
            last_revision: Arc::new(Mutex::new(None)),
        }
    }

    #[must_use]
    pub fn from_environment() -> Self {
        Self::new(MozcBridgeConfig::from_environment())
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

    async fn commit_inner(
        &self,
        candidate_id: i32,
        expected_revision: Option<u64>,
    ) -> Result<CommitResult, ProviderError> {
        let _operation = self.operation.lock().await;
        let revision = match expected_revision {
            Some(revision) => revision,
            None => self.last_revision.lock().await.ok_or_else(|| {
                ProviderError::Unavailable("no Mozc conversion is active".to_owned())
            })?,
        };
        let response = match self
            .call(format!("commit\t{candidate_id}\t{revision}"))
            .await
        {
            Ok(response) => response,
            Err(error) => {
                *self.last_revision.lock().await = None;
                return Err(error);
            }
        };
        if response.generation != Some(revision) {
            *self.last_revision.lock().await = None;
            return Err(ProviderError::Protocol(
                "Mozc bridge returned a different commit generation".to_owned(),
            ));
        }
        *self.last_revision.lock().await = None;
        let text = response
            .text
            .or(response.result)
            .ok_or_else(|| ProviderError::Protocol("commit response has no text".to_owned()))?;
        Ok(CommitResult {
            text,
            elapsed_millis: response.elapsed_micros.unwrap_or_default() / 1_000,
        })
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
        let _operation = self.operation.lock().await;
        *self.last_revision.lock().await = None;
        let command = format!(
            "convert\t{}\t{}\t{}\t{}",
            encode(&request.romaji),
            encode(&request.context_before),
            encode(&request.context_after),
            request.revision
        );
        let response = self.call(command).await?;
        if response.generation != Some(request.revision) {
            return Err(ProviderError::Protocol(
                "Mozc bridge returned a different conversion generation".to_owned(),
            ));
        }
        *self.last_revision.lock().await = Some(request.revision);
        Ok(conversion_result_from_response(response, true))
    }

    async fn commit(&self, candidate_id: i32) -> Result<CommitResult, ProviderError> {
        self.commit_inner(candidate_id, None).await
    }

    async fn commit_at(
        &self,
        candidate_id: i32,
        revision: u64,
    ) -> Result<CommitResult, ProviderError> {
        self.commit_inner(candidate_id, Some(revision)).await
    }

    async fn reset(&self) -> Result<(), ProviderError> {
        let _operation = self.operation.lock().await;
        let result = self.call("reset".to_owned()).await;
        if result.is_ok() {
            *self.last_revision.lock().await = None;
        }
        result.map(|_| ())
    }
}

/// A normalized key event accepted by the multiplexed Mozc bridge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MozcKey {
    Character(String),
    Space,
    Backspace,
    Delete,
    Escape,
    Tab,
    Enter,
    Left,
    Right,
    Up,
    Down,
    Function(u8),
    Named(String),
}

impl MozcKey {
    fn fields(&self) -> Result<Vec<String>, ProviderError> {
        let (kind, value) = match self {
            Self::Character(value) => {
                if value.is_empty() || value.len() > 1024 || value.chars().any(char::is_control) {
                    return Err(ProviderError::InvalidRequest(
                        "character key must be non-empty, valid, and at most 1024 bytes".to_owned(),
                    ));
                }
                ("character", encode(value))
            }
            Self::Space => ("space", String::new()),
            Self::Backspace => ("backspace", String::new()),
            Self::Delete => ("delete", String::new()),
            Self::Escape => ("escape", String::new()),
            Self::Tab => ("tab", String::new()),
            Self::Enter => ("enter", String::new()),
            Self::Left => ("left", String::new()),
            Self::Right => ("right", String::new()),
            Self::Up => ("up", String::new()),
            Self::Down => ("down", String::new()),
            Self::Function(number) => ("function", number.to_string()),
            Self::Named(name) => {
                if name.is_empty() || name.len() > 64 || name.chars().any(char::is_control) {
                    return Err(ProviderError::InvalidRequest(
                        "named key must be non-empty and at most 64 bytes".to_owned(),
                    ));
                }
                ("named", encode(name))
            }
        };
        Ok(vec![kind.to_owned(), value])
    }
}

/// A bounded composition edit accepted by the multiplexed Mozc bridge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MozcEdit {
    Insert(String),
    Replace { start: u32, end: u32, text: String },
    Delete { start: u32, end: u32 },
    Reset,
}

impl MozcEdit {
    fn fields(&self) -> Result<Vec<String>, ProviderError> {
        match self {
            Self::Reset => Ok(vec!["reset".to_owned()]),
            Self::Insert(text) => {
                validate_edit_text(text)?;
                Ok(vec!["insert".to_owned(), encode(text)])
            }
            Self::Delete { start, end } => Ok(vec![
                "delete".to_owned(),
                start.to_string(),
                end.to_string(),
            ]),
            Self::Replace { start, end, text } => {
                validate_edit_text(text)?;
                Ok(vec![
                    "replace".to_owned(),
                    start.to_string(),
                    end.to_string(),
                    encode(text),
                ])
            }
        }
    }
}

fn validate_edit_text(text: &str) -> Result<(), ProviderError> {
    if text.len() > 16 * 1024 || text.chars().any(char::is_control) {
        return Err(ProviderError::InvalidRequest(
            "edit text is invalid or too large".to_owned(),
        ));
    }
    Ok(())
}

/// State returned by a stateful key/edit operation on a multiplexed bridge.
#[derive(Debug, Clone, PartialEq)]
pub struct MozcSessionState {
    pub preedit: String,
    pub reading: String,
    pub preedit_segments: Vec<PreeditSegment>,
    pub candidates: Vec<ConversionCandidate>,
    pub focused_index: Option<usize>,
    pub consumed: bool,
    pub elapsed: Duration,
}

/// One supervised, bounded Mozc process shared by independent bridge sessions.
///
/// The child process owns at most 64 upstream sessions. All line-protocol
/// calls are serialized because the pinned `SessionHandler` is a synchronous
/// owner; the broker's optional model queue remains completely separate.
#[derive(Clone)]
pub struct MozcBridgePool {
    config: MozcBridgeConfig,
    process: Arc<Mutex<Option<BridgeProcess>>>,
    operation: Arc<Mutex<()>>,
    /// Monotonic identity of the child process. A session must never be
    /// reused across an epoch boundary without an explicit host recovery.
    epoch: Arc<AtomicU64>,
    /// A failed child is not silently replaced by the next health probe or
    /// stale command. The session owner must explicitly restart before opening
    /// a new session.
    failed: Arc<AtomicBool>,
}

impl std::fmt::Debug for MozcBridgePool {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MozcBridgePool")
            .field("binary_path", &self.config.binary_path)
            .field("profile_dir", &self.config.profile_dir)
            .field("epoch", &self.epoch.load(Ordering::Acquire))
            .field("failed", &self.failed.load(Ordering::Acquire))
            .finish()
    }
}

impl MozcBridgePool {
    #[must_use]
    pub fn new(config: MozcBridgeConfig) -> Self {
        Self {
            config,
            process: Arc::new(Mutex::new(None)),
            operation: Arc::new(Mutex::new(())),
            epoch: Arc::new(AtomicU64::new(0)),
            failed: Arc::new(AtomicBool::new(false)),
        }
    }

    #[must_use]
    pub fn from_environment() -> Self {
        Self::new(MozcBridgeConfig::from_environment())
    }

    async fn call(&self, command: String) -> Result<BridgeResponse, ProviderError> {
        let _operation = self.operation.lock().await;
        if self.failed.load(Ordering::Acquire) {
            return Err(ProviderError::Unavailable(
                "Mozc bridge is unavailable after a child failure; explicit restart required"
                    .to_owned(),
            ));
        }
        let mut process = self.process.lock().await;
        if process.is_none() {
            match BridgeProcess::start(&self.config).await {
                Ok(started) => *process = Some(started),
                Err(error) => {
                    self.failed.store(true, Ordering::Release);
                    return Err(error);
                }
            }
        }
        let duration = self.config.request_timeout;
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
                let failed = process.take();
                self.failed.store(true, Ordering::Release);
                self.epoch.fetch_add(1, Ordering::AcqRel);
                drop(process);
                if let Some(failed) = failed {
                    failed.terminate().await;
                }
                Err(error)
            }
            Err(_) => {
                let failed = process.take();
                self.failed.store(true, Ordering::Release);
                self.epoch.fetch_add(1, Ordering::AcqRel);
                drop(process);
                if let Some(failed) = failed {
                    failed.terminate().await;
                }
                Err(ProviderError::Timeout(duration))
            }
        }
    }

    /// Monotonic child-process identity. Callers use this to reject a result
    /// that was produced by a process which has since been replaced.
    #[must_use]
    pub fn epoch(&self) -> u64 {
        self.epoch.load(Ordering::Acquire)
    }

    /// Whether the pool is in the fail-closed state after child I/O loss.
    #[must_use]
    pub fn failed(&self) -> bool {
        self.failed.load(Ordering::Acquire)
    }

    /// Explicitly replace a failed child. Existing sessions are deliberately
    /// not reopened: their composition and candidate generations belonged to
    /// the old epoch and must be invalidated by the owner first.
    pub async fn restart(&self) -> Result<(), ProviderError> {
        let _operation = self.operation.lock().await;
        let mut process = self.process.lock().await;
        let old = process.take();
        self.failed.store(false, Ordering::Release);
        self.epoch.fetch_add(1, Ordering::AcqRel);
        drop(process);
        if let Some(old) = old {
            old.terminate().await;
        }
        let started = BridgeProcess::start(&self.config).await;
        match started {
            Ok(started) => {
                *self.process.lock().await = Some(started);
                Ok(())
            }
            Err(error) => {
                self.failed.store(true, Ordering::Release);
                Err(error)
            }
        }
    }

    /// Return the child PID for diagnostics and integration tests. `None`
    /// means the pool has not started its process yet.
    pub async fn process_id(&self) -> Option<u32> {
        self.process
            .lock()
            .await
            .as_ref()
            .and_then(|process| process.child.id())
    }

    pub async fn health(&self) -> ProviderHealth {
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
}

/// A client handle for one explicit session in a [`MozcBridgePool`].
#[derive(Clone)]
pub struct MozcSessionClient {
    pool: MozcBridgePool,
    session_id: u64,
}

impl std::fmt::Debug for MozcSessionClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MozcSessionClient")
            .field("pool", &self.pool)
            .field("session_id", &self.session_id)
            .finish()
    }
}

impl MozcSessionClient {
    #[must_use]
    pub fn new(pool: MozcBridgePool, session_id: u64) -> Self {
        Self { pool, session_id }
    }

    #[must_use]
    pub fn session_id(&self) -> u64 {
        self.session_id
    }

    pub async fn open(&self) -> Result<(), ProviderError> {
        if self.session_id == 0 {
            return Err(ProviderError::InvalidRequest(
                "bridge session id must be non-zero".to_owned(),
            ));
        }
        let response = self.pool.call(format!("open\t{}", self.session_id)).await?;
        if response.session_id != Some(self.session_id) || response.generation != Some(0) {
            return Err(ProviderError::Protocol(
                "Mozc bridge returned an uncorrelated open response".to_owned(),
            ));
        }
        Ok(())
    }

    pub async fn close(&self) -> Result<(), ProviderError> {
        self.close_at(None).await
    }

    pub async fn close_at(&self, generation: Option<u64>) -> Result<(), ProviderError> {
        let command = generation.map_or_else(
            || format!("close\t{}", self.session_id),
            |generation| format!("close\t{}\t{}", self.session_id, generation),
        );
        let response = self.pool.call(command).await?;
        if response.session_id != Some(self.session_id)
            || generation.is_some_and(|expected| response.generation != Some(expected))
        {
            return Err(ProviderError::Protocol(
                "Mozc bridge returned an uncorrelated close response".to_owned(),
            ));
        }
        Ok(())
    }

    pub async fn key(
        &self,
        key: &MozcKey,
        generation: u64,
    ) -> Result<MozcSessionState, ProviderError> {
        let fields = key.fields()?;
        let response = self
            .pool
            .call(format!(
                "key\t{}\t{}\t{}\t{}",
                self.session_id, generation, fields[0], fields[1]
            ))
            .await?;
        let expected_generation = generation.checked_add(1).ok_or_else(|| {
            ProviderError::Protocol("Mozc key generation is exhausted".to_owned())
        })?;
        if response.generation != Some(expected_generation) {
            return Err(ProviderError::Protocol(
                "Mozc bridge returned a different key generation".to_owned(),
            ));
        }
        Ok(session_state_from_response(response, true))
    }

    pub async fn edit(
        &self,
        edit: &MozcEdit,
        generation: u64,
    ) -> Result<MozcSessionState, ProviderError> {
        let fields = edit.fields()?;
        let command = format!(
            "edit\t{}\t{}\t{}",
            self.session_id,
            generation,
            fields.join("\t")
        );
        let response = self.pool.call(command).await?;
        let expected_generation = generation.checked_add(1).ok_or_else(|| {
            ProviderError::Protocol("Mozc edit generation is exhausted".to_owned())
        })?;
        if response.generation != Some(expected_generation) {
            return Err(ProviderError::Protocol(
                "Mozc bridge returned a different edit generation".to_owned(),
            ));
        }
        Ok(session_state_from_response(response, true))
    }

    pub async fn convert(
        &self,
        request: &ConversionRequest,
    ) -> Result<ConversionResult, ProviderError> {
        validate_request(request)?;
        let response = self
            .pool
            .call(format!(
                "convert\t{}\t{}\t{}\t{}\t{}",
                self.session_id,
                encode(&request.romaji),
                encode(&request.context_before),
                encode(&request.context_after),
                request.revision
            ))
            .await?;
        if response.generation != Some(request.revision) {
            return Err(ProviderError::Protocol(
                "Mozc bridge returned a different conversion generation".to_owned(),
            ));
        }
        Ok(conversion_result_from_response(response, true))
    }

    pub async fn commit(
        &self,
        candidate_id: i32,
        generation: u64,
    ) -> Result<CommitResult, ProviderError> {
        let response = self
            .pool
            .call(format!(
                "commit\t{}\t{}\t{}",
                self.session_id, candidate_id, generation
            ))
            .await?;
        if response.generation != Some(generation) {
            return Err(ProviderError::Protocol(
                "Mozc bridge returned a different commit generation".to_owned(),
            ));
        }
        let text = response
            .text
            .or(response.result)
            .ok_or_else(|| ProviderError::Protocol("commit response has no text".to_owned()))?;
        Ok(CommitResult {
            text,
            elapsed_millis: response.elapsed_micros.unwrap_or_default() / 1_000,
        })
    }

    pub async fn cancel(&self, generation: Option<u64>) -> Result<(), ProviderError> {
        let command = generation.map_or_else(
            || format!("cancel\t{}", self.session_id),
            |generation| format!("cancel\t{}\t{}", self.session_id, generation),
        );
        let response = self.pool.call(command).await?;
        if response.session_id != Some(self.session_id)
            || generation.is_some_and(|expected| {
                expected
                    .checked_add(1)
                    .is_none_or(|next| response.generation != Some(next))
            })
        {
            return Err(ProviderError::Protocol(
                "Mozc bridge returned an uncorrelated cancel response".to_owned(),
            ));
        }
        Ok(())
    }
}

fn session_state_from_response(
    response: BridgeResponse,
    default_consumed: bool,
) -> MozcSessionState {
    let result = conversion_result_from_response(response, default_consumed);
    MozcSessionState {
        reading: result.reading,
        preedit: result.preedit,
        preedit_segments: result.preedit_segments,
        candidates: result.candidates,
        focused_index: result.focused_index,
        consumed: result.consumed,
        elapsed: result.elapsed,
    }
}

fn diagnostics_enabled() -> bool {
    env::var("KANAI_DIAGNOSTICS")
        .is_ok_and(|value| value == "1" || value.eq_ignore_ascii_case("true"))
}

fn bridge_environment_with<F>(lookup: F) -> Vec<(OsString, OsString)>
where
    F: Fn(&str) -> Option<OsString>,
{
    BRIDGE_ENV_KEYS
        .iter()
        .filter_map(|key| lookup(key).map(|value| ((*key).into(), value)))
        .collect()
}

fn bridge_environment() -> Vec<(OsString, OsString)> {
    bridge_environment_with(|key| env::var_os(key))
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
        if config.binary_path.as_os_str().is_empty() || !config.binary_path.is_file() {
            return Err(ProviderError::Unavailable(format!(
                "Mozc bridge not found at {}. Set KANAI_MOZC_BRIDGE or install kanai-mozc-bridge next to the API/CLI executable.",
                config.binary_path.display()
            )));
        }
        if config.profile_dir.as_os_str().is_empty() {
            return Err(ProviderError::Unavailable(
                "Mozc profile path must not be empty".to_owned(),
            ));
        }
        tokio::fs::create_dir_all(&config.profile_dir)
            .await
            .map_err(|error| ProviderError::Io(error.to_string()))?;
        secure_profile_permissions(&config.profile_dir)?;
        let mut command = Command::new(&config.binary_path);
        if config.binary_path.is_absolute()
            && let Some(directory) = parent_directory(&config.binary_path)
        {
            command.current_dir(directory);
        }
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
        for (key, value) in bridge_environment() {
            command.env(key, value);
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

    /// Stop and reap a detached child with a bounded grace period. The
    /// `kill_on_drop` setting remains a final safety net if the platform does
    /// not report termination before the deadline.
    async fn terminate(mut self) {
        match self.child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => {
                let _ = self.child.start_kill();
            }
            Err(_) => {
                let _ = self.child.start_kill();
            }
        }
        let _ = timeout(Duration::from_secs(1), self.child.wait()).await;
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
    generation: Option<u64>,
    #[serde(default, rename = "sessionId")]
    session_id: Option<u64>,
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

fn conversion_result_from_response(
    response: BridgeResponse,
    default_consumed: bool,
) -> ConversionResult {
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
    ConversionResult {
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
        consumed: response.consumed.unwrap_or(default_consumed),
        elapsed: Duration::from_micros(response.elapsed_micros.unwrap_or_default()),
    }
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
    if request.romaji.chars().any(char::is_control) {
        return Err(ProviderError::InvalidRequest(
            "conversion input contains control characters".to_owned(),
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

// This is deliberately a suffix/layout check, not a PE parser. The same
// discovery code is used by POSIX builds and by tests that only need to
// validate a Windows package path.
fn platform_executable_suffix() -> &'static str {
    if cfg!(windows) { ".exe" } else { "" }
}

fn parent_directory(path: &Path) -> Option<&Path> {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
}

fn bridge_file_names(suffix: &str) -> Vec<String> {
    let mut names = Vec::with_capacity(BRIDGE_BINARY_STEMS.len() * 2);
    if !suffix.is_empty() {
        names.extend(
            BRIDGE_BINARY_STEMS
                .iter()
                .map(|stem| format!("{stem}{suffix}")),
        );
    }
    names.extend(BRIDGE_BINARY_STEMS.iter().map(|stem| (*stem).to_owned()));
    names
}

fn add_bridge_candidates(candidates: &mut Vec<PathBuf>, directory: &Path, suffix: &str) {
    candidates.extend(
        bridge_file_names(suffix)
            .into_iter()
            .map(|name| directory.join(name)),
    );
}

fn executable_search_directories(executable: &Path) -> Vec<PathBuf> {
    let Some(executable_directory) = parent_directory(executable) else {
        return Vec::new();
    };
    let mut directories = Vec::new();
    let mut add = |directory: PathBuf| {
        if !directories.iter().any(|existing| existing == &directory) {
            directories.push(directory);
        }
    };

    add(executable_directory.to_path_buf());
    add(executable_directory.join("runtime"));
    add(executable_directory.join("bin"));
    if let Some(package_directory) = parent_directory(executable_directory) {
        add(package_directory.join("runtime"));
        add(package_directory.join("bin"));
        add(package_directory.to_path_buf());
    }
    directories
}

fn fallback_bridge_path(root: &Path, executable: Option<&Path>, suffix: &str) -> PathBuf {
    if let Some(directory) = executable.and_then(parent_directory) {
        let name = bridge_file_names(suffix)
            .into_iter()
            .next()
            .unwrap_or_else(|| BRIDGE_BINARY_STEMS[0].to_owned());
        return directory.join(name);
    }

    let name = if suffix.is_empty() {
        BRIDGE_BINARY_STEMS[1].to_owned()
    } else {
        format!("{}{suffix}", BRIDGE_BINARY_STEMS[1])
    };
    root.join("third_party/mozc/src/bazel-bin/kanai").join(name)
}

fn find_bridge_binary_with_suffix(root: &Path, executable: Option<&Path>, suffix: &str) -> PathBuf {
    let mut candidates = Vec::new();
    if let Some(executable) = executable {
        for directory in executable_search_directories(executable) {
            add_bridge_candidates(&mut candidates, &directory, suffix);
        }
    }
    for directory in [
        root.join("bin"),
        root.join("runtime"),
        root.join("third_party/mozc/src/bazel-bin/kanai"),
        root.join("third_party/mozc/src/bazel-bin/src/kanai"),
        root.join("third_party/mozc/bazel-bin/src/kanai"),
        root.join("target/debug"),
        root.join("target/release"),
        root.join("target/x86_64-pc-windows-msvc/debug"),
        root.join("target/x86_64-pc-windows-msvc/release"),
    ] {
        add_bridge_candidates(&mut candidates, &directory, suffix);
    }
    candidates
        .into_iter()
        .find(|path| path.is_file())
        .unwrap_or_else(|| fallback_bridge_path(root, executable, suffix))
}

fn find_bridge_binary_with_executable(root: &Path, executable: Option<&Path>) -> PathBuf {
    find_bridge_binary_with_suffix(root, executable, platform_executable_suffix())
}

fn find_bridge_binary(root: &Path) -> PathBuf {
    let executable = env::current_exe().ok();
    find_bridge_binary_with_executable(root, executable.as_deref())
}

#[cfg(test)]
mod tests {
    use std::ffi::{OsStr, OsString};
    use std::fs;
    use std::path::Path;
    use std::time::Duration;

    use kanai_core::{ConversionProvider, ConversionRequest, ProviderError};

    use crate::{
        MozcBridge, MozcEdit, MozcKey, bridge_environment_with, configured_bridge_path, decode,
        encode, find_bridge_binary_with_suffix, validate_request,
    };

    fn write_placeholder(path: &Path) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create test directory");
        }
        // Deliberately not a PE header: path discovery is platform-neutral and
        // the package verifier, rather than this adapter, validates PE bytes.
        fs::write(path, b"placeholder bridge").expect("write test bridge");
    }

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

    #[test]
    fn multiplexed_key_and_edit_fields_are_separator_safe() {
        assert_eq!(
            MozcKey::Character("あ b".to_owned())
                .fields()
                .expect("key fields"),
            vec!["character".to_owned(), "%E3%81%82%20b".to_owned()]
        );
        assert_eq!(
            MozcEdit::Replace {
                start: 1,
                end: 2,
                text: "界".to_owned(),
            }
            .fields()
            .expect("edit fields"),
            vec![
                "replace".to_owned(),
                "1".to_owned(),
                "2".to_owned(),
                "%E7%95%8C".to_owned(),
            ]
        );
        assert!(
            MozcKey::Character("bad\nvalue".to_owned())
                .fields()
                .is_err()
        );
    }

    #[test]
    fn bridge_discovery_handles_packaged_windows_names_and_runtime_directory() {
        let package = tempfile::tempdir().expect("temporary package directory");
        let bin = package.path().join("bin");
        let runtime = package.path().join("runtime");
        let executable = bin.join("kanai.exe");
        let package_bridge = bin.join("kanai-mozc-bridge.exe");
        let runtime_bridge = runtime.join("kanai_mozc_bridge.exe");
        fs::create_dir_all(&bin).expect("create bin directory");
        write_placeholder(&package_bridge);

        assert_eq!(
            find_bridge_binary_with_suffix(package.path(), Some(&executable), ".exe"),
            package_bridge
        );

        fs::remove_file(&package_bridge).expect("remove sibling bridge");
        write_placeholder(&runtime_bridge);
        assert_eq!(
            find_bridge_binary_with_suffix(package.path(), Some(&executable), ".exe"),
            runtime_bridge
        );
    }

    #[test]
    fn explicit_bridge_configuration_is_honored_without_resolving_pe_bytes() {
        let package = tempfile::tempdir().expect("temporary package directory");
        let bin = package.path().join("bin");
        let executable = bin.join("kanai.exe");
        let configured = bin.join("custom-bridge.exe");
        fs::create_dir_all(&bin).expect("create bin directory");
        write_placeholder(&configured);

        let selected = configured_bridge_path(
            |key| (key == "KANAI_MOZC_BRIDGE").then(|| OsString::from("custom-bridge.exe")),
            Some(&executable),
        );
        assert_eq!(selected, Some(configured));

        let runtime_configured = package.path().join("runtime/configured-bridge.exe");
        write_placeholder(&runtime_configured);
        let selected = configured_bridge_path(
            |key| {
                (key == "KANAI_MOZC_BRIDGE")
                    .then(|| OsString::from("runtime/configured-bridge.exe"))
            },
            Some(&executable),
        );
        assert_eq!(selected, Some(runtime_configured));

        assert!(
            configured_bridge_path(
                |key| (key == "KANAI_MOZC_BRIDGE").then(OsString::new),
                Some(&executable),
            )
            .is_none()
        );
    }

    #[test]
    fn bridge_child_environment_excludes_ai_and_mozc_configuration() {
        let environment = bridge_environment_with(|key| match key {
            "PATH" => Some(OsString::from("/test/bin")),
            "KANA_AI_API_KEY" => Some(OsString::from("do-not-forward")),
            "KANA_AI_BASE_URL" => Some(OsString::from("do-not-forward")),
            "KANA_AI_MODEL" => Some(OsString::from("do-not-forward")),
            "KANA_AI_ALLOW_REMOTE" => Some(OsString::from("do-not-forward")),
            "KANAI_MOZC_BRIDGE" => Some(OsString::from("do-not-forward")),
            "KANAI_MOZC_PROFILE" => Some(OsString::from("do-not-forward")),
            _ => None,
        });

        assert!(
            environment.iter().any(|(key, value)| {
                key == "PATH" && value.as_os_str() == OsStr::new("/test/bin")
            })
        );
        assert!(environment.iter().all(|(key, value)| {
            key != "KANA_AI_API_KEY"
                && key != "KANA_AI_BASE_URL"
                && key != "KANA_AI_MODEL"
                && key != "KANA_AI_ALLOW_REMOTE"
                && key != "KANAI_MOZC_BRIDGE"
                && key != "KANAI_MOZC_PROFILE"
                && !value.to_string_lossy().contains("do-not-forward")
        }));
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

        // The bridge accepts valid UTF-8 composition text as well as ASCII
        // romaji; only control characters are rejected here.
        request.romaji = "日本語".to_owned();
        assert!(validate_request(&request).is_ok());

        request.romaji = "kyou\n".to_owned();
        assert_invalid_request(&request, "control characters");

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
