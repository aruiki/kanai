# Windows TSF beta

KanaAI's first Windows beta is a native Text Services Framework (TSF) Text
Input Processor (TIP). A browser Workbench, CLI, HTTP API, or Mozc bridge is
not an IME beta and is not packaged as one.

The implementation is being developed against the pinned upstream Mozc source
in `third_party/mozc`. The TSF TIP owns Windows text-service lifecycle,
preedit/candidate presentation, focus recovery, and the native integration
boundary. KanaAI's Rust broker and bounded local AI remain behind that boundary
and must never take ownership of commit, mode, or learning state.

## Required beta gates

- x64 TIP DLL builds with MSVC/Windows SDK and required Mozc dependencies.
- Text-service/profile registration and clean uninstall work in Windows.
- Notepad, Edge, and Office pass composition, conversion, candidate, commit,
  cancel, focus-loss, and restart tests.
- Secure fields, UI Automation, high-DPI, app-container policy, and x86/x64
  support are tested or explicitly documented as unsupported.
- Broker/model failure falls back without losing the composition or committing
  unexpected text.
- SHA-256, SBOM, provenance, and signing status are published honestly.

The product boundary and exit criteria are recorded in
[`docs/PRODUCT_RELEASE_CONTRACT.md`](../../docs/PRODUCT_RELEASE_CONTRACT.md).
