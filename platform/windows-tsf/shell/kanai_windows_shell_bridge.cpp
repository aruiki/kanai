// KanaAI Windows shell/bridge development seam.
//
// This executable starts the packaged loopback service (or probes one that is
// already running), opens the workbench, and can issue one bounded conversion
// request. It is intentionally NOT a TSF DLL/TIP: it has no COM registration,
// text-service lifecycle, candidate window, secure-field handling, or input
// processor. A future TSF adapter must use the contract header and add those
// platform responsibilities separately.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winhttp.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <vector>

#include "kanai_shell_bridge.h"

namespace {

using kanai::windows_shell::kDefaultPort;

struct Options {
  std::filesystem::path package_root;
  std::uint16_t port = kDefaultPort;
  bool open_browser = true;
  bool probe_only = false;
  std::wstring convert_text;
};

HANDLE g_api_process = nullptr;

BOOL WINAPI ConsoleCtrlHandler(DWORD event) {
  if ((event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT) && g_api_process != nullptr &&
      WaitForSingleObject(g_api_process, 0) == WAIT_TIMEOUT) {
    TerminateProcess(g_api_process, 1);
  }
  return TRUE;
}

void PrintUsage() {
  std::wcerr << L"Usage: kanai-windows-shell.exe [options]\n"
             << L"  --package-root <path>  Package directory (default: executable parent/..)\n"
             << L"  --port <1..65535>       Loopback service port (default: 8787)\n"
             << L"  --no-browser            Do not open the workbench\n"
             << L"  --probe                 Probe an existing service and exit\n"
             << L"  --convert <romaji>      Convert once, then stop the service if started here\n"
             << L"\nThis is a development shell seam, not a TSF TIP.\n";
}

std::string WideToUtf8(std::wstring_view value) {
  if (value.empty()) {
    return {};
  }
  const int required = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                                             static_cast<int>(value.size()), nullptr, 0,
                                             nullptr, nullptr);
  if (required <= 0) {
    return {};
  }
  std::string result(static_cast<std::size_t>(required), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(), required, nullptr,
                            nullptr) != required) {
    return {};
  }
  return result;
}

std::wstring QuoteArgument(std::wstring_view value) {
  std::wstring result;
  result.push_back(L'"');
  for (const wchar_t character : value) {
    if (character == L'\\') {
      result.push_back(L'\\');
    }
    if (character == L'"') {
      result.push_back(L'\\');
    }
    result.push_back(character);
  }
  result.push_back(L'"');
  return result;
}

std::wstring EnvironmentValue(const wchar_t* name) {
  DWORD length = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (length == 0) {
    return {};
  }
  std::wstring value(length, L'\0');
  DWORD copied = ::GetEnvironmentVariableW(name, value.data(), length);
  if (copied == 0 || copied >= length) {
    return {};
  }
  value.resize(copied);
  return value;
}

void FreeUrlComponents(URL_COMPONENTS* components) {
  if (components == nullptr) {
    return;
  }
  if (components->lpszScheme != nullptr) ::GlobalFree(components->lpszScheme);
  if (components->lpszUserName != nullptr) ::GlobalFree(components->lpszUserName);
  if (components->lpszPassword != nullptr) ::GlobalFree(components->lpszPassword);
  if (components->lpszUrlPath != nullptr) ::GlobalFree(components->lpszUrlPath);
  if (components->lpszExtraInfo != nullptr) ::GlobalFree(components->lpszExtraInfo);
  if (components->lpszHostName != nullptr) ::GlobalFree(components->lpszHostName);
}

std::filesystem::path FindApiExecutable(const std::filesystem::path& package_root) {
  const std::array<std::filesystem::path, 3> candidates = {
      package_root / L"bin" / L"kanai-api.exe",
      package_root / L"kanai-api.exe",
      std::filesystem::current_path() / L"bin" / L"kanai-api.exe",
  };
  for (const auto& candidate : candidates) {
    std::error_code error;
    if (std::filesystem::is_regular_file(candidate, error)) {
      return std::filesystem::absolute(candidate);
    }
  }
  return {};
}

std::filesystem::path FindBridgeExecutable(const std::filesystem::path& package_root) {
  return package_root / L"bin" / L"kanai-mozc-bridge.exe";
}

