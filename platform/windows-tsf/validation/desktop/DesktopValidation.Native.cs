// KanaAI desktop validation harness - native layer.
//
// Design rules, and they are the point of this file:
//   * Nothing here reports success. Every method that touches the input queue
//     returns the raw API result (events queued, last error) and lets the caller
//     decide. The caller decides using a readback of the target's own state.
//   * Every "get" is a read of observable state. There is no method here that
//     infers an outcome from an API return code.
//   * The window-station and desktop names are first-class data, because a
//     mismatch between the injector's desktop and the target's desktop is the
//     most likely explanation for a total, silent input-delivery failure.
//
// Language level: C# 5, so this compiles with the in-box
// C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe that ships with
// .NET Framework and needs no NuGet, no msbuild and no Roslyn.
//
// Build command (documented in README.md):
//   csc /nologo /target:library /platform:x64 /optimize+
//       /out:bin\DesktopValidation.Native.dll DesktopValidation.Native.cs
//
// Add-Type -TypeDefinition over this file is an equally supported way to
// consume it when no prebuilt DLL is present.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace KanaAI.DesktopValidation
{
    public sealed class KeyOutcome
    {
        public string Token = "";
        public int RequestedEvents;
        public int SentEvents;
        public int LastError;
        public bool ApiOk;
        public long TickCount;
        public string Detail = "";
    }

    public sealed class WindowRecord
    {
        public long Hwnd;
        public uint ProcessId;
        public uint ThreadId;
        public string ClassName = "";
        public string Title = "";
        public bool Visible;
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
        public long OwnerHwnd;
        public long ParentHwnd;
        public int ExStyle;
    }

    public sealed class ModuleRecord
    {
        public string Name = "";
        public string Path = "";
    }

    public sealed class PreflightRecord
    {
        public int ProcessId;
        public uint ThreadId;
        public uint SessionId;
        public int Is64BitProcess;
        public string WindowStation = "unknown";
        public int WindowStationError;
        public string Desktop = "unknown";
        public int DesktopError;
        public string IntegrityLevel = "unknown";
        public string IntegritySid = "";
        public int IntegrityError;
        public bool IsElevated;
        public string ElevationType = "unknown";
        public int UiAccess = -1;      // -1 unknown, 0 not declared, 1 declared
        public string UiAccessMethod = "not-probed";
        public string DpiAwareness = "unknown";
        public string DpiAwarenessDetail = "";
        public long ForegroundHwnd;
        public uint ForegroundProcessId;
        public string ForegroundClass = "";
        public string ForegroundTitle = "";
        public string ForegroundProcessName = "";
    }

    public sealed class TargetThreadRecord
    {
        public long Hwnd;
        public uint ProcessId;
        public uint ThreadId;
        public string Desktop = "unknown";
        public int DesktopError;
        public string WindowStation = "unknown";
        public int WindowStationError;
    }

    public sealed class CaretRecord
    {
        public bool Ok;
        public int LastError;
        public long ActiveHwnd;
        public long FocusHwnd;
        public long CaptureHwnd;
        public long CaretHwnd;
        public int CaretLeft;
        public int CaretTop;
        public int CaretRight;
        public int CaretBottom;
    }

    public sealed class LastInputRecord
    {
        public bool Ok;
        public int LastError;
        public uint TickCount;
        public uint LastInputTick;
    }

    public sealed class ImmRecord
    {
        public bool Ok;
        public int LastError;
        public bool Open;
        public string ContextName = "";
    }

    public sealed class DpiRecord
    {
        public bool Ok;
        public int LastError;
        public int ProcessAwareness = -1;   // 0 unaware, 1 system, 2 per-monitor
        public string ProcessAwarenessName = "unknown";
        public int ThreadAwareness = -1;
        public string ThreadAwarenessName = "unknown";
        public long AwarenessContext = 0;
        public string Method = "not-probed";
    }

    public static class Native
    {
        // Exported surface, mirrored by the pure PowerShell wiring check. The
        // self-test fails closed if a run script calls a member that is not
        // declared in this file.
        public static readonly string[] ApiSurface = new string[] {
            "SendInput", "PressKey", "SendKeySequence", "SendKeyChord", "SendTextAsUnicode",
            "CapturePreflight", "CaptureTargetThread", "GetWindowThreadInfo", "GetDpiRecord",
            "EnumerateWindows", "EnumerateChildWindows", "GetLoadedModules",
            "GetCaretRecord", "GetLastInputRecord", "GetImmRecord",
            "CreateLoopbackWindow", "PumpMessages", "GetLoopbackText", "DestroyLoopbackWindow",
            "ShowLoopback", "ShowLoopbackAndFocusEdit", "ForceForeground", "GetForegroundRecord",
            "SendWindowTextRequest", "CloseWindowIfOwned", "IsWindowAlive",
            "GetVirtualKeyForToken", "GetManifestUiAccessFlag", "GetLoopbackEditHwnd"
        };

        // Single source of truth for key tokens. The pure PowerShell plan
        // validator keeps a matching list and the self-test proves parity, so a
        // plan can never validate against a key the injector does not know.
        public static readonly string[] KeyTokenMap = new string[] {
            "VK_SHIFT", "VK_CONTROL", "VK_MENU", "VK_SPACE", "VK_RETURN", "VK_ESCAPE",
            "VK_TAB", "VK_BACK", "VK_A", "VK_B", "VK_C", "VK_D", "VK_E", "VK_F",
            "VK_G", "VK_H", "VK_I", "VK_J", "VK_K", "VK_L", "VK_M", "VK_N", "VK_O",
            "VK_P", "VK_Q", "VK_R", "VK_S", "VK_T", "VK_U", "VK_V", "VK_W", "VK_X",
            "VK_Y", "VK_Z", "VK_F6", "VK_CAPITAL", "VK_HANKAKU", "VK_ZENKAKU",
            "VK_CONVERT", "VK_NONCONVERT", "VK_OEM_3"
        };

        // ------------------------------------------------------------------
        // Constants
        // ------------------------------------------------------------------
        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const uint KEYEVENTF_UNICODE = 0x0004;
        private const uint KEYEVENTF_SCANCODE = 0x0008;
        private const uint MAPVK_VK_TO_VSC = 0;
        private const int UOI_NAME = 2;
        private const uint TOKEN_QUERY = 0x0008;
        private const uint TOKEN_QUERY_INFORMATION = 0x0020;
        private const int TokenIntegrityLevel = 25;
        private const int TokenElevation = 20;
        private const int TokenUIAccess = 26;
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint PROCESS_VM_READ = 0x0010;
        private const uint LIST_MODULES_ALL = 0x03;
        private const int GWL_EXSTYLE = -20;
        private const uint GW_OWNER = 4;
        private const uint WM_GETTEXT = 0x000D;
        private const uint WM_GETTEXTLENGTH = 0x000E;
        private const uint WM_CLOSE = 0x0010;
        private const uint SMTO_ABORTIFHUNG = 0x0002;
        private const int SW_SHOW = 5;
        private const int SW_RESTORE = 9;
        private const string LoopbackClassName = "KanaAIValidationLoopbackClass";
        private const int LoopbackEditId = 4101;
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

        [StructLayout(LayoutKind.Sequential)]
        internal struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Explicit)]
        internal struct INPUTUNION
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct INPUT
        {
            public uint type;
            public INPUTUNION u;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct RECT
        {
            public int Left, Top, Right, Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct GUITHREADINFO
        {
            public int cbSize;
            public uint flags;
            public IntPtr hwndActive;
            public IntPtr hwndFocus;
            public IntPtr hwndCapture;
            public IntPtr hwndMenuOwner;
            public IntPtr hwndMoveSize;
            public IntPtr hwndCaret;
            public RECT rcCaret;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct LASTINPUTINFO
        {
            public uint cbSize;
            public uint dwTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct TOKEN_ELEVATION
        {
            public int TokenIsElevated;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        internal struct SID_AND_ATTRIBUTES
        {
            public IntPtr Sid;
            public uint Attributes;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        internal struct TOKEN_MANDATORY_LABEL
        {
            public SID_AND_ATTRIBUTES Label;
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        internal delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        internal delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct WNDCLASSEX
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
        internal struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int x;
            public int y;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint GetLastError();

        [DllImport("kernel32.dll")]
        internal static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll")]
        internal static extern int GetCurrentProcessId();

        [DllImport("kernel32.dll")]
        internal static extern uint GetCurrentThreadId();

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr GetModuleHandleW(string moduleName);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi, BestFitMapping = false, ExactSpelling = true)]
        internal static extern IntPtr GetProcAddress(IntPtr module, string procedureName);

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool GetUserObjectInformationW(IntPtr hObj, int nIndex, byte[] pvInfo, int nLength, out int lpnLengthNeeded);

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern IntPtr GetProcessWindowStation();

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern IntPtr GetThreadDesktop(uint dwThreadId);

        [DllImport("user32.dll")]
        internal static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        internal static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        internal static extern bool BringWindowToTop(IntPtr hWnd);

        [DllImport("user32.dll")]
        internal static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        internal static extern IntPtr SetFocus(IntPtr hWnd);

        [DllImport("user32.dll")]
        internal static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

        [DllImport("user32.dll")]
        internal static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        internal static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll")]
        internal static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam, uint flags, uint timeout, out IntPtr result);

        [DllImport("user32.dll")]
        internal static extern IntPtr GetParent(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
        internal static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        internal static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        internal static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        internal static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr ImmGetContext(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool ImmGetOpenStatus(IntPtr hIMC);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern int ImmGetContextNameW(IntPtr hIMC, StringBuilder name, int maxLength);

        [DllImport("user32.dll")]
        internal static extern bool ImmReleaseContext(IntPtr hIMC);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern ushort MapVirtualKeyW(uint code, uint mapType);

        [DllImport("advapi32.dll", SetLastError = true)]
        internal static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        internal static extern bool GetTokenInformation(IntPtr tokenHandle, int tokenInformationClass, IntPtr tokenInformation, int tokenInformationLength, out int returnLength);

        [DllImport("advapi32.dll", SetLastError = true)]
        internal static extern bool CloseHandle(IntPtr handle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr stringSid);

        [DllImport("kernel32.dll")]
        internal static extern IntPtr LocalFree(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

        [DllImport("psapi.dll", SetLastError = true)]
        internal static extern bool EnumProcessModulesEx(IntPtr processHandle, [Out] IntPtr[] modules, uint cb, uint filter, out uint needed);

        [DllImport("psapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern uint GetModuleFileNameExW(IntPtr processHandle, IntPtr module, StringBuilder name, int maxLength);

        [DllImport("psapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern uint GetModuleBaseNameW(IntPtr processHandle, IntPtr module, StringBuilder name, int maxLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern ushort RegisterClassExW(ref WNDCLASSEX windowClass);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateWindowExW(uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle, int x, int y, int nWidth, int nHeight, IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool DestroyWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool MoveWindow(IntPtr hWnd, int x, int y, int width, int height, bool repaint);

        [DllImport("user32.dll")]
        private static extern IntPtr DefWindowProc(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool PeekMessage(out MSG message, IntPtr hWnd, uint min, uint max, uint remove);

        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG message);

        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref MSG message);

        [DllImport("user32.dll")]
        private static extern bool PostQuitMessage(int exitCode);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        // ------------------------------------------------------------------
        // Small helpers
        // ------------------------------------------------------------------
        private static int LastErrorCode()
        {
            return unchecked((int)GetLastError());
        }

        private static string GetWindowTextSafe(IntPtr hWnd)
        {
            StringBuilder builder = new StringBuilder(2048);
            GetWindowTextW(hWnd, builder, builder.Capacity);
            return builder.ToString();
        }

        private static string GetClassNameSafe(IntPtr hWnd)
        {
            StringBuilder builder = new StringBuilder(512);
            GetClassNameW(hWnd, builder, builder.Capacity);
            return builder.ToString();
        }

        private static string GetUserObjectName(IntPtr handle, out int error)
        {
            error = 0;
            if (handle == IntPtr.Zero)
            {
                error = LastErrorCode();
                return "unavailable";
            }
            byte[] buffer = new byte[2048];
            int needed = 0;
            if (!GetUserObjectInformationW(handle, UOI_NAME, buffer, buffer.Length, out needed))
            {
                error = LastErrorCode();
                return "unavailable";
            }
            return Encoding.Unicode.GetString(buffer).TrimEnd('\0');
        }

        private static WindowRecord DescribeWindow(IntPtr hWnd, bool includeOwner)
        {
            uint processId = 0;
            uint threadId = GetWindowThreadProcessId(hWnd, out processId);
            RECT rect;
            GetWindowRect(hWnd, out rect);
            WindowRecord record = new WindowRecord();
            record.Hwnd = hWnd.ToInt64();
            record.ProcessId = processId;
            record.ThreadId = threadId;
            record.ClassName = GetClassNameSafe(hWnd);
            record.Title = GetWindowTextSafe(hWnd);
            record.Visible = IsWindowVisible(hWnd);
            record.Left = rect.Left;
            record.Top = rect.Top;
            record.Right = rect.Right;
            record.Bottom = rect.Bottom;
            record.ParentHwnd = GetParent(hWnd).ToInt64();
            record.ExStyle = GetWindowLong32(hWnd, GWL_EXSTYLE);
            record.OwnerHwnd = includeOwner ? GetWindow(hWnd, GW_OWNER).ToInt64() : 0L;
            return record;
        }

        private static string ProcessNameOf(uint processId)
        {
            try
            {
                System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById((int)processId);
                return process.ProcessName;
            }
            catch (Exception)
            {
                return "unavailable";
            }
        }

        private static string ParseIntegrityRid(string sid)
        {
            if (string.IsNullOrEmpty(sid)) { return "unknown"; }
            string[] parts = sid.Split('-');
            try
            {
                uint rid = uint.Parse(parts[parts.Length - 1]);
                switch (rid)
                {
                    case 0x0000: return "untrusted";
                    case 0x1000: return "low";
                    case 0x2000: return "medium";
                    case 0x3000: return "high";
                    case 0x4000: return "system";
                    default: return "rid-" + rid.ToString("x");
                }
            }
            catch (Exception)
            {
                return "unknown";
            }
        }

        // ------------------------------------------------------------------
        // Input injection. Returns the API result only; delivery is decided by
        // the caller's independent readback, never here.
        // ------------------------------------------------------------------
        public static ushort GetVirtualKeyForToken(string token)
        {
            if (string.IsNullOrEmpty(token)) { return 0; }
            switch (token)
            {
                case "VK_SHIFT": return 0x10;
                case "VK_CONTROL": return 0x11;
                case "VK_MENU": return 0x12;
                case "VK_SPACE": return 0x20;
                case "VK_RETURN": return 0x0D;
                case "VK_ESCAPE": return 0x1B;
                case "VK_TAB": return 0x09;
                case "VK_BACK": return 0x08;
                case "VK_F6": return 0x75;
                case "VK_CAPITAL": return 0x14;
                case "VK_HANKAKU": return 0xF4;
                case "VK_ZENKAKU": return 0xF5;
                case "VK_CONVERT": return 0x1C;
                case "VK_NONCONVERT": return 0x1D;
                case "VK_OEM_3": return 0xC0;
                default: break;
            }
            if (token.Length == 3 && token[0] == 'V' && token[1] == 'K' && token[2] >= 'A' && token[2] <= 'Z')
            {
                return (ushort)token[2];
            }
            return 0;
        }

        private static bool TokenIsExtended(string token)
        {
            switch (token)
            {
                case "VK_RETURN":
                case "VK_ESCAPE":
                case "VK_TAB":
                case "VK_BACK":
                case "VK_MENU":
                case "VK_F6":
                case "VK_OEM_3":
                    return true;
                default:
                    return false;
            }
        }

        private static KeyOutcome SendKeyPair(ushort virtualKey, bool extended, bool scanCode, int delayMs)
        {
            int size = Marshal.SizeOf(typeof(INPUT));
            INPUT[] inputs = new INPUT[2];

            ushort scan = 0;
            uint baseFlags = 0;
            if (scanCode)
            {
                scan = MapVirtualKeyW(virtualKey, MAPVK_VK_TO_VSC);
                baseFlags = KEYEVENTF_SCANCODE;
            }
            if (extended) { baseFlags |= KEYEVENTF_EXTENDEDKEY; }

            inputs[0].type = INPUT_KEYBOARD;
            inputs[0].u.ki.wVk = scanCode ? (ushort)0 : virtualKey;
            inputs[0].u.ki.wScan = scan;
            inputs[0].u.ki.dwFlags = baseFlags;
            inputs[0].u.ki.time = 0;
            inputs[0].u.ki.dwExtraInfo = IntPtr.Zero;

            inputs[1].type = INPUT_KEYBOARD;
            inputs[1].u.ki.wVk = scanCode ? (ushort)0 : virtualKey;
            inputs[1].u.ki.wScan = scan;
            inputs[1].u.ki.dwFlags = baseFlags | KEYEVENTF_KEYUP;
            inputs[1].u.ki.time = 0;
            inputs[1].u.ki.dwExtraInfo = IntPtr.Zero;

            uint sent = SendInput(2, inputs, size);
            int error = LastErrorCode();
            if (delayMs > 0) { System.Threading.Thread.Sleep(delayMs); }

            KeyOutcome outcome = new KeyOutcome();
            outcome.RequestedEvents = 2;
            outcome.SentEvents = (int)sent;
            outcome.LastError = error;
            outcome.ApiOk = (sent == 2);
            outcome.TickCount = (long)Environment.TickCount;
            outcome.Detail = "virtualKey=" + virtualKey + ";extended=" + extended + ";scanCode=" + scanCode + ";scan=" + scan;
            return outcome;
        }

        private static KeyOutcome SendUnicodeChar(char character, int delayMs)
        {
            int size = Marshal.SizeOf(typeof(INPUT));
            INPUT[] inputs = new INPUT[2];
            inputs[0].type = INPUT_KEYBOARD;
            inputs[0].u.ki.wVk = 0;
            inputs[0].u.ki.wScan = (ushort)character;
            inputs[0].u.ki.dwFlags = KEYEVENTF_UNICODE;
            inputs[0].u.ki.time = 0;
            inputs[0].u.ki.dwExtraInfo = IntPtr.Zero;
            inputs[1].type = INPUT_KEYBOARD;
            inputs[1].u.ki.wVk = 0;
            inputs[1].u.ki.wScan = (ushort)character;
            inputs[1].u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            inputs[1].u.ki.time = 0;
            inputs[1].u.ki.dwExtraInfo = IntPtr.Zero;

            uint sent = SendInput(2, inputs, size);
            int error = LastErrorCode();
            if (delayMs > 0) { System.Threading.Thread.Sleep(delayMs); }

            KeyOutcome outcome = new KeyOutcome();
            outcome.RequestedEvents = 2;
            outcome.SentEvents = (int)sent;
            outcome.LastError = error;
            outcome.ApiOk = (sent == 2);
            outcome.TickCount = (long)Environment.TickCount;
            outcome.Detail = "unicode=0x" + ((int)character).ToString("x4");
            return outcome;
        }

        public static KeyOutcome PressKey(string token, int delayMs, bool scanCode)
        {
            ushort virtualKey = GetVirtualKeyForToken(token);
            if (virtualKey == 0)
            {
                KeyOutcome rejected = new KeyOutcome();
                rejected.Token = token;
                rejected.RequestedEvents = 0;
                rejected.SentEvents = 0;
                rejected.LastError = 0;
                rejected.ApiOk = false;
                rejected.Detail = "unknown key token; nothing was injected";
                return rejected;
            }
            KeyOutcome outcome = SendKeyPair(virtualKey, TokenIsExtended(token), scanCode, delayMs);
            outcome.Token = token;
            return outcome;
        }

        public static KeyOutcome[] SendKeySequence(string[] tokens, int delayMs, bool scanCode)
        {
            List<KeyOutcome> results = new List<KeyOutcome>();
            if (tokens == null) { return results.ToArray(); }
            for (int index = 0; index < tokens.Length; index++)
            {
                results.Add(PressKey(tokens[index], delayMs, scanCode));
            }
            return results.ToArray();
        }

        // Modifiers first, final token is the key itself. One outcome is returned
        // per physical key event so the receipt can show exactly what was queued.
        public static KeyOutcome[] SendKeyChord(string[] tokens, int delayMs, bool scanCode)
        {
            List<KeyOutcome> results = new List<KeyOutcome>();
            if (tokens == null || tokens.Length == 0) { return results.ToArray(); }
            int lastIndex = tokens.Length - 1;

            for (int index = 0; index < lastIndex; index++)
            {
                ushort modifier = GetVirtualKeyForToken(tokens[index]);
                if (modifier == 0)
                {
                    KeyOutcome rejected = new KeyOutcome();
                    rejected.Token = tokens[index];
                    rejected.Detail = "unknown modifier token; chord aborted before any key was pressed";
                    results.Add(rejected);
                    return results.ToArray();
                }
                results.Add(SendKeyPair(modifier, false, scanCode, 0));
            }

            results.Add(PressKey(tokens[lastIndex], delayMs, scanCode));

            for (int index = lastIndex - 1; index >= 0; index--)
            {
                ushort modifier = GetVirtualKeyForToken(tokens[index]);
                results.Add(SendKeyPair(modifier, false, scanCode, 0));
            }
            return results.ToArray();
        }

        public static KeyOutcome[] SendTextAsUnicode(string text, int delayMs)
        {
            List<KeyOutcome> results = new List<KeyOutcome>();
            if (string.IsNullOrEmpty(text)) { return results.ToArray(); }
            for (int index = 0; index < text.Length; index++)
            {
                results.Add(SendUnicodeChar(text[index], delayMs));
            }
            return results.ToArray();
        }

        // ------------------------------------------------------------------
        // Preflight
        // ------------------------------------------------------------------
        public static PreflightRecord CapturePreflight()
        {
            PreflightRecord record = new PreflightRecord();
            record.ProcessId = GetCurrentProcessId();
            record.ThreadId = GetCurrentThreadId();
            uint sessionId = 0;
            if (!ProcessIdToSessionId((uint)record.ProcessId, out sessionId))
            {
                sessionId = 0;
            }
            record.SessionId = sessionId;
            record.Is64BitProcess = Environment.Is64BitProcess ? 1 : 0;

            record.WindowStation = GetUserObjectName(GetProcessWindowStation(), out record.WindowStationError);
            record.Desktop = GetUserObjectName(GetThreadDesktop(record.ThreadId), out record.DesktopError);

            IntPtr token = IntPtr.Zero;
            if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_QUERY_INFORMATION, out token) && token != IntPtr.Zero)
            {
                int returned = 0;
                IntPtr buffer = Marshal.AllocHGlobal(2048);
                try
                {
                    if (GetTokenInformation(token, TokenIntegrityLevel, buffer, 2048, out returned) && returned >= Marshal.SizeOf(typeof(TOKEN_MANDATORY_LABEL)))
                    {
                        TOKEN_MANDATORY_LABEL label = (TOKEN_MANDATORY_LABEL)Marshal.PtrToStructure(buffer, typeof(TOKEN_MANDATORY_LABEL));
                        IntPtr stringSid = IntPtr.Zero;
                        if (ConvertSidToStringSidW(label.Label.Sid, out stringSid) && stringSid != IntPtr.Zero)
                        {
                            record.IntegritySid = Marshal.PtrToStringUni(stringSid);
                            record.IntegrityLevel = ParseIntegrityRid(record.IntegritySid);
                            LocalFree(stringSid);
                        }
                        else
                        {
                            record.IntegrityError = LastErrorCode();
                        }
                    }
                    else
                    {
                        record.IntegrityError = LastErrorCode();
                    }

                    returned = 0;
                    if (GetTokenInformation(token, TokenElevation, IntPtr.Zero, 0, out returned) && returned >= Marshal.SizeOf(typeof(TOKEN_ELEVATION)))
                    {
                        IntPtr elevationBuffer = Marshal.AllocHGlobal(returned);
                        try
                        {
                            if (GetTokenInformation(token, TokenElevation, elevationBuffer, returned, out returned))
                            {
                                TOKEN_ELEVATION elevation = (TOKEN_ELEVATION)Marshal.PtrToStructure(elevationBuffer, typeof(TOKEN_ELEVATION));
                                record.IsElevated = elevation.TokenIsElevated != 0;
                                record.ElevationType = record.IsElevated ? "elevated" : "medium-integrity-unelevated";
                            }
                        }
                        finally { Marshal.FreeHGlobal(elevationBuffer); }
                    }

                    // TokenUIAccess is not a documented cross-process query and is
                    // usually unavailable. When it is readable it is recorded, but
                    // the reported method is the manifest declaration scan.
                    returned = 0;
                    if (GetTokenInformation(token, TokenUIAccess, IntPtr.Zero, 0, out returned) && returned > 0)
                    {
                        IntPtr uiBuffer = Marshal.AllocHGlobal(returned);
                        try
                        {
                            if (GetTokenInformation(token, TokenUIAccess, uiBuffer, returned, out returned))
                            {
                                record.UiAccess = Marshal.ReadInt32(uiBuffer);
                                record.UiAccessMethod = "token-UIAccess-flag(readable)";
                            }
                        }
                        finally { Marshal.FreeHGlobal(uiBuffer); }
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                    CloseHandle(token);
                }
            }
            else
            {
                record.IntegrityError = LastErrorCode();
            }

            DpiRecord dpi = GetDpiRecord();
            record.DpiAwareness = dpi.ProcessAwarenessName;
            record.DpiAwarenessDetail = dpi.Method;

            IntPtr foreground = GetForegroundWindow();
            record.ForegroundHwnd = foreground.ToInt64();
            uint foregroundProcess = 0;
            GetWindowThreadProcessId(foreground, out foregroundProcess);
            record.ForegroundProcessId = foregroundProcess;
            record.ForegroundClass = foreground == IntPtr.Zero ? "" : GetClassNameSafe(foreground);
            record.ForegroundTitle = foreground == IntPtr.Zero ? "" : GetWindowTextSafe(foreground);
            record.ForegroundProcessName = foreground == IntPtr.Zero ? "" : ProcessNameOf(foregroundProcess);
            return record;
        }

        // DPI APIs are resolved dynamically so the harness still runs, and still
        // reports "unknown", on a Windows build that does not export them.
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        internal delegate int GetProcessDpiAwarenessDelegate(IntPtr process, out int awareness);

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        internal delegate IntPtr GetThreadDpiAwarenessContextDelegate();

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        internal delegate int GetAwarenessFromDpiAwarenessContextDelegate(IntPtr context);

        public static DpiRecord GetDpiRecord()
        {
            DpiRecord record = new DpiRecord();
            List<string> methods = new List<string>();

            IntPtr shcore = GetModuleHandleW("shcore.dll");
            if (shcore != IntPtr.Zero)
            {
                IntPtr address = GetProcAddress(shcore, "GetProcessDpiAwareness");
                if (address != IntPtr.Zero)
                {
                    int awareness = -1;
                    GetProcessDpiAwarenessDelegate probe = (GetProcessDpiAwarenessDelegate)Marshal.GetDelegateForFunctionPointer(address, typeof(GetProcessDpiAwarenessDelegate));
                    int hr = probe(GetCurrentProcess(), out awareness);
                    if (hr == 0)
                    {
                        record.Ok = true;
                        record.ProcessAwareness = awareness;
                        record.ProcessAwarenessName = DpiAwarenessName(awareness);
                        methods.Add("shcore!GetProcessDpiAwareness");
                    }
                }
            }

            IntPtr user32 = GetModuleHandleW("user32.dll");
            if (user32 != IntPtr.Zero)
            {
                IntPtr contextAddress = GetProcAddress(user32, "GetThreadDpiAwarenessContext");
                IntPtr nameAddress = GetProcAddress(user32, "GetAwarenessFromDpiAwarenessContext");
                if (contextAddress != IntPtr.Zero && nameAddress != IntPtr.Zero)
                {
                    GetThreadDpiAwarenessContextDelegate getContext = (GetThreadDpiAwarenessContextDelegate)Marshal.GetDelegateForFunctionPointer(contextAddress, typeof(GetThreadDpiAwarenessContextDelegate));
                    GetAwarenessFromDpiAwarenessContextDelegate getName = (GetAwarenessFromDpiAwarenessContextDelegate)Marshal.GetDelegateForFunctionPointer(nameAddress, typeof(GetAwarenessFromDpiAwarenessContextDelegate));
                    IntPtr context = getContext();
                    int awareness = getName(context);
                    record.AwarenessContext = context.ToInt64();
                    record.ThreadAwareness = awareness;
                    record.ThreadAwarenessName = DpiAwarenessName(awareness);
                    if (methods.Count == 0) { record.Ok = true; }
                    methods.Add("user32!GetThreadDpiAwarenessContext");
                }
            }

            record.Method = methods.Count == 0 ? "unavailable on this Windows build" : string.Join(", ", methods.ToArray());
            return record;
        }

        private static string DpiAwarenessName(int awareness)
        {
            switch (awareness)
            {
                case 0: return "unaware";
                case 1: return "system";
                case 2: return "per-monitor";
                default: return "unknown";
            }
        }

        // The target thread's desktop and window station. A mismatch against the
        // injector's own values is surfaced by the run script as a named finding,
        // because it is the most likely cause of silent total delivery failure.
        public static TargetThreadRecord CaptureTargetThread(long hwnd)
        {
            TargetThreadRecord record = new TargetThreadRecord();
            record.Hwnd = hwnd;
            uint processId = 0;
            uint threadId = GetWindowThreadProcessId(new IntPtr(hwnd), out processId);
            record.ProcessId = processId;
            record.ThreadId = threadId;
            record.WindowStation = GetUserObjectName(GetProcessWindowStation(), out record.WindowStationError);
            if (threadId == 0)
            {
                record.Desktop = "unavailable: the window has no owning thread";
                record.DesktopError = 0;
                return record;
            }
            record.Desktop = GetUserObjectName(GetThreadDesktop(threadId), out record.DesktopError);
            return record;
        }

        public static WindowRecord GetWindowThreadInfo(long hwnd)
        {
            return DescribeWindow(new IntPtr(hwnd), true);
        }

        // ------------------------------------------------------------------
        // Enumeration
        // ------------------------------------------------------------------
        public static WindowRecord[] EnumerateWindows(bool visibleOnly)
        {
            List<WindowRecord> records = new List<WindowRecord>();
            EnumWindowsProc callback = delegate(IntPtr hWnd, IntPtr lParam)
            {
                if (visibleOnly && !IsWindowVisible(hWnd)) { return true; }
                records.Add(DescribeWindow(hWnd, true));
                return true;
            };
            bool ok = EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            if (!ok)
            {
                WindowRecord failure = new WindowRecord();
                failure.ClassName = "<EnumWindows failed>";
                failure.Title = "error " + LastErrorCode();
                records.Add(failure);
            }
            return records.ToArray();
        }

        public static WindowRecord[] EnumerateChildWindows(long parent)
        {
            List<WindowRecord> records = new List<WindowRecord>();
            if (parent == 0) { return records.ToArray(); }
            EnumWindowsProc callback = delegate(IntPtr hWnd, IntPtr lParam)
            {
                records.Add(DescribeWindow(hWnd, false));
                return true;
            };
            bool ok = EnumChildWindows(new IntPtr(parent), callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            if (!ok)
            {
                WindowRecord failure = new WindowRecord();
                failure.ClassName = "<EnumChildWindows failed>";
                failure.Title = "error " + LastErrorCode();
                records.Add(failure);
            }
            return records.ToArray();
        }

        public static ModuleRecord[] GetLoadedModules(uint processId)
        {
            List<ModuleRecord> modules = new List<ModuleRecord>();
            IntPtr process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, processId);
            if (process == IntPtr.Zero)
            {
                ModuleRecord failure = new ModuleRecord();
                failure.Name = "<OpenProcess failed>";
                failure.Path = "error " + LastErrorCode();
                modules.Add(failure);
                return modules.ToArray();
            }
            try
            {
                IntPtr[] buffer = new IntPtr[2048];
                uint needed = 0;
                if (!EnumProcessModulesEx(process, buffer, (uint)(buffer.Length * IntPtr.Size), LIST_MODULES_ALL, out needed))
                {
                    ModuleRecord failure = new ModuleRecord();
                    failure.Name = "<EnumProcessModulesEx failed>";
                    failure.Path = "error " + LastErrorCode();
                    modules.Add(failure);
                    return modules.ToArray();
                }
                int count = (int)(needed / (uint)IntPtr.Size);
                if (count > buffer.Length) { count = buffer.Length; }
                for (int index = 0; index < count; index++)
                {
                    StringBuilder path = new StringBuilder(1024);
                    StringBuilder name = new StringBuilder(256);
                    GetModuleFileNameExW(process, buffer[index], path, path.Capacity);
                    GetModuleBaseNameW(process, buffer[index], name, name.Capacity);
                    ModuleRecord module = new ModuleRecord();
                    module.Name = name.ToString();
                    module.Path = path.ToString();
                    modules.Add(module);
                }
            }
            finally
            {
                CloseHandle(process);
            }
            return modules.ToArray();
        }

        public static CaretRecord GetCaretRecord(uint threadId)
        {
            CaretRecord record = new CaretRecord();
            GUITHREADINFO info = new GUITHREADINFO();
            info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
            if (!GetGUIThreadInfo(threadId, ref info))
            {
                record.Ok = false;
                record.LastError = LastErrorCode();
                return record;
            }
            record.Ok = true;
            record.ActiveHwnd = info.hwndActive.ToInt64();
            record.FocusHwnd = info.hwndFocus.ToInt64();
            record.CaptureHwnd = info.hwndCapture.ToInt64();
            record.CaretHwnd = info.hwndCaret.ToInt64();
            record.CaretLeft = info.rcCaret.Left;
            record.CaretTop = info.rcCaret.Top;
            record.CaretRight = info.rcCaret.Right;
            record.CaretBottom = info.rcCaret.Bottom;
            return record;
        }

        public static LastInputRecord GetLastInputRecord()
        {
            LastInputRecord record = new LastInputRecord();
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            record.TickCount = (uint)Environment.TickCount;
            if (!GetLastInputInfo(ref info))
            {
                record.Ok = false;
                record.LastError = LastErrorCode();
                return record;
            }
            record.Ok = true;
            record.LastInputTick = info.dwTime;
            return record;
        }

        // Only meaningful for a window owned by the calling thread. The run script
        // restricts this to the harness's own loopback window: there is no honest
        // cross-process way to read another app's IME open/closed state, and the
        // receipt says exactly that rather than guessing.
        public static ImmRecord GetImmRecord(long hwnd)
        {
            ImmRecord record = new ImmRecord();
            IntPtr context = ImmGetContext(new IntPtr(hwnd));
            if (context == IntPtr.Zero)
            {
                record.Ok = false;
                record.LastError = LastErrorCode();
                return record;
            }
            try
            {
                record.Ok = true;
                record.Open = ImmGetOpenStatus(context);
                StringBuilder name = new StringBuilder(256);
                ImmGetContextNameW(context, name, name.Capacity);
                record.ContextName = name.ToString();
            }
            finally
            {
                ImmReleaseContext(context);
            }
            return record;
        }

        // ------------------------------------------------------------------
        // Focus
        // ------------------------------------------------------------------
        public static WindowRecord GetForegroundRecord()
        {
            return DescribeWindow(GetForegroundWindow(), true);
        }

        public static bool ForceForeground(long hwnd, int settleMs)
        {
            IntPtr target = new IntPtr(hwnd);
            if (hwnd == 0 || !IsWindow(target)) { return false; }
            ShowWindow(target, SW_RESTORE);
            BringWindowToTop(target);

            IntPtr foreground = GetForegroundWindow();
            uint ignoredProcess = 0;
            uint foregroundThread = GetWindowThreadProcessId(foreground, out ignoredProcess);
            uint currentThread = GetCurrentThreadId();
            bool attached = false;
            if (foregroundThread != 0 && foregroundThread != currentThread)
            {
                attached = AttachThreadInput(currentThread, foregroundThread, true);
            }
            try
            {
                SetForegroundWindow(target);
                SetFocus(target);
            }
            finally
            {
                if (attached) { AttachThreadInput(currentThread, foregroundThread, false); }
            }
            if (settleMs > 0) { System.Threading.Thread.Sleep(settleMs); }
            return GetForegroundWindow() == target;
        }

        public static WindowRecord ShowLoopback(long hwnd)
        {
            ShowWindow(new IntPtr(hwnd), SW_SHOW);
            PumpMessages(80);
            return DescribeWindow(new IntPtr(hwnd), true);
        }

        public static bool IsWindowAlive(long hwnd)
        {
            return hwnd != 0 && IsWindow(new IntPtr(hwnd));
        }

        // Closes a window only when the harness's own registered window class
        // matches, so cleanup can never reach a window it did not create.
        public static bool CloseWindowIfOwned(long hwnd, string requiredClassName)
        {
            if (hwnd == 0 || !IsWindow(new IntPtr(hwnd))) { return false; }
            if (string.IsNullOrEmpty(requiredClassName)) { return false; }
            if (GetClassNameSafe(new IntPtr(hwnd)) != requiredClassName) { return false; }
            IntPtr result;
            SendMessageTimeoutW(new IntPtr(hwnd), WM_CLOSE, IntPtr.Zero, null, SMTO_ABORTIFHUNG, 2000, out result);
            PumpMessages(120);
            return !IsWindow(new IntPtr(hwnd));
        }

        public static string SendWindowTextRequest(long hwnd, int timeoutMs)
        {
            if (hwnd == 0) { return string.Empty; }
            // SendMessageTimeoutW returns an LRESULT, not a BOOL: a zero result
            // means the target did not answer in time, which is not the same as
            // an empty document.
            IntPtr result;
            int capacity = 8192;
            StringBuilder buffer = new StringBuilder(capacity);
            IntPtr answered = SendMessageTimeoutW(new IntPtr(hwnd), WM_GETTEXT, (IntPtr)capacity, buffer, SMTO_ABORTIFHUNG, (uint)timeoutMs, out result);
            if (answered == IntPtr.Zero) { return string.Empty; }
            return buffer.ToString();
        }

        // ------------------------------------------------------------------
        // Harness-owned loopback window.
        //
        // Purpose: prove that this session processes SendInput at all, using a
        // readback that is completely independent of the injection API. If the
        // canary does not appear here, every later step against any target is
        // inconclusive, and the receipt must say so instead of blaming the IME.
        // ------------------------------------------------------------------
        private static IntPtr loopbackWindow = IntPtr.Zero;
        private static IntPtr loopbackEdit = IntPtr.Zero;
        private static WndProcDelegate loopbackProc = null;

        private static IntPtr LoopbackWndProc(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam)
        {
            switch (message)
            {
                case WM_SETFOCUS:
                    if (loopbackEdit != IntPtr.Zero) { SetFocus(loopbackEdit); }
                    return IntPtr.Zero;
                case WM_SIZE:
                    if (loopbackEdit != IntPtr.Zero)
                    {
                        long packed = lParam.ToInt64();
                        int width = (int)(packed & 0xFFFF);
                        int height = (int)((packed >> 16) & 0xFFFF);
                        MoveWindow(loopbackEdit, 8, 8, Math.Max(width - 24, 10), Math.Max(height - 40, 10), true);
                    }
                    return IntPtr.Zero;
                case WM_DESTROY:
                    PostQuitMessage(0);
                    return IntPtr.Zero;
                default:
                    return DefWindowProc(hWnd, message, wParam, lParam);
            }
        }

        public static long CreateLoopbackWindow(string title, int width, int height)
        {
            if (loopbackWindow != IntPtr.Zero) { return loopbackWindow.ToInt64(); }
            loopbackProc = new WndProcDelegate(LoopbackWndProc);

            WNDCLASSEX windowClass = new WNDCLASSEX();
            windowClass.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX));
            windowClass.style = 0x0003;
            windowClass.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(loopbackProc);
            windowClass.hInstance = GetModuleHandleW(null);
            windowClass.lpszClassName = LoopbackClassName;
            ushort atom = RegisterClassExW(ref windowClass);
            if (atom == 0 && LastErrorCode() != 1410)
            {
                return 0;
            }

            loopbackWindow = CreateWindowExW(
                0,
                LoopbackClassName,
                string.IsNullOrEmpty(title) ? "KanaAI injector loopback" : title,
                WS_OVERLAPPEDWINDOW,
                80, 80, width, height,
                IntPtr.Zero, IntPtr.Zero, windowClass.hInstance, IntPtr.Zero);
            if (loopbackWindow == IntPtr.Zero) { return 0; }

            loopbackEdit = CreateWindowExW(
                0,
                "EDIT",
                string.Empty,
                WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN,
                8, 8, Math.Max(width - 24, 10), Math.Max(height - 40, 10),
                loopbackWindow, new IntPtr(LoopbackEditId), windowClass.hInstance, IntPtr.Zero);
            if (loopbackEdit == IntPtr.Zero)
            {
                DestroyWindow(loopbackWindow);
                loopbackWindow = IntPtr.Zero;
                return 0;
            }
            GC.KeepAlive(loopbackProc);
            PumpMessages(150);
            return loopbackWindow.ToInt64();
        }

        public static long GetLoopbackEditHwnd()
        {
            return loopbackEdit.ToInt64();
        }

        public static void PumpMessages(int milliseconds)
        {
            int deadline = Environment.TickCount + (milliseconds < 0 ? 0 : milliseconds);
            MSG message;
            do
            {
                while (PeekMessage(out message, IntPtr.Zero, 0, 0, 0))
                {
                    TranslateMessage(ref message);
                    DispatchMessage(ref message);
                }
                System.Threading.Thread.Sleep(10);
            }
            while (Environment.TickCount < deadline);
        }

        public static string GetLoopbackText()
        {
            if (loopbackEdit == IntPtr.Zero) { return string.Empty; }
            return GetWindowTextSafe(loopbackEdit);
        }

        public static bool ShowLoopbackAndFocusEdit()
        {
            if (loopbackWindow == IntPtr.Zero || loopbackEdit == IntPtr.Zero) { return false; }
            ShowWindow(loopbackWindow, SW_SHOW);
            BringWindowToTop(loopbackWindow);
            SetFocus(loopbackEdit);
            PumpMessages(150);
            return loopbackWindow == GetForegroundWindow();
        }

        public static bool DestroyLoopbackWindow()
        {
            if (loopbackWindow == IntPtr.Zero) { return true; }
            DestroyWindow(loopbackWindow);
            PumpMessages(200);
            loopbackWindow = IntPtr.Zero;
            loopbackEdit = IntPtr.Zero;
            return true;
        }

        // ------------------------------------------------------------------
        // UIAccess
        // ------------------------------------------------------------------
        // Windows exposes no supported Win32 query for "is this process
        // UIAccess", so the harness reports the manifest declaration found in the
        // given executable and always states how it was determined. -1 means the
        // question could not be answered and must not be read as "no".
        public static int GetManifestUiAccessFlag(string executablePath)
        {
            if (string.IsNullOrEmpty(executablePath)) { return -1; }
            try
            {
                if (!System.IO.File.Exists(executablePath)) { return -1; }
                byte[] bytes = System.IO.File.ReadAllBytes(executablePath);
                string text = Encoding.ASCII.GetString(bytes);
                int index = text.IndexOf("uiAccess", StringComparison.OrdinalIgnoreCase);
                if (index < 0) { return 0; }
                int valueIndex = index + "uiAccess".Length;
                while (valueIndex < text.Length && (text[valueIndex] == '"' || text[valueIndex] == ' ' || text[valueIndex] == '=')) { valueIndex++; }
                if (valueIndex < text.Length && (text[valueIndex] == 't' || text[valueIndex] == 'T')) { return 1; }
                if (valueIndex < text.Length && (text[valueIndex] == 'f' || text[valueIndex] == 'F')) { return 0; }
                return -1;
            }
            catch (Exception)
            {
                return -1;
            }
        }
    }
}
