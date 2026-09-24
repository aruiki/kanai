// These APIs are public from this private module so kanai-core can re-export a
// single stable surface. Until the broker integration adds those re-exports,
// rustc cannot see downstream uses from the library build alone.

use std::collections::VecDeque;
use std::collections::hash_map::DefaultHasher;
use std::fmt;
use std::hash::{Hash, Hasher};
use std::time::{Duration, Instant};

use serde::de::{self, SeqAccess, Visitor};
use serde::ser::SerializeSeq;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use thiserror::Error;

use crate::{CandidateOrigin, PersonalizedCandidate};

/// A deliberately small ladder of local generation tiers. Mozc remains the
/// baseline in every tier; these profiles control the optional assist model.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ModelTier {
    #[default]
    MozcOnly,
    Tiny,
    Compact,
    Balanced,
}

impl ModelTier {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::MozcOnly => "Mozc Only",
            Self::Tiny => "Tiny · 0.6B",
            Self::Compact => "Compact · 1.7B",
            Self::Balanced => "Balanced · 4B",
        }
    }

    #[must_use]
    pub const fn description(self) -> &'static str {
        match self {
            Self::MozcOnly => "生成AIなしで最軽量。変換・予測・修復・ユーザー辞書は利用できます。",
            Self::Tiny => "0.6B前後のQ4。短い推敲と候補補助。4GB RAMを推奨します。",
            Self::Compact => "1.7B前後のQ4。文脈再順位付けと段落単位の推敲に向きます。",
            Self::Balanced => "4B前後のQ4。文書全体の支援品質を優先します。",
        }
    }

    #[must_use]
    pub const fn model_size_b(self) -> Option<&'static str> {
        match self {
            Self::MozcOnly => None,
            Self::Tiny => Some("0.6B"),
            Self::Compact => Some("1.7B"),
            Self::Balanced => Some("4B"),
        }
    }

    #[must_use]
    pub const fn recommended_ram_gib(self) -> Option<u32> {
        match self {
            Self::MozcOnly => Some(0),
            Self::Tiny => Some(4),
            Self::Compact => Some(6),
            Self::Balanced => Some(12),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Quantization {
    NotApplicable,
    Q4Km,
    Q4,
    Q5Km,
}

impl Quantization {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::NotApplicable => "—",
            Self::Q4Km => "Q4_K_M",
            Self::Q4 => "Q4",
            Self::Q5Km => "Q5_K_M",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProfile {
    pub tier: ModelTier,
    pub parameters: &'static str,
    pub quantization: Quantization,
    pub approximate_model_mib: u32,
    pub recommended_ram_gib: u32,
    pub context_tokens: u32,
    pub max_output_tokens: u32,
    pub gpu_recommended: bool,
}

impl ModelProfile {
    #[must_use]
    pub const fn all() -> [Self; 4] {
        [
            Self {
                tier: ModelTier::MozcOnly,
                parameters: "—",
                quantization: Quantization::NotApplicable,
                approximate_model_mib: 0,
                recommended_ram_gib: 0,
                context_tokens: 0,
                max_output_tokens: 0,
                gpu_recommended: false,
            },
            Self {
                tier: ModelTier::Tiny,
                parameters: "≈0.6B",
                quantization: Quantization::Q4Km,
                approximate_model_mib: 500,
                recommended_ram_gib: 4,
                context_tokens: 2_048,
                max_output_tokens: 192,
                gpu_recommended: false,
            },
            Self {
                tier: ModelTier::Compact,
                parameters: "≈1.7B",
                quantization: Quantization::Q4Km,
                approximate_model_mib: 1_200,
                recommended_ram_gib: 6,
                context_tokens: 4_096,
                max_output_tokens: 384,
                gpu_recommended: true,
            },
            Self {
                tier: ModelTier::Balanced,
                parameters: "≈4B",
                quantization: Quantization::Q4Km,
                approximate_model_mib: 2_700,
                recommended_ram_gib: 12,
                context_tokens: 8_192,
                max_output_tokens: 768,
                gpu_recommended: true,
            },
        ]
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HardwareCapabilities {
    pub total_ram_gib: u32,
    pub available_ram_gib: u32,
    pub logical_cpus: u32,
    pub recommended_tier: ModelTier,
    pub explanation: String,
}

#[must_use]
pub fn recommend_tier(total_ram_gib: u32, logical_cpus: u32) -> ModelTier {
    recommend_tier_for_memory(total_ram_gib, total_ram_gib, logical_cpus)
}

/// Recommend a tier from free memory as well as installed capacity. This is
/// deliberately conservative: low-memory machines never auto-load a model.
#[must_use]
pub fn recommend_tier_for_memory(
    total_ram_gib: u32,
    available_ram_gib: u32,
    logical_cpus: u32,
) -> ModelTier {
    if total_ram_gib < 4 || available_ram_gib < 2 {
        ModelTier::MozcOnly
    } else if available_ram_gib < 4 || logical_cpus <= 3 {
        ModelTier::Tiny
    } else if available_ram_gib < 6 || total_ram_gib < 8 {
        ModelTier::Compact
    } else {
        ModelTier::Balanced
    }
}

/// Hard upper bound for the synchronous, deterministic candidate window.
///
/// The engine only scores and reorders this prefix. A larger Mozc page remains
/// intact after the prefix instead of causing an allocation proportional to the
/// full provider result.
pub const MAX_LOCAL_QUALITY_CANDIDATES: usize = 9;
/// Hard privacy bound for context admitted to the local-quality path.
pub const MAX_LOCAL_QUALITY_CONTEXT_CHARS: usize = 32;
/// Hard bound on the in-memory order cache.
pub const MAX_LOCAL_QUALITY_CACHE_ENTRIES: usize = 128;
/// A candidate may move at most this many places in one local decision.
pub const MAX_LOCAL_QUALITY_RANK_SHIFT: usize = 3;
/// Maximum semantic-rerank confidence required before an order is adopted.
pub const MIN_SEMANTIC_RERANK_CONFIDENCE: f64 = 0.75;
/// Suggested deadline for an off-key-path local semantic request.
pub const DEFAULT_SEMANTIC_RERANK_DEADLINE: Duration = Duration::from_millis(250);
/// Suggested hard deadline for the bounded deterministic policy.
pub const DEFAULT_FAST_RANK_DEADLINE: Duration = Duration::from_millis(2);
/// Hard cap that a caller can configure for the synchronous policy.
pub const MAX_FAST_RANK_DEADLINE: Duration = Duration::from_millis(20);

const MAX_READING_CHARS: usize = 64;
const MAX_CANDIDATE_TEXT_CHARS: usize = 96;
const MAX_READING_BYTES: usize = MAX_READING_CHARS * 4;
const MAX_CANDIDATE_TEXT_BYTES: usize = MAX_CANDIDATE_TEXT_CHARS * 4;
const FAST_CONTEXT_SUFFIX_BONUS: f64 = 16.0;
const FAST_CONTEXT_CONTAINS_BONUS: f64 = 8.0;
const FAST_READING_BONUS: f64 = 2.0;

/// Controls which deterministic/local data may affect candidate order.
///
/// `MozcBaseline` is the safe default. The broker must use it for protected
/// fields, Protect Mode, and before the user has made a local-feature choice.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LocalDataPolicy {
    #[default]
    MozcBaseline,
    CandidateFeatures,
    BoundedContext,
}

/// Immutable limits for the local-quality stage. All setters clamp to the hard
/// bounds above, so a broker/configuration mistake cannot make the path
/// unbounded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalQualityConfig {
    data_policy: LocalDataPolicy,
    max_candidates: usize,
    max_rank_shift: usize,
    max_context_chars: usize,
    cache_capacity: usize,
    fast_deadline: Duration,
    policy_revision: u32,
}

impl Default for LocalQualityConfig {
    fn default() -> Self {
        Self {
            data_policy: LocalDataPolicy::MozcBaseline,
            max_candidates: MAX_LOCAL_QUALITY_CANDIDATES,
            max_rank_shift: MAX_LOCAL_QUALITY_RANK_SHIFT,
            max_context_chars: MAX_LOCAL_QUALITY_CONTEXT_CHARS,
            cache_capacity: 64,
            fast_deadline: DEFAULT_FAST_RANK_DEADLINE,
            policy_revision: 1,
        }
    }
}

impl LocalQualityConfig {
    #[must_use]
    pub const fn new(data_policy: LocalDataPolicy) -> Self {
        Self {
            data_policy,
            max_candidates: MAX_LOCAL_QUALITY_CANDIDATES,
            max_rank_shift: MAX_LOCAL_QUALITY_RANK_SHIFT,
            max_context_chars: MAX_LOCAL_QUALITY_CONTEXT_CHARS,
            cache_capacity: 64,
            fast_deadline: DEFAULT_FAST_RANK_DEADLINE,
            policy_revision: 1,
        }
    }

    #[must_use]
    pub fn with_limits(
        mut self,
        max_candidates: usize,
        max_rank_shift: usize,
        max_context_chars: usize,
        cache_capacity: usize,
    ) -> Self {
        self.max_candidates = max_candidates.clamp(2, MAX_LOCAL_QUALITY_CANDIDATES);
        self.max_rank_shift = max_rank_shift.min(MAX_LOCAL_QUALITY_RANK_SHIFT);
        self.max_context_chars = max_context_chars.min(MAX_LOCAL_QUALITY_CONTEXT_CHARS);
        self.cache_capacity = cache_capacity.min(MAX_LOCAL_QUALITY_CACHE_ENTRIES);
        self
    }

    #[must_use]
    pub fn with_fast_deadline(mut self, deadline: Duration) -> Self {
        self.fast_deadline = if deadline > MAX_FAST_RANK_DEADLINE {
            MAX_FAST_RANK_DEADLINE
        } else {
            deadline
        };
        self
    }

    #[must_use]
    pub const fn with_policy_revision(mut self, revision: u32) -> Self {
        self.policy_revision = revision;
        self
    }

    #[must_use]
    pub const fn data_policy(self) -> LocalDataPolicy {
        self.data_policy
    }

    #[must_use]
    pub const fn max_candidates(self) -> usize {
        self.max_candidates
    }

    #[must_use]
    pub const fn max_rank_shift(self) -> usize {
        self.max_rank_shift
    }

    #[must_use]
    pub const fn max_context_chars(self) -> usize {
        self.max_context_chars
    }

    #[must_use]
    pub const fn cache_capacity(self) -> usize {
        self.cache_capacity
    }

    #[must_use]
    pub const fn fast_deadline(self) -> Duration {
        self.fast_deadline
    }

    #[must_use]
    pub const fn policy_revision(self) -> u32 {
        self.policy_revision
    }

    /// Normalize only the context admitted by this configuration. Callers can
    /// pass the result to a local prompt builder without retaining or sending
    /// either unbounded source string.
    #[must_use]
    pub fn bound_context(&self, context_before: &str, context_after: &str) -> BoundedLocalContext {
        if self.data_policy != LocalDataPolicy::BoundedContext {
            BoundedLocalContext::EMPTY
        } else {
            BoundedLocalContext::bounded(context_before, context_after, self.max_context_chars)
        }
    }
}

/// Borrowed metadata for one deterministic or semantic candidate-window
/// operation. It intentionally contains no candidate text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalQualityRequest<'a> {
    pub session_id: u64,
    pub generation: u64,
    /// `None` means the session/focus has ended.
    pub current_generation: Option<u64>,
    pub tier: ModelTier,
    pub reading: &'a str,
    pub context_before: &'a str,
    pub context_after: &'a str,
    pub model_revision: u64,
    pub learning_version: u64,
}

impl<'a> LocalQualityRequest<'a> {
    #[must_use]
    pub const fn new(
        session_id: u64,
        generation: u64,
        current_generation: Option<u64>,
        tier: ModelTier,
        reading: &'a str,
    ) -> Self {
        Self {
            session_id,
            generation,
            current_generation,
            tier,
            reading,
            context_before: "",
            context_after: "",
            model_revision: 0,
            learning_version: 0,
        }
    }

    #[must_use]
    pub const fn with_context(mut self, before: &'a str, after: &'a str) -> Self {
        self.context_before = before;
        self.context_after = after;
        self
    }

    #[must_use]
    pub const fn with_revisions(mut self, model_revision: u64, learning_version: u64) -> Self {
        self.model_revision = model_revision;
        self.learning_version = learning_version;
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FastRankStatus {
    Applied,
    CacheHit,
    Unchanged,
    MozcOnly,
    PolicyDisabled,
    StaleGeneration,
    SessionEnded,
    DeadlineExceeded,
    InvalidInput,
    DuplicateCandidateIds,
    RankShiftTooLarge,
    InsufficientCandidates,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FastRankOutcome {
    pub status: FastRankStatus,
    pub changed_positions: u16,
    pub evaluated_candidates: u16,
    pub cache_entries: u16,
    pub elapsed_micros: u64,
}

impl FastRankOutcome {
    #[must_use]
    pub const fn used_baseline(self) -> bool {
        !matches!(
            self.status,
            FastRankStatus::Applied | FastRankStatus::CacheHit
        )
    }

    #[must_use]
    pub const fn changed_candidate(self) -> bool {
        self.changed_positions > 0
    }
}

/// Fixed-capacity, allocation-bounded candidate ID order. Deserialization also
/// enforces the limit while reading, so a malformed model response cannot first
/// allocate an arbitrary `Vec<i32>`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CandidateIdOrder {
    ids: [i32; MAX_LOCAL_QUALITY_CANDIDATES],
    len: u8,
}

impl CandidateIdOrder {
    pub fn from_slice(ids: &[i32]) -> Result<Self, CandidateOrderError> {
        if ids.len() > MAX_LOCAL_QUALITY_CANDIDATES {
            return Err(CandidateOrderError::TooManyCandidates {
                count: ids.len(),
                max: MAX_LOCAL_QUALITY_CANDIDATES,
            });
        }
        let mut values = [0_i32; MAX_LOCAL_QUALITY_CANDIDATES];
        values[..ids.len()].copy_from_slice(ids);
        Ok(Self {
            ids: values,
            len: ids.len() as u8,
        })
    }

    #[must_use]
    pub const fn len(self) -> usize {
        self.len as usize
    }

    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.len == 0
    }

    #[must_use]
    pub fn as_slice(&self) -> &[i32] {
        &self.ids[..self.len()]
    }

    pub fn iter(&self) -> impl ExactSizeIterator<Item = i32> + '_ {
        self.as_slice().iter().copied()
    }

    fn resolve(
        self,
        expected: &[i32],
        max_rank_shift: usize,
    ) -> Result<IndexOrder, RerankRejection> {
        if self.len() != expected.len() {
            return Err(RerankRejection::IncompleteCandidateSet);
        }

        let mut old_indices = [usize::MAX; MAX_LOCAL_QUALITY_CANDIDATES];
        let mut seen_old = [false; MAX_LOCAL_QUALITY_CANDIDATES];
        let mut changed_positions = 0_u16;
        for (new_index, id) in self.iter().enumerate() {
            let Some(old_index) = expected.iter().position(|expected| *expected == id) else {
                return Err(RerankRejection::UnknownCandidate(id));
            };
            if seen_old[old_index] {
                return Err(RerankRejection::DuplicateCandidate);
            }
            seen_old[old_index] = true;
            old_indices[new_index] = old_index;
            if old_index != new_index {
                changed_positions += 1;
            }
        }

        for (new_index, old_index) in old_indices.iter().copied().take(expected.len()).enumerate() {
            if old_index == usize::MAX {
                return Err(RerankRejection::IncompleteCandidateSet);
            }
            if old_index.abs_diff(new_index) > max_rank_shift {
                return Err(RerankRejection::MovementTooLarge);
            }
        }

        Ok(IndexOrder {
            old_indices,
            len: self.len,
            changed_positions,
        })
    }
}

impl TryFrom<Vec<i32>> for CandidateIdOrder {
    type Error = CandidateOrderError;

    fn try_from(value: Vec<i32>) -> Result<Self, Self::Error> {
        Self::from_slice(&value)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CandidateOrderError {
    #[error("candidate order has {count} entries; maximum is {max}")]
    TooManyCandidates { count: usize, max: usize },
}

impl Serialize for CandidateIdOrder {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut sequence = serializer.serialize_seq(Some(self.len()))?;
        for id in self.iter() {
            sequence.serialize_element(&id)?;
        }
        sequence.end()
    }
}

impl<'de> Deserialize<'de> for CandidateIdOrder {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct CandidateIdOrderVisitor;

        impl<'de> Visitor<'de> for CandidateIdOrderVisitor {
            type Value = CandidateIdOrder;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(formatter, "at most 9 candidate IDs")
            }

            fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
            where
                A: SeqAccess<'de>,
            {
                let mut ids = [0_i32; MAX_LOCAL_QUALITY_CANDIDATES];
                let mut len = 0_usize;
                while let Some(id) = sequence.next_element::<i32>()? {
                    if len == MAX_LOCAL_QUALITY_CANDIDATES {
                        return Err(de::Error::invalid_length(
                            len + 1,
                            &"at most 9 candidate IDs",
                        ));
                    }
                    ids[len] = id;
                    len += 1;
                }
                Ok(CandidateIdOrder {
                    ids,
                    len: len as u8,
                })
            }
        }

        deserializer.deserialize_seq(CandidateIdOrderVisitor)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct IndexOrder {
    old_indices: [usize; MAX_LOCAL_QUALITY_CANDIDATES],
    len: u8,
    changed_positions: u16,
}

impl IndexOrder {
    fn from_scored(scored: &[ScoredCandidate], len: usize) -> Self {
        let mut old_indices = [0_usize; MAX_LOCAL_QUALITY_CANDIDATES];
        let mut changed_positions = 0_u16;
        for (new_index, candidate) in scored[..len].iter().enumerate() {
            old_indices[new_index] = candidate.old_index;
            if candidate.old_index != new_index {
                changed_positions = changed_positions.saturating_add(1);
            }
        }
        Self {
            old_indices,
            len: len as u8,
            changed_positions,
        }
    }

    fn ids(self, candidates: &[PersonalizedCandidate]) -> CandidateIdOrder {
        let len = self.len as usize;
        let mut ids = [0_i32; MAX_LOCAL_QUALITY_CANDIDATES];
        for (new_index, old_index) in self.old_indices[..len].iter().copied().enumerate() {
            ids[new_index] = candidates[old_index].candidate.id;
        }
        CandidateIdOrder {
            ids,
            len: len as u8,
        }
    }
}

fn apply_index_order<T>(values: &mut [T], order: IndexOrder) -> Result<u16, RerankRejection> {
    let len = order.len as usize;
    if values.len() < len {
        return Err(RerankRejection::IncompleteCandidateSet);
    }

    // Validate the complete permutation before the first swap. Then apply each
    // cycle directly with a fixed visited array. This is constant-space and
    // cannot leave a partially reordered slice after a malformed index.
    let mut seen = [false; MAX_LOCAL_QUALITY_CANDIDATES];
    for &old_index in &order.old_indices[..len] {
        if old_index >= len || seen[old_index] {
            return Err(RerankRejection::IncompleteCandidateSet);
        }
        seen[old_index] = true;
    }
    if seen[..len].iter().any(|visited| !visited) {
        return Err(RerankRejection::IncompleteCandidateSet);
    }

    let mut visited = [false; MAX_LOCAL_QUALITY_CANDIDATES];
    for start in 0..len {
        if visited[start] || order.old_indices[start] == start {
            visited[start] = true;
            continue;
        }
        let mut destination = start;
        loop {
            let source = order.old_indices[destination];
            values.swap(destination, source);
            visited[destination] = true;
            visited[source] = true;
            if order.old_indices[source] == start {
                break;
            }
            destination = source;
        }
    }
    Ok(order.changed_positions)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SemanticRerankAction {
    Rerank,
    Abstain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SemanticRerankReason {
    #[serde(rename = "semantic_context")]
    SemanticContext,
    #[serde(rename = "ambiguous_homophone")]
    AmbiguousHomophone,
    #[serde(rename = "domain_term")]
    DomainTerm,
    #[serde(rename = "intent_fit")]
    IntentFit,
    #[serde(rename = "abstain")]
    Abstain,
}

/// A rerank response may carry the documented `patch: null` field, but no
/// patch payload has a valid representation in this release.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NoCandidatePatch;

impl Serialize for NoCandidatePatch {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_none()
    }
}

impl<'de> Deserialize<'de> for NoCandidatePatch {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct NullOnlyVisitor;

        impl Visitor<'_> for NullOnlyVisitor {
            type Value = NoCandidatePatch;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("null; candidate patches are disabled")
            }

            fn visit_unit<E>(self) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                Ok(NoCandidatePatch)
            }

            fn visit_none<E>(self) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                Ok(NoCandidatePatch)
            }
        }

        deserializer.deserialize_option(NullOnlyVisitor)
    }
}

