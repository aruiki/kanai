#include "candidate_window.h"

#include "candidate_window_uia.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <objbase.h>
#include <windowsx.h>

namespace kanai::windows_tsf::ui {
namespace {

constexpr wchar_t kDefaultClassName[] = L"KanaAI.Tsf.CandidateWindow";
constexpr wchar_t kDefaultTitle[] = L"KanaAI candidates";
constexpr std::size_t kMaxCandidates = kUiCandidateLimit;
constexpr std::size_t kMaxPreeditSpans = 32;
constexpr std::size_t kMaxCandidateText = 512;
constexpr std::size_t kMaxDescriptionText = 256;
constexpr std::size_t kMaxAttributeText = 96;
constexpr int kMinimumDpi = 48;
constexpr int kMaximumDpi = 768;

// A hook callback has no user-data parameter. Keep a small registry keyed by
// the native hook so multiple TSF edit contexts in one process do not route a
// foreground event to whichever popup happened to be installed last.
std::mutex g_hook_mutex;
std::unordered_map<HWINEVENTHOOK, CandidateWindow*> g_hook_instances;

std::wstring BoundedWideText(std::wstring value, std::size_t maximum) {
  if (value.size() > maximum) {
    value.resize(maximum);
    if (!value.empty() &&
        (static_cast<std::uint16_t>(value.back()) & 0xFC00u) == 0xD800u) {
      value.pop_back();
    }
  }
  return value;
}

std::wstring JoinPreedit(const BrokerCandidatePageDto& page) {
  if (!page.preedit.empty()) {
    return BoundedWideText(page.preedit, kMaxCandidateText);
  }
  std::wstring result;
  for (const BrokerPreeditSpanDto& span : page.preedit_segments) {
    result += span.value;
  }
  return BoundedWideText(std::move(result), kMaxCandidateText);
}

UINT ClampDpi(UINT dpi) noexcept {
  if (dpi == 0) {
    dpi = 96;
  }
  return std::clamp(dpi, static_cast<UINT>(kMinimumDpi),
                    static_cast<UINT>(kMaximumDpi));
}

HFONT CreateUiFont(UINT dpi, int weight, bool small) noexcept {
  const int logical_height = small ? 10 : 11;
  const int pixel_height = -MulDiv(logical_height, static_cast<int>(dpi), 72);
  return ::CreateFontW(
      pixel_height, 0, 0, 0, weight, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
      L"Yu Gothic UI");
}

int HorizontalTextWidth(HDC dc, HFONT font, const std::wstring& text) noexcept {
  if (dc == nullptr || font == nullptr || text.empty()) {
    return 0;
  }
  HGDIOBJ old_font = ::SelectObject(dc, font);
  SIZE size{};
  const BOOL measured = ::GetTextExtentPoint32W(dc, text.c_str(),
                                                 static_cast<int>(text.size()),
                                                 &size);
  ::SelectObject(dc, old_font);
  return measured ? size.cx : 0;
}

void FillColorRect(HDC dc, const RECT& rect, COLORREF color) noexcept {
  HBRUSH brush = ::CreateSolidBrush(color);
  if (brush != nullptr) {
    ::FillRect(dc, &rect, brush);
    ::DeleteObject(brush);
  }
}

void DrawOneLine(HDC dc, RECT rect, const std::wstring& text, HFONT font,
                 COLORREF color) noexcept {
  ::SetTextColor(dc, color);
  HGDIOBJ old_font = ::SelectObject(dc, font);
  ::DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &rect,
              DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
  ::SelectObject(dc, old_font);
}

}  // namespace

CandidateWindow::CandidateWindow() = default;

CandidateWindow::~CandidateWindow() { Destroy(); }

bool CandidateWindow::Create(const CandidateWindowOptions& options,
                             CandidateWindowCallbacks callbacks) {
  Destroy();

  instance_ = options.instance == nullptr ? ::GetModuleHandleW(nullptr)
                                           : options.instance;
  owner_ = options.owner;
  class_name_ = options.class_name.empty() ? kDefaultClassName
                                             : options.class_name;
  title_ = options.title.empty() ? kDefaultTitle : options.title;
  callbacks_ = std::move(callbacks);
  light_dismiss_enabled_ = options.light_dismiss;

  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.style = CS_DBLCLKS;
  window_class.lpfnWndProc = &CandidateWindow::WindowProc;
  window_class.hInstance = instance_;
  window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  window_class.hbrBackground = nullptr;
  window_class.lpszClassName = class_name_.c_str();

  if (::RegisterClassExW(&window_class) != 0) {
    class_registered_by_us_ = true;
  } else if (::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    instance_ = nullptr;
    owner_ = nullptr;
    return false;
  }

  constexpr DWORD extended_style = WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
  constexpr DWORD window_style = WS_POPUP;
  window_ = ::CreateWindowExW(
      extended_style, class_name_.c_str(), title_.c_str(), window_style, 0, 0,
      ScaleForDpi(320, CurrentDpi()), ScaleForDpi(180, CurrentDpi()), owner_,
      nullptr, instance_, this);
  if (window_ == nullptr) {
    if (class_registered_by_us_) {
      ::UnregisterClassW(class_name_.c_str(), instance_);
      class_registered_by_us_ = false;
    }
    instance_ = nullptr;
    owner_ = nullptr;
    return false;
  }

  ::SetWindowLongPtrW(window_, GWLP_HWNDPARENT, reinterpret_cast<LONG_PTR>(owner_));
  ::SetWindowTextW(window_, title_.c_str());
  dpi_ = CurrentDpi();
  uia_provider_ = std::make_unique<CandidateWindowUiaProvider>(window_);
  return true;
}

void CandidateWindow::Destroy() {
  RemoveLightDismissHook();
  if (window_ != nullptr) {
    CandidateWindowReleaseUiaMap(window_);
    ::DestroyWindow(window_);
    window_ = nullptr;
  }
  // Keep the provider alive until WM_DESTROY has notified UIA that the native
  // window is gone. UIA may still hold a COM reference, which is released by
  // its final Release call after this object drops its owning reference.
  uia_provider_.reset();
  if (class_registered_by_us_ && instance_ != nullptr) {
    ::UnregisterClassW(class_name_.c_str(), instance_);
  }
  class_registered_by_us_ = false;
  instance_ = nullptr;
  owner_ = nullptr;
  class_name_.clear();
  title_.clear();
  callbacks_ = {};
  caret_screen_.reset();
  visible_ = false;
  dpi_ = 96;
  pressed_index_ = static_cast<std::size_t>(-1);
  focused_index_.reset();
  has_page_ = false;
  page_ = {};
}

bool CandidateWindow::IsCreated() const noexcept { return window_ != nullptr; }

bool CandidateWindow::IsVisible() const noexcept {
  return visible_ && window_ != nullptr && ::IsWindowVisible(window_) != FALSE;
}

bool CandidateWindow::Show(const BrokerCandidatePageDto& page,
                           const PixelRect& caret) {
  if (window_ == nullptr || !AcceptsPage(page)) {
    return false;
  }
  return Present(page, caret, true);
}

bool CandidateWindow::Update(const BrokerCandidatePageDto& page) {
  if (!IsVisible() || !AcceptsPage(page)) {
    return false;
  }
  const PixelRect caret = caret_screen_.value_or(PixelRect{0, 0, 0, 0});
  return Present(page, caret, false);
}

void CandidateWindow::MoveToCaret(const PixelRect& caret) {
  if (!IsVisible() || !has_page_) {
    return;
  }
  caret_screen_ = caret;
  const auto [width, height] = MeasureWindow();
  const PixelRect work_area = WorkAreaForCaret(caret);
  const CandidateWindowPlacement placement = PlaceCandidateWindow(
      caret, work_area, width, height, ScaleForDpi(4, dpi_));
  MoveWindowToPlacement(placement.x, placement.y, width, height, false);
}

void CandidateWindow::Hide(CandidateWindowDismissReason reason) {
  Dismiss(reason);
}

void CandidateWindow::SetOwner(HWND owner) {
  owner_ = owner;
  if (window_ != nullptr) {
    ::SetWindowLongPtrW(window_, GWLP_HWNDPARENT, reinterpret_cast<LONG_PTR>(owner));
  }
}

void CandidateWindow::SetLightDismissEnabled(bool enabled) {
  light_dismiss_enabled_ = enabled;
  if (!visible_) {
    return;
  }
  if (enabled) {
    InstallLightDismissHook();
  } else {
    RemoveLightDismissHook();
  }
}

void CandidateWindow::SetCallbacks(CandidateWindowCallbacks callbacks) {
  callbacks_ = std::move(callbacks);
}

bool CandidateWindow::HandleKeyDown(WPARAM key, LPARAM) {
  if (!IsVisible() || !has_page_ || page_.candidates.empty()) {
    return false;
  }

  const std::size_t count = page_.candidates.size();
  const std::size_t current = focused_index_.value_or(0);
  switch (key) {
    case VK_UP:
    case VK_LEFT:
      MoveFocus(current == 0 ? count - 1 : current - 1);
      return true;
    case VK_DOWN:
    case VK_RIGHT:
      MoveFocus(current + 1 >= count ? 0 : current + 1);
      return true;
    case VK_HOME:
      MoveFocus(0);
      return true;
    case VK_END:
      MoveFocus(count - 1);
      return true;
    case VK_PRIOR:
      SendCommand(CandidateCommandKind::kPreviousPage);
      return true;
    case VK_NEXT:
      SendCommand(CandidateCommandKind::kNextPage);
      return true;
    case VK_RETURN:
      CommitFocused();
      return true;
    case VK_ESCAPE: {
      // Build the command before clearing the visible snapshot.  The broker
      // remains the authority that actually cancels the composition.
      CandidateCommandDto cancel;
      cancel.generation = page_.generation;
      cancel.request_id = page_.request_id;
      cancel.kind = CandidateCommandKind::kCancel;
      cancel.page_index = page_.page_index;
      const auto command_callback = callbacks_.on_command;
      Dismiss(CandidateWindowDismissReason::kEscape);
      if (command_callback) {
        command_callback(cancel);
      }
      return true;
    }
    default:
      break;
  }

  if (key >= static_cast<WPARAM>('1') && key <= static_cast<WPARAM>('9')) {
    const std::size_t index = static_cast<std::size_t>(key - '1');
    if (index < count) {
      MoveFocus(index);
      CommitFocused();
      return true;
    }
  }
  return false;
}

std::optional<std::size_t> CandidateWindow::FocusedIndex() const noexcept {
  return focused_index_;
}

std::uint64_t CandidateWindow::Generation() const noexcept {
  return page_.generation;
}

LRESULT CALLBACK CandidateWindow::WindowProc(HWND window, UINT message,
                                              WPARAM w_param, LPARAM l_param) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(l_param);
    if (create == nullptr || create->lpCreateParams == nullptr) {
      return FALSE;
    }
    auto* self = static_cast<CandidateWindow*>(create->lpCreateParams);
    self->window_ = window;
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(self));
    return TRUE;
  }

  auto* self = reinterpret_cast<CandidateWindow*>(::GetWindowLongPtrW(
      window, GWLP_USERDATA));
  if (self == nullptr) {
    return ::DefWindowProcW(window, message, w_param, l_param);
  }
  return self->HandleMessage(message, w_param, l_param);
}

