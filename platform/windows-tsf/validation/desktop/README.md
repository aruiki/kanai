# KanaAI desktop IME input validation harness

日本語版要約: このハーネスは「API が成功を返した」ことだけを根拠に IME 入力の
成功を判定しない。すべての判定は、注入 API と無関係な経路 (ウィンドウメッセージ、
UI Automation、対象プロセスが自分で書き出す状態ファイル、ウィンドウ列挙) で
取得した観測値だけに基づく。実際の入力テストはまだ一度も実行していない。W1 は
未検証のまま。本ディレクトリ以外には何も変更していない。

---

## 1. Why this exists

`.local/validation/w1/` records a failed attempt at exactly this job. In that run
`SendInput` returned a non-zero event count for every keystroke, and that return
value was written down as if it were evidence of delivery. It was not:

* no key reached a Notepad document, a Win32 `EDIT`, or the IME indicator;
* `mozc_tip64.dll` was never loaded into the target process, so the installed TIP
  was never the active input processor for it;
* the operator later reported that **manual** typing, conversion and kana
  switching all worked in the installed build.

So the input path was fine and the injection path was broken, and the evidence
could not tell those two apart. **That is the defect this harness exists to
eliminate:** an API return value is not an observable.

## 2. The design decision that makes delivery confirmable

A step becomes `passed` only when an **independent readback** of observable state
matches the plan's expectation. There are four such channels, and none of them
is the code path that injected the key:

| channel | what it reads | independence |
|---|---|---|
| `wm-gettext` | `SendMessageTimeout(WM_GETTEXT)` on the target's edit control | a window message answered by the target process |
| `uia-text-pattern` | `TextPattern.DocumentRange` on the target window | a COM/UIA query, cross-process |
| `target-state-file` | text the target process itself writes while exiting | the target's own account, no message and no API return anywhere |
| `candidate-window-enumeration` | `EnumWindows` filtered by IME class name and owning process | window enumeration, independent of the input queue |

The verdict function is
`Resolve-KanaAiValidationStepVerdict` in `DesktopValidation.Common.ps1`, and its
parameter list deliberately **has no parameter that can carry an API return
value** (`apiOk`, `sentEvents`, `lastError` and friends are absent). The API
results are attached to each step result as `apiResults` for diagnosis, and are
structurally incapable of influencing `verdict`. Self-test `ST-27` asserts that
absence by reflecting over the function's own parameters, and `ST-26` replays
the exact W1 shape (API reported success, readback did not change) and asserts
the verdict is `failed`.

Three further rules make the result interpretable instead of ambiguous:

1. **Injector loopback first (`INJ-00`).** Before any application is touched,
   the harness types the canary into a window it created itself and reads it back
   with a window message. If that fails, the injector is broken and the receipt
   says so; the IME is not blamed.
2. **Symmetric IME toggle calibration (`CAL-01`..`CAL-08`).** The harness never
   assumes a starting IME state. It toggles, commits, toggles back and commits
   again. Whichever direction committed kana *is* the IME-on direction; the
   number of toggles needed later is derived from that. If the two commits are
   both kana or both ASCII, the toggle did not change the input processor, the
   direction stays unknown, and every direction-dependent step is recorded as
   `blocked` — never as passed.
3. **Two discriminating assertions are mandatory.** The plan validator rejects
   (`PLAN-MISSING-IME-ON-KANA`, `PLAN-MISSING-IME-OFF-ASCII`) any plan that does
   not assert *both* "the committed canary contains kana" and "the committed
   canary is exactly the ASCII canary". The same injected bytes producing two
   different committed results is what separates a working input processor from a
   dead session, and a plan that cannot show the difference is not worth running.

## 3. What the canary is, and why it is what it is

| | value |
|---|---|
| romaji / ASCII form | `kanaai` (six keystrokes) |
| kana form | `かなあい` (`U+304B U+306A U+3042 U+3044`) |
| documented in code | `Get-KanaAiValidationCanaryRomaji`, `Get-KanaAiValidationCanaryKana` |
| declared in the plan | `canary.romaji`, `canary.kana`, `canary.kanaCodePoints` |

The two forms are **deliberately the same letters**. The harness types exactly
the same injected keystrokes in both IME directions, so the *only* difference
between the two results is the input processor itself. Any step whose
`input.text` is not this string is rejected by the plan validator
(`PLAN-CANARY-TEXT-FORBIDDEN`), so the harness cannot type into anything by
accident. This is the only text this harness ever types anywhere.

