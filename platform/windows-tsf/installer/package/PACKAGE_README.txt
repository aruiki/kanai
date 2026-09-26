KanaAI Development Preview - installed package README
====================================================

STATUS: UNSIGNED WINDOWS X64 BETA, MOZC BASELINE ONLY, NO LOCAL AI
This is a local Windows TSF IME beta. It is not a completed product. It bundles
no local AI model and no local AI runtime, and it claims no AI result.

This file is installed package documentation. It states what this package
contains and what it does not implement. It deliberately does not state
verification results, because a package is built before those checks run and
cannot know them. The authoritative dated verification record, the supported
application list, and the published SHA-256 values for this exact build are in
the GitHub Release body for this version, at the repository named at the end of
this file. Read that Release body before relying on this package.

Windows shows the installed product as "KanaAI Development Preview". That is the
installed product name; it is not a statement that fewer features are present
than this file describes.

Scope and evidence
------------------
This is a Windows x64 installer, not a general Windows installer. The MSI is a
per-machine package, and Setup.exe checks for a 64-bit operating system. It is
not an x86 KanaAI application package.

The installed payload contains both x86 and x64 TIP DLL payloads:

  mozc_tip64.dll        x64 TSF TIP payload
  mozc_tip32.dll        x86 (32-bit) TSF TIP payload for 32-bit processes

Having the x86 DLL does not claim an x86 application, an x86 installer, or x86
registration. This beta supports x64 Windows and x64 COM registration only.
Whether x86 registration, x86 application use, and desktop input passed for this
exact build is recorded in the GitHub Release body, not in this file.

Install flow
------------
1. Obtain Setup.exe or the MSI from the GitHub Release assets for this version.
2. Double-click Setup.exe. It writes an embedded MSI to a temporary folder and
   starts Windows Installer; it does not build, download, or require manual
   placement of files. Alternatively, double-click the MSI.
3. Follow the Windows prompts. Because the MSI is per-machine, Windows may
   show UAC. Do not bypass it. If Windows reports that a restart is required,
   follow that request. If KanaAI does not appear, restart the target
   application and follow the Windows prompts. This beta does not promise
   automatic activation, and does not state whether signing out or restarting
   Windows is required.

Unsigned warning
----------------
This beta is unsigned. Windows may display a SmartScreen or other
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
  - kana/kanji conversion behaviour in this beta is not evidence that any
    AI path contributed to it;
  - the third-party notice shipped in ai\ states that the dependency notice
    inventory is incomplete and that no SBOM has been generated.

The installed files are an offline, CPU-only, network-free local component. No
network download, account, sign-in, or telemetry is performed by this package.

Mozc baseline and AI boundary
-----------------------------
The available conversion path is the pinned Mozc baseline. No AI path
contributes to it in this package, because no model and no inference runtime is
bundled.

No AI quality, speed, privacy, or fallback result is claimed by this package.
For shape 1, no local model, local-AI runtime, or AI weights are bundled. For
shape 2, the bundled bytes are not evidence of AI operation. mozc_broker.exe is
a Mozc component and is not the Rust KanaAI broker or a local model.

What this beta implements
-------------------------
Implemented in this package and intended to work:

  - a per-machine Windows x64 installation of a native TSF text service;
  - x64 COM registration of the TIP together with a Japanese (0x0411) language
    profile;
  - an x86 TIP payload, so 32-bit processes running on x64 Windows can load the
    TIP through their default per-user registration;
  - romaji composition, segmentation, conversion, candidates, preedit, commit,
    and cancel, owned by the pinned Mozc engine; and
  - an uninstall entry in Windows Settings > Apps > Installed apps.

What this beta does not implement
---------------------------------
Not implemented, not claimed, and not supported in this beta:

  - any local AI: no model, no inference runtime, no AI-assisted candidate
    reranking, and no AI quality, latency, privacy, or fallback result;
  - an x86 KanaAI application package, an x86-only installer, and x86-only
    Windows;
  - Microsoft Office and Microsoft Edge compatibility;
  - UI Automation (UIA), accessibility coverage, secure/password-field policy,
    and high-DPI behavior;
  - code signing, publisher trust, and any SmartScreen exemption; and
  - product completion, production support, and enterprise management.

Supported operating system and applications
-------------------------------------------
This beta targets Windows 10 and Windows 11 on x64 only. Setup.exe checks for a
64-bit operating system and the MSI is a per-machine installation.

The list of applications in which this exact build has actually been verified
for composition, conversion, candidates, commit, cancel, focus change, and
application restart is recorded in the GitHub Release body for this version.
This file does not repeat that list, because the package is built before the
verification runs and must not claim a result it cannot know.

Verification record
-------------------
The presence of a DLL, a model weight, a local-AI runtime, a successful MSI
install, or an x64 COM registration is not input verification and is not AI
verification. The dated verification record for this exact build, including
which lifecycle and desktop-input checks passed and which did not, is in the
GitHub Release body. Read it before relying on this package.

Uninstall
---------
On Windows, open Settings > Apps > Installed apps (or Apps & features),
select "KanaAI Development Preview", choose Uninstall, and follow the Windows
prompts. The MSI defines an uninstall path intended to remove its files and TSF
registration. Whether clean removal, reinstall, and rollback passed for this
exact build is recorded in the GitHub Release body, not in this file.

Release information
-------------------
This README is installed package documentation, not a release attestation. The
GitHub Release for this version carries, outside this file:

  - SHA-256 values for the published artifacts, including Setup.exe and the
    MSI;
  - the exact source commit and build/provenance record;
  - the applicable source, project license, and third-party license/notice
    links; and
  - the dated verification record for this exact build, including the
    supported application list.

Do not substitute a self-embedded hash or filename for those external records.

Repository and support
----------------------
Source, issue tracking, and current project status are at:
https://github.com/aruiki/kanai

For a reproducible support report, include the Windows version, application,
architecture, and observed behavior. Do not include secrets, model weights,
or private text.
