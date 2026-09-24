#!/usr/bin/env python3
"""Portable static checks for the Windows TSF candidate-window source slice.

These tests intentionally inspect source/build metadata only. They do not
create an HWND, load UIAutomationCore, or make an accessibility claim.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path


UI_ROOT = Path(__file__).resolve().parents[1]


class CandidateWindowSourceTests(unittest.TestCase):
    def read(self, relative: str) -> str:
        path = UI_ROOT / relative
        self.assertTrue(path.is_file(), f"missing {path}")
        return path.read_text(encoding="utf-8")

    def test_required_source_and_build_files_exist(self) -> None:
        required = {
            "README.md",
            "broker_dto.h",
            "broker-contract.json",
            "candidate_window.h",
            "candidate_window.cpp",
            "candidate_window_geometry.h",
            "candidate_window_geometry.cpp",
            "candidate_window_uia.h",
            "candidate_window_uia.cpp",
            "BUILD.bazel",
            "MODULE.bazel",
            "CMakeLists.txt",
            "tests/Test-CandidateWindowSource.ps1",
            "tests/test_candidate_window_source.py",
        }
        for relative in required:
            self.assertTrue((UI_ROOT / relative).is_file(), relative)

    def test_native_window_dpi_input_and_focus_hooks_are_present(self) -> None:
        window = self.read("candidate_window.cpp")
        for marker in (
            "CreateWindowExW",
            "WS_EX_TOOLWINDOW",
            "WS_EX_NOACTIVATE",
            "SW_SHOWNOACTIVATE",
            "GetDpiForWindow",
            "GetDpiForSystem",
            "AdjustWindowRectExForDpi",
            "WM_DPICHANGED",
            "MonitorFromPoint",
            "GetMonitorInfoW",
            "SetWinEventHook",
            "EVENT_SYSTEM_FOREGROUND",
            "EVENT_OBJECT_FOCUS",
            "UnhookWinEvent",
            "WM_KILLFOCUS",
        ):
            self.assertIn(marker, window)

    def test_keyboard_and_gdi_rendering_are_present(self) -> None:
        window = self.read("candidate_window.cpp")
        for marker in (
            "WM_KEYDOWN",
            "VK_UP",
            "VK_DOWN",
            "VK_PRIOR",
            "VK_NEXT",
            "VK_HOME",
            "VK_END",
            "VK_RETURN",
            "VK_ESCAPE",
            "WM_PAINT",
            "CreateCompatibleDC",
            "DrawTextW",
            "DT_END_ELLIPSIS",
            "COLOR_HIGHLIGHT",
        ):
            self.assertIn(marker, window)

    def test_uia_is_explicitly_a_stub(self) -> None:
        uia = self.read("candidate_window_uia.h") + self.read("candidate_window_uia.cpp")
        for marker in (
            "WM_GETOBJECT",
            "UiaReturnRawElementProvider",
            "IRawElementProviderSimple",
            "UIA_AutomationIdPropertyId",
            "E_NOTIMPL",
            "not a claim",
        ):
            self.assertIn(marker, uia)
        self.assertIn("candidate item accessibility", uia)

    def test_dto_contract_documents_generation_and_opaque_ids(self) -> None:
        dto = self.read("broker_dto.h")
        for marker in (
            "kBrokerDtoVersion",
            "generation",
            "request_id",
            "candidate_id",
            "CandidateCommandDto",
            "UTF-16",
            "opaque",
            "never be persisted",
            "must not infer",
        ):
            self.assertIn(marker, dto)
        contract = json.loads(self.read("broker-contract.json"))
        self.assertEqual(contract["schemaVersion"], 1)
        self.assertEqual(contract["status"], "technical-slice")
        self.assertEqual(contract["scope"], "candidate-window-only")
        self.assertTrue(contract["generation"]["required"])
        self.assertIn("opaque", contract["candidateId"]["rule"])
        self.assertIn(
            "complete UI Automation child tree and selection events",
            contract["notImplementedHere"],
        )

    def test_build_metadata_covers_native_dependencies(self) -> None:
        build = self.read("BUILD.bazel") + "\n" + self.read("CMakeLists.txt")
        for source in (
            "candidate_window.cpp",
            "candidate_window_geometry.cpp",
            "candidate_window_uia.cpp",
        ):
            self.assertIn(source, build)
        for library in (
            "user32",
            "gdi32",
            "ole32",
            "oleaut32",
            "uuid",
            "uiautomationcore",
        ):
            self.assertIn(library, build)
        cmake = self.read("CMakeLists.txt")
        self.assertIn("if(NOT WIN32)", cmake)
        self.assertIn("add_library", cmake)
        self.assertNotIn("add_executable", cmake)
        self.assertNotIn("install(", cmake)
        self.assertIn("technical slice", self.read("README.md").lower())
        self.assertIn("not a completed", self.read("README.md").lower())

    def test_source_does_not_add_transport_or_worker_policy(self) -> None:
        implementation = "\n".join(
            self.read(relative)
            for relative in (
                "candidate_window.h",
                "candidate_window.cpp",
                "candidate_window_geometry.h",
                "candidate_window_geometry.cpp",
                "broker_dto.h",
                "candidate_window_uia.h",
                "candidate_window_uia.cpp",
            )
        )
        for forbidden in (
            "WinHttpOpen",
            "InternetOpen",
            "URLDownloadToFile",
            "CreateThread",
            "std::thread",
            "CoInitialize",
        ):
            self.assertNotIn(forbidden, implementation)


if __name__ == "__main__":
    unittest.main()
