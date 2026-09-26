#ifndef _WIN32
#error "KanaAI's named-pipe broker client is Windows-only."
#endif

#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "engine/kanai_ai/pipe_broker_client.h"

#include <windows.h>
#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <iterator>
#include <limits>
#include <memory>
#include <mutex>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "engine/kanai_ai/broker_contract.h"

namespace kanai::tsf {
namespace {

using Clock = std::chrono::steady_clock;

constexpr std::uint32_t kMinimumTimeoutMilliseconds = 1;
constexpr std::uint32_t kMaximumTimeoutMilliseconds = 2000;
constexpr std::size_t kMaximumTransportFrameSize =
    kBrokerFrameHeaderSize + kBrokerMaxPayloadSize;

// This is a public capability marker, not a shared secret. The client also
// verifies the connected broker process image (or the exact
// KANAI_AI_TSF_SERVER_IMAGE path); the server separately validates the client
// process image, user/elevation token, and user-only pipe ACL.
constexpr std::string_view kPeerProof = "KanaAI.Tsf.TokenPeer.v1";

class UniqueHandle {
 public:
  UniqueHandle() = default;
  explicit UniqueHandle(HANDLE handle) : handle_(handle) {}
  ~UniqueHandle() { reset(); }

  UniqueHandle(const UniqueHandle&) = delete;
  UniqueHandle& operator=(const UniqueHandle&) = delete;

  UniqueHandle(UniqueHandle&& other) noexcept
      : handle_(std::exchange(other.handle_, nullptr)) {}
  UniqueHandle& operator=(UniqueHandle&& other) noexcept {
    if (this != &other) {
      reset();
      handle_ = std::exchange(other.handle_, nullptr);
    }
    return *this;
  }

  HANDLE get() const { return handle_; }
  void reset(HANDLE handle = nullptr) {
    if (valid()) {
      ::CloseHandle(handle_);
    }
    handle_ = handle;
  }

  bool valid() const {
    return handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE;
  }