LRESULT CandidateWindow::HandleMessage(UINT message, WPARAM w_param,
                                        LPARAM l_param) {
  switch (message) {
    case WM_CREATE:
      return 0;
    case WM_DESTROY:
      RemoveLightDismissHook();
      CandidateWindowReleaseUiaMap(window_);
      return 0;
    case WM_NCDESTROY: {
      const LRESULT result = ::DefWindowProcW(window_, message, w_param, l_param);
      ::SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
      visible_ = false;
      has_page_ = false;
      page_ = {};
      focused_index_.reset();
      caret_screen_.reset();
      window_ = nullptr;
      return result;
    }
    case WM_GETOBJECT:
      return CandidateWindowHandleGetObject(window_, uia_provider_.get(),
                                            w_param, l_param);
    case WM_DPICHANGED: {
      dpi_ = HIWORD(w_param) == 0 ? 96u : HIWORD(w_param);
      const auto* suggested = reinterpret_cast<const RECT*>(l_param);
      if (suggested != nullptr && window_ != nullptr) {
        const int width = suggested->right - suggested->left;
        const int height = suggested->bottom - suggested->top;
        ::SetWindowPos(window_, HWND_TOP, suggested->left, suggested->top,
                       std::max(1, width), std::max(1, height),
                       SWP_NOACTIVATE | SWP_NOZORDER);
      }
      return 0;
    }
    case WM_PAINT:
      Paint();
      return 0;
    case WM_ERASEBKGND:
      return 1;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
      if (HandleKeyDown(w_param, l_param)) {
        return 0;
      }
      break;
    case WM_LBUTTONDOWN: {
      pressed_index_ = HitTest(GET_X_LPARAM(l_param), GET_Y_LPARAM(l_param));
      ::SetCapture(window_);
      return 0;
    }
    case WM_LBUTTONUP: {
      ::ReleaseCapture();
      const std::size_t released_index =
          HitTest(GET_X_LPARAM(l_param), GET_Y_LPARAM(l_param));
      const std::size_t pressed_index = pressed_index_;
      pressed_index_ = static_cast<std::size_t>(-1);
      if (released_index != static_cast<std::size_t>(-1) &&
          released_index == pressed_index) {
        if (released_index == focused_index_.value_or(0)) {
          CommitFocused();
        } else {
          MoveFocus(released_index);
        }
      }
      return 0;
    }
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_ACTIVATE:
      if (LOWORD(w_param) == WA_INACTIVE && visible_) {
        Dismiss(CandidateWindowDismissReason::kFocusLoss);
      }
      return 0;
    case WM_KILLFOCUS:
      if (visible_) {
        Dismiss(CandidateWindowDismissReason::kFocusLoss);
      }
      return 0;
    case WM_ACTIVATEAPP:
      if (w_param == FALSE && visible_) {
        Dismiss(CandidateWindowDismissReason::kFocusLoss);
      }
      return 0;
    case WM_CANCELMODE:
    case WM_CAPTURECHANGED:
      pressed_index_ = static_cast<std::size_t>(-1);
      return 0;
    case WM_DISPLAYCHANGE:
    case WM_SETTINGCHANGE:
      if (visible_ && has_page_) {
        const PixelRect caret = caret_screen_.value_or(PixelRect{0, 0, 0, 0});
        const auto [width, height] = MeasureWindow();
        const PixelRect work_area = WorkAreaForCaret(caret);
        const CandidateWindowPlacement placement = PlaceCandidateWindow(
            caret, work_area, width, height, ScaleForDpi(4, dpi_));
        MoveWindowToPlacement(placement.x, placement.y, width, height, false);
      }
      return 0;
    default:
      break;
  }
  return ::DefWindowProcW(window_, message, w_param, l_param);
}

