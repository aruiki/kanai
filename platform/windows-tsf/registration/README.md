# KanaAI Windows TSF registration slice

This directory is a source-level registration contract for the future x64
KanaAI TIP. It contains metadata and reviewable templates; it does **not**
register an IME and does not ship a TIP DLL.

## Current boundary

`registration.json` is deliberately `source-only`:

- the planned x64 artifact name is `KanaAI.TsfTip.dll`, matching the Windows
  build harness;
- the build harness still has `KANAI_TSF_REFUSE_REGISTRATION=ON` and points to
  its Windows smoke-test plan;
- `registrationComplete` is `false`;
- `tipDllPresent` is `false`;
- `windowsTestsPassed` is `false`;
- the x86 TIP is explicitly blocked.

The identity block also records the pinned upstream Mozc CLSIDs only as a
reference. They are not KanaAI product identities and must not be registered
by these templates.

Registration is not complete until a real `KanaAI.TsfTip.dll` exists and Windows
registration, COM activation, language-profile, and application tests pass.
A registry template or a successful `reg query` is not evidence of runtime
readiness.

## What the metadata describes

The JSON identifies the text-service CLSID, the Japanese language profile
(`0x0411`), the profile GUID, the icon, the COM `InProcServer32` shape, the
TSF `LanguageProfile` hierarchy, and the required TSF APIs. TSF category
registration is called out separately because `ITfCategoryMgr` owns those
operations; a registry template must not pretend to replace that API.

The x64 file location is resolved from `ProgramW6432` with `ProgramFiles` as
a fallback. The future x86 location is resolved from `ProgramFiles(x86)`.
The matching registry views are `Registry64` and `Registry32` respectively;
see [registry-view.md](registry-view.md).

## Templates

- [per-user.reg.template](templates/per-user.reg.template) is a developer
  activation overlay. It is not a complete machine-wide TSF provider
  registration.
- [administrator-x64.reg.template](templates/administrator-x64.reg.template)
  is the reviewable x64 machine projection.
- [administrator-x86.reg.template](templates/administrator-x86.reg.template)
  is a blocked future sketch and must not be imported.

All templates contain `@@TIP_DLL_PATH@@` (or the x86 sentinel). They cannot
be imported as-is. The installer only resolves and uses an absolute path after
the DLL and Windows-test gates are satisfied.

## Installer entry points

Use the scripts in `../installer` for a plan first. The default is a dry run:

```powershell
..\..\..\scripts\register-tsf-dev.ps1 -DryRun
..\..\..\scripts\register-tsf-dev.ps1 -DryRun -Admin
```

`-Apply` is deliberately guarded. It requires a real, architecture-correct
TIP DLL and a Windows test receipt. Even after a projection is applied, the
scripts continue to report runtime verification and registration completion
as false until the Windows test suite has run.
