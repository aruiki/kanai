// KanaAI desktop validation harness - the target application.
//
// This is a real, separate Win32 process with a real multiline EDIT control, so
// Windows routes text services to it exactly the way it does for a classic
// Win32 editor: no TSF calls, no IMM32 calls, no opting in or out of anything.
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
        private const int SW_SHOW = 5;

        private static IntPtr mainWindow = IntPtr.Zero;
        private static IntPtr editControl = IntPtr.Zero;
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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern ushort RegisterClassExW(ref WNDCLASSEX windowClass);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr GetModuleHandleW(string moduleName);

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

        private static void WriteState(string phase)
        {
            if (string.IsNullOrEmpty(statePath)) { return; }
            try
            {
                StringBuilder builder = new StringBuilder();
                builder.Append("{");
                builder.Append("\"schemaVersion\":1,");
                builder.Append("\"phase\":\"").Append(JsonEscape(phase)).Append("\",");
                builder.Append("\"runId\":\"").Append(JsonEscape(runId)).Append("\",");
                builder.Append("\"processId\":").Append(GetCurrentProcessIdValue()).Append(",");
                builder.Append("\"threadId\":").Append(GetCurrentThreadId()).Append(",");
                builder.Append("\"hwnd\":").Append(mainWindow.ToInt64()).Append(",");
                builder.Append("\"editHwnd\":").Append(editControl.ToInt64()).Append(",");
                builder.Append("\"windowClass\":\"").Append(JsonEscape(WindowClass)).Append("\",");
                builder.Append("\"editClass\":\"EDIT\",");
                builder.Append("\"textAtPhase\":\"").Append(JsonEscape(ReadEditText())).Append("\",");
                builder.Append("\"modules\":[");
                List<string> modules = LoadedModulePaths();
                for (int index = 0; index < modules.Count; index++)
                {
                    if (index > 0) { builder.Append(','); }
                    builder.Append('"').Append(JsonEscape(modules[index])).Append('"');
                }
                builder.Append("]");
                builder.Append("}");
                string directory = Path.GetDirectoryName(Path.GetFullPath(statePath));
                if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory)) { Directory.CreateDirectory(directory); }
                File.WriteAllText(statePath, builder.ToString(), new UTF8Encoding(false));
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

        [STAThread]
        private static int Main(string[] args)
        {
            int width = 720;
            int height = 260;
            for (int index = 0; index < args.Length - 1; index++)
            {
                if (args[index] == "--state") { statePath = args[index + 1]; }
                else if (args[index] == "--runid") { runId = args[index + 1]; }
                else if (args[index] == "--width") { int parsed; if (int.TryParse(args[index + 1], out parsed)) { width = parsed; } }
                else if (args[index] == "--height") { int parsed; if (int.TryParse(args[index + 1], out parsed)) { height = parsed; } }
            }
            if (string.IsNullOrEmpty(runId)) { runId = "no-runid"; }

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
                "EDIT",
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
