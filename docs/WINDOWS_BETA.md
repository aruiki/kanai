# Windows beta guide

## Status

KanaAI's first Windows beta is a **portable Workbench/CLI beta**. It packages
the Rust local API, the pinned Mozc bridge, and the local web workbench behind
PowerShell install/start/stop scripts.

It is **not yet a registered Windows TSF keyboard**. The beta does not install
an IME into every Windows application, replace the Windows keyboard, or claim
system-wide preedit/candidate integration. Those capabilities are tracked as
the next native milestone in [`PLATFORM_ROADMAP.md`](PLATFORM_ROADMAP.md).

The beta is intended for technical users who want to inspect and test the
Japanese conversion runtime on Windows while the native shell is developed.

## Supported baseline

- Windows 10 21H2 or newer / Windows 11
- x64 PowerShell 5.1 or PowerShell 7
- Git for Windows with submodules
- Rust stable toolchain
- Node.js 22.22.2 or newer
- Visual Studio 2022 Build Tools with the Desktop development with C++ workload
- Bazelisk and the native prerequisites of the pinned Mozc revision

No administrator account is required for the portable per-user installation.
The beta stores its application under `%LOCALAPPDATA%\\Programs\\KanaAI-Beta` and
runtime data under `%LOCALAPPDATA%\\KanaAI` by default.

## Build from source

Run from a clean checkout in PowerShell:

```powershell
git clone --recurse-submodules https://github.com/aruiki/kanai.git
Set-Location kanai
./scripts/build-windows-beta.ps1 -Version 0.1.0-beta.1 -Package
```

The build script fails closed when the Rust, Node, submodule, or Mozc bridge
inputs are missing. It stages only the tested API/CLI/bridge payload, web
bundle, licenses, and Japanese beta guide. It does not include `.env` files,
API keys, local dictionaries, or learning history.

The generated ZIP is unsigned. Verify its SHA-256 before running it. An
unsigned executable may trigger Defender SmartScreen, Smart App Control, or
enterprise policy. The filename `setup.exe` or a ZIP extension does not bypass
those protections. Do not disable security controls to force installation.

## Install and run the portable beta

After extracting the ZIP:

```powershell
Set-Location .\\kanai-0.1.0-beta.1-windows-x64-portable
./Install-KanaAI.ps1
./Start-KanaAI.ps1
```

`Start-KanaAI.ps1` starts the loopback Rust service and opens the local
workbench in the default browser. The service binds to `127.0.0.1` only. To
stop it, run:

```powershell
./Stop-KanaAI.ps1
```

To remove the per-user application while retaining learned local data:

```powershell
./Uninstall-KanaAI.ps1
```

Use `-RemoveUserData` only when the user explicitly wants KanaAI's local Mozc
profile and installation data deleted. Browser `localStorage` learning is
owned by the browser profile and must be cleared separately from the Workbench
site data.

## Optional local AI

The portable beta works without a model. To enable the optional local
assistant/reranker, start a separate OpenAI-compatible server bound to loopback
and set `KANA_AI_MODEL` in the package's `config/kanai.env.example` copy.
The beta never downloads model weights automatically. Review the model license
and digest before copying a GGUF file into a release payload.

Remote AI endpoints are disabled by default. They require an explicit
`KANA_AI_ALLOW_REMOTE=1` setting and an HTTPS endpoint; the UI displays a
warning when a non-loopback target is configured.

## Beta limitations

The following are intentionally outside this package:

- TSF TIP registration and x86/x64 side-by-side DLLs;
- system-wide candidate windows, preedit selection, and app-container tests;
- password/secure-field enforcement and Protect Mode;
- installer signing, SmartScreen reputation, and automatic updates;
- encrypted canonical profile storage and sync;
- bundled local model weights.

These limitations are release blockers for a general-purpose Windows IME, but
not for the explicitly labeled portable developer beta.
