//! Platform-neutral contracts and explainable personalization for KanaAI.
//!
//! Mozc owns deterministic Japanese conversion. This crate deliberately sits
//! above it: providers produce candidates, while KanaAI adds transparent,
//! local-first ranking policy and persists only the minimum user state.

mod ai;
mod learning;
mod pipeline;
mod types;

pub use ai::{
    BoundedLocalContext, CandidateIdOrder, CandidateOrderError, DEFAULT_FAST_RANK_DEADLINE,
    DEFAULT_SEMANTIC_RERANK_DEADLINE, FastRankOutcome, FastRankStatus, HardwareCapabilities,
    LocalDataPolicy, LocalQualityConfig, LocalQualityEngine, LocalQualityRequest,
    MAX_FAST_RANK_DEADLINE, MAX_LOCAL_QUALITY_CACHE_ENTRIES, MAX_LOCAL_QUALITY_CANDIDATES,
    MAX_LOCAL_QUALITY_CONTEXT_CHARS, MAX_LOCAL_QUALITY_RANK_SHIFT, MIN_SEMANTIC_RERANK_CONFIDENCE,
    ModelProfile, ModelTier, NoCandidatePatch, Quantization, RerankRejection,
    SemanticProviderError, SemanticRerankAction, SemanticRerankAdmission, SemanticRerankApply,
    SemanticRerankDecision, SemanticRerankPlan, SemanticRerankReason, SemanticRerankResolution,
    SemanticRerankSnapshot, recommend_tier, recommend_tier_for_memory,
};
pub use learning::{LearningState, UserProfile, UserWord};
pub use pipeline::{
    CandidatePipeline, DEFAULT_PIPELINE_SEMANTIC_DEADLINE, ExtractedContext, FastConversionOutput,
    MAX_PIPELINE_CANDIDATES, MAX_PIPELINE_SEMANTIC_DEADLINE, PipelineError, PipelineSession,
    SemanticCandidate, SemanticRerankInput, SemanticRerankProvider, SemanticRerankReport,
    SemanticRerankTicket,
};
pub use types::{
    CandidateAdjustments, CandidateAttribute, CandidateOrigin, CommitResult, ConversionCandidate,
    ConversionProvider, ConversionRequest, ConversionResult, InputMode, PersonalizedCandidate,
    PreeditSegment, ProviderCapabilities, ProviderError, ProviderHealth,
};