bool CandidateWindow::Present(const BrokerCandidatePageDto& page,
                               const PixelRect& caret, bool show_window) {
  if (window_ == nullptr || !AcceptsPage(page)) {
    return false;
  }

  const bool new_request = !has_page_ ||
                           page.generation != page_.generation ||
                           page.request_id != page_.request_id;
  page_ = SanitizePage(page);
  has_page_ = true;
  caret_screen_ = caret;
  if (page_.candidates.empty()) {
    Dismiss(CandidateWindowDismissReason::kNoCandidates);
    return false;
  }

  if (new_request || !focused_index_.has_value() ||
      focused_index_.value() >= page_.candidates.size()) {
    focused_index_ = page_.focused_index.value_or(0);
  }
  if (focused_index_.value() >= page_.candidates.size()) {
    focused_index_ = 0;
  }
  if (uia_provider_ != nullptr) {
    uia_provider_->SetPage(page_);
    uia_provider_->SetFocusedIndex(focused_index_);
  }

  dpi_ = CurrentDpi();
  const auto [width, height] = MeasureWindow();
  const PixelRect work_area = WorkAreaForCaret(caret);
  const CandidateWindowPlacement placement = PlaceCandidateWindow(
      caret, work_area, width, height, ScaleForDpi(4, dpi_));
  const bool moved = MoveWindowToPlacement(placement.x, placement.y, width,
                                           height, show_window);
  if (!moved) {
    return false;
  }
  if (show_window) {
    visible_ = true;
    InstallLightDismissHook();
  }
  UpdateFocusRectangle();
  return true;
}

