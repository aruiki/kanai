# Windows TSF candidate-window source slice

This directory contains a Windows-only C++20 source slice for the candidate
window that a future KanaAI TIP can link into its x86 and x64 DLLs. It is a
technical slice, not a registered TSF text service and not an accessibility
completion claim.

## What is implemented

- `CandidateWindow` creates a native `WS_POPUP` HWND with
  `WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`, passing the TSF client HWND as the
  native owner. It is shown with `SW_SHOWNOACTIVATE`, so opening candidates
  does not steal focus from the application.
- `candidate_window_geometry.*` keeps DPI scaling and caret/work-area placement
  arithmetic independent of HWNDs. The Win32 layer uses
  `GetDpiForWindow`, `GetDpiForSystem`, `AdjustWindowRectExForDpi`, monitor
  work areas, and `WM_DPICHANGED`; it prefers below the caret, flips above when
  needed, and clamps to the monitor work area. The TIP must establish
  per-monitor-v2 awareness before creating the window; this library does not
  silently change the host application's process DPI policy.
- The window draws a preedit/reading header, a bounded candidate list, page
  status, selected-row highlighting, and a native border using GDI. Candidate
  text is passed to `DrawTextW` with ellipsis and `DT_NOPREFIX` handling.
- `HandleKeyDown` and the window procedure support Up/Down/Left/Right,
  Home/End, Page Up/Page Down, number selection, Enter, NumPad Enter, and
  Escape. A TSF key sink should call `HandleKeyDown` while the non-activating
  popup is shown; the window does not create a modal input loop.
- `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` and
  `SetWinEventHook(EVENT_OBJECT_FOCUS)` are installed only while the popup is
  visible and are removed before destruction. `WM_ACTIVATE`, `WM_KILLFOCUS`,
  and `WM_ACTIVATEAPP` provide the focus-loss path. The owner and foreground
  window are checked so returning to the TSF client does not dismiss the list.
- `WM_GETOBJECT` returns a small server-side `IRawElementProviderSimple`
  through `UiaReturnRawElementProvider`. The provider and
  `CandidateAutomationMetadata` expose stable root/item ID conventions and
  basic name/control-type/focus/offscreen properties.

## Broker DTO assumptions

`broker_dto.h` and `broker-contract.json` describe the boundary expected by
this slice. This is a **post-adapter UI DTO**, not the private rerank frame
specified by `tsf/metadata/broker-contract-v1.md`: the TSF host owns that
named-pipe frame, correlates its request, maps Mozc candidate records plus any
broker ranking into these display fields, and discards the wire-only indices.
The window must not parse or depend on the private frame.

1. The TIP owns the private broker transport, schema negotiation, and UTF-8
   JSON decoding. The UI receives bounded UTF-16 strings in
   `BrokerCandidatePageDto`; it does not know an HTTP URL or parse JSON.
2. `contractVersion`, `generation`, and a nonzero `requestId` are required. A
   response older than the currently presented generation is dropped. A TIP session
   epoch is checked by the outer TSF adapter before the DTO reaches this
   layer.
3. Candidate IDs are opaque signed integers scoped to one request/generation.
   They are not Mozc ranks, are never persisted, and are not reused after a
   request. The UI preserves broker order and never ranks candidates.
4. `focusedIndex` is optional and zero-based. The UI clamps/rejects malformed
   indexes, bounds text and list sizes, and drops duplicate IDs rather than
   inventing a selection identity.
5. The only outbound commands are commit, next page, previous page, and
   cancel. The command carries the current generation/request/page and the
   selected opaque ID where applicable. Conversion, learning, persistence,
   network access, and text insertion remain broker/TSF responsibilities.

The normalized-field mapping expected by the TIP is:

| UI DTO field | Adapter assumption |
|---|---|
| `candidate_id` | The adapter assigns an opaque ID for the current request/generation; the UI never derives it from list position. |
| `text`, `reading`, `description` | Decode normalized broker/Mozc text to bounded UTF-16; missing hints stay absent/empty. |
| `origin`, `attributes`, `score` | Optional presentation metadata copied without re-ranking or learning. |
| `preedit`, `preedit_segments` | TIP-owned insertion data; the window renders it but never edits the host range. |
| `page_index`, `page_count`, `focused_index` | Adapter-normalized page metadata; indices are zero-based and validated before display. |

The current Rust broker uses a signed `i32` candidate ID in its normalized
response. The UI uses `int64_t` so a future versioned broker contract can widen
the representation without changing the rendering code. This slice does not
claim that the HTTP/JSON API and the private pipe protocol are already the
same transport.

## Accessibility boundary

The UIA code is intentionally a **metadata/provider stub**, not a completed
accessibility implementation. It currently supplies a stable window automation
ID, a root name/control type, basic focus/offscreen properties, and candidate
ID/name metadata helpers. It does not yet expose a complete child candidate
collection, selection/invoke patterns, live-region announcements, or raised
selection events. Those belong in the TSF/UIA exit-gate work and must be tested
with real screen readers and application containers before claiming support.

The global foreground hook is a light-dismiss mechanism, not a replacement for
TSF focus teardown. The TIP must still destroy/reset the session on editor
focus loss, secure desktop transitions, and context destruction. A callback
must not synchronously destroy the `CandidateWindow` while a command callback
is being dispatched; the outer adapter should marshal lifecycle changes to its
UI thread.

## Building

From a Windows developer prompt with the Windows SDK installed:

```powershell
cmake -S platform/windows-tsf/ui -B build/windows-tsf-ui -A x64
cmake --build build/windows-tsf-ui --config Release
```

The x86 target uses the same source with `-A Win32`. Bazel metadata is also
provided in `BUILD.bazel`; the target is Windows-compatible and is not a DLL
registration rule. Neither build registers a TIP or packages an executable.

## Static checks

The source-only checks do not require Windows or a display:

```powershell
pwsh -File platform/windows-tsf/ui/tests/Test-CandidateWindowSource.ps1
```

They verify the ownership/DPI/keyboard/painting/light-dismiss/UIA seams, the
DTO boundary, and the absence of network/registration claims in this slice.
The same checks are available as a standard-library-only Python test:

```bash
python3 platform/windows-tsf/ui/tests/test_candidate_window_source.py
```
