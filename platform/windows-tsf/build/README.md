# Pinned Windows x64 TSF build and validation harness

This directory is a build/validation boundary for the Windows TSF source
slices. It is intentionally **not** a registration, installer, signing, or
release script. The harness never calls `regsvr32`, edits the TSF registry, or
turns a console/workbench seam into a TIP.

## What is pinned

`toolchain.json` is the machine-readable policy consumed by
`scripts/build-tsf-windows.ps1`:

- Windows x64 / `x86_64-pc-windows-msvc` / PE32+ (`0x8664`, `0x20b`);
- Visual Studio 2022 generator, MSVC v143 Hostx64/x64 compiler;
- Windows SDK `10.0.26100.0`, including `msctf.h`, `TextServ.h`, and the
  available x64 `MsCtfMonitor.lib`/TSF runtime prerequisites;
- CMake `3.31.6` (the version bundled with the pinned developer image);
- Bazel `9.0.2`, selected by the pinned `third_party/mozc/src/.bazeliskrc`;
- the exact `third_party/mozc` gitlink
  `13c98988247aa711d99db9e348ec2a597d14b5cd`; and
- the native COM DLL exports `DllGetClassObject` and `DllCanUnloadNow`.

`DllRegisterServer`/`DllUnregisterServer` are recorded as optional registration
exports in the policy, but are not required exports of a TSF TIP. TSF
registration is owned by the separate registration slice and is exercised by
the Windows host test; this harness does not perform it.

## WSL2 interop

The repository is often edited on a WSL2 UNC path. Invoke the Windows script
with a translated script path; do not expect Linux `PATH` to contain `cl.exe`:

```bash
WIN_SCRIPT="$(wslpath -w scripts/build-tsf-windows.ps1)"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$WIN_SCRIPT" -PlanOnly
```

For a real Windows build, open the x64 developer environment (or let the
harness initialize `VsDevCmd.bat -arch=x64 -host_arch=x64`):

```bash
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$WIN_SCRIPT" -BuildSystem CMake -SourceRoot C:/src/kanai-tsf-source
```

Bazel cannot use a UNC workspace. The harness uses the repository's pinned
`prepare-pinned-mozc.ps1` to make a disposable Windows-local archive, copies
the KanaAI host overlay, applies the reviewed patch, and never edits
`third_party/mozc` in place. The prepared stage is reused when its commit
marker and patch are intact. It also supplies WSL-safe Git settings for
Windows Git's `core.filemode`/line-ending view. If the local Windows host
cannot create Bazel's symlink forest, the harness does not require a broad
Developer Mode/security change: it retries the same pinned x64 target with
`--nowindows_enable_symlinks --nobuild_runfile_links --nobuild_runfile_manifests`
(and `--enable_runfiles=false`, in `--batch` mode).
If that fallback also fails, the exact Bazel error is surfaced; use a Windows
build environment with symlink support for a later pass. The Bazel action and
repository environments also receive an explicit Windows `PATH` containing
the pinned Python directory, Bazelisk directory, and the initialized MSVC/SDK
path; this avoids a generated Mozc action failing to launch `python.exe`.

The default cache root is `%LOCALAPPDATA%\KanaAI\tsf-build-cache` for a WSL
checkout (`windows-beta\tsf-build-cache` for a native checkout). It contains a
stable CMake build directory, Bazel `output_user_root`, disk cache, and
repository cache. These are reused by default; use `-ResetBuildCache` only when
an intentional clean rebuild is wanted. `-Force` replaces only the final
artifact directory and does not clear build caches.

Useful diagnostic modes are:

```powershell
# Reuse the default CMake/Bazel caches; reset only for a deliberate clean pass.
.\scripts\build-tsf-windows.ps1 -BuildSystem Bazel -MozcValidationOnly `
  -BuildCacheDirectory C:\Users\me\AppData\Local\KanaAI\tsf-build-cache

# If a fully clean first pass is required:
.\scripts\build-tsf-windows.ps1 -BuildSystem Bazel -MozcValidationOnly `
  -ResetBuildCache

# Explicitly initialize the known developer prompt (otherwise vswhere locates it).
.\scripts\build-tsf-windows.ps1 `
  -VsDevCmdPath 'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat'

