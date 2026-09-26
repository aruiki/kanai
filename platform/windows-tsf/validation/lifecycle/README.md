# KanaAI installer lifecycle verification (verification stage W2)

## Status: NO LIFECYCLE RUN HAS HAPPENED. W2 IS UNVERIFIED.

Nothing in this directory has been installed, uninstalled, registered or
unregistered. No `msiexec`, no `Setup.exe`, no `msi.dll`, no Windows Installer
COM object, no registry read and no process launch has been performed by the
`-Execute` path. The only commands that have been run against this harness are
`-PlanOnly`, `-SelfTest`, and the Windows PowerShell 5.1 parser. The receipts
this directory can produce today carry `mode = "plan-only"`, all machine
interaction counters at zero, and a `w2.claim` that says in plain words that
nothing about the candidate has been proven.

A W2 claim may only come from a receipt written by an `-Execute` run, on a real
machine, for one fixed-hash candidate. Until then, do not report W2 as passed.

## What this is

`KanaAI.wxs` is a per-machine Windows Installer package: a TSF text service (TIP),
COM classes, a Japanese language profile and a set of Mozc runtime files under a
single MSI directory, wrapped by a `Setup.exe` that embeds the MSI verbatim.
This harness is the second verification stage. It asks, on a real machine and for
one candidate:

1. can a user install it with one double-click of `Setup.exe`, and can it be
   installed from the MSI directly;
2. is the TSF registration actually present after the install, and actually
   absent after the uninstall;
3. does the uninstall leave no files, no registration and no orphaned process;
4. can the same MSI be installed again over the same product code, and is that
   second run a reinstall rather than a repair in disguise;
5. does the package behave as its source declares on a forward upgrade and on a
   refused downgrade.

## The pinned identity this harness refuses to deviate from

Read from the source, not guessed:

| Fact | Value | Source |
| --- | --- | --- |
| UpgradeCode | `{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}` | `platform/windows-tsf/installer/package/KanaAI.wxs:4` |
| Package Name | `KanaAI Development Preview` | `KanaAI.wxs:3` |
| Manufacturer | `KanaAI Project` | `KanaAI.wxs:3` |
| Scope | `perMachine` (`ALLUSERS=1`) | `KanaAI.wxs:4`; asserted again at `scripts/build-windows-installer.ps1:1980` |
| Platform | x64 (`wix build -arch x64`) | `scripts/build-windows-installer.ps1:1960` |
| InstallerVersion | 500 | `KanaAI.wxs:4` |
| Language | 1041 | `KanaAI.wxs:4` |
| Upgrade policy | `MajorUpgrade Schedule="afterInstallInitialize"` with a `DowngradeErrorMessage` | `KanaAI.wxs:5` |
| MSI directory id | `INSTALLFOLDER`, leaf `KanaAI`, parent `ProgramFilesFolder` | `KanaAI.wxs:10-12` |
| TIP CLSID | `{7E7B5C1E-6D3A-4F2C-9A0E-3F4B5D6C7E81}` | `platform/windows-tsf/registration/registration.json`, `installer/Common-TsfRegistration.ps1:11` |
| Language profile GUID | `{F3C2B7A1-6D54-4E8B-9A10-2C7D8E9F0A12}` | `registration.json`, `Common-TsfRegistration.ps1:12` |
| Language segment / id | `0x00000411` / 1041 | `Common-TsfRegistration.ps1:13-14` |
| Machine registration surface | `HKLM\SOFTWARE\Microsoft\CTF\TIP\<CLSID>` and `...\LanguageProfile\0x00000411\<profile>`, plus `HKLM\SOFTWARE\Classes\CLSID\<CLSID>\InProcServer32`, 64-bit view | `Common-TsfRegistration.ps1:531-549` |
| Product executables watched | `mozc_server.exe`, `mozc_broker.exe`, `mozc_renderer.exe`, `kanai-broker.exe`, `llama-server.exe` | `scripts/build-windows-installer.ps1:72-98` |

