#ifndef KANAI_WINDOWS_TSF_KANAI_AI_RANK_POLICY_H_
#define KANAI_WINDOWS_TSF_KANAI_AI_RANK_POLICY_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

#include "engine/kanai_ai/broker_contract.h"

namespace kanai::tsf {

inline constexpr std::size_t kDefaultMaxRerankedCandidates = 5;
inline constexpr int kCandidateRankCostStep = 64;

// Selects the lowest-cost candidates deterministically. Ties retain the
// original vector order, which is important for stable candidate UI behavior.
std::vector<std::size_t> SelectCandidateIndices(
    const std::vector<int>& original_costs, std::size_t maximum_count);

// Converts the canonical kanai-broker AI candidate order into
// rank-by-request-index. It rejects fallback responses, missing/duplicate IDs,
// text/reading/rank mutation, and incomplete permutations.
std::optional<std::vector<std::uint8_t>> MapAiOrderToRanks(
    const RerankRequest& request, const RerankResponse& response);

// Produces adjusted costs atomically. The best-ranked submitted candidate is
// anchored at the minimum submitted cost and every worse rank receives one
// non-negative cost step. No outside candidate can be promoted by a negative
// AI adjustment.
std::optional<std::vector<int>> ApplyRankPolicy(
    const std::vector<int>& original_costs,
    const std::vector<std::size_t>& selected_indices,
    const std::vector<std::uint8_t>& rank_by_index, int maximum_cost,
    int rank_cost_step = kCandidateRankCostStep);

}  // namespace kanai::tsf

#endif  // KANAI_WINDOWS_TSF_KANAI_AI_RANK_POLICY_H_
