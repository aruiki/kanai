# Windows TSF adapter

Target: a TSF Text Service/Input Processor DLL pair (x86 and x64) with a minimal COM shell around the KanaAI Rust broker.

TSF-specific work includes text-service registration, COM lifecycle, preedit/candidate presentation, UI Automation, secure fields, app-container behavior, and x86/x64 registration. None of that work should duplicate Japanese conversion or local model policy.

Unsigned development builds are distributed as portable archives first. A conventional `setup.exe` may be added later, but its filename does not bypass Microsoft Defender SmartScreen; signing and publisher reputation remain separate concerns.