`ProductCode` is **not** pinned: WiX derives it from the version, so the harness
reads it out of the candidate MSI's own `Property` table and requires the
installed product to be exactly that code.

### One disagreement with the work ticket, resolved by measurement

The work ticket for this harness said the package installs into
`Program Files (x86)\KanaAI`. The sources say something different:
`<StandardDirectory Id="ProgramFilesFolder">` in a package built with
`wix build -arch x64` resolves to the **64-bit** Program Files, and the sibling
registration slice documents `C:\Program Files\KanaAI\TSF` for x64 and reserves
`Program Files (x86)` for a future x86 TIP
(`platform/windows-tsf/installer/README.md:62-68`). This harness therefore does
not assert a hand-written absolute path. It resolves the directory chain from the
candidate MSI's own `Directory` table, records the resolution and its reason in
the receipt, and after the install it reads the authoritative location back from
the Windows Installer (`ProductInfo(InstallLocation)`). The receipt states which
of the two paths was observed.

## Files

| File | Lines | Purpose |
| --- | --- | --- |
| `Invoke-KanaAiLifecycleValidation.ps1` | 1104 | Entry point. Modes `-PlanOnly`, `-SelfTest`, `-Execute`. Gates, phase loop, receipt. |
| `LifecycleValidation.Common.ps1` | 2406 | Shared helpers, split into a pure half (plan validation, comparison engine, verdict engine, resume planner, receipt assembler, privacy scan) and an observation half that every function routes through one action gate. |
| `Invoke-KanaAiLifecycleValidationSelfTest.ps1` | 832 | 61 self-test cases, synthetic data only, no machine interaction. |
| `lifecycle-validation-plan.json` | 11 phases | The plan: pinned identity, registration identity, phase order, per-phase assertions, per-phase `proves` / `cannotProve`, safety gates, privacy policy, non-goals. |
| `README.md` | this file | What each phase proves, what it cannot, how to read the receipt, the elevation and UAC expectation. |

## The commands

### Plan only (safe, no machine interaction)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File platform\windows-tsf\validation\lifecycle\Invoke-KanaAiLifecycleValidation.ps1 -PlanOnly
```

Exit code 0. Writes `platform\windows-tsf\validation\lifecycle\runs\<runId>\plan.json`
and `...\receipt.json`. The receipt is marked `mode = "plan-only"`, carries a
`machineInteraction` block in which every counter is zero, and includes the
`ledger.sealedReason` that explains why they are zero. The ledger is sealed
before the first observation helper could possibly be called, and every
machine-touching helper throws `LIFECYCLE-GATE-SEALED` if it is called anyway
(self-test ST-53 proves this for all fourteen of them).

### Self test (safe, no machine interaction)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File platform\windows-tsf\validation\lifecycle\Invoke-KanaAiLifecycleValidationSelfTest.ps1
```

Exit code 0 when all 61 cases pass, 1 otherwise. Or through the entry point with
`-SelfTest`.

### A real lifecycle run (NOT performed; requires an elevated 64-bit shell)

Take the `machine` lock first, per `docs/PARALLEL_DEVELOPMENT.md`, and tell the
user what the run does to their machine. Then, from an **elevated** 64-bit
PowerShell:

```powershell
$h = 'platform\windows-tsf\validation\lifecycle\Invoke-KanaAiLifecycleValidation.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File $h -Execute `
  -CandidateMsi     '.local\installer\KanaAI-0.1.0-x64.msi' `
  -CandidateSetup   '.local\installer\KanaAI-0.1.0-Setup.exe' `
  -CandidateMsiOlder '' `
  -CandidateMsiNewer '' `
  -AllowLifecycle -LockConfirmed