/// Typed output accepted by the core. Unknown JSON fields and non-null patches
/// are rejected before this value can be constructed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SemanticRerankDecision {
    pub action: SemanticRerankAction,
    pub candidate_ids: CandidateIdOrder,
    pub patch: Option<NoCandidatePatch>,
    pub confidence: f64,
    pub reason: SemanticRerankReason,
    pub model_tier: ModelTier,
    pub expires_at_generation: u64,
    pub input_revision: u64,
    pub model_revision: u64,
    pub learning_version: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RerankRejection {
    #[error("MozcOnly does not admit local AI reranking")]
    MozcOnly,
    #[error("local-data policy keeps the Mozc baseline")]
    PolicyDisabled,
    #[error("candidate result belongs to a stale generation")]
    StaleGeneration,
    #[error("candidate result belongs to a different model revision")]
    WrongModelRevision,
    #[error("candidate result belongs to a different learning version")]
    WrongLearningVersion,
    #[error("candidate result belongs to a different model tier")]
    WrongModelTier,
    #[error("candidate result belongs to different input")]
    WrongInputRevision,
    #[error("semantic confidence is malformed")]
    InvalidConfidence,
    #[error("semantic confidence is below the adoption threshold")]
    LowConfidence,
    #[error("semantic reason is invalid for the action")]
    InvalidReason,
    #[error("candidate patches are disabled for semantic reranking")]
    CandidatePatch,
    #[error("abstention must not contain candidate IDs")]
    UnexpectedCandidates,
    #[error("semantic decision is missing candidates")]
    IncompleteCandidateSet,
    #[error("semantic decision repeats a candidate ID")]
    DuplicateCandidate,
    #[error("semantic decision contains an unknown candidate ID")]
    UnknownCandidate(i32),
    #[error("semantic decision moves a candidate too far")]
    MovementTooLarge,
    #[error("the current candidate set no longer matches the snapshot")]
    CandidateSetChanged,
    #[error("candidate input is malformed or unbounded")]
    InvalidInput,
    #[error("candidate IDs are duplicated in the baseline")]
    DuplicateInputCandidate,
    #[error("fewer than two candidates are available for reranking")]
    InsufficientCandidates,
}

