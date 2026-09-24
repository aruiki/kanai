#include "engine/kanai_ai/kanai_supplemental_model.h"

#include <algorithm>
#include <cstddef>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "engine/kanai_ai/rank_policy.h"

namespace kanai::tsf {

bool KanaAiSupplementalModel::IsAvailable() const {
  // The pinned SupplementalModelInterface does not carry kanai-broker's
  // required per-context sessionId/generation. Reporting availability before
  // that token bridge exists would permit an unsafe synchronous fallback.
  return false;
}

void KanaAiSupplementalModel::PostCorrect(
    const mozc::ConversionRequest& request,
    std::vector<mozc::prediction::Result>& results) const {
  // Deliberately no-op. A future optional executor may publish a validated
  // RerankResponse, but it must never originate a blocking call from here.
  (void)request;
  (void)results;
}

void KanaAiSupplementalModel::RescoreResults(
    const mozc::ConversionRequest& request,
    absl::Span<mozc::prediction::Result> results) const {
  (void)request;
  (void)results;
}

bool ApplyRerankToResults(const RerankRequest& request,
                          const RerankResponse& response,
                          std::vector<mozc::prediction::Result>* results) {
  if (results == nullptr ||
      results->size() != request.candidates.size() ||
      results->size() < 2 ||
      results->size() > kNativeMaxRerankedCandidates) {
    return false;
  }
  for (std::size_t index = 0; index < results->size(); ++index) {
    const BrokerCandidate& candidate = request.candidates[index];
    const mozc::prediction::Result& result = (*results)[index];
    if (candidate.text != result.value || candidate.rank != index ||
        (candidate.reading.has_value() ? *candidate.reading != result.key
                                       : !result.key.empty())) {
      return false;
    }
  }

  const std::optional<std::vector<std::uint8_t>> ranks =
      MapAiOrderToRanks(request, response);
  if (!ranks.has_value()) {
    return false;
  }

  std::vector<int> original_costs;
  original_costs.reserve(results->size());
  for (const mozc::prediction::Result& result : *results) {
    original_costs.push_back(result.cost);
  }
  std::vector<std::size_t> selected_indices(results->size());
  for (std::size_t index = 0; index < selected_indices.size(); ++index) {
    selected_indices[index] = index;
  }
  const std::optional<std::vector<int>> adjusted = ApplyRankPolicy(
      original_costs, selected_indices, *ranks,
      mozc::prediction::Result::kInvalidCost - 1);
  if (!adjusted.has_value()) {
    return false;
  }

  std::vector<std::size_t> order;
  order.reserve(response.ai.size());
  for (const BrokerCandidate& ai_candidate : response.ai) {
    const auto found = std::find_if(
        request.candidates.begin(), request.candidates.end(),
        [&ai_candidate](const BrokerCandidate& baseline) {
          return baseline.id == ai_candidate.id;
        });
    if (found == request.candidates.end()) {
      return false;
    }
    order.push_back(static_cast<std::size_t>(
        std::distance(request.candidates.begin(), found)));
  }
  if (order.size() != results->size()) {
    return false;
  }

  std::vector<mozc::prediction::Result> reranked;
  reranked.reserve(results->size());
  for (std::size_t destination = 0; destination < order.size(); ++destination) {
    const std::size_t source = order[destination];
    reranked.push_back(std::move((*results)[source]));
    reranked.back().cost_before_rescoring = reranked.back().cost;
    reranked.back().cost = (*adjusted)[source];
    if (destination != source) {
      reranked.back().attributes |= mozc::converter::Attribute::RERANKED;
    }
  }
  *results = std::move(reranked);
  return true;
}

}  // namespace kanai::tsf
