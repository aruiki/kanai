//! Platform-neutral contracts and explainable personalization for KanaAI.
//!
//! Mozc owns deterministic Japanese conversion. This crate deliberately sits
//! above it: providers produce candidates, while KanaAI adds transparent,
//! local-first ranking policy and persists only the minimum user state.

mod ai;
mod learning;
mod types;

pub use ai::{
    HardwareCapabilities, ModelProfile, ModelTier, Quantization, recommend_tier,
    recommend_tier_for_memory,
};
pub use learning::{LearningState, UserProfile, UserWord};
pub use types::{
    CandidateAdjustments, CandidateAttribute, CandidateOrigin, CommitResult, ConversionCandidate,
    ConversionProvider, ConversionRequest, ConversionResult, InputMode, PersonalizedCandidate,
    PreeditSegment, ProviderCapabilities, ProviderError, ProviderHealth,
};
