#include "engine/kanai_ai/broker_contract.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <iterator>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace kanai::tsf {
namespace {

constexpr std::size_t kMaxRerankTextBytes = 16 * 1024;
constexpr std::size_t kMaxPolicyVersionBytes = 64;
constexpr std::size_t kMaxProviderIdBytes = 64;
constexpr std::size_t kMaxErrorMessageBytes = 512;

void AppendU32(std::vector<std::uint8_t>* output, std::uint32_t value) {
  output->push_back(static_cast<std::uint8_t>((value >> 24) & 0xffU));
  output->push_back(static_cast<std::uint8_t>((value >> 16) & 0xffU));
  output->push_back(static_cast<std::uint8_t>((value >> 8) & 0xffU));
  output->push_back(static_cast<std::uint8_t>(value & 0xffU));
}

std::uint32_t ReadU32(const std::uint8_t* bytes) {
  return (static_cast<std::uint32_t>(bytes[0]) << 24) |
         (static_cast<std::uint32_t>(bytes[1]) << 16) |
         (static_cast<std::uint32_t>(bytes[2]) << 8) |
         static_cast<std::uint32_t>(bytes[3]);
}

void AppendJsonString(std::string* output, std::string_view value) {
  static constexpr char kHex[] = "0123456789abcdef";
  output->push_back('"');
  for (const char character : value) {
    const auto byte = static_cast<unsigned char>(character);
    switch (character) {
      case '"':
        *output += "\\\"";
        break;
      case '\\':
        *output += "\\\\";
        break;
      case '\b':
        *output += "\\b";
        break;
      case '\f':
        *output += "\\f";
        break;
      case '\n':
        *output += "\\n";
        break;
      case '\r':
        *output += "\\r";
        break;
      case '\t':
        *output += "\\t";
        break;
      default:
        if (byte < 0x20U) {
          *output += "\\u00";
          output->push_back(kHex[(byte >> 4) & 0x0fU]);
          output->push_back(kHex[byte & 0x0fU]);
        } else {
          output->push_back(character);
        }
        break;
    }
  }
  output->push_back('"');
}

void AppendJsonBytes(std::string* output, const std::vector<std::uint8_t>& bytes) {
  output->push_back('[');
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    if (index != 0) {
      output->push_back(',');
    }
    *output += std::to_string(static_cast<unsigned int>(bytes[index]));
  }
  output->push_back(']');
}

void AppendU64Json(std::string* output, std::uint64_t value) {
  *output += std::to_string(value);
}

class JsonValue {
 public:
  enum class Type {
    kNull,
    kBoolean,
    kNumber,
    kString,
    kArray,
    kObject,
  };

  Type type = Type::kNull;
  bool boolean = false;
  std::uint64_t number = 0;
  std::string string;
  std::vector<JsonValue> array;
  std::vector<std::pair<std::string, JsonValue>> object;

  const JsonValue* Find(std::string_view key) const {
    for (const auto& entry : object) {
      if (entry.first == key) {
        return &entry.second;
      }
    }
    return nullptr;
  }
};

class JsonParser {
 public:
  explicit JsonParser(std::string_view input) : input_(input) {}

  std::optional<JsonValue> Parse() {
    JsonValue result;
    if (!ParseValue(&result)) {
      return std::nullopt;
    }
    SkipWhitespace();
    if (position_ != input_.size() || !IsValidUtf8(input_)) {
      return std::nullopt;
    }
    return result;
  }

 private:
  void SkipWhitespace() {
    while (position_ < input_.size() &&
           (input_[position_] == ' ' || input_[position_] == '\t' ||
            input_[position_] == '\r' || input_[position_] == '\n')) {
      ++position_;
    }
  }

  bool Consume(char expected) {
    SkipWhitespace();
    if (position_ >= input_.size() || input_[position_] != expected) {
      return false;
    }
    ++position_;
    return true;
  }

  bool ParseValue(JsonValue* output) {
    SkipWhitespace();
    if (position_ >= input_.size()) {
      return false;
    }
    switch (input_[position_]) {
      case 'n':
        return ParseLiteral("null", JsonValue::Type::kNull, output);
      case 't':
        return ParseLiteral("true", JsonValue::Type::kBoolean, output, true);
      case 'f':
        return ParseLiteral("false", JsonValue::Type::kBoolean, output,
                            false);
      case '"':
        output->type = JsonValue::Type::kString;
        return ParseString(&output->string);
      case '[':
        return ParseArray(output);
      case '{':
        return ParseObject(output);
      default:
        if (input_[position_] >= '0' && input_[position_] <= '9') {
          return ParseNumber(output);
        }
        return false;
    }
  }

