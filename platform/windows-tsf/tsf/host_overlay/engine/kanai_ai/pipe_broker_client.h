#ifndef KANAI_WINDOWS_TSF_KANAI_AI_PIPE_BROKER_CLIENT_H_
#define KANAI_WINDOWS_TSF_KANAI_AI_PIPE_BROKER_CLIENT_H_

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "engine/kanai_ai/broker_contract.h"

namespace kanai::tsf {

// Synchronous named-pipe transport for an optional executor. It is never
// called from a key/preedit callback. Each connection performs the canonical
// kanai-broker AuthRequest/AuthResponse handshake and one rerank exchange.
using PipeRerankTransport =
    std::function<bool(const RerankRequest&, RerankResponse*)>;
using PipeReleaseTransport =
    std::function<bool(std::uint64_t, std::uint64_t)>;

// Build the real Windows named-pipe transport used by the supplemental
// model's bounded worker. The returned callable owns one reusable client,
// verifies the broker process image before authentication, and performs no
// I/O until the worker invokes it.
// An absent default pipe triggers a hidden sibling broker launch on that worker,
// with a process-lifetime job, one launcher per Windows session and 5s backoff.
// Explicit lab pipe/image overrides disable automatic startup. Release never
// starts a broker. The first startup request falls back without waiting.
PipeRerankTransport MakePipeRerankTransport(std::uint32_t timeout_milliseconds);
PipeReleaseTransport MakePipeReleaseTransport(
    std::uint32_t timeout_milliseconds);

class PipeBrokerClient {
 public:
  explicit PipeBrokerClient(std::uint32_t timeout_milliseconds);

  PipeBrokerClient(const PipeBrokerClient&) = delete;
  PipeBrokerClient& operator=(const PipeBrokerClient&) = delete;
  PipeBrokerClient(PipeBrokerClient&&) = delete;
  PipeBrokerClient& operator=(PipeBrokerClient&&) = delete;
  ~PipeBrokerClient() = default;

  bool Rerank(const RerankRequest& request, RerankResponse* response) const;
  bool Release(std::uint64_t session_id, std::uint64_t generation) const;

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
