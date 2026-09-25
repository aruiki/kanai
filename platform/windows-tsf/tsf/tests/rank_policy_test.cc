#include <cstdlib>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

#include "engine/kanai_ai/rank_policy.h"

namespace {

using kanai::tsf::ApplyRankPolicy;
using kanai::tsf::BrokerCandidate;
using kanai::tsf::EnhancementStatus;
using kanai::tsf::MapAiOrderToRanks;
using kanai::tsf::RerankRequest;
using kanai::tsf::RerankResponse;
using kanai::tsf::SelectCandidateIndices;

void Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAILED: " << message << "\n";
    std::exit(1);
  }
}

RerankRequest Request() {
  RerankRequest request;
  request.request_id = 42;
  request.session_id = 7;
  request.generation = 3;
  request.candidates = {
      {1, "かな", std::string("かな"), 0},
      {2, "彼方", std::string("かれかた"), 1},
      {3, "著者", std::string("いっしゃ"), 2},
  };
  return request;
}

RerankResponse Response(const RerankRequest& request) {
  RerankResponse response;
  response.request_id = request.request_id;
  response.session_id = request.session_id;
  response.generation = request.generation;
  response.broker_success = true;
  response.status = EnhancementStatus::kApplied;
  response.baseline = request.candidates;
  response.ai = {request.candidates[1], request.candidates[2],
                 request.candidates[0]};
  response.adopted = true;
  return response;
}

void TestDeterministicSelection() {
  const std::vector<int> costs = {100, 50, 100, 25, 75};
  const std::vector<std::size_t> selected = SelectCandidateIndices(costs, 3);
  Check(selected == std::vector<std::size_t>({3, 1, 4}),
        "selection uses cost then original index");
  Check(SelectCandidateIndices(costs, 0).empty(), "zero selection is empty");
}

void TestCanonicalAiOrder() {
  const RerankRequest request = Request();
  RerankResponse response = Response(request);
  const std::optional<std::vector<std::uint8_t>> ranks =
      MapAiOrderToRanks(request, response);
  Check(ranks.has_value() &&
            (*ranks == std::vector<std::uint8_t>({2, 0, 1})),
        "AI candidate order maps to request-index ranks");

  response.status = EnhancementStatus::kTimedOut;
  response.adopted = false;
  Check(!MapAiOrderToRanks(request, response).has_value(),
        "timeout never applies AI order");

  response = Response(request);
  response.ai[0].text = "mutated";
  Check(!MapAiOrderToRanks(request, response).has_value(),
        "candidate text mutation rejected");

  response = Response(request);
  response.baseline[0].text = "mutated baseline";
  Check(!MapAiOrderToRanks(request, response).has_value(),
        "baseline text mutation rejected");

  response = Response(request);
  response.ai[1] = response.ai[0];
  Check(!MapAiOrderToRanks(request, response).has_value(),
        "duplicate AI candidate rejected");
}

void TestBoundedPromotion() {
  const std::vector<int> original = {100, 110, 500, 50};
  // AI promotes candidate 1; indices 3, 0, 1 were the submitted top three.
  const std::vector<std::size_t> selected = {3, 0, 1};
  const std::vector<std::uint8_t> ranks = {2, 1, 0};
  const std::optional<std::vector<int>> adjusted =
      ApplyRankPolicy(original, selected, ranks, 1000, 64);
  Check(adjusted.has_value(), "valid policy applied");
  Check((*adjusted)[1] == 50, "best-ranked candidate reaches selected minimum");
  Check((*adjusted)[3] == 178, "third rank receives two cost steps");
  Check((*adjusted)[0] == 114, "second rank receives one cost step");
  Check((*adjusted)[2] == 500, "unscored candidate is untouched");

  const std::optional<std::vector<int>> clamped =
      ApplyRankPolicy({0, 1}, {0, 1}, {1, 0}, 64, 64);
  Check(clamped.has_value() && (*clamped)[0] == 64 && (*clamped)[1] == 0,
        "cost policy clamps at host maximum");
  Check(!ApplyRankPolicy(original, {0, 0, 1}, {0, 1, 2}, 1000)
             .has_value(),
        "duplicate selected candidate rejected");
  Check(!ApplyRankPolicy(original, {3, 0, 1}, {0, 0, 1}, 1000)
             .has_value(),
        "duplicate rank rejected atomically");
}

}  // namespace

int main() {
  TestDeterministicSelection();
  TestCanonicalAiOrder();
  TestBoundedPromotion();
  std::cout << "rank_policy_test: PASS\n";
  return 0;
}