  bool ParseLiteral(std::string_view literal, JsonValue::Type type,
                    JsonValue* output, bool boolean_value = false) {
    if (input_.substr(position_, literal.size()) != literal) {
      return false;
    }
    position_ += literal.size();
    output->type = type;
    output->boolean = boolean_value;
    return true;
  }

  bool ParseNumber(JsonValue* output) {
    const std::size_t start = position_;
    if (input_[position_] == '0') {
      ++position_;
    } else {
      if (input_[position_] < '1' || input_[position_] > '9') {
        return false;
      }
      while (position_ < input_.size() && input_[position_] >= '0' &&
             input_[position_] <= '9') {
        ++position_;
      }
    }
    if (position_ < input_.size() &&
        (input_[position_] == '.' || input_[position_] == 'e' ||
         input_[position_] == 'E' || input_[position_] == '-' ||
         input_[position_] == '+')) {
      return false;
    }
    std::uint64_t value = 0;
    for (std::size_t index = start; index < position_; ++index) {
      const std::uint64_t digit =
          static_cast<std::uint64_t>(input_[index] - '0');
      if (value > (std::numeric_limits<std::uint64_t>::max() - digit) / 10) {
        return false;
      }
      value = value * 10 + digit;
    }
    output->type = JsonValue::Type::kNumber;
    output->number = value;
    return true;
  }

  static void AppendUtf8(std::string* output, std::uint32_t code_point) {
    if (code_point <= 0x7fU) {
      output->push_back(static_cast<char>(code_point));
    } else if (code_point <= 0x7ffU) {
      output->push_back(static_cast<char>(0xc0U | (code_point >> 6)));
      output->push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
    } else if (code_point <= 0xffffU) {
      output->push_back(static_cast<char>(0xe0U | (code_point >> 12)));
      output->push_back(
          static_cast<char>(0x80U | ((code_point >> 6) & 0x3fU)));
      output->push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
    } else {
      output->push_back(static_cast<char>(0xf0U | (code_point >> 18)));
      output->push_back(
          static_cast<char>(0x80U | ((code_point >> 12) & 0x3fU)));
      output->push_back(
          static_cast<char>(0x80U | ((code_point >> 6) & 0x3fU)));
      output->push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
    }
  }

  bool ParseHex4(std::uint32_t* value) {
    if (input_.size() - position_ < 4) {
      return false;
    }
    std::uint32_t parsed = 0;
    for (int index = 0; index < 4; ++index) {
      const char character = input_[position_++];
      parsed <<= 4;
      if (character >= '0' && character <= '9') {
        parsed |= static_cast<std::uint32_t>(character - '0');
      } else if (character >= 'a' && character <= 'f') {
        parsed |= static_cast<std::uint32_t>(character - 'a' + 10);
      } else if (character >= 'A' && character <= 'F') {
        parsed |= static_cast<std::uint32_t>(character - 'A' + 10);
      } else {
        return false;
      }
    }
    *value = parsed;
    return true;
  }

  bool ParseString(std::string* output) {
    if (!Consume('"')) {
      return false;
    }
    output->clear();
    while (position_ < input_.size()) {
      const unsigned char character =
          static_cast<unsigned char>(input_[position_++]);
      if (character == '"') {
        return IsValidUtf8(*output);
      }
      if (character < 0x20U) {
        return false;
      }
      if (character != '\\') {
        output->push_back(static_cast<char>(character));
        continue;
      }
      if (position_ >= input_.size()) {
        return false;
      }
      const char escape = input_[position_++];
      switch (escape) {
        case '"':
        case '\\':
        case '/':
          output->push_back(escape);
          break;
        case 'b':
          output->push_back('\b');
          break;
        case 'f':
          output->push_back('\f');
          break;
        case 'n':
          output->push_back('\n');
          break;
        case 'r':
          output->push_back('\r');
          break;
        case 't':
          output->push_back('\t');
          break;
        case 'u': {
          std::uint32_t code_point = 0;
          if (!ParseHex4(&code_point)) {
            return false;
          }
          if (code_point >= 0xd800U && code_point <= 0xdbffU) {
            if (input_.size() - position_ < 6 || input_[position_] != '\\' ||
                input_[position_ + 1] != 'u') {
              return false;
            }
            position_ += 2;
            std::uint32_t low = 0;
            if (!ParseHex4(&low) || low < 0xdc00U || low > 0xdfffU) {
              return false;
            }
            code_point = 0x10000U + ((code_point - 0xd800U) << 10) +
                         (low - 0xdc00U);
          } else if (code_point >= 0xdc00U && code_point <= 0xdfffU) {
            return false;
          }
          AppendUtf8(output, code_point);
          break;
        }
        default:
          return false;
      }
    }
    return false;
  }

