# TSF registration installer slice

These scripts produce a reviewable TSF registration plan and, only after
explicit `-Apply`, can write the reviewed registry projection. They are not a
claim that a TIP is installed or working. The script syntax is compatible
with Windows PowerShell 5.1; registry application still requires a Windows
x64 host.

## Dry run first

From the repository root:

```powershell
.\scripts\register-tsf-dev.ps1 -DryRun
.\scripts\register-tsf-dev.ps1 -DryRun -Admin
.\platform\windows-tsf\installer\Install-TsfRegistration.ps1 -DryRun -Scope PerUser
.\platform\windows-tsf\installer\Uninstall-TsfRegistration.ps1 -DryRun -Scope Machine
```

The default mode is dry-run even when `-DryRun` is omitted. It does not read
or write the TSF registry and does not copy a DLL. It reports the resolved
Program Files root, the exact registry view, the CLSID/profile paths, the TSF
API calls that remain required, and the blocking gates.

## Apply gate

`-Apply` is intentionally not a bypass. The install script requires:

1. explicit approval of the provisional TSF CLSID/profile identity;
2. a real `KanaAI.TsfTip.dll` at the resolved path (the build harness itself
   remains guarded by `KANAI_TSF_REFUSE_REGISTRATION=ON`);
3. an x64 PE32+ DLL (or the explicitly blocked future x86 path is rejected);
4. a Windows test receipt with `windowsTestsPassed: true`, matching
   architecture, and a matching DLL SHA-256; and
5. for machine scope, an elevated 64-bit Windows PowerShell process.

The receipt is expected to look like:

```json
{
  "schemaVersion": 1,
  "architecture": "x64",
  "windowsTestsPassed": true,
  "tipDll": {
    "fileName": "KanaAI.TsfTip.dll",
    "sha256": "0123456789abcdef..."
  }
}
```

A registry projection is not a substitute for
`ITfInputProcessorProfiles::Register`, `AddLanguageProfile`,
`ITfCategoryMgr::RegisterCategory`, or `InstallLayoutOrTip`. Those API calls
are listed in every install plan and must be implemented/tested by the future
TIP registrar. The apply result intentionally keeps
`RegistrationComplete = $false` and `RuntimeVerified = $false`.

## Path rules

- `-InstallRoot` is an explicit final TSF directory (for example,
  `C:\Program Files\KanaAI\TSF`); `-ProgramFilesRoot` is the base directory
  used when the final directory should be derived.
- x64: resolve `ProgramW6432`, fall back to `ProgramFiles` only from a
  64-bit process, use `Registry64`, and install under
  `Program Files\KanaAI\TSF`.
- future x86: resolve `ProgramFiles(x86)`, use `Registry32`, and install under
  `Program Files (x86)\KanaAI\TSF`; this slice rejects it until an x86 TIP
  exists.
- Never use `%WINDIR%\IME` for a third-party TIP and never assume that a
  32-bit registry view represents the x64 TIP.

The uninstall script removes only the KanaAI CLSID/TIP/profile keys selected
by the plan. It does not remove parent `TIP` or `CLSID` roots, unrelated
profiles, or user data. Use `-RemoveUserActivation` only when the current
user's activation overlay should also be removed.
