# Windows beta and TSF roadmap

## Phase 1: Workbench/CLI beta

The current Windows beta is an unsigned, x64, per-user portable package. It
runs the KanaAI Rust API, the pinned Mozc bridge, and the local browser
Workbench through PowerShell scripts. It is a real conversion/AI testing path,
but it is not a registered TSF keyboard.

Build and install instructions are in
[`docs/WINDOWS_BETA.md`](../../docs/WINDOWS_BETA.md). The package is deliberately
labeled `workbench-cli-phase-1`; file presence is not treated as runtime
verification.

## Phase 2: TSF adapter

Target: a TSF Text Service/Input Processor DLL pair (x86 and x64) with a minimal COM shell around the KanaAI Rust broker.

TSF-specific work includes text-service registration, COM lifecycle, preedit/candidate presentation, UI Automation, secure fields, app-container behavior, and x86/x64 registration. None of that work should duplicate Japanese conversion or local model policy.

Unsigned development builds are distributed as portable archives first. A conventional `setup.exe` may be added later, but its filename does not bypass Microsoft Defender SmartScreen; signing and publisher reputation remain separate concerns.