  bool ParseArray(JsonValue* output) {
    if (!Consume('[')) {
      return false;
    }
    output->type = JsonValue::Type::kArray;
    SkipWhitespace();
    if (Consume(']')) {
      return true;
    }
    for (;;) {
      JsonValue element;
      if (!ParseValue(&element)) {
        return false;
      }
      output->array.push_back(std::move(element));
      if (Consume(']')) {
        return true;
      }
      if (!Consume(',')) {
        return false;
      }
    }
  }

  bool ParseObject(JsonValue* output) {
    if (!Consume('{')) {
      return false;
    }
    output->type = JsonValue::Type::kObject;
    SkipWhitespace();
    if (Consume('}')) {
      return true;
    }
    for (;;) {
      std::string key;
      if (!ParseString(&key) || output->Find(key) != nullptr ||
          !Consume(':')) {
        return false;
      }
      JsonValue value;
      if (!ParseValue(&value)) {
        return false;
      }
      output->object.emplace_back(std::move(key), std::move(value));
      if (Consume('}')) {
        return true;
      }
      if (!Consume(',')) {
        return false;
      }
    }
  }

  std::string_view input_;
  std::size_t position_ = 0;
};

const JsonValue* FindTyped(const JsonValue& object, std::string_view key,
                           JsonValue::Type type) {
  if (object.type != JsonValue::Type::kObject) {
    return nullptr;
  }
  const JsonValue* value = object.Find(key);
  return value != nullptr && value->type == type ? value : nullptr;
}

bool ReadU64(const JsonValue& object, std::string_view key,
             std::uint64_t* value) {
  const JsonValue* field = FindTyped(object, key, JsonValue::Type::kNumber);
  if (field == nullptr || value == nullptr) {
    return false;
  }
  *value = field->number;
  return true;
}

bool ReadU16(const JsonValue& object, std::string_view key, std::uint16_t* value) {
  std::uint64_t parsed = 0;
  if (!ReadU64(object, key, &parsed) || parsed > 0xffffU || value == nullptr) {
    return false;
  }
  *value = static_cast<std::uint16_t>(parsed);
  return true;
}

bool ReadU32(const JsonValue& object, std::string_view key, std::uint32_t* value) {
  std::uint64_t parsed = 0;
  if (!ReadU64(object, key, &parsed) || parsed > 0xffffffffU || value == nullptr) {
    return false;
  }
  *value = static_cast<std::uint32_t>(parsed);
  return true;
}

bool ReadBool(const JsonValue& object, std::string_view key, bool* value) {
  const JsonValue* field = FindTyped(object, key, JsonValue::Type::kBoolean);
  if (field == nullptr || value == nullptr) {
    return false;
  }
  *value = field->boolean;
  return true;
}

bool ReadString(const JsonValue& object, std::string_view key,
                std::string* value) {
  const JsonValue* field = FindTyped(object, key, JsonValue::Type::kString);
  if (field == nullptr || value == nullptr) {
    return false;
  }
  *value = field->string;
  return true;
}

bool HasControlCharacter(std::string_view value) {
  for (const char character : value) {
    const auto byte = static_cast<unsigned char>(character);
    if (byte < 0x20U || byte == 0x7fU) {
      return true;
    }
  }
  return false;
}

bool ValidBoundedText(std::string_view value, std::size_t maximum,
                      bool allow_empty) {
  return (allow_empty || !value.empty()) && value.size() <= maximum &&
         IsValidUtf8(value) && !HasControlCharacter(value);
}

std::optional<EnhancementStatus> ParseEnhancementStatus(
    std::string_view value) {
  if (value == "applied") return EnhancementStatus::kApplied;
  if (value == "fallback") return EnhancementStatus::kFallback;
  if (value == "skipped") return EnhancementStatus::kSkipped;
  if (value == "timedOut") return EnhancementStatus::kTimedOut;
  if (value == "cancelled") return EnhancementStatus::kCancelled;
  if (value == "rejected") return EnhancementStatus::kRejected;
  return std::nullopt;
}

