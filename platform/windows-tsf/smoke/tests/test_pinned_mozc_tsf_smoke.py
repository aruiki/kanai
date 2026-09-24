#!/usr/bin/env python3
"""Portable static contract tests for the pinned-Mozc Windows TSF smoke slice."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

SMOKE_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[4]
CONTRACT = json.loads((SMOKE_ROOT / "contract.json").read_text(encoding="utf-8"))
PLAN = json.loads((SMOKE_ROOT / "host-test-plan.json").read_text(encoding="utf-8"))
HARNESS = (SMOKE_ROOT / "Invoke-TsfWindowsSmoke.ps1").read_text(encoding="utf-8")
COMMON = (SMOKE_ROOT / "Smoke.Common.ps1").read_text(encoding="utf-8")
WRAPPER = (REPO_ROOT / "scripts" / "test-tsf-windows.ps1").read_text(encoding="utf-8")


class PinnedMozcTsfSmokeContractTest(unittest.TestCase):
    def test_pinned_mozc_and_registration_contract_matches_repository_metadata(self) -> None:
        integration = json.loads(
            (REPO_ROOT / "platform/windows-tsf/tsf/metadata/tsf-integration.json").read_text(
                encoding="utf-8"
            )
        )
        registration = json.loads(
            (REPO_ROOT / "platform/windows-tsf/registration/registration.json").read_text(
                encoding="utf-8"
            )
        )
        manifest = json.loads(
            (REPO_ROOT / "platform/windows-tsf/registration/registry-manifest.json").read_text(
                encoding="utf-8"
            )
        )
        toolchain = json.loads(
            (REPO_ROOT / "platform/windows-tsf/build/toolchain.json").read_text(encoding="utf-8")
        )

        commit = CONTRACT["pinnedMozc"]["commit"]
        clsid = CONTRACT["registration"]["textServiceClsid"]
        profile = CONTRACT["registration"]["languageProfileGuid"]
        self.assertEqual(integration["host"]["commit"], commit)
        self.assertEqual(toolchain["mozc"]["gitlink"], commit)
        self.assertEqual(toolchain["target"], "x86_64-pc-windows-msvc")
        self.assertEqual(
            toolchain["dll"]["requiredExports"], CONTRACT["artifact"]["requiredExports"]
        )
        self.assertEqual(integration["registration"]["ossTextServiceClsid"], clsid)
        self.assertEqual(integration["registration"]["ossLanguageProfileGuid"], profile)
        self.assertEqual(
            registration["registrationIdentity"]["pinnedMozcReference"]["textServiceClsid"],
            clsid,
        )
        self.assertEqual(
            registration["registrationIdentity"]["pinnedMozcReference"]["languageProfileGuid"],
            profile,
        )
        self.assertEqual(manifest["pinnedMozcReference"]["textServiceClsid"], clsid)
        self.assertEqual(manifest["pinnedMozcReference"]["languageProfileGuid"], profile)
        self.assertNotEqual(registration["textService"]["clsid"], clsid)
        self.assertFalse(registration["registrationIdentity"]["identityApproved"])
        self.assertFalse(integration["registration"]["kanaiProductRegistrationReady"])

    def test_required_ids_include_artifact_registration_loader_and_real_host(self) -> None:
        expected = {
            "pinned-mozc-source",
            "mozc-tip-x64-pe",
            "mozc-tip-exports",
            "registration-metadata",
            "registration-live",
            "dll-load",
            "dll-dependencies",
            "tsf-host-runtime",
            "app-host",
            "preedit-candidate-commit",
        }
        self.assertEqual(set(CONTRACT["windowsRequiredTestIds"]), expected)
        self.assertEqual(
            set(CONTRACT["staticTestIds"]),
            {
                "pinned-mozc-source",
                "mozc-tip-x64-pe",
                "mozc-tip-exports",
                "registration-metadata",
                "dll-dependencies",
            },
        )
        self.assertEqual(CONTRACT["artifact"]["requiredExports"], ["DllGetClassObject", "DllCanUnloadNow"])
        self.assertEqual(CONTRACT["artifact"]["peMachine"], "0x8664")
        self.assertEqual(CONTRACT["artifact"]["peMagic"], "0x20b")

    def test_minimal_host_plan_cannot_claim_registration_from_file_presence(self) -> None:
        self.assertEqual(PLAN["profile"]["textServiceClsid"], CONTRACT["registration"]["textServiceClsid"])
        self.assertEqual(PLAN["profile"]["languageProfileGuid"], CONTRACT["registration"]["languageProfileGuid"])
        self.assertEqual(PLAN["profile"]["pinnedMozcCommit"], CONTRACT["pinnedMozc"]["commit"])
        self.assertIn("pinnedMozcCommit", PLAN["hostResultContract"]["requiredFields"])
        self.assertIn("tipDllPath", PLAN["hostResultContract"]["requiredFields"])
        observations = PLAN["hostResultContract"]["observations"]
        self.assertEqual(observations["preedit"], "かな")
        self.assertEqual(observations["primaryCandidate"], "変換")
        self.assertEqual(observations["committedText"], "変換")
        self.assertTrue(observations["tsfHostLoad"])
        self.assertTrue(observations["profileActivated"])
        self.assertTrue(observations["compositionClosed"])
        self.assertTrue(observations["focusRetained"])
        self.assertTrue(observations["cleanTeardown"])
        self.assertIn("preedit", PLAN["steps"][1]["id"])
        self.assertIn("candidate", PLAN["steps"][2]["id"])
        self.assertIn("commit", PLAN["steps"][3]["id"])

    def test_harness_uses_wsl_safe_vsdevcmd_pe_exports_dependencies_and_loader(self) -> None:
        combined = HARNESS + COMMON
        for marker in (
            "VsDevCmd.bat -arch=x64 -host_arch=x64",
            "Assert-TsfSmokeX64Pe",
            "Get-TsfSmokeExportNames",
            "Get-TsfSmokeImportNames",
            "/exports",
            "/dependents",
            "LoadLibraryExW",
            "GetProcAddress",
            "FreeLibrary",
            "Registry64",
            "msctf.dll",
            "Notepad.exe",
            "ConvertFrom-TsfSmokeWslPath",
            "Push-Location -LiteralPath 'C:\\Windows'",
        ):
            self.assertIn(marker, combined)
        self.assertIn("Test-LiveRegistration", HARNESS)
        self.assertIn("Test-ApplicationHost", HARNESS)
        self.assertIn("Invoke-HostTest", HARNESS)
        self.assertIn("host-test-plan.json", HARNESS)
        self.assertIn("ARTIFACT_PROVENANCE_UNAVAILABLE", HARNESS)
        self.assertIn("stageSourceFilesVerified", HARNESS)

    def test_missing_app_tsf_runtime_or_host_has_distinct_clean_failures(self) -> None:
        self.assertIn("APP_HOST_UNAVAILABLE", HARNESS)
        self.assertIn("TSF_HOST_UNAVAILABLE", HARNESS)
        self.assertIn("TSF_HOST_TEST_UNAVAILABLE", HARNESS)
        self.assertIn("MOZC_NOT_REGISTERED", HARNESS)
        self.assertIn("Write-SmokeResult -Status 'failed'", HARNESS)
        self.assertIn("No real TSF host test was supplied", HARNESS)
        self.assertIn("This is not a passing smoke result", HARNESS)

    def test_harness_and_wrapper_do_not_register_or_modify_windows(self) -> None:
        combined = HARNESS + COMMON + WRAPPER
        forbidden = (
            r"(?im)^\s*(?:&|Start-Process)\s+.*\breg(?:svr32|\.exe)?\b",
            r"(?im)^\s*reg(?:\.exe)?\s+add\b",
            r"(?i)\bNew-ItemProperty\b",
            r"(?i)\bSet-ItemProperty\b",
            r"(?i)\bSetValue\s*\(",
            r"(?i)\bDeleteKey(?:Value)?\s*\(",
            r"(?i)\bAddLanguageProfile\s*\(",
            r"(?i)\bInstallLayoutOrTip\s*\(",
        )
        for pattern in forbidden:
            self.assertIsNone(re.search(pattern, combined), pattern)

    def test_wrapper_forwards_paths_and_starts_from_windows_local_directory(self) -> None:
        for name in (
            "MozcStage",
            "TipDll",
            "RuntimeRoot",
            "ResultPath",
            "HostTestPath",
            "ApplicationPath",
            "ExpectedTipSha256",
            "PreflightOnly",
            "SkipVsDevCmd",
        ):
            self.assertIn(name, WRAPPER)
        self.assertIn("Invoke-TsfWindowsSmoke.ps1", WRAPPER)
        self.assertIn("wslpath", WRAPPER)
        self.assertIn("Push-Location -LiteralPath 'C:\\Windows'", WRAPPER)


if __name__ == "__main__":
    unittest.main()
