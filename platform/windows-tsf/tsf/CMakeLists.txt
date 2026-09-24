cmake_minimum_required(VERSION 3.24)

project(KanaAI_Windows_TSF_Integration LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(KANAI_TSF_BUILD_TESTS "Build portable contract and host-boundary tests" ON)

if(KANAI_TSF_BUILD_TESTS)
  include(CTest)

  add_library(kanai_ai_broker_contract STATIC
    host_overlay/engine/kanai_ai/broker_contract.cc
    host_overlay/engine/kanai_ai/rank_policy.cc
  )
  target_include_directories(kanai_ai_broker_contract PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/host_overlay"
  )
  target_compile_features(kanai_ai_broker_contract PUBLIC cxx_std_20)

  if(MSVC)
    target_compile_options(kanai_ai_broker_contract PRIVATE /W4 /WX /permissive-)
  else()
    target_compile_options(kanai_ai_broker_contract PRIVATE
      -Wall -Wextra -Wpedantic -Werror
    )
  endif()

  add_executable(broker_contract_test tests/broker_contract_test.cc)
  target_link_libraries(broker_contract_test PRIVATE kanai_ai_broker_contract)
  add_test(NAME broker_contract_test COMMAND broker_contract_test)

  add_executable(rank_policy_test tests/rank_policy_test.cc)
  target_link_libraries(rank_policy_test PRIVATE kanai_ai_broker_contract)
  add_test(NAME rank_policy_test COMMAND rank_policy_test)

  find_package(Python3 3.10 COMPONENTS Interpreter REQUIRED)
  add_test(
    NAME verify_pinned_mozc_host
    COMMAND "${Python3_EXECUTABLE}"
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/verify_pinned_host.py"
      --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/../../.."
      --expected-commit 13c98988247aa711d99db9e348ec2a597d14b5cd
  )
endif()
