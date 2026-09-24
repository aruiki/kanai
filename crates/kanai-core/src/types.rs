use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InputMode {
    Direct,
    Hiragana,
    Katakana,
    Fullwidth,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CandidateOrigin {
    Conversion,
    Prediction,
    Suggestion,
    UserDictionary,
    UserHistory,
    TypingCorrection,
    SpellingCorrection,
    Unknown(String),
}

impl CandidateOrigin {
    #[must_use]
    pub fn from_attributes(attributes: &[String]) -> Self {
        if attributes
            .iter()
            .any(|value| value.eq_ignore_ascii_case("typingCorrection"))
        {
            return Self::TypingCorrection;
        }
        if attributes
            .iter()
            .any(|value| value.eq_ignore_ascii_case("spellingCorrection"))
        {
            return Self::SpellingCorrection;
        }
        if attributes
            .iter()
            .any(|value| value.eq_ignore_ascii_case("userHistory"))
        {
            return Self::UserHistory;
        }
        if attributes
            .iter()
            .any(|value| value.eq_ignore_ascii_case("userDictionary"))
        {
            return Self::UserDictionary;
        }
        Self::Conversion
    }

    #[must_use]
    pub fn label(&self) -> &str {
        match self {
            Self::Conversion => "文脈変換",
            Self::Prediction => "予測変換",
            Self::Suggestion => "入力補助",
            Self::UserDictionary => "ユーザー辞書",
            Self::UserHistory => "学習履歴",
            Self::TypingCorrection => "打鍵ミス修復",
            Self::SpellingCorrection => "綴り修正",
            Self::Unknown(value) => value,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CandidateAttribute {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreeditSegment {
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reading: Option<String>,
    pub highlighted: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversionCandidate {
    pub id: i32,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reading: Option<String>,
    pub provider_rank: usize,
    pub description: Option<String>,
    pub origin: CandidateOrigin,
    pub attributes: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CandidateAdjustments {
    pub mozc: f64,
    pub learning: f64,
    pub domain: f64,
    pub user_word: f64,
    pub context: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonalizedCandidate {
    #[serde(flatten)]
    pub candidate: ConversionCandidate,
    pub score: f64,
    pub adjustments: CandidateAdjustments,
    pub explanation: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversionResult {
    pub provider: String,
    pub reading: String,
    pub preedit: String,
    pub preedit_segments: Vec<PreeditSegment>,
    /// Normalized provider candidates; personalization is applied by the core policy layer.
    pub candidates: Vec<ConversionCandidate>,
    pub focused_index: Option<usize>,
    pub consumed: bool,
    pub elapsed: Duration,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversionRequest {
    pub romaji: String,
    #[serde(default)]
    pub context_before: String,
    #[serde(default)]
    pub context_after: String,
    #[serde(default = "default_limit")]
    pub limit: usize,
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub convert: bool,
}

impl ConversionRequest {
    #[must_use]
    pub fn new(romaji: impl Into<String>) -> Self {
        Self {
            romaji: romaji.into(),
            context_before: String::new(),
            context_after: String::new(),
            limit: default_limit(),
            revision: 0,
            convert: true,
        }
    }
}

const fn default_limit() -> usize {
    9
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitResult {
    pub text: String,
    pub elapsed_millis: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCapabilities {
    pub name: String,
    pub romaji: bool,
    pub kana: bool,
    pub n_best: bool,
    pub context: bool,
    pub user_dictionary: bool,
    pub local: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderHealth {
    pub available: bool,
    pub provider: String,
    pub detail: String,
    pub capabilities: ProviderCapabilities,
}

#[derive(Debug, Clone, Error, PartialEq, Eq)]
pub enum ProviderError {
    #[error("conversion provider is unavailable: {0}")]
    Unavailable(String),
    #[error("invalid conversion request: {0}")]
    InvalidRequest(String),
    #[error("candidate was not produced by this session: {0}")]
    UnknownCandidate(i32),
    #[error("provider I/O failed: {0}")]
    Io(String),
    #[error("provider timed out after {0:?}")]
    Timeout(Duration),
    #[error("provider returned malformed data: {0}")]
    Protocol(String),
}

#[async_trait]
pub trait ConversionProvider: Send + Sync {
    fn name(&self) -> &'static str;
    fn capabilities(&self) -> ProviderCapabilities;
    async fn health(&self) -> ProviderHealth;
    async fn convert(&self, request: &ConversionRequest)
    -> Result<ConversionResult, ProviderError>;
    async fn commit(&self, candidate_id: i32) -> Result<CommitResult, ProviderError>;
    async fn reset(&self) -> Result<(), ProviderError>;
}