DWORD HttpRequest(std::uint16_t port, const wchar_t* method, const wchar_t* path,
                  const std::string* body, std::string* response) {
  const std::wstring url = L"http://127.0.0.1:" + std::to_wstring(port) + path;
  URL_COMPONENTS components{};
  components.dwStructSize = sizeof(components);
  const DWORD url_length = static_cast<DWORD>(url.size());
  if (!::WinHttpCrackUrl(url.c_str(), url_length, 0, 0, &components)) {
    FreeUrlComponents(&components);
    return 0;
  }

  HINTERNET session = ::WinHttpOpen(L"KanaAI Windows shell seam",
                                   WINHTTP_ACCESS_TYPE_NO_PROXY,
                                   WINHTTP_NO_PROXY_NAME,
                                   WINHTTP_NO_PROXY_BYPASS, 0);
  if (session == nullptr) {
    FreeUrlComponents(&components);
    return 0;
  }
  ::WinHttpSetTimeouts(session, 1000, 1000, 1000, 1000);

  HINTERNET connection = ::WinHttpConnect(session, components.lpszHostName, components.nPort, 0);
  if (connection == nullptr) {
    ::WinHttpCloseHandle(session);
    FreeUrlComponents(&components);
    return 0;
  }
  HINTERNET request = ::WinHttpOpenRequest(connection, method, const_cast<wchar_t*>(path),
                                           nullptr, WINHTTP_NO_REFERER,
                                           WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
  if (request == nullptr) {
    ::WinHttpCloseHandle(connection);
    ::WinHttpCloseHandle(session);
    FreeUrlComponents(&components);
    return 0;
  }

  BOOL sent = FALSE;
  if (body != nullptr && !body->empty()) {
    const wchar_t* content_type = L"application/json; charset=utf-8";
    ::WinHttpSetOption(request, WINHTTP_OPTION_CONTENT_TYPE, &content_type,
                       static_cast<DWORD>(sizeof(content_type)));
    sent = ::WinHttpSendRequest(request, const_cast<char*>(body->data()),
                                static_cast<DWORD>(body->size()),
                                static_cast<DWORD>(body->size()), 0,
                                WINHTTP_NO_REFERER);
  } else {
    sent = ::WinHttpSendRequest(request, WINHTTP_NO_REQUEST_DATA, 0, 0, 0,
                                WINHTTP_NO_REFERER);
  }
  if (!sent || !::WinHttpReceiveResponse(request, nullptr)) {
    ::WinHttpCloseHandle(request);
    ::WinHttpCloseHandle(connection);
    ::WinHttpCloseHandle(session);
    FreeUrlComponents(&components);
    return 0;
  }

  DWORD status_code = 0;
  DWORD status_size = sizeof(status_code);
  if (!::WinHttpQueryHeaders(request,
                             WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX, &status_code, &status_size,
                             WINHTTP_NO_HEADER_INDEX)) {
    status_code = 0;
  }

  if (response != nullptr) {
    response->clear();
    for (;;) {
      DWORD available = 0;
      if (!::WinHttpQueryDataAvailable(request, &available) || available == 0) {
        break;
      }
      std::vector<char> buffer(available);
      DWORD read = 0;
      if (!::WinHttpReadData(request, buffer.data(), available, &read)) {
        break;
      }
      response->append(buffer.data(), read);
    }
  }

  ::WinHttpCloseHandle(request);
  ::WinHttpCloseHandle(connection);
  ::WinHttpCloseHandle(session);
  FreeUrlComponents(&components);
  return status_code;
}

std::uint16_t HttpStatus(std::uint16_t port) {
  return static_cast<std::uint16_t>(HttpRequest(port, L"GET", L"/api/health", nullptr, nullptr));
}

bool SendJson(std::uint16_t port, const wchar_t* path, const std::string& body,
              std::string& response) {
  const DWORD status = HttpRequest(port, L"POST", path, &body, &response);
  return status >= 200 && status < 300;
}

bool WaitForService(std::uint16_t port, std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (HttpStatus(port) == 200) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
  }
  return false;
}

