// Native TSF activation probe.
//
// Loads a TIP DLL exactly the way TSF does (LoadLibrary + DllGetClassObject for
// the text service CLSID) and then drives a real ITfTextInputProcessor
// lifecycle against a real ITfThreadMgr: Activate -> Deactivate. It does not
// read or write the TSF registry, so it can run without elevation and it never
// claims that a TIP is installed.
//
// Exit codes: 0 = every step succeeded, 10 = could not create/activate the
// thread manager, 11 = the TIP DLL could not be loaded, 12 = DllGetClassObject
// failed, 13 = the class factory could not create the text service, 14 =
// Activate failed, 15 = Deactivate failed, 2 = bad usage.
using System;
using System.Globalization;
using System.Runtime.InteropServices;

internal static class TipActivationProbe
{
    private const uint LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x00000100;
    private const uint LOAD_LIBRARY_SEARCH_DEFAULT_DIRS = 0x00001000;
    private const uint COINIT_APARTMENTTHREADED = 0x2;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibraryExW(string fileName, IntPtr file, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr module);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, uint coinit);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();

    [DllImport("msctf.dll")]
    private static extern int TF_CreateLangBarItemMgr(out IntPtr itemManager);

    [DllImport("msctf.dll")]
    private static extern int TF_CreateLangBarMgr(out IntPtr langBarManager);

    // Returns the thread manager TSF associates with the calling thread, as
    // opposed to a private CoCreateInstance(CLSID_TF_ThreadMgr) copy.
    [DllImport("msctf.dll")]
    private static extern int TF_GetThreadMgr(out IntPtr threadMgr);

    private static readonly Guid IidKeystrokeMgr = new Guid("aa80e7f0-2021-11d2-93e0-0060b067b86e");
    private static readonly Guid IidCompartmentMgr = new Guid("7dcf57ac-18ad-438b-824d-979bffb74b7c");
    private static readonly Guid IidSource = new Guid("4ea48a35-60ae-446f-8fd6-e6a8d82459f7");
    private static readonly Guid IidTextInputProcessor = new Guid("aa80e7f7-2021-11d2-93e0-0060b067b86e");
    private static readonly Guid IidClassFactory = new Guid("00000001-0000-0000-c000-000000000046");
    private static readonly Guid IidLangBarItemMgr = new Guid("a781718c-579a-4b15-a280-32b8577acc5e");

    // The system language bar help menu GUID used by Mozc's InitLangBar.
    private static readonly Guid SystemLangBarHelpMenu = new Guid("ED9D5450-EBE6-4255-8289-F8A31E687228");

    // Mirrors the exact TSF calls that TipTextServiceImpl::ActivateEx makes in
    // InitLanguageBar() and InitKeyEventSink(), the only two code paths that
    // propagate a failed HRESULT all the way out of Activate(). Reporting each
    // call separately localizes which TSF call rejects the activation.

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int DllGetClassObjectDelegate(ref Guid clsid, ref Guid iid, out IntPtr ppv);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int DllCanUnloadNowDelegate();

    [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)]
    private delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WndClassEx
    {
        public uint cbSize;
        public uint style;
        public WndProc lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassEx(ref WndClassEx wndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(uint exStyle, string className, string windowName,
        uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu,
        IntPtr instance, IntPtr param);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DefWindowProcW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr hwnd);

    // Kept alive for the lifetime of the process so the native window class
    // never points at a collected delegate.
    private static WndProc keepAliveWndProc = ProbeWndProc;

    private static IntPtr ProbeWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    // Creates a message-only window on the calling thread. TSF associates
    // keyboard state with a thread's window queue, so a thread without any
    // window can be rejected by ITfKeystrokeMgr even when every TSF call
    // before it succeeds.
    private static IntPtr CreateProbeWindow()
    {
        WndClassEx wndClass = new WndClassEx();
        wndClass.cbSize = (uint)Marshal.SizeOf(typeof(WndClassEx));
        wndClass.lpfnWndProc = keepAliveWndProc;
        wndClass.hInstance = Marshal.GetHINSTANCE(typeof(TipActivationProbe).Module);
        wndClass.lpszClassName = "KanaAI.TipActivationProbe." + GetCurrentProcessId();
        if (RegisterClassEx(ref wndClass) == 0)
        {
            int error = Marshal.GetLastWin32Error();
            if (error != 1410) // ERROR_CLASS_ALREADY_EXISTS
            {
                Report("probeRegisterClass", Format(unchecked((int)(0x80070000 | error))));
                return IntPtr.Zero;
            }
        }
        return CreateWindowExW(0, wndClass.lpszClassName, string.Empty, 0,
            0, 0, 0, 0, new IntPtr(-3) /* HWND_MESSAGE */, IntPtr.Zero,
            wndClass.hInstance, IntPtr.Zero);
    }

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentProcessId();

    [ComImport, Guid("529a9e6b-6587-4f23-ab9e-9c7d683e3c50")]
    private class ThreadMgrClass
    {
    }

    // Vtable order matches msctf.h: Activate, Deactivate, CreateDocumentMgr,
    // EnumDocumentMgrs, GetFocus, SetFocus. Only pointers are declared, which
    // is ABI-compatible for every slot used here.
    [ComImport, Guid("aa80e801-2021-11d2-93e0-0060b067b86e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITfThreadMgr
    {
        [PreserveSig]
        int Activate(out uint clientId);

        [PreserveSig]
        int Deactivate();

        [PreserveSig]
        int CreateDocumentMgr(out IntPtr documentMgr);

        [PreserveSig]
        int EnumDocumentMgrs(out IntPtr enumerator);

        [PreserveSig]
        int GetFocus(out IntPtr documentMgr);

        [PreserveSig]
        int SetFocus(IntPtr documentMgr);
    }

    [ComImport, Guid("aa80e7f7-2021-11d2-93e0-0060b067b86e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITfTextInputProcessor
    {
        [PreserveSig]
        int Activate(ITfThreadMgr threadMgr, uint clientId);

        [PreserveSig]
        int Deactivate();
    }

    [ComImport, Guid("00000001-0000-0000-c000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IClassFactory
    {
        [PreserveSig]
        int CreateInstance([MarshalAs(UnmanagedType.IUnknown)] object outer, ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object instance);

        [PreserveSig]
        int LockServer([MarshalAs(UnmanagedType.Bool)] bool @lock);
    }

    // Vtable order matches ctfutb.h: EnumItems then GetItem. Only the slots
    // the probe actually calls are declared.
    [ComImport, Guid("ba468c55-9956-4fb1-a59d-52a7dd7cc6aa"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITfLangBarItemMgr
    {
        [PreserveSig]
        int EnumItems(out IntPtr enumerator);

        [PreserveSig]
        int GetItem(ref Guid guid, out IntPtr item);
    }

    // Vtable order matches msctf.h: AdviseKeyEventSink, UnadviseKeyEventSink,
    // GetForeground, TestKeyDown, TestKeyUp, KeyDown, KeyUp, GetPreservedKey,
    // IsPreservedKey, PreserveKey, UnpreserveKey.
    [ComImport, Guid("aa80e7f0-2021-11d2-93e0-0060b067b86e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITfKeystrokeMgrNative
    {
        [PreserveSig]
        int AdviseKeyEventSink(uint clientId, [MarshalAs(UnmanagedType.Interface)] ITfKeyEventSink sink, [MarshalAs(UnmanagedType.Bool)] bool foreground);

        [PreserveSig]
        int UnadviseKeyEventSink(uint clientId);

        [PreserveSig]
        int GetForeground(out Guid clsid);

        [PreserveSig]
        int TestKeyDown(IntPtr wParam, IntPtr lParam, out int eaten);

        [PreserveSig]
        int TestKeyUp(IntPtr wParam, IntPtr lParam, out int eaten);

        [PreserveSig]
        int KeyDown(IntPtr wParam, IntPtr lParam, out int eaten);

        [PreserveSig]
        int KeyUp(IntPtr wParam, IntPtr lParam, out int eaten);

        [PreserveSig]
        int GetPreservedKey(IntPtr context, ref TF_PRESERVEDKEY key, out Guid guid);

        [PreserveSig]
        int IsPreservedKey(ref Guid guid, ref TF_PRESERVEDKEY key, out int preserved);

        [PreserveSig]
        int PreserveKey(uint clientId, ref Guid guid, ref TF_PRESERVEDKEY key,
            [MarshalAs(UnmanagedType.LPWStr)] string description, uint descriptionLength);

        [PreserveSig]
        int UnpreserveKey(ref Guid guid, ref TF_PRESERVEDKEY key);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TF_PRESERVEDKEY
    {
        public uint uVKey;
        public uint uModifiers;
    }

    // Vtable order matches msctf.h ITfSource: AdviseSink then UnadviseSink.
    [ComImport, Guid("4ea48a35-60ae-446f-8fd6-e6a8d82459f7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITfSourceNative
    {
        [PreserveSig]
        int AdviseSink(ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] object sink, out uint cookie);

        [PreserveSig]
        int UnadviseSink(uint cookie);
    }

    // Single method of msctf.h ITfClientId: GetClientId(REFCLSID, TfClientId*).
    [ComImport, Guid("d60a7b49-1b9f-4be2-b702-47e9dc05dec3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITfClientIdNative
    {
        [PreserveSig]
        int GetClientId(ref Guid clsid, out uint clientId);
    }

    // Implemented by this probe, so it must not be ComImport. The member order
    // must match msctf.h ITfKeyEventSink exactly.
    [Guid("aa80e7f5-2021-11d2-93e0-0060b067b86e")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [ComVisible(true)]
    private interface ITfKeyEventSink
    {
        [PreserveSig]
        int OnSetFocus(int foreground);

        [PreserveSig]
        int OnTestKeyDown(IntPtr context, IntPtr wParam, IntPtr lParam, out int eaten);

        [PreserveSig]
        int OnTestKeyUp(IntPtr context, IntPtr wParam, IntPtr lParam, out int eaten);

        [PreserveSig]
        int OnKeyDown(IntPtr context, IntPtr wParam, IntPtr lParam, out int eaten);

        [PreserveSig]
        int OnKeyUp(IntPtr context, IntPtr wParam, IntPtr lParam, out int eaten);

        [PreserveSig]
        int OnPreservedKey(IntPtr context, ref Guid guid, out int eaten);
    }

    // Implemented by this probe. Member order matches ctfutb.h
    // ITfSystemLangBarItemSink: InitMenu then OnMenuSelect.
    [Guid("1449d9ab-13cf-4687-aa3e-8d8b18574396")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [ComVisible(true)]
    private interface ITfSystemLangBarItemSink
    {
        [PreserveSig]
        int InitMenu(IntPtr menu);

        [PreserveSig]
        int OnMenuSelect(uint id);
    }

    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    private sealed class KeyEventSink : ITfKeyEventSink
    {
        public int OnSetFocus(int foreground) { return 0; }
        public int OnTestKeyDown(IntPtr context, IntPtr wParam, IntPtr lParam, out int eaten) { eaten = 0; return 0; }
        public int OnTestKeyUp(IntPtr context, IntPtr wParam, IntPtr lParam, out int eaten) { eaten = 0; return 0; }
        public int OnKeyDown(IntPtr context, IntPtr wParam, IntPtr lParam, out int eaten) { eaten = 0; return 0; }
        public int OnKeyUp(IntPtr context, IntPtr wParam, IntPtr lParam, out int eaten) { eaten = 0; return 0; }
        public int OnPreservedKey(IntPtr context, ref Guid guid, out int eaten) { eaten = 0; return 0; }
    }

    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    private sealed class SystemLangBarItemSink : ITfSystemLangBarItemSink
    {
        public int InitMenu(IntPtr menu) { return 0; }
        public int OnMenuSelect(uint id) { return 0; }
    }

    private static string Format(int hr)
    {
        return string.Format(CultureInfo.InvariantCulture, "0x{0:X8}", hr);
    }

    private static void Report(string key, string value)
    {
        Console.WriteLine("{0}={1}", key, value);
    }

    // Reports the TSF services this process can obtain. A failure here is an
    // environment limitation of the probe process, not of the TIP DLL, and it
    // is recorded so a non-S_OK Activate can be interpreted correctly.
    //
    // The InitLangBar()/InitKeyEventSink() mirrors matter because they are the
    // only two ActivateEx() paths that return a failed HRESULT directly; every
    // other failure is laundered through Deactivate(), which returns S_OK. If
    // textInputProcessorActivate fails with E_INVALIDARG, one of these mirrored
    // calls is expected to reproduce the same code.
    //
    // Returns the client id the probe should hand to
    // ITfTextInputProcessor::Activate(): a text-service id bound to the TIP
    // CLSID when one can be obtained, otherwise the plain application id from
    // ITfThreadMgr::Activate(). A real TSF host passes a CLSID-bound id, so
    // this mirrors production activation instead of the probe's own app id.
    private static uint DiagnoseTsf(ITfThreadMgr threadMgr, uint clientId, Guid textServiceClsid)
    {
        IntPtr itemManager = IntPtr.Zero;
        Report("tfCreateLangBarItemMgr", Format(TF_CreateLangBarItemMgr(out itemManager)));
        if (itemManager != IntPtr.Zero) { Marshal.Release(itemManager); }

        IntPtr langBarManager = IntPtr.Zero;
        Report("tfCreateLangBarMgr", Format(TF_CreateLangBarMgr(out langBarManager)));
        if (langBarManager != IntPtr.Zero) { Marshal.Release(langBarManager); }

        Report("queryInterfaceITfKeystrokeMgr", Format(QueryInterface(threadMgr, IidKeystrokeMgr)));
        Report("queryInterfaceITfCompartmentMgr", Format(QueryInterface(threadMgr, IidCompartmentMgr)));
        Report("queryInterfaceITfSource", Format(QueryInterface(threadMgr, IidSource)));

        DiagnoseLanguageBarHelpMenu();
        DiagnoseKeyEventSinkAdvise(threadMgr, clientId);
        return DiagnoseTextServiceTid(threadMgr, clientId, textServiceClsid);
    }

    // Microsoft IME (Japanese), registered under
    // HKLM\SOFTWARE\Microsoft\CTF\TIP with a 0x00000411 language profile. Only
    // used as a control: a client id requested for this well-known CLSID shows
    // whether ITfClientId::GetClientId works at all on this machine, which
    // separates "our TIP is not registered" from "tid handling is broken".
    private static readonly Guid RegisteredJapaneseTipClsid =
        new Guid("03B5835F-F03C-411B-9CE2-AA23E1171E36");

    // Probes which TfClientId values ITfKeystrokeMgr accepts. A plain
    // application id from ITfThreadMgr::Activate() is expected to be rejected
    // with E_INVALIDARG because AdviseKeyEventSink must be able to map a
    // foreground sink's tid back to a text service CLSID (Wine's msctf shows
    // exactly that check: GUID_NULL clsid -> E_INVALIDARG).
    // ITfClientId::GetClientId(clsid) is the documented way to obtain a
    // CLSID-bound id. Returns the first id, if any, that accepted
    // AdviseKeyEventSink for this TIP's CLSID.
    private static uint DiagnoseTextServiceTid(ITfThreadMgr threadMgr, uint appId, Guid textServiceClsid)
    {
        uint chosen = appId;

        // --- ITfClientId::GetClientId on the probe's own thread manager. ---
        ITfClientIdNative clientIdMgr = threadMgr as ITfClientIdNative;
        Report("queryInterfaceITfClientId", Format(clientIdMgr == null ? unchecked((int)0x80004002) : 0));
        if (clientIdMgr != null)
        {
            uint ownTid = 0;
            Guid clsid = textServiceClsid;
            int hr = clientIdMgr.GetClientId(ref clsid, out ownTid);
            Report("clientIdGetOwnClsid", Format(hr) + " tid=" + ownTid);
            if (hr >= 0 && ownTid != 0 &&
                TryAdviseKeyEventSink(threadMgr, ownTid, "adviseKeyEventSinkOwnClsidTid"))
            {
                chosen = ownTid;
            }

            // Control: same call for a registered Japanese TIP.
            uint regTid = 0;
            Guid registered = RegisteredJapaneseTipClsid;
            hr = clientIdMgr.GetClientId(ref registered, out regTid);
            Report("clientIdGetRegisteredClsid", Format(hr) + " tid=" + regTid);
            if (hr >= 0 && regTid != 0)
            {
                TryAdviseKeyEventSink(threadMgr, regTid, "adviseKeyEventSinkRegisteredClsidTid");
            }
        }

        // --- TF_GetThreadMgr: the thread manager TSF itself binds to this
        // thread. If the CoCreateInstance copy is a detached instance whose
        // client ids are unknown to the keystroke manager, this differs. ---
        IntPtr systemThreadMgrPtr = IntPtr.Zero;
        int tfHr = TF_GetThreadMgr(out systemThreadMgrPtr);
        Report("tfGetThreadMgr", Format(tfHr));
        if (tfHr >= 0 && systemThreadMgrPtr != IntPtr.Zero)
        {
            object systemThreadMgrObject = null;
            try
            {
                systemThreadMgrObject = Marshal.GetObjectForIUnknown(systemThreadMgrPtr);
            }
            finally
            {
                Marshal.Release(systemThreadMgrPtr);
            }

            try
            {
                ITfThreadMgr systemThreadMgr = systemThreadMgrObject as ITfThreadMgr;
                if (systemThreadMgr == null)
                {
                    Report("tfGetThreadMgrCast", Format(unchecked((int)0x80004002)));
                }
                else
                {
                    uint systemAppTid = 0;
                    int hr = systemThreadMgr.Activate(out systemAppTid);
                    Report("tfGetThreadMgrActivate", Format(hr) + " tid=" + systemAppTid);
                    if (hr >= 0)
                    {
                        TryAdviseKeyEventSink(systemThreadMgr, systemAppTid,
                            "adviseKeyEventSinkSystemMgrAppTid");

                        ITfClientIdNative systemClientIdMgr = systemThreadMgr as ITfClientIdNative;
                        if (systemClientIdMgr != null)
                        {
                            uint systemTid = 0;
                            Guid own = textServiceClsid;
                            hr = systemClientIdMgr.GetClientId(ref own, out systemTid);
                            Report("tfGetThreadMgrClientIdOwnClsid", Format(hr) + " tid=" + systemTid);
                            if (hr >= 0 && systemTid != 0 &&
                                TryAdviseKeyEventSink(systemThreadMgr, systemTid,
                                    "adviseKeyEventSinkSystemMgrOwnTid") &&
                                chosen == appId)
                            {
                                chosen = systemTid;
                            }
                        }
                        systemThreadMgr.Deactivate();
                    }
                }
            }
            finally
            {
                Marshal.ReleaseComObject(systemThreadMgrObject);
            }
        }

        return chosen;
    }

    // Advises a foreground key event sink with the given tid and unadvises it
    // again so a successful probe does not leave a sink registered for the
    // TIP's later Activate(). Returns true on S_OK.
    private static bool TryAdviseKeyEventSink(ITfThreadMgr threadMgr, uint tid, string key)
    {
        ITfKeystrokeMgrNative keystroke = threadMgr as ITfKeystrokeMgrNative;
        if (keystroke == null)
        {
            Report(key, Format(unchecked((int)0x80004002)));
            return false;
        }
        KeyEventSink sink = new KeyEventSink();
        int hr = keystroke.AdviseKeyEventSink(tid, sink, true);
        Report(key, Format(hr));
        if (hr >= 0)
        {
            Report(key + "Unadvise", Format(keystroke.UnadviseKeyEventSink(tid)));
        }
        return hr == 0;
    }


    // Mirrors TipLangBar::InitLangBar()'s help menu block: GetItem on the
    // system language bar help menu, then AdviseSink with
    // IID_ITfSystemLangBarItemSink on the returned item.
    private static void DiagnoseLanguageBarHelpMenu()
    {
        IntPtr itemManager = IntPtr.Zero;
        int hr = TF_CreateLangBarItemMgr(out itemManager);
        if (hr < 0 || itemManager == IntPtr.Zero)
        {
            Report("langBarItemMgrCreate", Format(hr));
            return;
        }

        try
        {
            ITfLangBarItemMgr manager = (ITfLangBarItemMgr)Marshal.GetObjectForIUnknown(itemManager);
            Guid helpMenu = SystemLangBarHelpMenu;
            IntPtr item = IntPtr.Zero;
            hr = manager.GetItem(ref helpMenu, out item);
            Report("langBarGetSystemHelpMenu", Format(hr));
            if (hr < 0 || item == IntPtr.Zero)
            {
                return;
            }

            try
            {
                object itemObject = Marshal.GetObjectForIUnknown(item);
                ITfSourceNative source = itemObject as ITfSourceNative;
                if (source == null)
                {
                    Report("langBarHelpMenuQuerySource", Format(unchecked((int)0x80004002)));
                    return;
                }
                Report("langBarHelpMenuQuerySource", Format(0));

                Guid systemSinkIid = typeof(ITfSystemLangBarItemSink).GUID;
                SystemLangBarItemSink sink = new SystemLangBarItemSink();
                uint cookie;
                hr = source.AdviseSink(ref systemSinkIid, sink, out cookie);
                Report("langBarHelpMenuAdviseSink", Format(hr));
                if (hr >= 0)
                {
                    Report("langBarHelpMenuUnadviseSink", Format(source.UnadviseSink(cookie)));
                }
            }
            finally
            {
                Marshal.Release(item);
            }
        }
        finally
        {
            Marshal.Release(itemManager);
        }
    }

    // Mirrors TipTextServiceImpl::InitKeyEventSink(): AdviseKeyEventSink with
    // the same foreground flag the TIP uses. TSF may reject the call when the
    // thread has no focused document manager, so the variants isolate whether
    // the foreground flag or the missing focus is what returns E_INVALIDARG.
    private static void DiagnoseKeyEventSinkAdvise(ITfThreadMgr threadMgr, uint clientId)
    {
        ITfKeystrokeMgrNative keystroke = threadMgr as ITfKeystrokeMgrNative;
        if (keystroke == null)
        {
            Report("adviseKeyEventSink", Format(unchecked((int)0x80004002)));
            return;
        }

        // Baseline calls that do not take a sink, to separate "the keystroke
        // manager rejects this tid/process" from "it rejects sinks".
        Guid foregroundClsid;
        Report("keystrokeGetForeground", Format(keystroke.GetForeground(out foregroundClsid)));

        Guid preservedGuid = Guid.NewGuid();
        TF_PRESERVEDKEY preservedKey = new TF_PRESERVEDKEY();
        preservedKey.uVKey = 0x41; // 'A'
        preservedKey.uModifiers = 0x0002; // TF_MOD_ALT
        Report("keystrokePreserveKey", Format(keystroke.PreserveKey(clientId, ref preservedGuid, ref preservedKey, "KanaAI probe", 14)));
        Report("keystrokeUnpreserveKey", Format(keystroke.UnpreserveKey(ref preservedGuid, ref preservedKey)));

        KeyEventSink sink = new KeyEventSink();
        int hr = keystroke.AdviseKeyEventSink(clientId, sink, true);
        Report("adviseKeyEventSink", Format(hr));
        if (hr >= 0)
        {
            Report("unadviseKeyEventSink", Format(keystroke.UnadviseKeyEventSink(clientId)));
        }

        // tid 0 is TF_CLIENTID_NULL; comparing it against the activated tid
        // shows whether the rejection depends on the client id at all.
        hr = keystroke.AdviseKeyEventSink(0, sink, true);
        Report("adviseKeyEventSinkTid0", Format(hr));
        if (hr >= 0)
        {
            keystroke.UnadviseKeyEventSink(0);
        }

        hr = keystroke.AdviseKeyEventSink(clientId, sink, false);
        Report("adviseKeyEventSinkBackground", Format(hr));
        if (hr >= 0)
        {
            Report("unadviseKeyEventSinkBackground", Format(keystroke.UnadviseKeyEventSink(clientId)));
        }

        IntPtr focused = IntPtr.Zero;
        int getFocusHr = threadMgr.GetFocus(out focused);
        Report("threadMgrGetFocus", Format(getFocusHr) + " null=" + (focused == IntPtr.Zero));
        if (focused != IntPtr.Zero) { Marshal.Release(focused); }

        IntPtr documentMgr = IntPtr.Zero;
        int createHr = threadMgr.CreateDocumentMgr(out documentMgr);
        Report("threadMgrCreateDocumentMgr", Format(createHr));
        if (createHr >= 0 && documentMgr != IntPtr.Zero)
        {
            int setFocusHr = threadMgr.SetFocus(documentMgr);
            Report("threadMgrSetFocus", Format(setFocusHr));

            hr = keystroke.AdviseKeyEventSink(clientId, sink, true);
            Report("adviseKeyEventSinkWithFocus", Format(hr));
            if (hr >= 0)
            {
                Report("unadviseKeyEventSinkWithFocus", Format(keystroke.UnadviseKeyEventSink(clientId)));
            }

            IntPtr restored = IntPtr.Zero;
            if (setFocusHr >= 0)
            {
                threadMgr.SetFocus(IntPtr.Zero);
            }
            Marshal.Release(documentMgr);
        }

        // Final variable: whether the calling thread owns a window at all.
        IntPtr hwnd = CreateProbeWindow();
        Report("probeWindowCreated", hwnd != IntPtr.Zero ? "yes" : "no");
        if (hwnd != IntPtr.Zero)
        {
            hr = keystroke.AdviseKeyEventSink(clientId, sink, true);
            Report("adviseKeyEventSinkWithWindow", Format(hr));
            if (hr >= 0)
            {
                Report("unadviseKeyEventSinkWithWindow", Format(keystroke.UnadviseKeyEventSink(clientId)));
            }
            DestroyWindow(hwnd);
        }
    }

    // Gives the thread a focused document manager before Activate(), mirroring
    // a real TSF client (an application window) so ActivateEx()'s focus
    // dependent paths behave as they would in a real app. Returns a handle the
    // caller must release after Deactivate().
    private static IntPtr EnsureThreadFocus(ITfThreadMgr threadMgr)
    {
        IntPtr focused = IntPtr.Zero;
        if (threadMgr.GetFocus(out focused) >= 0 && focused != IntPtr.Zero)
        {
            return focused;
        }
        if (focused != IntPtr.Zero) { Marshal.Release(focused); focused = IntPtr.Zero; }

        IntPtr documentMgr = IntPtr.Zero;
        if (threadMgr.CreateDocumentMgr(out documentMgr) >= 0 && documentMgr != IntPtr.Zero)
        {
            if (threadMgr.SetFocus(documentMgr) >= 0)
            {
                return documentMgr;
            }
            Marshal.Release(documentMgr);
        }
        return IntPtr.Zero;
    }

    private static int QueryInterface(object comObject, Guid iid)
    {
        IntPtr unknown = Marshal.GetIUnknownForObject(comObject);
        if (unknown == IntPtr.Zero) { return unchecked((int)0x80004005); }
        try
        {
            IntPtr queried = IntPtr.Zero;
            int hr = Marshal.QueryInterface(unknown, ref iid, out queried);
            if (queried != IntPtr.Zero) { Marshal.Release(queried); }
            return hr;
        }
        finally
        {
            Marshal.Release(unknown);
        }
    }

    private static int Run(string tipPath, Guid clsid)
    {
        Report("tipDll", tipPath);
        Report("architecture", IntPtr.Size == 8 ? "x64" : "x86");
        Report("textServiceClsid", clsid.ToString("B").ToUpperInvariant());

        int hr = CoInitializeEx(IntPtr.Zero, COINIT_APARTMENTTHREADED);
        bool uninitialize = hr >= 0;
        if (hr == unchecked((int)0x80010106))
        {
            // RPC_E_CHANGED_MODE: COM is already initialized with another
            // apartment model. Keep going; the caller owns the lifetime.
            uninitialize = false;
        }
        Report("coInitializeEx", Format(hr));

        ITfThreadMgr threadMgr;
        try
        {
            threadMgr = (ITfThreadMgr)new ThreadMgrClass();
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("ITfThreadMgr construction failed: " + exception.Message);
            if (uninitialize) { CoUninitialize(); }
            return 10;
        }

        uint clientId = 0;
        hr = threadMgr.Activate(out clientId);
        Report("threadMgrActivate", Format(hr));
        Report("clientId", clientId.ToString(CultureInfo.InvariantCulture));
        if (hr < 0)
        {
            if (uninitialize) { CoUninitialize(); }
            return 10;
        }

        IntPtr module = LoadLibraryExW(tipPath, IntPtr.Zero,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (module == IntPtr.Zero)
        {
            Console.Error.WriteLine("LoadLibraryExW failed with Win32 error " + Marshal.GetLastWin32Error());
            threadMgr.Deactivate();
            if (uninitialize) { CoUninitialize(); }
            return 11;
        }
        Report("loadLibrary", "ok");

        uint serviceClientId = DiagnoseTsf(threadMgr, clientId, clsid);
        Report("activateClientIdSource",
            serviceClientId == clientId ? "threadMgrActivate" : "clientIdGet");
        Report("activateClientId", serviceClientId.ToString(CultureInfo.InvariantCulture));

        IntPtr getClassObjectPointer = GetProcAddress(module, "DllGetClassObject");
        IntPtr canUnloadNowPointer = GetProcAddress(module, "DllCanUnloadNow");
        Report("exportDllGetClassObject", getClassObjectPointer != IntPtr.Zero ? "present" : "missing");
        Report("exportDllCanUnloadNow", canUnloadNowPointer != IntPtr.Zero ? "present" : "missing");
        if (getClassObjectPointer == IntPtr.Zero || canUnloadNowPointer == IntPtr.Zero)
        {
            FreeLibrary(module);
            threadMgr.Deactivate();
            if (uninitialize) { CoUninitialize(); }
            return 12;
        }

        object instance = null;
        object factory = null;
        int exitCode = 0;
        try
        {
            DllGetClassObjectDelegate getClassObject = (DllGetClassObjectDelegate)Marshal.GetDelegateForFunctionPointer(getClassObjectPointer, typeof(DllGetClassObjectDelegate));
            Guid classFactoryIid = new Guid("00000001-0000-0000-c000-000000000046");
            IntPtr classFactoryPointer = IntPtr.Zero;
            hr = getClassObject(ref clsid, ref classFactoryIid, out classFactoryPointer);
            Report("dllGetClassObject", Format(hr));
            if (hr < 0 || classFactoryPointer == IntPtr.Zero)
            {
                exitCode = 12;
            }
            else
            {
                factory = Marshal.GetObjectForIUnknown(classFactoryPointer);
                Marshal.Release(classFactoryPointer);
                IClassFactory classFactory = (IClassFactory)factory;
                Guid textInputProcessorIid = new Guid("aa80e7f7-2021-11d2-93e0-0060b067b86e");
                hr = classFactory.CreateInstance(null, ref textInputProcessorIid, out instance);
                Report("createInstance", Format(hr));
                if (hr < 0 || instance == null)
                {
                    exitCode = 13;
                }
                else
                {
                    // A real TSF client always has a focused document manager
                    // by the time it activates a text service, so mirror that
                    // precondition before calling Activate().
                    IntPtr heldFocus = EnsureThreadFocus(threadMgr);
                    Report("probeHeldFocus", heldFocus != IntPtr.Zero ? "yes" : "no");

                    ITfTextInputProcessor processor = (ITfTextInputProcessor)instance;
                    hr = processor.Activate(threadMgr, serviceClientId);
                    Report("textInputProcessorActivate", Format(hr));
                    if (hr < 0)
                    {
                        exitCode = 14;
                    }

                    // TSF only tears a text service down after a successful
                    // activation, but a failed activation still needs the
                    // cleanup path exercised so the probe can report whether the
                    // object survives it. The failure code above is preserved.
                    int deactivateHr = processor.Deactivate();
                    Report("textInputProcessorDeactivate", Format(deactivateHr));
                    if (hr >= 0 && deactivateHr < 0)
                    {
                        exitCode = 15;
                    }

                    if (heldFocus != IntPtr.Zero)
                    {
                        threadMgr.SetFocus(IntPtr.Zero);
                        Marshal.Release(heldFocus);
                    }
                }
            }

            if (instance != null)
            {
                Marshal.ReleaseComObject(instance);
                instance = null;
            }
            if (factory != null)
            {
                Marshal.ReleaseComObject(factory);
                factory = null;
            }

            DllCanUnloadNowDelegate canUnloadNow = (DllCanUnloadNowDelegate)Marshal.GetDelegateForFunctionPointer(canUnloadNowPointer, typeof(DllCanUnloadNowDelegate));
            Report("dllCanUnloadNow", Format(canUnloadNow()));
            return exitCode;
        }
        finally
        {
            if (instance != null) { Marshal.ReleaseComObject(instance); }
            if (factory != null) { Marshal.ReleaseComObject(factory); }
            FreeLibrary(module);
            threadMgr.Deactivate();
            if (uninitialize) { CoUninitialize(); }
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length < 1 || args.Length > 2)
        {
            Console.Error.WriteLine("usage: TipActivationProbe.exe <tip.dll> [text-service-clsid]");
            return 2;
        }
        Guid clsid = args.Length == 2
            ? new Guid(args[1])
            : new Guid("7E7B5C1E-6D3A-4F2C-9A0E-3F4B5D6C7E81");
        try
        {
            return Run(args[0], clsid);
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("probe failed: " + exception);
            return 1;
        }
    }
}