bool CandidateWindow::AcceptsPage(const BrokerCandidatePageDto& page) const noexcept {
  if (page.contract_version != kBrokerDtoVersion || page.request_id == 0) {
    return false;
  }
  if (!has_page_) {
    return true;
  }
  if (page.generation < page_.generation) {
    return false;
  }
  if (page.generation == page_.generation && page.request_id < page_.request_id) {
    return false;
  }
  return true;
}

BrokerCandidatePageDto CandidateWindow::SanitizePage(
    const BrokerCandidatePageDto& page) const {
  BrokerCandidatePageDto bounded = page;
  bounded.contract_version = kBrokerDtoVersion;
  bounded.page_count = std::max<std::size_t>(1, bounded.page_count);
  bounded.reading = BoundedWideText(std::move(bounded.reading), kMaxCandidateText);
  bounded.preedit = BoundedWideText(std::move(bounded.preedit), kMaxCandidateText);
  if (bounded.preedit_segments.size() > kMaxPreeditSpans) {
    bounded.preedit_segments.resize(kMaxPreeditSpans);
  }
  for (BrokerPreeditSpanDto& span : bounded.preedit_segments) {
    span.value = BoundedWideText(std::move(span.value), kMaxCandidateText);
    if (span.reading.has_value()) {
      span.reading = BoundedWideText(std::move(*span.reading), kMaxCandidateText);
    }
  }

  std::vector<BrokerCandidateDto> candidates;
  candidates.reserve(std::min(bounded.candidates.size(), kMaxCandidates));
  std::unordered_set<std::int64_t> ids;
  for (BrokerCandidateDto& candidate : bounded.candidates) {
    if (candidate.text.empty() || candidates.size() >= kMaxCandidates) {
      continue;
    }
    // Duplicate IDs make a selection ambiguous.  The broker should reject
    // them; dropping later duplicates is safer than inventing a ranking.
    if (!ids.insert(candidate.candidate_id).second) {
      continue;
    }
    candidate.text = BoundedWideText(std::move(candidate.text), kMaxCandidateText);
    if (candidate.reading.has_value()) {
      candidate.reading = BoundedWideText(std::move(*candidate.reading),
                                          kMaxCandidateText);
    }
    candidate.description =
        BoundedWideText(std::move(candidate.description), kMaxDescriptionText);
    if (!std::isfinite(candidate.score)) {
      candidate.score = 0.0;
    }
    if (candidate.attributes.size() > 8) {
      candidate.attributes.resize(8);
    }
    for (std::wstring& attribute : candidate.attributes) {
      attribute = BoundedWideText(std::move(attribute), kMaxAttributeText);
    }
    candidates.push_back(std::move(candidate));
  }
  bounded.candidates = std::move(candidates);
  if (bounded.focused_index.has_value() &&
      bounded.focused_index.value() >= bounded.candidates.size()) {
    bounded.focused_index.reset();
  }
  return bounded;
}