std::uint16_t ParsePort(std::wstring_view value) {
  if (value.empty()) {
    return 0;
  }
  unsigned long parsed = 0;
  try {
    parsed = std::stoul(std::wstring(value));
  } catch (...) {
    return 0;
  }
  if (parsed == 0 || parsed > 65535) {
    return 0;
  }
  return static_cast<std::uint16_t>(parsed);
}

bool ParseOptions(int argc, wchar_t** argv, Options* options) {
  if (options == nullptr) {
    return false;
  }
  std::error_code error;
  const std::filesystem::path executable_path = std::filesystem::path(argv[0]);
  if (executable_path.has_parent_path()) {
    options->package_root = executable_path.parent_path().parent_path();
  }
  else {
    options->package_root = std::filesystem::current_path(error);
    if (error) {
      return false;
    }
  }
  for (int index = 1; index < argc; ++index) {
    const std::wstring_view argument(argv[index]);
    auto require_value = [&](const char* name, std::wstring* value) {
      if (index + 1 >= argc) {
        std::wcerr << L"Missing value for " << name << L"\n";
        return false;
      }
      *value = argv[++index];
      return true;
    };
    if (argument == L"--package-root") {
      std::wstring value;
      if (!require_value("--package-root", &value)) {
        return false;
      }
      options->package_root = std::filesystem::path(value);
    } else if (argument == L"--port") {
      std::wstring value;
      if (!require_value("--port", &value)) {
        return false;
      }
      options->port = ParsePort(value);
      if (options->port == 0) {
        std::wcerr << L"--port must be between 1 and 65535\n";
        return false;
      }
    } else if (argument == L"--no-browser") {
      options->open_browser = false;
    } else if (argument == L"--probe") {
      options->probe_only = true;
    } else if (argument == L"--convert") {
      if (!require_value("--convert", &options->convert_text)) {
        return false;
      }
    } else if (argument == L"--help" || argument == L"-h") {
      PrintUsage();
      return false;
    } else {
      std::wcerr << L"Unknown option: " << argument << L"\n";
      PrintUsage();
      return false;
    }
  }
  options->package_root = std::filesystem::absolute(options->package_root, error);
  return !error;
}

std::string JsonEscape(std::wstring_view value) {
  std::string result;
  result.reserve(value.size() + 8);
  for (const wchar_t character : value) {
    switch (character) {
      case L'"':
        result += "\\\"";
        break;
      case L'\\':
        result += "\\\\";
        break;
      case L'\b':
        result += "\\b";
        break;
      case L'\f':
        result += "\\f";
        break;
      case L'\n':
        result += "\\n";
        break;
      case L'\r':
        result += "\\r";
        break;
      case L'\t':
        result += "\\t";
        break;
      default:
        if (character < 0x20) {
          static constexpr char hex[] = "0123456789abcdef";
          result += "\\u00";
          result.push_back(hex[(character >> 4) & 0xf]);
          result.push_back(hex[character & 0xf]);
        } else {
          const std::string utf8 = WideToUtf8(std::wstring_view(&character, 1));
          result += utf8;
        }
        break;
    }
  }
  return result;
}

HANDLE StartApi(const std::filesystem::path& api_path, const std::filesystem::path& package_root,
                std::uint16_t port) {
  const std::filesystem::path bridge_path = FindBridgeExecutable(package_root);
  const std::wstring old_bridge = EnvironmentValue(L"KANAI_MOZC_BRIDGE");
  const std::wstring old_profile = EnvironmentValue(L"KANAI_MOZC_PROFILE");
  const std::wstring old_port = EnvironmentValue(L"KANAI_PORT");
  const std::wstring port_text = std::to_wstring(port);
  ::SetEnvironmentVariableW(L"KANAI_MOZC_BRIDGE", bridge_path.c_str());
  ::SetEnvironmentVariableW(L"KANAI_PORT", port_text.c_str());
  const std::wstring local_app_data = EnvironmentValue(L"LOCALAPPDATA");
  const std::filesystem::path profile =
      local_app_data.empty() ? package_root / L"data" / L"mozc"
                             : std::filesystem::path(local_app_data) / L"KanaAI" / L"mozc";
  ::SetEnvironmentVariableW(L"KANAI_MOZC_PROFILE", profile.c_str());

  std::wstring command_line = QuoteArgument(api_path.wstring());
  std::vector<wchar_t> mutable_command_line(command_line.begin(), command_line.end());
  mutable_command_line.push_back(L'\0');
  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(startup_info);
  PROCESS_INFORMATION process_info{};
  const BOOL created = ::CreateProcessW(
      api_path.c_str(), mutable_command_line.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, package_root.c_str(), &startup_info, &process_info);
  ::SetEnvironmentVariableW(L"KANAI_MOZC_BRIDGE", old_bridge.empty() ? nullptr : old_bridge.c_str());
  ::SetEnvironmentVariableW(L"KANAI_MOZC_PROFILE", old_profile.empty() ? nullptr : old_profile.c_str());
  ::SetEnvironmentVariableW(L"KANAI_PORT", old_port.empty() ? nullptr : old_port.c_str());
  if (!created) {
    return nullptr;
  }
  ::CloseHandle(process_info.hThread);
  return process_info.hProcess;
}

