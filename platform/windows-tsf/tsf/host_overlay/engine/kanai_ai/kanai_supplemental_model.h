#ifndef KANAI_WINDOWS_TSF_KANAI_AI_SUPPLEMENTAL_MODEL_H_
#define KANAI_WINDOWS_TSF_KANAI_AI_SUPPLEMENTAL_MODEL_H_

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <memory>
#include <optional>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "absl/types/span.h"
#include "engine/kanai_ai/broker_contract.h"
#include "engine/supplemental_model_interface.h"
#include "prediction/result.h"
#include "request/conversion_request.h"

namespace kanai::tsf {

class KanaAiSupplementalModel;
class SessionBindingOwner;

enum class SessionFieldClass {
  kRegular,
  kPassword,
  kProtected,
};

// Capability issued by the trusted TSF session owner. It is deliberately not
// part of the broker JSON contract: a value reconstructed by an untrusted
// ConversionRequest or client callback must never be accepted as a binding.
// Its fields are intentionally opaque outside the model/owner pair.
struct SessionBinding {
 private:
  friend class KanaAiSupplementalModel;
  friend class SessionBindingOwner;

  SessionBinding(std::uint64_t session_id, std::uint64_t generation,
                 std::uint64_t epoch, SessionFieldClass field_class)
      : session_id(session_id),
        generation(generation),
        epoch(epoch),
        field_class(field_class) {}

  std::uint64_t session_id = 0;
  std::uint64_t generation = 0;
  std::uint64_t epoch = 0;
  SessionFieldClass field_class = SessionFieldClass::kRegular;
};

// Installed at Mozc's server-side supplemental-model seam. The model remains
// inert by default; the trusted SessionHandler must bind a session and the
// Modules owner must start the bounded asynchronous transport worker. The
// worker may call the broker, but PostCorrect itself only performs an in-memory
// queue operation and never performs I/O from a key/preedit callback.
class KanaAiSupplementalModel final
    : public mozc::engine::SupplementalModelInterface {
 public:
  using RerankTransport =
      std::function<bool(const RerankRequest&, RerankResponse*)>;
  using SessionReleaseTransport =
      std::function<bool(std::uint64_t, std::uint64_t)>;

  ~KanaAiSupplementalModel() override;

  // The upstream Modules owner installs exactly one model instance. The
  // factory publishes that instance for the trusted TSF session owner without
  // exposing a client-supplied binding to Mozc callbacks.
  static std::unique_ptr<KanaAiSupplementalModel> Create();
  static KanaAiSupplementalModel* Global();

  // Called by the trusted server-side SessionHandler immediately before a
  // key/command dispatch. It creates a fresh opaque binding for that command;
  // an old worker response can therefore never be consumed by a later
  // conversion. Password/protected contexts advance the generation but leave
  // the model unavailable.
  static bool BeginMozcCommand(std::uint64_t session_id,
                               SessionFieldClass field_class);
  static void EndMozcSession(std::uint64_t session_id);

  bool IsAvailable() const override;

  // Starts the bounded worker from a trusted process owner. The overload is
  // also used by SessionBindingOwner so the worker and session capability
  // have one lifecycle.
  bool StartAsyncExecutor(RerankTransport transport,
                          std::size_t capacity = 4) {
    return StartAsyncExecutorInternal(std::move(transport), {}, capacity);
  }

  bool StartAsyncExecutor(RerankTransport transport,
                          SessionReleaseTransport release_transport,
                          std::size_t capacity = 4) {
    return StartAsyncExecutorInternal(std::move(transport),
                                      std::move(release_transport), capacity);
  }

  void PostCorrect(
      const mozc::ConversionRequest& request,
      std::vector<mozc::prediction::Result>& results) const override;
  void RescoreResults(
      const mozc::ConversionRequest& request,
      absl::Span<mozc::prediction::Result> results) const override;

  // Predict, CorrectComposition, and DecodeEnglish remain inherited no-op
  // assist seams until separately designed and reviewed.

 private:
  friend class SessionBindingOwner;

  // These operations are private so a client callback cannot manufacture a
  // trusted capability. Only SessionBindingOwner and the trusted server-side
  // BeginMozcCommand hook may issue or apply one. Secure field classes are
  // rejected at bind time and invalidate any previous regular-field binding.
  std::optional<SessionBinding> BindSession(std::uint64_t session_id,
                                           std::uint64_t generation,
                                           SessionFieldClass field_class);
  void InvalidateSession(const SessionBinding& binding);
  bool ApplyRerankForSession(const SessionBinding& binding,
                             const RerankRequest& request,
                             const RerankResponse& response,
                             std::vector<mozc::prediction::Result>* results);

  struct AsyncJob {
    SessionBinding binding;
    RerankRequest request;
  };

  struct ReadyRerank {
    SessionBinding binding;
    RerankRequest request;
    RerankResponse response;
  };

  struct AsyncReleaseJob {
    std::uint64_t session_id = 0;
    std::uint64_t generation = 0;
  };

  bool StartAsyncExecutorInternal(RerankTransport transport,
                                  SessionReleaseTransport release_transport,
                                  std::size_t capacity);
  void StopAsyncExecutorInternal();
  void AsyncWorker();
  bool EnqueueAsync(const SessionBinding& binding,
                    const RerankRequest& request) const;
  bool EnqueueReleaseAsync(std::uint64_t session_id,
                           std::uint64_t generation) const;
  void DropPendingAsync(std::uint64_t session_id) const;
  void DropPendingRerank(std::uint64_t session_id) const;
  bool PublishAsync(const SessionBinding& binding, const RerankRequest& request,
                    const RerankResponse& response);
  std::optional<RerankRequest> MakeRerankRequest(
      const mozc::ConversionRequest& request,
      const std::vector<mozc::prediction::Result>& results) const;

  mutable std::mutex binding_mutex_;
  std::optional<SessionBinding> active_binding_;
  std::uint64_t next_epoch_ = 0;
  mutable std::uint64_t next_request_id_ = 1;
  std::unordered_map<std::uint64_t, std::uint64_t> mozc_generations_;
  std::unordered_set<std::uint64_t> mozc_secure_sessions_;
  bool async_enabled_ = false;
  mutable std::optional<ReadyRerank> ready_rerank_;

  mutable std::mutex async_mutex_;
  mutable std::condition_variable async_cv_;
  mutable std::deque<AsyncJob> async_jobs_;
  mutable std::deque<AsyncReleaseJob> async_release_jobs_;
  mutable RerankTransport async_transport_;
  mutable SessionReleaseTransport async_release_transport_;
  mutable std::thread async_worker_;
  mutable std::size_t async_capacity_ = 0;
  mutable bool async_stopping_ = false;
};

// Process-local capability owner used by embedders and focused TSF lifecycle
// code. The staged SessionHandler uses the static BeginMozcCommand hook for
// the normal server path; this class remains available for explicit host
// integration/tests. It performs no I/O itself and remains separate from
// Mozc's key/preedit callbacks. Secure fields are rejected at bind time.
class SessionBindingOwner final {
 public:
  explicit SessionBindingOwner(KanaAiSupplementalModel& model) : model_(&model) {}

