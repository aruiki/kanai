//! Session-aware adapter for the bounded KanaAI Mozc bridge.
//!
//! One bridge process now owns explicit upstream sessions. The Rust session
//! owner still serializes each broker context independently, while the bridge
//! process serializes the pinned synchronous Mozc `SessionHandler` calls. The
//! optional model queue is never called from these state operations.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use kanai_core::{ConversionRequest, ProviderError};
use kanai_mozc::{MozcBridgeConfig, MozcBridgePool, MozcEdit, MozcKey, MozcSessionClient};
use tokio::sync::Mutex;

use crate::{
    BackendError, BackendHealth, BrokerRequest, BrokerResponse, CancellationToken, Candidate,
    CommitRequest, CommitResponse, ConvertRequest, ConvertResponse, CreateSessionRequest,
    EditAction, EditRequest, EditResponse, FallbackMode, FocusLostRequest, FocusLostResponse,
    HealthResponse, HealthStatus, KeyEvent, KeyRequest, KeyResponse, RequestCommand,
    ResponsePayload, SessionBackend,
};

struct LocalSession {
    /// Mozc's rendered preedit is the canonical composition coordinate space.
    /// Host edit ranges are interpreted against this value, not against raw
    /// ASCII/romaji input, so the Rust owner and C++ bridge cannot drift.
    composition: String,
    candidates: HashMap<u64, i32>,
    active_generation: Option<u64>,
}

struct MozcSession {
    client: MozcSessionClient,
    bridge_epoch: u64,
    local: Mutex<LocalSession>,
}

impl MozcSession {
    fn new(client: MozcSessionClient, bridge_epoch: u64) -> Self {
        Self {
            client,
            bridge_epoch,
            local: Mutex::new(LocalSession {
                composition: String::new(),
                candidates: HashMap::new(),
                active_generation: None,
            }),
        }
    }
}

/// A real Mozc-backed session owner.
///
/// The broker keeps its existing session/generation DTOs, while one bounded
/// bridge process owns the independent upstream sessions. The C++ protocol is
/// incognito and never persists learning, so sharing the process does not
/// share user history between native input contexts.
#[derive(Clone)]
pub struct MozcSessionBackend {
    config: MozcBridgeConfig,
    pool: Arc<MozcBridgePool>,
    sessions: Arc<Mutex<HashMap<u64, Arc<MozcSession>>>>,
}

impl std::fmt::Debug for MozcSessionBackend {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MozcSessionBackend")
            .field("binary_path", &self.config.binary_path)
            .field("profile_dir", &self.config.profile_dir)
            .finish()
    }
}