bool IsValidFallbackMode(std::string_view value) {
  return value == "none" || value == "directInput" ||
         value == "lastValidPreedit";
}

bool IsValidEnhancementReason(std::string_view value) {
  static constexpr std::string_view kReasons[] = {
      "none",           "secureField",     "policyDisabled",
      "consentRequired", "noBaseline",      "noChange",
      "providerTimeout", "providerUnavailable", "providerRejected",
      "invalidResult",  "staleGeneration", "cancelled"};
  return std::find(std::begin(kReasons), std::end(kReasons), value) !=
         std::end(kReasons);
}

bool ValidateCandidate(const BrokerCandidate& candidate,
                       std::size_t* aggregate_bytes) {
  if (candidate.id == 0 ||
      !ValidBoundedText(candidate.text, kMaxRerankTextBytes, false)) {
    return false;
  }
  std::size_t candidate_bytes = candidate.text.size();
  if (candidate.reading.has_value()) {
    if (!ValidBoundedText(*candidate.reading, kMaxRerankTextBytes, false)) {
      return false;
    }
    candidate_bytes += candidate.reading->size();
  }
  if (candidate_bytes > kBrokerMaxRerankCandidateBytes ||
      *aggregate_bytes > kBrokerMaxRerankCandidateBytes - candidate_bytes) {
    return false;
  }
  *aggregate_bytes += candidate_bytes;
  return true;
}

bool SameCandidate(const BrokerCandidate& lhs, const BrokerCandidate& rhs) {
  return lhs.id == rhs.id && lhs.text == rhs.text &&
         lhs.reading == rhs.reading && lhs.rank == rhs.rank;
}

std::optional<BrokerCandidate> ParseCandidate(const JsonValue& value) {
  if (value.type != JsonValue::Type::kObject) {
    return std::nullopt;
  }
  BrokerCandidate candidate;
  if (!ReadU64(value, "id", &candidate.id) ||
      !ReadString(value, "text", &candidate.text) ||
      !ReadU16(value, "rank", &candidate.rank)) {
    return std::nullopt;
  }
  const JsonValue* reading = value.Find("reading");
  if (reading != nullptr) {
    if (reading->type != JsonValue::Type::kString) {
      return std::nullopt;
    }
    candidate.reading = reading->string;
  }
  std::size_t aggregate = 0;
  if (!ValidateCandidate(candidate, &aggregate)) {
    return std::nullopt;
  }
  return candidate;
}

bool ValidateCandidateList(const std::vector<BrokerCandidate>& candidates,
                           std::size_t maximum_count) {
  if (candidates.empty() || candidates.size() > maximum_count) {
    return false;
  }
  std::size_t aggregate = 0;
  for (std::size_t index = 0; index < candidates.size(); ++index) {
    if (!ValidateCandidate(candidates[index], &aggregate)) {
      return false;
    }
    for (std::size_t prior = 0; prior < index; ++prior) {
      if (candidates[prior].id == candidates[index].id) {
        return false;
      }
    }
  }
  return true;
}

bool ValidateRerankRequest(const RerankRequest& request) {
  if (request.request_id == 0 || request.session_id == 0 ||
      request.candidates.size() < 2 ||
      request.candidates.size() > kNativeMaxRerankedCandidates ||
      !ValidBoundedText(request.context_before, kBrokerMaxContextBytes, true) ||
      !ValidBoundedText(request.context_after, kBrokerMaxContextBytes, true) ||
      !ValidBoundedText(request.policy_version, kMaxPolicyVersionBytes, false) ||
      request.deadline_ms == 0 ||
      request.deadline_ms > kBrokerMaxEnhancementDeadlineMs) {
    return false;
  }
  return ValidateCandidateList(request.candidates, kNativeMaxRerankedCandidates);
}

}  // namespace

bool IsValidUtf8(std::string_view value) {
  const auto* bytes = reinterpret_cast<const unsigned char*>(value.data());
  const std::size_t size = value.size();
  for (std::size_t index = 0; index < size;) {
    const std::uint8_t first = bytes[index];
    if (first <= 0x7fU) {
      ++index;
      continue;
    }
    std::size_t continuation_count = 0;
    std::uint8_t second_min = 0x80U;
    std::uint8_t second_max = 0xbfU;
    if (first >= 0xc2U && first <= 0xdfU) {
      continuation_count = 1;
    } else if (first >= 0xe0U && first <= 0xefU) {
      continuation_count = 2;
      if (first == 0xe0U) second_min = 0xa0U;
      if (first == 0xedU) second_max = 0x9fU;
    } else if (first >= 0xf0U && first <= 0xf4U) {
      continuation_count = 3;
      if (first == 0xf0U) second_min = 0x90U;
      if (first == 0xf4U) second_max = 0x8fU;
    } else {
      return false;
    }
    if (continuation_count == 0 || size - index <= continuation_count) {
      return false;
    }
    if (bytes[index + 1] < second_min || bytes[index + 1] > second_max) {
      return false;
    }
    for (std::size_t offset = 2; offset <= continuation_count; ++offset) {
      if (bytes[index + offset] < 0x80U || bytes[index + offset] > 0xbfU) {
        return false;
      }
    }
    index += continuation_count + 1;
  }
  return true;
}