void CandidateWindow::MoveFocus(std::size_t index) {
  if (!visible_ || page_.candidates.empty()) {
    return;
  }
  const std::size_t count = page_.candidates.size();
  focused_index_ = index < count ? index : 0;
  if (uia_provider_ != nullptr) {
    uia_provider_->SetFocusedIndex(focused_index_);
  }
  UpdateFocusRectangle();
}

void CandidateWindow::CommitFocused() {
  if (!visible_ || !focused_index_.has_value() ||
      focused_index_.value() >= page_.candidates.size()) {
    return;
  }
  SendCommand(CandidateCommandKind::kCommit,
              page_.candidates[focused_index_.value()].candidate_id);
}

void CandidateWindow::SendCommand(
    CandidateCommandKind kind, std::optional<std::int64_t> candidate_id) {
  CandidateCommandDto command;
  command.generation = page_.generation;
  command.request_id = page_.request_id;
  command.kind = kind;
  command.candidate_id = candidate_id;
  command.page_index = page_.page_index;
  if (callbacks_.on_command) {
    callbacks_.on_command(command);
  }
}

void CandidateWindow::Dismiss(CandidateWindowDismissReason reason) {
  if (window_ == nullptr) {
    return;
  }
  const bool was_visible = visible_;
  RemoveLightDismissHook();
  if (::IsWindowVisible(window_) != FALSE) {
    ::ShowWindow(window_, SW_HIDE);
  }
  visible_ = false;
  pressed_index_ = static_cast<std::size_t>(-1);
  focused_index_.reset();
  ResetSnapshot();
  if (was_visible && callbacks_.on_dismiss) {
    callbacks_.on_dismiss(reason);
  }
}

void CandidateWindow::InstallLightDismissHook() {
  if (!visible_ || !light_dismiss_enabled_ || foreground_hook_ != nullptr) {
    return;
  }
  constexpr DWORD hook_flags = WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS;
  foreground_hook_ = ::SetWinEventHook(
      EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
      &CandidateWindow::WinEventProc, 0, 0, hook_flags);
  focus_hook_ = ::SetWinEventHook(
      EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS, nullptr,
      &CandidateWindow::WinEventProc, 0, 0, hook_flags);
  if (foreground_hook_ == nullptr || focus_hook_ == nullptr) {
    RemoveLightDismissHook();
    return;
  }
  std::lock_guard<std::mutex> lock(g_hook_mutex);
  g_hook_instances.emplace(foreground_hook_, this);
  g_hook_instances.emplace(focus_hook_, this);
}

