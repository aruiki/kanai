KanaAI Development Preview - installed package README
====================================================

STATUS: UNSIGNED WINDOWS X64 DEVELOPER PREVIEW
This is a local Windows TSF IME developer snapshot, not a completed product, a
published GitHub prerelease, or evidence that Japanese input works. This
snapshot is not approved for publication until the applicable release gates
pass. Actual application input and clean uninstall/reinstall are not yet
verified for this snapshot.

Scope and evidence
------------------
This is a Windows x64 installer, not a general Windows installer. The MSI is a
per-machine package, and Setup.exe checks for a 64-bit operating system. It is
not an x86 KanaAI application package.

The installed payload contains both x86 and x64 TIP DLL payloads:

  mozc_tip64.dll        x64 TSF TIP payload
  mozc_tip32.dll        x86 (32-bit) TSF TIP payload for 32-bit processes

Having the x86 DLL does not claim an x86 application, an x86 installer, or x86
registration. The only installation evidence recorded for this snapshot is a
successful MSI install and x64 COM registration on one machine. x86
registration, x86 application use, and actual desktop input are not verified.

Install flow (intended for a future release)
--------------------------------------------
1. Obtain Setup.exe or the MSI from the approved release location after its
   release gates have passed.
2. Double-click Setup.exe. It writes an embedded MSI to a temporary folder and
   starts Windows Installer; it does not build, download, or require manual
   placement of files. Alternatively, double-click the MSI.
3. Follow the Windows prompts. Because the MSI is per-machine, Windows may
   show UAC. Do not bypass it. If Windows reports that a restart is required,
   follow that request. If KanaAI does not appear, restart the target
   application and follow the Windows prompts. This snapshot does not promise
   automatic activation or that signing out or restarting Windows is required.

Unsigned warning
----------------
This preview is unsigned. Windows may display a SmartScreen or other
security warning for an artifact without a recognized signature or publisher.
Do not disable or bypass SmartScreen, Smart App Control, antivirus, or
enterprise policy. Use only the release's published verification information
and follow your organization's security policy.

Installed components
--------------------
  mozc_tip64.dll        x64 TSF text service TIP
  mozc_tip32.dll        32-bit TSF text service TIP payload
  mozc_server.exe       Mozc conversion server
  mozc_renderer.exe     Mozc candidate renderer
  mozc_broker.exe       Mozc process broker/prelauncher
  msvcp140.dll          app-local x64 Microsoft Visual C++ runtime file
  vcruntime140.dll      app-local x64 Microsoft Visual C++ runtime file
  vcruntime140_1.dll    app-local x64 Microsoft Visual C++ runtime file
  LICENSE.txt           KanaAI project license notice
  MOZC-LICENSE.txt      Mozc license notice
  credits_en.html       Mozc third-party credits
  README.txt            This document

The installer helper is embedded in the MSI for registration actions; it is not
listed as a separately installed user file. mozc_broker.exe is a Mozc
component, not the Rust KanaAI broker and not a local model.

Optional local-AI payload
-------------------------
This package is built in one of two shapes. Determine which one you received by
listing the installed files.

Shape 1 - no local AI (the default when the build was not given the local-AI
inputs): the list above is the complete installed payload. There is no model,
no local-AI runtime, and no AI weight on this machine.

Shape 2 - local-AI bytes included: the list above plus

  kanai-broker.exe                the KanaAI native AI broker executable
  ai\model\                       the pinned local model weight (one file)
  ai\runtime\                     the reviewed local inference runtime closure,
                                  including llama-server.exe and its DLLs
  ai\licenses\                    the model and runtime license texts
  ai\THIRD-PARTY-NOTICES.txt      the local-AI third-party notice

Shape 2 means only that the reviewed model, runtime, license, and notice files
were placed in the install folder. It does NOT mean that any AI feature is
active, working, registered, enabled, or configured. In particular:

  - the installer does not start, install, register, or validate the broker or
    the local-AI runtime, and it does not configure Windows to use them;
  - the model is not executed, benchmarked, or quality-checked by this package,
    and no AI quality, accuracy, latency, privacy, or fallback result is claimed;
  - kana/kanji conversion behaviour in this snapshot is not evidence that any
    AI path contributed to it;
  - the third-party notice shipped in ai\ states that the dependency notice
    inventory is incomplete and that no SBOM has been generated.

The installed files are an offline, CPU-only, network-free local component. No
network download, account, sign-in, or telemetry is performed by this package.

Mozc baseline and AI boundary
-----------------------------
The intended available path is the pinned Mozc baseline conversion path. That
intended path is not evidence of successful desktop input: actual desktop
application input verification is still pending at this snapshot.

No AI quality, speed, privacy, or fallback result is claimed by this package.
For shape 1, no local model, local-AI runtime, or AI weights are bundled. For
shape 2, the bundled bytes are not evidence of AI operation. mozc_broker.exe is
a Mozc component and is not the Rust KanaAI broker or a local model.

Verification status and known limitations
-----------------------------------------
The following are not verified or claimed for this snapshot:

  - actual desktop application input, including kana composition, kanji
    conversion, candidates, commit, cancel, focus changes, and app restart;
  - clean uninstall, reinstall, or rollback;
  - an x86 KanaAI application, x86 registration, or broad x86 support;
  - Microsoft Office or Microsoft Edge compatibility;
  - UI Automation (UIA), accessibility, secure/password fields, or high-DPI
    behavior;
  - AI quality, AI operation, AI startup, or an AI-enhanced path;
  - code signing, publisher trust, or a SmartScreen exemption; or
  - product completion or production support.

The presence of a DLL, a model weight, a local-AI runtime, a successful MSI
install, or an x64 COM registration is not input verification and is not AI
verification.

Uninstall
---------
On Windows, open Settings > Apps > Installed apps (or Apps & features),
select "KanaAI Development Preview", choose Uninstall, and follow the Windows
prompts. The MSI defines an uninstall path intended to remove its files and TSF
registration. Clean removal, reinstall, and rollback have not been verified.
Do not treat the current install receipt as a clean uninstall result.

Release information
-------------------
This README is installed package documentation, not a release attestation. An
eventual GitHub prerelease must be accompanied outside this file by:

  - SHA-256 values for the published artifacts, including Setup.exe and the
    MSI;
  - the exact source commit and build/provenance record; and
  - the applicable source, project license, and third-party license/notice
    links.

Do not substitute a self-embedded hash or filename for those external records.
This snapshot is not approved for publication until the release gates pass.

Repository and support
----------------------
Source, issue tracking, and current project status are at:
https://github.com/aruiki/kanai

For a reproducible support report, include the Windows version, application,
architecture, and observed behavior. Do not include secrets, model weights,
or private text.
