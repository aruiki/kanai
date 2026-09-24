#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "engine/kanai_ai/broker_contract.h"

namespace {

using kanai::tsf::AuthRequest;
using kanai::tsf::AuthResponse;
using kanai::tsf::BrokerCandidate;
using kanai::tsf::DecodeAuthResponseJson;
using kanai::tsf::DecodeBrokerFrame;
using kanai::tsf::DecodeRerankResponseJson;
using kanai::tsf::EncodeAuthRequestJson;
using kanai::tsf::EncodeBrokerFrame;
using kanai::tsf::EncodeRerankRequestJson;
using kanai::tsf::EnhancementStatus;
using kanai::tsf::IsValidUtf8;
using kanai::tsf::kBrokerFrameHeaderSize;
using kanai::tsf::MakeBrokerPipeName;
using kanai::tsf::RerankRequest;
using kanai::tsf::RerankResponse;

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
  };
  request.policy_version = "v1";
  request.deadline_ms = 20;
  request.baseline_latency_micros = 125;
  return request;
}

void TestUtf8AndPipeName() {
  Check(IsValidUtf8("ascii"), "ASCII UTF-8 accepted");
  Check(IsValidUtf8("日本語"), "valid Japanese UTF-8 accepted");
  Check(!IsValidUtf8(std::string("\xc0\xaf", 2)),
        "overlong two-byte sequence rejected");
  Check(!IsValidUtf8(std::string("\xed\xa0\x80", 3)),
        "UTF-8-encoded surrogate rejected");
  Check(MakeBrokerPipeName(7) ==
            "\\\\.\\pipe\\KanaAI.TsfBroker.v1.7",
        "session-scoped pipe name");
}

void TestKbf1Frame() {
  const std::optional<std::vector<std::uint8_t>> frame =
      EncodeBrokerFrame("{\"ok\":true}");
  Check(frame.has_value() && frame->size() == kBrokerFrameHeaderSize + 11,
        "KBF1 frame size is exact");
  Check((*frame)[0] == 'K' && (*frame)[1] == 'B' && (*frame)[2] == 'F' &&
            (*frame)[3] == '1',
        "canonical KBF1 magic");
  Check((*frame)[4] == 0 && (*frame)[5] == 0 && (*frame)[6] == 0 &&
            (*frame)[7] == 11,
        "canonical big-endian payload length");
  const std::optional<std::string> payload = DecodeBrokerFrame(*frame);
  Check(payload.has_value() && *payload == "{\"ok\":true}",
        "KBF1 frame round trips");

  std::vector<std::uint8_t> trailing = *frame;
  trailing.push_back(0);
  Check(!DecodeBrokerFrame(trailing).has_value(),
        "trailing frame bytes rejected");
}

void TestAuthProjection() {
  AuthRequest auth;
  auth.client_id = "KanaAI.MozcServer";
  auth.nonce.resize(32, 1);
  auth.proof = {'K', 'a', 'n', 'a', 'A', 'I'};
  const std::optional<std::string> json = EncodeAuthRequestJson(auth);
  Check(json.has_value(), "canonical AuthRequest encodes");
  const std::string accepted =
      R"({"version":1,"accepted":true,"peer":{"clientId":"KanaAI.MozcServer"}})";
  const std::optional<AuthResponse> response =
      DecodeAuthResponseJson(accepted, "KanaAI.MozcServer");
  Check(response.has_value() && response->accepted,
        "canonical AuthResponse accepts matching peer");
  Check(!DecodeAuthResponseJson(accepted, "other-client").has_value(),
        "auth peer identity mismatch rejected");
}

