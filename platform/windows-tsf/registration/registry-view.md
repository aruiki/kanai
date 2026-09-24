# Windows TSF registry-view guidance

The x64 KanaAI TIP is a **64-bit registry object**. Do not inspect or write
it from a 32-bit PowerShell process and assume that the resulting entry is the
one used by 64-bit applications.

## Paths

The provider and profile metadata for this slice is described by:

- `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\CTF\TIP\{CLSID}` (machine scope)
- `HKEY_CURRENT_USER\Software\Microsoft\CTF\TIP\{CLSID}\LanguageProfile\0x00000411\{PROFILE_GUID}` (user activation overlay)
- `Software\Classes\CLSID\{CLSID}\InProcServer32` (COM registration; machine or per-user;
  `HKEY_CLASSES_ROOT\CLSID` is the merged view, not a substitute for choosing
  the correct registry view)

The machine scope is the production direction. The per-user scope is a
reviewed developer overlay and does not replace the TSF APIs or category
registration.

## 64-bit view

Use 64-bit PowerShell and .NET `Microsoft.Win32.RegistryView.Registry64`, or
64-bit `reg.exe`:

```text
reg.exe query "HKLM\SOFTWARE\Microsoft\CTF\TIP\{CLSID}" /reg:64
reg.exe query "HKLM\SOFTWARE\Classes\CLSID\{CLSID}" /reg:64
reg.exe query "HKCU\Software\Microsoft\CTF\TIP\{CLSID}\LanguageProfile\0x00000411\{PROFILE_GUID}" /reg:64
```

In Registry Editor, use **View > Registry Keys (64-bit)**. A visible
`Wow6432Node` is the 32-bit view, not the x64 TIP registration.

## Future x86 view

The x86 TIP is intentionally not implemented in this slice. When it is
added, use a 32-bit installer/reg.exe and `RegistryView.Registry32` for the
32-bit entries:

```text
reg.exe query "HKLM\SOFTWARE\Microsoft\CTF\TIP\{CLSID}" /reg:32
reg.exe query "HKLM\SOFTWARE\Classes\CLSID\{CLSID}" /reg:32
```

Put the x86 binary under the resolved `Program Files (x86)` root
(`ProgramFiles(x86)`), and the x64 binary under the resolved `Program Files`
root (`ProgramW6432`, falling back to `ProgramFiles`). Never point a
registry string at an unexpanded `%ProgramFiles%`-style variable.

## What to verify

A successful `reg query` only proves that a value exists. It does not prove
that the COM class can be loaded, that the TIP implements the required TSF
interfaces, that the profile is enabled, or that an application can use it.
Registration is not complete until a real `KanaAI.TsfTip.dll` exists and the
Windows registration, activation, COM, and application tests pass.
