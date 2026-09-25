//! End-to-end candidate pipeline contracts.
//!
//! This module is intentionally an orchestration layer above Mozc.  The
//! provider owns composition and candidate generation; this module extracts a
//! bounded candidate set, captures a small context window, applies the fast
//! deterministic policy, and exposes a separate slow semantic-rerank seam.
//! No method in the fast path performs model or network I/O.

use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::time::timeout;

use crate::{
    CandidateAdjustments, ConversionCandidate, ConversionProvider, ConversionRequest,
    ConversionResult, FastRankOutcome, LearningState, LocalDataPolicy, LocalQualityConfig,
    LocalQualityEngine, LocalQualityRequest, MAX_LOCAL_QUALITY_CANDIDATES,
    MAX_LOCAL_QUALITY_CONTEXT_CHARS, ModelTier, PersonalizedCandidate, ProviderError,
    RerankRejection, SemanticProviderError, SemanticRerankAdmission, SemanticRerankDecision,
    SemanticRerankReason, SemanticRerankResolution, SemanticRerankSnapshot,
};

/// Maximum number of provider candidates retained by the orchestration layer.
pub const MAX_PIPELINE_CANDIDATES: usize = 30;
/// Default deadline for the explicitly scheduled slow semantic path.
pub const DEFAULT_PIPELINE_SEMANTIC_DEADLINE: Duration = Duration::from_millis(250);
/// Hard deadline accepted by the orchestration layer.
pub const MAX_PIPELINE_SEMANTIC_DEADLINE: Duration = Duration::from_secs(2);

const MAX_READING_CHARS: usize = 64;
const MAX_CANDIDATE_TEXT_CHARS: usize = 96;
const MAX_CANDIDATE_READING_CHARS: usize = 64;
const MAX_SEMANTIC_CANDIDATES: usize = MAX_LOCAL_QUALITY_CANDIDATES;

/// Correlation and policy facts captured for one candidate generation.
///
/// `current_generation` is owned by the session owner, not by a model.  A slow
/// result is useful only while it still matches this snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PipelineSession {
    pub session_id: u64,
    pub generation: u64,
    pub current_generation: Option<u64>,
    pub tier: ModelTier,
    pub model_revision: u64,
    pub learning_version: u64,
}

impl PipelineSession {
    #[must_use]
    pub const fn new(session_id: u64, generation: u64, tier: ModelTier) -> Self {
        Self {
            session_id,
            generation,
            current_generation: Some(generation),
            tier,
            model_revision: 0,
            learning_version: 0,
        }
    }

    #[must_use]
    pub const fn with_revisions(mut self, model_revision: u64, learning_version: u64) -> Self {
        self.model_revision = model_revision;
        self.learning_version = learning_version;
        self
    }

    #[must_use]
    pub const fn is_current(self) -> bool {
        matches!(self.current_generation, Some(current) if current == self.generation)
    }
}

/// A bounded, normalized context window extracted from a conversion request.
///
/// The strings contain at most `max_context_chars` Unicode scalar values in
/// total.  Control characters are removed and runs of whitespace collapse to
/// one ASCII space.  The type is safe to hand to a local provider; it never
/// retains the original request strings.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractedContext {
    before: String,
    after: String,
}

impl ExtractedContext {
    #[must_use]
    pub fn from_request(request: &ConversionRequest, max_context_chars: usize) -> Self {
        let limit = max_context_chars.min(MAX_LOCAL_QUALITY_CONTEXT_CHARS);
        if limit == 0 {
            return Self::default();
        }
        let before = normalized_tail(&request.context_before, limit);
        let remaining = limit.saturating_sub(before.chars().count());
        let after = normalized_head(&request.context_after, remaining);
        Self { before, after }
    }

    #[must_use]
    pub fn before(&self) -> &str {
        &self.before
    }

    #[must_use]
    pub fn after(&self) -> &str {
        &self.after
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.before.chars().count() + self.after.chars().count()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn chars(&self) -> impl Iterator<Item = char> + '_ {
        self.before.chars().chain(self.after.chars())
    }
}

