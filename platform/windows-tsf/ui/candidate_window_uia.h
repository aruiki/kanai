// UI Automation metadata and a deliberately small provider stub.
//
// The provider is enough to expose a stable window identity and basic state to
// a UIA client while the candidate item tree, selection pattern, live regions,
// and event bridge are still being designed.  It is not a claim that the TSF
// candidate UI is accessible or conformant.
#ifndef KANAI_PLATFORM_WINDOWS_TSF_UI_CANDIDATE_WINDOW_UIA_H_
#define KANAI_PLATFORM_WINDOWS_TSF_UI_CANDIDATE_WINDOW_UIA_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>

#include <uiautomationclient.h>
#include <uiautomationcore.h>
#include <uiautomationcoreapi.h>
#include <windows.h>

#include "broker_dto.h"

namespace kanai::windows_tsf::ui {

inline constexpr wchar_t kCandidateWindowAutomationId[] =
    L"KanaAI.Tsf.CandidateWindow";
inline constexpr wchar_t kCandidateWindowAutomationName[] =
    L"KanaAI candidate list";

struct CandidateAutomationMetadata {
  std::wstring automation_id;
  std::wstring name;
  std::wstring help_text;
  std::size_t ordinal = 0;
  bool selected = false;
  bool prediction = false;
};

// These pure metadata helpers are also the contract a future per-candidate
// provider can reuse.  IDs are stable only while the request/generation is
// current; they are not persisted or exposed as a database key.
[[nodiscard]] std::wstring MakeCandidateAutomationId(
    const BrokerCandidateDto& candidate, std::size_t ordinal);
[[nodiscard]] std::wstring MakeCandidateAutomationName(
    const BrokerCandidateDto& candidate);
[[nodiscard]] CandidateAutomationMetadata MakeCandidateAutomationMetadata(
    const BrokerCandidateDto& candidate, std::size_t ordinal, bool selected);

// A server-side IRawElementProviderSimple for the popup itself.  It exposes
// only root metadata and intentionally returns no patterns.  In particular,
// this class does not pretend to expose a complete candidate collection or
// selection semantics; those are follow-up work for the TSF accessibility
// gate.
class CandidateWindowUiaProvider final : public IRawElementProviderSimple {
 public:
  explicit CandidateWindowUiaProvider(HWND window);
  ~CandidateWindowUiaProvider();

  CandidateWindowUiaProvider(const CandidateWindowUiaProvider&) = delete;
  CandidateWindowUiaProvider& operator=(const CandidateWindowUiaProvider&) = delete;

  void SetPage(const BrokerCandidatePageDto& page);
  void SetFocusedIndex(std::optional<std::size_t> index);
  void SetWindow(HWND window);

  [[nodiscard]] HWND window() const noexcept { return window_; }

  // COM identity and IRawElementProviderSimple.
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE get_ProviderOptions(
      ProviderOptions* options) override;
  HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID pattern_id,
                                                 IUnknown** provider) override;
  HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property_id,
                                               VARIANT* value) override;
  HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(
      IRawElementProviderSimple** provider) override;

 private:
  [[nodiscard]] std::wstring RootNameUnlocked() const;
  [[nodiscard]] bool HasKeyboardFocus() const;

  LONG reference_count_ = 1;
  HWND window_ = nullptr;
  BrokerCandidatePageDto page_;
  mutable std::mutex page_mutex_;
};

// Called from WM_GETOBJECT.  UiaReturnRawElementProvider performs the
// required COM reference-count handoff; callers must keep the provider alive
// until the window is destroyed.
[[nodiscard]] LRESULT CandidateWindowHandleGetObject(
    HWND window, CandidateWindowUiaProvider* provider, WPARAM w_param,
    LPARAM l_param);

// Tells UIA to release any provider/event map entries during WM_DESTROY.
void CandidateWindowReleaseUiaMap(HWND window) noexcept;

}  // namespace kanai::windows_tsf::ui

#endif  // KANAI_PLATFORM_WINDOWS_TSF_UI_CANDIDATE_WINDOW_UIA_H_
