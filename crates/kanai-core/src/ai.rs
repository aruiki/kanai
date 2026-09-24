use serde::{Deserialize, Serialize};

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

#[cfg(test)]
mod tests {
    use super::{ModelTier, recommend_tier, recommend_tier_for_memory};

    #[test]
    fn low_memory_devices_never_receive_a_generative_model() {
        assert_eq!(recommend_tier(2, 8), ModelTier::MozcOnly);
        assert_eq!(recommend_tier(3, 16), ModelTier::MozcOnly);
    }

    #[test]
    fn recommendation_considers_cpu_and_memory() {
        assert_eq!(recommend_tier(4, 2), ModelTier::Tiny);
        assert_eq!(recommend_tier(4, 4), ModelTier::Compact);
        assert_eq!(recommend_tier(8, 4), ModelTier::Balanced);
    }

    #[test]
    fn free_memory_can_force_the_safe_tier() {
        assert_eq!(recommend_tier_for_memory(16, 1, 16), ModelTier::MozcOnly);
        assert_eq!(recommend_tier_for_memory(4, 2, 8), ModelTier::Tiny);
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
}