fn normalized_tail(value: &str, limit: usize) -> String {
    if limit == 0 {
        return String::new();
    }
    let scan_limit = limit.saturating_mul(4).max(limit);
    let mut reversed = Vec::with_capacity(limit);
    let mut pending_space = false;
    for character in value.chars().rev().take(scan_limit) {
        if character.is_control() || character.is_whitespace() {
            if !reversed.is_empty() {
                pending_space = true;
            }
            continue;
        }
        if pending_space && !reversed.is_empty() {
            if reversed.len() == limit {
                break;
            }
            reversed.push(' ');
            pending_space = false;
        }
        if reversed.len() == limit {
            break;
        }
        reversed.push(character);
    }
    reversed.reverse();
    reversed.into_iter().collect()
}

fn normalized_head(value: &str, limit: usize) -> String {
    if limit == 0 {
        return String::new();
    }
    let scan_limit = limit.saturating_mul(4).max(limit);
    let mut result = String::with_capacity(limit);
    let mut pending_space = false;
    for character in value.chars().take(scan_limit) {
        if character.is_control() || character.is_whitespace() {
            if !result.is_empty() {
                pending_space = true;
            }
            continue;
        }
        if pending_space {
            if result.chars().count() == limit {
                break;
            }
            result.push(' ');
            pending_space = false;
        }
        if result.chars().count() == limit {
            break;
        }
        result.push(character);
    }
    result
}

/// Candidate data admitted to the optional local semantic provider.
///
/// Provider implementations receive only the bounded reading, bounded context,
/// and candidate ID/text/reading.  Mozc descriptions, logs, attributes, and
/// user profile data are intentionally absent from this DTO.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticCandidate {
    pub id: i32,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reading: Option<String>,
}

/// Immutable input passed from the slow path to a local model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticRerankInput {
    pub session_id: u64,
    pub generation: u64,
    pub tier: ModelTier,
    pub model_revision: u64,
    pub learning_version: u64,
    pub input_revision: u64,
    pub reading: String,
    pub context_before: String,
    pub context_after: String,
    pub candidates: Vec<SemanticCandidate>,
}

impl SemanticRerankInput {
    fn validate(&self) -> Result<(), RerankRejection> {
        if self.session_id == 0 {
            return Err(RerankRejection::InvalidInput);
        }
        if !valid_text(&self.reading, MAX_READING_CHARS) {
            return Err(RerankRejection::InvalidInput);
        }
        if !valid_optional_text(&self.context_before, MAX_LOCAL_QUALITY_CONTEXT_CHARS)
            || !valid_optional_text(&self.context_after, MAX_LOCAL_QUALITY_CONTEXT_CHARS)
            || self.context_before.chars().count() + self.context_after.chars().count()
                > MAX_LOCAL_QUALITY_CONTEXT_CHARS
        {
            return Err(RerankRejection::InvalidInput);
        }
        if self.candidates.len() < 2 || self.candidates.len() > MAX_SEMANTIC_CANDIDATES {
            return Err(RerankRejection::InsufficientCandidates);
        }
        for (index, candidate) in self.candidates.iter().enumerate() {
            if !valid_text(&candidate.text, MAX_CANDIDATE_TEXT_CHARS)
                || !valid_optional_text(
                    candidate.reading.as_deref().unwrap_or_default(),
                    MAX_CANDIDATE_READING_CHARS,
                )
            {
                return Err(RerankRejection::InvalidInput);
            }
            if self.candidates[..index]
                .iter()
                .any(|previous| previous.id == candidate.id)
            {
                return Err(RerankRejection::DuplicateInputCandidate);
            }
        }
        Ok(())
    }
}

/// A provider-neutral asynchronous semantic reranking seam.
///
/// Implementations may call a local model, but the pipeline invokes this trait
/// only from [`CandidatePipeline::apply_semantic_rerank`], which is explicitly
/// separate from the fast conversion path and bounded by a timeout.
#[async_trait]
pub trait SemanticRerankProvider: Send + Sync {
    async fn rerank(
        &self,
        input: SemanticRerankInput,
    ) -> Result<SemanticRerankDecision, SemanticProviderError>;
}

