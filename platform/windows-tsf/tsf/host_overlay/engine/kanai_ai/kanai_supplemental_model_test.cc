#include "engine/kanai_ai/kanai_supplemental_model.h"

#include <string>
#include <utility>
#include <vector>

#include "testing/gunit.h"

namespace kanai::tsf {
namespace {

RerankRequest MakeRequest() {
  RerankRequest request;
  request.request_id = 10;
  request.session_id = 7;
  request.generation = 2;
  request.candidates = {
      {1, "かな", std::string("かな"), 0},
      {2, "彼方", std::string("かれかた"), 1},
  };
  return request;
}

std::vector<mozc::prediction::Result> MakeResults(
    const RerankRequest& request) {
  std::vector<mozc::prediction::Result> results;
  for (std::size_t index = 0; index < request.candidates.size(); ++index) {
    mozc::prediction::Result result;
    result.key = request.candidates[index].reading.value_or("");
    result.value = request.candidates[index].text;
    result.cost = 100 + static_cast<int>(index) * 10;
    results.push_back(std::move(result));
  }
  return results;
}

RerankResponse MakeResponse(const RerankRequest& request) {
  RerankResponse response;
  response.request_id = request.request_id;
  response.session_id = request.session_id;
  response.generation = request.generation;
  response.broker_success = true;
  response.status = EnhancementStatus::kApplied;
  response.baseline = request.candidates;
  response.ai = {request.candidates[1], request.candidates[0]};
  response.adopted = true;
  return response;
}

TEST(KanaAiSupplementalModelTest, RemainsInertWithoutSessionBridge) {
  KanaAiSupplementalModel model;
  EXPECT_FALSE(model.IsAvailable());
}

TEST(KanaAiSupplementalModelTest, AppliesOnlyExactAsyncPermutation) {
  const RerankRequest request = MakeRequest();
  std::vector<mozc::prediction::Result> results = MakeResults(request);
  std::vector<mozc::prediction::Result> original = results;
  RerankResponse response = MakeResponse(request);

  ASSERT_TRUE(ApplyRerankToResults(request, response, &results));
  ASSERT_EQ(results.size(), 2U);
  EXPECT_EQ(results[0].value, "彼方");
  EXPECT_EQ(results[1].value, "かな");
  EXPECT_EQ(results[0].cost, 100);
  EXPECT_EQ(results[1].cost, 164);
  EXPECT_NE(results[0].attributes, original[0].attributes);
  EXPECT_NE(results[1].attributes, original[1].attributes);

  results = original;
  response.status = EnhancementStatus::kTimedOut;
  response.adopted = false;
  EXPECT_FALSE(ApplyRerankToResults(request, response, &results));
  EXPECT_EQ(results.size(), original.size());
  EXPECT_EQ(results[0].value, original[0].value);
  EXPECT_EQ(results[0].cost, original[0].cost);
}

TEST(KanaAiSupplementalModelTest, RejectsMutatedCandidateAtomically) {
  const RerankRequest request = MakeRequest();
  std::vector<mozc::prediction::Result> results = MakeResults(request);
  const std::vector<mozc::prediction::Result> original = results;
  RerankResponse response = MakeResponse(request);
  response.ai[0].text = "mutated";

  EXPECT_FALSE(ApplyRerankToResults(request, response, &results));
  ASSERT_EQ(results.size(), original.size());
  for (std::size_t index = 0; index < results.size(); ++index) {
    EXPECT_EQ(results[index].value, original[index].value);
    EXPECT_EQ(results[index].cost, original[index].cost);
  }
}

}  // namespace
}  // namespace kanai::tsf
