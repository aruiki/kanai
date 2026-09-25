#include "engine/kanai_ai/kanai_supplemental_model.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "engine/kanai_ai/rank_policy.h"

namespace kanai::tsf {
namespace {

std::atomic<KanaAiSupplementalModel*> g_global_model{nullptr};

constexpr std::size_t kMaxAsyncQueueCapacity = 8;
constexpr std::size_t kMaxContextScalars = 32;
constexpr std::size_t kMaxContextBytes = 4 * 1024;
constexpr std::size_t kMaxCandidateTextBytes = 64 * 1024;

struct ScalarSpan {
  std::size_t begin;
  std::size_t end;
};

std::optional<std::vector<ScalarSpan>> GetScalarSpans(
    std::string_view value) {
  std::vector<ScalarSpan> spans;
  std::size_t offset = 0;
  while (offset < value.size()) {
    const auto lead = static_cast<unsigned char>(value[offset]);
    std::size_t width = 0;
    if (lead <= 0x7f) {
      width = 1;
    } else if (lead >= 0xc2 && lead <= 0xdf) {
      width = 2;
    } else if (lead >= 0xe0 && lead <= 0xef) {
      width = 3;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      width = 4;
    } else {
      return std::nullopt;
    }
    if (width > value.size() - offset) {
      return std::nullopt;
    }
    for (std::size_t index = 1; index < width; ++index) {
      const auto continuation = static_cast<unsigned char>(value[offset + index]);
      if ((continuation & 0xc0) != 0x80) {
        return std::nullopt;
      }
    }
    if (width == 1 && (lead < 0x20 || lead == 0x7f)) {
      return std::nullopt;
    }
    spans.push_back({offset, offset + width});
    offset += width;
  }
  return spans;
}

std::string TakeScalars(std::string_view value, std::size_t maximum,
                        bool from_end) {
  if (value.size() > kMaxContextBytes) {
    return {};
  }
  const auto spans = GetScalarSpans(value);
  if (!spans.has_value() || spans->empty() || maximum == 0) {
    return {};
  }
  const std::size_t count = std::min(maximum, spans->size());
  const std::size_t index = from_end ? spans->size() - count : 0;
  return std::string(value.substr((*spans)[index].begin,
                                  (*spans)[index + count - 1].end -
                                      (*spans)[index].begin));
}

bool IsBoundedCandidateText(std::string_view value, bool allow_empty) {
  if ((!allow_empty && value.empty()) || value.size() > kMaxCandidateTextBytes) {
    return false;
  }
  const auto spans = GetScalarSpans(value);
  return spans.has_value() && (allow_empty || !spans->empty());
}

}  // namespace

std::unique_ptr<KanaAiSupplementalModel>
KanaAiSupplementalModel::Create() {
  auto model = std::unique_ptr<KanaAiSupplementalModel>(
      new KanaAiSupplementalModel());
  KanaAiSupplementalModel* expected = nullptr;
  if (!g_global_model.compare_exchange_strong(expected, model.get())) {
    return nullptr;
  }
  return model;
}

KanaAiSupplementalModel* KanaAiSupplementalModel::Global() {
  return g_global_model.load(std::memory_order_acquire);
}

// The trusted SessionHandler maps the content-free "kanai.protected" context
// marker to SessionFieldClass::kProtected before calling this method.
bool KanaAiSupplementalModel::BeginMozcCommand(
    std::uint64_t session_id, SessionFieldClass field_class) {
  if (session_id == 0) {
    return false;
  }
  auto* model = Global();
  if (model == nullptr) {
    return false;
  }
  std::lock_guard<std::mutex> binding_lock(model->binding_mutex_);
  auto [iterator, inserted] =
      model->mozc_generations_.try_emplace(session_id, 0);
  if (iterator->second == std::numeric_limits<std::uint64_t>::max()) {
    return false;
  }
  ++iterator->second;
  if (field_class == SessionFieldClass::kRegular &&
      model->mozc_secure_sessions_.contains(session_id)) {
    field_class = SessionFieldClass::kProtected;
  }
  if (field_class != SessionFieldClass::kRegular) {
    model->mozc_secure_sessions_.insert(session_id);
    std::optional<std::uint64_t> release_generation;
    if (model->active_binding_.has_value() &&
        model->active_binding_->session_id == session_id) {
      release_generation = model->active_binding_->generation;
    }
    model->DropPendingRerank(session_id);
    if (release_generation.has_value()) {
      (void)model->EnqueueReleaseAsync(session_id, *release_generation);
    }
    model->active_binding_.reset();
    model->ready_rerank_.reset();
    return true;
  }
  if (model->next_epoch_ == std::numeric_limits<std::uint64_t>::max()) {
    return false;
  }
  ++model->next_epoch_;
  model->ready_rerank_.reset();
  model->active_binding_ = SessionBinding{
      session_id, iterator->second, model->next_epoch_, field_class};
  model->DropPendingAsync(session_id);
  (void)inserted;
  return true;
}

void KanaAiSupplementalModel::EndMozcSession(std::uint64_t session_id) {
  auto* model = Global();
  if (model == nullptr) {
    return;
  }
  std::optional<AsyncReleaseJob> release;
  {
    std::lock_guard<std::mutex> lock(model->binding_mutex_);
    model->mozc_generations_.erase(session_id);
    model->mozc_secure_sessions_.erase(session_id);
    if (model->active_binding_.has_value() &&
        model->active_binding_->session_id == session_id) {
      release = AsyncReleaseJob{session_id,
                                model->active_binding_->generation};
      model->active_binding_.reset();
    }
    model->ready_rerank_.reset();
  }
  if (release.has_value()) {
    (void)model->EnqueueReleaseAsync(release->session_id, release->generation);
  }
}

KanaAiSupplementalModel::~KanaAiSupplementalModel() {
  KanaAiSupplementalModel* expected = this;
  g_global_model.compare_exchange_strong(expected, nullptr);
  StopAsyncExecutorInternal();
}

bool KanaAiSupplementalModel::IsAvailable() const {
  std::lock_guard<std::mutex> lock(binding_mutex_);
  // The executor is opt-in. A model without a trusted binding and worker stays
  // completely inert, which preserves the pinned Mozc baseline.
  return async_enabled_ && active_binding_.has_value() &&
         active_binding_->field_class == SessionFieldClass::kRegular;
}

std::optional<SessionBinding> KanaAiSupplementalModel::BindSession(
    std::uint64_t session_id, std::uint64_t generation,
    SessionFieldClass field_class) {
  std::lock_guard<std::mutex> lock(binding_mutex_);
  if (field_class != SessionFieldClass::kRegular) {
    active_binding_.reset();
    ready_rerank_.reset();
    DropPendingAsync(session_id);
    return std::nullopt;
  }
  if (session_id == 0) {
    return std::nullopt;
  }
  if (active_binding_.has_value() &&
      active_binding_->session_id == session_id &&
      generation < active_binding_->generation) {
    return std::nullopt;
  }
  if (active_binding_.has_value() &&
      active_binding_->session_id == session_id &&
      active_binding_->generation == generation &&
      active_binding_->field_class == field_class) {
    return active_binding_;
  }
  if (next_epoch_ == std::numeric_limits<std::uint64_t>::max()) {
    return std::nullopt;
  }
  ++next_epoch_;
  ready_rerank_.reset();
  active_binding_ =
      SessionBinding{session_id, generation, next_epoch_, field_class};
  DropPendingAsync(session_id);
  return active_binding_;
}

void KanaAiSupplementalModel::InvalidateSession(
    const SessionBinding& binding) {
  std::lock_guard<std::mutex> lock(binding_mutex_);
  if (active_binding_.has_value() &&
      active_binding_->session_id == binding.session_id &&
      active_binding_->generation == binding.generation &&
      active_binding_->epoch == binding.epoch) {
    active_binding_.reset();
    ready_rerank_.reset();
    DropPendingAsync(binding.session_id);
  }
}

bool KanaAiSupplementalModel::ApplyRerankForSession(
    const SessionBinding& binding, const RerankRequest& request,
    const RerankResponse& response,
    std::vector<mozc::prediction::Result>* results) {
  if (results == nullptr) {
    return false;
  }
  std::lock_guard<std::mutex> lock(binding_mutex_);
  if (!active_binding_.has_value() ||
      active_binding_->session_id != binding.session_id ||
      active_binding_->generation != binding.generation ||
      active_binding_->epoch != binding.epoch ||
      active_binding_->field_class != SessionFieldClass::kRegular ||
      binding.field_class != SessionFieldClass::kRegular ||
      request.session_id != binding.session_id ||
      request.generation != binding.generation) {
    return false;
  }
  return ApplyRerankToResults(request, response, results);
}

bool KanaAiSupplementalModel::StartAsyncExecutorInternal(
    RerankTransport transport, SessionReleaseTransport release_transport,
    std::size_t capacity) {
  if (!transport || capacity == 0 || capacity > kMaxAsyncQueueCapacity) {
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(async_mutex_);
    if (async_worker_.joinable() || async_stopping_) {
      return false;
    }
    async_transport_ = std::move(transport);
    async_release_transport_ = std::move(release_transport);
    async_capacity_ = capacity;
    async_stopping_ = false;
  }
  {
    std::lock_guard<std::mutex> lock(binding_mutex_);
    async_enabled_ = true;
  }
  try {
    async_worker_ = std::thread([this] { AsyncWorker(); });
  } catch (...) {
    {
      std::lock_guard<std::mutex> lock(async_mutex_);
      async_transport_ = nullptr;
      async_release_transport_ = nullptr;
      async_release_jobs_.clear();
      async_capacity_ = 0;
      async_stopping_ = true;
    }
    std::lock_guard<std::mutex> lock(binding_mutex_);
    async_enabled_ = false;
    return false;
  }
  return true;
}

void KanaAiSupplementalModel::StopAsyncExecutorInternal() {
  bool called_from_worker = false;
  {
    std::lock_guard<std::mutex> lock(async_mutex_);
    called_from_worker = async_worker_.joinable() &&
                         async_worker_.get_id() == std::this_thread::get_id();
    async_stopping_ = true;
    async_jobs_.clear();
    async_release_jobs_.clear();
  }
  async_cv_.notify_all();
  if (!called_from_worker && async_worker_.joinable()) {
    async_worker_.join();
  }
  {
    std::lock_guard<std::mutex> lock(async_mutex_);
    async_transport_ = nullptr;
    async_release_transport_ = nullptr;
    async_release_jobs_.clear();
    async_capacity_ = 0;
  }
  {
    std::lock_guard<std::mutex> lock(binding_mutex_);
    async_enabled_ = false;
    ready_rerank_.reset();
  }
}

void KanaAiSupplementalModel::AsyncWorker() {
  for (;;) {
    std::optional<AsyncJob> rerank_job;
    std::optional<AsyncReleaseJob> release_job;
    RerankTransport rerank_transport;
    SessionReleaseTransport release_transport;
    {
      std::unique_lock<std::mutex> lock(async_mutex_);
      async_cv_.wait(lock, [this] {
        return async_stopping_ || !async_jobs_.empty() ||
               !async_release_jobs_.empty();
      });
      if (async_stopping_) {
        return;
      }
      // Release work is preferred so a deleted focus does not leave a
      // rerank-only broker session behind a slow optional request.
      if (!async_release_jobs_.empty()) {
        release_job = async_release_jobs_.front();
        async_release_jobs_.pop_front();
        release_transport = async_release_transport_;
      } else {
        rerank_job.emplace(std::move(async_jobs_.front()));
        async_jobs_.pop_front();
        rerank_transport = async_transport_;
      }
    }
    try {
      if (release_job.has_value() && release_transport) {
        (void)release_transport(release_job->session_id,
                                release_job->generation);
      } else if (rerank_job.has_value() && rerank_transport) {
        RerankResponse response;
        if (rerank_transport(rerank_job->request, &response)) {
          PublishAsync(rerank_job->binding, rerank_job->request, response);
        }
      }
    } catch (...) {
      // A provider/client failure is a baseline fallback; never let an
      // optional transport exception terminate the Mozc process.
    }
  }
}

bool KanaAiSupplementalModel::EnqueueAsync(const SessionBinding& binding,
                                            const RerankRequest& request) const {
  std::lock_guard<std::mutex> lock(async_mutex_);
  if (async_stopping_ || !async_transport_ || async_capacity_ == 0) {
    return false;
  }
  // A session only needs its newest candidate window. Dropping an older
  // window is safe and prevents a fast typist from filling the optional queue.
  for (auto iterator = async_jobs_.begin(); iterator != async_jobs_.end();) {
    if (iterator->binding.session_id == binding.session_id) {
      iterator = async_jobs_.erase(iterator);
    } else {
      ++iterator;
    }
  }
  for (auto iterator = async_release_jobs_.begin();
       iterator != async_release_jobs_.end();) {
    if (iterator->session_id == binding.session_id) {
      iterator = async_release_jobs_.erase(iterator);
    } else {
      ++iterator;
    }
  }
  if (async_jobs_.size() + async_release_jobs_.size() >= async_capacity_) {
    return false;
  }
  async_jobs_.push_back(AsyncJob{binding, request});
  async_cv_.notify_one();
  return true;
}

bool KanaAiSupplementalModel::EnqueueReleaseAsync(
    std::uint64_t session_id, std::uint64_t generation) const {
  std::lock_guard<std::mutex> lock(async_mutex_);
  if (async_stopping_ || !async_release_transport_ || async_capacity_ == 0) {
    return false;
  }
  for (auto iterator = async_jobs_.begin(); iterator != async_jobs_.end();) {
    if (iterator->binding.session_id == session_id) {
      iterator = async_jobs_.erase(iterator);
    } else {
      ++iterator;
    }
  }
  for (auto iterator = async_release_jobs_.begin();
       iterator != async_release_jobs_.end();) {
    if (iterator->session_id == session_id) {
      iterator = async_release_jobs_.erase(iterator);
    } else {
      ++iterator;
    }
  }
  if (async_jobs_.size() + async_release_jobs_.size() >= async_capacity_) {
    // Release is a lifecycle cleanup and takes priority over optional work.
    if (!async_jobs_.empty()) {
      async_jobs_.pop_front();
    } else if (!async_release_jobs_.empty()) {
      async_release_jobs_.pop_front();
    }
  }
  async_release_jobs_.push_back(AsyncReleaseJob{session_id, generation});
  async_cv_.notify_one();
  return true;
}

void KanaAiSupplementalModel::DropPendingAsync(std::uint64_t session_id) const {
  std::lock_guard<std::mutex> lock(async_mutex_);
  for (auto iterator = async_jobs_.begin(); iterator != async_jobs_.end();) {
    if (iterator->binding.session_id == session_id) {
      iterator = async_jobs_.erase(iterator);
    } else {
      ++iterator;
    }
  }
  for (auto iterator = async_release_jobs_.begin();
       iterator != async_release_jobs_.end();) {
    if (iterator->session_id == session_id) {
      iterator = async_release_jobs_.erase(iterator);
    } else {
      ++iterator;
    }
  }
}

void KanaAiSupplementalModel::DropPendingRerank(std::uint64_t session_id) const {
  std::lock_guard<std::mutex> lock(async_mutex_);
  for (auto iterator = async_jobs_.begin(); iterator != async_jobs_.end();) {
    if (iterator->binding.session_id == session_id) {
      iterator = async_jobs_.erase(iterator);
    } else {
      ++iterator;
    }
  }
}

bool KanaAiSupplementalModel::PublishAsync(
    const SessionBinding& binding, const RerankRequest& request,
    const RerankResponse& response) {
  if (!MapAiOrderToRanks(request, response).has_value()) {
    return false;
  }
  std::lock_guard<std::mutex> lock(binding_mutex_);
  if (!active_binding_.has_value() ||
      active_binding_->session_id != binding.session_id ||
      active_binding_->generation != binding.generation ||
      active_binding_->epoch != binding.epoch ||
      active_binding_->field_class != SessionFieldClass::kRegular ||
      binding.field_class != SessionFieldClass::kRegular ||
      request.session_id != binding.session_id ||
      request.generation != binding.generation) {
    return false;
  }
  ready_rerank_ = ReadyRerank{binding, request, response};
  return true;
}

std::optional<RerankRequest> KanaAiSupplementalModel::MakeRerankRequest(
    const mozc::ConversionRequest& request,
    const std::vector<mozc::prediction::Result>& results) const {
  if (!active_binding_.has_value() || results.size() < 2 ||
      results.size() > kNativeMaxRerankedCandidates) {
    return std::nullopt;
  }
  RerankRequest rerank;
  rerank.request_id = next_request_id_;
  next_request_id_ = next_request_id_ ==
                             std::numeric_limits<std::uint64_t>::max()
                         ? 1
                         : next_request_id_ + 1;
  rerank.session_id = active_binding_->session_id;
  rerank.generation = active_binding_->generation;
  rerank.candidates.reserve(results.size());
  for (std::size_t index = 0; index < results.size(); ++index) {
    const mozc::prediction::Result& result = results[index];
    if (!IsBoundedCandidateText(result.value, false) ||
        (!result.key.empty() && !IsBoundedCandidateText(result.key, false))) {
      return std::nullopt;
    }
    BrokerCandidate candidate;
    candidate.id = static_cast<std::uint64_t>(index + 1);
    candidate.text = result.value;
    if (!result.key.empty()) {
      candidate.reading = result.key;
    }
    candidate.rank = static_cast<std::uint16_t>(index);
    rerank.candidates.push_back(std::move(candidate));
  }
  const auto context = request.GetSurroundingContext();
  rerank.context_before = TakeScalars(context.first, kMaxContextScalars, true);
  rerank.context_after = TakeScalars(context.second, kMaxContextScalars, false);
  if (rerank.context_before.empty() && !request.key().empty()) {
    rerank.context_before = TakeScalars(request.key(), kMaxContextScalars, true);
  }
  rerank.policy_version = "v1";
  rerank.deadline_ms = 250;
  return rerank;
}

void KanaAiSupplementalModel::PostCorrect(
    const mozc::ConversionRequest& request,
    std::vector<mozc::prediction::Result>& results) const {
  std::optional<AsyncJob> job;
  {
    std::lock_guard<std::mutex> lock(binding_mutex_);
    if (!async_enabled_ || !active_binding_.has_value() ||
        active_binding_->field_class != SessionFieldClass::kRegular) {
      return;
    }
    if (ready_rerank_.has_value()) {
      const bool matches =
          ready_rerank_->binding.session_id == active_binding_->session_id &&
          ready_rerank_->binding.generation == active_binding_->generation &&
          ready_rerank_->binding.epoch == active_binding_->epoch &&
          ready_rerank_->request.session_id == active_binding_->session_id &&
          ready_rerank_->request.generation == active_binding_->generation;
      if (matches &&
          ApplyRerankToResults(ready_rerank_->request, ready_rerank_->response,
                               &results)) {
        ready_rerank_.reset();
        return;
      }
      ready_rerank_.reset();
    }
    auto rerank = MakeRerankRequest(request, results);
    if (!rerank.has_value()) {
      return;
    }
    job = AsyncJob{*active_binding_, std::move(*rerank)};
  }
  // This only appends to a bounded in-memory queue. The actual pipe call is
  // performed by AsyncWorker and can never block Mozc's key/preedit callback.
  EnqueueAsync(job->binding, job->request);
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