/// A semantic request ticket tied to the exact fast-path candidate snapshot.
#[derive(Debug, Clone)]
pub struct SemanticRerankTicket {
    snapshot: SemanticRerankSnapshot,
    input: SemanticRerankInput,
}

impl SemanticRerankTicket {
    #[must_use]
    pub const fn snapshot(&self) -> SemanticRerankSnapshot {
        self.snapshot
    }

    #[must_use]
    pub const fn input(&self) -> &SemanticRerankInput {
        &self.input
    }

    #[must_use]
    pub fn into_input(self) -> SemanticRerankInput {
        self.input
    }
}

/// Semantic result plus non-content decision metadata for diagnostics.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SemanticRerankReport {
    pub resolution: SemanticRerankResolution,
    pub confidence: Option<f64>,
    pub reason: Option<SemanticRerankReason>,
}

impl SemanticRerankReport {
    fn from_resolution(resolution: SemanticRerankResolution) -> Self {
        Self {
            resolution,
            confidence: None,
            reason: None,
        }
    }
}

/// Result of Mozc generation plus the fast local candidate stage.
#[derive(Debug, Clone)]
pub struct FastConversionOutput {
    /// The unmodified provider result, retained for diagnostics and fallback.
    pub result: ConversionResult,
    /// Personalized candidates before the bounded fast ranker.
    pub baseline_candidates: Vec<PersonalizedCandidate>,
    /// Candidates currently safe to display after the fast ranker.
    pub candidates: Vec<PersonalizedCandidate>,
    pub focused_index: Option<usize>,
    pub context: ExtractedContext,
    pub fast_rank: FastRankOutcome,
    pub session: PipelineSession,
}

impl FastConversionOutput {
    #[must_use]
    pub fn candidate_ids(&self) -> Vec<i32> {
        self.candidates
            .iter()
            .map(|candidate| candidate.candidate.id)
            .collect()
    }

    #[must_use]
    pub fn baseline_ids(&self) -> Vec<i32> {
        self.baseline_candidates
            .iter()
            .map(|candidate| candidate.candidate.id)
            .collect()
    }
}

/// Orchestrates the actual candidate vertical slice while keeping Mozc as the
/// conversion owner.
#[derive(Debug)]
pub struct CandidatePipeline {
    quality: LocalQualityEngine,
    semantic_deadline: Duration,
}

impl Default for CandidatePipeline {
    fn default() -> Self {
        Self::new(LocalQualityConfig::new(LocalDataPolicy::CandidateFeatures))
    }
}

impl CandidatePipeline {
    #[must_use]
    pub fn new(config: LocalQualityConfig) -> Self {
        Self {
            quality: LocalQualityEngine::new(config),
            semantic_deadline: DEFAULT_PIPELINE_SEMANTIC_DEADLINE,
        }
    }

    #[must_use]
    pub fn mozc_only() -> Self {
        Self::new(LocalQualityConfig::new(LocalDataPolicy::MozcBaseline))
    }

    #[must_use]
    pub fn with_semantic_deadline(mut self, deadline: Duration) -> Self {
        self.semantic_deadline = deadline.min(MAX_PIPELINE_SEMANTIC_DEADLINE);
        self
    }

    #[must_use]
    pub const fn config(&self) -> LocalQualityConfig {
        self.quality.config()
    }

    #[must_use]
    pub fn cache_entries(&self) -> usize {
        self.quality.cache_entries()
    }

    pub fn clear_cache(&mut self) {
        self.quality.clear_cache();
    }