The plan validator also re-derives `canary.kana` from `canary.kanaCodePoints` and
fails with `PLAN-KANA-CODEPOINT-MISMATCH` if they disagree — the symptom of a
plan file that was decoded with the wrong code page. That check has already
caught a real error in this repository's own plan file.

## 4. Files

| file | purpose |
|---|---|
| `Invoke-KanaAIDesktopValidation.ps1` | entry point: plan-only, self-test, cleanup-only, real run |
| `DesktopValidation.Common.ps1` | pure logic only: hashing, JSON, plan validation, verdict rule, comparison, privacy scan, cleanup planning, native wiring scan |
| `DesktopValidation.Native.cs` | P/Invoke layer: window station/desktop, session, integrity, DPI, focus, caret, enumeration, loaded modules, `SendInput`, the harness loopback window |
| `DesktopValidation.ProbeHost.cs` | the target application the harness launches: a real separate Win32 process with a real multiline `EDIT` |
| `Invoke-KanaAIDesktopValidationSelfTest.ps1` | 53 synthetic-data test cases, no desktop, no process launch |
| `desktop-validation-plan.json` | the run manifest: 36 steps with their action, expected observable and readback method |
| `runs/` | generated output (receipts, plan copies, self-test report). Safe to delete. |

## 5. Commands

All paths are relative to the repository root. Windows PowerShell 5.1 is the
supported host; `-NoProfile` matters because a profile could load modules or
change the window station.

### 5.1 Self-test (no desktop interaction, safe at any time)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File platform\windows-tsf\validation\desktop\Invoke-KanaAIDesktopValidationSelfTest.ps1
```

Exit `0` when all 53 cases pass, `1` otherwise. Last report:
`platform\windows-tsf\validation\desktop\runs\self-test-last.json`.

### 5.2 Plan-only (no desktop interaction, safe at any time)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File platform\windows-tsf\validation\desktop\Invoke-KanaAIDesktopValidation.ps1 -PlanOnly
```

Validates the plan and the harness wiring, writes `runs\<runId>\plan.json` and
`runs\<runId>\receipt.json`, and exits `0`. It returns before any native type is
loaded, any process is started, any window is created, any key is injected and
any registry key is read, and the receipt says so in
`desktopInteraction.statement`.

Add `-AllowMachineInspection` to also collect read-only registry and installed
file data (OS build, installed `ProductCode`, KanaAI TIP `InprocServer32` path
and its SHA-256). It still performs no desktop interaction and never installs,
registers or unregisters anything.

### 5.3 A real run — requires the coordinator's go-ahead and the `machine` lock

```powershell
scripts\with-development-lock.ps1 -Name machine {
    powershell -NoProfile -ExecutionPolicy Bypass -File `
        platform\windows-tsf\validation\desktop\Invoke-KanaAIDesktopValidation.ps1 `
        -AllowDesktop -LockConfirmed -LockName machine
}
```

The run **refuses to start** (`exit 3`, and a `run-refused` receipt is written)
unless all of the following hold:

* `-AllowDesktop` is present — the operator authorises injecting keystrokes into
  the shared interactive desktop;
* `-LockConfirmed` is present — the operator asserts the coordinator granted the
  go-ahead;
* `-LockName` is exactly `machine`;
* the plan validates and the native wiring check passes.

The harness cannot verify that `scripts\with-development-lock.ps1 -Name machine`
is actually held. It records only that the operator asserted it
(`gates.machineLockNote`). Only the coordinator can grant that, and the lock must
be the coordinator's to take.

Useful switches for a real run:

| switch | effect |
|---|---|
| `-Target probehost` | default. Launches the harness-owned probe host |
| `-Target notepad` | external app; also requires `-AllowExternalTarget`, never records document text, and never closes a window it did not open |
| `-AllowMachineInspection` | read-only registry and installed-file data |
| `-AllowScreenshots` | PNG of the target window, harness-owned target only |
| `-AllowExternalTextCapture` | record document text even when the target's policy forbids it |
| `-SkipCompile` | fail instead of building `bin\*.dll` when they are missing |
| `-NativeDll`, `-ProbeHostExe` | use prebuilt binaries from somewhere else |
| `-OutputDirectory`, `-ReceiptPath`, `-Plan` | override the usual locations |