bool OpenWorkbench(std::uint16_t port) {
  const std::wstring url = L"http://127.0.0.1:" + std::to_wstring(port);
  const HINSTANCE result = ::ShellExecuteW(nullptr, L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<INT_PTR>(result) > 32;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  for (int index = 1; index < argc; ++index) {
    if (std::wstring_view(argv[index]) == L"--help" || std::wstring_view(argv[index]) == L"-h") {
      PrintUsage();
      return 0;
    }
  }
  Options options;
  if (!ParseOptions(argc, argv, &options)) {
    return 2;
  }

  const bool already_ready = HttpStatus(options.port) == 200;
  if (options.probe_only) {
    if (already_ready) {
      std::wcout << L"KanaAI service is ready on 127.0.0.1:" << options.port << L"\n";
      return 0;
    }
    std::wcerr << L"KanaAI service is not ready on 127.0.0.1:" << options.port << L"\n";
    return 3;
  }

  const std::filesystem::path api_path = FindApiExecutable(options.package_root);
  if (api_path.empty() && !already_ready) {
    std::wcerr << L"kanai-api.exe was not found under the package root\n";
    return 4;
  }

  HANDLE api_process = already_ready ? nullptr : StartApi(api_path, options.package_root, options.port);
  if (!already_ready && api_process == nullptr) {
    std::wcerr << L"Could not start kanai-api.exe\n";
    return 5;
  }
  g_api_process = api_process;

  if (!WaitForService(options.port, std::chrono::seconds(30))) {
    std::wcerr << L"KanaAI service did not become ready\n";
    if (api_process != nullptr) {
      ::TerminateProcess(api_process, 1);
      ::WaitForSingleObject(api_process, 5000);
      ::CloseHandle(api_process);
    }
    return 6;
  }

  if (!options.convert_text.empty()) {
    const std::string body = "{\"romaji\":\"" + JsonEscape(options.convert_text) +
                             "\",\"contextBefore\":\"\",\"contextAfter\":\"\",\"limit\":9,"
                             "\"aiMode\":\"off\"}";
    std::string response;
    const bool sent = SendJson(options.port, L"/api/convert", body, response);
    if (sent) {
      std::cout << response << std::endl;
    } else {
      std::cerr << "Conversion request failed\n";
    }
    if (api_process != nullptr) {
      ::TerminateProcess(api_process, 0);
      ::WaitForSingleObject(api_process, 5000);
      ::CloseHandle(api_process);
    }
    return sent ? 0 : 7;
  }

  if (options.open_browser && !OpenWorkbench(options.port)) {
    std::wcerr << L"KanaAI is ready, but Windows could not open the workbench browser.\n";
  }
  std::wcout << L"KanaAI workbench: http://127.0.0.1:" << options.port << L"\n";
  std::wcout << L"Development shell seam only; no TSF TIP was registered.\n";

  ::SetConsoleCtrlHandler(ConsoleCtrlHandler, TRUE);
  if (api_process != nullptr) {
    ::WaitForSingleObject(api_process, INFINITE);
    ::CloseHandle(api_process);
  } else {
    std::wcout << L"Press Ctrl+C to stop waiting.\n";
    std::wcin.get();
  }
  ::SetConsoleCtrlHandler(ConsoleCtrlHandler, FALSE);
  return 0;
}