    /// Convert a normalized provider result into the fast display candidate
    /// set.  This method performs no model or network I/O.
    #[must_use]
    pub fn rank_result(
        &mut self,
        result: ConversionResult,
        request: &ConversionRequest,
        session: PipelineSession,
        candidates: Vec<PersonalizedCandidate>,
    ) -> FastConversionOutput {
        let context = if self.quality.config().data_policy() == LocalDataPolicy::BoundedContext {
            ExtractedContext::from_request(request, self.quality.config().max_context_chars())
        } else {
            ExtractedContext::default()
        };
        let mut baseline_candidates = candidates;
        baseline_candidates.truncate(request.limit.min(MAX_PIPELINE_CANDIDATES));
        let mut ranked_candidates = baseline_candidates.clone();
        let focused_id = result
            .focused_index
            .and_then(|index| ranked_candidates.get(index))
            .map(|candidate| candidate.candidate.id);
        let quality_request = LocalQualityRequest::new(
            session.session_id,
            session.generation,
            session.current_generation,
            session.tier,
            &result.reading,
        )
        .with_context(context.before(), context.after())
        .with_revisions(session.model_revision, session.learning_version);
        let fast_rank = self
            .quality
            .rank_fast(&mut ranked_candidates, &quality_request);
        let focused_index = focused_id.and_then(|id| {
            ranked_candidates
                .iter()
                .position(|candidate| candidate.candidate.id == id)
        });
        FastConversionOutput {
            result,
            baseline_candidates,
            candidates: ranked_candidates,
            focused_index,
            context,
            fast_rank,
            session,
        }
    }

    /// Run the real provider and the fast local stage as one operation.
    pub async fn convert_fast<P: ConversionProvider + ?Sized>(
        &mut self,
        provider: &P,
        request: &ConversionRequest,
        session: PipelineSession,
        learning_state: Option<&LearningState>,
        now: u64,
    ) -> Result<FastConversionOutput, ProviderError> {
        let result = provider.convert(request).await?;
        let context = if self.quality.config().data_policy() == LocalDataPolicy::BoundedContext {
            ExtractedContext::from_request(request, self.quality.config().max_context_chars())
        } else {
            ExtractedContext::default()
        };
        let candidates = if let Some(state) = learning_state {
            state.personalize_ordered(
                result.candidates.clone(),
                &result.reading,
                context.before(),
                now,
            )
        } else {
            Self::extract_candidates(&result, request.limit)
        };
        Ok(self.rank_result(result, request, session, candidates))
    }

    /// Convert provider candidates into the common personalized representation
    /// without applying learning or sorting.  This is the candidate extraction
    /// boundary used by callers that already have a Mozc result.
    #[must_use]
    pub fn extract_candidates(
        result: &ConversionResult,
        limit: usize,
    ) -> Vec<PersonalizedCandidate> {
        let limit = limit.min(MAX_PIPELINE_CANDIDATES);
        result
            .candidates
            .iter()
            .take(limit)
            .enumerate()
            .map(|(index, candidate)| Self::personalize_baseline_candidate(candidate, index))
            .collect()
    }

    /// Capture the exact bounded input for a later asynchronous model call.
    pub fn prepare_semantic_rerank(
        &self,
        output: &FastConversionOutput,
        current: PipelineSession,
    ) -> Result<SemanticRerankTicket, RerankRejection> {
        if current.current_generation != Some(output.session.generation) {
            return Err(RerankRejection::StaleGeneration);
        }
        if current.generation != output.session.generation
            || current.session_id != output.session.session_id
        {
            return Err(RerankRejection::StaleGeneration);
        }
        if current.tier != output.session.tier {
            return Err(RerankRejection::WrongModelTier);
        }
        if current.model_revision != output.session.model_revision {
            return Err(RerankRejection::WrongModelRevision);
        }
        if current.learning_version != output.session.learning_version {
            return Err(RerankRejection::WrongLearningVersion);
        }
        let request = LocalQualityRequest::new(
            output.session.session_id,
            output.session.generation,
            current.current_generation,
            output.session.tier,
            &output.result.reading,
        )
        .with_context(output.context.before(), output.context.after())
        .with_revisions(
            output.session.model_revision,
            output.session.learning_version,
        );
        let snapshot = self
            .quality
            .capture_semantic_rerank(&request, &output.candidates)?;
        let candidates = output.candidates[..snapshot.len()]
            .iter()
            .map(|candidate| SemanticCandidate {
                id: candidate.candidate.id,
                text: candidate.candidate.text.clone(),
                reading: candidate.candidate.reading.clone(),
            })
            .collect::<Vec<_>>();
        let input = SemanticRerankInput {
            session_id: output.session.session_id,
            generation: output.session.generation,
            tier: output.session.tier,
            model_revision: output.session.model_revision,
            learning_version: output.session.learning_version,
            input_revision: snapshot.input_revision(),
            reading: output.result.reading.clone(),
            context_before: output.context.before().to_owned(),
            context_after: output.context.after().to_owned(),
            candidates,
        };
        input.validate()?;
        Ok(SemanticRerankTicket { snapshot, input })
    }