### 5.4 Cleanup of a previous run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
    platform\windows-tsf\validation\desktop\Invoke-KanaAIDesktopValidation.ps1 `
    -CleanupOnly -AllowDesktop -LockConfirmed -LockName machine `
    -OutputDirectory platform\windows-tsf\validation\desktop\runs\<runId>
```

## 6. Exit codes

| code | meaning |
|---|---|
| `0` | `passed`, `plan_only`, or `self_test_passed` |
| `1` | `failed` — at least one asserted step's readback did not match, or the privacy scan rejected the receipt |
| `2` | `unconfirmed` — every assertion agreed, but a critical finding (window station/desktop mismatch, TIP DLL never loaded) or a `delivery_unconfirmed` step means no product verdict may be claimed |
| `3` | `incomplete` — a step was `blocked` or `not_run`, or the run was refused by a gate |
| `4` | harness error — the native layer would not load, or a required file is missing |

`record_only` steps never influence the exit code. They are declared
non-gating in the plan and reported as observations.

## 7. How to read a receipt

Top-level fields:

| field | what to look at |
|---|---|
| `overall`, `exitCode` | the single verdict and its exit code |
| `verdictCounts` | per-verdict tally, so a `passed` run cannot hide a `blocked` step |
| `steps[]` | per step: `expected`, `input`, `apiResults` (diagnostic only), `readback`, `matchMode`, `reason`, `corroboration`, `verdict` |
| `findings[]` | named findings with `severity`. `critical` ones cap the run at `unconfirmed` |
| `desktopInteraction` | `performed`, `keystrokesInjected`, `processesLaunched`, `windowsCreated`, and a `statement` |
| `gates` | which authorisation switches were set, and the machine-lock caveat |
| `environmentStatic` | OS version, architecture, host PowerShell — collected with no desktop access |
| `machineInspection` | OS build, installed `ProductCode`, TIP DLL path and SHA-256, or an explicit reason why it was skipped |
| `wiring` | static source scan proving the PowerShell call sites and the C# surface agree |
| `planValidation` | `ok`, step count, every error code and warning |
| `imeCalibration` | which toggle direction committed kana, and how many toggles were needed |
| `targetSelfReport` | the text and module list the target process recorded about itself at exit |
| `candidateWindowObservation` | which class names were searched, whether a window belonged to the target, and whether any text readback produced candidate content |
| `cleanup`, `cleanupPasses` | every ledger entry, the action taken and the outcome |
| `artifacts[]` | `pathRelative`, `bytes`, `sha256` — paths are relative to this directory on purpose |
| `privacy.sanity` | the result of scanning the serialized receipt for leaks |

`apiResultNote` is repeated on every step for a reason: the numbers in
`apiResults` say only that the call was accepted. They are never a verdict.

## 8. Findings this harness raises by name

| id | severity | meaning |
|---|---|---|
| `WINSTA-DESKTOP-MISMATCH` | critical | the injector and the target do not share a window station and desktop. Injected input cannot reach a window on another desktop, and no API return value would ever reveal this |
| `TIP-DLL-NOT-LOADED` | critical | no `mozc_tip*` module was loaded into the target process, so the installed TIP was never its active input processor and no conversion result can be attributed to this build |
| `TARGET-CLOSE-REFUSED` | critical | the target window did not close; the harness refused to force-kill anything it could not identify as its own |
| `STEP-EXECUTION-ERROR` | critical | a step raised; its verdict is `failed` |
| `NATIVE-LOAD-FAILED` | critical | the native layer would not load, so no step ran |
| `TARGET-SELF-REPORT-UNREADABLE` | critical | the target's own account of itself could not be read |
| `WINSTA-DESKTOP-PARITY` | info | injector and target share a window station and desktop |
| `SCOPE-LIMIT` | info | appended only when every assertion passed, listing what the run still does not cover |

## 9. Cleanup: what makes a stray window or process impossible

W1 left a canary Notepad tab and a stray process behind. Four mechanisms make
that structurally impossible here:

1. **The default target is a harness-owned process.** `DesktopValidation.ProbeHost.cs`
   is a small Win32 application the harness compiles and launches. Notepad on
   Windows 11 is single-instance and restores the user's tab session, so a
   Notepad-based harness shares a process with the user's own documents; the
   probe host never does. `-Target notepad` exists but is opt-in, requires
   `-AllowExternalTarget`, and the harness will not close a window it did not open.
2. **The ledger records identity, not names.** Every object the harness creates
   is appended to `launch-ledger.json` with the process id, start time and
   executable path, or the window class. Cleanup terminates by pid *only* after
   the live process path matches the recorded executable; a mismatch is
   `refused`, never force-killed.
3. **Windows are closed by class match.** `CloseWindowIfOwned` requires the live
   window class to equal the class the harness registered, so cleanup cannot
   reach a window the harness did not create.
4. **Cleanup is idempotent by construction.** `Resolve-KanaAiValidationCleanupPlan`
   is a pure function of (ledger, live state). After a clean pass, every entry
   resolves to `already-clean` or `verify-absent`; only `terminate-by-pid`,
   `close-window` and `delete-file` mutate anything. Plan step `CLN-02` runs a
   second pass in the same run and asserts the target window is still gone, and
   self-tests `ST-41`..`ST-44` prove the property with synthetic ledgers,
   including an unknown ledger kind being reported rather than guessed at.

The ledger is written to disk as it grows, so `-CleanupOnly` works even after a
crashed run.

## 10. Privacy

Collected: the fixed canary, the target's document text, window classes and
geometry, the foreground window's class and process (**not** its title, which can
contain the operator's document name), process ids and start times, registry
values under the uninstall and `CLSID` keys, and file hashes.

Never collected: environment variables, clipboard contents, user documents or
their paths, any typed text other than the canary, window titles of applications
other than the target.

Enforcement is not just intent:

* artifact paths in a receipt are **relative to this directory**; an absolute
  path outside it would contain the operator's user name and is replaced by a
  bare file name;
* `New-KanaAiValidationTextObservation` records a SHA-256 and a length when the
  target's policy forbids recording text, and the raw value is simply absent;
* the serialized receipt is scanned for forbidden keys (`clipboard`, `token`,
  `apikey`, `userProfile`, `appData`, ...) and forbidden value patterns
  (`%VAR%`, `Bearer ...`, `-----BEGIN ... PRIVATE KEY-----`, `\Users\...\Documents\`,
  `\AppData\`) after the run, and the run is marked `failed` if the scan objects
  (`privacy.sanity`);
* the key scan walks the whole receipt tree, not just the top level.

## 11. Host notes that shaped the code

* **`@($list)` is broken here.** On this Windows PowerShell build
  (5.1.26100.9444) an array subexpression around a `List[object]` throws
  "Argument types do not match". Every list therefore goes through
  `ConvertTo-KanaAiValidationArray`, and every enumeration uses `foreach`.
  Self-test `ST-52` guards this.
* **No `Get-FileHash`.** SHA-256 uses `System.Security.Cryptography.SHA256`,
  streaming for files. Self-test `ST-04` checks the implementation against the
  published vectors for the empty string and `abc`.
* **Scripts are ASCII-only.** Windows PowerShell 5.1 decodes a BOM-less script
  with the system ANSI code page, so a kana literal in a `.ps1` would be
  corrupted on a machine whose code page is not UTF-8. All non-ASCII
  expectations live in the UTF-8 JSON plan and are validated by code point.
* **C# is language level 5** so it builds with the in-box compiler, with no
  NuGet and no msbuild:

  ```powershell
  $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  & $csc /nologo /target:library /platform:x64 /optimize+ `
      /out:bin\DesktopValidation.Native.dll DesktopValidation.Native.cs
  & $csc /nologo /target:winexe  /platform:x64 /optimize+ `
      /out:bin\KanaAIValidationProbeHost.exe DesktopValidation.ProbeHost.cs
  ```

  The harness builds these itself on the first real run if they are missing, and
  falls back to the in-process `Add-Type` compiler when no `csc.exe` is found.
  `-SkipCompile` turns a missing binary into an error instead.

## 12. Status — read this before trusting any run

**No real input test has been run. Nothing in this directory has touched the
interactive desktop, launched the probe host, injected a keystroke, or started
ctfmon, TSF, the broker or any model process.** W1 remains **unverified**: there
is still no independent evidence that the installed KanaAI TIP converts romaji to
kana in a running application, and the operator's manual report remains a user
statement rather than a machine capture.

What *has* been executed and verified, with these exact results:

| check | command | result |
|---|---|---|
| PowerShell 5.1 parser over all three `.ps1` files | `[System.Management.Automation.Language.Parser]::ParseFile` | 0 errors, 0 parse errors |
| self-test | `Invoke-KanaAIDesktopValidationSelfTest.ps1` | 53 cases, 53 passed, exit `0` |
| plan-only | `Invoke-KanaAIDesktopValidation.ps1 -PlanOnly` | 36 steps validated, 0 warnings, exit `0` |
| plan-only + machine inspection | `... -PlanOnly -AllowMachineInspection` | exit `0`; see below |
| gate refusal (no desktop) | `Invoke-KanaAIDesktopValidation.ps1` | refused both gates, exit `3` |
| C# build, both files, in-box `csc` | see 11 | exit `0` for both |
| native surface vs. call sites, by reflection over the built DLL | separate process, load and reflect | 22 called members, 0 missing |

The machine-inspection probe was run once, read-only, and its receipt is kept at
`runs\probe-machine-inspection\receipt.json`. It found, on this machine:

* OS: `Windows 10 Pro`, display version `25H2`, build `26200.9457`
  (the `ProductName` registry value is stale on Windows 11; `DisplayVersion`
  and `CurrentBuild`+`UBR` are the reliable fields);
* installed product: `KanaAI Development Preview` `0.1.0`, publisher
  `KanaAI Project`, install date `20260925`;
* KanaAI TIP CLSID `{7E7B5C1E-6D3A-4F2C-9A0E-3F4B5D6C7E81}` with
  `InprocServer32` = `C:\Program Files (x86)\KanaAI\mozc_tip64.dll`,
  SHA-256 `5be0b94fbcd0816771e76509aebcc2ce3c9533be7ad84f1e5632f0f9cfdfa47d`.

`ProductCode` and `InstallLocation` came back **empty** from that probe, even
though W1 recorded `{307FE767-2B88-4915-8337-6E35423976B7}`. The uninstall key
was read (its `InstallDate` was populated), so the field is being missed rather
than absent. Treat the `ProductCode` in a receipt from this harness version as
unconfirmed until that is fixed; the W1 value is not evidence for this run.

Still unverified, in order of how much it matters:

1. **The real input path.** Every step in the plan is untested against a live
   session. If the injector loopback `INJ-00` fails on the operator's desktop,
   the likely cause is the same one that broke W1: a shared desktop, a
   foreground lock, or a session that does not process injected input at all.
   That would be an environment result, not a product result, and the receipt
   would say so.
2. **The IME toggle binding.** `Ctrl+Space` is the Windows-standard
   activate/deactivate chord, but the installed Mozc build may bind it
   differently. If the two calibration commits come back identical, the
   direction-dependent steps are `blocked` rather than wrong, and the receipt
   names the cause. Re-run with a different `input.keys` in the plan if needed.
3. **Candidate window class names.** The searched list is a documented
   guess-check list, not a measured one. W1 never observed a candidate window,
   so this machine has no evidence of what class Mozc registers here. An
   unmatched class name is reported as `present: false` with the searched list
   attached; the harness does not claim the candidate window is absent from the
   system, only that no window of a known class was found.
4. **Candidate text.** Not readable through `WM_GETTEXT` or UI Automation, as far
   as anyone has measured. The harness attempts both readbacks and records the
   failure reason rather than guessing at candidate content.
5. **Cross-process IME open/closed state.** There is no honest way to read it;
   the harness records that fact and decides IME direction from committed text
   instead.
6. **The `-Target notepad` profile.** Declared in the plan, deliberately not
   implemented by the run loop. A plan step that selects it is recorded
   `blocked` with that reason. The external-target path is unexercised.
7. **`-CleanupOnly` against a real crashed run.** The pure planning logic is
   tested; the live execution path is not.
8. **Registry and installed-file inspection.** The read path is exercised once
   (see 12) and works, except that `ProductCode` and `InstallLocation` came back
   empty, which is an open defect, not a design choice.
9. **Screenshots.** Off by default, unexercised.

A green plan-only run and a green self-test mean the harness is wired correctly.
They say nothing whatsoever about whether KanaAI converts romaji to kana.
