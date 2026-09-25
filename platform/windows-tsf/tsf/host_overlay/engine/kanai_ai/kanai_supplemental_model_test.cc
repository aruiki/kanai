#include "engine/kanai_ai/kanai_supplemental_model.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
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

TEST(KanaAiSupplementalModelTest, SessionHandlerBridgeIssuesAndInvalidatesBindings) {
  auto model = KanaAiSupplementalModel::Create();
  ASSERT_TRUE(model != nullptr);
  SessionBindingOwner owner(*model);
  std::atomic<bool> released = false;
  ASSERT_TRUE(owner.StartAsyncExecutor(
      [](const RerankRequest&, RerankResponse*) { return false; },
      [&released](std::uint64_t, std::uint64_t) {
        released.store(true, std::memory_order_release);
        return true;
      }));
  EXPECT_FALSE(model->IsAvailable());
  EXPECT_TRUE(KanaAiSupplementalModel::BeginMozcCommand(
      7, SessionFieldClass::kRegular));
  EXPECT_TRUE(model->IsAvailable());
  EXPECT_TRUE(KanaAiSupplementalModel::BeginMozcCommand(
      7, SessionFieldClass::kPassword));
  EXPECT_FALSE(model->IsAvailable());
  // A missing marker on a later command cannot downgrade a sticky secure
  // session back to regular before the trusted owner ends it.
  EXPECT_TRUE(KanaAiSupplementalModel::BeginMozcCommand(
      7, SessionFieldClass::kRegular));
  EXPECT_FALSE(model->IsAvailable());
  // Repeated secure notifications must not erase the already queued release.
  EXPECT_TRUE(KanaAiSupplementalModel::BeginMozcCommand(
      7, SessionFieldClass::kProtected));
  EXPECT_FALSE(model->IsAvailable());
  KanaAiSupplementalModel::EndMozcSession(7);
  for (int attempt = 0; attempt < 100 &&
                         !released.load(std::memory_order_acquire);
       ++attempt) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  EXPECT_TRUE(released.load(std::memory_order_acquire));
  EXPECT_FALSE(model->IsAvailable());
}

TEST(KanaAiSupplementalModelTest, AsyncWorkerPublishesAndAppliesWithoutBlockingCallback) {
  KanaAiSupplementalModel model;
  SessionBindingOwner owner(model);
  std::mutex mutex;
  std::condition_variable condition;
  bool entered = false;
  bool release = false;
  auto transport = [&](const RerankRequest& request,
                       RerankResponse* response) {
    std::unique_lock<std::mutex> lock(mutex);
    entered = true;
    condition.notify_all();
    condition.wait(lock, [&] { return release; });
    *response = MakeResponse(request);
    return true;
  };

  ASSERT_TRUE(owner.StartAsyncExecutor(transport));
  const std::optional<SessionBinding> binding = owner.Bind(7, 2);
  ASSERT_TRUE(binding.has_value());
  EXPECT_TRUE(model.IsAvailable());

  const RerankRequest baseline = MakeRequest();
  std::vector<mozc::prediction::Result> results = MakeResults(baseline);
  const mozc::ConversionRequest request;
  model.PostCorrect(request, results);

  bool worker_entered = false;
  {
    std::unique_lock<std::mutex> lock(mutex);
    worker_entered = condition.wait_for(
        lock, std::chrono::seconds(1), [&] { return entered; });
    release = true;
  }
  condition.notify_all();
  ASSERT_TRUE(worker_entered);

  bool applied = false;
  for (int attempt = 0; attempt < 100; ++attempt) {
    model.PostCorrect(request, results);
    if (results[0].value == "彼方") {
      applied = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  owner.StopAsyncExecutor();
  EXPECT_TRUE(applied);
  EXPECT_FALSE(model.IsAvailable());
}

TEST(KanaAiSupplementalModelTest, AsyncResponseFromPreviousGenerationIsDropped) {
  KanaAiSupplementalModel model;
  SessionBindingOwner owner(model);
  std::mutex mutex;
  std::condition_variable condition;
  bool entered = false;
  bool release = false;
  std::atomic<int> calls = 0;
  auto transport = [&](const RerankRequest& request,
                       RerankResponse* response) {
    const int call = calls.fetch_add(1, std::memory_order_relaxed);
    if (call > 0) {
      return false;
    }
    std::unique_lock<std::mutex> lock(mutex);
    entered = true;
    condition.notify_all();
    condition.wait(lock, [&] { return release; });
    *response = MakeResponse(request);
    return true;
  };
  ASSERT_TRUE(owner.StartAsyncExecutor(transport));
  const auto first = owner.Bind(7, 2);
  ASSERT_TRUE(first.has_value());
  const RerankRequest baseline = MakeRequest();
  std::vector<mozc::prediction::Result> results = MakeResults(baseline);
  const mozc::ConversionRequest request;
  model.PostCorrect(request, results);

  bool worker_entered = false;
  {
    std::unique_lock<std::mutex> lock(mutex);
    worker_entered = condition.wait_for(
        lock, std::chrono::seconds(1), [&] { return entered; });
    release = true;
  }
  condition.notify_all();
  ASSERT_TRUE(worker_entered);
  const auto second = owner.Bind(7, 3);
  ASSERT_TRUE(second.has_value());
  for (int attempt = 0; attempt < 20; ++attempt) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  const std::vector<mozc::prediction::Result> original = results;
  model.PostCorrect(request, results);
  EXPECT_EQ(results.size(), original.size());
  EXPECT_EQ(results[0].value, original[0].value);
  EXPECT_EQ(results[1].value, original[1].value);
  owner.StopAsyncExecutor();
}

TEST(KanaAiSupplementalModelTest, RejectsStaleSessionBindingBeforeApply) {
  KanaAiSupplementalModel model;
  SessionBindingOwner owner(model);
  const RerankRequest request = MakeRequest();
  std::vector<mozc::prediction::Result> results = MakeResults(request);
  const std::vector<mozc::prediction::Result> original = results;
  const RerankResponse response = MakeResponse(request);

  const std::optional<SessionBinding> first = owner.Bind(7, 2);
  ASSERT_TRUE(first.has_value());
  EXPECT_TRUE(owner.ApplyRerank(*first, request, response, &results));

  // A secure-field transition invalidates the old regular-field capability
  // before returning no binding to the optional executor.
  EXPECT_FALSE(owner.Bind(7, 2, SessionFieldClass::kPassword).has_value());
  EXPECT_FALSE(owner.ApplyRerank(*first, request, response, &results));
  const std::optional<SessionBinding> rebound = owner.Bind(7, 2);
  ASSERT_TRUE(rebound.has_value());

  results = original;
  EXPECT_FALSE(owner.Bind(7, 1).has_value());
  const std::optional<SessionBinding> newer = owner.Bind(7, 3);
  ASSERT_TRUE(newer.has_value());
  EXPECT_FALSE(owner.ApplyRerank(*first, request, response, &results));
  EXPECT_EQ(results[0].value, original[0].value);
  EXPECT_EQ(results[1].value, original[1].value);

  RerankRequest current_request = request;
  current_request.generation = 3;
  RerankResponse current_response = MakeResponse(current_request);
  EXPECT_TRUE(owner.ApplyRerank(*newer, current_request, current_response,
                                &results));
  owner.Invalidate(*newer);
  results = original;
  EXPECT_FALSE(owner.ApplyRerank(*newer, current_request, current_response,
                                 &results));
  EXPECT_EQ(results[0].value, original[0].value);
  EXPECT_EQ(results[1].value, original[1].value);
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