    /// Execute the slow semantic stage and apply a validated order atomically.
    /// Any timeout, cancellation, provider error, or invalid decision leaves the
    /// fast-path candidates untouched.
    pub async fn apply_semantic_rerank<P: SemanticRerankProvider + ?Sized>(
        &mut self,
        ticket: SemanticRerankTicket,
        output: &mut FastConversionOutput,
        current: PipelineSession,
        provider: &P,
    ) -> SemanticRerankResolution {
        self.apply_semantic_rerank_with_report(ticket, output, current, provider)
            .await
            .resolution
    }

    /// Apply the slow path and retain only bounded decision metadata for
    /// diagnostics.  The metadata never contains candidate or context text.
    pub async fn apply_semantic_rerank_with_report<P: SemanticRerankProvider + ?Sized>(
        &mut self,
        ticket: SemanticRerankTicket,
        output: &mut FastConversionOutput,
        current: PipelineSession,
        provider: &P,
    ) -> SemanticRerankReport {
        if current.current_generation != Some(ticket.snapshot.generation())
            || current.generation != ticket.snapshot.generation()
            || current.session_id != ticket.snapshot.session_id()
        {
            return SemanticRerankReport::from_resolution(SemanticRerankResolution::Rejected(
                RerankRejection::StaleGeneration,
            ));
        }
        if current.tier != ticket.snapshot.tier() {
            return SemanticRerankReport::from_resolution(SemanticRerankResolution::Rejected(
                RerankRejection::WrongModelTier,
            ));
        }
        if current.model_revision != ticket.snapshot.model_revision() {
            return SemanticRerankReport::from_resolution(SemanticRerankResolution::Rejected(
                RerankRejection::WrongModelRevision,
            ));
        }
        if current.learning_version != ticket.snapshot.learning_version() {
            return SemanticRerankReport::from_resolution(SemanticRerankResolution::Rejected(
                RerankRejection::WrongLearningVersion,
            ));
        }
        let expected_ids = ticket.snapshot.candidate_ids();
        if output.candidates.len() < expected_ids.len()
            || output
                .candidates
                .iter()
                .zip(expected_ids.iter())
                .any(|(candidate, expected)| candidate.candidate.id != expected)
        {
            return SemanticRerankReport::from_resolution(SemanticRerankResolution::Rejected(
                RerankRejection::CandidateSetChanged,
            ));
        }

        let window_len = ticket.snapshot.len();
        let focused_id = output
            .focused_index
            .and_then(|index| output.candidates.get(index))
            .map(|candidate| candidate.candidate.id);
        let provider_result = match timeout(
            self.semantic_deadline,
            provider.rerank(ticket.input.clone()),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err(SemanticProviderError::TimedOut),
        };
        let decision_metadata = provider_result
            .as_ref()
            .ok()
            .map(|decision| (decision.confidence, decision.reason));
        let admission = SemanticRerankAdmission::new(
            current.current_generation,
            current.model_revision,
            current.learning_version,
            &mut output.candidates,
        );
        let resolution =
            self.quality
                .resolve_semantic_rerank(ticket.snapshot, admission, provider_result);
        if let SemanticRerankResolution::Applied { changed_positions } = resolution
            && changed_positions > 0
        {
            for candidate in output.candidates.iter_mut().take(window_len) {
                mark_semantic_rerank(candidate, decision_metadata);
            }
        }
        output.focused_index = focused_id.and_then(|id| {
            output
                .candidates
                .iter()
                .position(|candidate| candidate.candidate.id == id)
        });
        SemanticRerankReport {
            resolution,
            confidence: decision_metadata.map(|metadata| metadata.0),
            reason: decision_metadata.map(|metadata| metadata.1),
        }
    }

