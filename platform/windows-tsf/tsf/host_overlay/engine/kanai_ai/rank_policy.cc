#include "engine/kanai_ai/rank_policy.h"

#include <algorithm>
#include <cstdint>
#include <numeric>
#include <vector>

namespace kanai::tsf {

std::vector<std::size_t> SelectCandidateIndices(
    const std::vector<int>& original_costs, std::size_t maximum_count) {
  if (original_costs.empty() || maximum_count == 0) {
    return {};
  }
  std::vector<std::size_t> indices(original_costs.size());
  std::iota(indices.begin(), indices.end(), 0);
  const std::size_t selected_count =
      std::min(maximum_count, original_costs.size());
  std::partial_sort(indices.begin(), indices.begin() + selected_count,
                    indices.end(), [&original_costs](std::size_t lhs,
                                                      std::size_t rhs) {
                      if (original_costs[lhs] != original_costs[rhs]) {
                        return original_costs[lhs] < original_costs[rhs];
                      }
                      return lhs < rhs;
                    });
  indices.resize(selected_count);
  return indices;
}

std::optional<std::vector<std::uint8_t>> MapAiOrderToRanks(
    const RerankRequest& request, const RerankResponse& response) {
  if (!response.broker_success ||
      response.status != EnhancementStatus::kApplied || !response.adopted ||
      response.request_id != request.request_id ||
      response.session_id != request.session_id ||
      response.generation != request.generation ||
      response.baseline.size() != request.candidates.size() ||
      response.ai.size() != request.candidates.size()) {
    return std::nullopt;
  }
  for (std::size_t index = 0; index < request.candidates.size(); ++index) {
    const BrokerCandidate& expected = request.candidates[index];
    const BrokerCandidate& actual = response.baseline[index];
    if (actual.id != expected.id || actual.text != expected.text ||
        actual.reading != expected.reading || actual.rank != expected.rank) {
      return std::nullopt;
    }
  }

  std::vector<std::uint8_t> rank_by_index(request.candidates.size(), 0);
  std::vector<bool> seen(request.candidates.size(), false);
  for (std::size_t rank = 0; rank < response.ai.size(); ++rank) {
    const BrokerCandidate& ai_candidate = response.ai[rank];
    const auto found = std::find_if(
        request.candidates.begin(), request.candidates.end(),
        [&ai_candidate](const BrokerCandidate& baseline) {
          return baseline.id == ai_candidate.id &&
                 baseline.text == ai_candidate.text &&
                 baseline.reading == ai_candidate.reading &&
                 baseline.rank == ai_candidate.rank;
        });
    if (found == request.candidates.end()) {
      return std::nullopt;
    }
    const std::size_t index = static_cast<std::size_t>(
        std::distance(request.candidates.begin(), found));
    if (seen[index]) {
      return std::nullopt;
    }
    seen[index] = true;
    rank_by_index[index] = static_cast<std::uint8_t>(rank);
  }
  if (std::find(seen.begin(), seen.end(), false) != seen.end()) {
    return std::nullopt;
  }
  return rank_by_index;
}

std::optional<std::vector<int>> ApplyRankPolicy(
    const std::vector<int>& original_costs,
    const std::vector<std::size_t>& selected_indices,
    const std::vector<std::uint8_t>& rank_by_index, int maximum_cost,
    int rank_cost_step) {
  const std::size_t selected_count = selected_indices.size();
  if (selected_count < 2 ||
      selected_count > kNativeMaxRerankedCandidates ||
      rank_by_index.size() != selected_count || maximum_cost <= 0 ||
      rank_cost_step <= 0) {
    return std::nullopt;
  }

  std::vector<bool> seen(original_costs.size(), false);
  int minimum_cost = maximum_cost;
  for (const std::size_t index : selected_indices) {
    if (index >= original_costs.size() || seen[index]) {
      return std::nullopt;
    }
    seen[index] = true;
    minimum_cost = std::min(minimum_cost, original_costs[index]);
  }

  std::vector<std::uint8_t> seen_ranks(selected_count, 0);
  for (std::size_t position = 0; position < selected_count; ++position) {
    const std::uint8_t rank = rank_by_index[position];
    if (rank >= selected_count || seen_ranks[rank]) {
      return std::nullopt;
    }
    seen_ranks[rank] = 1;
  }

  if (std::find(seen_ranks.begin(), seen_ranks.end(), 0) != seen_ranks.end()) {
    return std::nullopt;
  }

  std::vector<int> adjusted_costs = original_costs;
  for (std::size_t position = 0; position < selected_count; ++position) {
    const std::size_t result_index = selected_indices[position];
    const std::int64_t rank_offset =
        static_cast<std::int64_t>(rank_by_index[position]) * rank_cost_step;
    const std::int64_t desired_cost =
        std::min<std::int64_t>(maximum_cost,
                               static_cast<std::int64_t>(minimum_cost) +
                                   rank_offset);
    adjusted_costs[result_index] = static_cast<int>(desired_cost);
  }
  return adjusted_costs;
}

}  // namespace kanai::tsf