```

Notes on the parameters:

- `-CandidateMsi` is **required**. It is the one fixed-hash candidate the run is
  about; the receipt records its SHA-256 and that hash is the identity of the
  claim.
- `-CandidateSetup` is optional. Without it the `install-setup` phase runs no
  command and is reported `unconfirmed` with the reason. It is never silently
  skipped and never reported as a pass.
- `-CandidateMsiNewer` enables `upgrade-forward`; `-CandidateMsiOlder` enables
  `downgrade-refused`. Both are optional, and both additionally require that the
  supplied package really is newer / older than what is installed, so a
  mislabelled MSI cannot turn those phases into a silent no-op that looks like a
  pass.
- `-ResumeFrom <phase>` resumes from a named phase. `-PriorReceiptPath <receipt>`
  supplies the prior receipt whose results the resume planner reads.
- `-AllowDestructiveRerun` is the only way a destructive phase re-runs. Without
  it, a resume that points at a completed or previously failed destructive phase
  is **refused**, not retried.
- `-AllowUnexpectedExistingInstall` acknowledges a pre-existing KanaAI install.
  `-AllowPreexistingTarget` acknowledges that the candidate's own product code is
  already installed; it forfeits the clean-install baseline, and the phases that
  needed it are then reported `unconfirmed`, not `pass`.
- `-WhatIf` renders and records every command line and starts no process. Such a
  run's receipt is honest about having executed nothing.
- Exit codes: `0` pass, `1` failed, `2` refused by a gate, `3` unconfirmed,
  `4` harness error.

## Phases: what each one proves, and what it cannot

The full assertion list, the exact command templates and the per-phase
`proves` / `cannotProve` text live in `lifecycle-validation-plan.json`. The
summary:

| Phase | Command | Proves | Cannot prove |
| --- | --- | --- | --- |
| `preflight` | none | The Windows Installer reports the candidate product code as not installed, the KanaAI registration keys are absent, and the declared install directory does not exist. | That the machine is otherwise healthy, or that the candidate can install. |
| `baseline` | none | A complete before-picture exists: installed KanaAI products, install directory file list, registration keys, product process list with pids. | Anything about the candidate. |
| `install-setup` | `Setup.exe` | The one-double-click path installs per machine. Independently of the exit code: the product is installed under the candidate MSI's own `ProductCode`, the TIP / language-profile / COM keys all exist, the registered `InProcServer32` names a real file, and every file the MSI declares is present. | What the message box said. That the TIP converts romaji. |
| `uninstall-clean-1` | `msiexec /x {productCode} /qn` | Afterwards: product absent from the installer, all three registration keys gone, the registered DLL gone, the install directory gone, and no KanaAI process running that the harness neither started nor saw at baseline. | That nothing outside the install directory and the KanaAI registration surface was left behind. A machine-wide sweep is deliberately not this harness's business. |
| `install-msi` | `msiexec /i <msi> /qn` | The MSI installs on its own, with the same registration and file evidence, and the verbose log is classified as an install. | That the MSI is byte-identical to the one inside `Setup.exe`; that is a build-time invariant, and `install-setup` only proves the installed product code matches this MSI. |
| `reinstall-same` | `msiexec /i <msi> /qn` (no `REINSTALL` property) | `InstallDate` unchanged, file set identical, still registered, and the verbose log shows a `REINSTALL` property. | That a deliberately corrupted file would be restored. If the log carries no decisive marker, this phase is `unconfirmed` and proves nothing about repair versus reinstall. |
| `upgrade-forward` | `msiexec /i <newer> /qn` | A newer package with the same `UpgradeCode` replaces the installed one, the installed product code becomes the newer one, and the newer package's files and the registration are present. | That user data or history survive, or that the upgrade can be rolled back. |
| `downgrade-refused` | `msiexec /i <older> /qn` | The install is refused with **1638** as `MajorUpgrade DowngradeErrorMessage` declares, and the refusal is inert: newer product, files and registration untouched. | That a user cannot force a downgrade by uninstalling first. |
| `uninstall-clean-2` | `msiexec /x {productCode} /qn` | A second clean removal works, so the earlier install was not a one-off. | That the machine is bit-for-bit as it was; only the harness's own recorded before-picture is compared. |
| `absent-final` | none | A separate post-uninstall observation still finds nothing installed, nothing registered, no directory and no product process. | Anything about what the product did while installed. |
| `cleanup` | none | No process the harness started is still running, judged by pid **and** a matching image name so a recycled pid is never killed; a second cleanup pass resolves to already-clean; no path outside the harness output directory is deleted. | That the machine has no unrelated leftover state. |

## How a phase decides, independently of the exit code

Every phase declares a list of assertions. Each assertion is evaluated against an
observation bundle that was read **after** the command finished, through channels
that have nothing to do with the command's own return value:

- **installed product state** — `WindowsInstaller.Installer.ProductInfo(pc, 'InstallState')`
  through the COM automation interface. `DEFAULT` / `LOCAL` is installed;
  `ADVERTISED` is not; an unreadable answer is `unknown`, which is `unconfirmed`,
  never `absent`.
- **which product is installed** — `Installer.Products` filtered to product codes
  whose `UpgradeCode` equals the pinned KanaAI one. No other installed product is
  inspected in detail or written to a receipt.
- **registration** — read-only observation of the 64-bit machine view of the three
  pinned key paths, plus the current user's `Enable` overlay. A key with no real
  file behind its `InProcServer32` is a **failure**, not a registration. If the
  surface cannot be read at all, the check is `unconfirmed`, not a pass. The
  receipt records which of the three keys were seen and whether the registered DLL
  path was read from the registry or inferred from the install directory.
- **file inventory** — the expected set is read out of the **candidate MSI's own**
  `File` / `Component` / `Directory` tables, relative to `INSTALLFOLDER`. Nothing
  is hand-maintained, so a file the package declares but that fails to appear is
  reported by name. An extra undeclared file is recorded as unexpected but is not
  a failure.
- **processes** — only the product's own executable names, by name only. A process
  counts as an orphan only if the harness neither started it nor saw it at the
  baseline.
- **verbose log** — classified only when it carries a decisive marker. An
  unclassifiable or ambiguous log is `unconfirmed`.

The rule that ties it together is enforced at the plan level, not by convention:
`Test-KanaAiLifecyclePlan` **rejects** any phase that runs a command and whose
only required assertion is `command-exit-code`, and it rejects any destructive
phase that has no required product-state, product-code, expected-files or
install-directory assertion. Self-test cases ST-12 and ST-13 mutate a plan to
prove both refusals happen, and ST-28 proves the consequence end to end: an
install that returns 0 with no registration is `fail`, and the exit-code check
itself is still recorded as `pass` — which is exactly why it must not decide
anything.

`unconfirmed` is a first-class outcome. A phase is `unconfirmed` when nothing
failed but a required observation could not be taken, and a run containing any
`unconfirmed` phase is never reported as passed.

## The receipt

`runs\<runId>\receipt.json` (or wherever `-ReceiptPath` points). Top-level keys:

| Key | What it holds |
| --- | --- |
| `mode`, `verificationStage`, `w2` | `plan-only` / `execute` / `execute-whatif`, `W2`, and the explicit claim this receipt is entitled to make. |
| `environment` | OS version, build, revision, 64-bit flags, PowerShell and CLR version, account name, elevation state. Collected by a read-only identity query, in every mode. |
| `pinnedIdentity`, `registrationIdentity` | Copied from the plan, so a receipt is readable on its own. |
| `candidate` | Leaf name, repository-relative path, byte length and SHA-256 of the MSI, the Setup.exe, and the optional older/newer MSIs. The absolute path is deliberately absent. |
| `candidateIdentity` | `ProductCode`, `UpgradeCode`, `ProductName`, `ProductVersion`, `Manufacturer`, `ALLUSERS` and the package template platform, all read from the MSI itself. |
| `expectedFilePlan` | The file list the candidate declares, and anything the MSI stores outside `INSTALLFOLDER`. |
| `safety` | Every gate, its rule, whether it was satisfied, and the detail. |
| `machineInteraction` | Counters: installer COM objects, MSI database opens, registry reads and writes, filesystem reads, process launches, msiexec invocations, directory and file mutations, and whether the gate was sealed. All zero in plan-only. |
| `baseline`, `inventory` | The before-picture and the final picture of the install directory, as file lists relative to the install root. |
| `phases` | Per phase: id, name, decision and its reason, prior outcome, requires, preconditions and whether they held, the exact rendered command line, the command's exit code and duration, every check with its own outcome and evidence, the full observation bundle, `proves`, `cannotProve`. |
| `cleanupPasses` | Both cleanup passes: which pids were stopped, and which were refused and why. |
| `artifacts` | The plan copy, the source plan, and every verbose Windows Installer log, each with a relative path, size and SHA-256. A file that was not present gets `recorded: false` rather than a fabricated digest. |
| `findings` | `info` / `warning` / `critical` findings, including `W2-UNVERIFIED` and, for an execute run that did not pass, `W2-NOT-PASSED`. |
| `privacy` | The plan's own policy, plus the scan result, which top-level fields were excluded from the scan and why, and the SHA-256 of the excluded text. |
| `overall`, `exitCode` | `passed` / `failed` / `refused` / `unconfirmed` / `plan_only`, and the process exit code. |

A resumed run additionally records `resumedFrom` (the prior receipt's path, run id
and SHA-256) and a warning finding stating that a phase marked `pass` by way of
`skip-completed` was proven by *that* receipt. A complete W2 claim needs both
receipts.

### Privacy

The receipt never contains environment variables, the clipboard, user documents,
window titles, or any installed product other than those sharing the pinned
KanaAI `UpgradeCode`. Artifacts are recorded relative to the harness output root;
the candidate is identified by a repository-relative path plus its SHA-256; any
path that still carries a user profile, `LocalAppData`, `Temp` or `MyDocuments`
prefix is rewritten to a token. A final scan of the serialized receipt fails the
run if any of that is violated. The one field excluded from that scan is the
plan's own privacy policy, which necessarily names the categories it never
collects; the exclusion and the excluded text's digest are both recorded.

## Safety properties, and how they are enforced

- **Bounded.** Before any phase runs, the candidate MSI's `Property` table and
  package template platform are read. A `ProductName`, `UpgradeCode`,
  `ProductCode`, `ProductVersion`, `ALLUSERS` or platform that does not match the
  pinned KanaAI identity is a hard refusal with exit code 2. Nothing is installed,
  uninstalled or written.
- **Consent and locking.** `-Execute` refuses without `-AllowLifecycle` and
  without `-LockConfirmed`. The harness asserts the lock flag; it does not take
  the `machine` lock itself.
- **Elevation.** `-Execute` refuses unless the process is an elevated
  administrator on a 64-bit OS, from a 64-bit process. The package is perMachine
  and writes `HKLM` and Program Files.
- **It never touches state it did not create.** If any product sharing the pinned
  `UpgradeCode` is already installed, the run is refused unless
  `-AllowUnexpectedExistingInstall` is passed. A pre-existing install of the
  candidate's own product code is separately refused without
  `-AllowPreexistingTarget`, and acknowledging it forfeits the clean-install
  baseline rather than pretending it still exists.
- **Preconditions stop destructive commands.** `uninstall-*` requires an installed
  product; `install-msi` requires an absent one; `upgrade-forward` and
  `downgrade-refused` require the supplied package to really be newer / older. An
  unmet precondition produces `unconfirmed` and **no command runs**.
- **Cleanup is self-contained and idempotent.** A process is terminated only when
  its pid is in this run's launch ledger *and* the live image name matches the
  recorded one. The only filesystem deletion is inside the harness output
  directory, and it is refused otherwise. `C:\Program Files\KanaAI` is removed by
  the uninstaller, never by this harness. Cleanup runs twice and both passes are
  recorded.
- **Every command is dry-rendered first.** The exact command line is printed as a
  `WHATIF: would run -> ...` line and recorded with the command before it starts,
  and `-WhatIf` renders everything without starting anything.

## Elevation and the UAC expectation

`KanaAI.wxs` is `Scope="perMachine"`, so a real run needs an **elevated 64-bit
PowerShell** (right-click, Run as administrator). Start the harness from that
shell. Two consequences, stated plainly because they are real behaviour and not
something this harness controls:

- Run from an elevated shell, there is **no UAC prompt**: the `msiexec` install
  runs in a process that is already elevated. The harness will not prompt, and
  will not click anything.
- If instead a user double-clicks `Setup.exe` from Explorer, `Setup.manifest`
  requests `asInvoker`, so `Setup.exe` itself is **not** elevated. The UAC consent
  dialog then comes from the `msiexec.exe` child that `Setup.exe` starts
  (`Setup.cs:24-27`), after `Setup.exe` has already shown its own window. This
  harness does not run `Setup.exe` that way; it runs it from the already-elevated
  shell, and the difference is recorded by the fact that the run is elevated.

`Setup.exe` is a `winexe` that shows a **modal message box** after `msiexec`
returns and only then exits with msiexec's code (`Setup.cs:31-38`). The harness
starts it and waits; it cannot and will not dismiss that box. **An operator must
click OK on it during the `install-setup` phase**, and the phase timeout (3600
seconds) is sized for that. If the operator does not, the phase times out, the
harness terminates that one process, and the phase is a failure with the exact
command line in the receipt.

## What is still unverified

Everything below is unverified, and this harness has not begun to change that:

- No `Setup.exe` install has been run. The one-double-click path is untested.
- No MSI install or uninstall has been run. The TSF registration has never been
  observed to appear or disappear on a real machine through this harness.
- Reinstall-over-the-same-product-code has not been run. Whether the Windows
  Installer log carries a decisive `REINSTALL` marker on this machine is unknown;
  if it does not, that phase is designed to report `unconfirmed` rather than
  guess.
- The upgrade-forward and downgrade-refused phases have not been run. The
  `1638` expectation comes from `KanaAI.wxs:5` and the Windows Installer
  documentation, not from an observation on this machine.
- Whether the pinned `INSTALLFOLDER` really resolves to `Program Files\KanaAI` on
  a 64-bit package is unmeasured here; the harness records what it observes.
- The registration identity is still `identityApproved: false` in
  `platform/windows-tsf/registration/registration.json`, and
  `KanaAI.TsfTip.dll` is still `presentInSourceTree: false`. Whether the shipped
  helper registers `KanaAI.TsfTip.dll`, `mozc_tip64.dll` or something else is not
  asserted by this harness; it records the `InProcServer32` value it actually
  reads and then checks whether a real file is there.
- The self test and plan-only mode prove the harness's own logic only. They are
  not evidence about the product, and they do not make W2 any closer to verified.
- The observation half of `LifecycleValidation.Common.ps1` (the Windows Installer
  COM calls, the MSI table walks, the registry reads, the process launch) has
  never been executed. It is written, reviewed and parse-checked, and that is the
  whole of its track record. The first real run must be treated as the first
  execution of that code.

## Non-goals

- Proving the installed TIP converts romaji to kana in a running application.
  That is the desktop-input verification stage; this harness launches no
  application and touches no desktop.
- Proving the local AI payload runs or produces acceptable output.
- Proving rollback of a failed upgrade, or repair of a deliberately corrupted
  file.
- Producing a signed, released or generally available product.
