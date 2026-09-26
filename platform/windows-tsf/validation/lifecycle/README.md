# KanaAI installer lifecycle verification (verification stage W2)

## Status: THREE `-Execute` RUNS HAVE HAPPENED. W2 IS **NOT** VERIFIED.

This section used to say that no lifecycle run had ever happened. That was
false. `-Execute` has been run three times on this machine and the receipts
exist; see [What is still unverified](#what-is-still-unverified) for what each run
established.

W2 is still not verified, for one reason: **no receipt yet exists in which every
phase passes.** The most recent run
(`.local/w2-execute-20260926-202806/w2/receipt.json`, `exitCode = 1`) records
`UF-01` and `DR-01` as failures, and the fixes for both have not been executed.
The three defects those two phases hit were found and fixed in this directory
after that run:

1. the `product-code` expectation was compared against the plan's instruction text
   and was keyed off the phase name, so it reported two equal codes as a
   disagreement and pointed `downgrade-refused` at the wrong product (`d754745`);
2. the verbose log classifier was a bag of mutually exclusive markers whose
   patterns could never match a real log, so it could not decide four of the
   phases that assert it;
3. the plan expected `1638` for a refused downgrade when this package's
   `LaunchCondition` returns `1603` under `/qn`.

The first and the third are harness and plan defects. The second is a harness
defect that hid the third. None of them is a product defect, and none of them may
be written up as one.

A W2 claim may only come from a receipt written by an `-Execute` run, on a real
machine, for one fixed-hash candidate, **in which no phase failed**. Until then,
do not report W2 as passed.

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
| MSI directory id | `INSTALLFOLDER`, leaf `KanaAI`, parent `ProgramFiles64Folder` | `KanaAI.wxs:10-12` |
| TIP CLSID | `{7E7B5C1E-6D3A-4F2C-9A0E-3F4B5D6C7E81}` | `platform/windows-tsf/registration/registration.json`, `installer/Common-TsfRegistration.ps1:11` |
| Language profile GUID | `{F3C2B7A1-6D54-4E8B-9A10-2C7D8E9F0A12}` | `registration.json`, `Common-TsfRegistration.ps1:12` |
| Language segment / id | `0x00000411` / 1041 | `Common-TsfRegistration.ps1:13-14` |
| Machine registration surface | `HKLM\SOFTWARE\Microsoft\CTF\TIP\<CLSID>` and `...\LanguageProfile\0x00000411\<profile>`, plus `HKLM\SOFTWARE\Classes\CLSID\<CLSID>\InProcServer32`, 64-bit view | `Common-TsfRegistration.ps1:531-549` |
| Product executables watched | `mozc_server.exe`, `mozc_broker.exe`, `mozc_renderer.exe`, `kanai-broker.exe`, `llama-server.exe` | `scripts/build-windows-installer.ps1:72-98` |

`ProductCode` is **not** pinned: WiX derives it from the version, so the harness
reads it out of the candidate MSI's own `Property` table and requires the
installed product to be exactly that code.

### One disagreement with the work ticket, and one with our own first reading

The work ticket for this harness said the package installs into
`Program Files (x86)\KanaAI`.

Our own first reading went the other way: it said `<StandardDirectory
Id="ProgramFilesFolder">` in a package built with `wix build -arch x64` resolves
to the **64-bit** Program Files, and cited the sibling registration slice's
`C:\Program Files\KanaAI\TSF` for x64 (`platform/windows-tsf/installer/README.md:62-68`).
**That reading was wrong, and it was settled by measurement rather than by
argument.** `KanaAI.wxs:10` said `ProgramFilesFolder`, and `ProgramFilesFolder`
is the 32-bit directory in every Windows Installer context: the older x86
candidate and the `0.0.9` / `0.1.1` upgrade fixtures all installed to
`C:\Program Files (x86)\KanaAI` and their verbose logs record
`INSTALLFOLDER = C:\Program Files (x86)\KanaAI\`, while the same logs record
`ProgramFiles64Folder = C:\Program Files\`. The `wxs` is now
`ProgramFiles64Folder` (`KanaAI.wxs:10`), and the 64-bit candidate installs to
`C:\Program Files\KanaAI` — measured, in the run receipt.

The lesson generalises past this file: **a standard directory's bitness is a
property of Windows Installer, not of the `-arch` a package was built with.**
The same confusion is what made the upgrade fixtures look like a harness fault.

This harness therefore does not assert a hand-written absolute path. It resolves
the directory chain from the candidate MSI's own `Directory` table, records the
resolution and its reason in the receipt, and after the install it reads the
authoritative location back from the Windows Installer
(`ProductInfo(InstallLocation)`). The receipt states which of the two paths was
observed.

## Files

| File | Lines | Purpose |
| --- | --- | --- |
| `Invoke-KanaAiLifecycleValidation.ps1` | 1191 | Entry point. Modes `-PlanOnly`, `-SelfTest`, `-Execute`. Gates, phase loop, receipt. |
| `LifecycleValidation.Common.ps1` | 2997 | Shared helpers, split into a pure half (plan validation, comparison engine, verdict engine, log classifier, resume planner, receipt assembler, privacy scan) and an observation half that every function routes through one action gate. |
| `Invoke-KanaAiLifecycleValidationSelfTest.ps1` | 1582 | 87 self-test cases. No machine interaction. Synthetic inputs, plus the decisive msiexec lines of the five classified logs of one real measured run, reduced to the tokens that are evidence. |
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

Exit code 0 when all 87 cases pass, 1 otherwise. Or through the entry point with
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
- **verbose log** — read for **facts** and then classified by an ordered
  derivation, not matched against one marker per outcome. An unclassifiable or
  self-contradicting log is `unconfirmed`.

### How a verbose log is classified, and why it is not a marker bag

The classifier used to be four mutually exclusive markers and required exactly
one to fire. Measured against the six real logs of one W2 run
(`.local/w2-execute-20260926-202806/w2`), that rule classified **one** of them,
called three `ambiguous-multiple-markers`, and found nothing in the sixth — and
four of the eleven phases assert this check, one of them as a **required** check
that could therefore never pass.

The reason is that the facts that identify a log are not exclusive. A reinstall
contains an install sequence. A MajorUpgrade contains a product removal. An
uninstall contains both. A bag of markers cannot tell *two facts that belong
together* from *two facts that contradict each other*.

So the log is read once for facts, and the classification is derived from them in
order. Every fact pattern is anchored on a token msiexec emits in the same shape
on every localisation; the Japanese text is an extra alternative, never the only
way to see a fact.

| Fact | Read from | Meaning |
| --- | --- | --- |
| `alreadyInstalled` | `Property(S): ProductState = 5` | the product was already registered when this transaction started. `5` is `INSTALLSTATE_DEFAULT`, the same value `Get-KanaAiLifecycleProductInstallStateName` maps |
| `installDatePresent` | `Property(S): Installed = <date>` | the cached install date, written only for an already-registered product |
| `productRemoved` | `CleanupConfigData(RemovingProduct=1)` | **this** transaction removed the product. `RemoveExistingProducts` in a MajorUpgrade is not that, which is why `RemoveFiles` is not used at all |
| `upgradeDetected` | `Adding WIX_UPGRADE_DETECTED property` | `FindRelatedProducts` found a strictly older related product |
| `downgradeDetected` | `Adding WIX_DOWNGRADE_DETECTED property` | it found an equal-or-newer one, and the package refuses |
| `reinstallRequested` | `Property (REINSTALL):` or `Property(S): REINSTALL =` | a reinstall or repair was asked for explicitly. The shipped plan never asks, so a real W2 log does not carry it |
| `installSequence` | `Doing action: InstallInitialize` and its two other spellings | an install transaction ran |
| `legacy1638` | `Error 1638` and its localised form | the documented version-conflict refusal, for a package that reports it that way |

The derivation, in order, with the earlier rules being the stronger facts:

1. `upgradeDetected` **and** `downgradeDetected` → `ambiguous-multiple-markers`.
   `FindRelatedProducts` cannot set both in one transaction, so a log that claims
   it did is not believed.
2. `downgradeDetected` or `legacy1638` → `downgrade-refused`.
3. `upgradeDetected` → `upgrade`.
4. `alreadyInstalled` and `productRemoved` → `uninstall`.
5. `alreadyInstalled` → `reinstall`. This is the decisive difference from a first
   install, and it does **not** need a `REINSTALL` property: a first install
   starts with the product absent.
6. `reinstallRequested` → `reinstall`.
7. `installSequence` and not `productRemoved` → `first-install`.
8. anything else → not confident.

`any` is an instruction, not a classification name: any confident classification
satisfies it, and it still cannot rescue a log that could not be classified. It
used to be compared like a name, so it could only ever fail — which is why every
phase that used it also had to mark the check not required.

Two traps this table exists to close, both found by reading real logs:

- **Nothing may be anchored with `^`.** A verbose log prefixes every line with
  `MSI (s) (pid) [time]: `. The earlier patterns were anchored, so they matched a
  real log exactly never, and the self test used strings without the prefix — so
  the cases passed while the check could not fire on any run. ST-83 drives both
  shapes.
- **The facts are read out of real logs, not invented.** ST-82 carries the
  decisive lines of the five classified logs of the measured run, with the
  account name, the install path and the log bulk left out because none of them is
  evidence.

### The refused downgrade returns 1603, not 1638

`KanaAI.wxs` sets `MajorUpgrade/@DowngradeErrorMessage`. WiX compiles that into
the launch condition `NOT WIX_DOWNGRADE_DETECTED`, read out of the package's own
`LaunchCondition` and `Upgrade` tables. A failed launch condition under `/qn` is
**1603**; 1638 is the code Windows documents for the same policy and is what a
bundled install reports. Measured on this machine, installing 0.0.9 over 0.1.1:

```
PROPERTY CHANGE: Adding WIX_DOWNGRADE_DETECTED property. Its value is '{B89B09D1-...}'.
Action start name="LaunchConditions" ...  returned 3
MainEngineThread is returning 1603
```

The phase therefore accepts exactly `{1603, 1638}` and nothing else, and the exit
code decides nothing on its own: the refusal is proven by `msi-log-classification`
(the `WIX_DOWNGRADE_DETECTED` assignment, which only this transaction can make),
`product-state`, `product-code` and `file-inventory-unchanged` together. An
earlier version of this plan named `1638` from documentation rather than from an
observation, so a correct machine failed the phase.

### The `product-code` expectation is an instruction, never a value

`ProductCode` is derived by WiX from the version, so the plan cannot state one.
Every `product-code` assertion therefore carries a short **instruction** that
says where the expected code has to come from, and the harness resolves that
instruction to a real product code before it compares anything. The instruction
is never itself compared to a product code.

| Instruction | Resolves to | Phases | If it cannot be resolved |
| --- | --- | --- | --- |
| `from-candidate-msi` | the candidate MSI's own `ProductCode`, read from that package's `Property` table | `install-setup`, `install-msi`, `reinstall-same` | `unconfirmed` |
| `from-newer-msi` | the newer fixture MSI's own `ProductCode`, read from that package's `Property` table | `upgrade-forward` | `unconfirmed` (e.g. no `-CandidateMsiNewer`) |
| `from-current-msi` | the product code that was installed **immediately before this phase's command ran** | `downgrade-refused` | `unconfirmed` |
| anything else | nothing | none | `unconfirmed`, with the instruction named |

`from-current-msi` is the one that is not about a package. After a refused
downgrade the installed product code must still be the one that was there
before the command ran — by then the newer fixture's, because `upgrade-forward`
replaced the candidate. A downgrade that quietly replaced the product is a
policy failure; the *candidate's* product code is not what this phase is
asserting.

The expectation is resolved from the phase's own instruction, never from the
phase's name, and the receipt records all four facts so a reader can audit the
wiring without trusting it: `expectedProductCode` (the resolved value),
`expectedProductCodeSource` (`candidate-msi`, `newer-msi`,
`installed-before-this-phase`, `not-asserted` or `unknown-instruction`),
`expectedProductCodeInstruction` (the plan's own text) and
`productCodeBeforeCommand` (what was installed before the command started).
If the recorded source is not the one the instruction permits, the check is
`unconfirmed`: two equal codes reached the wrong way round are a coincidence,
not evidence.

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

## Known prohibitions, and the self-test case that enforces each

These are the mistakes this harness has already made once, or has been built to
be unable to make. Each one is a rule, and each rule is enforced by a named
self-test case rather than by convention — which is the only thing that makes it
stick, because ST-69 is the record of a case that pinned the wrong P/Invoke
prototype and passed the bug it was written to catch.

- **Never compare a resolved product code against a raw plan expectation.** A
  `product-code` expectation is a resolution instruction. Comparing a GUID with
  the instruction text is always false, so the check could only ever fail, and a
  correct forward upgrade was failed with the self-contradictory line "the
  installed product code is `'{B89B09D1-…}'`, expected `'{B89B09D1-…}'`". Enforced
  by ST-77 (all three instructions, each driven with two equal codes, each must
  pass and none may quote the instruction in its verdict) and ST-81 (`$installed
  -eq $expect` may not exist in the shared helpers at all).
- **Never let an unresolvable or mis-wired expectation become a verdict.** An
  instruction this harness does not implement, a blank expected code, a missing
  before-picture, and a provenance that does not match the instruction are all
  `unconfirmed` with the reason named — never a pass, and never a `fail` either,
  because a failure accuses the machine of a comparison that was never made.
  Enforced by ST-78.
- **Never emit a failure whose two codes are equal.** A disagreement states two
  different codes. Enforced by ST-79, which drives every failure path and
  compares the two codes the detail names.
- **Never key a phase's expectation off the phase's name.** One phase name
  having a phase-correct expectation left every other phase silently inheriting
  the candidate MSI's product code, so `downgrade-refused` compared itself
  against `{CD242B2B-…}` after `upgrade-forward` had already replaced the
  installed product with `{B89B09D1-…}`. The expectation comes from the phase's
  own instruction, and the before-picture is captured *before* the command
  starts. Enforced by ST-80 (the shipped plan's own phases, driven through the
  resolver) and ST-81 (the call site, the arguments and the ordering).
- **Never decide a phase from a command exit code alone**, and never let a
  registry key with no real file behind it count as a registration. Enforced by
  ST-10, ST-12, ST-13, ST-28, ST-29 and ST-30.
- **Never identify a log by one marker, and never anchor a pattern to the start
  of a line.** The facts that identify a transaction are not exclusive — a
  reinstall has an install sequence, a MajorUpgrade has a product removal, an
  uninstall has both — so mutually exclusive markers call ordinary runs
  ambiguous. And a verbose log prefixes every line, so `^` matches a real log
  never. Both were true at once, and the self test could not see either because
  its strings had no prefix. Enforced by ST-07, ST-82 and ST-83.
- **Never let an expectation be a name the machinery cannot produce.** Every
  `msi-log-classification` expectation in the plan is checked against the
  classifications the classifier really emits, and against the measured log of
  the phase that asserts it. `any` means any confident classification and cannot
  rescue an unclassifiable log. Enforced by ST-84 and ST-85.
- **Never let a plan claim something the artifact does not contain.** RS-01's
  `proves` list said the log shows a `REINSTALL` property, for a phase whose own
  command deliberately supplies none. It never could, and the real log does not.
  The decisive evidence is the log's record that the product was already
  registered when the transaction started. Enforced by ST-82, ST-84 and ST-86.
- **Never nest one self-test case inside another case's body.** ST-63 to ST-66
  once ended up inside ST-62: the file still parsed and every case still
  reported ok, but the outer cases could no longer fail on their own. Enforced
  structurally by ST-71, over the AST of this very file.
- **Never write a case that guards a mistake instead of the fix.** Every case
  above is driven with the *old* failing shape as well as the new one wherever
  that is possible without machine access.

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

**Three `-Execute` runs have happened.** Their receipts are in
`.local/w2-execute-*`. The most recent is
`.local/w2-execute-20260926-202806/w2/receipt.json`. What those runs established,
and what they did not, is stated here rather than left to a reader of the JSON:

| Phase | Run #3 outcome | What is still open |
| --- | --- | --- |
| `PF-01` / `PF-02` | pass | — |
| `IS-01` `Setup.exe` | **all checks pass** | the operator still has to click the launcher's modal box; the harness cannot |
| `UC-01` clean uninstall | pass | — |
| `IM-01` MSI install | pass except `msi-log-classification`, recorded `unconfirmed` | the classifier has since been rewritten; the new verdict needs a new run |
| `RS-01` reinstall | pass except `msi-log-classification`, `unconfirmed` | as above. The log carries no `REINSTALL` property and cannot: the phase supplies none |
| `UF-01` upgrade forward | **fail**: `product-code` and `expected-files` | `product-code` failed on the defect fixed in `d754745`; `expected-files` failed because the 0.1.1 fixture was built from a **32-bit** `KanaAI.wxs` while the candidate installs 64-bit, so its files went to a different directory |
| `DR-01` downgrade refused | **fail**: `command-exit-code` and `product-code` | the exit code was the `1603` finding resolved above; `product-code` failed on the same `d754745` defect; the 0.0.9 fixture has the same 32-bit problem |
| `UC-02` / `OB-01` / `CL-01` | pass | — |

Still unverified, and this harness has not begun to change any of it:

- **No run has yet produced a W2 receipt in which every phase passes.** Run #3
  still carries `UF-01` and `DR-01` as failures, and the fixes for them have not
  been executed. Until a receipt says so, W2 is not verified.
- The 0.1.1 and 0.0.9 upgrade/downgrade fixtures have not been rebuilt from the
  current 64-bit `KanaAI.wxs`. Until they are, `UF-01` and `DR-01` cannot pass
  their `expected-files` check, whatever the harness does.
- Whether the pinned `INSTALLFOLDER` resolves to `Program Files\KanaAI` is now
  **measured**: the run recorded the resolution, and it agrees with the 64-bit
  `ProgramFiles64Folder` in the current `KanaAI.wxs:10`.
- The `product-code` expectations of `upgrade-forward` and `downgrade-refused`
  have not been exercised against a machine that passes them. Their logic is
  proven by ST-77 to ST-81 against synthetic data, and their previous verdicts
  were the self-contradicting line `d754745` removed, but only a new receipt can
  turn them into an observation.
- The registration identity is still `identityApproved: false` in
  `platform/windows-tsf/registration/registration.json`, and
  `KanaAI.TsfTip.dll` is still `presentInSourceTree: false`. Whether the shipped
  helper registers `KanaAI.TsfTip.dll`, `mozc_tip64.dll` or something else is not
  asserted by this harness; it records the `InProcServer32` value it actually
  reads and then checks whether a real file is there. The runs did observe real
  TIP, language-profile and COM keys appearing and disappearing, so the surface is
  reachable; which DLL it should point at is still undecided.
- The self test and plan-only mode prove the harness's own logic only. They are
  not evidence about the product, and they do not make W2 any closer to verified.
- The runs were made against a candidate built from an earlier commit, not from
  the current `main`. Any statement here about the product is about that
  candidate's hashes, as recorded in its `pinnedIdentity` block.

## Non-goals

- Proving the installed TIP converts romaji to kana in a running application.
  That is the desktop-input verification stage; this harness launches no
  application and touches no desktop.
- Proving the local AI payload runs or produces acceptable output.
- Proving rollback of a failed upgrade, or repair of a deliberately corrupted
  file.
- Producing a signed, released or generally available product.
