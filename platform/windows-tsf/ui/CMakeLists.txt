cmake_minimum_required(VERSION 3.25)

project(KanaAIWindowsTsfCandidateUi LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "KanaAI Windows TSF candidate UI is a Windows-only source slice")
endif()

add_library(kanai_windows_candidate_window STATIC
  broker_dto.h
  candidate_window.h
  candidate_window_geometry.h
  candidate_window_geometry.cpp
  candidate_window_uia.h
  candidate_window_uia.cpp
  candidate_window.cpp
)

target_compile_features(kanai_windows_candidate_window PRIVATE cxx_std_20)
target_include_directories(kanai_windows_candidate_window PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(kanai_windows_candidate_window PRIVATE
  WIN32_LEAN_AND_MEAN
  NOMINMAX
  UNICODE
  _UNICODE
  _WIN32_WINNT=0x0A00
  WINVER=0x0A00
)

if(MSVC)
  target_compile_options(kanai_windows_candidate_window PRIVATE
    /W4
    /WX
    /permissive-
    /Zc:__cplusplus
    /EHsc
    /utf-8
  )
else()
  target_compile_options(kanai_windows_candidate_window PRIVATE -Wall -Wextra -Wpedantic)
endif()

# The UI uses only Win32/GDI and the UIA provider hand-off.  It does not link a
# broker transport, Rust library, or network library.
target_link_libraries(kanai_windows_candidate_window PRIVATE
  user32
  gdi32
  ole32
  oleaut32
  uuid
  uiautomationcore
)

# This target is intentionally a static source slice.  Registration, COM TSF
# lifecycle, and x86/x64 packaging remain the responsibility of the TIP.
