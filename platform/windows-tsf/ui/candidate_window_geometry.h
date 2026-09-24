// Small, platform-neutral geometry helpers used by the Win32 candidate popup.
// Keeping placement arithmetic independent of HWNDs makes the edge cases
// reviewable and testable without creating a window.
#ifndef KANAI_PLATFORM_WINDOWS_TSF_UI_CANDIDATE_WINDOW_GEOMETRY_H_
#define KANAI_PLATFORM_WINDOWS_TSF_UI_CANDIDATE_WINDOW_GEOMETRY_H_

#include <cstdint>

namespace kanai::windows_tsf::ui {

struct PixelRect {
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;

  [[nodiscard]] constexpr int width() const noexcept {
    return right > left ? right - left : 0;
  }

  [[nodiscard]] constexpr int height() const noexcept {
    return bottom > top ? bottom - top : 0;
  }
};

struct CandidateWindowPlacement {
  int x = 0;
  int y = 0;
  bool below_caret = true;
};

// DPI values are physical pixels per inch.  A value of zero means that the
// caller has not obtained a monitor DPI yet and uses the Windows default.
[[nodiscard]] int ScaleForDpi(int logical_pixels, std::uint32_t dpi) noexcept;

// Places a physical-pixel-sized popup near the caret.  It prefers below and
// to the right, flips above when the work area is too short, and finally
// clamps both axes to the monitor work area.
[[nodiscard]] CandidateWindowPlacement PlaceCandidateWindow(
    const PixelRect& caret, const PixelRect& work_area, int window_width,
    int window_height, int gap) noexcept;

}  // namespace kanai::windows_tsf::ui

#endif  // KANAI_PLATFORM_WINDOWS_TSF_UI_CANDIDATE_WINDOW_GEOMETRY_H_