void CandidateWindow::RemoveLightDismissHook() {
  const HWINEVENTHOOK hooks[] = {foreground_hook_, focus_hook_};
  foreground_hook_ = nullptr;
  focus_hook_ = nullptr;
  for (const HWINEVENTHOOK hook : hooks) {
    if (hook != nullptr) {
      ::UnhookWinEvent(hook);
    }
  }
  std::lock_guard<std::mutex> lock(g_hook_mutex);
  for (const HWINEVENTHOOK hook : hooks) {
    if (hook != nullptr) {
      g_hook_instances.erase(hook);
    }
  }
}

void CandidateWindow::HandleForegroundChanged(HWND foreground) {
  if (!visible_ || window_ == nullptr) {
    return;
  }
  if (foreground == nullptr) {
    Dismiss(CandidateWindowDismissReason::kFocusLoss);
    return;
  }
  const HWND candidate_root = ::GetAncestor(window_, GA_ROOT);
  const HWND foreground_root = ::GetAncestor(foreground, GA_ROOT);
  const HWND owner_root = ::GetAncestor(owner_, GA_ROOT);
  if (foreground_root == candidate_root || foreground_root == owner_root ||
      ::IsChild(window_, foreground) != FALSE) {
    return;
  }
  Dismiss(CandidateWindowDismissReason::kFocusLoss);
}