impl RerankRejection {
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::MozcOnly => "mozcOnly",
            Self::PolicyDisabled => "policyDisabled",
            Self::StaleGeneration => "staleGeneration",
            Self::WrongModelRevision => "wrongModelRevision",
            Self::WrongLearningVersion => "wrongLearningVersion",
            Self::WrongModelTier => "wrongModelTier",
            Self::WrongInputRevision => "wrongInputRevision",
            Self::InvalidConfidence => "invalidConfidence",
            Self::LowConfidence => "lowConfidence",
            Self::InvalidReason => "invalidReason",
            Self::CandidatePatch => "candidatePatch",
            Self::UnexpectedCandidates => "unexpectedCandidates",
            Self::IncompleteCandidateSet => "incompleteCandidateSet",
            Self::DuplicateCandidate => "duplicateCandidate",
            Self::UnknownCandidate(_) => "unknownCandidate",
            Self::MovementTooLarge => "movementTooLarge",
            Self::CandidateSetChanged => "candidateSetChanged",
            Self::InvalidInput => "invalidInput",
            Self::DuplicateInputCandidate => "duplicateInputCandidate",
            Self::InsufficientCandidates => "insufficientCandidates",
        }
    }
}

/// Provider/transport errors that must leave the already-returned Mozc or fast
/// result untouched. There is deliberately no inline retry variant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SemanticProviderError {
    #[error("local semantic request timed out")]
    TimedOut,
    #[error("local semantic provider is unavailable")]
    Unavailable,
    #[error("local semantic request was cancelled")]
    Cancelled,
    #[error("local semantic provider returned malformed output")]
    MalformedResponse,
}

impl SemanticProviderError {
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::TimedOut => "providerTimeout",
            Self::Unavailable => "providerUnavailable",
            Self::Cancelled => "cancelled",
            Self::MalformedResponse => "malformedResponse",
        }
    }
}

/// Content-free snapshot captured before an off-key-path provider request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SemanticRerankSnapshot {
    session_id: u64,
    generation: u64,
    tier: ModelTier,
    model_revision: u64,
    learning_version: u64,
    input_revision: u64,
    candidate_ids: CandidateIdOrder,
    candidate_fingerprints: [CandidateFingerprint; MAX_LOCAL_QUALITY_CANDIDATES],
    max_rank_shift: usize,
    uses_context: bool,
    cache_key: CacheKey,
}

impl SemanticRerankSnapshot {
    #[must_use]
    pub const fn session_id(self) -> u64 {
        self.session_id
    }

    #[must_use]
    pub const fn generation(self) -> u64 {
        self.generation
    }

    #[must_use]
    pub const fn tier(self) -> ModelTier {
        self.tier
    }

    #[must_use]
    pub const fn model_revision(self) -> u64 {
        self.model_revision
    }

    #[must_use]
    pub const fn learning_version(self) -> u64 {
        self.learning_version
    }

    #[must_use]
    pub const fn input_revision(self) -> u64 {
        self.input_revision
    }

    #[must_use]
    pub const fn candidate_ids(self) -> CandidateIdOrder {
        self.candidate_ids
    }

    #[must_use]
    pub const fn len(self) -> usize {
        self.candidate_ids.len()
    }

    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.candidate_ids.is_empty()
    }

    #[must_use]
    pub const fn uses_context(self) -> bool {
        self.uses_context
    }

    fn matches_candidates(self, candidates: &[PersonalizedCandidate]) -> bool {
        let len = self.len();
        if candidates.len() < len {
            return false;
        }
        self.candidate_ids.iter().enumerate().all(|(index, id)| {
            candidates[index].candidate.id == id
                && candidate_fingerprint(&candidates[index]) == self.candidate_fingerprints[index]
        })
    }
}

/// Current admission facts read immediately before atomic adoption. The broker
/// must obtain these while holding the same session lock/generation epoch used
/// to mutate candidate state.
#[derive(Debug)]
pub struct SemanticRerankAdmission<'a> {
    pub current_generation: Option<u64>,
    pub current_model_revision: u64,
    pub current_learning_version: u64,
    pub candidates: &'a mut [PersonalizedCandidate],
}

impl<'a> SemanticRerankAdmission<'a> {
    #[must_use]
    pub const fn new(
        current_generation: Option<u64>,
        current_model_revision: u64,
        current_learning_version: u64,
        candidates: &'a mut [PersonalizedCandidate],
    ) -> Self {
        Self {
            current_generation,
            current_model_revision,
            current_learning_version,
            candidates,
        }
    }
}

/// A complete permutation validated against a snapshot. It contains no
/// candidate text/context and can therefore be held in the bounded cache.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SemanticRerankPlan {
    snapshot: SemanticRerankSnapshot,
    candidate_ids: CandidateIdOrder,
    changed_positions: u16,
}

impl SemanticRerankPlan {
    #[must_use]
    pub const fn is_abstain(self) -> bool {
        self.candidate_ids.is_empty()
    }

    #[must_use]
    pub const fn candidate_ids(self) -> CandidateIdOrder {
        self.candidate_ids
    }

    #[must_use]
    pub const fn changed_positions(self) -> u16 {
        self.changed_positions
    }