impl MozcSessionBackend {
    #[must_use]
    pub fn new(config: MozcBridgeConfig) -> Self {
        Self {
            pool: Arc::new(MozcBridgePool::new(config.clone())),
            config,
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    #[must_use]
    pub fn from_environment() -> Self {
        Self::new(MozcBridgeConfig::from_environment())
    }

    /// Return the shared bridge child PID after the pool has been started.
    pub async fn process_id(&self) -> Option<u32> {
        self.pool.process_id().await
    }

    /// Return the current child epoch for recovery tests/diagnostics.
    #[must_use]
    pub fn bridge_epoch(&self) -> u64 {
        self.pool.epoch()
    }

    /// Explicitly start a fresh child after all old sessions were invalidated.
    pub async fn restart_bridge(&self) -> Result<(), BackendError> {
        self.pool.restart().await.map_err(provider_error)
    }

    async fn session(&self, session_id: u64) -> Result<Arc<MozcSession>, BackendError> {
        if self.pool.failed() {
            self.sessions.lock().await.clear();
            return Err(BackendError::SessionInvalidated);
        }
        let session = self
            .sessions
            .lock()
            .await
            .get(&session_id)
            .cloned()
            .ok_or_else(|| BackendError::Protocol("unknown Mozc session".to_owned()))?;
        if session.bridge_epoch != self.pool.epoch() {
            self.sessions.lock().await.clear();
            return Err(BackendError::SessionInvalidated);
        }
        Ok(session)
    }

    async fn classify_client_error(&self, epoch: u64, error: ProviderError) -> BackendError {
        let transport_failure = matches!(
            error,
            ProviderError::Unavailable(_) | ProviderError::Io(_) | ProviderError::Timeout(_)
        );
        if transport_failure && (self.pool.failed() || self.pool.epoch() != epoch) {
            self.sessions.lock().await.clear();
            BackendError::SessionInvalidated
        } else {
            provider_error(error)
        }
    }

    async fn client_result<T>(
        &self,
        epoch: u64,
        result: Result<T, ProviderError>,
    ) -> Result<T, BackendError> {
        match result {
            Ok(value) => Ok(value),
            Err(error) => Err(self.classify_client_error(epoch, error).await),
        }
    }
}

#[async_trait]
impl SessionBackend for MozcSessionBackend {
    async fn execute(
        &self,
        request: &BrokerRequest,
        cancellation: &CancellationToken,
    ) -> Result<BrokerResponse, BackendError> {
        if cancellation.is_cancelled() {
            return Err(BackendError::Cancelled);
        }
        let result = match request {
            RequestCommand::CreateSession(command) => self.create_session(command).await,
            RequestCommand::PrepareRerankSession(_) => Err(BackendError::Protocol(
                "rerank-only session must be handled by the async broker owner".to_owned(),
            )),
            RequestCommand::Key(command) => self.key(command).await,
            RequestCommand::Edit(command) => self.edit(command).await,
            RequestCommand::Convert(command) => self.convert(command).await,
            RequestCommand::Commit(command) => self.commit(command).await,
            RequestCommand::Cancel(command) => self.cancel(command).await,
            RequestCommand::FocusLost(command) => self.focus_lost(command).await,
            RequestCommand::Health(_) => Ok(ResponsePayload::Health(self.health().await)),
            RequestCommand::Generation(command) => {
                Ok(ResponsePayload::Generation(crate::GenerationResponse {
                    session_id: command.session_id,
                    generation: 0,
                }))
            }
            RequestCommand::RerankCandidates(_) | RequestCommand::SemanticAssist(_) => {
                Err(BackendError::Protocol(
                    "optional enhancement must not reach the Mozc backend".to_owned(),
                ))
            }
        };
        if cancellation.is_cancelled() {
            Err(BackendError::Cancelled)
        } else {
            result
        }
    }

    async fn health(&self) -> BackendHealth {
        let health = self.pool.health().await;
        HealthResponse {
            status: if health.available {
                HealthStatus::Ready
            } else {
                HealthStatus::Unavailable
            },
            protocol_version: crate::PROTOCOL_VERSION,
            max_frame_bytes: crate::frame::DEFAULT_MAX_FRAME_BYTES as u32,
            fallback: if health.available {
                FallbackMode::None
            } else {
                FallbackMode::LastValidPreedit
            },
            detail: if health.detail.len() > 512 {
                "Mozc session is unavailable".to_owned()
            } else {
                health.detail
            },
        }
    }
}

impl MozcSessionBackend {
    async fn create_session(
        &self,
        command: &CreateSessionRequest,
    ) -> Result<BrokerResponse, BackendError> {
        if self.sessions.lock().await.contains_key(&command.session_id) {
            return Err(BackendError::Protocol(
                "Mozc session already exists".to_owned(),
            ));
        }
        if self.pool.failed() {
            self.pool.restart().await.map_err(provider_error)?;
        }
        let client = MozcSessionClient::new((*self.pool).clone(), command.session_id);
        let epoch = self.pool.epoch();
        if let Err(error) = client.open().await {
            return Err(self.classify_client_error(epoch, error).await);
        }
        let session = Arc::new(MozcSession::new(client.clone(), epoch));
        let mut sessions = self.sessions.lock().await;
        if sessions.contains_key(&command.session_id) {
            // A concurrent creator won the race. Close the extra upstream
            // session instead of leaving an unreachable owner behind.
            drop(sessions);
            let _ = client.close().await;
            return Err(BackendError::Protocol(
                "Mozc session already exists".to_owned(),
            ));
        }
        sessions.insert(command.session_id, session);
        Ok(ResponsePayload::Created(crate::SessionCreated {
            session_id: command.session_id,
            generation: 0,
            fallback: FallbackMode::None,
        }))
    }

    async fn key(&self, command: &KeyRequest) -> Result<BrokerResponse, BackendError> {
        let session = self.session(command.session_id).await?;
        let state = self
            .client_result(
                session.bridge_epoch,
                session
                    .client
                    .key(&mozc_key(&command.key), command.generation)
                    .await,
            )
            .await?;
        let mut local = session.local.lock().await;
        // The bridge's rendered preedit is authoritative.  Keeping a second
        // raw romaji string made host edit ranges disagree with the C++
        // SessionHandler as soon as kana conversion occurred.
        local.composition = state.preedit;
        local.candidates.clear();
        local.active_generation = None;
        Ok(ResponsePayload::Key(KeyResponse {
            session_id: command.session_id,
            generation: command.generation,
            preedit: local.composition.clone(),
            consumed: state.consumed,
            candidates: Vec::new(),
            focused_index: None,
            fallback: FallbackMode::None,
        }))
    }

    async fn edit(&self, command: &EditRequest) -> Result<BrokerResponse, BackendError> {
        let session = self.session(command.session_id).await?;
        // Validate the host range against the same rendered preedit that the
        // bridge uses before sending the command.  This rejects impossible
        // ranges locally and keeps the two composition owners aligned.
        let mut expected = session.local.lock().await.composition.clone();
        apply_edit(&mut expected, &command.action)?;
        let state = self
            .client_result(
                session.bridge_epoch,
                session
                    .client
                    .edit(&mozc_edit(&command.action), command.generation)
                    .await,
            )
            .await?;
        if state.preedit != expected {
            return Err(BackendError::Protocol(
                "Mozc edit response changed the composition unexpectedly".to_owned(),
            ));
        }
        let mut local = session.local.lock().await;
        local.composition = state.preedit;
        local.candidates.clear();
        local.active_generation = None;
        Ok(ResponsePayload::Edit(EditResponse {
            session_id: command.session_id,
            generation: command.generation,
            preedit: local.composition.clone(),
            consumed: state.consumed,
            candidates: Vec::new(),
            focused_index: None,
            fallback: FallbackMode::None,
        }))
    }

    async fn convert(&self, command: &ConvertRequest) -> Result<BrokerResponse, BackendError> {
        let session = self.session(command.session_id).await?;
        let composition = session.local.lock().await.composition.clone();
        if composition.is_empty() {
            return Ok(ResponsePayload::Convert(ConvertResponse {
                session_id: command.session_id,
                generation: command.generation,
                preedit: String::new(),
                consumed: true,
                candidates: Vec::new(),
                focused_index: None,
                page: command.page,
                page_size: command.page_size,
                has_more: false,
                fallback: FallbackMode::None,
            }));
        }
        let mut request = ConversionRequest::new(composition);
        request.revision = command.generation;
        request.limit = 30;
        let result = match self
            .client_result(session.bridge_epoch, session.client.convert(&request).await)
            .await
        {
            Ok(result) => result,
            Err(error) => {
                if std::env::var("KANAI_DIAGNOSTICS")
                    .is_ok_and(|value| value == "1" || value.eq_ignore_ascii_case("true"))
                {
                    eprintln!("Mozc session conversion failed: {error}");
                }
                return Err(error);
            }
        };
        let mut candidates = Vec::with_capacity(result.candidates.len());
        let mut original_ids = HashMap::new();
        for (index, candidate) in result.candidates.iter().enumerate() {
            // Mozc's internal candidate id is an i32 index and may be zero or
            // negative for special candidates.  The broker protocol requires
            // stable, positive request-scoped IDs, so remap the page while
            // retaining the original id for the generation-checked commit.
            let id = u64::try_from(index + 1).map_err(|_| {
                BackendError::Protocol("Mozc candidate page is too large".to_owned())
            })?;
            original_ids.insert(id, candidate.id);
            candidates.push(Candidate {
                id,
                text: candidate.text.clone(),
                reading: candidate.reading.clone(),
                rank: u16::try_from(candidate.provider_rank.max(index)).unwrap_or(u16::MAX),
            });
        }
        let start = usize::min(
            candidates.len(),
            (command.page as usize).saturating_mul(command.page_size as usize),
        );
        let end = usize::min(candidates.len(), start + command.page_size as usize);
        let page_candidates = candidates[start..end].to_vec();
        let focused_index = result
            .focused_index
            .filter(|index| *index < candidates.len())
            .map(|index| {
                if index >= start && index < end {
                    index - start
                } else {
                    0
                }
            });
        {
            let mut local = session.local.lock().await;
            local.composition = result.preedit.clone();
            local.candidates = original_ids;
            local.active_generation = Some(command.generation);
        }
        Ok(ResponsePayload::Convert(ConvertResponse {
            session_id: command.session_id,
            generation: command.generation,
            preedit: result.preedit,
            consumed: result.consumed,
            candidates: page_candidates,
            focused_index,
            page: command.page,
            page_size: command.page_size,
            has_more: end < candidates.len(),
            fallback: FallbackMode::None,
        }))
    }

    async fn commit(&self, command: &CommitRequest) -> Result<BrokerResponse, BackendError> {
        let session = self.session(command.session_id).await?;
        let original_id = {
            let local = session.local.lock().await;
            if local.active_generation != Some(command.generation) {
                return Err(BackendError::Protocol(
                    "candidate does not belong to the active Mozc generation".to_owned(),
                ));
            }
            local
                .candidates
                .get(&command.candidate_id)
                .copied()
                .ok_or_else(|| {
                    BackendError::Protocol("candidate is not in this Mozc session".to_owned())
                })?
        };
        let result = self
            .client_result(
                session.bridge_epoch,
                session.client.commit(original_id, command.generation).await,
            )
            .await?;
        let mut local = session.local.lock().await;
        local.composition.clear();
        local.candidates.clear();
        local.active_generation = None;
        Ok(ResponsePayload::Commit(CommitResponse {
            session_id: command.session_id,
            generation: command.generation,
            text: result.text,
            consumed: true,
        }))
    }

    async fn cancel(&self, command: &crate::CancelRequest) -> Result<BrokerResponse, BackendError> {
        let session = self.session(command.session_id).await?;
        let generation = command.generation.unwrap_or_default();
        self.client_result(
            session.bridge_epoch,
            session.client.cancel(command.generation).await,
        )
        .await?;
        let mut local = session.local.lock().await;
        local.composition.clear();
        local.candidates.clear();
        local.active_generation = None;
        Ok(ResponsePayload::Cancel(crate::CancelResponse {
            session_id: command.session_id,
            generation,
            target_request_id: command.target_request_id,
        }))
    }

    async fn focus_lost(&self, command: &FocusLostRequest) -> Result<BrokerResponse, BackendError> {
        let session = self.session(command.session_id).await?;
        self.client_result(
            session.bridge_epoch,
            session.client.close_at(Some(command.generation)).await,
        )
        .await?;
        let mut local = session.local.lock().await;
        local.composition.clear();
        local.candidates.clear();
        local.active_generation = None;
        self.sessions.lock().await.remove(&command.session_id);
        Ok(ResponsePayload::FocusLost(FocusLostResponse {
            session_id: command.session_id,
            generation: command.generation,
        }))
    }
}

fn append_bounded(input: &mut String, value: &str) -> Result<(), BackendError> {
    if input.len().saturating_add(value.len()) > 1024 {
        return Err(BackendError::Protocol(
            "Mozc composition exceeds the adapter bound".to_owned(),
        ));
    }
    input.push_str(value);
    Ok(())
}

fn apply_edit(input: &mut String, action: &EditAction) -> Result<(), BackendError> {
    match action {
        EditAction::Insert { text } => append_bounded(input, text)?,
        EditAction::Replace { range, text } => {
            let start = scalar_index(input, range.start)?;
            let end = scalar_index(input, range.end)?;
            if start > end {
                return Err(BackendError::Protocol("edit range is reversed".to_owned()));
            }
            if input
                .len()
                .saturating_sub(end - start)
                .saturating_add(text.len())
                > 1024
            {
                return Err(BackendError::Protocol(
                    "Mozc composition exceeds the adapter bound".to_owned(),
                ));
            }
            input.replace_range(start..end, text);
        }
        EditAction::Delete { range } => {
            let start = scalar_index(input, range.start)?;
            let end = scalar_index(input, range.end)?;
            if start > end {
                return Err(BackendError::Protocol("edit range is reversed".to_owned()));
            }
            input.replace_range(start..end, "");
        }
        EditAction::Reset => input.clear(),
    }
    Ok(())
}

fn scalar_index(text: &str, index: u32) -> Result<usize, BackendError> {
    let index = usize::try_from(index)
        .map_err(|_| BackendError::Protocol("edit range is too large".to_owned()))?;
    text.char_indices()
        .nth(index)
        .map(|(offset, _)| offset)
        .or_else(|| (index == text.chars().count()).then_some(text.len()))
        .ok_or_else(|| BackendError::Protocol("edit range is outside composition".to_owned()))
}

fn mozc_key(key: &KeyEvent) -> MozcKey {
    match key {
        KeyEvent::Character { value } => MozcKey::Character(value.clone()),
        KeyEvent::Space => MozcKey::Space,
        KeyEvent::Backspace => MozcKey::Backspace,
        KeyEvent::Delete => MozcKey::Delete,
        KeyEvent::Escape => MozcKey::Escape,
        KeyEvent::Tab => MozcKey::Tab,
        KeyEvent::Enter => MozcKey::Enter,
        KeyEvent::Left => MozcKey::Left,
        KeyEvent::Right => MozcKey::Right,
        KeyEvent::Up => MozcKey::Up,
        KeyEvent::Down => MozcKey::Down,
        KeyEvent::Function { number } => MozcKey::Function(*number),
        KeyEvent::Named { name } => MozcKey::Named(name.clone()),
    }
}

fn mozc_edit(action: &EditAction) -> MozcEdit {
    match action {
        EditAction::Insert { text } => MozcEdit::Insert(text.clone()),
        EditAction::Replace { range, text } => MozcEdit::Replace {
            start: range.start,
            end: range.end,
            text: text.clone(),
        },
        EditAction::Delete { range } => MozcEdit::Delete {
            start: range.start,
            end: range.end,
        },
        EditAction::Reset => MozcEdit::Reset,
    }
}

fn provider_error(error: ProviderError) -> BackendError {
    match error {
        ProviderError::Unavailable(message) => BackendError::Unavailable(message),
        ProviderError::InvalidRequest(message) => BackendError::Rejected(message),
        ProviderError::UnknownCandidate(id) => {
            BackendError::Protocol(format!("unknown Mozc candidate {id}"))
        }
        ProviderError::Io(message) => BackendError::Unavailable(message),
        ProviderError::Timeout(_) => BackendError::Timeout,
        ProviderError::Protocol(message) => BackendError::Protocol(message),
    }
}

#[cfg(test)]
mod tests {
    use super::{EditAction, apply_edit};
    use crate::TextRange;

    #[test]
    fn edit_ranges_are_measured_in_rendered_unicode_scalars() {
        let mut composition = "きょう".to_owned();
        apply_edit(
            &mut composition,
            &EditAction::Replace {
                range: TextRange { start: 1, end: 2 },
                text: "よ".to_owned(),
            },
        )
        .expect("valid rendered composition range");
        assert_eq!(composition, "きよう");
    }

    #[test]
    fn edit_rejects_ranges_outside_the_rendered_composition() {
        let mut composition = "きょう".to_owned();
        let result = apply_edit(
            &mut composition,
            &EditAction::Delete {
                range: TextRange { start: 0, end: 9 },
            },
        );
        assert!(result.is_err());
        assert_eq!(composition, "きょう");
    }
}
