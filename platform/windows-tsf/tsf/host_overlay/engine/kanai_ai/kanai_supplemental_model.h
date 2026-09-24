#ifndef KANAI_WINDOWS_TSF_KANAI_AI_SUPPLEMENTAL_MODEL_H_
#define KANAI_WINDOWS_TSF_KANAI_AI_SUPPLEMENTAL_MODEL_H_

#include <vector>

#include "absl/types/span.h"
#include "engine/kanai_ai/broker_contract.h"
#include "engine/supplemental_model_interface.h"
#include "prediction/result.h"
#include "request/conversion_request.h"

namespace kanai::tsf {

// Installed at Mozc's server-side supplemental-model seam, but intentionally
// inert until a per-context owner can provide kanai-broker session/generation
// tokens. It never calls a model or broker from a key/preedit callback.
class KanaAiSupplementalModel final
    : public mozc::engine::SupplementalModelInterface {
 public:
  bool IsAvailable() const override;
  void PostCorrect(
      const mozc::ConversionRequest& request,
      std::vector<mozc::prediction::Result>& results) const override;
  void RescoreResults(
      const mozc::ConversionRequest& request,
      absl::Span<mozc::prediction::Result> results) const override;

  // Predict, CorrectComposition, and DecodeEnglish remain inherited no-op
  // assist seams until separately designed and reviewed.
};

// Applies one already-validated asynchronous kanai-broker result to the exact
// Mozc result vector that produced its baseline. The request/response must be
// an exact permutation of the same candidate IDs, text, readings, and ranks.
// This function performs no I/O and is the safe handoff point for a future
// session-token-aware optional executor.
bool ApplyRerankToResults(
    const RerankRequest& request, const RerankResponse& response,
    std::vector<mozc::prediction::Result>* results);

}  // namespace kanai::tsf

#endif  // KANAI_WINDOWS_TSF_KANAI_AI_SUPPLEMENTAL_MODEL_H_
