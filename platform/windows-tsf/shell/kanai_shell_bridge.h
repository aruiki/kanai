// KanaAI Windows shell integration seam.
//
// This header describes the deliberately small boundary between a future
// Windows TSF adapter and the loopback KanaAI service. It is not a TSF
// implementation and does not register a TIP. The current console bridge in
// kanai_windows_shell_bridge.cpp is a development launcher/probe only.
#ifndef KANAI_PLATFORM_WINDOWS_TSF_KANAI_SHELL_BRIDGE_H_
#define KANAI_PLATFORM_WINDOWS_TSF_KANAI_SHELL_BRIDGE_H_

#include <cstdint>

namespace kanai::windows_shell {

inline constexpr std::uint32_t kContractVersion = 1;
inline constexpr wchar_t kDefaultAddress[] = L"127.0.0.1";
inline constexpr std::uint16_t kDefaultPort = 8787;

// A future native shell should keep its own text-service lifecycle and use a
// bounded, asynchronous request to the service. It must not put a synchronous
// dictionary/model/network call on the TSF key path.
struct ConvertRequest {
  std::uint32_t contract_version = kContractVersion;
  const wchar_t* romaji = nullptr;
  const wchar_t* context_before = nullptr;
  const wchar_t* context_after = nullptr;
  std::uint32_t limit = 9;
  const wchar_t* ai_mode = L"off";
};

enum class BridgeStatus : std::int32_t {
  kOk = 0,
  kInvalidArgument = 1,
  kServiceUnavailable = 2,
  kRequestFailed = 3,
  kTimeout = 4,
  kDecodeFailed = 5,
};

}  // namespace kanai::windows_shell

#endif  // KANAI_PLATFORM_WINDOWS_TSF_KANAI_SHELL_BRIDGE_H_
