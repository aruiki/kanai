#include "candidate_window_uia.h"

#include <algorithm>
#include <limits>
#include <string>
#include <utility>

#include <objbase.h>
#include <propvarutil.h>

namespace kanai::windows_tsf::ui {
namespace {

constexpr std::size_t kMaxNameLength = 512;
constexpr std::size_t kMaxHelpLength = 256;

std::wstring BoundedText(std::wstring value, std::size_t maximum) {
  if (value.size() <= maximum) {
    return value;
  }
  value.resize(maximum);
  // Do not leave a dangling UTF-16 high surrogate at a truncation boundary.
  if (!value.empty() && (static_cast<std::uint16_t>(value.back()) & 0xFC00u) == 0xD800u) {
    value.pop_back();
  }
  return value;
}

std::wstring CandidateIdText(std::int64_t candidate_id) {
  return std::to_wstring(candidate_id);
}

HRESULT PutBstr(VARIANT* value, const std::wstring& text) noexcept {
  if (value == nullptr) {
    return E_POINTER;
  }
  VariantInit(value);
  if (text.size() > static_cast<std::size_t>(std::numeric_limits<ULONG>::max())) {
    return E_OUTOFMEMORY;
  }
  value->vt = VT_BSTR;
  value->bstrVal = ::SysAllocStringLen(
      text.c_str(), static_cast<ULONG>(text.size()));
  return value->bstrVal == nullptr ? E_OUTOFMEMORY : S_OK;
}

HRESULT PutInt(VARIANT* value, int integer) noexcept {
  if (value == nullptr) {
    return E_POINTER;
  }
  VariantInit(value);
  value->vt = VT_I4;
  value->lVal = integer;
  return S_OK;
}

HRESULT PutBool(VARIANT* value, bool boolean) noexcept {
  if (value == nullptr) {
    return E_POINTER;
  }
  VariantInit(value);
  value->vt = VT_BOOL;
  value->boolVal = boolean ? VARIANT_TRUE : VARIANT_FALSE;
  return S_OK;
}

}  // namespace

std::wstring MakeCandidateAutomationId(const BrokerCandidateDto& candidate,
                                        std::size_t ordinal) {
  std::wstring id = L"KanaAI.Tsf.Candidate.";
  id += CandidateIdText(candidate.candidate_id);
  if (candidate.origin == CandidateOrigin::kPrediction ||
      candidate.origin == CandidateOrigin::kSuggestion) {
    id += L".Prediction";
  } else {
    id += L".Conversion";
  }
  // Ordinal is presentation metadata, not a replacement for the opaque ID.
  // Including it keeps duplicate/invalid broker IDs distinguishable in a
  // debugger while preserving the ID prefix for clients.
  id += L".";
  id += std::to_wstring(ordinal + 1);
  return id;
}

std::wstring MakeCandidateAutomationName(const BrokerCandidateDto& candidate) {
  return BoundedText(candidate.text, kMaxNameLength);
}

CandidateAutomationMetadata MakeCandidateAutomationMetadata(
    const BrokerCandidateDto& candidate, std::size_t ordinal, bool selected) {
  CandidateAutomationMetadata metadata;
  metadata.automation_id = MakeCandidateAutomationId(candidate, ordinal);
  metadata.name = MakeCandidateAutomationName(candidate);
  metadata.help_text = L"Candidate supplied by the KanaAI broker";
  metadata.ordinal = ordinal;
  metadata.selected = selected;
  metadata.prediction = candidate.origin == CandidateOrigin::kPrediction ||
                        candidate.origin == CandidateOrigin::kSuggestion;
  return metadata;
}

CandidateWindowUiaProvider::CandidateWindowUiaProvider(HWND window)
    : window_(window) {}

CandidateWindowUiaProvider::~CandidateWindowUiaProvider() = default;

void CandidateWindowUiaProvider::SetPage(const BrokerCandidatePageDto& page) {
  std::lock_guard<std::mutex> lock(page_mutex_);
  page_ = page;
  page_.reading = BoundedText(std::move(page_.reading), kMaxNameLength);
  page_.preedit = BoundedText(std::move(page_.preedit), kMaxNameLength);
  if (page_.candidates.size() > kUiCandidateLimit) {
    page_.candidates.resize(kUiCandidateLimit);
  }
  for (BrokerCandidateDto& candidate : page_.candidates) {
    candidate.text = BoundedText(std::move(candidate.text), kMaxNameLength);
    if (candidate.reading.has_value()) {
      candidate.reading = BoundedText(std::move(*candidate.reading), kMaxNameLength);
    }
    candidate.description =
        BoundedText(std::move(candidate.description), kMaxHelpLength);
  }
  if (page_.focused_index.has_value() &&
      page_.focused_index.value() >= page_.candidates.size()) {
    page_.focused_index.reset();
  }
}

void CandidateWindowUiaProvider::SetFocusedIndex(
    std::optional<std::size_t> index) {
  std::lock_guard<std::mutex> lock(page_mutex_);
  if (!index.has_value() || index.value() < page_.candidates.size()) {
    page_.focused_index = index;
  }
}

void CandidateWindowUiaProvider::SetWindow(HWND window) { window_ = window; }

HRESULT STDMETHODCALLTYPE CandidateWindowUiaProvider::QueryInterface(
    REFIID riid, void** object) {
  if (object == nullptr) {
    return E_POINTER;
  }
  *object = nullptr;
  if (riid == IID_IUnknown || riid == IID_IRawElementProviderSimple) {
    *object = static_cast<IRawElementProviderSimple*>(this);
    AddRef();
    return S_OK;
  }
  return E_NOINTERFACE;
}

ULONG STDMETHODCALLTYPE CandidateWindowUiaProvider::AddRef() {
  return static_cast<ULONG>(::InterlockedIncrement(&reference_count_));
}

ULONG STDMETHODCALLTYPE CandidateWindowUiaProvider::Release() {
  const LONG count = ::InterlockedDecrement(&reference_count_);
  if (count == 0) {
    delete this;
  }
  return static_cast<ULONG>(std::max(0L, count));
}

HRESULT STDMETHODCALLTYPE CandidateWindowUiaProvider::get_ProviderOptions(
    ProviderOptions* options) {
  if (options == nullptr) {
    return E_POINTER;
  }
  *options = ProviderOptions_ServerSideProvider;
  return S_OK;
}

HRESULT STDMETHODCALLTYPE CandidateWindowUiaProvider::GetPatternProvider(
    PATTERNID, IUnknown** provider) {
  if (provider == nullptr) {
    return E_POINTER;
  }
  *provider = nullptr;
  // Selection, invoke, and expand/collapse are intentionally deferred.  The
  // TSF host can dispatch keyboard/pointer actions without claiming UIA
  // pattern support here.
  return E_NOTIMPL;
}

HRESULT STDMETHODCALLTYPE CandidateWindowUiaProvider::GetPropertyValue(
    PROPERTYID property_id, VARIANT* value) {
  if (value == nullptr) {
    return E_POINTER;
  }
  std::lock_guard<std::mutex> lock(page_mutex_);

  switch (property_id) {
    case UIA_NamePropertyId:
      return PutBstr(value, RootNameUnlocked());
    case UIA_AutomationIdPropertyId:
      return PutBstr(value, kCandidateWindowAutomationId);
    case UIA_ClassNamePropertyId:
      return PutBstr(value, kCandidateWindowAutomationId);
    case UIA_ControlTypePropertyId:
      return PutInt(value, UIA_WindowControlTypeId);
    case UIA_IsControlElementPropertyId:
    case UIA_IsContentElementPropertyId:
      return PutBool(value, true);
    case UIA_IsEnabledPropertyId:
      return PutBool(value, window_ != nullptr && ::IsWindowEnabled(window_) != FALSE);
    case UIA_IsKeyboardFocusablePropertyId:
      return PutBool(value, false);
    case UIA_HasKeyboardFocusPropertyId:
      return PutBool(value, HasKeyboardFocus());
    case UIA_IsOffscreenPropertyId:
      return PutBool(value, window_ == nullptr || !::IsWindowVisible(window_));
    case UIA_HelpTextPropertyId:
      return PutBstr(value,
                     L"Technical provider stub; candidate item accessibility "
                     L"patterns are not implemented yet.");
    default:
      VariantInit(value);
      value->vt = VT_UNKNOWN;
      value->punkVal = nullptr;
      return S_OK;
  }
}

HRESULT STDMETHODCALLTYPE
CandidateWindowUiaProvider::get_HostRawElementProvider(
    IRawElementProviderSimple** provider) {
  if (provider == nullptr) {
    return E_POINTER;
  }
  *provider = nullptr;
  return S_OK;
}

std::wstring CandidateWindowUiaProvider::RootNameUnlocked() const {
  if (page_.candidates.empty()) {
    return kCandidateWindowAutomationName;
  }
  const std::size_t index = page_.focused_index.value_or(0);
  if (index >= page_.candidates.size()) {
    return kCandidateWindowAutomationName;
  }
  const BrokerCandidateDto& candidate = page_.candidates[index];
  std::wstring name = candidate.text.empty() ? kCandidateWindowAutomationName
                                              : candidate.text;
  if (candidate.origin == CandidateOrigin::kPrediction ||
      candidate.origin == CandidateOrigin::kSuggestion) {
    name += L" (prediction)";
  }
  return BoundedText(std::move(name), kMaxNameLength);
}

bool CandidateWindowUiaProvider::HasKeyboardFocus() const {
  return window_ != nullptr && ::GetFocus() == window_;
}

LRESULT CandidateWindowHandleGetObject(HWND window,
                                         CandidateWindowUiaProvider* provider,
                                         WPARAM w_param, LPARAM l_param) {
  if (window == nullptr || provider == nullptr || provider->window() != window) {
    return 0;
  }
  // Do not filter wParam/lParam: the UIA contract requires forwarding the
  // values exactly as received from the client.
  return ::UiaReturnRawElementProvider(
      window, w_param, l_param,
      static_cast<IRawElementProviderSimple*>(provider));
}

void CandidateWindowReleaseUiaMap(HWND window) noexcept {
  if (window != nullptr) {
    ::UiaReturnRawElementProvider(window, 0, 0, nullptr);
  }
}

}  // namespace kanai::windows_tsf::ui