  SessionBindingOwner(const SessionBindingOwner&) = delete;
  SessionBindingOwner& operator=(const SessionBindingOwner&) = delete;
  SessionBindingOwner(SessionBindingOwner&&) = delete;
  SessionBindingOwner& operator=(SessionBindingOwner&&) = delete;

  std::optional<SessionBinding> Bind(
      std::uint64_t session_id, std::uint64_t generation,
      SessionFieldClass field_class = SessionFieldClass::kRegular) {
    return model_->BindSession(session_id, generation, field_class);
  }

  void Invalidate(const SessionBinding& binding) {
    model_->InvalidateSession(binding);
  }

  bool ApplyRerank(const SessionBinding& binding, const RerankRequest& request,
                   const RerankResponse& response,
                   std::vector<mozc::prediction::Result>* results) {
    return model_->ApplyRerankForSession(binding, request, response, results);
  }

  // Starts the non-blocking optional worker. The supplied transport is called
  // only on the worker thread; a key/preedit callback can still return the
  // Mozc baseline while the pipe is unavailable or slow.
  bool StartAsyncExecutor(
      KanaAiSupplementalModel::RerankTransport transport,
      std::size_t capacity = 4) {
    return model_->StartAsyncExecutorInternal(std::move(transport), {}, capacity);
  }

  bool StartAsyncExecutor(
      KanaAiSupplementalModel::RerankTransport transport,
      KanaAiSupplementalModel::SessionReleaseTransport release_transport,
      std::size_t capacity = 4) {
    return model_->StartAsyncExecutorInternal(
        std::move(transport), std::move(release_transport), capacity);
  }

  void StopAsyncExecutor() { model_->StopAsyncExecutorInternal(); }

  // Called by the worker after a transport response. It is public on the
  // trusted owner only so a TSF adapter can use the same validated handoff
  // without exposing model internals to Mozc callbacks.
  bool PublishRerank(const SessionBinding& binding, const RerankRequest& request,
                     const RerankResponse& response) {
    return model_->PublishAsync(binding, request, response);
  }

 private:
  KanaAiSupplementalModel* model_;
};

// Applies one already-validated asynchronous kanai-broker result to the exact
// Mozc result vector that produced its baseline. The request/response must be
// an exact permutation of the same candidate IDs, text, readings, and ranks.
// This function performs no I/O and is the safe handoff point for the
// session-token-aware optional executor.
bool ApplyRerankToResults(
    const RerankRequest& request, const RerankResponse& response,
    std::vector<mozc::prediction::Result>* results);

}  // namespace kanai::tsf

#endif  // KANAI_WINDOWS_TSF_KANAI_AI_SUPPLEMENTAL_MODEL_H_