std::string MakeBrokerPipeName(std::uint32_t windows_session_id) {
  return std::string(kBrokerPipeNamePrefix) +
         std::to_string(windows_session_id);
}

std::optional<std::vector<std::uint8_t>> EncodeBrokerFrame(
    std::string_view utf8_json_payload) {
  if (utf8_json_payload.empty() ||
      utf8_json_payload.size() > kBrokerMaxPayloadSize ||
      utf8_json_payload.size() > 0xffffffffU ||
      !IsValidUtf8(utf8_json_payload)) {
    return std::nullopt;
  }
  std::vector<std::uint8_t> frame;
  frame.reserve(kBrokerFrameHeaderSize + utf8_json_payload.size());
  frame.insert(frame.end(), kBrokerFrameMagic,
               kBrokerFrameMagic + std::char_traits<char>::length(
                                         kBrokerFrameMagic));
  AppendU32(&frame, static_cast<std::uint32_t>(utf8_json_payload.size()));
  frame.insert(frame.end(), utf8_json_payload.begin(),
               utf8_json_payload.end());
  return frame;
}

std::optional<std::string> DecodeBrokerFrame(
    std::span<const std::uint8_t> complete_frame) {
  if (complete_frame.size() < kBrokerFrameHeaderSize ||
      !std::equal(kBrokerFrameMagic,
                  kBrokerFrameMagic + std::char_traits<char>::length(
                                          kBrokerFrameMagic),
                  complete_frame.begin())) {
    return std::nullopt;
  }
  const std::uint32_t payload_size = ReadU32(complete_frame.data() + 4);
  if (payload_size == 0 || payload_size > kBrokerMaxPayloadSize ||
      complete_frame.size() !=
          kBrokerFrameHeaderSize + static_cast<std::size_t>(payload_size)) {
    return std::nullopt;
  }
  const auto* payload = complete_frame.data() + kBrokerFrameHeaderSize;
  std::string result(reinterpret_cast<const char*>(payload), payload_size);
  return IsValidUtf8(result) ? std::optional<std::string>(std::move(result))
                             : std::nullopt;
}

std::optional<std::string> EncodeAuthRequestJson(const AuthRequest& request) {
  if (request.version != kBrokerProtocolVersion ||
      !ValidBoundedText(request.client_id, kBrokerMaxClientIdBytes, false) ||
      request.nonce.size() != kBrokerMaxAuthNonceBytes ||
      request.proof.empty() ||
      request.proof.size() > kBrokerMaxAuthProofBytes ||
      std::all_of(request.nonce.begin(), request.nonce.end(),
                  [](std::uint8_t byte) { return byte == 0; })) {
    return std::nullopt;
  }
  std::string json = "{\"version\":1,\"clientId\":";
  AppendJsonString(&json, request.client_id);
  json += ",\"nonce\":";
  AppendJsonBytes(&json, request.nonce);
  json += ",\"proof\":";
  AppendJsonBytes(&json, request.proof);
  json += "}";
  return json;
}

