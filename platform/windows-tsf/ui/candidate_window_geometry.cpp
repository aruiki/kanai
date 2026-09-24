#include "candidate_window_geometry.h"

#include <algorithm>
#include <limits>

namespace kanai::windows_tsf::ui {
namespace {

constexpr std::uint32_t kDefaultDpi = 96;
constexpr std::uint32_t kMinimumDpi = 48;
constexpr std::uint32_t kMaximumDpi = 768;

std::int64_t ClampWorkCoordinate(std::int64_t value, std::int64_t low,
                                 std::int64_t high) noexcept {
  if (high < low) {
    return low;
  }
  return std::clamp(value, low, high);
}

}  // namespace

int ScaleForDpi(int logical_pixels, std::uint32_t dpi) noexcept {
  const std::uint32_t effective_dpi =
      std::clamp(dpi == 0 ? kDefaultDpi : dpi, kMinimumDpi, kMaximumDpi);
  const std::int64_t scaled =
      (static_cast<std::int64_t>(logical_pixels) * effective_dpi + kDefaultDpi / 2) /
      kDefaultDpi;
  if (scaled > std::numeric_limits<int>::max()) {
    return std::numeric_limits<int>::max();
  }
  if (scaled < std::numeric_limits<int>::min()) {
    return std::numeric_limits<int>::min();
  }
  return static_cast<int>(scaled);
}

CandidateWindowPlacement PlaceCandidateWindow(const PixelRect& caret,
                                               const PixelRect& work_area,
                                               int window_width,
                                               int window_height,
                                               int gap) noexcept {
  const std::int64_t width = std::max(0, window_width);
  const std::int64_t height = std::max(0, window_height);
  const std::int64_t separation = std::max(0, gap);

  // A malformed work area should not make the popup disappear off-screen.
  // Use a synthetic zero-sized work area at the caret in that case; the caller
  // will still get a deterministic position and can report the invalid input.
  const bool has_work_area = work_area.right > work_area.left &&
                              work_area.bottom > work_area.top;
  const std::int64_t work_left = has_work_area ? work_area.left : caret.left;
  const std::int64_t work_top = has_work_area ? work_area.top : caret.top;
  const std::int64_t work_right =
      has_work_area ? work_area.right : caret.left + static_cast<std::int64_t>(caret.width());
  const std::int64_t work_bottom =
      has_work_area ? work_area.bottom : caret.top + static_cast<std::int64_t>(caret.height());

  std::int64_t x = caret.left;
  std::int64_t y = static_cast<std::int64_t>(caret.bottom) + separation;
  bool below_caret = true;

  if (y + height > work_bottom) {
    y = static_cast<std::int64_t>(caret.top) - separation - height;
    below_caret = false;
    if (y < work_top) {
      y = static_cast<std::int64_t>(caret.bottom) + separation;
      below_caret = true;
    }
  }

  if (x + width > work_right) {
    x = work_right - width;
  }
  x = ClampWorkCoordinate(x, work_left, work_right - width);
  y = ClampWorkCoordinate(y, work_top, work_bottom - height);

  const std::int64_t max_int = std::numeric_limits<int>::max();
  const std::int64_t min_int = std::numeric_limits<int>::min();
  x = std::clamp(x, min_int, max_int);
  y = std::clamp(y, min_int, max_int);
  return {static_cast<int>(x), static_cast<int>(y), below_caret};
}

}  // namespace kanai::windows_tsf::ui
