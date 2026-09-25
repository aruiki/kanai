// C++ projection of KanaAI's canonical kanai-broker v1 DTOs and KBF1 framing.
//
// The Rust crate at crates/kanai-broker owns the semantic contract. This file
// implements only the native framing/JSON boundary required by the pinned
// Mozc supplemental-model seam. Portable tests validate the exact camelCase
// field names and bounded behavior.

#ifndef KANAI_WINDOWS_TSF_KANAI_AI_BROKER_CONTRACT_H_
#define KANAI_WINDOWS_TSF_KANAI_AI_BROKER_CONTRACT_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace kanai::tsf {

inline constexpr std::uint16_t kBrokerProtocolVersion = 1;
inline constexpr char kBrokerFrameMagic[] = "KBF1";
inline constexpr std::size_t kBrokerFrameHeaderSize = 8;
inline constexpr std::size_t kBrokerMaxPayloadSize = 1024 * 1024;
inline constexpr std::size_t kBrokerMaxAuthNonceBytes = 32;
inline constexpr std::size_t kBrokerMaxAuthProofBytes = 512;
inline constexpr std::size_t kBrokerMaxClientIdBytes = 128;
inline constexpr std::size_t kBrokerMaxContextBytes = 512;
inline constexpr std::size_t kBrokerMaxRerankCandidateBytes = 64 * 1024;
inline constexpr std::size_t kBrokerMaxEnhancementDeadlineMs = 2000;
inline constexpr std::size_t kNativeMaxRerankedCandidates = 5;
inline constexpr char kBrokerPipeNamePrefix[] =
    "\\\\.\\pipe\\KanaAI.TsfBroker.v1.";
inline constexpr wchar_t kBrokerWidePipeNamePrefix[] =
    L"\\\\.\\pipe\\KanaAI.TsfBroker.v1.";

enum class EnhancementStatus {
  kApplied,
  kFallback,
  kSkipped,
  kTimedOut,
  kCancelled,
  kRejected,
};

struct AuthRequest {
  std::uint16_t version = kBrokerProtocolVersion;
  std::string client_id;
  std::vector<std::uint8_t> nonce;
  std::vector<std::uint8_t> proof;
};

struct AuthResponse {
  std::uint16_t version = kBrokerProtocolVersion;
  bool accepted = false;
  std::optional<std::string> peer_client_id;
  std::optional<std::string> error;
};

struct BrokerCandidate {
  std::uint64_t id = 0;
  std::string text;
  std::optional<std::string> reading;
  std::uint16_t rank = 0;
};

struct PrepareRerankSessionRequest {
  std::uint64_t request_id = 0;
  std::uint64_t session_id = 0;
  std::uint64_t generation = 0;
};

struct GenerationResponse {
  std::uint64_t session_id = 0;
  std::uint64_t generation = 0;
};

struct ReleaseRerankSessionRequest {
  std::uint64_t request_id = 0;
  std::uint64_t session_id = 0;
  std::uint64_t generation = 0;
};

struct RerankRequest {
  std::uint64_t request_id = 0;
  std::uint64_t session_id = 0;
  std::uint64_t generation = 0;
  std::vector<BrokerCandidate> candidates;
  std::string context_before;
  std::string context_after;
  std::string policy_version = "v1";
  std::uint32_t deadline_ms = 250;
  std::uint64_t baseline_latency_micros = 0;
};

struct RerankResponse {
  std::uint64_t request_id = 0;
  std::uint64_t session_id = 0;
  std::uint64_t generation = 0;
  bool broker_success = false;
  EnhancementStatus status = EnhancementStatus::kFallback;
  std::vector<BrokerCandidate> baseline;
  std::vector<BrokerCandidate> ai;
  bool adopted = false;
  std::string fallback;
  std::string reason;
  std::string error_code;
};

bool IsValidUtf8(std::string_view value);
std::string MakeBrokerPipeName(std::uint32_t windows_session_id);

std::optional<std::vector<std::uint8_t>> EncodeBrokerFrame(
    std::string_view utf8_json_payload);
std::optional<std::string> DecodeBrokerFrame(
    std::span<const std::uint8_t> complete_frame);

std::optional<std::string> EncodeAuthRequestJson(
    const AuthRequest& request);
std::optional<AuthResponse> DecodeAuthResponseJson(
    std::string_view json, std::string_view expected_client_id);

std::optional<std::string> EncodePrepareRerankSessionJson(
    const PrepareRerankSessionRequest& request);
std::optional<GenerationResponse> DecodeGenerationResponseJson(
    std::string_view json, const PrepareRerankSessionRequest& expected_request);
std::optional<std::string> EncodeReleaseRerankSessionJson(
    const ReleaseRerankSessionRequest& request);
std::optional<GenerationResponse> DecodeFocusLostResponseJson(
    std::string_view json, const ReleaseRerankSessionRequest& expected_request);

std::optional<std::string> EncodeRerankRequestJson(
    const RerankRequest& request);
std::optional<RerankResponse> DecodeRerankResponseJson(
    std::string_view json, const RerankRequest& expected_request);

}  // namespace kanai::tsf

#endif  // KANAI_WINDOWS_TSF_KANAI_AI_BROKER_CONTRACT_H_