std::optional<AuthResponse> DecodeAuthResponseJson(
    std::string_view json, std::string_view expected_client_id) {
  const std::optional<JsonValue> root = JsonParser(json).Parse();
  if (!root.has_value() || root->type != JsonValue::Type::kObject) {
    return std::nullopt;
  }
  std::uint64_t version = 0;
  AuthResponse response;
  if (!ReadU64(*root, "version", &version) ||
      version != kBrokerProtocolVersion ||
      !ReadBool(*root, "accepted", &response.accepted)) {
    return std::nullopt;
  }
  response.version = kBrokerProtocolVersion;
  const JsonValue* peer = root->Find("peer");
  if (peer != nullptr) {
    if (peer->type != JsonValue::Type::kObject) {
      return std::nullopt;
    }
    std::string peer_id;
    if (!ReadString(*peer, "clientId", &peer_id) ||
        !ValidBoundedText(peer_id, kBrokerMaxClientIdBytes, false)) {
      return std::nullopt;
    }
    response.peer_client_id = std::move(peer_id);
  }
  const JsonValue* error = root->Find("error");
  if (error != nullptr) {
    if (error->type != JsonValue::Type::kString ||
        !ValidBoundedText(error->string, kMaxErrorMessageBytes, false)) {
      return std::nullopt;
    }
    response.error = error->string;
  }
  if (response.accepted) {
    if (!response.peer_client_id.has_value() ||
        *response.peer_client_id != expected_client_id) {
      return std::nullopt;
    }
  } else if (!response.error.has_value()) {
    return std::nullopt;
  }
  return response;
}

std::optional<std::string> EncodePrepareRerankSessionJson(
    const PrepareRerankSessionRequest& request) {
  if (request.request_id == 0 || request.session_id == 0) {
    return std::nullopt;
  }
  std::string json = "{\"version\":1,\"requestId\":";
  AppendU64Json(&json, request.request_id);
  json += ",\"command\":{\"operation\":\"prepareRerankSession\",\"payload\":{";
  json += "\"sessionId\":";
  AppendU64Json(&json, request.session_id);
  json += ",\"generation\":";
  AppendU64Json(&json, request.generation);
  json += ",\"fieldClass\":\"regular\"}}}";
  return json;
}

std::optional<GenerationResponse> DecodeGenerationResponseJson(
    std::string_view json,
    const PrepareRerankSessionRequest& expected_request) {
  const std::optional<JsonValue> root = JsonParser(json).Parse();
  if (!root.has_value() || root->type != JsonValue::Type::kObject) {
    return std::nullopt;
  }
  std::uint64_t version = 0;
  std::uint64_t request_id = 0;
  if (!ReadU64(*root, "version", &version) ||
      version != kBrokerProtocolVersion ||
      !ReadU64(*root, "requestId", &request_id) ||
      request_id != expected_request.request_id) {
    return std::nullopt;
  }
  const JsonValue* envelope_generation = root->Find("generation");
  if (envelope_generation == nullptr ||
      envelope_generation->type != JsonValue::Type::kNumber ||
      envelope_generation->number != expected_request.generation) {
    return std::nullopt;
  }
  const JsonValue* outcome = FindTyped(*root, "outcome", JsonValue::Type::kObject);
  const JsonValue* success =
      outcome == nullptr ? nullptr : FindTyped(*outcome, "success", JsonValue::Type::kObject);
  if (success == nullptr) {
    return std::nullopt;
  }
  std::string operation;
  const JsonValue* payload =
      FindTyped(*success, "payload", JsonValue::Type::kObject);
  GenerationResponse response;
  if (payload == nullptr || !ReadString(*success, "operation", &operation) ||
      operation != "generation" ||
      !ReadU64(*payload, "sessionId", &response.session_id) ||
      !ReadU64(*payload, "generation", &response.generation) ||
      response.session_id != expected_request.session_id ||
      response.generation != expected_request.generation) {
    return std::nullopt;
  }
  return response;
}

std::optional<std::string> EncodeReleaseRerankSessionJson(
    const ReleaseRerankSessionRequest& request) {
  if (request.request_id == 0 || request.session_id == 0) {
    return std::nullopt;
  }
  std::string json = "{\"version\":1,\"requestId\":";
  AppendU64Json(&json, request.request_id);
  json += ",\"command\":{\"operation\":\"focusLost\",\"payload\":{";
  json += "\"sessionId\":";
  AppendU64Json(&json, request.session_id);
  json += ",\"generation\":";
  AppendU64Json(&json, request.generation);
  json += "}}}";
  return json;
}