    /// Rechecks generation, revisions, and candidate fingerprints before the
    /// in-place permutation. No mutation occurs before all checks pass.
    pub fn apply(
        self,
        admission: SemanticRerankAdmission<'_>,
    ) -> Result<SemanticRerankApply, RerankRejection> {
        self.snapshot.check_admission(
            admission.current_generation,
            admission.current_model_revision,
            admission.current_learning_version,
            admission.candidates,
        )?;
        if self.is_abstain() {
            return Ok(SemanticRerankApply::Abstained);
        }
        let order = self.candidate_ids.resolve(
            self.snapshot.candidate_ids.as_slice(),
            self.snapshot.max_rank_shift,
        )?;
        let changed = apply_index_order(admission.candidates, order)?;
        debug_assert_eq!(changed, self.changed_positions);
        Ok(SemanticRerankApply::Applied {
            changed_positions: changed,
        })
    }
}

impl SemanticRerankSnapshot {
    fn check_admission(
        self,
        current_generation: Option<u64>,
        current_model_revision: u64,
        current_learning_version: u64,
        candidates: &[PersonalizedCandidate],
    ) -> Result<(), RerankRejection> {
        if current_generation != Some(self.generation) {
            return Err(RerankRejection::StaleGeneration);
        }
        if current_model_revision != self.model_revision {
            return Err(RerankRejection::WrongModelRevision);
        }
        if current_learning_version != self.learning_version {
            return Err(RerankRejection::WrongLearningVersion);
        }
        if !self.matches_candidates(candidates) {
            return Err(RerankRejection::CandidateSetChanged);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SemanticRerankApply {
    Applied { changed_positions: u16 },
    Abstained,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SemanticRerankResolution {
    Applied { changed_positions: u16 },
    Abstained,
    Fallback(SemanticProviderError),
    Rejected(RerankRejection),
}

impl SemanticRerankResolution {
    #[must_use]
    pub const fn is_applied(self) -> bool {
        matches!(self, Self::Applied { .. })
    }

    #[must_use]
    pub const fn preserved_baseline(self) -> bool {
        match self {
            Self::Applied { changed_positions } => changed_positions == 0,
            Self::Abstained | Self::Fallback(_) | Self::Rejected(_) => true,
        }
    }

    #[must_use]
    pub const fn reason_code(self) -> &'static str {
        match self {
            Self::Applied { .. } => "applied",
            Self::Abstained => "abstain",
            Self::Fallback(error) => error.code(),
            Self::Rejected(rejection) => rejection.code(),
        }
    }
}

/// Stateful, synchronous policy/cache. It performs no I/O and owns no task or
/// timer that can block a key callback. A broker can call `rank_fast` on its
/// bounded candidate path and run semantic assist separately.
#[derive(Debug)]
pub struct LocalQualityEngine {
    config: LocalQualityConfig,
    fast_cache: VecDeque<FastCacheEntry>,
    semantic_cache: VecDeque<SemanticCacheEntry>,
    fast_cache_limit: usize,
    semantic_cache_limit: usize,
}

impl Default for LocalQualityEngine {
    fn default() -> Self {
        Self::new(LocalQualityConfig::default())
    }
}

impl LocalQualityEngine {
    #[must_use]
    pub fn new(config: LocalQualityConfig) -> Self {
        let semantic_capacity = config.cache_capacity / 2;
        let fast_capacity = config.cache_capacity - semantic_capacity;
        Self {
            config,
            fast_cache: VecDeque::with_capacity(fast_capacity),
            semantic_cache: VecDeque::with_capacity(semantic_capacity),
            fast_cache_limit: fast_capacity,
            semantic_cache_limit: semantic_capacity,
        }
    }

    #[must_use]
    pub fn mozc_only() -> Self {
        Self::new(LocalQualityConfig::new(LocalDataPolicy::MozcBaseline))
    }

    #[must_use]
    pub const fn config(&self) -> LocalQualityConfig {
        self.config
    }

    #[must_use]
    pub fn cache_entries(&self) -> usize {
        self.fast_cache
            .len()
            .saturating_add(self.semantic_cache.len())
    }

    /// Context-derived fingerprints and decisions are process-local and
    /// generation-scoped. Call this on focus loss, Protect Mode, logout, and
    /// profile/model switches.
    pub fn clear_cache(&mut self) {
        self.fast_cache.clear();
        self.semantic_cache.clear();
    }

    /// Deterministically scores a bounded prefix and reorders it in place.
    /// Every fallback is detected before mutation, so callers can retain this
    /// function's result as the Mozc/fast baseline without a defensive clone.
    pub fn rank_fast(
        &mut self,
        candidates: &mut [PersonalizedCandidate],
        request: &LocalQualityRequest<'_>,
    ) -> FastRankOutcome {
        let started = Instant::now();
        let evaluated = candidates
            .len()
            .min(self.config.max_candidates)
            .min(u16::MAX as usize) as u16;

        macro_rules! fast_fallback {
            ($status:expr) => {
                return self.fast_outcome($status, 0, evaluated, started)
            };
        }
        if request.tier == ModelTier::MozcOnly {
            fast_fallback!(FastRankStatus::MozcOnly);
        }
        if self.config.data_policy == LocalDataPolicy::MozcBaseline {
            fast_fallback!(FastRankStatus::PolicyDisabled);
        }
        if request.current_generation.is_none() {
            fast_fallback!(FastRankStatus::SessionEnded);
        }
        if request.current_generation != Some(request.generation) {
            fast_fallback!(FastRankStatus::StaleGeneration);
        }
        if evaluated < 2 {
            fast_fallback!(FastRankStatus::InsufficientCandidates);
        }
        if !valid_reading(request.reading) {
            fast_fallback!(FastRankStatus::InvalidInput);
        }
        if let Err(error) = validate_candidate_window(&candidates[..evaluated as usize]) {
            fast_fallback!(match error {
                RerankRejection::DuplicateInputCandidate => FastRankStatus::DuplicateCandidateIds,
                _ => FastRankStatus::InvalidInput,
            });
        }
        if self.fast_deadline_reached(started) {
            fast_fallback!(FastRankStatus::DeadlineExceeded);
        }

        let context = self.context_for(request);
        let ids = candidate_ids(&candidates[..evaluated as usize]);
        let cache_key = input_cache_key(
            CacheOperation::FastRank,
            request,
            &self.config,
            &context,
            ids,
            &candidates[..evaluated as usize],
        );

        if let Some(order) = lookup_fast_cache(&mut self.fast_cache, cache_key)
            && let Ok(index_order) = order.resolve(ids.as_slice(), self.config.max_rank_shift)
            && !self.fast_deadline_reached(started)
            && let Ok(changed) = apply_index_order(candidates, index_order)
        {
            let status = if changed > 0 {
                FastRankStatus::CacheHit
            } else {
                FastRankStatus::Unchanged
            };
            return self.fast_outcome(status, changed, evaluated, started);
        }

        let window = &candidates[..evaluated as usize];
        let mut scored = [ScoredCandidate::default(); MAX_LOCAL_QUALITY_CANDIDATES];
        for (old_index, candidate) in window.iter().enumerate() {
            if self.fast_deadline_reached(started) {
                fast_fallback!(FastRankStatus::DeadlineExceeded);
            }
            let score = fast_score(request.reading.trim(), &context, candidate);
            if !score.is_finite() {
                fast_fallback!(FastRankStatus::InvalidInput);
            }
            scored[old_index] = ScoredCandidate { old_index, score };
        }
        scored[..window.len()].sort_unstable_by(|left, right| {
            right
                .score
                .total_cmp(&left.score)
                .then_with(|| left.old_index.cmp(&right.old_index))
        });
        let index_order = IndexOrder::from_scored(&scored, window.len());
        if index_order
            .old_indices
            .iter()
            .copied()
            .take(window.len())
            .enumerate()
            .any(|(new_index, old_index)| {
                old_index.abs_diff(new_index) > self.config.max_rank_shift
            })
        {
            fast_fallback!(FastRankStatus::RankShiftTooLarge);
        }
        if self.fast_deadline_reached(started) {
            fast_fallback!(FastRankStatus::DeadlineExceeded);
        }

        let cache_order = index_order.ids(window);
        let changed = apply_index_order(candidates, index_order)
            .expect("a freshly constructed permutation is complete");
        insert_fast_cache(
            &mut self.fast_cache,
            self.fast_cache_limit,
            cache_key,
            cache_order,
        );
        let status = if changed > 0 {
            FastRankStatus::Applied
        } else {
            FastRankStatus::Unchanged
        };
        self.fast_outcome(status, changed, evaluated, started)
    }

    /// Captures the exact bounded input identity without retaining reading,
    /// context, candidate values, or history. The caller may use its existing
    /// baseline to construct a privacy-reviewed local model request.
    pub fn capture_semantic_rerank(
        &self,
        request: &LocalQualityRequest<'_>,
        candidates: &[PersonalizedCandidate],
    ) -> Result<SemanticRerankSnapshot, RerankRejection> {
        if request.tier == ModelTier::MozcOnly {
            return Err(RerankRejection::MozcOnly);
        }
        if self.config.data_policy == LocalDataPolicy::MozcBaseline {
            return Err(RerankRejection::PolicyDisabled);
        }
        if request.current_generation != Some(request.generation) {
            return Err(RerankRejection::StaleGeneration);
        }
        if !valid_reading(request.reading) {
            return Err(RerankRejection::InvalidInput);
        }
        let len = candidates.len().min(self.config.max_candidates);
        if len < 2 {
            return Err(RerankRejection::InsufficientCandidates);
        }
        validate_candidate_window(&candidates[..len])?;

        let context = self.context_for(request);
        let ids = candidate_ids(&candidates[..len]);
        let cache_key = input_cache_key(
            CacheOperation::SemanticRerank,
            request,
            &self.config,
            &context,
            ids,
            &candidates[..len],
        );
        let mut fingerprints = [CandidateFingerprint::default(); MAX_LOCAL_QUALITY_CANDIDATES];
        for (index, candidate) in candidates[..len].iter().enumerate() {
            fingerprints[index] = candidate_fingerprint(candidate);
        }

        Ok(SemanticRerankSnapshot {
            session_id: request.session_id,
            generation: request.generation,
            tier: request.tier,
            model_revision: request.model_revision,
            learning_version: request.learning_version,
            input_revision: cache_key.primary,
            candidate_ids: ids,
            candidate_fingerprints: fingerprints,
            max_rank_shift: self.config.max_rank_shift,
            uses_context: !context.is_empty(),
            cache_key,
        })
    }

    /// Returns a complete plan only for the exact session, generation, model,
    /// learning, context, and candidate snapshot. Call before dispatching a
    /// local model request; a hit requires no provider call.
    pub fn cached_semantic_rerank(
        &mut self,
        snapshot: &SemanticRerankSnapshot,
    ) -> Option<SemanticRerankPlan> {
        let plan = lookup_semantic_cache(&mut self.semantic_cache, snapshot.cache_key)?;
        (plan.snapshot.cache_key == snapshot.cache_key).then_some(plan)
    }

    /// Maps a bounded provider result to an atomic in-place decision. Timeout,
    /// cancellation, absence, malformed output, and every validation failure
    /// preserve the current candidate slice.
    pub fn resolve_semantic_rerank(
        &mut self,
        snapshot: SemanticRerankSnapshot,
        admission: SemanticRerankAdmission<'_>,
        provider_result: Result<SemanticRerankDecision, SemanticProviderError>,
    ) -> SemanticRerankResolution {
        if let Some(plan) = self.cached_semantic_rerank(&snapshot) {
            return match plan.apply(admission) {
                Ok(SemanticRerankApply::Applied { changed_positions }) => {
                    SemanticRerankResolution::Applied { changed_positions }
                }
                Ok(SemanticRerankApply::Abstained) => SemanticRerankResolution::Abstained,
                Err(rejection) => SemanticRerankResolution::Rejected(rejection),
            };
        }

        let decision = match provider_result {
            Ok(decision) => decision,
            Err(error) => return SemanticRerankResolution::Fallback(error),
        };
        let plan = match validate_semantic_rerank(&decision, snapshot, &admission) {
            Ok(plan) => plan,
            Err(rejection) => return SemanticRerankResolution::Rejected(rejection),
        };
        let resolution = match plan.apply(admission) {
            Ok(SemanticRerankApply::Applied { changed_positions }) => {
                SemanticRerankResolution::Applied { changed_positions }
            }
            Ok(SemanticRerankApply::Abstained) => SemanticRerankResolution::Abstained,
            Err(rejection) => return SemanticRerankResolution::Rejected(rejection),
        };
        insert_semantic_cache(
            &mut self.semantic_cache,
            self.semantic_cache_limit,
            snapshot.cache_key,
            plan,
        );
        resolution
    }

    fn context_for(&self, request: &LocalQualityRequest<'_>) -> BoundedLocalContext {
        self.config
            .bound_context(request.context_before, request.context_after)
    }

    fn fast_deadline_reached(&self, started: Instant) -> bool {
        started.elapsed() >= self.config.fast_deadline
    }

    fn fast_outcome(
        &self,
        status: FastRankStatus,
        changed_positions: u16,
        evaluated_candidates: u16,
        started: Instant,
    ) -> FastRankOutcome {
        FastRankOutcome {
            status,
            changed_positions,
            evaluated_candidates,
            cache_entries: self.cache_entries().min(u16::MAX as usize) as u16,
            elapsed_micros: started.elapsed().as_micros().min(u128::from(u64::MAX)) as u64,
        }
    }
}

fn validate_semantic_rerank(
    decision: &SemanticRerankDecision,
    snapshot: SemanticRerankSnapshot,
    admission: &SemanticRerankAdmission<'_>,
) -> Result<SemanticRerankPlan, RerankRejection> {
    snapshot.check_admission(
        admission.current_generation,
        admission.current_model_revision,
        admission.current_learning_version,
        admission.candidates,
    )?;
    if decision.expires_at_generation != snapshot.generation {
        return Err(RerankRejection::StaleGeneration);
    }
    if decision.input_revision != snapshot.input_revision {
        return Err(RerankRejection::WrongInputRevision);
    }
    if decision.model_revision != snapshot.model_revision {
        return Err(RerankRejection::WrongModelRevision);
    }
    if decision.learning_version != snapshot.learning_version {
        return Err(RerankRejection::WrongLearningVersion);
    }
    if decision.model_tier != snapshot.tier {
        return Err(RerankRejection::WrongModelTier);
    }
    if !decision.confidence.is_finite() || !(0.0..=1.0).contains(&decision.confidence) {
        return Err(RerankRejection::InvalidConfidence);
    }
    if decision.patch.is_some() {
        return Err(RerankRejection::CandidatePatch);
    }

    match decision.action {
        SemanticRerankAction::Abstain => {
            if !decision.candidate_ids.is_empty() {
                return Err(RerankRejection::UnexpectedCandidates);
            }
            if decision.reason != SemanticRerankReason::Abstain {
                return Err(RerankRejection::InvalidReason);
            }
            Ok(SemanticRerankPlan {
                snapshot,
                candidate_ids: decision.candidate_ids,
                changed_positions: 0,
            })
        }
        SemanticRerankAction::Rerank => {
            if decision.reason == SemanticRerankReason::Abstain {
                return Err(RerankRejection::InvalidReason);
            }
            if decision.confidence < MIN_SEMANTIC_RERANK_CONFIDENCE {
                return Err(RerankRejection::LowConfidence);
            }
            let order = decision
                .candidate_ids
                .resolve(snapshot.candidate_ids.as_slice(), snapshot.max_rank_shift)?;
            Ok(SemanticRerankPlan {
                snapshot,
                candidate_ids: decision.candidate_ids,
                changed_positions: order.changed_positions,
            })
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct ScoredCandidate {
    old_index: usize,
    score: f64,
}

fn fast_score(
    reading: &str,
    context: &BoundedLocalContext,
    candidate: &PersonalizedCandidate,
) -> f64 {
    let context_affinity = if context.ends_with(&candidate.candidate.text) {
        FAST_CONTEXT_SUFFIX_BONUS
    } else if context.contains(&candidate.candidate.text) {
        FAST_CONTEXT_CONTAINS_BONUS
    } else {
        0.0
    };
    let reading_match = if candidate
        .candidate
        .reading
        .as_deref()
        .is_some_and(|candidate_reading| candidate_reading.trim() == reading)
    {
        FAST_READING_BONUS
    } else {
        0.0
    };
    let source_prior = match candidate.candidate.origin {
        CandidateOrigin::TypingCorrection | CandidateOrigin::SpellingCorrection => 8.0,
        CandidateOrigin::UserHistory => 4.0,
        CandidateOrigin::UserDictionary => 3.0,
        CandidateOrigin::Suggestion => -4.0,
        CandidateOrigin::Conversion | CandidateOrigin::Prediction | CandidateOrigin::Unknown(_) => {
            0.0
        }
    };
    candidate.score + context_affinity + reading_match + source_prior
}

fn valid_reading(reading: &str) -> bool {
    let reading = reading.trim();
    !reading.is_empty()
        && reading.len() <= MAX_READING_BYTES
        && reading.chars().count() <= MAX_READING_CHARS
        && !reading.chars().any(char::is_control)
}

fn valid_candidate_text(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_CANDIDATE_TEXT_BYTES
        && value.chars().count() <= MAX_CANDIDATE_TEXT_CHARS
        && !value.chars().any(char::is_control)
}

fn validate_candidate_window(candidates: &[PersonalizedCandidate]) -> Result<(), RerankRejection> {
    for (index, candidate) in candidates.iter().enumerate() {
        if !valid_candidate_text(&candidate.candidate.text) {
            return Err(RerankRejection::InvalidInput);
        }
        if candidate
            .candidate
            .reading
            .as_deref()
            .is_some_and(|reading| !valid_reading(reading))
        {
            return Err(RerankRejection::InvalidInput);
        }
        for previous in &candidates[..index] {
            if previous.candidate.id == candidate.candidate.id {
                return Err(RerankRejection::DuplicateInputCandidate);
            }
        }
    }
    Ok(())
}

fn candidate_ids(candidates: &[PersonalizedCandidate]) -> CandidateIdOrder {
    let mut ids = [0_i32; MAX_LOCAL_QUALITY_CANDIDATES];
    for (index, candidate) in candidates.iter().enumerate() {
        ids[index] = candidate.candidate.id;
    }
    CandidateIdOrder {
        ids,
        len: candidates.len() as u8,
    }
}

/// Fixed-size normalized context. It contains at most 32 scalars, never a
/// newline/control character, and is discarded when the stack frame returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoundedLocalContext {
    values: [char; MAX_LOCAL_QUALITY_CONTEXT_CHARS],
    len: u8,
    before_len: u8,
}

impl BoundedLocalContext {
    const EMPTY: Self = Self {
        values: ['\0'; MAX_LOCAL_QUALITY_CONTEXT_CHARS],
        len: 0,
        before_len: 0,
    };

    fn bounded(before: &str, after: &str, limit: usize) -> Self {
        if limit == 0 {
            return Self::EMPTY;
        }
        let limit = limit.min(MAX_LOCAL_QUALITY_CONTEXT_CHARS);
        let mut values = ['\0'; MAX_LOCAL_QUALITY_CONTEXT_CHARS];
        let mut len = 0_usize;

        // Read only a bounded tail. A hostile input containing a long run of
        // controls cannot turn normalization into an unbounded scan.
        let scan_limit = limit.saturating_mul(4).max(limit);
        let mut reversed = ['\0'; MAX_LOCAL_QUALITY_CONTEXT_CHARS];
        let mut reversed_len = 0_usize;
        let mut pending_space = false;
        for character in before.chars().rev().take(scan_limit) {
            if character.is_control() || character.is_whitespace() {
                if reversed_len > 0 {
                    pending_space = true;
                }
                continue;
            }
            if pending_space && reversed_len > 0 {
                reversed[reversed_len] = ' ';
                reversed_len += 1;
                pending_space = false;
                if reversed_len == limit {
                    break;
                }
            }
            reversed[reversed_len] = character;
            reversed_len += 1;
            if reversed_len == limit {
                break;
            }
        }
        while reversed_len > 0 {
            reversed_len -= 1;
            values[len] = reversed[reversed_len];
            len += 1;
        }
        let before_len = len as u8;

        for character in after.chars().take(scan_limit) {
            if len == limit {
                break;
            }
            if character.is_control() || character.is_whitespace() {
                if len > 0 {
                    pending_space = true;
                }
                continue;
            }
            if pending_space {
                values[len] = ' ';
                len += 1;
                pending_space = false;
                if len == limit {
                    break;
                }
            }
            values[len] = character;
            len += 1;
        }

        Self {
            values,
            len: len as u8,
            before_len,
        }
    }

    #[must_use]
    pub const fn len(self) -> usize {
        self.len as usize
    }

    #[must_use]
    pub const fn before_len(self) -> usize {
        self.before_len as usize
    }

    #[must_use]
    pub fn as_chars(&self) -> &[char] {
        &self.values[..self.len as usize]
    }

    pub fn iter(&self) -> impl ExactSizeIterator<Item = char> + '_ {
        self.as_chars().iter().copied()
    }

    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.len == 0
    }

    fn ends_with(self, suffix: &str) -> bool {
        let mut end = self.before_len as usize;
        while end > 0 && self.values[end - 1] == ' ' {
            end -= 1;
        }
        let mut suffix = suffix.chars().rev();
        let Some(first) = suffix.next() else {
            return false;
        };
        if end == 0 || self.values[end - 1] != first {
            return false;
        }
        end -= 1;
        for expected in suffix {
            if end == 0 || self.values[end - 1] != expected {
                return false;
            }
            end -= 1;
        }
        true
    }

    fn contains(self, needle: &str) -> bool {
        let needle_len = needle.chars().count();
        if needle_len == 0 || needle_len > self.len as usize {
            return false;
        }
        for start in 0..=self.len as usize - needle_len {
            let matches = self.values[start..start + needle_len]
                .iter()
                .copied()
                .zip(needle.chars())
                .all(|(actual, expected)| actual == expected);
            if matches {
                return true;
            }
        }
        false
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct CacheKey {
    primary: u64,
    secondary: u64,
}

#[derive(Debug, Clone, Copy)]
enum CacheOperation {
    FastRank,
    SemanticRerank,
}

#[derive(Debug, Clone, Copy)]
struct FastCacheEntry {
    key: CacheKey,
    order: CandidateIdOrder,
}

#[derive(Debug, Clone, Copy)]
struct SemanticCacheEntry {
    key: CacheKey,
    plan: SemanticRerankPlan,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct CandidateFingerprint {
    primary: u64,
    secondary: u64,
}

fn input_cache_key(
    operation: CacheOperation,
    request: &LocalQualityRequest<'_>,
    config: &LocalQualityConfig,
    context: &BoundedLocalContext,
    ids: CandidateIdOrder,
    candidates: &[PersonalizedCandidate],
) -> CacheKey {
    let mut primary = DefaultHasher::new();
    let mut secondary = DefaultHasher::new();

    hash_cache_header(
        &mut primary,
        &mut secondary,
        operation,
        request,
        config,
        context,
    );
    ids.len().hash(&mut primary);
    ids.len().hash(&mut secondary);
    for id in ids.iter() {
        id.hash(&mut primary);
        id.hash(&mut secondary);
    }
    for candidate in candidates {
        let fingerprint = candidate_fingerprint(candidate);
        fingerprint.primary.hash(&mut primary);
        fingerprint.secondary.hash(&mut secondary);
    }
    CacheKey {
        primary: primary.finish(),
        secondary: secondary.finish(),
    }
}

fn hash_cache_header(
    primary: &mut DefaultHasher,
    secondary: &mut DefaultHasher,
    operation: CacheOperation,
    request: &LocalQualityRequest<'_>,
    config: &LocalQualityConfig,
    context: &BoundedLocalContext,
) {
    let operation_code = match operation {
        CacheOperation::FastRank => 1_u8,
        CacheOperation::SemanticRerank => 2_u8,
    };
    operation_code.hash(primary);
    operation_code.hash(secondary);
    request.session_id.hash(primary);
    request.session_id.hash(secondary);
    request.generation.hash(primary);
    request.generation.hash(secondary);
    request.model_revision.hash(primary);
    request.model_revision.hash(secondary);
    request.learning_version.hash(primary);
    request.learning_version.hash(secondary);
    model_tier_code(request.tier).hash(primary);
    model_tier_code(request.tier).hash(secondary);
    local_data_policy_code(config.data_policy).hash(primary);
    local_data_policy_code(config.data_policy).hash(secondary);
    config.max_candidates.hash(primary);
    config.max_candidates.hash(secondary);
    config.max_rank_shift.hash(primary);
    config.max_rank_shift.hash(secondary);
    config.max_context_chars.hash(primary);
    config.max_context_chars.hash(secondary);
    config.policy_revision.hash(primary);
    config.policy_revision.hash(secondary);
    request.reading.trim().hash(primary);
    request.reading.trim().hash(secondary);
    context.len.hash(primary);
    context.len.hash(secondary);
    context.before_len.hash(primary);
    context.before_len.hash(secondary);
    for character in context.values.iter().copied().take(context.len as usize) {
        character.hash(primary);
        character.hash(secondary);
    }
}

fn candidate_fingerprint(candidate: &PersonalizedCandidate) -> CandidateFingerprint {
    let mut primary = DefaultHasher::new();
    let mut secondary = DefaultHasher::new();
    candidate.candidate.id.hash(&mut primary);
    candidate.candidate.id.hash(&mut secondary);
    candidate.candidate.text.hash(&mut primary);
    candidate.candidate.text.hash(&mut secondary);
    candidate.candidate.reading.hash(&mut primary);
    candidate.candidate.reading.hash(&mut secondary);
    candidate.candidate.provider_rank.hash(&mut primary);
    candidate.candidate.provider_rank.hash(&mut secondary);
    candidate.score.to_bits().hash(&mut primary);
    candidate.score.to_bits().hash(&mut secondary);
    candidate_origin_code(&candidate.candidate.origin).hash(&mut primary);
    candidate_origin_code(&candidate.candidate.origin).hash(&mut secondary);
    CandidateFingerprint {
        primary: primary.finish(),
        secondary: secondary.finish(),
    }
}

const fn model_tier_code(tier: ModelTier) -> u8 {
    match tier {
        ModelTier::MozcOnly => 0,
        ModelTier::Tiny => 1,
        ModelTier::Compact => 2,
        ModelTier::Balanced => 3,
    }
}

const fn local_data_policy_code(policy: LocalDataPolicy) -> u8 {
    match policy {
        LocalDataPolicy::MozcBaseline => 0,
        LocalDataPolicy::CandidateFeatures => 1,
        LocalDataPolicy::BoundedContext => 2,
    }
}

const fn candidate_origin_code(origin: &CandidateOrigin) -> u8 {
    match origin {
        CandidateOrigin::Conversion => 0,
        CandidateOrigin::Prediction => 1,
        CandidateOrigin::Suggestion => 2,
        CandidateOrigin::UserDictionary => 3,
        CandidateOrigin::UserHistory => 4,
        CandidateOrigin::TypingCorrection => 5,
        CandidateOrigin::SpellingCorrection => 6,
        CandidateOrigin::Unknown(_) => 7,
    }
}

fn lookup_fast_cache(
    cache: &mut VecDeque<FastCacheEntry>,
    key: CacheKey,
) -> Option<CandidateIdOrder> {
    let index = cache.iter().position(|entry| entry.key == key)?;
    let entry = cache.remove(index)?;
    cache.push_back(entry);
    Some(entry.order)
}

fn insert_fast_cache(
    cache: &mut VecDeque<FastCacheEntry>,
    max_entries: usize,
    key: CacheKey,
    order: CandidateIdOrder,
) {
    if max_entries == 0 {
        return;
    }
    if let Some(index) = cache.iter().position(|entry| entry.key == key) {
        cache.remove(index);
    }
    while cache.len() >= max_entries {
        cache.pop_front();
    }
    cache.push_back(FastCacheEntry { key, order });
}

fn lookup_semantic_cache(
    cache: &mut VecDeque<SemanticCacheEntry>,
    key: CacheKey,
) -> Option<SemanticRerankPlan> {
    let index = cache.iter().position(|entry| entry.key == key)?;
    let entry = cache.remove(index)?;
    cache.push_back(entry);
    Some(entry.plan)
}

fn insert_semantic_cache(
    cache: &mut VecDeque<SemanticCacheEntry>,
    max_entries: usize,
    key: CacheKey,
    plan: SemanticRerankPlan,
) {
    if max_entries == 0 {
        return;
    }
    if let Some(index) = cache.iter().position(|entry| entry.key == key) {
        cache.remove(index);
    }
    while cache.len() >= max_entries {
        cache.pop_front();
    }
    cache.push_back(SemanticCacheEntry { key, plan });
}

#[cfg(test)]
mod tests {
    use super::{
        CandidateIdOrder, FastRankStatus, LocalDataPolicy, LocalQualityConfig, LocalQualityEngine,
        LocalQualityRequest, MAX_FAST_RANK_DEADLINE, MAX_LOCAL_QUALITY_CACHE_ENTRIES, ModelTier,
        RerankRejection, SemanticProviderError, SemanticRerankAction, SemanticRerankAdmission,
        SemanticRerankDecision, SemanticRerankReason, SemanticRerankResolution,
    };
    use crate::{
        CandidateAdjustments, CandidateOrigin, ConversionCandidate, PersonalizedCandidate,
    };

    use std::time::Duration;

    fn candidate(id: i32, text: &str, score: f64) -> PersonalizedCandidate {
        PersonalizedCandidate {
            candidate: ConversionCandidate {
                id,
                text: text.to_owned(),
                reading: None,
                provider_rank: id as usize,
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

    fn sample_candidates() -> Vec<PersonalizedCandidate> {
        vec![
            candidate(10, "default", 100.0),
            candidate(20, "東京", 99.0),
            candidate(30, "京都", 98.0),
        ]
    }

    fn request<'a>(reading: &'a str, context: &'a str) -> LocalQualityRequest<'a> {
        LocalQualityRequest::new(7, 42, Some(42), ModelTier::Compact, reading)
            .with_context(context, "")
            .with_revisions(0x1234, 9)
    }

    fn for_each_permutation(values: &mut [i32], start: usize, visit: &mut impl FnMut(&[i32])) {
        if start == values.len() {
            visit(values);
            return;
        }
        for index in start..values.len() {
            values.swap(start, index);
            for_each_permutation(values, start + 1, visit);
            values.swap(start, index);
        }
    }

    fn semantic_decision(
        snapshot: &super::SemanticRerankSnapshot,
        ids: &[i32],
    ) -> SemanticRerankDecision {
        SemanticRerankDecision {
            action: SemanticRerankAction::Rerank,
            candidate_ids: CandidateIdOrder::from_slice(ids).expect("bounded order"),
            patch: None,
            confidence: 0.9,
            reason: SemanticRerankReason::AmbiguousHomophone,
            model_tier: ModelTier::Compact,
            expires_at_generation: snapshot.generation(),
            input_revision: snapshot.input_revision(),
            model_revision: snapshot.model_revision(),
            learning_version: snapshot.learning_version(),
        }
    }

    #[test]
    fn low_memory_devices_never_receive_a_generative_model() {
        assert_eq!(super::recommend_tier(2, 8), ModelTier::MozcOnly);
        assert_eq!(super::recommend_tier(3, 16), ModelTier::MozcOnly);
    }

    #[test]
    fn recommendation_considers_cpu_and_memory() {
        assert_eq!(super::recommend_tier(4, 2), ModelTier::Tiny);
        assert_eq!(super::recommend_tier(4, 4), ModelTier::Compact);
        assert_eq!(super::recommend_tier(8, 4), ModelTier::Balanced);
    }

    #[test]
    fn free_memory_can_force_the_safe_tier() {
        assert_eq!(
            super::recommend_tier_for_memory(16, 1, 16),
            ModelTier::MozcOnly
        );
        assert_eq!(super::recommend_tier_for_memory(4, 2, 8), ModelTier::Tiny);
    }

    #[test]
    fn model_profiles_keep_mozc_only_as_the_zero_model_baseline() {
        let profiles = super::ModelProfile::all();
        assert_eq!(profiles[0].tier, ModelTier::MozcOnly);
        assert_eq!(profiles[0].approximate_model_mib, 0);
        assert_eq!(profiles[0].recommended_ram_gib, 0);
        assert!(
            profiles[1..]
                .iter()
                .all(|profile| profile.approximate_model_mib > 0)
        );
    }

    #[test]
    fn mozc_only_and_baseline_policy_are_no_ops() {
        let mut candidates = sample_candidates();
        let original = candidates.clone();
        let mut engine = LocalQualityEngine::mozc_only();
        let mut mozc_request = request("きょう", "");
        mozc_request.tier = ModelTier::MozcOnly;
        let outcome = engine.rank_fast(&mut candidates, &mozc_request);
        assert_eq!(outcome.status, FastRankStatus::MozcOnly);
        assert_eq!(candidates, original);

        let mut engine =
            LocalQualityEngine::new(LocalQualityConfig::new(LocalDataPolicy::MozcBaseline));
        let outcome = engine.rank_fast(&mut candidates, &request("きょう", ""));
        assert_eq!(outcome.status, FastRankStatus::PolicyDisabled);
        assert_eq!(candidates, original);
    }

    #[test]
    fn context_is_explicitly_bounded_and_control_free() {
        let config =
            LocalQualityConfig::new(LocalDataPolicy::BoundedContext).with_limits(5, 2, 5, 0);
        let context = config.bound_context(" far\ncontext 東京", "只看这里");
        assert_eq!(context.len(), 5);
        assert!(context.iter().all(|character| !character.is_control()));
        assert!(context.iter().collect::<String>().contains("東京"));

        let baseline = LocalQualityConfig::new(LocalDataPolicy::MozcBaseline);
        assert!(baseline.bound_context("東京", "context").is_empty());
    }

    #[test]
    fn bounded_fast_policy_promotes_repeated_segment_and_hits_cache() {
        let mut engine =
            LocalQualityEngine::new(LocalQualityConfig::new(LocalDataPolicy::BoundedContext));
        let mut candidates = sample_candidates();
        let request = request("とうきょう", "昨日の東京で");
        let first = engine.rank_fast(&mut candidates, &request);
        assert_eq!(first.status, FastRankStatus::Applied);
        assert_eq!(candidates[0].candidate.id, 20);
        assert_eq!(first.changed_positions, 2);
        assert_eq!(engine.cache_entries(), 1);

        let mut cached_candidates = sample_candidates();
        let second = engine.rank_fast(&mut cached_candidates, &request);
        assert_eq!(second.status, FastRankStatus::CacheHit);
        assert_eq!(cached_candidates[0].candidate.id, 20);
    }

    #[test]
    fn cache_is_keyed_by_generation_learning_and_context() {
        let mut engine =
            LocalQualityEngine::new(LocalQualityConfig::new(LocalDataPolicy::BoundedContext));
        let mut candidates = sample_candidates();
        let base = request("とうきょう", "東京で");
        assert!(matches!(
            engine.rank_fast(&mut candidates, &base).status,
            FastRankStatus::Applied
        ));

        let mut next_generation_candidates = sample_candidates();
        let mut next_generation = base;
        next_generation.generation += 1;
        next_generation.current_generation = Some(next_generation.generation);
        assert_eq!(
            engine
                .rank_fast(&mut next_generation_candidates, &next_generation)
                .status,
            FastRankStatus::Applied
        );
        assert_eq!(engine.cache_entries(), 2);

        let mut changed_learning_candidates = sample_candidates();
        let mut changed_learning = base;
        changed_learning.learning_version += 1;
        engine.rank_fast(&mut changed_learning_candidates, &changed_learning);
        assert_eq!(engine.cache_entries(), 3);
    }

    #[test]
    fn cache_capacity_is_hard_bounded() {
        let config = LocalQualityConfig::new(LocalDataPolicy::CandidateFeatures)
            .with_limits(5, 2, 0, 2)
            .with_fast_deadline(MAX_FAST_RANK_DEADLINE);
        let mut engine = LocalQualityEngine::new(config);
        for generation in 0..8 {
            let mut candidates = sample_candidates();
            let mut current = request("きょう", "");
            current.generation = generation;
            current.current_generation = Some(generation);
            engine.rank_fast(&mut candidates, &current);
            assert!(engine.cache_entries() <= MAX_LOCAL_QUALITY_CACHE_ENTRIES);
            assert!(engine.cache_entries() <= 2);
        }
    }

    #[test]
    fn stale_duplicate_and_deadline_paths_do_not_mutate() {
        let config = LocalQualityConfig::new(LocalDataPolicy::BoundedContext)
            .with_fast_deadline(Duration::ZERO);
        let mut engine = LocalQualityEngine::new(config);
        let mut candidates = sample_candidates();
        let original = candidates.clone();

        let mut stale = request("きょう", "");
        stale.current_generation = Some(stale.generation + 1);
        assert_eq!(
            engine.rank_fast(&mut candidates, &stale).status,
            FastRankStatus::StaleGeneration
        );
        assert_eq!(candidates, original);

        let mut duplicate = sample_candidates();
        duplicate[1].candidate.id = duplicate[0].candidate.id;
        assert_eq!(
            engine
                .rank_fast(&mut duplicate, &request("きょう", ""))
                .status,
            FastRankStatus::DuplicateCandidateIds
        );
        assert_eq!(
            engine
                .rank_fast(&mut candidates, &request("きょう", ""))
                .status,
            FastRankStatus::DeadlineExceeded
        );
        assert_eq!(candidates, original);
    }

    #[test]
    fn semantic_snapshot_requires_local_policy_and_valid_ids() {
        let engine = LocalQualityEngine::mozc_only();
        let candidates = sample_candidates();
        let mut mozc_request = request("とうきょう", "");
        mozc_request.tier = ModelTier::MozcOnly;
        assert_eq!(
            engine
                .capture_semantic_rerank(&mozc_request, &candidates)
                .expect_err("MozcOnly must reject semantic work"),
            RerankRejection::MozcOnly
        );

        let engine =
            LocalQualityEngine::new(LocalQualityConfig::new(LocalDataPolicy::CandidateFeatures));
        let mut duplicate = candidates.clone();
        duplicate[1].candidate.id = duplicate[0].candidate.id;
        assert_eq!(
            engine
                .capture_semantic_rerank(&request("とうきょう", ""), &duplicate)
                .expect_err("duplicate baseline"),
            RerankRejection::DuplicateInputCandidate
        );
    }

    #[test]
    fn semantic_decision_reorders_only_after_complete_validation() {
        let mut engine =
            LocalQualityEngine::new(LocalQualityConfig::new(LocalDataPolicy::CandidateFeatures));
        let mut candidates = sample_candidates();
        let request = request("とうきょう", "");
        let snapshot = engine
            .capture_semantic_rerank(&request, &candidates)
            .expect("snapshot");
        let decision = semantic_decision(&snapshot, &[20, 10, 30]);
        let admission = SemanticRerankAdmission::new(Some(42), 0x1234, 9, &mut candidates);
        let resolution = engine.resolve_semantic_rerank(snapshot, admission, Ok(decision));
        assert!(matches!(
            resolution,
            SemanticRerankResolution::Applied {
                changed_positions: 2
            }
        ));
        assert_eq!(
            candidates
                .iter()
                .map(|item| item.candidate.id)
                .collect::<Vec<_>>(),
            vec![20, 10, 30]
        );
    }

    #[test]
    fn unknown_duplicate_and_oversized_moves_are_atomic_rejections() {
        let mut engine = LocalQualityEngine::new(
            LocalQualityConfig::new(LocalDataPolicy::CandidateFeatures).with_limits(5, 1, 0, 8),
        );
        let request = request("とうきょう", "");
        let invalid_orders: &[&[i32]] = &[&[20], &[20, 20, 30], &[20, 10, 999], &[30, 20, 10]];

        for ids in invalid_orders {
            let mut candidates = sample_candidates();
            let original = candidates.clone();
            let snapshot = engine
                .capture_semantic_rerank(&request, &candidates)
                .expect("snapshot");
            let decision = semantic_decision(&snapshot, ids);
            let admission = SemanticRerankAdmission::new(Some(42), 0x1234, 9, &mut candidates);
            let resolution = engine.resolve_semantic_rerank(snapshot, admission, Ok(decision));
            assert!(matches!(resolution, SemanticRerankResolution::Rejected(_)));
            assert_eq!(candidates, original);
        }
    }

    #[test]
    fn stale_model_and_provider_results_preserve_the_baseline() {
        let mut engine =
            LocalQualityEngine::new(LocalQualityConfig::new(LocalDataPolicy::CandidateFeatures));
        let request = request("とうきょう", "");
        let mut candidates = sample_candidates();
        let original = candidates.clone();
        let snapshot = engine
            .capture_semantic_rerank(&request, &candidates)
            .expect("snapshot");
        let admission = SemanticRerankAdmission::new(Some(43), 0x1234, 9, &mut candidates);
        let decision = semantic_decision(&snapshot, &[20, 10, 30]);
        assert_eq!(
            engine.resolve_semantic_rerank(snapshot, admission, Ok(decision)),
            SemanticRerankResolution::Rejected(RerankRejection::StaleGeneration)
        );
        assert_eq!(candidates, original);

        let snapshot = engine
            .capture_semantic_rerank(&request, &candidates)
            .expect("snapshot");
        let admission = SemanticRerankAdmission::new(Some(42), 0x1234, 9, &mut candidates);
        assert_eq!(
            engine.resolve_semantic_rerank(
                snapshot,
                admission,
                Err(SemanticProviderError::TimedOut),
            ),
            SemanticRerankResolution::Fallback(SemanticProviderError::TimedOut)
        );
        assert_eq!(candidates, original);
    }

    #[test]
    fn changed_candidate_text_is_rejected_even_when_ids_match() {
        let mut engine =
            LocalQualityEngine::new(LocalQualityConfig::new(LocalDataPolicy::CandidateFeatures));
        let request = request("とうきょう", "");
        let mut candidates = sample_candidates();
        let snapshot = engine
            .capture_semantic_rerank(&request, &candidates)
            .expect("snapshot");
        candidates[1].candidate.text = "東京 都".to_owned();
        let decision = semantic_decision(&snapshot, &[20, 10, 30]);
        let admission = SemanticRerankAdmission::new(Some(42), 0x1234, 9, &mut candidates);
        assert_eq!(
            engine.resolve_semantic_rerank(snapshot, admission, Ok(decision)),
            SemanticRerankResolution::Rejected(RerankRejection::CandidateSetChanged)
        );
        assert_eq!(candidates[1].candidate.text, "東京 都");
    }

    #[test]
    fn abstain_is_bounded_and_does_not_touch_candidates() {
        let mut engine =
            LocalQualityEngine::new(LocalQualityConfig::new(LocalDataPolicy::CandidateFeatures));
        let request = request("とうきょう", "");
        let mut candidates = sample_candidates();
        let original = candidates.clone();
        let snapshot = engine
            .capture_semantic_rerank(&request, &candidates)
            .expect("snapshot");
        let decision = SemanticRerankDecision {
            action: SemanticRerankAction::Abstain,
            candidate_ids: CandidateIdOrder::from_slice(&[]).expect("empty"),
            patch: None,
            confidence: 0.2,
            reason: SemanticRerankReason::Abstain,
            model_tier: ModelTier::Compact,
            expires_at_generation: 42,
            input_revision: snapshot.input_revision(),
            model_revision: snapshot.model_revision(),
            learning_version: snapshot.learning_version(),
        };
        let admission = SemanticRerankAdmission::new(Some(42), 0x1234, 9, &mut candidates);
        assert_eq!(
            engine.resolve_semantic_rerank(snapshot, admission, Ok(decision)),
            SemanticRerankResolution::Abstained
        );
        assert_eq!(candidates, original);
    }

    #[test]
    fn semantic_cache_hit_avoids_another_provider_decision() {
        let mut engine =
            LocalQualityEngine::new(LocalQualityConfig::new(LocalDataPolicy::CandidateFeatures));
        let request = request("とうきょう", "");
        let mut candidates = sample_candidates();
        let snapshot = engine
            .capture_semantic_rerank(&request, &candidates)
            .expect("snapshot");
        let decision = semantic_decision(&snapshot, &[20, 10, 30]);
        let admission = SemanticRerankAdmission::new(Some(42), 0x1234, 9, &mut candidates);
        assert!(
            engine
                .resolve_semantic_rerank(snapshot, admission, Ok(decision))
                .is_applied()
        );

        let repeated_baseline = sample_candidates();
        let snapshot = engine
            .capture_semantic_rerank(&request, &repeated_baseline)
            .expect("snapshot");
        assert!(engine.cached_semantic_rerank(&snapshot).is_some());
    }

    #[test]
    fn every_small_bounded_permutation_is_applied_without_cloning() {
        let mut permutation = [10, 20, 30, 40];
        for_each_permutation(&mut permutation, 0, &mut |order| {
            let candidate_order =
                CandidateIdOrder::from_slice(order).expect("bounded test permutation");
            let resolved = candidate_order
                .resolve(&[10, 20, 30, 40], 3)
                .expect("complete permutation");
            let mut values = [10, 20, 30, 40];
            let changed = super::apply_index_order(&mut values, resolved)
                .expect("validated permutation applies");
            assert_eq!(values, *order);
            let expected_changed = (0..order.len())
                .filter(|&new| order[new] != [10, 20, 30, 40][new])
                .count();
            assert_eq!(usize::from(changed), expected_changed);
        });
    }

    #[test]
    fn candidate_id_deserialization_is_bounded_and_patch_is_rejected() {
        let oversized = serde_json::json!({
            "action": "rerank",
            "candidateIds": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
            "patch": null,
            "confidence": 0.9,
            "reason": "domain_term",
            "modelTier": "compact",
            "expiresAtGeneration": 42,
            "inputRevision": 1,
            "modelRevision": 2,
            "learningVersion": 3
        });
        assert!(serde_json::from_value::<SemanticRerankDecision>(oversized).is_err());

        let valid = serde_json::json!({
            "action": "rerank",
            "candidateIds": [1],
            "patch": null,
            "confidence": 0.9,
            "reason": "domain_term",
            "modelTier": "compact",
            "expiresAtGeneration": 42,
            "inputRevision": 1,
            "modelRevision": 2,
            "learningVersion": 3
        });
        let parsed: SemanticRerankDecision =
            serde_json::from_value(valid).expect("documented null patch is accepted");
        assert!(parsed.patch.is_none());

        let patch = serde_json::json!({
            "action": "rerank",
            "candidateIds": [1],
            "patch": {"text": "injected"},
            "confidence": 0.9,
            "reason": "domain_term",
            "modelTier": "compact",
            "expiresAtGeneration": 42,
            "inputRevision": 1,
            "modelRevision": 2,
            "learningVersion": 3
        });
        assert!(serde_json::from_value::<SemanticRerankDecision>(patch).is_err());
    }
}
