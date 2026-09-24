cmake_minimum_required(VERSION 3.30)

# This project only supplies the native build shell.  It does not contain a
# TSF implementation and it never registers a TIP.  The PowerShell entry point
# supplies an explicit list of reviewed source slices; refusing an implicit
# glob keeps a console/workbench seam from being mislabeled as an IME.
project(KanaAIWindowsTsfTip VERSION 0.1.0 LANGUAGES CXX)

set(KANAI_TSF_SOURCE_ROOT "" CACHE PATH "Root containing the reviewed TSF TIP source slices")
set(KANAI_TSF_SOURCE_FILES "" CACHE STRING "Semicolon-separated absolute TSF source/definition/resource files")
set(KANAI_TSF_DLL_NAME "KanaAI.TsfTip" CACHE STRING "TIP DLL basename without .dll")
set(KANAI_TSF_TARGET_NAME "KanaAI_TsfTip" CACHE STRING "CMake target name")
set(KANAI_TSF_DEF_FILE "" CACHE FILEPATH "Optional module-definition file for COM exports")
set(KANAI_TSF_REFUSE_REGISTRATION "ON" CACHE BOOL "Build-only guard; registration is never performed")

if(NOT WIN32)
  message(FATAL_ERROR "KanaAI TSF TIP sources must be built on Windows with MSVC; this is not a cross-compilation harness.")
endif()
if(NOT MSVC)
  message(FATAL_ERROR "The KanaAI TSF TIP target requires the MSVC compiler, not Clang, MinGW, or another generator.")
endif()
if(NOT KANAI_TSF_SOURCE_ROOT OR NOT EXISTS "${KANAI_TSF_SOURCE_ROOT}")
  message(FATAL_ERROR "KANAI_TSF_SOURCE_ROOT is missing. Provide the reviewed TSF TIP source slices; the existing Windows shell seam is not a TSF TIP.")
endif()
if(NOT KANAI_TSF_SOURCE_FILES)
  message(FATAL_ERROR "KANAI_TSF_SOURCE_FILES is empty. The harness requires an explicit source slice list and will not compile a guessed executable.")
endif()
if(NOT KANAI_TSF_DLL_NAME MATCHES "^[A-Za-z0-9_.-]+$")
  message(FATAL_ERROR "KANAI_TSF_DLL_NAME contains an unsafe character: ${KANAI_TSF_DLL_NAME}")
endif()
if(NOT KANAI_TSF_TARGET_NAME MATCHES "^[A-Za-z_][A-Za-z0-9_.-]*$")
  message(FATAL_ERROR "KANAI_TSF_TARGET_NAME is not a safe CMake target name: ${KANAI_TSF_TARGET_NAME}")
endif()

set(_kanai_tsf_sources)
foreach(_kanai_tsf_source IN LISTS KANAI_TSF_SOURCE_FILES)
  if(NOT EXISTS "${_kanai_tsf_source}")
    message(FATAL_ERROR "TSF source file does not exist: ${_kanai_tsf_source}")
  endif()
  list(APPEND _kanai_tsf_sources "${_kanai_tsf_source}")
endforeach()
list(REMOVE_DUPLICATES _kanai_tsf_sources)
if(NOT _kanai_tsf_sources)
  message(FATAL_ERROR "No TSF source files were supplied to CMake.")
endif()

set(_kanai_tsf_text "")
foreach(_kanai_tsf_source IN LISTS _kanai_tsf_sources)
  file(READ "${_kanai_tsf_source}" _kanai_tsf_file_text)
  string(APPEND _kanai_tsf_text "${_kanai_tsf_file_text}\n")
endforeach()
foreach(_kanai_tsf_marker IN ITEMS
    "msctf.h"
    "ITfThreadMgr"
    "ITfTextInputProcessor"
    "DllGetClassObject"
    "DllCanUnloadNow")
  string(FIND "${_kanai_tsf_text}" "${_kanai_tsf_marker}" _kanai_tsf_marker_position)
  if(_kanai_tsf_marker_position EQUAL -1)
    message(FATAL_ERROR "Source slices are missing TSF marker '${_kanai_tsf_marker}'. Refusing to build a non-TSF executable.")
  endif()
endforeach()

add_library(${KANAI_TSF_TARGET_NAME} SHARED ${_kanai_tsf_sources})
set_target_properties(${KANAI_TSF_TARGET_NAME} PROPERTIES
  OUTPUT_NAME "${KANAI_TSF_DLL_NAME}"
  PREFIX ""
  SUFFIX ".dll"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  PDB_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/pdb"
)
target_compile_features(${KANAI_TSF_TARGET_NAME} PRIVATE cxx_std_20)
target_compile_definitions(${KANAI_TSF_TARGET_NAME} PRIVATE
  WIN32_LEAN_AND_MEAN
  NOMINMAX
  UNICODE
  _UNICODE
  _WIN32_WINNT=0x0A00
)
target_compile_options(${KANAI_TSF_TARGET_NAME} PRIVATE
  /W4
  /WX
  /permissive-
  /Zc:__cplusplus
  /EHsc
  /utf-8
)
target_include_directories(${KANAI_TSF_TARGET_NAME} PRIVATE "${KANAI_TSF_SOURCE_ROOT}")
target_link_libraries(${KANAI_TSF_TARGET_NAME} PRIVATE
  MsCtfMonitor
  ole32
  oleaut32
  uuid
  user32
  gdi32
  advapi32
  shlwapi
)

if(KANAI_TSF_DEF_FILE)
  if(NOT EXISTS "${KANAI_TSF_DEF_FILE}")
    message(FATAL_ERROR "KANAI_TSF_DEF_FILE does not exist: ${KANAI_TSF_DEF_FILE}")
  endif()
  target_sources(${KANAI_TSF_TARGET_NAME} PRIVATE "${KANAI_TSF_DEF_FILE}")
else()
  string(FIND "${_kanai_tsf_text}" "__declspec(dllexport)" _kanai_tsf_dllexport_position)
  if(_kanai_tsf_dllexport_position EQUAL -1)
    message(FATAL_ERROR "No module-definition file or __declspec(dllexport) declaration was found. COM exports cannot be validated by inference.")
  endif()
endif()

if(NOT KANAI_TSF_REFUSE_REGISTRATION)
  message(FATAL_ERROR "KANAI_TSF_REFUSE_REGISTRATION must remain ON; this harness is build/validation-only.")
endif()

message(STATUS "KanaAI TSF TIP: Windows x64 MSVC target=${KANAI_TSF_TARGET_NAME} output=${KANAI_TSF_DLL_NAME}.dll (registration is not performed)")