std::optional<GenerationResponse> DecodeFocusLostResponseJson(
    std::string_view json,
    const ReleaseRerankSessionRequest& expected_request) {
  const std::optional<JsonValue> root = JsonParser(json).Parse();
  if (!root.has_value() || root->type != JsonValue::Type::kObject) {
    return std::nullopt;
  }
  std::uint64_t version = 0;
  std::uint64_t request_id = 0;
  const JsonValue* envelope_generation = root->Find("generation");
  if (!ReadU64(*root, "version", &version) ||
      version != kBrokerProtocolVersion ||
      !ReadU64(*root, "requestId", &request_id) ||
      request_id != expected_request.request_id ||
      envelope_generation == nullptr ||
      envelope_generation->type != JsonValue::Type::kNumber ||
      envelope_generation->number != expected_request.generation) {
    return std::nullopt;
  }
  const JsonValue* outcome = FindTyped(*root, "outcome", JsonValue::Type::kObject);
  const JsonValue* success =
      outcome == nullptr ? nullptr : FindTyped(*outcome, "success", JsonValue::Type::kObject);
  const JsonValue* payload =
      success == nullptr ? nullptr : FindTyped(*success, "payload", JsonValue::Type::kObject);
  std::string operation;
  GenerationResponse response;
  if (payload == nullptr || !ReadString(*success, "operation", &operation) ||
      operation != "focusLost" ||
      !ReadU64(*payload, "sessionId", &response.session_id) ||
      !ReadU64(*payload, "generation", &response.generation) ||
      response.session_id != expected_request.session_id ||
      response.generation != expected_request.generation) {
    return std::nullopt;
  }
  return response;
}

std::optional<std::string> EncodeRerankRequestJson(
    const RerankRequest& request) {
  if (!ValidateRerankRequest(request)) {
    return std::nullopt;
  }
  std::string json = "{\"version\":1,\"requestId\":";
  AppendU64Json(&json, request.request_id);
  json += ",\"command\":{\"operation\":\"rerankCandidates\",\"payload\":{";
  json += "\"sessionId\":";
  AppendU64Json(&json, request.session_id);
  json += ",\"generation\":";
  AppendU64Json(&json, request.generation);
  json += ",\"candidates\":[";
  for (std::size_t index = 0; index < request.candidates.size(); ++index) {
    if (index != 0) json += ",";
    const BrokerCandidate& candidate = request.candidates[index];
    json += "{\"id\":";
    AppendU64Json(&json, candidate.id);
    json += ",\"text\":";
    AppendJsonString(&json, candidate.text);
    if (candidate.reading.has_value()) {
      json += ",\"reading\":";
      AppendJsonString(&json, *candidate.reading);
    }
    json += ",\"rank\":";
    json += std::to_string(candidate.rank);
    json += "}";
  }
  json += "],\"contextBefore\":";
  AppendJsonString(&json, request.context_before);
  json += ",\"contextAfter\":";
  AppendJsonString(&json, request.context_after);
  json += ",\"policyVersion\":";
  AppendJsonString(&json, request.policy_version);
  json += ",\"deadlineMs\":";
  json += std::to_string(request.deadline_ms);
  json += ",\"baselineLatencyMicros\":";
  AppendU64Json(&json, request.baseline_latency_micros);
  json += "}}}";
  return json;
}

