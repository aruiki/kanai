// KanaAI desktop validation harness - the target application.
//
// This is a real, separate Win32 process with a real multiline edit control, so
// Windows routes text services to it the way it does for a classic Win32 editor.
// The harness launches this instead of Notepad for two reasons:
//
//   1. Notepad on Windows 11 is single-instance and restores the user's tab
//      session. A previous attempt to use it left the user with a canary tab
//      and a stray process. A harness-owned host makes cleanup exact: the only
//      process and window that exist are the ones the harness created.
//   2. The host writes a state file containing its own process id, window
//      handle, window class and, at exit, the text it believes it holds plus
//      its own loaded-module list. That gives the harness a readback channel
//      that is completely independent of any cross-process window message.
//
// Which edit control, and why it is a choice rather than a constant
// --------------------------------------------------------------
// Measured: with a plain `EDIT` control, "kanaai" committed as the literal text
// "kanaai". Sampling the host's own IMM context every 100 ms for four seconds
// after the keystrokes gave `ime.open=False`, an empty preedit and zero reported
// candidates at all forty samples, and then Enter committed plain ASCII. So the
// keystrokes arrive and the readback is neither early nor racy; the composition
// simply never opens, because a plain EDIT control does not host a TSF text
// service and a TSF-only text service is therefore never handed its keystrokes.
// The same window enumeration that found no `MSCTFIME UI` or `IME` window
// belonging to this host found five of each belonging to Notepad.
//
// `RICHEDIT50W` is offered because Msftedit.dll creates a TSF text service for
// its own window, which would give the harness a target that actually receives
// the text service's keystrokes - without this host having to implement
// ITfThreadMgr, ITfDocumentMgr, ITfSource and ITfTextEditSink by hand. That
// interop is deliberately NOT written here: the only msctf.h on this machine is
// a partial header with no GetTextService, StatusWindow, CreateITfSource,
// GetWindow or GetCurrentContext declaration, so a hand-written vtable would be
// a guess, and a wrong vtable corrupts memory rather than failing.
//
// Which one is in use is measured, not assumed: the state file reports the real
// window class of the control that was created, and `--edit plain|rich` selects.
//
// Build command (documented in README.md):
//   csc /nologo /target:winexe /platform:x64 /optimize+
//       /out:bin\KanaAIValidationProbeHost.exe DesktopValidation.ProbeHost.cs
//
// Language level: C# 5, in-box csc only. No NuGet, no msbuild.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace KanaAIValidationProbeHost
{
    internal static class ProbeHost
    {
        internal const string WindowClass = "KanaAIValidationProbeHostClass";
        private const int EditId = 5101;

        private const uint WS_OVERLAPPEDWINDOW = 0x00CF0000;
        private const uint WS_CHILD = 0x40000000;
        private const uint WS_VISIBLE = 0x10000000;
        private const uint WS_VSCROLL = 0x00200000;
        private const uint ES_MULTILINE = 0x0004;
        private const uint ES_AUTOVSCROLL = 0x0080;
        private const uint ES_WANTRETURN = 0x1000;
        private const uint WM_SIZE = 0x0005;
        private const uint WM_SETFOCUS = 0x0007;
        private const uint WM_DESTROY = 0x0002;
        // The harness needs the composition string *while the composition is
        // open*. Waiting for WM_DESTROY would only ever show the final committed
        // document, which is the observation the harness already had. This
        // message asks the target to write its state on demand; the write is
        // synchronous inside the target, so a successful send means the new
        // state is already on disk when the send returns.
        private const uint WM_KANAAI_REPORT_STATE = 0x8001;
        private const int SW_SHOW = 5;

        private static IntPtr mainWindow = IntPtr.Zero;
        private static IntPtr editControl = IntPtr.Zero;

// What was asked for, and what actually happened. Both are reported, because a
// target that silently fell back to a plain EDIT would look exactly like the
// defect the rich control is being used to investigate.
private static string requestedEditClass = "EDIT";
private static string editLoadNote = "not requested";

// The class Windows really gave the control, read back from the window itself.
// Reporting the requested name would be reporting an intention, and this
// harness exists to report measurements.
private static string RealEditClass()
{
    if (editControl == IntPtr.Zero) { return string.Empty; }
    StringBuilder builder = new StringBuilder(128);
    GetClassNameW(editControl, builder, builder.Capacity);
    return builder.ToString();
}
        private static string statePath = string.Empty;
        private static string runId = string.Empty;
        private static WndProcDelegate windowProcedure = null;

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WNDCLASSEX
        {
            public int cbSize;
            public int style;
            public IntPtr lpfnWndProc;
            public int cbClsExtra;
            public int cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
            [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
            public IntPtr hIconSm;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int x;
            public int y;
        }

        // RegisterClassExW is in user32, not kernel32.  This is the same wrong
        // library DesktopValidation.Native.cs had; both are fixed together
        // because the probe host cannot register its window class without it.
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern ushort RegisterClassExW(ref WNDCLASSEX windowClass);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr GetModuleHandleW(string moduleName);

        // Msftedit.dll registers the RICHEDIT50W class. It has to be loaded before
        // the control is created, and the load result is reported rather than
        // assumed.
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryW(string fileName);

        // Read back from the window, so the receipt states a measurement and not
        // an intention.
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int GetClassNameW(IntPtr hWnd, StringBuilder className, int maxCount);

        // The keyboard layout in effect for this thread, and how to change it.
        //
        // Measured: HKCU\Keyboard Layout\Preload has 1 = 00000411, the Japanese
        // layout, yet VK_K produced a literal "k" in the document rather than the
        // kana the Japanese layout maps it to. So the layout in effect for this
        // thread was NOT the preloaded one, and that is a separate fact from which
        // TSF input processor is active. Both are reported: the HKL that was in
        // effect before anything was changed, and the one after.
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadKeyboardLayoutW(string id, uint flags);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr ActivateKeyboardLayout(IntPtr hkl, uint flags);

        [DllImport("user32.dll")]
        private static extern IntPtr GetKeyboardLayout(uint threadId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int GetKeyboardLayoutNameW(StringBuilder name, int maxCount);

        private static string DescribeKeyboardLayout()
        {
            // The low word of the HKL is the language id. It is the only part that
            // identifies the layout, and it is what a reader can compare against
            // the registry without trusting a name.
            uint threadId = GetCurrentThreadId();
            IntPtr hkl = GetKeyboardLayout(threadId);
            uint langId = (uint)(hkl.ToInt64() & 0xFFFF);
            StringBuilder name = new StringBuilder(64);
            GetKeyboardLayoutNameW(name, name.Capacity);
            return string.Format(
                CultureInfo.InvariantCulture,
                "thread={0} hkl=0x{1:X} langId=0x{2:X4} name='{3}'",
                threadId, hkl.ToInt64(), langId, name.ToString());
        }

        private static string ApplyJapaneseKeyboardLayout()
        {
            string before = DescribeKeyboardLayout();
            IntPtr loaded = LoadKeyboardLayoutW("00000411", 0);
            if (loaded == IntPtr.Zero)
            {
                return "before: " + before + "; LoadKeyboardLayoutW('00000411') failed with win32 error " +
                       Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture);
            }
            IntPtr activated = ActivateKeyboardLayout(loaded, 0);
            return "before: " + before + "; loaded hkl=0x" + loaded.ToInt64().ToString("X", CultureInfo.InvariantCulture) +
                   "; after: " + DescribeKeyboardLayout() +
                   "; activate=0x" + activated.ToInt64().ToString("X", CultureInfo.InvariantCulture);
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateWindowExW(uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle, int x, int y, int nWidth, int nHeight, IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool MoveWindow(IntPtr hWnd, int x, int y, int width, int height, bool repaint);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool DestroyWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern IntPtr DefWindowProc(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern IntPtr SetFocus(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool GetMessage(out MSG message, IntPtr hWnd, uint min, uint max);

        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG message);

        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref MSG message);

        [DllImport("user32.dll")]
        private static extern bool PostQuitMessage(int exitCode);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        // -------------------------------------------------------------------
        // The preedit and the candidate list.
        //
        // The harness reads this process's document with WM_GETTEXT and UIA, and
        // both of those can only see *committed* text. With the IME in the ON
        // direction, every keystroke accumulates in the composition string and
        // nothing is committed until the user converts, so a harness that reads
        // only committed text observes an empty document and cannot tell a
        // working IME from a dead one. That is the "preedit not observed" defect:
        // it made the kana steps unobservable, and the calibration that decides
        // how many toggles reach IME-ON could never be determined.
        //
        // The fix has to live *here*, in the target process, and that is not a
        // stylistic choice. IMM32 is per-process: a HIMC belongs to the thread
        // that owns the focused window, and ImmGetCompositionStringW on a
        // context obtained for another process's window does not read that
        // process's composition. So no amount of extra code in the harness
        // process can observe the preedit of a foreign window. The target is
        // already the harness's own independent readback channel - it writes the
        // module list that way too - and this is the same channel extended to
        // the composition state and the candidate list.
        //
        // The candidate list is what makes the AI observable at all: "AI ON and
        // AI OFF produce different candidates" is a claim about these strings.
        // -------------------------------------------------------------------
        [DllImport("imm32.dll")]
        private static extern IntPtr ImmGetContext(IntPtr hWnd);

        [DllImport("imm32.dll")]
        private static extern bool ImmReleaseContext(IntPtr hIMC);

        [DllImport("imm32.dll")]
        private static extern bool ImmGetOpenStatus(IntPtr hIMC);

        [DllImport("imm32.dll", CharSet = CharSet.Unicode)]
        private static extern int ImmGetDescriptionW(IntPtr hIMC, StringBuilder description, int buflen);

        [DllImport("imm32.dll", CharSet = CharSet.Unicode)]
        private static extern int ImmGetCompositionStringW(IntPtr hIMC, uint dwIndex, StringBuilder lpBuf, int dwBufLen);

        [DllImport("imm32.dll", CharSet = CharSet.Unicode)]
        private static extern int ImmGetCandidateListW(IntPtr hIMC, uint dwIndex, IntPtr lpCandidateList, int dwBufLen);

        [DllImport("imm32.dll")]
        private static extern int ImmGetCandidateListCountW(IntPtr hIMC);

        // The conversion mode, which is a different fact from the open status.
        //
        // Why this was added. Measured on 2026-09-27 and again on 2026-09-28:
        // mozc_tip64.dll IS loaded into this process, MSCTF.dll is loaded, the
        // keyboard layout in effect for this thread is 0x4110411 (Japanese), and
        // the text service is created and focused - every one of the
        // CoInitializeEx / Activate / CreateDocumentMgr / CreateContext / SetFocus
        // calls returns S_OK. And yet "k" commits as the ASCII "k", ime.open is
        // false, and there is no preedit and no candidate at any of thirty samples.
        //
        // A kana layout maps VK_K to a kana, so a literal "k" means something
        // intercepted the keystroke and passed it through unconverted. An IME in
        // its alphanumeric (direct input) mode does exactly that: it takes the
        // key and commits the ASCII without opening a composition. That is a
        // different fact from the profile being active, and it is a different
        // fact again from the text service being open, and the instrument could
        // report neither. ImmGetOpenStatus answers the third question and the
        // answer was always false, which says nothing about the second.
        //
        // The bits are reported both raw and decoded, because a raw value that
        // nobody has decoded is the same as no value at all.
        [DllImport("imm32.dll")]
        private static extern int ImmGetConversionStatus(IntPtr hIMC);

        private const uint IME_OPEN = 0x00000010;
        private const uint IME_CONVERSION = 0x00000020;
        // IME_CMODE bits, from imm.h. NATIVE is kana/romaji input on; the
        // ALPHANUMERIC bits are the direct-input states where keys pass through.
        private const uint IME_CMODE_KANA = 0x00000000;
        private const uint IME_CMODE_ALPHANUMERIC = 0x00000001;
        private const uint IME_CMODE_FULLALPHANUMERIC = 0x00000002;
        private const uint IME_CMODE_HALFWIDTHALPHANUMERIC = 0x00000004;
        private const uint IME_CMODE_OFF = 0x00000040;

        // GCS_COMPSTR is the marked composition string; GCS_COMPREADSTR is the
        // reading of it. Both are read because an IME may leave one of them
        // empty, and an empty reading with a non-empty composition is normal
        // rather than a failure.
        private const uint GCS_COMPSTR = 0x00000001;
        private const uint GCS_COMPREADSTR = 0x00000002;

        // CANDIDATELIST is 6 DWORDs followed by an array of CANDIDATEINDEX.
        // CANDIDATEINDEX is two DWORDs and a pointer, so with the default
        // packing it is 16 bytes on x64 and the array starts at offset 24.
        private const int CandidateListHeaderBytes = 24;
        private const int CandidateIndexBytes = 16;

        [StructLayout(LayoutKind.Sequential)]
        private struct CANDIDATEINDEX
        {
            public int dwIndex;
            public int dwAttribute;
            public IntPtr lpstr;
        }

        // What the target process knows about its own IME state. Written into
        // the state file as an object so that "nothing was observed" is
        // distinguishable from "an empty composition was observed": the former
        // sets contextAvailable=false, the latter sets it true with an empty
        // preedit.
        private sealed class ImeObservation
        {
            public bool ContextAvailable;
            public string ContextNote = string.Empty;
            public bool Open;
            public string Description = string.Empty;
            // The conversion mode, read separately from Open. Open says the
            // composition window is up; this says which input state the IME is
            // in, which is what decides whether a keystroke is converted at all.
            public int ConversionStatus = -1;
            public string ConversionMode = "not read";
            public string Preedit = string.Empty;
            public string PreeditReading = string.Empty;
            // The count the IME itself reports, and the number of strings this
            // process actually managed to read. They are separate fields because
            // they disagree exactly when the readback was truncated, and a
            // truncated candidate list is the one failure that would make an AI
            // rerank look like a no-op.
            public int ReportedCandidateCount;
            public int CandidateCount;
            public List<string> Candidates = new List<string>();
            public int SelectionIndex = -1;
            public List<string> ReadbackSources = new List<string>();
        }

        private static ImeObservation ReadImeState()
        {
            ImeObservation observation = new ImeObservation();
            if (editControl == IntPtr.Zero)
            {
                observation.ContextAvailable = false;
                observation.ContextNote = "the edit control does not exist, so this process has no IME context to ask";
                return observation;
            }
            IntPtr context = ImmGetContext(editControl);
            if (context == IntPtr.Zero)
            {
                // A focused window with no IME context is a real state, not an
                // error: it means no IME is attached to this thread's focus. It
                // is reported as such so a reader can tell "no IME here" from
                // "the readback failed".
                observation.ContextAvailable = false;
                observation.ContextNote = "ImmGetContext returned no context for the focused edit control, so no IME is attached to this thread's focus";
                return observation;
            }
            try
            {
                observation.ContextAvailable = true;
                observation.ReadbackSources.Add("ime-context");
                observation.Open = ImmGetOpenStatus(context);
                // ImmGetConversionStatus is declared and NOT called, for the same
                // reason ActivateProfile is not called below. Measured today: with
                // this call present the host dies during its "ready" write with
                // APPCRASH c0000005 and never writes a state file at all, while
                // ImmGetOpenStatus on the same context returns normally. The
                // thread already has a TSF text service attached (SetFocus has not
                // run yet at the "ready" write, but ImmGetContext still answers),
                // so this is the documented "some MSCTF entry points fault inside
                // this process" case, not a bug in the reading.
                //
                // A harness that dies cannot report anything, and an unreported
                // fact is worth less than a working instrument. The call is
                // withheld and the reason recorded; the conversion mode is read
                // from a standalone process instead, where the same class of call
                // succeeds. See STATE.md 0-G-8.
                observation.ConversionMode = "not read here: ImmGetConversionStatus faults in this process (see the comment above); read from a standalone process";
                StringBuilder description = new StringBuilder(256);
                if (ImmGetDescriptionW(context, description, description.Capacity) > 0)
                {
                    observation.Description = description.ToString();
                    observation.ReadbackSources.Add("ime-description");
                }
                StringBuilder composition = new StringBuilder(4096);
                if (ImmGetCompositionStringW(context, GCS_COMPSTR, composition, composition.Capacity) > 0)
                {
                    observation.Preedit = composition.ToString();
                    observation.ReadbackSources.Add("composition-string");
                }
                StringBuilder reading = new StringBuilder(4096);
                if (ImmGetCompositionStringW(context, GCS_COMPREADSTR, reading, reading.Capacity) > 0)
                {
                    observation.PreeditReading = reading.ToString();
                    observation.ReadbackSources.Add("composition-reading");
                }
                ReadCandidates(context, observation);
            }
            finally
            {
                ImmReleaseContext(context);
            }
            return observation;
        }

        private static void ReadCandidates(IntPtr context, ImeObservation observation)
        {
            try
            {
                int count = ImmGetCandidateListCountW(context);
                if (count <= 0) { return; }
                observation.ReportedCandidateCount = count;
                observation.ReadbackSources.Add("candidate-count");
                // Size the buffer from the list itself rather than assuming a
                // page: the strings are UTF-16 and a wrong estimate truncates
                // the tail of the list, which would quietly lose the candidates
                // the AI actually re-ranked.
                int needed = ImmGetCandidateListW(context, 0, IntPtr.Zero, 0);
                if (needed <= 0) { return; }
                IntPtr buffer = Marshal.AllocHGlobal(needed);
                try
                {
                    int written = ImmGetCandidateListW(context, 0, buffer, needed);
                    if (written <= 0) { return; }
                    int usable = written < needed ? written : needed;
                    if (usable < CandidateListHeaderBytes) { return; }
                    // CANDIDATELIST: dwSize(0) dwStyle(4) dwCount(8) dwSelection(12).
                    int selection = Marshal.ReadInt32(buffer, 12);
                    int entries = (usable - CandidateListHeaderBytes) / CandidateIndexBytes;
                    for (int index = 0; index < entries; index++)
                    {
                        // CANDIDATEINDEX: dwIndex(0) dwAttribute(4) lpstr(8).
                        IntPtr entry = new IntPtr(buffer.ToInt64() + CandidateListHeaderBytes + (index * CandidateIndexBytes));
                        IntPtr text = Marshal.ReadIntPtr(entry, 8);
                        if (text == IntPtr.Zero) { continue; }
                        observation.Candidates.Add(Marshal.PtrToStringUni(text) ?? string.Empty);
                    }
                    if (observation.Candidates.Count > 0)
                    {
                        observation.ReadbackSources.Add("candidate-list");
                        observation.CandidateCount = observation.Candidates.Count;
                        observation.SelectionIndex = selection;
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            catch (Exception exception)
            {
                // A candidate list that could not be read is an absent
                // observation, not an empty one. It is recorded in the text the
                // harness can see and, because ReadbackSources then lacks
                // "candidate-list" while ReportedCandidateCount is positive, the
                // difference between "no candidates" and "could not read" stays
                // visible.
                observation.Candidates.Add("<candidate list unavailable>|" + exception.GetType().Name);
            }
        }

        private static string ReadEditText()
        {
            if (editControl == IntPtr.Zero) { return string.Empty; }
            StringBuilder builder = new StringBuilder(16384);
            GetWindowTextW(editControl, builder, builder.Capacity);
            return builder.ToString();
        }

        private static List<string> LoadedModulePaths()
        {
            List<string> paths = new List<string>();
            try
            {
                System.Diagnostics.Process self = System.Diagnostics.Process.GetCurrentProcess();
                foreach (System.Diagnostics.ProcessModule module in self.Modules)
                {
                    paths.Add(module.ModuleName + "|" + module.FileName);
                }
            }
            catch (Exception exception)
            {
                paths.Add("<module list unavailable>|" + exception.GetType().Name);
            }
            return paths;
        }

        // Monotonic count of state writes. The harness asks for a live readback
        // with ReportStateNow; if this number does not advance, the readback did
        // not happen and the harness must treat whatever it is holding as stale
        // rather than as a fresh observation. Without the counter, a harness that
        // silently failed to trigger the refresh would read the "ready" state
        // written before any keystroke and believe the document was empty.
        private static int stateWriteCount;

        private static void WriteState(string phase)
        {
            if (string.IsNullOrEmpty(statePath)) { return; }
            try
            {
                ImeObservation ime = ReadImeState();
                StringBuilder builder = new StringBuilder();
                builder.Append("{");
                builder.Append("\"schemaVersion\":2,");
                builder.Append("\"phase\":\"").Append(JsonEscape(phase)).Append("\",");
                builder.Append("\"runId\":\"").Append(JsonEscape(runId)).Append("\",");
                builder.Append("\"stateWriteCount\":").Append((stateWriteCount + 1).ToString(CultureInfo.InvariantCulture)).Append(",");
                builder.Append("\"processId\":").Append(GetCurrentProcessIdValue()).Append(",");
                builder.Append("\"threadId\":").Append(GetCurrentThreadId()).Append(",");
                builder.Append("\"hwnd\":").Append(mainWindow.ToInt64()).Append(",");
                builder.Append("\"editHwnd\":").Append(editControl.ToInt64()).Append(",");
                builder.Append("\"windowClass\":\"").Append(JsonEscape(WindowClass)).Append("\",");
                builder.Append("\"editClass\":\"").Append(JsonEscape(RealEditClass())).Append("\",");
                builder.Append("\"editClassRequested\":\"").Append(JsonEscape(requestedEditClass)).Append("\",");
                builder.Append("\"editLoadNote\":\"").Append(JsonEscape(editLoadNote)).Append("\",");
                // The TSF attachment is reported with its per-call HRESULTs, so a
                // reader can tell "attached", "failed at CreateContext" and
                // "threw" apart without guessing.
                builder.Append("\"tsf\":\"").Append(JsonEscape(tsfNote)).Append("\",");
                builder.Append("\"tsfAttached\":").Append(tsfNote.StartsWith("text service attached", StringComparison.Ordinal) ? "true" : "false").Append(",");
                builder.Append("\"tsfProfile\":\"").Append(JsonEscape(tsfProfileNote)).Append("\",");
                builder.Append("\"tsfActivate\":\"").Append(JsonEscape(tsfActivateNote)).Append("\",");
                builder.Append("\"keyboardLayout\":\"").Append(JsonEscape(keyboardLayoutNote)).Append("\",");
                builder.Append("\"textAtPhase\":\"").Append(JsonEscape(ReadEditText())).Append("\",");
                builder.Append("\"ime\":{");
                builder.Append("\"contextAvailable\":").Append(ime.ContextAvailable ? "true" : "false").Append(",");
                builder.Append("\"contextNote\":\"").Append(JsonEscape(ime.ContextNote)).Append("\",");
                builder.Append("\"open\":").Append(ime.Open ? "true" : "false").Append(",");
                builder.Append("\"conversionStatus\":").Append(ime.ConversionStatus.ToString(CultureInfo.InvariantCulture)).Append(",");
                builder.Append("\"conversionMode\":\"").Append(JsonEscape(ime.ConversionMode)).Append("\",");
                builder.Append("\"description\":\"").Append(JsonEscape(ime.Description)).Append("\",");
                builder.Append("\"preedit\":\"").Append(JsonEscape(ime.Preedit)).Append("\",");
                builder.Append("\"preeditReading\":\"").Append(JsonEscape(ime.PreeditReading)).Append("\",");
                builder.Append("\"reportedCandidateCount\":").Append(ime.ReportedCandidateCount.ToString(CultureInfo.InvariantCulture)).Append(",");
                builder.Append("\"candidateCount\":").Append(ime.CandidateCount.ToString(CultureInfo.InvariantCulture)).Append(",");
                builder.Append("\"selectionIndex\":").Append(ime.SelectionIndex.ToString(CultureInfo.InvariantCulture)).Append(",");
                builder.Append("\"candidates\":[");
                for (int index = 0; index < ime.Candidates.Count; index++)
                {
                    if (index > 0) { builder.Append(','); }
                    builder.Append('"').Append(JsonEscape(ime.Candidates[index])).Append('"');
                }
                builder.Append("],");
                builder.Append("\"readbackSources\":[");
                for (int index = 0; index < ime.ReadbackSources.Count; index++)
                {
                    if (index > 0) { builder.Append(','); }
                    builder.Append('"').Append(JsonEscape(ime.ReadbackSources[index])).Append('"');
                }
                builder.Append("]},");
                builder.Append("\"modules\":[");
                List<string> modules = LoadedModulePaths();
                for (int index = 0; index < modules.Count; index++)
                {
                    if (index > 0) { builder.Append(','); }
                    builder.Append('"').Append(JsonEscape(modules[index])).Append('"');
                }
                builder.Append("]");
                builder.Append("}");
                // Written through a temporary file and swapped in, because the
                // harness now reads this file *while the run is in progress*
                // rather than only at process exit. A plain File.WriteAllText
                // truncates first and writes second, so a reader landing in
                // between sees a half-written document and reports a parse
                // failure for a file that is perfectly valid. File.Replace is
                // atomic on NTFS, so a reader sees the old document or the new
                // one and never a torn one.
                string directory = Path.GetDirectoryName(Path.GetFullPath(statePath));
                if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory)) { Directory.CreateDirectory(directory); }
                string temporary = statePath + ".tmp";
                File.WriteAllText(temporary, builder.ToString(), new UTF8Encoding(false));
                if (File.Exists(statePath)) { File.Replace(temporary, statePath, null); }
                else { File.Move(temporary, statePath); }
                stateWriteCount++;
            }
            catch (Exception)
            {
                // The host must never die because it could not record its state.
            }
        }

        private static int GetCurrentProcessIdValue()
        {
            return System.Diagnostics.Process.GetCurrentProcess().Id;
        }

        private static string JsonEscape(string value)
        {
            if (value == null) { return string.Empty; }
            StringBuilder builder = new StringBuilder(value.Length + 8);
            foreach (char character in value)
            {
                switch (character)
                {
                    case '\\': builder.Append("\\\\"); break;
                    case '"': builder.Append("\\\""); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (character < ' ') { builder.Append("\\u").Append(((int)character).ToString("x4", CultureInfo.InvariantCulture)); }
                        else { builder.Append(character); }
                        break;
                }
            }
            return builder.ToString();
        }

        private static IntPtr WindowProcedure(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam)
        {
            switch (message)
            {
                case WM_SETFOCUS:
                    if (editControl != IntPtr.Zero) { SetFocus(editControl); }
                    return IntPtr.Zero;
                case WM_KANAAI_REPORT_STATE:
                    // Reply non-zero so the sender can tell "the target wrote its
                    // state" from "the message never reached the target".
                    WriteState("live");
                    return new IntPtr(stateWriteCount);
                case WM_SIZE:
                    if (editControl != IntPtr.Zero)
                    {
                        long packed = lParam.ToInt64();
                        int width = (int)(packed & 0xFFFF);
                        int height = (int)((packed >> 16) & 0xFFFF);
                        MoveWindow(editControl, 8, 8, Math.Max(width - 24, 10), Math.Max(height - 40, 10), true);
                    }
                    return IntPtr.Zero;
                case WM_DESTROY:
                    // Record what this process believes it holds, from inside this
                    // process, before it goes away.
                    WriteState("closing");
                    PostQuitMessage(0);
                    return IntPtr.Zero;
                default:
                    return DefWindowProc(hWnd, message, wParam, lParam);
            }
        }


// ---------------------------------------------------------------------------
// TSF text service hosting.
//
// Why this exists. Measured: with a plain EDIT control and with
// RICHEDIT50W, typing the canary committed the literal ASCII text "kanaai" and
// the target's own IMM context reported ime.open=False, an empty preedit and
// zero candidates at all thirty samples of a four-second window. The keystrokes
// arrived - six of six delivered events - so neither the control class nor the
// readback timing was the variable. A TSF-only text service is never handed
// keystrokes by a window that has no TSF text service, and neither control
// creates one. This is what creates one.
//
// The interface layouts are taken from the machine's own
// msctf.idl, not from memory, and every call reports its HRESULT into the state
// file. That matters twice over. A wrong vtable corrupts memory rather than
// failing, and the only msctf.h on this machine is a partial header with no
// GetTextService, StatusWindow, CreateITfSource, GetWindow or GetCurrentContext
// declaration at all - so writing against that header would have been a guess.
// The authoritative layouts, verified against msctf.idl:
//
//   ITfThreadMgr   {AA80E801-2021-11D2-93E0-0060B067B86E}
//     Activate, Deactivate, CreateDocumentMgr, EnumDocumentMgrs, GetFocus,
//     SetFocus, AssociateFocus, IsThreadFocus, GetFunctionProvider,
//     EnumFunctionProviders, GetGlobalCompartment
//   ITfDocumentMgr {AA80E7F4-2021-11D2-93E0-0060B067B86E}
//     CreateContext, Push, Pop, GetTop, GetBase, EnumContexts
//
// Both CLSID_TF_ThreadMgr {529A9E6B-6587-4F23-AB9E-9C7D683E3C50} and both
// interface IIDs were read out of HKCR on this machine. A recalled value,
// CLSID_TF_InputProcessorProfileMgr {57864485-B1B6-4803-9210-6C6B036F14DE}, does
// not exist here at all.
//
// Only CreateContext and SetFocus are declared, so only those two slots have to
// be right, and each unused slot in between is still declared so the offsets
// line up. TfClientId and TfEditCookie are DWORD.
// ---------------------------------------------------------------------------

[ComImport, Guid("AA80E7F4-2021-11D2-93E0-0060B067B86E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ITfDocumentMgr
{
    [PreserveSig]
    int CreateContext(
        uint tidOwner,
        uint dwFlags,
        [MarshalAs(UnmanagedType.IUnknown)] object punk,
        [MarshalAs(UnmanagedType.Interface)] out ITfContextOwnerHandle ppic,
        out uint pecTextStore);
}

[ComImport, Guid("AA80E801-2021-11D2-93E0-0060B067B86E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ITfThreadMgr
{
    [PreserveSig] int Activate(out uint ptid);
    [PreserveSig] int Deactivate();
    [PreserveSig] int CreateDocumentMgr([MarshalAs(UnmanagedType.Interface)] out ITfDocumentMgr ppdim);
    [PreserveSig] int EnumDocumentMgrs([MarshalAs(UnmanagedType.Interface)] out object ppEnum);
    [PreserveSig] int GetFocus([MarshalAs(UnmanagedType.Interface)] out object ppdimFocus);
    [PreserveSig] int SetFocus([MarshalAs(UnmanagedType.Interface)] ITfDocumentMgr pdimFocus);
}

// ITfContext is declared as an opaque handle on purpose. Nothing here calls into
// it, and a partial declaration of a partially-specified interface is exactly
// the kind of thing that goes wrong silently.
[ComImport, Guid("AA80E7FD-2021-11D2-93E0-0060B067B86E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ITfContextOwnerHandle
{
}

[ComImport, Guid("529A9E6B-6587-4F23-AB9E-9C7D683E3C50")]
internal class TfThreadMgrClass
{
}

[DllImport("ole32.dll")]
private static extern int CoInitializeEx(IntPtr reserved, uint dwCoInit);

private const uint COINIT_APARTMENTTHREADED = 0x2;

// TF_CTX_DOC. Not present in this machine's msctf.h or msctf.idl, so it is
// stated here as the value it has always had and CreateContext's HRESULT is
// reported either way: if the flags were wrong the receipt would say so.
private const uint TF_CTX_DOC = 0x00000000;

private static ITfThreadMgr tsfThreadMgr = null;
private static ITfDocumentMgr tsfDocumentMgr = null;
private static ITfContextOwnerHandle tsfContext = null;
private static uint tsfClientId = 0;

private static string tsfNote = "not attempted";

[DllImport("ole32.dll")]
private static extern int CoUninitialize();

private static void ReleaseComObject(object value)
{
    if (null == value) { return; }
    try { Marshal.ReleaseComObject(value); } catch { }
}

// Attach this window to a TSF text service.
//
// Everything it did is returned as a string and recorded in the state file, so
// the outcome is a measurement. "Tried and failed at step 3" and "succeeded" are
// very different facts about a run and a reader cannot tell them apart from a
// silent return.
private static string AttachTsfTextService(IntPtr window)
{
    var steps = new List<string>();

    int comInit = CoInitializeEx(IntPtr.Zero, COINIT_APARTMENTTHREADED);
    // 0x00010106 is S_FALSE and 0x80010106 is RPC_E_CHANGED_MODE. Both mean COM is
    // already up on this thread, with an apartment this call did not choose.
    // Neither is "COM is unusable".
    //
    // This matters because [STAThread] on Main is what gives the right apartment,
    // and that attribute was once accidentally removed by a fragment insert. The
    // CLR then initialised COM as MTA, this call returned RPC_E_CHANGED_MODE, and
    // the function - which only tolerated S_FALSE - reported the text service as
    // unattached, so every run read tsfAttached=false. A failure that means "the
    // apartment was already decided" must not be reported as "there is no text
    // service".
    steps.Add("CoInitializeEx=0x" + comInit.ToString("X8", CultureInfo.InvariantCulture));
    if ((comInit < 0) && (comInit != unchecked((int)0x00010106)) && (comInit != unchecked((int)0x80010106)))
    {
        tsfNote = "failed: " + string.Join("; ", steps.ToArray());
        return tsfNote;
    }

    try
    {
        ITfThreadMgr threadMgr = (ITfThreadMgr)new TfThreadMgrClass();
        tsfThreadMgr = threadMgr;
        // No HRESULT is recorded for the CoCreateInstance itself: the C# coclass
        // `new` does not expose one, and an earlier version of this line put
        // Marshal.GetHRForLastWin32Error() here under an "HRESULT" label. That is
        // a Win32 error code, not an HRESULT, and reporting it in a column of
        // HRESULTs is the same mistake as reporting an unreadable module list as
        // an empty one. The cast throwing is the signal, and it is caught below.

        int hrActivate = threadMgr.Activate(out tsfClientId);
        steps.Add("Activate=0x" + hrActivate.ToString("X8", CultureInfo.InvariantCulture) + " clientId=" + tsfClientId.ToString(CultureInfo.InvariantCulture));
        // E_UNEXPECTED and S_FALSE both mean the thread manager was already
        // active, which is not a failure for this purpose.
        bool activated = (hrActivate >= 0) || (hrActivate == unchecked((int)0x8000FFFF)) || (hrActivate == 1);

        int hrCreate = threadMgr.CreateDocumentMgr(out tsfDocumentMgr);
        steps.Add("CreateDocumentMgr=0x" + hrCreate.ToString("X8", CultureInfo.InvariantCulture));
        if (hrCreate < 0)
        {
            tsfNote = "failed: " + string.Join("; ", steps.ToArray());
            return tsfNote;
        }

        uint editCookie = 0;
        int hrContext = tsfDocumentMgr.CreateContext(tsfClientId, TF_CTX_DOC, null, out tsfContext, out editCookie);
        steps.Add("CreateContext=0x" + hrContext.ToString("X8", CultureInfo.InvariantCulture) + " cookie=" + editCookie.ToString(CultureInfo.InvariantCulture));
        if (hrContext < 0)
        {
            tsfNote = "failed: " + string.Join("; ", steps.ToArray());
            return tsfNote;
        }

        int hrFocus = threadMgr.SetFocus(tsfDocumentMgr);
        steps.Add("SetFocus=0x" + hrFocus.ToString("X8", CultureInfo.InvariantCulture));

        string verdict = ((hrFocus >= 0) && activated) ? "text service attached" : "attached with a non-fatal HRESULT";
        tsfNote = verdict + ": " + string.Join("; ", steps.ToArray());
    }
    catch (Exception error)
    {
        // A caught exception here is a fact about the interop, not a reason to
        // pretend the text service was never attempted.
        tsfNote = "threw: " + error.GetType().Name + ": " + error.Message + "; steps so far: " + string.Join("; ", steps.ToArray());
    }
    return tsfNote;
}

// ---------------------------------------------------------------------------
// Which input processor is actually active for this thread?
//
// Why this exists. Measured, in order:
//   1. a plain EDIT control committed the canary as literal ASCII, and the
//      target's own IMM context reported ime.open=False at all thirty samples;
//   2. RICHEDIT50W behaved identically, so the control class was not the variable;
//   3. a real TSF text service was then attached - CoInitializeEx, Activate,
//      CreateDocumentMgr, CreateContext and SetFocus all returned S_OK - and a
//      preedit still never opened and no kana was ever committed.
//
// A focused text service that receives no composition means the thread's INPUT
// PROCESSOR is not a romaji-mode Japanese IME, or is not KanaAI. That is the one
// remaining explanation and it had not been measured.
//
// The layout is this machine's msctf.idl (ITfInputProcessorProfileMgr, 8
// methods): ActivateProfile, DeactivateProfile, GetProfile, EnumProfiles,
// ReleaseInputProcessor, RegisterProfile, UnregisterProfile, GetActiveProfile.
// TF_INPUTPROCESSORPROFILE is
//   { DWORD dwProfileType; GUID clsid; GUID guidProfile; UINT_PTR dwHkl; DWORD dwFlags }
// and the profile types are TF_PROFILETYPE_INPUTPROCESSOR 0x1 and
// TF_PROFILETYPE_KEYBOARDLAYOUT 0x2.
//
// This reports. It does not activate anything: changing the thread's input
// processor is a different act from observing which one is in effect, and an
// observation that quietly repairs what it is observing is not an observation.
// ---------------------------------------------------------------------------

[StructLayout(LayoutKind.Sequential)]
internal struct TfInputProcessorProfile
{
    // msctf.idl line 2033, all nine fields, in the IDL's order:
    //   DWORD dwProfileType;  LANGID langid;  CLSID clsid;  GUID guidProfile;
    //   GUID catid;  HKL hklSubstitute;  DWORD dwCaps;  HKL hkl;  DWORD dwFlags;
    // It is 88 bytes on x64 with natural alignment, and ActivateKanaAiInputProcessor
    // asserts that before calling anything. An earlier four-field version of this
    // struct is what the APPCRASH in 0-C-10 was: the callee wrote past the buffer.
    public uint dwProfileType;
    public ushort langid;
    [MarshalAs(UnmanagedType.LPStruct)] public Guid clsid;
    [MarshalAs(UnmanagedType.LPStruct)] public Guid guidProfile;
    [MarshalAs(UnmanagedType.LPStruct)] public Guid catid;
    public UIntPtr hklSubstitute;
    public uint dwCaps;
    public UIntPtr hkl;
    public uint dwFlags;
}

[ComImport, Guid("71C6E74C-0F28-11D8-A82A-00065B84435C"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ITfInputProcessorProfileMgr
{
    // Declared in vtable order from msctf.idl 2056-2103, with every parameter list
    // taken from the IDL rather than from memory. C# lays ComImport methods out in
    // declaration order, so an omitted slot shifts every later call onto the wrong
    // entry, and a wrong entry is a memory access rather than an error.
    //
    // GetProfile has SIX parameters, not two. A previous declaration gave it two,
    // and TF_INPUTPROCESSORPROFILE was given four fields when the IDL describes
    // nine. Those mistakes are what produced the APPCRASH in 0-C-10: the callee
    // wrote past the buffer it was handed. The struct size is therefore asserted
    // before any call, and the call is refused if it does not match.
    [PreserveSig] int ActivateProfile(uint dwProfileType, ushort langid, IntPtr clsid, IntPtr guidProfile, IntPtr hkl, uint dwFlags);
    [PreserveSig] int DeactivateProfile(uint dwProfileType, ushort langid, IntPtr clsid, IntPtr guidProfile, IntPtr hkl, uint dwFlags);
    [PreserveSig] int GetProfile(uint dwProfileType, ushort langid, IntPtr clsid, IntPtr guidProfile, IntPtr hkl, out TfInputProcessorProfile pProfile);
    [PreserveSig] int EnumProfiles(ushort langid, out IntPtr ppEnum);
    [PreserveSig] int ReleaseInputProcessor(IntPtr rclsid, uint dwFlags);
    [PreserveSig] int RegisterProfile(IntPtr rclsid, ushort langid, IntPtr guidProfile, IntPtr pchDesc, uint cchDesc, IntPtr pchIconFile, uint cchFile, uint uIconIndex, IntPtr hklsubstitute, uint dwPreferredLayout, int bEnabledByDefault, uint dwFlags);
    [PreserveSig] int UnregisterProfile(IntPtr rclsid, ushort langid, IntPtr guidProfile, uint dwFlags);
    [PreserveSig] int GetActiveProfile(IntPtr catid, out TfInputProcessorProfile pProfile);
}

private const uint TF_PROFILETYPE_INPUTPROCESSOR = 0x0001;
private const uint TF_PROFILETYPE_KEYBOARDLAYOUT = 0x0002;

// KanaAI's own registration, read out of this machine's registry during this work:
// HKLM\SOFTWARE\Microsoft\CTF\TIP\{7E7B5C1E-...}\LanguageProfile\0x00000411
private static readonly Guid KanaAiTipGuid = new Guid("7E7B5C1E-6D3A-4F2C-9A0E-3F4B5D6C7E81");
private static readonly Guid KanaAiProfileGuid = new Guid("F3C2B7A1-6D54-4E8B-9A10-2C7D8E9F0A12");

// The one category that answers GetActiveProfile on this machine, and the category
// in which the active input processor was measured to BE KanaAI (0-C-17). Its
// value was read out of the TIP's own Category subkey, not from a list of
// well-known GUIDs.
private static readonly Guid KanaAiInputProcessorCategory = new Guid("34745C63-B2F0-4784-8B67-5E12C8701A31");

[ComImport, Guid("33C53A50-F456-4884-B049-85FD643ECFED")]
internal class TfInputProcessorProfilesClass
{
}

// Activates KanaAI's input processor profile for this thread, and reports what
// the OS said before and after.
//
// Why: measured in 0-C-17, KanaAI IS the active input processor for Japanese on
// this machine, with TF_IPP_FLAG_ACTIVE set, and the text service is attached and
// focused - yet "k" commits as "k" and no preedit ever opens. The remaining
// explanation is the text service's own on/off state. Activating the profile
// explicitly is the surgical thing to try, and it is cheap to report whether it
// changed anything.
private static string tsfActivateNote = "not attempted";

private static string DescribeProfileStruct(string label, TfInputProcessorProfile profile)
{
    return string.Format(
        CultureInfo.InvariantCulture,
        "{0}: type=0x{1:X} langid=0x{2:X4} clsid={{{3}}} profile={{{4}}} dwFlags=0x{5:X8}{6}",
        label, profile.dwProfileType, profile.langid,
        profile.clsid.ToString("D").ToUpperInvariant(),
        profile.guidProfile.ToString("D").ToUpperInvariant(),
        profile.dwFlags,
        (profile.dwFlags & 0x1) == 1 ? " (TF_IPP_FLAG_ACTIVE)" : "");
}

private static string ActivateKanaAiInputProcessor()
{
    var steps = new List<string>();
    // The struct size is what crashed a previous attempt, so it is checked first
    // and the call is refused if it does not match the IDL's description.
    int size = Marshal.SizeOf(typeof(TfInputProcessorProfile));
    steps.Add("TF_INPUTPROCESSORPROFILE size=" + size.ToString(CultureInfo.InvariantCulture) + " (IDL describes 88 on x64)");
    if (size != 88)
    {
        tsfActivateNote = "refused: struct layout is " + size + " bytes, not the 88 the IDL describes; not calling";
        return tsfActivateNote;
    }

    object coclass = null;
    IntPtr unknown = IntPtr.Zero;
    IntPtr queried = IntPtr.Zero;
    IntPtr tipMemory = IntPtr.Zero;
    IntPtr profileMemory = IntPtr.Zero;
    IntPtr categoryMemory = IntPtr.Zero;
    try
    {
        coclass = new TfInputProcessorProfilesClass();
        unknown = Marshal.GetIUnknownForObject(coclass);
        Guid iid = new Guid("71C6E74C-0F28-11D8-A82A-00065B84435C");
        int hrQuery = Marshal.QueryInterface(unknown, ref iid, out queried);
        steps.Add("QueryInterface(ITfInputProcessorProfileMgr)=0x" + hrQuery.ToString("X8", CultureInfo.InvariantCulture));
        if (hrQuery < 0 || queried == IntPtr.Zero)
        {
            tsfActivateNote = "unavailable: " + string.Join("; ", steps.ToArray());
            return tsfActivateNote;
        }

        var mgr = (ITfInputProcessorProfileMgr)Marshal.GetObjectForIUnknown(queried);

        categoryMemory = Marshal.AllocHGlobal(16);
        Marshal.StructureToPtr(KanaAiInputProcessorCategory, categoryMemory, false);
        TfInputProcessorProfile before;
        int hrBefore = mgr.GetActiveProfile(categoryMemory, out before);
        steps.Add(DescribeProfileStruct("before GetActiveProfile=0x" + hrBefore.ToString("X8", CultureInfo.InvariantCulture), before));

        tipMemory = Marshal.AllocHGlobal(16);
        Marshal.StructureToPtr(KanaAiTipGuid, tipMemory, false);
        profileMemory = Marshal.AllocHGlobal(16);
        Marshal.StructureToPtr(KanaAiProfileGuid, profileMemory, false);

        int hrActivate = mgr.ActivateProfile(
            TF_PROFILETYPE_INPUTPROCESSOR, 0x0411, tipMemory, profileMemory, IntPtr.Zero, 0);
        steps.Add("ActivateProfile(INPUTPROCESSOR, 0x0411, KanaAI)=0x" + hrActivate.ToString("X8", CultureInfo.InvariantCulture));

        TfInputProcessorProfile after;
        int hrAfter = mgr.GetActiveProfile(categoryMemory, out after);
        steps.Add(DescribeProfileStruct("after  GetActiveProfile=0x" + hrAfter.ToString("X8", CultureInfo.InvariantCulture), after));

        tsfActivateNote = string.Join("; ", steps.ToArray());
    }
    catch (Exception error)
    {
        tsfActivateNote = "threw: " + error.GetType().Name + ": " + error.Message + "; steps so far: " + string.Join("; ", steps.ToArray());
    }
    finally
    {
        if (categoryMemory != IntPtr.Zero) { Marshal.FreeHGlobal(categoryMemory); }
        if (profileMemory != IntPtr.Zero) { Marshal.FreeHGlobal(profileMemory); }
        if (tipMemory != IntPtr.Zero) { Marshal.FreeHGlobal(tipMemory); }
        if (queried != IntPtr.Zero) { Marshal.Release(queried); }
        if (unknown != IntPtr.Zero) { Marshal.Release(unknown); }
    }
    return tsfActivateNote;
}

// KanaAI's registered language profile, read out of
// HKLM\SOFTWARE\Microsoft\CTF\TIP\{7E7B5C1E-...}\LanguageProfile\0x00000411
// during this work, not from memory. Enable = 1 there.


private static string tsfProfileNote = "not read";

// The keyboard layout that was in effect, and what was done about it. The HKL's
// low word is the language id, so a reader can compare it against the registry
// without trusting a localised name.
private static string keyboardLayoutNote = "not read";

private static string DescribeProfile(string label, int hr, TfInputProcessorProfile profile)
{
    // langid and hkl are included because they are the two fields that decide
    // whether a profile is Japanese and whether a layout is attached to it; the
    // earlier four-field struct had neither, and the one it called dwHkl is now
    // `hkl`.
    return string.Format(
        CultureInfo.InvariantCulture,
        "{0}=0x{1:X8} type=0x{2:X} langid=0x{3:X4} clsid={{{4}}} profile={{{5}}} hkl=0x{6:X} flags=0x{7:X8}",
        label, hr, profile.dwProfileType, profile.langid, profile.clsid, profile.guidProfile,
        profile.hkl.ToUInt64(), profile.dwFlags);
}

                // [STAThread] is load-bearing and was accidentally removed once.
        //
        // It was dropped by a fragment insert that kept lines 0..index-1 and
        // therefore excluded the attribute line itself. With it gone the CLR
        // initialises COM as MTA, and AttachTsfTextService's
        // CoInitializeEx(COINIT_APARTMENTTHREADED) then fails with
        // RPC_E_CHANGED_MODE, which the function treated as fatal - so the text
        // service stopped being attached and every run reported tsfAttached=false.
        // TSF wants a single-threaded apartment. This attribute is what provides
        // it, and the probe host is not correct without it.
        [STAThread]
        private static int Main(string[] args)
        {
            int width = 720;
            int height = 260;
            string editChoice = "plain";
            string layoutChoice = "keep";
            for (int index = 0; index < args.Length - 1; index++)
            {
                if (args[index] == "--state") { statePath = args[index + 1]; }
                else if (args[index] == "--runid") { runId = args[index + 1]; }
                else if (args[index] == "--width") { int parsed; if (int.TryParse(args[index + 1], out parsed)) { width = parsed; } }
                else if (args[index] == "--height") { int parsed; if (int.TryParse(args[index + 1], out parsed)) { height = parsed; } }
                else if (args[index] == "--edit") { editChoice = args[index + 1]; }
                else if (args[index] == "--layout") { layoutChoice = args[index + 1]; }
            }
            if (string.IsNullOrEmpty(runId)) { runId = "no-runid"; }

            // The rich control's class is registered by Msftedit.dll, so the
            // library has to be loaded before CreateWindowExW asks for the class.
            // A failure here is reported through the state file rather than being
            // swallowed, because a target that silently fell back to a plain EDIT
            // would look exactly like the defect this is meant to investigate.
            string editClassName = "EDIT";
            string richLoadNote = "not requested";
            if (string.Equals(editChoice, "rich", StringComparison.OrdinalIgnoreCase))
            {
                richLoadNote = "requested";
                IntPtr richModule = LoadLibraryW("Msftedit.dll");
                if (richModule == IntPtr.Zero)
                {
                    richLoadNote = "Msftedit.dll did not load; win32 error " + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture);
                }
                else
                {
                    editClassName = "RICHEDIT50W";
                    richLoadNote = "Msftedit.dll loaded at 0x" + richModule.ToInt64().ToString("x", CultureInfo.InvariantCulture);
                }
            }
            requestedEditClass = editClassName;
            editLoadNote = richLoadNote;

            windowProcedure = new WndProcDelegate(WindowProcedure);
            GC.KeepAlive(windowProcedure);

            WNDCLASSEX windowClass = new WNDCLASSEX();
            windowClass.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX));
            windowClass.style = 0x0003;
            windowClass.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(windowProcedure);
            windowClass.hInstance = GetModuleHandleW(null);
            windowClass.lpszClassName = WindowClass;
            if (RegisterClassExW(ref windowClass) == 0) { return 10; }

            mainWindow = CreateWindowExW(
                0,
                WindowClass,
                "KanaAI Desktop Validation Probe " + runId,
                WS_OVERLAPPEDWINDOW,
                120, 120, width, height,
                IntPtr.Zero, IntPtr.Zero, windowClass.hInstance, IntPtr.Zero);
            if (mainWindow == IntPtr.Zero) { return 11; }

            editControl = CreateWindowExW(
                0,
                editClassName,
                string.Empty,
                WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN,
                8, 8, Math.Max(width - 24, 10), Math.Max(height - 40, 10),
                mainWindow, new IntPtr(EditId), windowClass.hInstance, IntPtr.Zero);
            if (editControl == IntPtr.Zero)
            {
                DestroyWindow(mainWindow);
                return 12;
            }

            ShowWindow(mainWindow, SW_SHOW);

            // The window exists; now give its thread a TSF text service, so that
            // a TSF-only text service is actually handed this window's keystrokes.
            // The result of every call is recorded rather than assumed.
            AttachTsfTextService(editControl);
            // The explicit ActivateProfile call was tried here and faulted inside this process:
            //   APPCRASH KanaAIValidationProbeHost.exe, faulting module MSCTF.dll, code c0000005,
            //   four event-log entries in a single run. The identical call succeeds in a standalone
            //   console process (.local\ai6\ProbeActiveInputProcessor.cs, exit 0, no crash), so the
            //   declarations and the 88-byte struct are right and whatever differs is this process.
            //   That difference is NOT identified, and an unidentified fault in the target the harness
            //   owns is worse than no activation: a probe host that dies cannot report the text
            //   service attachment that IS proven, nor anything else. So the call is withheld and the
            //   reason is recorded. The corrected declarations stay in the file.
            tsfActivateNote = "not attempted: calling ActivateProfile from this process faulted inside MSCTF.dll (c0000005). The same call succeeds standalone, so the difference is this process and is not yet identified. See STATE.md 0-C-18.";

            // The keyboard layout, measured and optionally changed. Kept separate
            // from the TSF attachment because they are separate facts: the layout
            // decides which characters a raw key event becomes, the input processor
            // decides whether a composition is started at all.
            keyboardLayoutNote = DescribeKeyboardLayout();
            if (string.Equals(layoutChoice, "jp", StringComparison.OrdinalIgnoreCase))
            {
                keyboardLayoutNote = ApplyJapaneseKeyboardLayout();
            }

            WriteState("ready");
            SetFocus(editControl);

            MSG message;
            while (GetMessage(out message, IntPtr.Zero, 0, 0))
            {
                TranslateMessage(ref message);
                DispatchMessage(ref message);
            }
            return 0;
        }
    }
}
