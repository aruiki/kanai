// Broker-facing data transfer objects for the Windows TSF candidate window.
//
// This header is an adapter seam, not a wire codec.  The TIP owns the private
// broker connection and is responsible for validating the broker envelope and
// decoding UTF-8 JSON (or the eventual private transport) into these types.
// The candidate window only receives bounded, already-normalized snapshots.
#ifndef KANAI_PLATFORM_WINDOWS_TSF_UI_BROKER_DTO_H_
#define KANAI_PLATFORM_WINDOWS_TSF_UI_BROKER_DTO_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace kanai::windows_tsf::ui {

// Keep this in lock-step with the broker/TIP adapter contract.  A mismatch is
// a hard error; the UI must not infer a missing field or start a conversion.
inline constexpr std::uint32_t kBrokerDtoVersion = 1;
// Defensive presentation bound. The broker owns the real page contract; the
// window truncates only after the TIP has validated a response.
inline constexpr std::size_t kUiCandidateLimit = 20;

// CandidateOrigin is presentation metadata only.  The broker remains the
// source of truth for ordering, explanation, and learning eligibility.
enum class CandidateOrigin : std::uint8_t {
  kConversion,
  kPrediction,
  kSuggestion,
  kUserDictionary,
  kUserHistory,
  kTypingCorrection,
  kSpellingCorrection,
  kUnknown,
};

struct BrokerPreeditSpanDto {
  // Values are UTF-16 after the TIP has decoded the broker response.  The
  // broker's public offsets are Unicode scalar values, not UTF-8 byte offsets.
  std::wstring value;
  std::optional<std::wstring> reading;
  bool highlighted = false;
};

struct BrokerCandidateDto {
  // candidate_id is opaque to the UI.  It is scoped to one request/generation
  // and must never be persisted, reused for another request, or treated as a
  // Mozc rank.  The current broker uses a signed integer on the wire, but the
  // UI keeps a signed 64-bit value so a future contract can widen it.
  std::int64_t candidate_id = 0;
  std::wstring text;

  // reading/description are optional presentation hints.  Empty is valid;
  // absent optional values must remain absent rather than being synthesized
  // from surrounding document text.
  std::optional<std::wstring> reading;
  std::wstring description;
  CandidateOrigin origin = CandidateOrigin::kUnknown;
  std::vector<std::wstring> attributes;
  bool learning_eligible = false;
  double score = 0.0;
};

struct BrokerCandidatePageDto {
  std::uint32_t contract_version = kBrokerDtoVersion;

  // generation and request_id are monotonic within a TIP session; request_id
  // is nonzero. The window drops a response older than the currently
  // presented response. A TIP
  // session epoch is owned by the TSF shell and must be checked before these
  // values are accepted by the broker.
  std::uint64_t generation = 0;
  std::uint64_t request_id = 0;

  std::size_t page_index = 0;
  std::size_t page_count = 1;
  bool has_next_page = false;

  std::wstring reading;
  std::wstring preedit;
  std::vector<BrokerPreeditSpanDto> preedit_segments;
  std::vector<BrokerCandidateDto> candidates;
  std::optional<std::size_t> focused_index;
};

enum class CandidateCommandKind : std::uint8_t {
  kCommit,
  kNextPage,
  kPreviousPage,
  kCancel,
};

// Commands are intentionally small and content-free except for the selected
// opaque ID.  The TSF adapter adds its session epoch and sends the command to
// the broker; the UI never performs ranking, conversion, learning, or I/O.
struct CandidateCommandDto {
  std::uint32_t contract_version = kBrokerDtoVersion;
  std::uint64_t generation = 0;
  std::uint64_t request_id = 0;
  CandidateCommandKind kind = CandidateCommandKind::kCancel;
  std::optional<std::int64_t> candidate_id;
  std::size_t page_index = 0;
};

}  // namespace kanai::windows_tsf::ui

#endif  // KANAI_PLATFORM_WINDOWS_TSF_UI_BROKER_DTO_H_