 private:
  HANDLE handle_ = nullptr;
};

std::wstring SiblingBrokerImage() {
  std::vector<wchar_t> image(32'768);
  const DWORD length = ::GetModuleFileNameW(nullptr, image.data(),
                                           static_cast<DWORD>(image.size()));
  if (length == 0 || length >= image.size()) return {};
  std::wstring path(image.data(), length);
  const auto separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return {};
  return path.substr(0, separator + 1) + L"kanai-broker.exe";
}

// Only called by the optional transport worker. Keep the first request
// fail-open: model startup is never awaited, and retries are rate-limited.
void MaybeStartSiblingBroker() {
  // Explicit lab endpoints must never accidentally launch the installed model.
  if (::GetEnvironmentVariableW(L"KANAI_AI_TSF_PIPE", nullptr, 0) != 0 ||
      ::GetEnvironmentVariableW(L"KANAI_AI_TSF_SERVER_IMAGE", nullptr, 0) != 0) {
    return;
  }
  struct Launcher {
    std::mutex mutex;
    Clock::time_point next_attempt{};
    UniqueHandle ownership;
    UniqueHandle job;
    UniqueHandle process;
  };
  static Launcher launcher;
  std::lock_guard<std::mutex> lock(launcher.mutex);
  if (Clock::now() < launcher.next_attempt) return;
  launcher.next_attempt = Clock::now() + std::chrono::seconds(5);
  if (launcher.process.valid() &&
      ::WaitForSingleObject(launcher.process.get(), 0) == WAIT_TIMEOUT) return;
  launcher.process.reset();
  launcher.job.reset();
  if (!launcher.ownership.valid()) {
    DWORD session = 0;
    if (!::ProcessIdToSessionId(::GetCurrentProcessId(), &session)) return;
    const std::wstring name = L"Local\\KanaAI.BrokerLauncher.v1." +
                              std::to_wstring(session);
    // Object existence is a process-lifetime lease, not thread-owned locking.
    UniqueHandle ownership(::CreateMutexW(nullptr, FALSE, name.c_str()));
    const DWORD error = ::GetLastError();
    if (!ownership.valid() || error == ERROR_ALREADY_EXISTS) return;
    launcher.ownership = std::move(ownership);
  }
  const std::wstring executable = SiblingBrokerImage();
  if (executable.empty()) return;
  UniqueHandle job(::CreateJobObjectW(nullptr, nullptr));
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!job.valid() || !::SetInformationJobObject(
          job.get(), JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
    return;
  }
  std::wstring command = L"\"" + executable + L"\"";
  const std::wstring directory = executable.substr(0, executable.find_last_of(L"\\/"));
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION child = {};
  if (!::CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr,
                        FALSE, CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr,
                        directory.c_str(), &startup, &child)) return;
  UniqueHandle process(child.hProcess);
  UniqueHandle thread(child.hThread);
  if (!::AssignProcessToJobObject(job.get(), process.get()) ||
      ::ResumeThread(thread.get()) == static_cast<DWORD>(-1)) {
    ::TerminateProcess(process.get(), 1);
    return;
  }
  launcher.job = std::move(job);
  launcher.process = std::move(process);
}

std::wstring ReadConfiguredPipeName() {
  std::wstring default_name;
  DWORD session_id = 0;
  if (::ProcessIdToSessionId(::GetCurrentProcessId(), &session_id)) {
    default_name.assign(
        kBrokerWidePipeNamePrefix,
        std::char_traits<wchar_t>::length(kBrokerWidePipeNamePrefix));
    default_name += std::to_wstring(session_id);
  }

  std::vector<wchar_t> buffer(256);
  const DWORD copied = ::GetEnvironmentVariableW(
      L"KANAI_AI_TSF_PIPE", buffer.data(),
      static_cast<DWORD>(buffer.size()));
  if (copied == 0 || copied >= buffer.size()) {
    return default_name;
  }
  std::wstring configured(buffer.data(), copied);
  const std::wstring allowed_prefix(
      kBrokerWidePipeNamePrefix,
      std::char_traits<wchar_t>::length(kBrokerWidePipeNamePrefix));
  if (configured.starts_with(allowed_prefix) &&
      configured.size() > allowed_prefix.size()) {
    return configured;
  }
  return default_name;
}

std::uint32_t RemainingMilliseconds(Clock::time_point deadline) {
  const auto now = Clock::now();
  if (now >= deadline) {
    return 0;
  }
  const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                             deadline - now)
                             .count();
  if (remaining <= 0) {
    return 1;
  }
  return static_cast<std::uint32_t>(std::min<std::int64_t>(
      remaining, std::numeric_limits<std::uint32_t>::max()));
}

bool CompleteOverlapped(HANDLE handle, HANDLE event, OVERLAPPED* overlapped,
                         Clock::time_point deadline, DWORD* bytes_transferred) {
  if (bytes_transferred == nullptr || overlapped == nullptr) {
    return false;
  }
  const DWORD wait_result =
      ::WaitForSingleObject(event, RemainingMilliseconds(deadline));
  if (wait_result == WAIT_TIMEOUT) {
    ::CancelIoEx(handle, overlapped);
    DWORD ignored = 0;
    ::GetOverlappedResult(handle, overlapped, &ignored, TRUE);
    return false;
  }
  if (wait_result != WAIT_OBJECT_0) {
    return false;
  }
  return ::GetOverlappedResult(handle, overlapped, bytes_transferred, FALSE) !=
         FALSE;
}

bool ConnectPipe(const std::wstring& pipe_name, Clock::time_point deadline,
                 UniqueHandle* pipe, bool allow_start = false) {
  if (pipe == nullptr || pipe_name.empty() ||
      RemainingMilliseconds(deadline) == 0) {
    return false;
  }
  if (!::WaitNamedPipeW(pipe_name.c_str(), RemainingMilliseconds(deadline))) {
    if (::GetLastError() == ERROR_FILE_NOT_FOUND && allow_start) {
      MaybeStartSiblingBroker();
    }
    return false;
  }
  UniqueHandle handle(::CreateFileW(
      pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
      FILE_FLAG_OVERLAPPED, nullptr));
  if (!handle.valid()) {
    return false;
  }
  DWORD mode = PIPE_READMODE_BYTE;
  if (!::SetNamedPipeHandleState(handle.get(), &mode, nullptr, nullptr)) {
    return false;
  }
  *pipe = std::move(handle);
  return true;
}

bool ReadExactly(HANDLE pipe, HANDLE event, void* buffer, DWORD requested,
                 Clock::time_point deadline) {
  auto* bytes = static_cast<std::uint8_t*>(buffer);
  DWORD offset = 0;
  while (offset < requested) {
    if (!::ResetEvent(event)) {
      return false;
    }
    OVERLAPPED overlapped = {};
    overlapped.hEvent = event;
    DWORD transferred = 0;
    const BOOL started = ::ReadFile(pipe, bytes + offset, requested - offset,
                                   &transferred, &overlapped);
    if (started) {
      if (!::GetOverlappedResult(pipe, &overlapped, &transferred, FALSE) ||
          transferred == 0) {
        return false;
      }
    } else {
      const DWORD error = ::GetLastError();
      if (error != ERROR_IO_PENDING ||
          !CompleteOverlapped(pipe, event, &overlapped, deadline, &transferred) ||
          transferred == 0) {
        return false;
      }
    }
    offset += transferred;
  }
  return true;
}

bool WriteExactly(HANDLE pipe, HANDLE event, const std::uint8_t* buffer,
                  DWORD requested, Clock::time_point deadline) {
  DWORD offset = 0;
  while (offset < requested) {
    if (!::ResetEvent(event)) {
      return false;
    }
    OVERLAPPED overlapped = {};
    overlapped.hEvent = event;
    DWORD transferred = 0;
    const BOOL started = ::WriteFile(pipe, buffer + offset, requested - offset,
                                    &transferred, &overlapped);
    if (started) {
      if (!::GetOverlappedResult(pipe, &overlapped, &transferred, FALSE) ||
          transferred == 0) {
        return false;
      }
    } else {
      const DWORD error = ::GetLastError();
      if (error != ERROR_IO_PENDING ||
          !CompleteOverlapped(pipe, event, &overlapped, deadline, &transferred) ||
          transferred == 0) {
        return false;
      }
    }
    offset += transferred;
  }
  return true;
}

bool SendPayload(HANDLE pipe, HANDLE event, std::string_view json,
                 Clock::time_point deadline) {
  const std::optional<std::vector<std::uint8_t>> frame =
      EncodeBrokerFrame(json);
  return frame.has_value() && frame->size() <= kMaximumTransportFrameSize &&
         WriteExactly(pipe, event, frame->data(),
                      static_cast<DWORD>(frame->size()), deadline);
}

bool ReceivePayload(HANDLE pipe, HANDLE event, Clock::time_point deadline,
                    std::string* payload) {
  if (payload == nullptr) {
    return false;
  }
  std::array<std::uint8_t, kBrokerFrameHeaderSize> header{};
  if (!ReadExactly(pipe, event, header.data(),
                   static_cast<DWORD>(header.size()), deadline)) {
    return false;
  }
  const std::uint32_t payload_size =
      (static_cast<std::uint32_t>(header[4]) << 24) |
      (static_cast<std::uint32_t>(header[5]) << 16) |
      (static_cast<std::uint32_t>(header[6]) << 8) |
      static_cast<std::uint32_t>(header[7]);
  if (payload_size == 0 || payload_size > kBrokerMaxPayloadSize) {
    return false;
  }
  std::vector<std::uint8_t> frame(kBrokerFrameHeaderSize + payload_size);
  std::copy(header.begin(), header.end(), frame.begin());
  if (!ReadExactly(pipe, event, frame.data() + kBrokerFrameHeaderSize,
                   payload_size, deadline)) {
    return false;
  }
  const std::optional<std::string> decoded = DecodeBrokerFrame(frame);
  if (!decoded.has_value()) {
    return false;
  }
  *payload = std::move(*decoded);
  return true;
}

bool VerifyServerImage(HANDLE pipe) {
  DWORD process_id = 0;
  if (::GetNamedPipeServerProcessId(pipe, &process_id) == 0) {
    return false;
  }
  UniqueHandle process(::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                      process_id));
  if (!process.valid()) {
    return false;
  }
  std::vector<wchar_t> image_buffer(32'768);
  DWORD image_length = static_cast<DWORD>(image_buffer.size());
  if (::QueryFullProcessImageNameW(process.get(), 0, image_buffer.data(),
                                   &image_length) == 0) {
    return false;
  }
  std::wstring image(image_buffer.data(), image_length);

  std::vector<wchar_t> expected_buffer(32'768);
  const DWORD expected_length = ::GetEnvironmentVariableW(
      L"KANAI_AI_TSF_SERVER_IMAGE", expected_buffer.data(),
      static_cast<DWORD>(expected_buffer.size()));
  if (expected_length >= expected_buffer.size()) {
    return false;
  }
  if (expected_length > 0) {
    std::wstring expected(expected_buffer.data(), expected_length);
    while (!expected.empty() &&
           (expected.back() == L'\\' || expected.back() == L'/')) {
      expected.pop_back();
    }
    while (!image.empty() &&
           (image.back() == L'\\' || image.back() == L'/')) {
      image.pop_back();
    }
    return ::CompareStringOrdinal(image.c_str(), -1, expected.c_str(), -1,
                                  TRUE) == CSTR_EQUAL;
  }

  const std::wstring expected = SiblingBrokerImage();
  return !expected.empty() &&
         ::CompareStringOrdinal(image.c_str(), -1, expected.c_str(), -1,
                                 TRUE) == CSTR_EQUAL;
}

bool Authenticate(HANDLE pipe, HANDLE event, const std::string& client_id,
                  Clock::time_point deadline) {
  if (!VerifyServerImage(pipe)) {
    return false;
  }
  AuthRequest request;
  request.client_id = client_id;
  request.nonce.resize(kBrokerMaxAuthNonceBytes);
  if (BCryptGenRandom(nullptr, request.nonce.data(),
                      static_cast<ULONG>(request.nonce.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    return false;
  }
  request.proof.assign(kPeerProof.begin(), kPeerProof.end());
  const std::optional<std::string> auth_json = EncodeAuthRequestJson(request);
  std::string auth_response_json;
  if (!auth_json.has_value() || !SendPayload(pipe, event, *auth_json, deadline) ||
      !ReceivePayload(pipe, event, deadline, &auth_response_json)) {
    return false;
  }
  const std::optional<AuthResponse> auth_response =
      DecodeAuthResponseJson(auth_response_json, client_id);
  return auth_response.has_value() && auth_response->accepted;
}

}  // namespace

PipeRerankTransport MakePipeRerankTransport(
    std::uint32_t timeout_milliseconds) {
  auto client = std::make_shared<PipeBrokerClient>(timeout_milliseconds);
  return [client](const RerankRequest& request, RerankResponse* response) {
    return client->Rerank(request, response);
  };
}

PipeReleaseTransport MakePipeReleaseTransport(
    std::uint32_t timeout_milliseconds) {
  auto client = std::make_shared<PipeBrokerClient>(timeout_milliseconds);
  return [client](std::uint64_t session_id, std::uint64_t generation) {
    return client->Release(session_id, generation);
  };
}

PipeBrokerClient::PipeBrokerClient(std::uint32_t timeout_milliseconds)
    : pipe_name_(ReadConfiguredPipeName()),
      timeout_milliseconds_(std::clamp(
          timeout_milliseconds, kMinimumTimeoutMilliseconds,
          kMaximumTimeoutMilliseconds)) {}

bool PipeBrokerClient::Rerank(const RerankRequest& request,
                              RerankResponse* response) const {
  if (response == nullptr || pipe_name_.empty()) {
    return false;
  }
  const std::optional<std::string> request_json =
      EncodeRerankRequestJson(request);
  const PrepareRerankSessionRequest prepare{
      request.request_id, request.session_id, request.generation};
  const std::optional<std::string> prepare_json =
      EncodePrepareRerankSessionJson(prepare);
  if (!request_json.has_value() || !prepare_json.has_value()) {
    return false;
  }

  const auto deadline =
      Clock::now() + std::chrono::milliseconds(timeout_milliseconds_);
  const auto exchange = [&](const std::string& payload,
                            std::string* response_json) {
    UniqueHandle pipe;
    if (!ConnectPipe(pipe_name_, deadline, &pipe, true)) {
      return false;
    }
    UniqueHandle event(::CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!event.valid() ||
        !Authenticate(pipe.get(), event.get(), client_id_, deadline) ||
        !SendPayload(pipe.get(), event.get(), payload, deadline)) {
      return false;
    }
    return ReceivePayload(pipe.get(), event.get(), deadline, response_json);
  };

  std::string prepare_response;
  if (!exchange(*prepare_json, &prepare_response) ||
      !DecodeGenerationResponseJson(prepare_response, prepare).has_value()) {
    return false;
  }
  std::string rerank_response;
  if (!exchange(*request_json, &rerank_response)) {
    return false;
  }
  const std::optional<RerankResponse> decoded =
      DecodeRerankResponseJson(rerank_response, request);
  if (!decoded.has_value()) {
    return false;
  }
  *response = *decoded;
  return true;
}

bool PipeBrokerClient::Release(std::uint64_t session_id,
                                std::uint64_t generation) const {
  if (pipe_name_.empty() || session_id == 0) {
    return false;
  }
  const ReleaseRerankSessionRequest request{session_id, session_id, generation};
  const std::optional<std::string> request_json =
      EncodeReleaseRerankSessionJson(request);
  if (!request_json.has_value()) {
    return false;
  }
  const auto deadline =
      Clock::now() + std::chrono::milliseconds(timeout_milliseconds_);
  UniqueHandle pipe;
  if (!ConnectPipe(pipe_name_, deadline, &pipe)) {
    return false;
  }
  UniqueHandle event(::CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (!event.valid() ||
      !Authenticate(pipe.get(), event.get(), client_id_, deadline) ||
      !SendPayload(pipe.get(), event.get(), *request_json, deadline)) {
    return false;
  }
  std::string response_json;
  if (!ReceivePayload(pipe.get(), event.get(), deadline, &response_json) ||
      !DecodeFocusLostResponseJson(response_json, request).has_value()) {
    return false;
  }
  return true;
}

}  // namespace kanai::tsf