    fn personalize_baseline_candidate(
        candidate: &ConversionCandidate,
        index: usize,
    ) -> PersonalizedCandidate {
        let provider_rank = candidate.provider_rank.max(index);
        let mozc = 920.0 / (provider_rank.saturating_add(1) as f64);
        PersonalizedCandidate {
            candidate: candidate.clone(),
            score: mozc,
            adjustments: CandidateAdjustments {
                mozc,
                learning: 0.0,
                domain: 0.0,
                user_word: 0.0,
                context: 0.0,
            },
            explanation: format!(
                "{}・Mozc の候補順序を採用しました",
                candidate.origin.label()
            ),
        }
    }
}

fn mark_semantic_rerank(
    candidate: &mut PersonalizedCandidate,
    metadata: Option<(f64, SemanticRerankReason)>,
) {
    const ATTRIBUTE: &str = "ローカルAI・文脈再順位";
    if !candidate
        .candidate
        .attributes
        .iter()
        .any(|attribute| attribute == ATTRIBUTE)
    {
        candidate.candidate.attributes.push(ATTRIBUTE.to_owned());
    }
    let detail = metadata.map_or_else(
        || "保存済みのローカルAI判定で再順位".to_owned(),
        |(confidence, reason)| {
            let label = match reason {
                SemanticRerankReason::SemanticContext => "前後の文脈",
                SemanticRerankReason::AmbiguousHomophone => "同音異義の文脈",
                SemanticRerankReason::DomainTerm => "専門語",
                SemanticRerankReason::IntentFit => "入力意図",
                SemanticRerankReason::Abstain => "保守的な判定",
            };
            format!(
                "ローカルAI（{label}、信頼度 {:.0}%）で再順位",
                confidence * 100.0
            )
        },
    );
    let explanation = format!("{}・{detail}", candidate.explanation);
    candidate.explanation = explanation.chars().take(240).collect();
}

fn valid_text(value: &str, max_chars: usize) -> bool {
    !value.is_empty() && value.chars().count() <= max_chars && !value.chars().any(char::is_control)
}

fn valid_optional_text(value: &str, max_chars: usize) -> bool {
    value.chars().count() <= max_chars && !value.chars().any(char::is_control)
}