void CandidateWindow::Paint() {
  PAINTSTRUCT paint{};
  HDC target = ::BeginPaint(window_, &paint);
  if (target == nullptr || window_ == nullptr) {
    return;
  }
  RECT client{};
  ::GetClientRect(window_, &client);
  const int width = std::max(1L, client.right - client.left);
  const int height = std::max(1L, client.bottom - client.top);
  HDC memory = ::CreateCompatibleDC(target);
  HBITMAP bitmap = memory == nullptr ? nullptr : ::CreateCompatibleBitmap(target, width, height);
  HGDIOBJ old_bitmap = memory == nullptr ? nullptr : ::SelectObject(memory, bitmap);

  HDC canvas = memory == nullptr ? target : memory;
  const COLORREF background = ::GetSysColor(COLOR_WINDOW);
  const COLORREF normal_text = ::GetSysColor(COLOR_WINDOWTEXT);
  const COLORREF secondary_text = ::GetSysColor(COLOR_GRAYTEXT);
  const COLORREF selected_background = ::GetSysColor(COLOR_HIGHLIGHT);
  const COLORREF selected_text = ::GetSysColor(COLOR_HIGHLIGHTTEXT);
  const int header_height = ScaleForDpi(48, dpi_);
  const int footer_height = ScaleForDpi(28, dpi_);
  const int row_height = RowHeight();
  const int padding = ScaleForDpi(10, dpi_);
  const int number_width = ScaleForDpi(30, dpi_);

  RECT all{0, 0, width, height};
  FillColorRect(canvas, all, background);
  HFONT normal_font = CreateUiFont(dpi_, FW_NORMAL, false);
  HFONT small_font = CreateUiFont(dpi_, FW_NORMAL, true);
  HFONT bold_font = CreateUiFont(dpi_, FW_BOLD, false);
  ::SetBkMode(canvas, TRANSPARENT);

  RECT header{0, 0, width, header_height};
  DrawOneLine(canvas, header, page_.reading.empty() ? kDefaultTitle : page_.reading,
              bold_font != nullptr ? bold_font : normal_font, normal_text);
  const std::wstring preedit = JoinPreedit(page_);
  if (!preedit.empty()) {
    RECT preedit_rect{padding, header_height - ScaleForDpi(19, dpi_),
                      width - padding, header_height};
    DrawOneLine(canvas, preedit_rect, preedit,
                small_font != nullptr ? small_font : normal_font,
                secondary_text);
  }
  RECT separator{0, header_height, width, header_height + 1};
  FillColorRect(canvas, separator, ::GetSysColor(COLOR_WINDOWFRAME));

  const int first_row = header_height + 1;
  for (std::size_t index = 0; index < page_.candidates.size(); ++index) {
    const int top = first_row + static_cast<int>(index) * row_height;
    if (top >= height - footer_height) {
      break;
    }
    RECT row{0, top, width, std::min(height, top + row_height)};
    const bool selected = focused_index_.has_value() &&
                          focused_index_.value() == index;
    FillColorRect(canvas, row, selected ? selected_background : background);
    const COLORREF row_text = selected ? selected_text : normal_text;
    const std::wstring number = std::to_wstring(index + 1) + L".";
    RECT number_rect{padding, top, padding + number_width, top + row_height};
    DrawOneLine(canvas, number_rect, number,
                small_font != nullptr ? small_font : normal_font, row_text);

    const BrokerCandidateDto& candidate = page_.candidates[index];
    const int text_left = padding + number_width;
    RECT text_rect{text_left, top, width - padding, top + row_height};
    if (candidate.description.empty()) {
      DrawOneLine(canvas, text_rect, candidate.text,
                  normal_font != nullptr ? normal_font : small_font, row_text);
    } else {
      RECT surface_rect{text_left, top, width - padding,
                        top + row_height / 2 + ScaleForDpi(2, dpi_)};
      DrawOneLine(canvas, surface_rect, candidate.text,
                  normal_font != nullptr ? normal_font : small_font, row_text);
      RECT description_rect{text_left, top + row_height / 2,
                            width - padding, top + row_height};
      DrawOneLine(canvas, description_rect, candidate.description,
                  small_font != nullptr ? small_font : normal_font,
                  selected ? row_text : secondary_text);
    }
  }

  RECT footer{0, std::max(first_row, height - footer_height), width, height};
  FillColorRect(canvas, footer, ::GetSysColor(COLOR_BTNFACE));
  const std::wstring page_text =
      L"Page " + std::to_wstring(page_.page_index + 1) + L"/" +
      std::to_wstring(page_.page_count) +
      L"    \u2190\u2193 select   Enter commit   Esc cancel";
  DrawOneLine(canvas, footer, page_text,
              small_font != nullptr ? small_font : normal_font, normal_text);
  RECT border{0, 0, width, height};
  ::FrameRect(canvas, &border, static_cast<HBRUSH>(::GetStockObject(GRAY_BRUSH)));

  if (memory != nullptr) {
    ::BitBlt(target, 0, 0, width, height, memory, 0, 0, SRCCOPY);
    ::SelectObject(memory, old_bitmap);
    ::DeleteObject(bitmap);
    ::DeleteDC(memory);
  }
  if (normal_font != nullptr) ::DeleteObject(normal_font);
  if (small_font != nullptr) ::DeleteObject(small_font);
  if (bold_font != nullptr) ::DeleteObject(bold_font);
  ::EndPaint(window_, &paint);
}

void CandidateWindow::UpdateFocusRectangle() {
  if (window_ != nullptr && visible_) {
    ::InvalidateRect(window_, nullptr, FALSE);
  }
}

void CandidateWindow::ResetSnapshot() {
  page_ = {};
  has_page_ = false;
  focused_index_.reset();
  if (uia_provider_ != nullptr) {
    uia_provider_->SetPage(BrokerCandidatePageDto{});
  }
}

UINT CandidateWindow::CurrentDpi() const noexcept {
  UINT dpi = 0;
  if (window_ != nullptr) {
    dpi = ::GetDpiForWindow(window_);
  }
  if (dpi == 0) {
    dpi = ::GetDpiForSystem();
  }
  return ClampDpi(dpi);
}

PixelRect CandidateWindow::WorkAreaForCaret(const PixelRect& caret) const noexcept {
  POINT point{caret.left, caret.bottom};
  const HMONITOR monitor = ::MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (monitor != nullptr && ::GetMonitorInfoW(monitor, &info) != FALSE) {
    return {info.rcWork.left, info.rcWork.top, info.rcWork.right,
            info.rcWork.bottom};
  }
  RECT work{};
  if (::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0) != FALSE) {
    return {work.left, work.top, work.right, work.bottom};
  }
  return {0, 0, ::GetSystemMetrics(SM_CXSCREEN),
          ::GetSystemMetrics(SM_CYSCREEN)};
}