std::optional<RerankResponse> DecodeRerankResponseJson(
    std::string_view json, const RerankRequest& expected_request) {
  if (!ValidateRerankRequest(expected_request)) {
    return std::nullopt;
  }
  const std::optional<JsonValue> root = JsonParser(json).Parse();
  if (!root.has_value() || root->type != JsonValue::Type::kObject) {
    return std::nullopt;
  }
  RerankResponse response;
  std::uint64_t version = 0;
  if (!ReadU64(*root, "version", &version) ||
      version != kBrokerProtocolVersion ||
      !ReadU64(*root, "requestId", &response.request_id) ||
      response.request_id != expected_request.request_id) {
    return std::nullopt;
  }
  const JsonValue* outcome = FindTyped(*root, "outcome", JsonValue::Type::kObject);
  if (outcome == nullptr) {
    return std::nullopt;
  }
  const JsonValue* failure = outcome->Find("failure");
  const JsonValue* success = outcome->Find("success");
  if ((failure == nullptr) == (success == nullptr)) {
    return std::nullopt;
  }
  const JsonValue* envelope_generation = root->Find("generation");
  if (envelope_generation != nullptr &&
      (envelope_generation->type != JsonValue::Type::kNumber ||
       envelope_generation->number != expected_request.generation)) {
    return std::nullopt;
  }
  response.session_id = expected_request.session_id;
  response.generation = expected_request.generation;
  response.baseline = expected_request.candidates;
  if (failure != nullptr) {
    std::string message;
    std::string fallback;
    bool retryable = false;
    if (failure->type != JsonValue::Type::kObject ||
        !ReadString(*failure, "code", &response.error_code) ||
        !ReadString(*failure, "message", &message) ||
        !ReadBool(*failure, "retryable", &retryable) ||
        !ReadString(*failure, "fallback", &fallback) ||
        !ValidBoundedText(response.error_code, 64, false) ||
        !ValidBoundedText(message, kMaxErrorMessageBytes, false) ||
        !IsValidFallbackMode(fallback)) {
      return std::nullopt;
    }
    response.broker_success = false;
    response.status = EnhancementStatus::kFallback;
    return response;
  }

  std::string operation;
  if (success->type != JsonValue::Type::kObject ||
      !ReadString(*success, "operation", &operation) ||
      operation != "rerankCandidates") {
    return std::nullopt;
  }
  const JsonValue* payload =
      FindTyped(*success, "payload", JsonValue::Type::kObject);
  if (payload == nullptr || envelope_generation == nullptr ||
      !ReadU64(*payload, "sessionId", &response.session_id) ||
      !ReadU64(*payload, "generation", &response.generation) ||
      response.session_id != expected_request.session_id ||
      response.generation != expected_request.generation ||
      !ReadBool(*payload, "adopted", &response.adopted) ||
      !ReadString(*payload, "fallback", &response.fallback) ||
      !ReadString(*payload, "reason", &response.reason)) {
    return std::nullopt;
  }
  std::string status_text;
  if (!ReadString(*payload, "status", &status_text)) {
    return std::nullopt;
  }
  const std::optional<EnhancementStatus> status =
      ParseEnhancementStatus(status_text);
  if (!status.has_value() || !IsValidFallbackMode(response.fallback) ||
      !IsValidEnhancementReason(response.reason)) {
    return std::nullopt;
  }
  response.status = *status;
  const JsonValue* baseline =
      FindTyped(*payload, "baseline", JsonValue::Type::kArray);
  const JsonValue* ai = FindTyped(*payload, "ai", JsonValue::Type::kArray);
  if (baseline == nullptr || ai == nullptr ||
      baseline->array.size() != expected_request.candidates.size() ||
      ai->array.size() != expected_request.candidates.size()) {
    return std::nullopt;
  }
  for (std::size_t index = 0; index < baseline->array.size(); ++index) {
    const std::optional<BrokerCandidate> candidate =
        ParseCandidate(baseline->array[index]);
    if (!candidate.has_value() ||
        !SameCandidate(*candidate, expected_request.candidates[index])) {
      return std::nullopt;
    }
  }
  std::vector<bool> seen(expected_request.candidates.size(), false);
  for (const JsonValue& value : ai->array) {
    const std::optional<BrokerCandidate> candidate = ParseCandidate(value);
    if (!candidate.has_value()) {
      return std::nullopt;
    }
    const auto found = std::find_if(
        expected_request.candidates.begin(), expected_request.candidates.end(),
        [&candidate](const BrokerCandidate& baseline_candidate) {
          return baseline_candidate.id == candidate->id &&
                 baseline_candidate.text == candidate->text &&
                 baseline_candidate.reading == candidate->reading;
        });
    if (found == expected_request.candidates.end() || !SameCandidate(*found, *candidate)) {
      return std::nullopt;
    }
    const std::size_t index = static_cast<std::size_t>(
        std::distance(expected_request.candidates.begin(), found));
    if (seen[index]) {
      return std::nullopt;
    }
    seen[index] = true;
    response.ai.push_back(std::move(*candidate));
  }
  const JsonValue* metrics =
      FindTyped(*payload, "metrics", JsonValue::Type::kObject);
  std::string feature;
  std::string provider;
  std::string locality;
  std::uint64_t baseline_count = 0;
  std::uint64_t ai_count = 0;
  std::uint32_t deadline = 0;
  if (metrics == nullptr || !ReadString(*metrics, "feature", &feature) ||
      !ReadString(*metrics, "provider", &provider) ||
      !ReadString(*metrics, "locality", &locality) ||
      !ReadU64(*metrics, "baselineCandidateCount", &baseline_count) ||
      !ReadU64(*metrics, "aiCandidateCount", &ai_count) ||
      !ReadU32(*metrics, "deadlineMs", &deadline) || feature != "candidateRerank" ||
      locality != "local" ||
      !ValidBoundedText(provider, kMaxProviderIdBytes, false) ||
      baseline_count != expected_request.candidates.size() ||
      ai_count != expected_request.candidates.size() || deadline == 0 ||
      deadline > kBrokerMaxEnhancementDeadlineMs) {
    return std::nullopt;
  }
  if (response.status != EnhancementStatus::kApplied || !response.adopted) {
    response.ai = response.baseline;
  }
  response.broker_success = true;
  return response;
}

}  // namespace kanai::tsf
