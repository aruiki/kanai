use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::{
    CandidateAdjustments, CandidateOrigin, ConversionCandidate, ModelTier, PersonalizedCandidate,
};

// Keep Mozc's base score visible while allowing repeated, explicit learning
// to overcome a one-rank gap without allowing a single use to dominate.
const LEARNING_FREQUENCY_WEIGHT: f64 = 300.0;
const LEARNING_CONTEXT_BONUS: f64 = 18.0;
const REPEATED_LEARNING_THRESHOLD: f64 = 500.0;
const MOZC_SCORE_SCALE: f64 = 920.0;
const DOMAIN_TERM_WEIGHT: f64 = 36.0;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserProfile {
    pub learning_enabled: bool,
    pub personalization_strength: f64,
    pub history_limit: usize,
    pub domain_terms: Vec<String>,
    pub recency_half_life_days: f64,
    #[serde(default)]
    pub model_tier: ModelTier,
}

impl Default for UserProfile {
    fn default() -> Self {
        Self {
            learning_enabled: true,
            personalization_strength: 0.68,
            history_limit: 300,
            domain_terms: Vec::new(),
            recency_half_life_days: 45.0,
            model_tier: ModelTier::MozcOnly,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LearnedCandidate {
    pub count: u32,
    pub last_used_at: u64,
    pub contexts: BTreeMap<String, u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserWord {
    pub id: String,
    pub reading: String,
    pub text: String,
    #[serde(default = "default_word_boost")]
    pub boost: f64,
    pub created_at: u64,
}

const fn default_word_boost() -> f64 {
    180.0
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LearningState {
    pub version: u8,
    pub profile: UserProfile,
    pub learned: BTreeMap<String, LearnedCandidate>,
    pub user_words: Vec<UserWord>,
    pub history: Vec<HistoryEntry>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub reading: String,
    pub text: String,
    pub at: u64,
}

impl Default for LearningState {
    fn default() -> Self {
        Self {
            version: 1,
            profile: UserProfile::default(),
            learned: BTreeMap::new(),
            user_words: Vec::new(),
            history: Vec::new(),
        }
    }
}

impl LearningState {
    #[must_use]
    pub fn key(reading: &str, text: &str) -> String {
        format!("{reading}\u{1f}{text}")
    }

    pub fn record(&mut self, reading: &str, text: &str, context_tail: &str, now: u64) {
        if !self.profile.learning_enabled {
            return;
        }
        let key = Self::key(reading, text);
        let stats = self.learned.entry(key).or_insert(LearnedCandidate {
            count: 0,
            last_used_at: now,
            contexts: BTreeMap::new(),
        });
        stats.count = stats.count.saturating_add(1);
        stats.last_used_at = now;
        if !context_tail.is_empty() {
            let context_count = stats.contexts.entry(context_tail.to_owned()).or_default();
            *context_count = context_count.saturating_add(1);
        }
        self.history.insert(
            0,
            HistoryEntry {
                reading: reading.to_owned(),
                text: text.to_owned(),
                at: now,
            },
        );
        self.history.truncate(self.profile.history_limit);
    }

    /// Adds explainable local adjustments while preserving the provider order.
    ///
    /// The fast candidate ranker needs the original Mozc order as its baseline.
    /// Keeping this operation separate from [`Self::personalize`] prevents a
    /// learning policy from silently becoming an unbounded reordering stage
    /// before the bounded ranker has validated the candidate window.
    #[must_use]
    pub fn personalize_ordered(
        &self,
        candidates: Vec<ConversionCandidate>,
        reading: &str,
        context_before: &str,
        now: u64,
    ) -> Vec<PersonalizedCandidate> {
        let context_tail = context_signature(context_before);
        let domain_terms = build_domain_terms(&self.profile.domain_terms);

        candidates
            .into_iter()
            .enumerate()
            .map(|(index, candidate)| {
                let key = Self::key(reading, &candidate.text);
                let learned = self.learned.get(&key);
                let learning = if self.profile.learning_enabled {
                    learned.map_or(0.0, |stats| {
                        let frequency =
                            LEARNING_FREQUENCY_WEIGHT * (1.0 + stats.count as f64).log2();
                        let age_days = now.saturating_sub(stats.last_used_at) as f64 / 86_400_000.0;
                        let recency =
                            2_f64.powf(-age_days / self.profile.recency_half_life_days.max(1.0));
                        let context_bonus = if stats.contexts.contains_key(&context_tail) {
                            LEARNING_CONTEXT_BONUS
                        } else {
                            0.0
                        };
                        (frequency * recency + context_bonus)
                            * self.profile.personalization_strength.clamp(0.0, 1.0)
                    })
                } else {
                    0.0
                };
                let user_word = self
                    .user_words
                    .iter()
                    .filter(|word| word.reading == reading && word.text == candidate.text)
                    .map(|word| word.boost)
                    .fold(0.0, f64::max);
                let normalized_candidate_text = candidate.text.to_lowercase();
                let domain = domain_terms
                    .iter()
                    .filter(|term| normalized_candidate_text.contains(term.as_str()))
                    .count() as f64
                    * DOMAIN_TERM_WEIGHT;
                let context = match candidate.origin {
                    CandidateOrigin::UserHistory => 24.0,
                    CandidateOrigin::UserDictionary => 18.0,
                    CandidateOrigin::TypingCorrection | CandidateOrigin::SpellingCorrection => 42.0,
                    CandidateOrigin::Conversion | CandidateOrigin::Prediction => 0.0,
                    CandidateOrigin::Suggestion => -8.0,
                    CandidateOrigin::Unknown(_) => 0.0,
                };
                let provider_rank = candidate.provider_rank.max(index);
                let mozc = MOZC_SCORE_SCALE / (provider_rank.saturating_add(1) as f64);
                let adjustments = CandidateAdjustments {
                    mozc,
                    learning,
                    domain,
                    user_word,
                    context,
                };
                let score = mozc + learning + domain + user_word + context;
                let explanation =
                    explain_candidate(candidate.origin.label(), learning, domain, user_word);
                PersonalizedCandidate {
                    candidate: ConversionCandidate {
                        provider_rank,
                        ..candidate
                    },
                    score,
                    adjustments,
                    explanation,
                }
            })
            .collect()
    }

    /// Adds explainable local adjustments and orders the complete candidate set.
    #[must_use]
    pub fn personalize(
        &self,
        candidates: Vec<ConversionCandidate>,
        reading: &str,
        context_before: &str,
        now: u64,
    ) -> Vec<PersonalizedCandidate> {
        let mut personalized = self.personalize_ordered(candidates, reading, context_before, now);
        personalized.sort_by(|left, right| {
            right.score.total_cmp(&left.score).then_with(|| {
                left.candidate
                    .provider_rank
                    .cmp(&right.candidate.provider_rank)
            })
        });
        personalized
    }
}

fn context_signature(context: &str) -> String {
    let compact = context.trim_end();
    compact
        .chars()
        .rev()
        .take(12)
        .collect::<String>()
        .chars()
        .rev()
        .collect()
}

fn build_domain_terms(terms: &[String]) -> Vec<String> {
    let mut values = terms
        .iter()
        .map(|term| term.trim().to_lowercase())
        .filter(|term| !term.is_empty())
        .collect::<Vec<_>>();
    values.sort();
    values.dedup();
    values
}

fn explain_candidate(origin: &str, learning: f64, domain: f64, user_word: f64) -> String {
    if user_word > 0.0 {
        return "ユーザー辞書で優先しました".to_owned();
    }
    if learning >= REPEATED_LEARNING_THRESHOLD {
        return format!("{origin}・繰り返し学習で優先しました");
    }
    if learning > 0.0 {
        return format!("{origin}・この文脈での学習を優先しました");
    }
    if domain > 0.0 {
        return format!("{origin}・専門語を検出しました");
    }
    format!("{origin}・Mozc の文脈スコアを採用しました")
}

#[cfg(test)]
mod tests {
    use super::{LearningState, UserProfile, UserWord};
    use crate::{CandidateOrigin, ConversionCandidate};

    fn candidate(text: &str, rank: usize) -> ConversionCandidate {
        ConversionCandidate {
            id: rank as i32,
            text: text.to_owned(),
            reading: None,
            provider_rank: rank,
            description: None,
            origin: CandidateOrigin::Conversion,
            attributes: Vec::new(),
            log: None,
        }
    }

    #[test]
    fn repeated_learning_promotes_without_hiding_other_candidates() {
        let now = 1_700_000_000_000;
        let mut state = LearningState::default();
        for _ in 0..6 {
            state.record("にほん", "日本語", "設計メモ", now);
        }
        let ranked = state.personalize(
            vec![candidate("日本", 0), candidate("日本語", 1)],
            "にほん",
            "設計メモ",
            now,
        );
        assert_eq!(ranked[0].candidate.text, "日本語");
        assert_eq!(ranked.len(), 2);
    }

    #[test]
    fn strength_zero_disables_personalization() {
        let mut state = LearningState {
            profile: UserProfile {
                personalization_strength: 0.0,
                ..UserProfile::default()
            },
            ..LearningState::default()
        };
        for _ in 0..10 {
            state.record("きょう", "京", "", 1_700_000_000_000);
        }
        let ranked = state.personalize(
            vec![candidate("今日", 0), candidate("京", 1)],
            "きょう",
            "",
            1_700_000_000_000,
        );
        assert_eq!(ranked[0].candidate.text, "今日");
    }

    #[test]
    fn learning_opt_out_and_history_limit_bound_local_state() {
        let now = 1_700_000_000_000;
        let mut state = LearningState::default();
        state.profile.learning_enabled = false;
        state.record("にほん", "日本語", "設計", now);
        assert!(state.learned.is_empty());
        assert!(state.history.is_empty());

        state.profile.learning_enabled = true;
        state.profile.history_limit = 2;
        state.record("にほん", "日本", "設計", now + 1);
        state.record("にほん", "日本語", "設計", now + 2);
        state.record("にほん", "日 本", "設計", now + 3);

        assert_eq!(state.history.len(), 2);
        assert_eq!(state.history[0].text, "日 本");
        assert_eq!(state.history[1].text, "日本語");
        assert_eq!(state.learned.len(), 3);
        assert_eq!(
            state
                .learned
                .get(&LearningState::key("にほん", "日本語"))
                .expect("recorded candidate")
                .count,
            1
        );
    }

    #[test]
    fn user_dictionary_and_domain_terms_are_explainable() {
        let now = 1_700_000_000_000;
        let mut state = LearningState::default();
        state.profile.domain_terms = vec!["  rust  ".to_owned()];
        state.user_words.push(UserWord {
            id: "rust-1".to_owned(),
            reading: "らすと".to_owned(),
            text: "Rust".to_owned(),
            boost: 180.0,
            created_at: now,
        });

        let ranked = state.personalize(
            vec![
                candidate("Java", 0),
                candidate("Rust", 1),
                candidate("RustIDE", 2),
            ],
            "らすと",
            "",
            now,
        );
        let rust = ranked
            .iter()
            .find(|item| item.candidate.text == "Rust")
            .expect("user word candidate");
        assert_eq!(rust.adjustments.user_word, 180.0);
        assert!(rust.explanation.contains("ユーザー辞書"));

        let domain = ranked
            .iter()
            .find(|item| item.candidate.text == "RustIDE")
            .expect("domain candidate");
        assert_eq!(domain.adjustments.domain, 36.0);
        assert!(domain.explanation.contains("専門語"));
    }
}