void TestCanonicalRerankRequest() {
  const RerankRequest request = Request();
  const std::optional<std::string> json = EncodeRerankRequestJson(request);
  Check(json.has_value(), "canonical rerankCandidates request encodes");
  const std::string expected =
      R"({"version":1,"requestId":42,"command":{"operation":"rerankCandidates","payload":{"sessionId":7,"generation":3,"candidates":[{"id":1,"text":"かな","reading":"かな","rank":0},{"id":2,"text":"彼方","reading":"かれかた","rank":1}],"contextBefore":"","contextAfter":"","policyVersion":"v1","deadlineMs":20,"baselineLatencyMicros":125}}})";
  Check(*json == expected,
        "C++ request projection matches kanai-broker serde field order");
  Check(json->find("\"operation\":\"rerankCandidates\"") != std::string::npos,
        "operation uses kanai-broker camelCase");
  Check(json->find("\"contextBefore\":\"\"") != std::string::npos,
        "bounded context fields remain explicit");
  Check(json->find("\"deadlineMs\":20") != std::string::npos,
        "deadline uses canonical DTO field");
  Check(json->find("\"baselineLatencyMicros\":125") != std::string::npos,
        "quality metrics input uses canonical DTO field");

  RerankRequest invalid = request;
  invalid.session_id = 0;
  Check(!EncodeRerankRequestJson(invalid).has_value(),
        "zero broker session id rejected");
  invalid = request;
  invalid.candidates.pop_back();
  Check(!EncodeRerankRequestJson(invalid).has_value(),
        "native one-candidate rerank rejected");
  invalid = request;
  invalid.candidates[0].text = std::string("\xc0\xaf", 2);
  Check(!EncodeRerankRequestJson(invalid).has_value(),
        "invalid candidate UTF-8 rejected");
}

void TestCanonicalRerankResponse() {
  const RerankRequest request = Request();
  const std::string json = R"({
    "version":1,
    "requestId":42,
    "generation":3,
    "outcome":{
      "success":{
        "operation":"rerankCandidates",
        "payload":{
          "sessionId":7,
          "generation":3,
          "status":"applied",
          "baseline":[
            {"id":1,"text":"かな","reading":"かな","rank":0},
            {"id":2,"text":"彼方","reading":"かれかた","rank":1}
          ],
          "ai":[
            {"id":2,"text":"彼方","reading":"かれかた","rank":1},
            {"id":1,"text":"かな","reading":"かな","rank":0}
          ],
          "adopted":true,
          "metrics":{
            "feature":"candidateRerank",
            "provider":"local-test",
            "locality":"local",
            "baselineLatencyMicros":125,
            "aiLatencyMicros":2000,
            "baselineCandidateCount":2,
            "aiCandidateCount":2,
            "changedPositions":2,
            "adoptedCount":2,
            "deadlineMs":20
          },
          "fallback":"none",
          "reason":"none"
        }
      }
    }
  })";
  const std::optional<RerankResponse> response =
      DecodeRerankResponseJson(json, request);
  Check(response.has_value() && response->broker_success &&
            response->status == EnhancementStatus::kApplied &&
            response->adopted && response->ai.size() == 2 &&
            response->ai[0].id == 2,
        "canonical applied rerank response decodes");

  const std::string failure =
      R"({"version":1,"requestId":42,"generation":3,"outcome":{"failure":{"code":"enhancementRequiresAsync","message":"async required","retryable":false,"fallback":"none"}}})";
  const std::optional<RerankResponse> failure_response =
      DecodeRerankResponseJson(failure, request);
  Check(failure_response.has_value() && !failure_response->broker_success &&
            failure_response->error_code == "enhancementRequiresAsync",
        "synchronous broker rejection remains fail-open data");

  std::string mutated = json;
  const std::string original = "\"text\":\"彼方\"";
  const std::size_t position = mutated.find(original);
  Check(position != std::string::npos, "response fixture contains candidate");
  mutated.replace(position, original.size(), "\"text\":\"mutated\"");
  Check(!DecodeRerankResponseJson(mutated, request).has_value(),
        "AI candidate text mutation rejected");
}

}  // namespace

int main() {
  TestUtf8AndPipeName();
  TestKbf1Frame();
  TestAuthProjection();
  TestCanonicalRerankRequest();
  TestCanonicalRerankResponse();
  std::cout << "broker_contract_test: PASS\n";
  return 0;
}
