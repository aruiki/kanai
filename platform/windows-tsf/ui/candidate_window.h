// Native Win32 candidate popup used by the Windows TSF input processor.
//
// The window is deliberately owned by the TSF client window and is shown with
// SWP_NOACTIVATE.  TSF normally keeps keyboard focus in the application, so
// the host may forward normalized key messages through HandleKeyDown() (or
// send WM_KEYDOWN to the HWND) while the pointer path remains native.
#ifndef KANAI_PLATFORM_WINDOWS_TSF_UI_CANDIDATE_WINDOW_H_
#define KANAI_PLATFORM_WINDOWS_TSF_UI_CANDIDATE_WINDOW_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "broker_dto.h"
#include "candidate_window_geometry.h"

namespace kanai::windows_tsf::ui {

class CandidateWindowUiaProvider;

enum class CandidateWindowDismissReason : std::uint8_t {
  kFocusLoss,
  kEscape,
  kOwnerDestroyed,
  kNoCandidates,
  kReplaced,
  kDestroyed,
  kSystem,
};

struct CandidateWindowOptions {
  HINSTANCE instance = nullptr;
  HWND owner = nullptr;
  std::wstring class_name = L"KanaAI.Tsf.CandidateWindow";
  std::wstring title = L"KanaAI candidates";
  bool light_dismiss = true;
};

struct CandidateWindowCallbacks {
  std::function<void(const CandidateCommandDto&)> on_command;
  std::function<void(CandidateWindowDismissReason)> on_dismiss;
};

class CandidateWindow final {
 public:
  CandidateWindow();
  ~CandidateWindow();

  CandidateWindow(const CandidateWindow&) = delete;
  CandidateWindow& operator=(const CandidateWindow&) = delete;
  CandidateWindow(CandidateWindow&&) = delete;
  CandidateWindow& operator=(CandidateWindow&&) = delete;

  // All methods must be called on the TSF/UI thread that owns the HWND.
  [[nodiscard]] bool Create(const CandidateWindowOptions& options,
                             CandidateWindowCallbacks callbacks);
  void Destroy();
  [[nodiscard]] bool IsCreated() const noexcept;
  [[nodiscard]] bool IsVisible() const noexcept;
  [[nodiscard]] HWND Handle() const noexcept { return window_; }
  [[nodiscard]] HWND Owner() const noexcept { return owner_; }

  // Presents a broker snapshot at a screen-coordinate caret rectangle.  The
  // rectangle and returned placement use physical pixels, not logical pixels.
  bool Show(const BrokerCandidatePageDto& page, const PixelRect& caret);
  bool Update(const BrokerCandidatePageDto& page);
  void MoveToCaret(const PixelRect& caret);
  void Hide(CandidateWindowDismissReason reason =
                CandidateWindowDismissReason::kSystem);

  void SetOwner(HWND owner);
  void SetLightDismissEnabled(bool enabled);
  void SetCallbacks(CandidateWindowCallbacks callbacks);

  // The non-activating popup cannot become keyboard-focused by itself.  TSF's
  // key sink calls this for navigation/commit/cancel, preserving application
  // focus while still giving the popup deterministic keyboard semantics.
  bool HandleKeyDown(WPARAM key, LPARAM key_data);

  [[nodiscard]] std::optional<std::size_t> FocusedIndex() const noexcept;
  [[nodiscard]] std::uint64_t Generation() const noexcept;

  static LRESULT CALLBACK WindowProc(HWND window, UINT message,
                                     WPARAM w_param, LPARAM l_param);

 private:
  LRESULT HandleMessage(UINT message, WPARAM w_param, LPARAM l_param);
  bool Present(const BrokerCandidatePageDto& page, const PixelRect& caret,
               bool show_window);
  bool AcceptsPage(const BrokerCandidatePageDto& page) const noexcept;
  BrokerCandidatePageDto SanitizePage(const BrokerCandidatePageDto& page) const;
  void MoveFocus(std::size_t index);
  void CommitFocused();
  void SendCommand(CandidateCommandKind kind,
                   std::optional<std::int64_t> candidate_id = std::nullopt);
  void Dismiss(CandidateWindowDismissReason reason);
  void InstallLightDismissHook();
  void RemoveLightDismissHook();
  void HandleForegroundChanged(HWND foreground);
  void Paint();
  void UpdateFocusRectangle();
  void ResetSnapshot();
  [[nodiscard]] UINT CurrentDpi() const noexcept;
  [[nodiscard]] PixelRect WorkAreaForCaret(const PixelRect& caret) const noexcept;
  [[nodiscard]] std::pair<int, int> MeasureWindow() const;
  [[nodiscard]] int RowHeight() const noexcept;
  bool MoveWindowToPlacement(int x, int y, int width, int height,
                             bool show_window);
  [[nodiscard]] std::size_t HitTest(int x, int y) const noexcept;

  static void CALLBACK WinEventProc(HWINEVENTHOOK hook, DWORD event,
                                    HWND event_window, LONG object_id,
                                    LONG child_id, DWORD event_time,
                                    DWORD event_type);
  static CandidateWindow* FindHookInstance(HWINEVENTHOOK hook) noexcept;

  HINSTANCE instance_ = nullptr;
  HWND window_ = nullptr;
  HWND owner_ = nullptr;
  std::wstring class_name_;
  std::wstring title_;
  CandidateWindowCallbacks callbacks_;
  BrokerCandidatePageDto page_;
  bool has_page_ = false;
  bool visible_ = false;
  bool light_dismiss_enabled_ = true;
  bool class_registered_by_us_ = false;
  std::optional<PixelRect> caret_screen_;
  std::optional<std::size_t> focused_index_;
  std::size_t pressed_index_ = static_cast<std::size_t>(-1);
  std::uint32_t dpi_ = 96;
  std::unique_ptr<CandidateWindowUiaProvider> uia_provider_;
  HWINEVENTHOOK foreground_hook_ = nullptr;
  HWINEVENTHOOK focus_hook_ = nullptr;
};

}  // namespace kanai::windows_tsf::ui

#endif  // KANAI_PLATFORM_WINDOWS_TSF_UI_CANDIDATE_WINDOW_H_