std::pair<int, int> CandidateWindow::MeasureWindow() const {
  const UINT dpi = CurrentDpi();
  const int minimum_width = ScaleForDpi(320, dpi);
  const int maximum_width = ScaleForDpi(720, dpi);
  const int horizontal_padding = ScaleForDpi(48, dpi);
  int widest_text = 0;
  HDC dc = ::GetDC(window_);
  const bool release_dc = dc != nullptr;
  if (dc == nullptr) {
    dc = ::GetDC(nullptr);
  }
  HFONT font = CreateUiFont(dpi, FW_NORMAL, false);
  if (dc != nullptr && font != nullptr) {
    const std::wstring page_prefix = page_.reading.empty() ? L"" : page_.reading + L"  ";
    widest_text = std::max(widest_text,
                           HorizontalTextWidth(dc, font, page_prefix));
    for (std::size_t index = 0; index < page_.candidates.size(); ++index) {
      const BrokerCandidateDto& candidate = page_.candidates[index];
      std::wstring text = std::to_wstring(index + 1) + L". " + candidate.text;
      if (candidate.reading.has_value() && !candidate.reading->empty()) {
        text += L"  (" + *candidate.reading + L")";
      }
      widest_text = std::max(widest_text, HorizontalTextWidth(dc, font, text));
    }
  }
  if (font != nullptr) ::DeleteObject(font);
  if (release_dc && dc != nullptr) ::ReleaseDC(window_, dc);

  int width = std::clamp(widest_text + horizontal_padding, minimum_width,
                         maximum_width);
  int height = ScaleForDpi(48, dpi) + ScaleForDpi(1, dpi) +
               static_cast<int>(page_.candidates.size()) * RowHeight() +
               ScaleForDpi(28, dpi);

  RECT adjusted{};
  if (::AdjustWindowRectExForDpi(&adjusted, WS_POPUP, FALSE,
                                 WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, dpi) !=
      FALSE) {
    width += std::max<LONG>(0, adjusted.right - adjusted.left);
    height += std::max<LONG>(0, adjusted.bottom - adjusted.top);
  }
  return {std::max(1, width), std::max(1, height)};
}

int CandidateWindow::RowHeight() const noexcept {
  return std::max(ScaleForDpi(30, dpi_), ScaleForDpi(20, dpi_));
}

bool CandidateWindow::MoveWindowToPlacement(int x, int y, int width, int height,
                                            bool show_window) {
  if (window_ == nullptr) {
    return false;
  }
  UINT flags = SWP_NOACTIVATE;
  if (show_window) {
    flags |= SWP_SHOWWINDOW;
  }
  const BOOL moved = ::SetWindowPos(
      window_, HWND_TOP, x, y, std::max(1, width), std::max(1, height), flags);
  if (moved == FALSE) {
    return false;
  }
  if (show_window) {
    ::ShowWindow(window_, SW_SHOWNOACTIVATE);
  }
  return true;
}

std::size_t CandidateWindow::HitTest(int x, int y) const noexcept {
  if (!visible_ || page_.candidates.empty() || x < 0) {
    return static_cast<std::size_t>(-1);
  }
  RECT client{};
  if (window_ == nullptr || ::GetClientRect(window_, &client) == FALSE) {
    return static_cast<std::size_t>(-1);
  }
  const int first_row = ScaleForDpi(48, dpi_) + 1;
  const int footer_top = client.bottom - ScaleForDpi(28, dpi_);
  const int row_height = RowHeight();
  if (y < first_row || y >= footer_top || row_height <= 0) {
    return static_cast<std::size_t>(-1);
  }
  const std::size_t index =
      static_cast<std::size_t>((y - first_row) / row_height);
  return index < page_.candidates.size() ? index
                                          : static_cast<std::size_t>(-1);
}

void CALLBACK CandidateWindow::WinEventProc(HWINEVENTHOOK hook, DWORD,
                                             HWND event_window, LONG, LONG,
                                             DWORD, DWORD) {
  CandidateWindow* instance = FindHookInstance(hook);
  if (instance != nullptr) {
    instance->HandleForegroundChanged(event_window);
  }
}

CandidateWindow* CandidateWindow::FindHookInstance(HWINEVENTHOOK hook) noexcept {
  std::lock_guard<std::mutex> lock(g_hook_mutex);
  const auto instance = g_hook_instances.find(hook);
  return instance == g_hook_instances.end() ? nullptr : instance->second;
}

}  // namespace kanai::windows_tsf::ui