/// Errors from a pipeline adapter that needs to expose a public result while
/// retaining a provider error.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum PipelineError {
    #[error("conversion provider failed: {0}")]
    Provider(#[from] ProviderError),
    #[error("candidate ranking was rejected: {0}")]
    Ranking(#[from] RerankRejection),
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use async_trait::async_trait;

    use super::{CandidatePipeline, ExtractedContext, PipelineSession, SemanticRerankProvider};
    use crate::{
        CandidateAdjustments, CandidateOrigin, ConversionCandidate, ConversionRequest,
        ConversionResult, LocalDataPolicy, LocalQualityConfig, ModelTier, PersonalizedCandidate,
        ProviderCapabilities, ProviderError, ProviderHealth, SemanticProviderError,
        SemanticRerankDecision,
    };

    fn provider_candidate(id: i32, text: &str, rank: usize) -> ConversionCandidate {
        ConversionCandidate {
            id,
            text: text.to_owned(),
            reading: Some("とうきょう".to_owned()),
            provider_rank: rank,
            description: Some("internal-description".to_owned()),
            origin: CandidateOrigin::Conversion,
            attributes: vec!["internal-attribute".to_owned()],
            log: Some("internal-log".to_owned()),
        }
    }

    fn provider_result() -> ConversionResult {
        ConversionResult {
            provider: "Mozc".to_owned(),
            reading: "とうきょう".to_owned(),
            preedit: "東京".to_owned(),
            preedit_segments: Vec::new(),
            candidates: vec![
                provider_candidate(10, "東京", 0),
                provider_candidate(20, "京都", 1),
                provider_candidate(30, "とうきょう", 2),
            ],
            focused_index: Some(0),
            consumed: true,
            elapsed: Duration::from_millis(1),
        }
    }

    struct FakeProvider {
        result: ConversionResult,
    }

    #[async_trait]
    impl crate::ConversionProvider for FakeProvider {
        fn name(&self) -> &'static str {
            "fake-mozc"
        }

        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities {
                name: "fake-mozc".to_owned(),
                romaji: true,
                kana: true,
                n_best: true,
                context: true,
                user_dictionary: false,
                local: true,
            }
        }

        async fn health(&self) -> ProviderHealth {
            ProviderHealth {
                available: true,
                provider: "fake-mozc".to_owned(),
                detail: "ready".to_owned(),
                capabilities: self.capabilities(),
            }
        }

        async fn convert(
            &self,
            _request: &ConversionRequest,
        ) -> Result<ConversionResult, ProviderError> {
            Ok(self.result.clone())
        }

        async fn commit(&self, _candidate_id: i32) -> Result<crate::CommitResult, ProviderError> {
            Ok(crate::CommitResult {
                text: String::new(),
                elapsed_millis: 0,
            })
        }

        async fn reset(&self) -> Result<(), ProviderError> {
            Ok(())
        }
    }

    struct ReorderProvider {
        order: Vec<i32>,
        delay: Duration,
    }

    #[async_trait]
    impl SemanticRerankProvider for ReorderProvider {
        async fn rerank(
            &self,
            input: super::SemanticRerankInput,
        ) -> Result<SemanticRerankDecision, SemanticProviderError> {
            if !self.delay.is_zero() {
                tokio::time::sleep(self.delay).await;
            }
            Ok(SemanticRerankDecision {
                action: crate::SemanticRerankAction::Rerank,
                candidate_ids: crate::CandidateIdOrder::from_slice(&self.order)
                    .map_err(|_| SemanticProviderError::MalformedResponse)?,
                patch: None,
                confidence: 0.95,
                reason: crate::SemanticRerankReason::SemanticContext,
                model_tier: input.tier,
                expires_at_generation: input.generation,
                input_revision: input.input_revision,
                model_revision: input.model_revision,
                learning_version: input.learning_version,
            })
        }
    }

    fn pipeline() -> CandidatePipeline {
        CandidatePipeline::new(
            LocalQualityConfig::new(LocalDataPolicy::BoundedContext)
                .with_limits(5, 3, 32, 8)
                .with_fast_deadline(Duration::from_millis(20)),
        )
        .with_semantic_deadline(Duration::from_millis(50))
    }

    fn session() -> PipelineSession {
        PipelineSession::new(7, 42, ModelTier::Compact).with_revisions(3, 9)
    }

    #[test]
    fn context_extraction_is_bounded_tail_head_and_control_free() {
        let mut request = ConversionRequest::new("とうきょう");
        request.context_before = " far\ncontext 東京".to_owned();
        request.context_after = "只看这里".to_owned();
        let context = ExtractedContext::from_request(&request, 5);
        assert_eq!(context.len(), 5);
        assert!(context.chars().all(|character| !character.is_control()));
        assert!(context.before().contains("東京"));
    }

    #[tokio::test]
    async fn fast_and_slow_stages_reorder_the_real_candidate_window() {
        let mut pipeline = pipeline();
        let mut request = ConversionRequest::new("とうきょう");
        request.context_before = "昨日の東京で".to_owned();
        let provider = FakeProvider {
            result: provider_result(),
        };
        let mut output = pipeline
            .convert_fast(&provider, &request, session(), None, 0)
            .await
            .expect("provider conversion");
        assert_eq!(output.fast_rank.changed_positions, 0);

        let ticket = pipeline
            .prepare_semantic_rerank(&output, session())
            .expect("semantic ticket");
        let input = ticket.input();
        assert_eq!(input.candidates.len(), 3);
        assert!(!input.candidates[0].text.contains("internal"));
        assert!(input.context_before.contains("東京"));

        let slow = ReorderProvider {
            order: vec![20, 10, 30],
            delay: Duration::ZERO,
        };
        let resolution = pipeline
            .apply_semantic_rerank(ticket, &mut output, session(), &slow)
            .await;
        assert!(resolution.is_applied());
        assert_eq!(output.candidate_ids(), vec![20, 10, 30]);
        assert_eq!(output.focused_index, Some(1));
        assert!(
            output.candidates[0]
                .candidate
                .attributes
                .iter()
                .any(|attribute| attribute == "ローカルAI・文脈再順位")
        );
    }

    #[tokio::test]
    async fn timeout_and_stale_results_preserve_fast_candidates() {
        let mut pipeline = pipeline();
        let request = ConversionRequest::new("とうきょう");
        let provider = FakeProvider {
            result: provider_result(),
        };
        let mut output = pipeline
            .convert_fast(&provider, &request, session(), None, 0)
            .await
            .expect("provider conversion");
        let original = output.candidate_ids();
        let ticket = pipeline
            .prepare_semantic_rerank(&output, session())
            .expect("semantic ticket");
        let slow = ReorderProvider {
            order: vec![20, 10, 30],
            delay: Duration::from_millis(100),
        };
        let resolution = pipeline
            .apply_semantic_rerank(ticket, &mut output, session(), &slow)
            .await;
        assert!(matches!(
            resolution,
            crate::SemanticRerankResolution::Fallback(SemanticProviderError::TimedOut)
        ));
        assert_eq!(output.candidate_ids(), original);

        let ticket = pipeline
            .prepare_semantic_rerank(&output, session())
            .expect("semantic ticket");
        let mut stale = session();
        stale.generation += 1;
        stale.current_generation = Some(stale.generation);
        let slow = ReorderProvider {
            order: vec![20, 10, 30],
            delay: Duration::ZERO,
        };
        let resolution = pipeline
            .apply_semantic_rerank(ticket, &mut output, stale, &slow)
            .await;
        assert!(matches!(
            resolution,
            crate::SemanticRerankResolution::Rejected(crate::RerankRejection::StaleGeneration)
        ));
        assert_eq!(output.candidate_ids(), original);
    }

    fn scored_candidate(id: i32, text: &str, score: f64) -> PersonalizedCandidate {
        PersonalizedCandidate {
            candidate: ConversionCandidate {
                id,
                text: text.to_owned(),
                reading: Some("こうえん".to_owned()),
                provider_rank: id as usize - 1,
                description: None,
                origin: CandidateOrigin::Conversion,
                attributes: Vec::new(),
                log: None,
            },
            score,
            adjustments: CandidateAdjustments {
                mozc: score,
                learning: 0.0,
                domain: 0.0,
                user_word: 0.0,
                context: 0.0,
            },
            explanation: "test".to_owned(),
        }
    }

    #[test]
    fn bounded_context_disambiguates_multiple_homophones_without_keyword_tables() {
        let cases = [
            ("昨日公園に行った", "公園"),
            ("大学で講演を聞いた", "講演"),
            ("候補者を後援する", "後援"),
        ];
        for (context, expected) in cases {
            let result = ConversionResult {
                provider: "Mozc".to_owned(),
                reading: "こうえん".to_owned(),
                preedit: expected.to_owned(),
                preedit_segments: Vec::new(),
                candidates: Vec::new(),
                focused_index: Some(0),
                consumed: true,
                elapsed: Duration::ZERO,
            };
            let mut request = ConversionRequest::new("kouen");
            request.context_before = context.to_owned();
            let mut pipeline = pipeline();
            let candidates = vec![
                scored_candidate(1, "交喚", 100.0),
                scored_candidate(2, expected, 99.0),
                scored_candidate(3, "こうえん", 98.0),
            ];
            let output = pipeline.rank_result(
                result,
                &request,
                PipelineSession::new(1, 1, ModelTier::Compact),
                candidates,
            );
            assert_eq!(output.candidates[0].candidate.text, expected);
        }
    }

    #[tokio::test]
    async fn learning_preserves_provider_order_before_fast_ranking() {
        let mut pipeline = pipeline();
        let mut request = ConversionRequest::new("とうきょう");
        request.context_before = "昨日の東京で".to_owned();
        let mut state = crate::LearningState::default();
        for _ in 0..8 {
            state.record("とうきょう", "京都", "昨日の東京で", 1);
        }
        let provider = FakeProvider {
            result: provider_result(),
        };
        let output = pipeline
            .convert_fast(&provider, &request, session(), Some(&state), 1)
            .await
            .expect("provider conversion");
        assert_eq!(output.baseline_ids(), vec![10, 20, 30]);
        assert_eq!(output.candidate_ids(), vec![20, 10, 30]);
    }
}
