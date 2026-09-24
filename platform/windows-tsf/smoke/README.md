# Pinned-Mozc Windows x64 TSF smoke slice

This directory is a Windows-side smoke boundary for the smallest useful Phase 1
vertical slice: the pinned upstream `//win32/tip:mozc_tip64` TIP must load in an
x64 process, match the pinned registration identity, resolve its DLL
dependencies, and complete one real preedit → candidate → commit interaction.

The harness does **not** register, enable, unregister, or relabel Mozc as
KanaAI. The upstream OSS CLSIDs remain distinct from the unapproved KanaAI
identity. A result is not a public-beta or complete Phase 1 release result.

## WSL interop

Translate the PowerShell script and Windows-local Bazel stage paths before
launching Windows PowerShell. The script accepts Linux absolute paths as an
additional convenience and translates them with `wsl.exe wslpath -w`. For an
installed/copied TIP, set `MOZC_TIP_SHA256` to the reviewed digest first.

```bash
WIN_SCRIPT="$(wslpath -w scripts/test-tsf-windows.ps1)"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$WIN_SCRIPT" \
  -MozcStage 'C:/build/kanai-tsf-mozc' \
  -RuntimeRoot 'C:/Program Files/Mozc' \
  -TipDll 'C:/Program Files/Mozc/mozc_tip64.dll' \
  -ExpectedTipSha256 "$MOZC_TIP_SHA256" \
  -HostTestPath 'C:/qa/mozc-tsf-host-test.ps1' \
  -ResultPath "$(wslpath -w /tmp/opencode/kanai-tsf-smoke.json)"
```

`dumpbin.exe` is initialized automatically with
`VsDevCmd.bat -arch=x64 -host_arch=x64`. If Visual Studio/vswhere is absent,
the run fails as `MSVC_DEVELOPER_ENVIRONMENT_UNAVAILABLE` rather than silently substituting
a PE parser-only claim. A WSL UNC current directory is not used for `cmd`,
VsDevCmd, dumpbin, or the isolated host process.

Use `-PreflightOnly` to inspect the pin, x64 PE, exports, dependencies, and
static registration metadata. Its result is always `not-run`, never `passed`,
because it does not load the TIP in a registered TSF application.

## Real host receipt

`-HostTestPath` must be a `.ps1` or `.exe` test driver. PowerShell drivers are
started in an isolated Windows PowerShell process and receive:

- `-ResultPath`
- `-TestPlanPath`
- `-ApplicationPath`
- `-TipDllPath`
- `-TextServiceClsid`
- `-LanguageProfileGuid`
- `-LanguageId`
- `-MozcCommit`
- `-TipDllSha256`

The driver must follow `host-test-plan.json`, interact with a visible editable
control in the supplied x64 application, and write the exact receipt contract.
The runner checks the tested process/profile/artifact binding and the literal
observations `かな` → `変換` → committed `変換`. A missing app, `msctf.dll`,
registration, host driver, or receipt is a clean failure with remediation; it
is never converted into a synthetic pass.

The default app is `%WINDIR%\\System32\\Notepad.exe`. The tested live COM
`InProcServer32` bytes must have the same SHA-256 as the supplied
`mozc_tip64.dll`. An explicit installed/copied TIP outside the pinned
Bazel/source roots must also provide its reviewed `-ExpectedTipSha256`;
otherwise the harness reports `ARTIFACT_PROVENANCE_UNAVAILABLE` rather than
treating a filename as a pin.

## Static checks

The portable Python check needs only the standard library:

```bash
python3 platform/windows-tsf/smoke/tests/test_pinned_mozc_tsf_smoke.py
```

Windows PowerShell also parses every script and exercises the pure PE header
parser with synthetic x64/x86 images:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File platform/windows-tsf/smoke/tests/Test-PinnedMozcTsfSmoke.ps1
```

Neither static check loads a TIP, edits registration, or substitutes for the
real host receipt.
