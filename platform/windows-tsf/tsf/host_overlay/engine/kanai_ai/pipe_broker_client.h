#ifndef KANAI_WINDOWS_TSF_KANAI_AI_PIPE_BROKER_CLIENT_H_
#define KANAI_WINDOWS_TSF_KANAI_AI_PIPE_BROKER_CLIENT_H_

#include <cstdint>
#include <string>
#include <vector>

#include "engine/kanai_ai/broker_contract.h"

namespace kanai::tsf {

// Synchronous named-pipe transport for an optional executor. It is never
// called from a key/preedit callback. Each connection performs the canonical
// kanai-broker AuthRequest/AuthResponse handshake and one rerank exchange.
class PipeBrokerClient {
 public:
  explicit PipeBrokerClient(std::uint32_t timeout_milliseconds);

  PipeBrokerClient(const PipeBrokerClient&) = delete;
  PipeBrokerClient& operator=(const PipeBrokerClient&) = delete;
  PipeBrokerClient(PipeBrokerClient&&) = delete;
  PipeBrokerClient& operator=(PipeBrokerClient&&) = delete;
  ~PipeBrokerClient() = default;

  bool Rerank(const RerankRequest& request, RerankResponse* response) const;

  const std::wstring& pipe_name() const { return pipe_name_; }
  std::uint32_t timeout_milliseconds() const { return timeout_milliseconds_; }
  const std::string& client_id() const { return client_id_; }

 private:
  std::wstring pipe_name_;
  std::uint32_t timeout_milliseconds_;
  std::string client_id_ = "KanaAI.MozcServer";
};

}  // namespace kanai::tsf

#endif  // KANAI_WINDOWS_TSF_KANAI_AI_PIPE_BROKER_CLIENT_H_