# Inspect policy only; no Windows test or artifact is claimed.
.\scripts\build-tsf-windows.ps1 -PlanOnly

# Build/PE/export-check the pinned upstream Mozc TIP as a diagnostic only.
# This never stages a KanaAI artifact and never makes a beta claim.
.\scripts\build-tsf-windows.ps1 -BuildSystem Bazel -MozcValidationOnly

# Normal KanaAI path: source slices must contain a real TSF TIP implementation.
.\scripts\build-tsf-windows.ps1 -BuildSystem CMake `
  -SourceRoot C:\src\kanai-tsf-tip `
  -RunWindowsSmokeTests -TestHostPath C:\qa\tsf-host-test.ps1
```

`-MozcValidationOnly` is useful when the full KanaAI TIP has not been added yet.
It can demonstrate that the pinned upstream host is buildable, but its result
is always `mozc-tip-validation-only`, with `NativeBeta = $false`.

## First-pass target policy

The accelerated first pass is intentionally narrow: one Windows x64 TIP DLL
target, with no x86/ARM64, UIA, server, or installer fan-out. The pinned default
Bazel diagnostic target is `//win32/tip:mozc_tip64`; a KanaAI target must be
passed explicitly and is still subject to the x64-only target guard. This keeps
the first cache warm and produces one artifact that can be PE/export checked
before broader work is attempted.

## Build and validation flow

1. Verify the repository gitlink, exact checkout, `.bazeliskrc`, Visual Studio,
   x64 compiler, CMake, SDK headers/libraries, and the Windows TSF runtime.
2. Require source markers for a real TSF implementation (`msctf.h`,
   `ITfThreadMgr`, `ITfTextInputProcessor`, `DllGetClassObject`, and
   `DllCanUnloadNow`). The existing adapter/UI/console slices fail this gate
   instead of being mislabeled as a DLL.
3. For Bazel, prepare or reuse a disposable copy of the pinned Mozc source and
   invoke exactly one explicit x64 target with stable output/disk/repository
   caches. Bazel disables the upstream platform-specific Clang selection for
   this pass and pins `@local_config_cc//:cc-toolchain-x64_windows` plus
   `compiler_msvc_like`; the action/repository PATH is explicit and the first
   retry is batched/no-runfiles when the local symlink probe is unavailable.
   For CMake, configure the supplied source list with the pinned Visual Studio
   generator
   into a stable cache directory and build one `SHARED` TIP target. Do not fan
   out to x86/UIA/installer targets in this pass.
4. Parse the resulting PE rather than trusting its filename. Reject non-x64,
   PE32, non-DLL, missing-export, and `dumpbin /exports` failures.
5. Run the smoke-test contract in `smoke-test-plan.json` when
   `-RunWindowsSmokeTests` is requested. A real 64-bit TSF host test is
   required for lifecycle, candidate UI, secure-field, app-container, and
   focus-teardown checks. A load/export-only test cannot pass that gate.
6. Stage the DLL, optional import library/symbols, toolchain metadata, source
   revision, exact file hashes, and the smoke result in
   `artifact-manifest.json`/`SHA256SUMS`.

Without `-RunWindowsSmokeTests`, staging is allowed for diagnostics but is
labeled `unverified-tsf-tip` and `not-a-native-beta`. A native-beta label is
rejected unless every required Windows test is `passed` and
`-PromoteNativeBeta` is explicit. File presence, PE headers, exports, and
packaging never imply runtime verification.

## Static checks

The source-only checks run under Windows PowerShell 5.1 or PowerShell 7 and do
not require a Windows build:

```powershell
.\platform\windows-tsf\build\tests\Test-TsfWindowsBuildHarness.ps1
```

They parse the harness, validate the JSON/CMake policy, check that the claim
gate and WSL/pinned-Mozc paths are present, and exercise the pure PE header
parser with synthetic x64/x86 images. They do not register a TIP and do not
substitute for the Windows smoke-test plan.
