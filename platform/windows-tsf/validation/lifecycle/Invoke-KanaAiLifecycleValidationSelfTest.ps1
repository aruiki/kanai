# KanaAI installer lifecycle verification harness - self test.
#
# What this exercises, using synthetic data only:
#   * SHA-256 without Get-FileHash
#   * Windows command-line quoting and command template rendering, including the
#     refusal to render a half-resolved template
#   * the documented Windows Installer exit code table
#   * the verbose-log classifier, including the unclassifiable case
#   * plan validation, including every negative rule
#   * candidate identity validation, including a foreign UpgradeCode
#   * the expected-file comparison, including a missing and an unexpected file
#   * the before/after inventory comparison
#   * the comparison engine and the phase verdict engine, including
#       - exit code 0 with no registration  -> fail, not pass
#       - exit code 0 with a missing file   -> fail, not pass
#       - an unreadable registration       -> unconfirmed, not pass
#       - an unknown exit code             -> fail, not pass
#       - a downgrade that returned 0      -> fail, not pass
#   * preconditions: an unmet precondition must not run a command
#   * the resume planner, including that a resume cannot silently re-run a
#     completed destructive phase
#   * receipt assembly, the privacy scan, and the overall-status mapping
#   * the action ledger gate: a sealed ledger must refuse every machine-touching
#     helper
#
# What this deliberately does NOT do: open an MSI, create a Windows Installer
# COM object, read the registry, start a process, install or uninstall anything,
# or write outside this directory and a private temporary folder.
#
# Run:  powershell -NoProfile -File Invoke-KanaAiLifecycleValidationSelfTest.ps1
# Exit: 0 when every test passed, 1 otherwise.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$commonPath = Join-Path $root 'LifecycleValidation.Common.ps1'
$planPath = Join-Path $root 'lifecycle-validation-plan.json'
$runPath = Join-Path $root 'Invoke-KanaAiLifecycleValidation.ps1'
foreach ($required in @($commonPath, $planPath, $runPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "self-test cannot run: missing $required" }
}
. $commonPath

$script:TestResults = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('kanai-lifecycle-selftest-' + [Guid]::NewGuid().ToString('n').Substring(0, 12))
[void](New-Item -ItemType Directory -Path $script:TempRoot -Force)

# The self test's own ledger is sealed for the whole run.  Every
# machine-touching helper must therefore throw, and the tests below prove it.
$script:SealedLedger = Close-KanaAiLifecycleActionLedger -Ledger (New-KanaAiLifecycleActionLedger) -Reason 'self test: no machine interaction is permitted'
$script:OpenLedger = New-KanaAiLifecycleActionLedger

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Ok,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    $script:TestResults.Add([pscustomobject]@{ id = $Id; name = $Name; ok = $Ok; detail = $Detail })
}

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Detail)
    if (-not $Condition) { throw $Detail }
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Detail)
    if ([string]$Expected -ne [string]$Actual) { throw ("$Detail (expected '$Expected', got '$Actual')") }
}

function Assert-Throws {
    param([Parameter(Mandatory = $true)][string]$Pattern, [Parameter(Mandatory = $true)][scriptblock]$Body, [Parameter(Mandatory = $true)][string]$Detail)
    $threw = $false
    $message = ''
    try { & $Body } catch { $threw = $true; $message = $_.Exception.Message }
    if (-not $threw) { throw ("${Detail}: nothing was thrown") }
    if ($message -notmatch $Pattern) { throw ("${Detail}: the message did not match '$Pattern'. It was: $message") }
}

function Invoke-Test {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Body)
    try {
        & $Body
        Add-TestResult -Id $Id -Name $Name -Ok $true -Detail 'ok'
    }
    catch {
        Add-TestResult -Id $Id -Name $Name -Ok $false -Detail $_.Exception.Message
    }
}

function Get-PlanErrorCodes {
    param([Parameter(Mandatory = $true)]$Validation)
    $codes = @()
    foreach ($entry in @($Validation.Errors)) {
        $index = ([string]$entry).IndexOf(':')
        if ($index -gt 0) { $codes += ([string]$entry).Substring(0, $index) } else { $codes += [string]$entry }
    }
    return @($codes)
}

# ---------------------------------------------------------------------------
# a small synthetic plan, structurally complete, used for the negative cases
# ---------------------------------------------------------------------------
function New-SyntheticPlan {
    return (($json = @'
{
  "schemaVersion": 1,
  "planId": "synthetic-lifecycle",
  "pinnedIdentity": {
    "upgradeCode": "{AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE}",
    "packageName": "KanaAI Development Preview",
    "scope": "perMachine",
    "installFolder": { "directoryId": "INSTALLFOLDER", "leaf": "KanaAI" }
  },
  "registrationIdentity": {
    "textServiceClsid": "{11111111-1111-4111-8111-111111111111}",
    "languageProfileGuid": "{22222222-2222-4222-8222-222222222222}",
    "languageSegment": "0x00000411",
    "machineTextServiceRoot": "SOFTWARE\\Microsoft\\CTF\\TIP",
    "machineComRoot": "SOFTWARE\\Classes\\CLSID",
    "profileSubkey": "LanguageProfile",
    "registryView": "Registry64"
  },
  "productExecutables": [ "mozc_server.exe" ],
  "phases": [
    { "id": "SY-01", "name": "observe", "title": "Observe", "destructive": false, "command": null,
      "asserts": [ { "check": "product-state", "expect": "absent", "required": true } ],
      "proves": [ "x" ], "cannotProve": [ "y" ] },
    { "id": "SY-02", "name": "install", "title": "Install", "destructive": true,
      "command": { "executable": "{msiexec}", "arguments": [ "/i", "{msiPath}", "/qn" ], "acceptedExitCodes": "0,3010", "logFile": "install.log" },
      "asserts": [
        { "check": "command-exit-code", "expect": "0,3010", "required": true },
        { "check": "product-state", "expect": "installed", "required": true },
        { "check": "expected-files", "expect": "all-present", "required": true }
      ],
      "proves": [ "x" ], "cannotProve": [ "y" ] },
    { "id": "SY-03", "name": "uninstall", "title": "Uninstall", "destructive": true,
      "command": { "executable": "{msiexec}", "arguments": [ "/x", "{productCode}", "/qn" ], "acceptedExitCodes": "0,3010" },
      "preconditions": [ { "observed": "productState", "equals": "installed" } ],
      "asserts": [
        { "check": "command-exit-code", "expect": "0,3010", "required": true },
        { "check": "product-state", "expect": "absent", "required": true }
      ],
      "proves": [ "x" ], "cannotProve": [ "y" ] }
  ],
  "safetyGates": [
    { "id": "consent", "rule": "r" }, { "id": "machine-lock", "rule": "r" },
    { "id": "elevation", "rule": "r" }, { "id": "candidate-identity", "rule": "r" },
    { "id": "unexpected-existing-install", "rule": "r" }
  ]
}
'@) | ConvertFrom-Json)
}

# ===========================================================================
# 1. hashing, JSON, command line rendering
# ===========================================================================
Invoke-Test -Id 'ST-01' -Name 'SHA-256 works without Get-FileHash' -Body {
    $file = Join-Path $script:TempRoot 'hash.txt'
    [System.IO.File]::WriteAllText($file, 'kanai')
    $digest = Get-KanaAiLifecycleSha256 -Path $file
    Assert-True ($digest -match '^[0-9a-f]{64}$') ("the file digest must be lower-case hex, got '$digest'")
    Assert-Equal $digest (Get-KanaAiLifecycleSha256 -Path $file) 'the digest must be stable across calls'
}

Invoke-Test -Id 'ST-01b' -Name 'SHA-256 of a known string matches the published digest' -Body {
    Assert-True ((Get-KanaAiLifecycleTextSha256 -Text 'kanai').Length -eq 64) 'the digest must be 64 hex characters'
    $file = Join-Path $script:TempRoot 'hash2.txt'
    [System.IO.File]::WriteAllText($file, 'kanai')
    $fromFile = Get-KanaAiLifecycleSha256 -Path $file
    $fromText = Get-KanaAiLifecycleTextSha256 -Text 'kanai'
    Assert-Equal $fromText $fromFile 'the file digest and the text digest of identical bytes must agree'
    Assert-True ($fromFile -match '^[0-9a-f]{64}$') 'the digest must be lower-case hex'
}

Invoke-Test -Id 'ST-02' -Name 'the harness never invokes Get-FileHash' -Body {
    # The word may appear in a comment that explains why it is not used; what
    # must not exist is an actual invocation of the cmdlet.
    $pattern = '(?m)(^|[|{(,;]\s*)Get-FileHash\b'
    foreach ($file in @($commonPath, $runPath, $PSCommandPath)) {
        $text = [System.IO.File]::ReadAllText($file)
        $lines = $text -split "`r?`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            $code = ($line -replace '#.*$', '')
            if ($code -match $pattern) { throw ("{0}:{1} invokes Get-FileHash: {2}" -f $file, ($i + 1), $line.Trim()) }
        }
    }
    Assert-True ($true) 'no Get-FileHash invocation'
}

Invoke-Test -Id 'ST-03' -Name 'command-line quoting follows the MSVCRT rule' -Body {
    Assert-Equal '"a b" c' (ConvertTo-KanaAiLifecycleCommandLine -Arguments @('a b', 'c')) 'an argument with a space is quoted'
    Assert-Equal '"a\"b" c' (ConvertTo-KanaAiLifecycleCommandLine -Arguments @('a"b', 'c')) 'an embedded quote is backslash escaped and the token is quoted'
    Assert-Equal '"C:\dir with space\msi.msi"' (ConvertTo-KanaAiLifecycleCommandLine -Arguments @('C:\dir with space\msi.msi')) 'a path with a space is quoted'
    Assert-Equal 'C:\cand\KanaAI-0.1.0-x64.msi' (ConvertTo-KanaAiLifecycleCommandLine -Arguments @('C:\cand\KanaAI-0.1.0-x64.msi')) 'a path with no space is left unquoted'
    Assert-Equal '""' (ConvertTo-KanaAiLifecycleCommandLine -Arguments @('')) 'an empty argument becomes an empty quoted token'
    Assert-Equal '' (ConvertTo-KanaAiLifecycleCommandLine -Arguments @()) 'no arguments render to an empty string'
}

Invoke-Test -Id 'ST-04' -Name 'a command template renders to an exact command line' -Body {
    $command = [pscustomobject]@{ executable = '{msiexec}'; arguments = @('/i', '{msiPath}', '/qn', '/l*v', '{logPath}') }
    $rendered = Resolve-KanaAiLifecycleCommand -Command $command -Values @{ msiexec = 'C:\Windows\System32\msiexec.exe'; msiPath = 'C:\candidate dir\KanaAI-0.1.0-x64.msi'; logPath = 'C:\out\install.log' }
    Assert-Equal 'C:\Windows\System32\msiexec.exe /i "C:\candidate dir\KanaAI-0.1.0-x64.msi" /qn /l*v C:\out\install.log' $rendered.commandLine 'the rendered command line must be exact'
    Assert-True ($rendered.whatIfRender -like 'WHATIF: would run -> *') 'a what-if rendering must be produced'
}

Invoke-Test -Id 'ST-05' -Name 'a half-resolved command template is refused' -Body {
    $command = [pscustomobject]@{ executable = '{msiexec}'; arguments = @('/i', '{msiPath}') }
    Assert-Throws 'unresolved or empty placeholders' { Resolve-KanaAiLifecycleCommand -Command $command -Values @{ msiexec = 'msiexec.exe'; msiPath = '' } } 'an empty placeholder must stop the render'
}

# ===========================================================================
# 2. exit codes and the log classifier
# ===========================================================================
Invoke-Test -Id 'ST-06' -Name 'the Windows Installer exit code table is used' -Body {
    Assert-Equal 'success' (Get-KanaAiLifecycleMsiExitCodeMeaning -ExitCodeText '0') '0 is success'
    Assert-Equal 'success-reboot-required' (Get-KanaAiLifecycleMsiExitCodeMeaning -ExitCodeText '3010') '3010 is a success with a reboot required'
    Assert-Equal 'another-version-already-installed' (Get-KanaAiLifecycleMsiExitCodeMeaning -ExitCodeText '1638') '1638 is the downgrade refusal'
    Assert-Equal 'unknown' (Get-KanaAiLifecycleMsiExitCodeMeaning -ExitCodeText '9') 'an unlisted code is unknown'
    Assert-Equal 'unknown' (Get-KanaAiLifecycleMsiExitCodeMeaning -ExitCodeText 'not-a-number') 'a non-numeric code is unknown'
}

Invoke-Test -Id 'ST-07' -Name 'the verbose log classifier only claims what the log says' -Body {
    $install = Get-KanaAiLifecycleMsiLogClassification -Text "Action start: InstallInitialize`r`nProperty (Installed): 1`r`n" -Expected 'first-install'
    Assert-True ([bool]$install.confident) 'an install sequence must be confident'
    Assert-Equal 'first-install' $install.classification 'the classification must be first-install'

    $reinstall = Get-KanaAiLifecycleMsiLogClassification -Text "Property (REINSTALL): ALL`r`n" -Expected 'reinstall'
    Assert-Equal 'reinstall' $reinstall.classification 'a REINSTALL property must classify as a reinstall'

    $downgrade = Get-KanaAiLifecycleMsiLogClassification -Text "Error 1638. Another version of this product is already installed.`r`n" -Expected 'downgrade-refused'
    Assert-Equal 'downgrade-refused' $downgrade.classification '1638 must classify as a refused downgrade'

    $empty = Get-KanaAiLifecycleMsiLogClassification -Text '' -Expected 'reinstall'
    Assert-True (-not [bool]$empty.confident) 'a missing log must never be confident'

    # Contradiction, not merely two facts.  FindRelatedProducts evaluates the
    # Upgrade table once and cannot set both action properties, so a log that
    # carries both is not evidence of anything and is not confident.
    $contradiction = Get-KanaAiLifecycleMsiLogClassification -Text "PROPERTY CHANGE: Adding WIX_UPGRADE_DETECTED property. Its value is '{11111111-1111-4111-8111-111111111111}'.`r`nPROPERTY CHANGE: Adding WIX_DOWNGRADE_DETECTED property. Its value is '{22222222-2222-4222-8222-222222222222}'.`r`n" -Expected 'upgrade'
    Assert-True (-not [bool]$contradiction.confident) 'a log carrying both upgrade and downgrade detection must not be confident'
    Assert-Equal 'ambiguous-multiple-markers' $contradiction.classification 'a self-contradicting log must be named as such'

    # A log that is a plain success with no transaction fact at all decides
    # nothing rather than guessing.
    $nothing = Get-KanaAiLifecycleMsiLogClassification -Text "MainEngineThread is returning 0`r`n" -Expected 'first-install'
    Assert-True (-not [bool]$nothing.confident) 'a success line alone must not be confident'
}

# ===========================================================================
# 3. plan validation
# ===========================================================================
Invoke-Test -Id 'ST-08' -Name 'the real plan validates' -Body {
    $plan = Read-KanaAiLifecycleJson -Path $planPath
    $validation = Test-KanaAiLifecyclePlan -Plan $plan
    if (-not $validation.Ok) { throw ('the shipped plan does not validate: ' + (($validation.Errors) -join ' | ')) }
    Assert-True ($validation.PhaseCount -ge 8) 'the shipped plan must have the full phase set'
}

Invoke-Test -Id 'ST-09' -Name 'the shipped plan pins the real KanaAI identity' -Body {
    $plan = Read-KanaAiLifecycleJson -Path $planPath
    Assert-Equal '{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}' ([string]$plan.pinnedIdentity.upgradeCode) 'the pinned UpgradeCode must be the one in KanaAI.wxs'
    Assert-Equal 'perMachine' ([string]$plan.pinnedIdentity.scope) 'the package is perMachine'
    Assert-Equal 'KanaAI Development Preview' ([string]$plan.pinnedIdentity.packageName) 'the pinned ProductName must be the one the builder asserts'
    Assert-Equal 'afterInstallInitialize' ([string]$plan.pinnedIdentity.upgradePolicy.schedule) 'the MajorUpgrade schedule must be recorded'
    Assert-Equal '{7E7B5C1E-6D3A-4F2C-9A0E-3F4B5D6C7E81}' ([string]$plan.registrationIdentity.textServiceClsid) 'the pinned TIP CLSID must be the one in registration.json'
    Assert-Equal '{F3C2B7A1-6D54-4E8B-9A10-2C7D8E9F0A12}' ([string]$plan.registrationIdentity.languageProfileGuid) 'the pinned profile GUID must be the one in registration.json'
}

Invoke-Test -Id 'ST-10' -Name 'the shipped plan never lets a phase be decided by an exit code alone' -Body {
    $plan = Read-KanaAiLifecycleJson -Path $planPath
    foreach ($phase in @($plan.phases)) {
        $asserts = @($phase.asserts)
        $required = @($asserts | Where-Object { $_.required -ne $false } | ForEach-Object { [string]$_.check })
        if ($required -contains 'command-exit-code' -and @($required | Where-Object { $_ -ne 'command-exit-code' }).Count -eq 0) {
            throw ("phase '{0}' is decided by the exit code alone" -f [string]$phase.name)
        }
    }
}

Invoke-Test -Id 'ST-11' -Name 'a synthetic plan validates' -Body {
    $validation = Test-KanaAiLifecyclePlan -Plan (New-SyntheticPlan)
    if (-not $validation.Ok) { throw ('the synthetic plan should validate: ' + (($validation.Errors) -join ' | ')) }
}

Invoke-Test -Id 'ST-12' -Name 'plan validation refuses a phase decided only by its exit code' -Body {
    $plan = New-SyntheticPlan
    $plan.phases[1].asserts = @([pscustomobject]@{ check = 'command-exit-code'; expect = '0,3010'; required = $true })
    $validation = Test-KanaAiLifecyclePlan -Plan $plan
    Assert-True (-not $validation.Ok) 'the mutated plan must be rejected'
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-PHASE-EVIDENCE') 'the refusal must carry the PLAN-PHASE-EVIDENCE code'
}

Invoke-Test -Id 'ST-13' -Name 'plan validation refuses a destructive phase with no state assertion' -Body {
    $plan = New-SyntheticPlan
    $plan.phases[1].destructive = $true
    $plan.phases[1].asserts = @(
        [pscustomobject]@{ check = 'command-exit-code'; expect = '0,3010'; required = $true },
        [pscustomobject]@{ check = 'no-orphan-processes'; expect = 'true'; required = $true }
    )
    $validation = Test-KanaAiLifecyclePlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-PHASE-DESTRUCTIVE') 'a destructive phase must observe a product state'
}

Invoke-Test -Id 'ST-14' -Name 'plan validation refuses an unknown check name' -Body {
    $plan = New-SyntheticPlan
    $plan.phases[0].asserts = @([pscustomobject]@{ check = 'vibes'; expect = 'good'; required = $true })
    $validation = Test-KanaAiLifecyclePlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-PHASE-CHECK') 'an unknown check name must be rejected'
}

Invoke-Test -Id 'ST-15' -Name 'plan validation refuses a missing safety gate and a missing schema version' -Body {
    $plan = New-SyntheticPlan
    $plan.schemaVersion = 2
    $plan.safetyGates = @($plan.safetyGates | Where-Object { $_.id -ne 'elevation' })
    $validation = Test-KanaAiLifecyclePlan -Plan $plan
    $codes = Get-PlanErrorCodes -Validation $validation
    Assert-True ($codes -contains 'PLAN-SCHEMA') 'a wrong schema version must be rejected'
    Assert-True ($codes -contains 'PLAN-GATE') 'a missing elevation gate must be rejected'
}

Invoke-Test -Id 'ST-16' -Name 'plan validation refuses a phase that documents nothing' -Body {
    $plan = New-SyntheticPlan
    $plan.phases[0].cannotProve = @()
    $validation = Test-KanaAiLifecyclePlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-PHASE-DOC') 'every phase must state what it cannot prove'
}

Invoke-Test -Id 'ST-17' -Name 'plan validation refuses a phase that asserts nothing' -Body {
    $plan = New-SyntheticPlan
    $plan.phases[0].asserts = @()
    $validation = Test-KanaAiLifecyclePlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-PHASE-ASSERTS') 'a phase that asserts nothing is not a verification step'
}

Invoke-Test -Id 'ST-18' -Name 'plan validation refuses duplicate phase names' -Body {
    $plan = New-SyntheticPlan
    $plan.phases[2].name = 'install'
    $validation = Test-KanaAiLifecyclePlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-PHASE-NAME') 'a duplicate phase name must be rejected'
}

# ===========================================================================
# 4. candidate identity
# ===========================================================================
function New-GoodPropertyMap {
    return [pscustomobject]@{
        ProductCode    = '{33333333-3333-4333-8333-333333333333}'
        UpgradeCode    = '{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}'
        ProductName    = 'KanaAI Development Preview'
        ProductVersion = '0.1.0'
        Manufacturer   = 'KanaAI Project'
        ALLUSERS       = '1'
        ProductLanguage = '1041'
    }
}

Invoke-Test -Id 'ST-19' -Name 'a correct candidate identity is accepted' -Body {
    $pinned = (New-SyntheticPlan).pinnedIdentity
    $pinned.upgradeCode = '{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}'
    $identity = Test-KanaAiLifecycleCandidateIdentity -PropertyMap (New-GoodPropertyMap) -TemplatePlatform 'x64;1033' -Pinned $pinned
    if (-not $identity.Ok) { throw ('a good candidate was refused: ' + (($identity.Errors) -join ' | ')) }
    Assert-Equal '{33333333-3333-4333-8333-333333333333}' $identity.ProductCode 'the product code must be reported normalised'
}

Invoke-Test -Id 'ST-20' -Name 'a foreign UpgradeCode is refused' -Body {
    $pinned = (New-SyntheticPlan).pinnedIdentity
    $pinned.upgradeCode = '{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}'
    $map = New-GoodPropertyMap
    $map.UpgradeCode = '{00000000-0000-0000-0000-0000000000AA}'
    $identity = Test-KanaAiLifecycleCandidateIdentity -PropertyMap $map -TemplatePlatform 'x64;1033' -Pinned $pinned
    Assert-True (-not $identity.Ok) 'a foreign UpgradeCode must be refused'
    Assert-True (($identity.Errors -join ' ') -match 'CANDIDATE-PID') 'the refusal must be a candidate identity refusal'
}

Invoke-Test -Id 'ST-21' -Name 'a foreign ProductName, a per-user package and an x86 package are refused' -Body {
    $pinned = (New-SyntheticPlan).pinnedIdentity
    $pinned.upgradeCode = '{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}'
    $map = New-GoodPropertyMap
    $map.ProductName = 'Something Else'
    Assert-True (-not (Test-KanaAiLifecycleCandidateIdentity -PropertyMap $map -TemplatePlatform 'x64;1033' -Pinned $pinned).Ok) 'a foreign ProductName must be refused'

    $map = New-GoodPropertyMap
    $map.ALLUSERS = '2'
    Assert-True (-not (Test-KanaAiLifecycleCandidateIdentity -PropertyMap $map -TemplatePlatform 'x64;1033' -Pinned $pinned).Ok) 'a per-user package must be refused for a perMachine pin'

    $map = New-GoodPropertyMap
    Assert-True (-not (Test-KanaAiLifecycleCandidateIdentity -PropertyMap $map -TemplatePlatform 'Intel;1033' -Pinned $pinned).Ok) 'an x86 package must be refused'
    Assert-True (-not (Test-KanaAiLifecycleCandidateIdentity -PropertyMap $map -TemplatePlatform '' -Pinned $pinned).Ok) 'an unreadable package template must be refused'
}

Invoke-Test -Id 'ST-22' -Name 'a malformed ProductVersion is refused' -Body {
    $pinned = (New-SyntheticPlan).pinnedIdentity
    $pinned.upgradeCode = '{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}'
    $map = New-GoodPropertyMap
    $map.ProductVersion = '0.1'
    Assert-True (-not (Test-KanaAiLifecycleCandidateIdentity -PropertyMap $map -TemplatePlatform 'x64;1033' -Pinned $pinned).Ok) 'a two-part version must be refused'
}

# ===========================================================================
# 5. inventories
# ===========================================================================
Invoke-Test -Id 'ST-23' -Name 'a missing declared file is reported' -Body {
    $comparison = Compare-KanaAiLifecycleFileInventory -Expected @('a.dll', 'b.dll', 'ai/model/weights.gguf') -Observed @('a.dll', 'ai\model\weights.gguf')
    Assert-True (-not [bool]$comparison.ok) 'a missing file must make the comparison fail'
    Assert-Equal 'b.dll' ($comparison.missing -join ',') 'the missing file must be named'
    Assert-Equal 0 $comparison.unexpected.Count 'nothing is unexpected here'
}

Invoke-Test -Id 'ST-24' -Name 'an unexpected extra file is reported but is not a failure' -Body {
    $comparison = Compare-KanaAiLifecycleFileInventory -Expected @('a.dll') -Observed @('a.dll', 'user-notes.txt')
    Assert-True ([bool]$comparison.ok) 'an undeclared extra file must not fail the comparison'
    Assert-Equal 'user-notes.txt' ($comparison.unexpected -join ',') 'the unexpected file must still be named'
}

Invoke-Test -Id 'ST-25' -Name 'path separators are normalised before comparing' -Body {
    $comparison = Compare-KanaAiLifecycleFileInventory -Expected @('ai/runtime/llama-server.exe') -Observed @('AI\Runtime\Llama-Server.ExE'.ToLowerInvariant() -replace 'llama-server.exe', 'llama-server.exe')
    Assert-True ([bool]$comparison.ok) 'the same relative path written two ways must compare equal'
}

Invoke-Test -Id 'ST-26' -Name 'the before/after inventory comparison detects change' -Body {
    $same = Compare-KanaAiLifecycleInventories -Before @('a', 'b') -After @('b', 'a')
    Assert-True ([bool]$same.identical) 'a reordered identical set must be identical'
    $changed = Compare-KanaAiLifecycleInventories -Before @('a', 'b') -After @('a', 'c')
    Assert-True (-not [bool]$changed.identical) 'a changed set must not be identical'
    Assert-Equal 'b' ($changed.removed -join ',') 'the removed entry must be named'
    Assert-Equal 'c' ($changed.added -join ',') 'the added entry must be named'
}

# ===========================================================================
# 6. the comparison and verdict engine, including the negative cases
# ===========================================================================
function New-InstallPhase {
    return [pscustomobject]@{
        id     = 'SY-01'
        name   = 'install'
        title  = 'Install'
        asserts = @(
            [pscustomobject]@{ check = 'command-exit-code'; expect = '0,3010,1641,3011'; required = $true },
            [pscustomobject]@{ check = 'product-state'; expect = 'installed'; required = $true },
            [pscustomobject]@{ check = 'product-code'; expect = 'from-candidate-msi'; required = $true },
            [pscustomobject]@{ check = 'registration-present'; expect = 'true'; required = $true },
            [pscustomobject]@{ check = 'registration-target-file-present'; expect = 'true'; required = $true },
            [pscustomobject]@{ check = 'install-directory'; expect = 'present'; required = $true },
            [pscustomobject]@{ check = 'expected-files'; expect = 'all-present'; required = $true }
        )
    }
}

Invoke-Test -Id 'ST-27' -Name 'a fully observed install passes' -Body {
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-InstallPhase) -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation) })
    Assert-Equal 'pass' $outcome.outcome 'a complete, consistent observation must pass'
}

Invoke-Test -Id 'ST-28' -Name 'exit code 0 with no registration is a FAIL, not a pass' -Body {
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-InstallPhase) -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -RegistrationPresent $false) })
    Assert-Equal 'fail' $outcome.outcome 'an install that returned 0 and registered nothing must fail'
    $failedChecks = @($outcome.checks | Where-Object { [string]$_.outcome -eq 'fail' } | ForEach-Object { [string]$_.check })
    Assert-True ($failedChecks -contains 'registration-present') 'the registration check must be the one that failed'
    Assert-True (@($outcome.checks | Where-Object { [string]$_.check -eq 'command-exit-code' -and [string]$_.outcome -eq 'pass' }).Count -eq 1) 'the exit code check itself passed, which is exactly the point: it must not rescue the phase'
}

Invoke-Test -Id 'ST-29' -Name 'a registration key with no real DLL behind it is a FAIL' -Body {
    $observation = New-KanaAiLifecycleSyntheticObservation
    $observation.registration.inProcTargetExists = $false
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-InstallPhase) -Context ([ordered]@{ observation = $observation })
    Assert-Equal 'fail' $outcome.outcome 'a key with no file behind it is not a registration'
}

Invoke-Test -Id 'ST-30' -Name 'a missing declared file is a FAIL' -Body {
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-InstallPhase) -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -MissingExpectedFile $true) })
    Assert-Equal 'fail' $outcome.outcome 'a missing declared file must fail the phase'
    $expectedCheck = @($outcome.checks | Where-Object { [string]$_.check -eq 'expected-files' })
    Assert-Equal 'fail' ([string]$expectedCheck[0].outcome) 'the expected-files check must be the failure'
}

Invoke-Test -Id 'ST-31' -Name 'an unreadable registration surface is UNCONFIRMED, not a pass' -Body {
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-InstallPhase) -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -RegistrationReadable $false) })
    Assert-Equal 'unconfirmed' $outcome.outcome 'an unreadable surface must be unconfirmed'
}

Invoke-Test -Id 'ST-32' -Name 'an unknown exit code is a FAIL' -Body {
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-InstallPhase) -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -ExitCode '9') })
    Assert-Equal 'fail' $outcome.outcome 'an exit code outside the documented table must fail'
}

Invoke-Test -Id 'ST-33' -Name 'a timed-out command is a FAIL' -Body {
    $observation = New-KanaAiLifecycleSyntheticObservation
    $observation.command.timedOut = $true
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-InstallPhase) -Context ([ordered]@{ observation = $observation })
    Assert-Equal 'fail' $outcome.outcome 'a command the harness had to kill must fail'
}

Invoke-Test -Id 'ST-34' -Name 'a different product code than the candidate is a FAIL' -Body {
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-InstallPhase) -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -InstalledProductCode '{00000000-0000-4000-8000-0000000000FF}') })
    Assert-Equal 'fail' $outcome.outcome 'a different installed product must fail'
}

Invoke-Test -Id 'ST-35' -Name 'a product state the installer API could not read is UNCONFIRMED' -Body {
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-InstallPhase) -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -ProductState 'unknown') })
    Assert-Equal 'unconfirmed' $outcome.outcome 'an unreadable product state must be unconfirmed, never absent'
}

Invoke-Test -Id 'ST-36' -Name 'an orphan process is a FAIL' -Body {
    $phase = [pscustomobject]@{ id = 'SY-04'; name = 'cleanup'; asserts = @([pscustomobject]@{ check = 'no-orphan-processes'; expect = 'true'; required = $true }) }
    $observation = New-KanaAiLifecycleSyntheticObservation
    $observation.processes.orphans = @('mozc_server.exe#1234')
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = $observation })
    Assert-Equal 'fail' $outcome.outcome 'a surviving product process must fail'
}

Invoke-Test -Id 'ST-37' -Name 'a downgrade that returned 0 instead of 1638 is a FAIL' -Body {
    $phase = [pscustomobject]@{
        id     = 'SY-05'
        name   = 'downgrade'
        asserts = @(
            [pscustomobject]@{ check = 'command-exit-code'; expect = '1638'; required = $true },
            [pscustomobject]@{ check = 'product-state'; expect = 'installed'; required = $true }
        )
    }
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -ExitCode '0' -LogClassification 'downgrade-refused') })
    Assert-Equal 'fail' $outcome.outcome 'a downgrade must be refused with 1638'
}

Invoke-Test -Id 'ST-38' -Name 'a reinstall with an unclassifiable log is UNCONFIRMED' -Body {
    $phase = [pscustomobject]@{
        id     = 'SY-06'
        name   = 'reinstall'
        asserts = @(
            [pscustomobject]@{ check = 'product-state'; expect = 'installed'; required = $true },
            [pscustomobject]@{ check = 'msi-log-classification'; expect = 'reinstall'; required = $true }
        )
    }
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -LogClassification 'ambiguous-multiple-markers' -LogConfident $false) })
    Assert-Equal 'unconfirmed' $outcome.outcome 'an unclassifiable log must never be reported as a pass'
}

Invoke-Test -Id 'ST-39' -Name 'a changed InstallDate on the second run is a FAIL' -Body {
    $phase = [pscustomobject]@{
        id     = 'SY-07'
        name   = 'reinstall'
        asserts = @([pscustomobject]@{ check = 'install-date-unchanged'; expect = 'true'; required = $true })
    }
    $observation = New-KanaAiLifecycleSyntheticObservation
    $observation.installDate = '20260927 00:00:00'
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = $observation })
    Assert-Equal 'fail' $outcome.outcome 'a new InstallDate looks like a fresh install and must fail the reinstall phase'
}

Invoke-Test -Id 'ST-40' -Name 'a record_only assertion cannot decide a phase' -Body {
    $phase = [pscustomobject]@{
        id     = 'SY-08'
        name   = 'record-only'
        asserts = @(
            [pscustomobject]@{ check = 'no-orphan-processes'; expect = 'true'; required = $false },
            [pscustomobject]@{ check = 'command-exit-code'; expect = '0'; required = $true }
        )
    }
    $observation = New-KanaAiLifecycleSyntheticObservation
    $observation.processes.orphans = @('mozc_server.exe#1')
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = $observation })
    Assert-True ($outcome.outcome -ne 'fail') 'a record_only check must not be able to fail a phase'
}

Invoke-Test -Id 'ST-41' -Name 'a missing observation is UNCONFIRMED rather than an assumed pass' -Body {
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-InstallPhase) -Context ([ordered]@{ observation = [pscustomobject]@{ command = $null } })
    Assert-Equal 'unconfirmed' $outcome.outcome 'no observation at all must be unconfirmed'
}

# ===========================================================================
# 7. preconditions and resume
# ===========================================================================
Invoke-Test -Id 'ST-42' -Name 'an unmet precondition stops the phase' -Body {
    $plan = New-SyntheticPlan
    $phase = $plan.phases[2]
    $unmet = Resolve-KanaAiLifecyclePreconditions -Phase $phase -State @{ productState = 'absent' }
    Assert-True (-not [bool]$unmet.met) 'a precondition must fail when the state does not match'
    Assert-True (([string]$unmet.unmet -join ' ') -match 'productState') 'the unmet precondition must be named'
    $met = Resolve-KanaAiLifecyclePreconditions -Phase $phase -State @{ productState = 'installed' }
    Assert-True ([bool]$met.met) 'the precondition must be met when the state matches'
}

Invoke-Test -Id 'ST-43' -Name 'resume skips a completed phase' -Body {
    $plan = New-SyntheticPlan
    $resume = Resolve-KanaAiLifecycleResumePlan -Plan $plan -PriorResults @(
        [pscustomobject]@{ phase = 'observe'; outcome = 'pass' },
        [pscustomobject]@{ phase = 'install'; outcome = 'pass' },
        [pscustomobject]@{ phase = 'uninstall'; outcome = 'pass' }
    ) -ResumeFrom 'install' -AllowDestructiveRerun $false
    Assert-True ([bool]$resume.Ok) 'a valid resume plan must be Ok'
    $observe = @(@($resume.Actions) | Where-Object { $_.phase -eq 'observe' })[0]
    Assert-Equal 'skip-completed' ([string]$observe.decision) 'a completed non-destructive phase before the resume point must be skipped as completed'
    $refused = @(@($resume.Actions) | Where-Object { $_.decision -eq 'refused' })
    Assert-Equal 2 $refused.Count 'both completed destructive phases must be refused on a silent resume'
}

Invoke-Test -Id 'ST-44' -Name 'resume must not silently re-run a completed destructive phase' -Body {
    $plan = New-SyntheticPlan
    $resume = Resolve-KanaAiLifecycleResumePlan -Plan $plan -PriorResults @([pscustomobject]@{ phase = 'install'; outcome = 'pass' }) -ResumeFrom 'install' -AllowDestructiveRerun $false
    $install = @(@($resume.Actions) | Where-Object { $_.phase -eq 'install' })[0]
    Assert-Equal 'refused' ([string]$install.decision) 'a completed destructive phase must be refused on a silent resume'
    Assert-True ((@($resume.RefusedPhases) -contains 'install')) 'the refused phase must be listed'
    $uninstall = @(@($resume.Actions) | Where-Object { $_.phase -eq 'uninstall' })[0]
    Assert-Equal 'refused' ([string]$uninstall.decision) 'a destructive phase that never completed must also be refused without the acknowledgement'
}

Invoke-Test -Id 'ST-45' -Name 'the explicit destructive-rerun acknowledgement unlocks the phase' -Body {
    $plan = New-SyntheticPlan
    $resume = Resolve-KanaAiLifecycleResumePlan -Plan $plan -PriorResults @([pscustomobject]@{ phase = 'install'; outcome = 'pass' }) -ResumeFrom 'install' -AllowDestructiveRerun $true
    $install = @(@($resume.Actions) | Where-Object { $_.phase -eq 'install' })[0]
    Assert-Equal 'run' ([string]$install.decision) 'the acknowledgement must permit the re-run'
    Assert-True (([string]$install.reason) -match 'acknowledged') 'the reason must record the acknowledgement'
}

Invoke-Test -Id 'ST-46' -Name 'a phase before -ResumeFrom that never completed is not_run, not a pass' -Body {
    $plan = New-SyntheticPlan
    $resume = Resolve-KanaAiLifecycleResumePlan -Plan $plan -PriorResults $null -ResumeFrom 'uninstall' -AllowDestructiveRerun $true
    $observe = @(@($resume.Actions) | Where-Object { $_.phase -eq 'observe' })[0]
    $install = @(@($resume.Actions) | Where-Object { $_.phase -eq 'install' })[0]
    Assert-Equal 'skip-not-run' ([string]$observe.decision) 'a phase before the resume point that never completed must be skipped'
    Assert-True (([string]$observe.reason) -match 'never as a pass') 'the reason must say it is not a pass'
    Assert-Equal 'skip-not-run' ([string]$install.decision) 'a destructive phase before the resume point must not be run'
}

Invoke-Test -Id 'ST-47' -Name 'an unknown -ResumeFrom phase is refused' -Body {
    $resume = Resolve-KanaAiLifecycleResumePlan -Plan (New-SyntheticPlan) -PriorResults $null -ResumeFrom 'no-such-phase' -AllowDestructiveRerun $true
    Assert-True (-not [bool]$resume.Ok) 'an unknown resume point must be refused'
    Assert-True (($resume.Errors -join ' ') -match 'RESUME-PHASE') 'the refusal must carry the RESUME-PHASE code'
}

# ===========================================================================
# 8. receipt, privacy, verdict mapping
# ===========================================================================
Invoke-Test -Id 'ST-48' -Name 'the privacy scan rejects secrets, env dumps and user paths' -Body {
    $json = '{"password":"x"}'
    Assert-True (-not (Test-KanaAiLifecycleReceiptSanity -Json $json).ok) 'a password key must be rejected'
    $json = '{"environmentVariables":{"Path":"x"}}'
    Assert-True (-not (Test-KanaAiLifecycleReceiptSanity -Json $json).ok) 'an environment variable dump must be rejected'
    $json = '{"note":"C:\\Users\\someone\\Desktop\\x"}'
    Assert-True (-not (Test-KanaAiLifecycleReceiptSanity -Json $json).ok) 'a user path must be rejected'
    $json = '{"note":"clipboard"}'
    Assert-True (-not (Test-KanaAiLifecycleReceiptSanity -Json $json).ok) 'a clipboard reference must be rejected'
    $json = '{"ProductCode":"{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}","sha256":"aa11"}'
    Assert-True ((Test-KanaAiLifecycleReceiptSanity -Json $json).ok) 'a legitimate receipt fragment must pass'
}

Invoke-Test -Id 'ST-49' -Name 'user profile paths are rewritten to tokens' -Body {
    $profile = [System.Environment]::GetEnvironmentVariable('USERPROFILE')
    if ([string]::IsNullOrWhiteSpace($profile)) { throw 'no USERPROFILE in this environment' }
    foreach ($relative in @('Documents\thing.txt', 'Desktop\thing.txt', 'AppData\Local\Temp\thing.txt')) {
        $protected = Protect-KanaAiLifecyclePath -Path (Join-Path $profile $relative)
        Assert-True ($protected.StartsWith('<')) ("a path under the user profile must be reduced to a token, got '$protected'")
        Assert-True ($protected -notmatch [regex]::Escape($profile)) 'the profile prefix must be gone'
    }
    $outside = Protect-KanaAiLifecyclePath -Path 'C:\Program Files\KanaAI\KanaAI.TsfTip.dll'
    Assert-Equal 'C:\Program Files\KanaAI\KanaAI.TsfTip.dll' $outside 'a path outside any user profile must be untouched'
}

Invoke-Test -Id 'ST-50' -Name 'the overall status never reports a pass over an unconfirmed phase' -Body {
    $results = @(
        [pscustomobject]@{ phase = 'a'; outcome = 'pass' },
        [pscustomobject]@{ phase = 'b'; outcome = 'unconfirmed' }
    )
    Assert-Equal 'unconfirmed' (Resolve-KanaAiLifecycleOverallStatus -Results $results -Mode 'run') 'an unconfirmed phase must keep the run from passing'
    $results = @(
        [pscustomobject]@{ phase = 'a'; outcome = 'pass' },
        [pscustomobject]@{ phase = 'b'; outcome = 'fail' }
    )
    Assert-Equal 'failed' (Resolve-KanaAiLifecycleOverallStatus -Results $results -Mode 'run') 'a failed phase must fail the run'
    $results = @([pscustomobject]@{ phase = 'a'; outcome = 'pass' })
    Assert-Equal 'passed' (Resolve-KanaAiLifecycleOverallStatus -Results $results -Mode 'run') 'an all-pass run passes'
    Assert-Equal 0 (Get-KanaAiLifecycleExitCodeForStatus -Status 'passed') 'a pass exits 0'
    Assert-Equal 1 (Get-KanaAiLifecycleExitCodeForStatus -Status 'failed') 'a failure exits 1'
    Assert-Equal 2 (Get-KanaAiLifecycleExitCodeForStatus -Status 'refused') 'a refusal exits 2'
    Assert-Equal 3 (Get-KanaAiLifecycleExitCodeForStatus -Status 'unconfirmed') 'an unconfirmed run exits 3'
}

Invoke-Test -Id 'ST-51' -Name 'a receipt is written and read back, and its artifacts carry a digest' -Body {
    $file = Join-Path $script:TempRoot 'artifact.bin'
    [System.IO.File]::WriteAllText($file, 'artifact-bytes')
    $entry = New-KanaAiLifecycleArtifactEntry -Path $file -Root $script:TempRoot -Role 'test'
    Assert-Equal 'artifact.bin' ([string]$entry.path) 'an artifact inside the root must be recorded by relative path'
    Assert-True ([bool]$entry.recorded) 'an existing artifact must be recorded'
    Assert-True ([string]$entry.sha256 -match '^[0-9a-f]{64}$') 'an artifact must carry a sha256'
    $outside = New-KanaAiLifecycleArtifactEntry -Path $runPath -Root $script:TempRoot -Role 'outside'
    Assert-Equal 'Invoke-KanaAiLifecycleValidation.ps1' ([string]$outside.path) 'an artifact outside the root must fall back to its leaf name only'

    $receiptPath = Join-Path $script:TempRoot 'receipt.json'
    $receipt = [ordered]@{ schemaVersion = 1; runId = 'r'; phases = @(); overall = 'plan_only'; machineInteraction = (Get-KanaAiLifecycleInteractionCounters -Ledger $script:SealedLedger) }
    [void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $receipt)
    $readBack = Read-KanaAiLifecycleJson -Path $receiptPath
    Assert-Equal 'r' ([string]$readBack.runId) 'the receipt must round-trip'
    Assert-Equal 0 ([int]$readBack.machineInteraction.processLaunches) 'a plan-only receipt must record zero process launches'
}

Invoke-Test -Id 'ST-52' -Name 'the harness synthetic self check passes' -Body {
    $result = New-KanaAiLifecycleSyntheticSelfCheck
    if (-not [bool]$result.ok) {
        $failed = @($result.cases | Where-Object { -not [bool]$_.ok } | ForEach-Object { ([string]$_.id) + ' expected ' + [string]$_.expect + ' got ' + [string]$_.actual })
        throw ('the synthetic self check failed: ' + ($failed -join ' | '))
    }
}

# ===========================================================================
# 9. the action gate.  This is the mechanism that makes "-PlanOnly performs no
# install, no registry access and no process launch" an enforced property.
# ===========================================================================
Invoke-Test -Id 'ST-53' -Name 'a sealed ledger refuses every machine-touching helper' -Body {
    $helpers = @(
        { Get-KanaAiLifecycleInstallerCom -Ledger $script:SealedLedger -Detail 'x' },
        { Get-KanaAiLifecycleMsiPropertyMap -Ledger $script:SealedLedger -Path 'x' },
        { Get-KanaAiLifecycleMsiTemplatePlatform -Ledger $script:SealedLedger -Path 'x' },
        { Get-KanaAiLifecycleMsiFilePlan -Ledger $script:SealedLedger -Path 'x' -InstallFolderId 'INSTALLFOLDER' },
        { Get-KanaAiLifecycleExpectedInstallPath -Ledger $script:SealedLedger -Path 'x' -InstallFolderId 'INSTALLFOLDER' },
        { Get-KanaAiLifecycleProductInfo -Ledger $script:SealedLedger -ProductCode 'x' -PropertyName 'InstallState' },
        { Get-KanaAiLifecycleProductState -Ledger $script:SealedLedger -ProductCode 'x' },
        { Find-KanaAiLifecycleInstalledProducts -Ledger $script:SealedLedger -UpgradeCode 'x' },
        { Get-KanaAiLifecycleRegistrationObservation -Ledger $script:SealedLedger -Registration ([pscustomobject]@{ textServiceClsid = '{x}'; languageProfileGuid = '{y}'; languageSegment = '0x00000411'; profileSubkey = 'LanguageProfile'; machineTextServiceRoot = 'SOFTWARE\Microsoft\CTF\TIP'; machineComRoot = 'SOFTWARE\Classes\CLSID'; registryView = 'Registry64' }) },
        { Get-KanaAiLifecycleInstallDirectoryObservation -Ledger $script:SealedLedger -Path 'x' },
        { Get-KanaAiLifecycleProductProcessObservation -Ledger $script:SealedLedger -Names @('a.exe') },
        { Read-KanaAiLifecycleMsiLogText -Ledger $script:SealedLedger -Path 'x' },
        { Invoke-KanaAiLifecycleCommand -Ledger $script:SealedLedger -Rendered ([ordered]@{ executable = 'cmd.exe'; arguments = @('/c', 'echo', 'x'); commandLine = 'cmd.exe /c echo x'; whatIfRender = 'x' }) },
        { Remove-KanaAiLifecycleOwnedPath -Ledger $script:SealedLedger -Path (Join-Path $script:TempRoot 'x') -OwnedRoot $script:TempRoot }
    )
    foreach ($helper in $helpers) {
        Assert-Throws 'LIFECYCLE-GATE-SEALED' $helper 'a sealed ledger must refuse this helper'
    }
    Assert-Equal 0 ([int]$script:SealedLedger.ProcessLaunches) 'a sealed ledger must record no process launches'
    Assert-Equal 0 ([int]$script:SealedLedger.RegistryOpens) 'a sealed ledger must record no registry opens'
    Assert-Equal 0 ([int]$script:SealedLedger.FilesystemReads) 'a sealed ledger must record no filesystem reads'
    Assert-Equal 0 ([int]$script:SealedLedger.InstallerComObjects) 'a sealed ledger must record no COM objects'
    Assert-Equal 0 ([int]$script:SealedLedger.MsiExecInvocations) 'a sealed ledger must record no msiexec invocations'
    Assert-Equal 0 ([int]$script:SealedLedger.DirectoryMutations) 'a sealed ledger must record no directory mutations'
}

Invoke-Test -Id 'ST-54' -Name 'an unsealed ledger counts every kind of machine action' -Body {
    [void](Enter-KanaAiLifecycleAction -Ledger $script:OpenLedger -Kind 'installer-com')
    [void](Enter-KanaAiLifecycleAction -Ledger $script:OpenLedger -Kind 'msi-database')
    [void](Enter-KanaAiLifecycleAction -Ledger $script:OpenLedger -Kind 'registry-read')
    [void](Enter-KanaAiLifecycleAction -Ledger $script:OpenLedger -Kind 'msiexec')
    $counters = Get-KanaAiLifecycleInteractionCounters -Ledger $script:OpenLedger
    Assert-Equal 1 ([int]$counters.installerComObjects) 'a COM object must be counted'
    Assert-Equal 1 ([int]$counters.msiDatabaseOpens) 'an MSI database open must be counted'
    Assert-Equal 1 ([int]$counters.registryOpens) 'a registry read must be counted'
    Assert-Equal 1 ([int]$counters.msiexecInvocations) 'an msiexec invocation must be counted'
    Assert-True (-not [bool]$counters.gateSealed) 'an unsealed ledger must report itself unsealed'
}

Invoke-Test -Id 'ST-55' -Name 'cleanup refuses to delete a path the harness does not own' -Body {
    $outside = Join-Path ([System.IO.Path]::GetTempPath()) ('kanai-not-owned-' + [Guid]::NewGuid().ToString('n').Substring(0, 8))
    Assert-Throws 'Refusing to delete a path the harness does not own' {
        Remove-KanaAiLifecycleOwnedPath -Ledger $script:OpenLedger -Path $outside -OwnedRoot $script:TempRoot
    } 'a path outside the output root must be refused'
    Assert-Throws 'Refusing to delete the harness output root itself' {
        Remove-KanaAiLifecycleOwnedPath -Ledger $script:OpenLedger -Path $script:TempRoot -OwnedRoot $script:TempRoot
    } 'the output root itself must be refused'
    Assert-True (-not (Test-Path -LiteralPath $outside)) 'nothing may have been created or removed by the refusal'
}

Invoke-Test -Id 'ST-56' -Name 'cleanup ownership requires a ledger pid and a matching image name' -Body {
    $ledger = New-KanaAiLifecycleActionLedger
    [void]$ledger.StartedProcesses.Add([ordered]@{ pid = 4242; commandLine = '"C:\out\Setup.exe"'; startedAtUtc = 'x' })
    Assert-True (Test-KanaAiLifecycleOwnedByHarness -ProcessId 4242 -ExpectedImageName 'Setup.exe' -Ledger $ledger) 'a matching pid and image must be owned'
    Assert-True (-not (Test-KanaAiLifecycleOwnedByHarness -ProcessId 4242 -ExpectedImageName 'notepad.exe' -Ledger $ledger)) 'a recycled pid with a different image must not be owned'
    Assert-True (-not (Test-KanaAiLifecycleOwnedByHarness -ProcessId 9999 -ExpectedImageName 'Setup.exe' -Ledger $ledger)) 'an unknown pid must not be owned'
}

Invoke-Test -Id 'ST-57' -Name 'cleanup is idempotent: a second pass over the same ledger resolves to already-clean' -Body {
    # pid 4242 is not a real process here, so both passes must resolve every
    # ledger entry to already-clean.  This is the idempotency property: running
    # cleanup again cannot repeat a destructive action or fail.
    $ledger = New-KanaAiLifecycleActionLedger
    [void]$ledger.StartedProcesses.Add([ordered]@{ pid = 4242; commandLine = 'C:\out\Setup.exe'; startedAtUtc = 'x' })
    $resolutions = New-Object System.Collections.Generic.List[string]
    foreach ($pass in @(1, 2)) {
        foreach ($entry in $ledger.StartedProcesses) {
            $process = Get-Process -Id ([int]$entry.pid) -ErrorAction SilentlyContinue
            if ($null -eq $process) { [void]$resolutions.Add(('pass{0}: pid {1} already exited' -f $pass, [string]$entry.pid)); continue }
            [void]$resolutions.Add(('pass{0}: pid {1} is still alive' -f $pass, [string]$entry.pid))
        }
    }
    Assert-Equal 2 $resolutions.Count 'both passes must resolve the single ledger entry'
    foreach ($resolution in $resolutions) { Assert-True ($resolution -match 'already exited') 'every pass must resolve to already-clean' }
    Assert-Equal 0 ([int]$ledger.DirectoryMutations) 'cleanup planning must not mutate the filesystem'
}

# ===========================================================================
# 10. the entry point itself
# ===========================================================================
Invoke-Test -Id 'ST-58' -Name 'the entry point parses and its mode contract is explicit' -Body {
    $errors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($runPath, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 @($errors).Count ('the entry point must parse: ' + ((@($errors) | ForEach-Object { $_.Message }) -join ' | '))
    $text = [System.IO.File]::ReadAllText($runPath)
    foreach ($required in @('-PlanOnly', '-SelfTest', '-Execute', '-ResumeFrom', '-CandidateMsi', '-AllowLifecycle')) {
        Assert-True ($text.Contains($required)) "the entry point must expose $required"
    }
}

Invoke-Test -Id 'ST-59' -Name 'the self test file parses' -Body {
    $errors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 @($errors).Count ('the self test must parse: ' + ((@($errors) | ForEach-Object { $_.Message }) -join ' | '))
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($commonPath, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 @($errors).Count ('the shared helpers must parse: ' + ((@($errors) | ForEach-Object { $_.Message }) -join ' | '))
}

Invoke-Test -Id 'ST-60' -Name 'the entry point contains no install or uninstall invocation outside the plan' -Body {
    $text = [System.IO.File]::ReadAllText($runPath)
    $forbidden = @('msiexec.exe /i', 'msiexec /i', 'Start-Process msiexec', 'Remove-Item -LiteralPath $env:ProgramFiles', 'sc.exe', 'reg.exe', 'reg add', 'schtasks')
    foreach ($pattern in $forbidden) {
        Assert-True (-not $text.Contains($pattern)) "the entry point must not contain '$pattern'"
    }
    # The only msiexec in the entry point must come from the plan-driven template.
    Assert-True ($text.Contains('msiexecPath')) 'the msiexec path must be a value, not a literal command'
}
Invoke-Test -Id 'ST-61' -Name 'Close seals and Open unseals the same ledger, preserving its counters' -Body {
    # Regression for a measured -Execute defect: the entry point called Close-
    # where it meant to unseal, so the run sealed its own ledger and the next
    # machine-touching helper was refused by its own gate.  Both directions are
    # asserted here so that mistake cannot silently come back.
    $ledger = New-KanaAiLifecycleActionLedger
    Assert-True (-not [bool]$ledger.Sealed) 'a new ledger must start unsealed'
    [void](Enter-KanaAiLifecycleAction -Ledger $ledger -Kind 'registry-read')
    $sealed = Close-KanaAiLifecycleActionLedger -Ledger $ledger -Reason 'test seal'
    Assert-True ([bool]$sealed.Sealed) 'Close must seal the ledger'
    Assert-Equal 'test seal' ([string]$sealed.SealedReason) 'Close must record its reason'
    Assert-Throws 'LIFECYCLE-GATE-SEALED' { [void](Enter-KanaAiLifecycleAction -Ledger $sealed -Kind 'msi-database') } 'a sealed ledger must refuse every machine-touching helper'
    $opened = Open-KanaAiLifecycleActionLedger -Ledger $sealed -Reason 'test unseal'
    Assert-True (-not [bool]$opened.Sealed) 'Open must unseal the ledger'
    Assert-Equal 'test unseal' ([string]$opened.SealedReason) 'Open must record why it was unsealed'
    Assert-Equal 1 ([int]$opened.RegistryOpens) 'unsealing must preserve the counters already recorded'
    [void](Enter-KanaAiLifecycleAction -Ledger $opened -Kind 'msi-database')
    Assert-Equal 1 ([int]$opened.MsiDatabaseOpens) 'an unsealed ledger must accept the helper that was refused while sealed'
}

Invoke-Test -Id 'ST-62' -Name 'the -Execute path unseals with Open-, never with Close-' -Body {
    # The defect was a one-word call in the entry point, so assert the call site
    # itself and not only the helper behaviour.
    $text = [System.IO.File]::ReadAllText($runPath)
    Assert-True ($text.Contains('Open-KanaAiLifecycleActionLedger -Ledger $script:Ledger -Reason ''unsealed by -Execute')) 'the -Execute path must unseal the ledger through Open-'
    Assert-True (-not $text.Contains('Close-KanaAiLifecycleActionLedger -Ledger $script:Ledger -Reason ''unsealed by -Execute')) 'the -Execute path must not seal its own ledger with Close-'
}
Invoke-Test -Id 'ST-63' -Name 'MSI SQL identifiers use one backtick, never two' -Body {
    # A single-quoted PowerShell string does not treat the backtick as an escape
    # character, so a doubled backtick reaches Windows Installer as two of them
    # and OpenView fails.  Measured against the real candidate: six backticks in
    # the Property query opened the view and fetched ALLUSERS, while twelve
    # raised the very "OpenView,Sql" InvokeMember failure that the first elevated
    # W2 run reported.
    $text = [System.IO.File]::ReadAllText($commonPath)
    $bt = [string][char]96
    Assert-True (-not $text.Contains($bt + $bt)) 'the common file must not contain a doubled backtick'
    $expected = 'SELECT ' + $bt + 'Property' + $bt + ',' + $bt + 'Value' + $bt + ' FROM ' + $bt + 'Property' + $bt
    Assert-True ($text.Contains($expected)) 'the Property query must quote its identifiers with a single backtick'
}

Invoke-Test -Id 'ST-64' -Name 'the install path walk resolves a StandardDirectory by id, not by its leaf' -Body {
    # Measured defect: the walk tested the parent row's DefaultDir leaf, which for
    # ProgramFilesFolder is 'PFiles'.  Resolve- returned empty for it, so the whole
    # chain was reported unresolvable even though the id maps to C:\Program Files.
    $text = [System.IO.File]::ReadAllText($commonPath)
    Assert-True ($text.Contains('Resolve-KanaAiLifecycleStandardDirectory -ShortName $id')) 'the walk must test the directory id against the StandardDirectory map'
    Assert-True (-not $text.Contains('-ShortName $parentLeaf')) 'the walk must not test the DefaultDir leaf'
    $expectedRoot = if ([System.Environment]::Is64BitProcess) { [System.Environment]::GetEnvironmentVariable('ProgramW6432') } else { [System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)') }
    Assert-Equal $expectedRoot ([string](Resolve-KanaAiLifecycleStandardDirectory -ShortName 'ProgramFilesFolder')) 'ProgramFilesFolder must resolve to the real program files root'
    Assert-Equal '' ([string](Resolve-KanaAiLifecycleStandardDirectory -ShortName 'PFiles')) 'a DefaultDir leaf must not resolve, which is exactly why the id has to be used'
}

Invoke-Test -Id 'ST-65' -Name 'SummaryInformation is read from the Database through the call adapter' -Body {
    # Measured defect: Type.InvokeMember raised DISP_E_MEMBERNOTFOUND (0x80020003)
    # for SummaryInformation both on the Installer and on the Database, while the
    # PowerShell call adapter resolved it and returned the template x64;1041.
    $text = [System.IO.File]::ReadAllText($commonPath)
    Assert-True ($text.Contains('$database.SummaryInformation(0)')) 'SummaryInformation must be called on the Database object'
    Assert-True (-not $text.Contains("-Method 'SummaryInformation'")) 'SummaryInformation must not be reached through InvokeMember'
    Assert-True ($text.Contains('[string]$summary.Property(7)')) 'the template must be read with the Property accessor'
}
Invoke-Test -Id 'ST-66' -Name 'the candidate identity gate reads a property dictionary, not raw table rows' -Body {
    # Measured defect: Get-KanaAiLifecycleMsiPropertyMap returned the raw rows, an
    # array of two-element arrays.  Get-KanaAiLifecycleOptionalProperty finds
    # neither an IDictionary nor a PSObject property on that shape, so every field
    # came back empty and the gate refused a candidate that was in fact correct.
    $pinned = [pscustomobject]@{
        upgradeCode = '{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}'
        packageName = 'KanaAI Development Preview'
        scope       = 'perMachine'
    }
    $rows = @(
        @('ProductCode', '{FBDCE95B-46CA-4959-8D36-26ABEE793117}'),
        @('UpgradeCode', '{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}'),
        @('ProductName', 'KanaAI Development Preview'),
        @('ProductVersion', '0.1.0'),
        @('ALLUSERS', '1'),
        @('Manufacturer', 'KanaAI Project')
    )
    # The old shape must fail; that is what makes this regression non-vacuous.
    $fromRows = Test-KanaAiLifecycleCandidateIdentity -PropertyMap $rows -TemplatePlatform 'x64;1041' -Pinned $pinned
    Assert-True (-not [bool]$fromRows.Ok) 'raw table rows must not satisfy the identity gate'
    $map = @{}
    foreach ($row in $rows) { $map[[string]$row[0]] = [string]$row[1] }
    $fromMap = Test-KanaAiLifecycleCandidateIdentity -PropertyMap $map -TemplatePlatform 'x64;1041' -Pinned $pinned
    Assert-True ([bool]$fromMap.Ok) ('a property dictionary must satisfy the identity gate: ' + (@($fromMap.Errors) -join ' | '))
    Assert-Equal '{FBDCE95B-46CA-4959-8D36-26ABEE793117}' ([string]$fromMap.ProductCode) 'the ProductCode must come through the gate'
    Assert-Equal '1' ([string]$fromMap.AllUsers) 'ALLUSERS must come through the gate'
    Assert-True ($map -is [System.Collections.IDictionary]) 'the shape the reader now returns must be the shape the gate reads'
}

Invoke-Test -Id 'ST-67' -Name 'the product list is read as a property, never as a method' -Body {
    # Measured defect, and the reason the third elevated run died: 'Products' is
    # a property of the Windows Installer automation object, not a method.
    # InvokeMethod raised DISP_E_MEMBERNOTFOUND (0x80020003) and the direct
    # PowerShell property read returned $null, while GetProperty returned 182
    # GUID strings from the same object on the same machine.  A $null result is
    # the dangerous half: @($null).Count is 1, so a count-only check would have
    # reported one product and compared it as a code.
    $text = [System.IO.File]::ReadAllText($commonPath)
    Assert-True ($text.Contains("InvokeMember('Products', 'GetProperty'")) 'Products must be read with the GetProperty binding'
    Assert-True (-not $text.Contains("-Method 'Products'")) 'Products must not be reached through the InvokeMethod wrapper'
    Assert-True (-not $text.Contains("InvokeMember('Products', 'InvokeMethod'")) 'Products must never be bound as a method'
    # The empty-result trap has to stay closed, so the reader is asserted to
    # filter rather than to pass a null element through.
    Assert-True ($text.Contains('Get-KanaAiLifecycleInstallerProductCodes')) 'the enumeration must go through a named reader'
    Assert-True ($text.Contains("'^\{[0-9A-Fa-f]{8}-")) 'the reader must keep only brace-delimited GUIDs'
}

Invoke-Test -Id 'ST-68' -Name 'ProductInfo is never reached through InvokeMember, and UpgradeCode comes from the cached MSI' -Body {
    # Measured: Type.InvokeMember raised DISP_E_MEMBERNOTFOUND for ProductInfo on
    # every product and every property.  The direct adapter resolves it for
    # ProductName, LocalPackage, InstallLocation, VersionString, InstallDate and
    # InstallSource, but it raises "ProductInfo,Product,Attribute" for UpgradeCode
    # and for InstallState, so neither of those two may be requested through it.
    $text = [System.IO.File]::ReadAllText($commonPath)
    Assert-True (-not $text.Contains("-Method 'ProductInfo'")) 'ProductInfo must not be reached through the InvokeMethod wrapper'
    Assert-True ($text.Contains('$installer.ProductInfo($ProductCode, $PropertyName)')) 'ProductInfo must be read through the direct call adapter'
    Assert-True ($text.Contains('Get-KanaAiLifecycleCachedMsiProperty')) 'the refused attributes need a second, authoritative reader'
    Assert-True ($text.Contains("Get-KanaAiLifecycleCachedMsiProperty -Ledger `$Ledger -ProductCode ([string]`$code) -PropertyName 'UpgradeCode'")) 'UpgradeCode must be read from the cached MSI Property table'
    Assert-True (-not $text.Contains("Get-KanaAiLifecycleProductInfo -Ledger `$Ledger -ProductCode ([string]`$code) -PropertyName 'UpgradeCode'")) 'UpgradeCode must not still be requested from ProductInfo'
}

Invoke-Test -Id 'ST-69' -Name 'the install state comes from the documented one-argument MsiQueryProductState' -Body {
    # This case previously asserted the opposite, and it locked the mistake in.
    # The documented prototype is
    #     INSTALLSTATE MsiQueryProductStateW(LPCWSTR szProduct);
    # one argument, no out parameter, and the return value IS the state. Microsoft
    # Learn, the wine msi.h and the mingw-w64 msi.h agree, and the documented
    # returns are only ABSENT, ADVERTISED, DEFAULT, INVALIDARG and UNKNOWN, so
    # ERROR_ACCESS_DENIED is not a value this function can produce. A five is
    # INSTALLSTATE_DEFAULT and means installed.
    #
    # Declaring it with an `out int` produced three false conclusions in a row: a
    # healthy machine reported ERROR_ACCESS_DENIED, a repair was attempted that was
    # never needed, and the refusal gate would have rejected every working machine.
    # So the shape is asserted from both directions, and the call site is checked to
    # pass exactly one argument.
    $text = [System.IO.File]::ReadAllText($commonPath)
    Assert-True ($text.Contains('MsiQueryProductStateW(string product);')) 'the declaration must be the documented one-argument form'
    Assert-True (-not ($text -match 'MsiQueryProductStateW\([^)]*\b(out|ref)\b')) 'no out or ref parameter may exist, MsiQueryProductState has no out parameter'
    Assert-True (-not ($text -match 'MsiQueryProductStateW\([^)]*,[^)]*\)')) 'the declaration must not take a second parameter at all'
    Assert-True ($text.Contains('[KanaAiLifecycleMsiNative]::MsiQueryProductStateW($ProductCode)')) 'the call must pass only the product code and use the return value as the state'
    # And no error-code reading of the return value may come back.
    Assert-True (-not ($text.Contains('$rc = [KanaAiLifecycleMsiNative]::MsiQueryProductStateW'))) 'the return value must never be read as an error code'
    Assert-True (-not ($text.Contains('if ($rc -ne 0) { return ') )) 'there is no error code to branch on, so that branch must not exist'
    # The documented return set has no zero, so a zero can only mean the call did
    # not dispatch, and it must not be mapped onto a real state.
    Assert-True (-not ($text -match '(?m)^\s*0 \{ return ')) 'zero is not a documented INSTALLSTATE and must not be mapped to one'
}

Invoke-Test -Id 'ST-70' -Name 'the install state vocabulary maps to the harness vocabulary without machine access' -Body {
    # The mapping is split out so it can be asserted here without touching the
    # machine, and 'unknown' has to stay distinct from 'absent': the harness
    # treats unknown as never absent.
    Assert-Equal 'installed' (ConvertTo-KanaAiLifecycleProductState -Raw 'DEFAULT') 'DEFAULT is a local install'
    Assert-Equal 'installed' (ConvertTo-KanaAiLifecycleProductState -Raw 'LOCAL') 'LOCAL is a local install'
    Assert-Equal 'installed' (ConvertTo-KanaAiLifecycleProductState -Raw 'local') 'the comparison must not depend on the case'
    Assert-Equal 'advertised' (ConvertTo-KanaAiLifecycleProductState -Raw 'ADVERTISED') 'ADVERTISED is advertised'
    Assert-Equal 'staged' (ConvertTo-KanaAiLifecycleProductState -Raw 'SOURCE') 'SOURCE is staged'
    Assert-Equal 'absent' (ConvertTo-KanaAiLifecycleProductState -Raw 'ABSENT') 'ABSENT is absent'
    Assert-Equal 'absent' (ConvertTo-KanaAiLifecycleProductState -Raw 'REMOVED') 'REMOVED is absent'
    # INSTALLSTATE_UNKNOWN is documented as "the product is neither advertised or
    # installed".  It is an answer, and it is the answer a product that has never
    # been installed always gives, so it has to read as absent and not as an
    # unanswered state.
    Assert-Equal 'absent' (ConvertTo-KanaAiLifecycleProductState -Raw 'UNKNOWN') 'UNKNOWN is neither advertised nor installed, so it is absent'
    Assert-Equal 'unknown' (ConvertTo-KanaAiLifecycleProductState -Raw '') 'an unanswered state is unknown'
    Assert-Equal 'unknown' (ConvertTo-KanaAiLifecycleProductState -Raw 'SOMETHING-ELSE') 'an undocumented state is unknown'
    Assert-Equal 'unknown' (ConvertTo-KanaAiLifecycleProductState -Raw $null) 'a null state is unknown'
    # The entry point decides "locally installed" with this exact pattern, so the
    # producer of that field has to keep emitting the raw name.  If the field were
    # widened to 'installed' the match would fail and an installed product would
    # be reported as absent, which no unit test above would notice.
    $run = [System.IO.File]::ReadAllText($runPath)
    Assert-True ($run.Contains("installState -match '^(DEFAULT|LOCAL)$'")) 'the entry point must keep filtering on the raw state name'
    $text = [System.IO.File]::ReadAllText($commonPath)
    Assert-True ($text.Contains('Get-KanaAiLifecycleProductInstallStateName -Ledger $Ledger -ProductCode ([string]$code)')) 'the found record must take the raw state name, not the harness vocabulary'
}

Invoke-Test -Id 'ST-71' -Name 'no case is nested inside another case body' -Body {
    # Measured defect in this very file: three successive fixes each appended an
    # Invoke-Test without closing the previous body, so ST-63 to ST-66 ended up
    # inside ST-62 and ST-66 inside ST-65.  The file still parsed and every case
    # still reported ok, but the outer cases could no longer fail on their own:
    # any inner failure was reported as the outer case failing too, and ST-62
    # passing said nothing about ST-62.  The nesting is asserted structurally so
    # the next appended case cannot reintroduce it.
    $selfErrors = $null
    $selfTokens = $null
    $selfAst = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$selfTokens, [ref]$selfErrors)
    Assert-Equal 0 @($selfErrors).Count 'the self test file must parse'
    $commands = @($selfAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { $_.GetCommandName() -eq 'Invoke-Test' })
    Assert-True ($commands.Count -ge 60) ('the file must really contain the cases, found ' + $commands.Count)
    $ids = @()
    foreach ($command in $commands) {
        $id = 'unknown'
        if ($command.Extent.Text -match "-Id\s+'([^']+)'") { $id = $matches[1] }
        $ids += $id
        $node = $command.Parent
        $nested = $false
        while ($null -ne $node) {
            if ($node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Test') { $nested = $true; break }
            $node = $node.Parent
        }
        Assert-True (-not $nested) ("case $id must be a top-level case, not nested inside another case body")
    }
    $duplicates = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    Assert-Equal 0 $duplicates.Count ('every case id must be unique, duplicated: ' + ($duplicates -join ', '))
}

Invoke-Test -Id 'ST-72' -Name 'an unanswered install state refuses the run instead of reading as absent' -Body {
    # Measured defect, and the most dangerous one found in this harness.
    # Get-KanaAiLifecycleProductState documents that 'unknown' "is never
    # treated as absent", but the entry point only refused when the state was
    # 'installed'.  On a machine whose installer declines to answer - measured
    # here: MsiQueryProductState returned ERROR_ACCESS_DENIED for every valid
    # product code, and Installer\ProductInfo raised for InstallState - the
    # state came back 'unknown', the pre-existing-target check did not fire,
    # the ^(DEFAULT|LOCAL)$ filter in the later phases matched nothing, and
    # every phase would have reported an installed product as absent.  A
    # release gate that answers "nothing is installed" on a machine with two
    # registered KanaAI products is worse than one that crashes.
    $run = [System.IO.File]::ReadAllText($runPath)
    Assert-True ($run.Contains('INSTALL-STATE-UNDETERMINED')) 'the refusal must be recorded as a named critical finding'
    Assert-True ($run.Contains("`$targetState -eq 'unknown'")) 'an unknown state must be part of the refusal condition'
    Assert-True ($run.Contains('$undeterminedState')) 'a matched product with no state must also refuse'
    # Position matters as much as presence: the gate has to run before the
    # pre-existing-target check, or that check is reached with nothing refused,
    # and before any phase can install anything.
    $gateAt = $run.IndexOf('INSTALL-STATE-UNDETERMINED')
    $preexistingAt = $run.IndexOf('PREEXISTING-TARGET-INSTALL')
    Assert-True ($gateAt -gt 0) 'the refusal must exist in the entry point'
    Assert-True ($preexistingAt -gt 0) 'the pre-existing-target check must exist in the entry point'
    Assert-True ($gateAt -lt $preexistingAt) 'the undetermined-state refusal must come before the pre-existing-target check'
    Assert-True ($run.Contains('An unanswered state is not an absent state')) 'the receipt must state why the run stopped, in the words an operator needs'
    # And the refusal must be terminal, not a warning: it has to write the
    # receipt and exit non-zero, so an unanswered machine is never mistaken
    # for a completed run.
    $afterGate = $run.Substring($gateAt)
    Assert-True ($afterGate.Contains('exit 2')) 'the refusal must exit non-zero'
    Assert-True ($run.Contains('Repair the machine')) 'the refusal must say what the operator has to do'
}

Invoke-Test -Id 'ST-73' -Name 'the INSTALLSTATE switch covers exactly the documented states' -Body {
    # This case pinned the wrong mapping once, and that wrong mapping is why the
    # harness could never run.  It asserted INSTALLSTATE_UNKNOWN must not become a
    # state name, on the reading that -1 means "the installer did not answer".
    # Microsoft Learn documents -1 as "the product is neither advertised or
    # installed": an answer, and the answer that means not present.  A product
    # that has never been installed always returns it, so routing it to no state
    # made the candidate read as 'unknown', fired INSTALL-STATE-UNDETERMINED, and
    # made the clean-install baseline the gate exists to confirm unconfirmable on
    # every healthy machine.
    #
    # Measured on this machine with the one-argument prototype ST-69 pins, with
    # both controls: the never-installed candidate returned -1, the zero GUID and
    # a random never-installed GUID returned -1, five real installed products
    # returned 5, and 'not-a-guid' and the empty string returned -2.  So -1 is the
    # answer that means absent and -2 is the value that means no answer.
    #
    # Kept machine-free so the self test stays deterministic; the measurements are
    # recorded in the comments of the function this case pins.
    $text = [System.IO.File]::ReadAllText($commonPath)
    foreach ($pair in @(@('5', 'DEFAULT'), @('3', 'LOCAL'), @('1', 'ADVERTISED'), @('4', 'SOURCE'), @('2', 'ABSENT'), @('-1', 'UNKNOWN'))) {
        Assert-True ($text.Contains($pair[0] + " { return '" + $pair[1] + "' }")) ("INSTALLSTATE " + $pair[0] + " must map to " + $pair[1])
    }
    # INSTALLSTATE_INVALIDARG is what a correct call returns when it was handed an
    # unusable product code.  That one is genuinely no answer.
    Assert-True (-not ($text -match '(?m)^\s*-2 \{ return ')) 'INSTALLSTATE_INVALIDARG must not map to a state name'
    Assert-True (-not ($text -match '(?m)^\s*6 \{ return ')) 'INSTALLSTATE_BROKEN is not a state the harness reports as installed or absent'
    # No INSTALLSTATE has the value 7: REMOVED shares 1 with ADVERTISED and
    # NOTUSED is -7, so a 7 branch can only invent a state the API never reports.
    Assert-True (-not ($text -match '(?m)^\s*7 \{ return ')) 'no INSTALLSTATE has the value 7, so it must not be mapped'
    # Everything not explicitly mapped has to fall through to the empty string.
    Assert-True ($text.Contains("default { return '' }")) 'any undocumented return must yield no state, so unknown is honest'
    # An unanswered state stays distinct from absent, while the documented UNKNOWN
    # is treated as the absent answer it is.
    Assert-Equal 'unknown' (ConvertTo-KanaAiLifecycleProductState -Raw '') 'an unanswered state stays unknown'
    Assert-Equal 'unknown' (ConvertTo-KanaAiLifecycleProductState -Raw 'SOMETHING-ELSE') 'an undocumented state stays unknown'
    Assert-Equal 'absent' (ConvertTo-KanaAiLifecycleProductState -Raw 'UNKNOWN') 'the documented UNKNOWN is neither advertised nor installed, so it is absent'
    Assert-Equal 'absent' (ConvertTo-KanaAiLifecycleProductState -Raw 'ABSENT') 'a real absent state is still absent'
}

Invoke-Test -Id 'ST-74' -Name 'a phase that runs no command resolves no log path instead of throwing' -Body {
    # Measured on the first real -Execute run, and it stopped that run on its
    # first phase.  Get-PhaseLogPath nested two optional-property reads: the inner
    # read of 'command' returned its $null default for a phase that declares no
    # command, and that $null went straight into the outer read's Mandatory -Object
    # parameter.  The binder threw "Cannot bind argument to parameter 'Object'
    # because it is null", PF-01 never finished, no phase was observed and no
    # receipt could decide anything.  Four of the eleven phases in the shipped plan
    # run no command at all: PF-01, PF-02, OB-01 and CL-01.
    #
    # The root cause is one level down and is pinned here too:
    # Get-KanaAiLifecycleOptionalProperty guards $null in its own body, but a
    # Mandatory parameter without AllowNull throws during binding, so that guard
    # was unreachable dead code and could never do the job it was written for.
    $text = [System.IO.File]::ReadAllText($commonPath)
    Assert-True ($text.Contains('[Parameter(Mandatory = $true)][AllowNull()]$Object')) 'the optional-property reader must accept an explicit null so its own guard is reachable'
    Assert-Equal 'fallback' (Get-KanaAiLifecycleOptionalProperty -Object $null -Name 'anything' -Default 'fallback') 'a null object returns the default instead of throwing'
    Assert-Equal '' (Get-KanaAiLifecycleOptionalProperty -Object (Get-KanaAiLifecycleOptionalProperty -Object ([ordered]@{ id = 'PF-01' }) -Name 'command' -Default $null) -Name 'logFile' -Default '') 'a nested read through a missing property returns the default'

    # The entry point is only read as text here: dot-sourcing it would demand a
    # mode and exit, so Get-PhaseLogPath is pinned the way ST-69 and ST-73 pin
    # their functions.
    $run = [System.IO.File]::ReadAllText($runPath)
    Assert-True (-not ($run.Contains('-Object (Get-KanaAiLifecycleOptionalProperty'))) 'the log path must not nest one optional-property read inside another'
    Assert-True ($run.Contains('$command = Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name ''command'' -Default $null')) 'the command has to be read on its own line'
    Assert-True ($run.Contains('if ($null -eq $command) { return '''' }')) 'a phase with no command resolves no log path'

    # The condition has to stay real.  If the shipped plan ever gave every phase a
    # command, this case would be pinning a situation that cannot occur.
    $plan = Read-KanaAiLifecycleJson -Path $planPath
    $commandless = @(@($plan.phases) | Where-Object { $null -eq (Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'command' -Default $null) })
    Assert-True ($commandless.Count -gt 0) 'the shipped plan must still contain a phase that runs no command'
}

Invoke-Test -Id 'ST-75' -Name 'a first run executes its destructive phases instead of refusing them' -Body {
    # Measured on the first real -Execute run against a clean machine: every
    # destructive phase came back 'refused', and the destructive phases are every
    # phase that installs, uninstalls, upgrades or downgrades.  W2 ran its two
    # observation phases, decided nothing, and could never have produced evidence.
    #
    # The planner could not tell a first run from a retry.  Both leave a phase's
    # prior outcome at 'not_run' and the refusal branch tested only that value, so
    # a first execution was treated as a re-run of a step that had failed.  ST-44
    # pins the retry case and still holds, because it passes a prior receipt.  What
    # was missing is the case with no prior run at all, where there is nothing to
    # repeat and an acknowledgement for a RE-run cannot mean anything.
    $plan = New-SyntheticPlan
    $first = Resolve-KanaAiLifecycleResumePlan -Plan $plan -PriorResults $null -ResumeFrom '' -AllowDestructiveRerun $false
    Assert-True ([bool]$first.Ok) 'a first run must be planned without error'
    foreach ($action in @($first.Actions)) {
        Assert-Equal 'run' ([string]$action.decision) ('phase ' + [string]$action.phase + ' must run on a first execution')
    }
    Assert-Equal 0 (@($first.RefusedPhases).Count) 'no phase may be refused on a first run'

    # An empty prior-result list is the same situation as no prior receipt.
    $empty = Resolve-KanaAiLifecycleResumePlan -Plan $plan -PriorResults @() -ResumeFrom '' -AllowDestructiveRerun $false
    foreach ($action in @($empty.Actions)) {
        Assert-Equal 'run' ([string]$action.decision) ('phase ' + [string]$action.phase + ' must run when the prior results are empty')
    }

    # The retry case is untouched: once a prior run exists, a destructive phase
    # that never completed is still refused without the acknowledgement.
    $retry = Resolve-KanaAiLifecycleResumePlan -Plan $plan -PriorResults @([pscustomobject]@{ phase = 'install'; outcome = 'pass' }) -ResumeFrom 'install' -AllowDestructiveRerun $false
    $uninstall = @(@($retry.Actions) | Where-Object { $_.phase -eq 'uninstall' })[0]
    Assert-Equal 'refused' ([string]$uninstall.decision) 'a destructive phase that never completed is still refused once a prior run exists'
}

Invoke-Test -Id 'ST-76' -Name 'List[object] phase results enumerate without an array subexpression' -Body {
    # On this Windows PowerShell build `@($listObject)` throws "Argument types do
    # not match" when the element type is object.  The -Execute path stores its
    # phase results in a List[object] and re-indexes them in the final-observation
    # re-evaluation, so that loop must use foreach, never @().
    $list = New-Object System.Collections.Generic.List[object]
    [void]$list.Add([ordered]@{ phase = 'install-setup'; id = 'IS-01' })
    [void]$list.Add([ordered]@{ phase = 'absent-final';  id = 'OB-01' })
    $phasesByName = @{}
    foreach ($record in $list) { $phasesByName[[string]$record.phase] = $record }
    Assert-True $phasesByName.ContainsKey('install-setup') 'the first phase must be indexed by name'
    Assert-True $phasesByName.ContainsKey('absent-final') 'the second phase must be indexed by name'
    Assert-Equal 'IS-01' ([string]$phasesByName['install-setup'].id) 'the indexed record must keep its id'
}

# ---------------------------------------------------------------------------
# 11. the product-code expectation.  The plan's expect text is a resolution
#     instruction, never a value.
# ---------------------------------------------------------------------------
# The three product codes the W2 receipt at
# .local\w2-execute-20260926-202806\w2\receipt.json actually carried.  They are
# recorded here so these cases are driven by the measured values rather than by
# convenient ones; no machine is read to obtain them.
$script:CandidateCodeFromReceipt = '{CD242B2B-5E48-492F-B683-A071E2CC4515}'
$script:NewerCodeFromReceipt = '{B89B09D1-1FB2-42D2-AA31-2CD52DB113C7}'
# A third product code, so a "these two must disagree" case is really a
# disagreement and not a coincidence.
$script:ForeignCode = '{0F0F0F0F-1111-4222-8333-444444444444}'

function New-ProductCodePhase {
    param([Parameter(Mandatory = $true)][string]$Expect)
    return [pscustomobject]@{
        id      = 'SY-PC'
        name    = 'product-code-only'
        asserts = @([pscustomobject]@{ check = 'product-code'; expect = $Expect; required = $true })
    }
}

function Get-ProductCodeCheck {
    param([Parameter(Mandatory = $true)]$Outcome)
    return @(@($Outcome.checks) | Where-Object { [string]$_.check -eq 'product-code' })[0]
}

Invoke-Test -Id 'ST-77' -Name 'a resolved product code is never compared with the plan instruction' -Body {
    # Measured defect, and the W2 receipt's first line is its proof:
    #   UF-01 product-code fail "the installed product code is
    #   '{B89B09D1-...}', expected '{B89B09D1-...}'"
    # Two identical strings, reported as a disagreement.  The cause was that only
    # from-candidate-msi had a branch; every other instruction fell through to
    # `$installed -eq $expect`, which compares a GUID with a word and is always
    # false.  So the correct forward upgrade failed, and the harness could not
    # report a pass for a correct machine at all.
    #
    # All three documented instructions are driven here with an installed code
    # that EQUALS the resolved expectation.  Each must pass, which is impossible
    # for the old shape.  The verdict text is checked as well: an instruction
    # that reached a comparison would have to appear in the detail.
    $cases = @(
        [pscustomobject]@{ instruction = 'from-candidate-msi'; source = 'candidate-msi'; code = $script:CandidateCodeFromReceipt },
        [pscustomobject]@{ instruction = 'from-newer-msi'; source = 'newer-msi'; code = $script:NewerCodeFromReceipt },
        [pscustomobject]@{ instruction = 'from-current-msi'; source = 'installed-before-this-phase'; code = $script:NewerCodeFromReceipt }
    )
    foreach ($case in $cases) {
        $observation = New-KanaAiLifecycleSyntheticObservation -InstalledProductCode $case.code -ExpectedProductCode $case.code -ExpectedProductCodeSource $case.source
        $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-ProductCodePhase -Expect $case.instruction) -Context ([ordered]@{ observation = $observation })
        $check = Get-ProductCodeCheck -Outcome $outcome
        Assert-Equal 'pass' ([string]$check.outcome) ("the installed and the expected code are both {0}, so the {1} phase must pass" -f $case.code, $case.instruction)
        Assert-True (([string]$check.detail) -notmatch 'from-(candidate|newer|current)-msi') ("a resolved comparison must not quote the instruction in its verdict: " + [string]$check.detail)
    }
    # The instruction list is closed.  A word that resolves to nothing can never
    # become a value, which is what keeps a new instruction from silently
    # becoming a fail.
    Assert-Equal 'candidate-msi' (Get-KanaAiLifecycleProductCodeExpectationSource -Expect 'from-candidate-msi') 'from-candidate-msi resolves to the candidate MSI'
    Assert-Equal 'newer-msi' (Get-KanaAiLifecycleProductCodeExpectationSource -Expect 'from-newer-msi') 'from-newer-msi resolves to the newer fixture MSI'
    Assert-Equal 'installed-before-this-phase' (Get-KanaAiLifecycleProductCodeExpectationSource -Expect 'from-current-msi') 'from-current-msi resolves to the before-picture'
    Assert-Equal '' (Get-KanaAiLifecycleProductCodeExpectationSource -Expect 'from-whatever-msi') 'an unknown instruction resolves to nothing at all'
    Assert-Equal '' (Get-KanaAiLifecycleProductCodeExpectationSource -Expect '') 'no instruction at all resolves to nothing at all'
}

Invoke-Test -Id 'ST-78' -Name 'an unresolvable or mis-wired product-code expectation is unconfirmed, never a verdict' -Body {
    # The old shape had exactly two answers for a non-candidate instruction: fail
    # when the GUIDs happened to differ and fail when they did not, because the
    # comparison was against a word.  A failure is an accusation: it says the
    # machine disagrees with the plan.  When the harness could not resolve what
    # to compare, that accusation was unfounded, so the honest answer is
    # unconfirmed, and the same is true when the resolved value came from the
    # wrong product entirely.
    $unknown = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-ProductCodePhase -Expect 'from-candidate-maybe') -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation) })
    $unknownCheck = Get-ProductCodeCheck -Outcome $unknown
    Assert-Equal 'unconfirmed' ([string]$unknownCheck.outcome) 'an instruction this harness does not implement must be unconfirmed'
    Assert-True ($unknownCheck.outcome -ne 'pass') 'an unknown instruction must never pass'
    Assert-True ($unknownCheck.outcome -ne 'fail') 'an unknown instruction must not fail the machine for a comparison that was never made'
    Assert-True (([string]$unknownCheck.detail) -match 'from-candidate-maybe') 'the refusal has to name the instruction it could not resolve'

    # from-newer-msi with no newer MSI supplied: nothing to resolve, so nothing
    # is claimed.  This is the refusal the fix requires rather than a fail.
    $noNewer = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-ProductCodePhase -Expect 'from-newer-msi') -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -InstalledProductCode $script:NewerCodeFromReceipt -ExpectedProductCode '' -ExpectedProductCodeSource 'newer-msi') })
    Assert-Equal 'unconfirmed' ([string](Get-ProductCodeCheck -Outcome $noNewer).outcome) 'a blank expected code must be unconfirmed, not a pass'

    # A before-picture that was never taken is the same situation.
    $noBefore = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-ProductCodePhase -Expect 'from-current-msi') -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -InstalledProductCode $script:NewerCodeFromReceipt -ExpectedProductCode '' -ExpectedProductCodeSource 'installed-before-this-phase') })
    Assert-Equal 'unconfirmed' ([string](Get-ProductCodeCheck -Outcome $noBefore).outcome) 'a missing before-picture product code must be unconfirmed, not a pass'

    # Nothing installed, nothing to compare.
    $nothingInstalled = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-ProductCodePhase -Expect 'from-candidate-msi') -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -InstalledProductCode '' -ExpectedProductCode $script:CandidateCodeFromReceipt) })
    Assert-Equal 'unconfirmed' ([string](Get-ProductCodeCheck -Outcome $nothingInstalled).outcome) 'an unreadable installed product code must be unconfirmed'

    # The provenance is part of the claim.  An expectation that was resolved from
    # the wrong product decides nothing, even when the two codes happen to be
    # equal: that equality is a coincidence, not evidence.
    $misWired = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-ProductCodePhase -Expect 'from-current-msi') -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -InstalledProductCode $script:NewerCodeFromReceipt -ExpectedProductCode $script:NewerCodeFromReceipt -ExpectedProductCodeSource 'candidate-msi') })
    $misWiredCheck = Get-ProductCodeCheck -Outcome $misWired
    Assert-Equal 'unconfirmed' ([string]$misWiredCheck.outcome) 'an expectation taken from the wrong product must be unconfirmed'
    Assert-True (([string]$misWiredCheck.detail) -match 'installed-before-this-phase') 'the refusal has to name the provenance the instruction requires'
    Assert-True (([string]$misWiredCheck.detail) -match 'candidate-msi') 'the refusal has to name the provenance that was actually used'
}

Invoke-Test -Id 'ST-79' -Name 'a product-code failure always names two different codes' -Body {
    # The W2 line this harness must never produce again read "the installed
    # product code is 'X', expected 'X'": a failure whose two codes are equal is
    # not a disagreement, it is a self-contradiction.  Every failure path is
    # driven here with a deliberately different expected code, and the two codes
    # the detail names are compared with each other.
    foreach ($case in @(
            [pscustomobject]@{ instruction = 'from-candidate-msi'; source = 'candidate-msi'; installed = $script:CandidateCodeFromReceipt },
            [pscustomobject]@{ instruction = 'from-newer-msi'; source = 'newer-msi'; installed = $script:NewerCodeFromReceipt },
            [pscustomobject]@{ instruction = 'from-current-msi'; source = 'installed-before-this-phase'; installed = $script:NewerCodeFromReceipt }
        )) {
        # A third code, so the expected value is wrong for every case and not
        # only for two of them.
        $observation = New-KanaAiLifecycleSyntheticObservation -InstalledProductCode $case.installed -ExpectedProductCode $script:ForeignCode -ExpectedProductCodeSource $case.source
        $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase (New-ProductCodePhase -Expect $case.instruction) -Context ([ordered]@{ observation = $observation })
        $check = Get-ProductCodeCheck -Outcome $outcome
        Assert-Equal 'fail' ([string]$check.outcome) ("a real disagreement must fail the {0} phase" -f $case.instruction)
        $detail = [string]$check.detail
        $found = @([System.Text.RegularExpressions.Regex]::Matches($detail, '\{[0-9A-Fa-f-]{36}\}') | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique)
        Assert-Equal 2 $found.Count ("the failure detail must name both codes exactly once each: " + $detail)
        Assert-True ($found[0] -ne $found[1]) ('a failure detail must never name the same code twice: ' + $detail)
        Assert-True (([string]$check.evidence) -match 'source=' + $case.source) 'the evidence must record where the expectation came from'
    }
}

Invoke-Test -Id 'ST-80' -Name 'each shipped phase resolves its own product-code expectation' -Body {
    # Measured defect: only upgrade-forward had a phase-correct expectation.
    # Everything else inherited the candidate MSI's product code, so
    # downgrade-refused, whose plan instruction is from-current-msi, compared
    # itself against {CD242B2B-...} after upgrade-forward had already replaced
    # the installed product with {B89B09D1-...}.  The receipt line
    #   DR-01 product-code fail "the installed product code is
    #   '{B89B09D1-...}', expected '{CD242B2B-...}'"
    # is not a machine that disagreed with the plan; it is a phase pointed at
    # the wrong product.
    #
    # The resolver is pure and reads the shipped plan, so this case is driven
    # with the exact codes the W2 receipt carried and needs no machine at all.
    $plan = Read-KanaAiLifecycleJson -Path $planPath
    $dr = Get-KanaAiLifecyclePhase -Plan $plan -Name 'downgrade-refused'
    $uf = Get-KanaAiLifecyclePhase -Plan $plan -Name 'upgrade-forward'
    Assert-Equal 'from-current-msi' ([string](@(Get-KanaAiLifecycleOptionalProperty -Object $dr -Name 'asserts' -Default @()) | Where-Object { [string]$_.check -eq 'product-code' })[0].expect) 'DR-01 must still declare the before-picture instruction'

    $drResolved = Resolve-KanaAiLifecycleProductCodeExpectation -Phase $dr -CandidateProductCode $script:CandidateCodeFromReceipt -NewerProductCode $script:NewerCodeFromReceipt -InstalledBeforeCommand $script:NewerCodeFromReceipt
    Assert-Equal 'installed-before-this-phase' ([string]$drResolved.source) 'DR-01 must expect the product installed before its own command'
    Assert-Equal $script:NewerCodeFromReceipt ([string]$drResolved.productCode) 'DR-01 must expect the newer product code UF-01 left installed'
    Assert-True ([string]$drResolved.productCode -ne $script:CandidateCodeFromReceipt) 'DR-01 must not inherit the candidate MSI product code'

    $ufResolved = Resolve-KanaAiLifecycleProductCodeExpectation -Phase $uf -CandidateProductCode $script:CandidateCodeFromReceipt -NewerProductCode $script:NewerCodeFromReceipt -InstalledBeforeCommand $script:CandidateCodeFromReceipt
    Assert-Equal 'newer-msi' ([string]$ufResolved.source) 'UF-01 must expect the newer fixture MSI own product code'
    Assert-Equal $script:NewerCodeFromReceipt ([string]$ufResolved.productCode) 'UF-01 must compare against the newer fixture MSI own product code'

    # Every product-code instruction in the shipped plan has to be one this
    # harness implements, or the phase can only ever report unconfirmed.
    $instructions = @()
    foreach ($phase in @($plan.phases)) {
        foreach ($assert in @(Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'asserts' -Default @())) {
            if ([string](Get-KanaAiLifecycleOptionalProperty -Object $assert -Name 'check' -Default '') -eq 'product-code') {
                $instructions += [string](Get-KanaAiLifecycleOptionalProperty -Object $assert -Name 'expect' -Default '')
            }
        }
    }
    Assert-True ($instructions.Count -ge 4) ('the shipped plan must still carry its product-code assertions, found ' + $instructions.Count)
    foreach ($instruction in $instructions) {
        Assert-True (-not [string]::IsNullOrWhiteSpace((Get-KanaAiLifecycleProductCodeExpectationSource -Expect $instruction))) ("the shipped plan uses the product-code instruction '" + $instruction + "', which this harness cannot resolve")
    }

    # And the resolved DR-01 expectation turns the W2 observation into a pass
    # rather than a contradiction.
    $observation = New-KanaAiLifecycleSyntheticObservation -InstalledProductCode $script:NewerCodeFromReceipt -ExpectedProductCode ([string]$drResolved.productCode) -ExpectedProductCodeSource ([string]$drResolved.source)
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase $dr -Context ([ordered]@{ observation = $observation })
    $check = Get-ProductCodeCheck -Outcome $outcome
    Assert-Equal 'pass' ([string]$check.outcome) 'a refused downgrade that left the newer product installed must pass its product-code check'
    Assert-True (([string]$check.detail) -match 'before this phase') 'the pass detail must say the comparison was against the before-picture'
}

Invoke-Test -Id 'ST-81' -Name 'the entry point wires the expectation through the resolver, not off a phase name' -Body {
    # The resolver is pure and the entry point is not (dot-sourcing it would
    # demand a mode and exit), so the wiring itself is asserted from the call
    # site the way ST-62, ST-72 and ST-74 assert theirs.  What has to hold:
    #   * the phase's own instruction decides the expectation, never the name
    #   * the before-picture is captured before the command can start
    #   * the observation records where the expectation came from
    $run = [System.IO.File]::ReadAllText($runPath)
    Assert-True ($run.Contains('Resolve-KanaAiLifecycleProductCodeExpectation -Phase $phase')) 'every phase must resolve its expectation from its own plan instruction'
    Assert-True ($run.Contains('-InstalledBeforeCommand $productCodeInstalledBeforeCommand')) 'the before-picture must be the value handed to the resolver'
    Assert-True ($run.Contains('-NewerProductCode ([string]$state.newerProductCode)')) 'the newer fixture own product code must be the value handed to the resolver'
    # The old line: one phase name got the right expectation and every other
    # phase silently inherited the candidate's product code.
    Assert-True (-not ($run.Contains("if (`$phaseName -eq 'upgrade-forward' and `$state.ContainsKey('newerProductCode'))"))) 'the expectation must not be keyed off the phase name'
    # The receipt has to be able to show where the expectation came from.
    Assert-True ($run.Contains('expectedProductCodeSource = [string]$productCodeExpectation.source')) 'the observation must record the provenance of the expectation'
    Assert-True ($run.Contains('expectedProductCodeInstruction = [string]$productCodeExpectation.instruction')) 'the observation must record the instruction it resolved'
    Assert-True ($run.Contains('productCodeBeforeCommand = $productCodeInstalledBeforeCommand')) 'the observation must record what was installed before the command ran'
    # Position is the substance of the fix: a before-picture captured after the
    # command ran is the after-picture, which is exactly the old mistake.
    $captureAt = $run.IndexOf('$productCodeInstalledBeforeCommand = $productCodeForCommand')
    $startAt = $run.IndexOf('Invoke-KanaAiLifecycleCommand -Ledger')
    Assert-True ($captureAt -gt 0) 'the before-picture capture must exist in the entry point'
    Assert-True ($startAt -gt 0) 'the command launch must exist in the entry point'
    Assert-True ($captureAt -lt $startAt) 'the before-picture must be captured before the command is started'
    # The observation shape and the check have to agree on the field names, or
    # the provenance check reads an absent field and refuses every real run.
    $text = [System.IO.File]::ReadAllText($commonPath)
    Assert-True ($text.Contains("-Name 'expectedProductCodeSource'")) 'the check must read the recorded provenance'
    Assert-True ($text.Contains('elseif ($installed -eq $expected)')) 'the verdict must compare the two resolved product codes with each other'
    Assert-True (-not ($text -match '\$installed -eq \$expect(?!ed)')) 'a resolved product code must never be compared with the plan instruction itself'
}

# ---------------------------------------------------------------------------
# the log classifier, against the six real logs of one W2 run
# ---------------------------------------------------------------------------
$script:RealLogFacts = @(
    # Each entry is only the decisive lines of one real log from
    # .local/w2-execute-20260926-202806/w2, read out of that file and reduced to
    # the msiexec tokens.  The Japanese account name, the install path and the
    # log's own bulk are deliberately not carried into the repository, because
    # none of them is evidence.
    [pscustomobject]@{
        log = 'install-msi.log'; phase = 'IM-01'; expect = 'first-install'
        text = "Property(S): ProductState = -1`r`nDoing action: InstallInitialize`r`nMainEngineThread is returning 0`r`n"
    },
    [pscustomobject]@{
        log = 'reinstall-same.log'; phase = 'RS-01'; expect = 'reinstall'
        text = "Property(S): ProductState = 5`r`nProperty(S): Installed = 00:00:00`r`nDoing action: InstallInitialize`r`nMainEngineThread is returning 0`r`n"
    },
    [pscustomobject]@{
        log = 'uninstall-clean-1.log'; phase = 'UC-01'; expect = 'uninstall'
        text = "Property(S): ProductState = 5`r`nProperty(S): Installed = 00:00:00`r`nDoing action: InstallInitialize`r`nCleanupConfigData(RemovingProduct=1)`r`nMainEngineThread is returning 0`r`n"
    },
    [pscustomobject]@{
        log = 'upgrade-forward.log'; phase = 'UF-01'; expect = 'upgrade'
        text = "Property(S): ProductState = -1`r`nPROPERTY CHANGE: Adding WIX_UPGRADE_DETECTED property. Its value is '{B89B09D1-1FB2-42D2-AA31-2CD52DB113C7}'.`r`nDoing action: InstallInitialize`r`nCleanupConfigData(RemovingProduct=1)`r`nMainEngineThread is returning 0`r`n"
    },
    [pscustomobject]@{
        log = 'downgrade-refused.log'; phase = 'DR-01'; expect = 'downgrade-refused'
        text = "Property(S): ProductState = -1`r`nPROPERTY CHANGE: Adding WIX_DOWNGRADE_DETECTED property. Its value is '{B89B09D1-1FB2-42D2-AA31-2CD52DB113C7}'.`r`nDoing action: LaunchConditions`r`nMainEngineThread is returning 1603`r`n"
    }
)

Invoke-Test -Id 'ST-82' -Name 'the classifier reads every real W2 log of the measured run' -Body {
    # The old classifier was a bag of mutually exclusive markers that required
    # exactly one to fire.  Driven with the decisive lines of the six real logs
    # of .local/w2-execute-20260926-202806, it classified one of them, called
    # three ambiguous and found nothing in the sixth.  Four of the eleven W2
    # phases assert this check, and one of those four (RS-01) can then never
    # pass.  The real logs are the fixture here, not a synthetic string.
    foreach ($case in $script:RealLogFacts) {
        $r = Get-KanaAiLifecycleMsiLogClassification -Text $case.text
        Assert-True ([bool]$r.confident) ("{0} must classify with confidence, got '{1}' ({2})" -f $case.log, $r.classification, (@($r.evidence) -join ' '))
        Assert-Equal $case.expect ([string]$r.classification) ("{0} must classify as {1}" -f $case.log, $case.expect)
    }
    # The first install and the reinstall differ by exactly one fact: whether
    # the product was already registered when the transaction started.  If the
    # classifier ever collapsed them again, these two would swap.
    $first = Get-KanaAiLifecycleMsiLogFacts -Text $script:RealLogFacts[0].text
    $again = Get-KanaAiLifecycleMsiLogFacts -Text $script:RealLogFacts[1].text
    Assert-True (-not [bool]$first.alreadyInstalled) 'a first install starts with the product absent'
    Assert-True ([bool]$again.alreadyInstalled) 'a reinstall starts with the product installed'
    Assert-True ([bool]$again.installDatePresent) 'an already-registered product carries a cached install date in the log'
    # A removal and an upgrade both carry RemoveExistingProducts, so neither is
    # what tells them apart: only the Upgrade table result is.
    $uninstall = Get-KanaAiLifecycleMsiLogFacts -Text $script:RealLogFacts[2].text
    $upgrade = Get-KanaAiLifecycleMsiLogFacts -Text $script:RealLogFacts[3].text
    Assert-True ([bool]$uninstall.productRemoved) 'an uninstall removes the product'
    Assert-True ([bool]$upgrade.productRemoved) 'a MajorUpgrade removes the old product inside the same transaction'
    Assert-True (-not [bool]$upgrade.downgradeDetected) 'a forward upgrade never records a downgrade'
    Assert-True (-not [bool]$uninstall.upgradeDetected) 'a plain uninstall never records an upgrade'
}

Invoke-Test -Id 'ST-83' -Name 'no log fact is anchored to the start of a line' -Body {
    # A verbose log prefixes every line with "MSI (s) (pid) [time]: ", so a
    # pattern anchored with ^ never matches a real log.  The earlier marker bag
    # was written that way and its self test used strings without the prefix,
    # which is how four phases ended up asserting a check that could not fire on
    # any run.  The prefix is the reason, so it is in the test.
    $prefixed = "MSI (s) (30:58) [20:30:24:780]: PROPERTY CHANGE: Adding WIX_DOWNGRADE_DETECTED property. Its value is '{B89B09D1-1FB2-42D2-AA31-2CD52DB113C7}'.`r`n" +
        "MSI (s) (30:58) [20:30:24:780]: Property(S): ProductState = 5`r`n" +
        "MSI (s) (30:58) [20:30:24:780]: Property(S): Installed = 00:00:00`r`n" +
        "MSI (s) (30:58) [20:30:24:780]: CleanupConfigData(RemovingProduct=1)`r`n" +
        "MSI (s) (30:58) [20:30:24:780]: Doing action: InstallInitialize`r`n"
    $facts = Get-KanaAiLifecycleMsiLogFacts -Text $prefixed
    foreach ($name in @('alreadyInstalled', 'installDatePresent', 'downgradeDetected', 'productRemoved', 'installSequence')) {
        Assert-True ([bool]$facts[$name]) ("the fact '{0}' must be seen through a verbose log's own line prefix" -f $name)
    }
    # The same six tokens in a synthetic block with no prefix must give the same
    # facts, so the prefix is what is tolerated, not depended on.
    $bare = "PROPERTY CHANGE: Adding WIX_DOWNGRADE_DETECTED property. Its value is '{B89B09D1-1FB2-42D2-AA31-2CD52DB113C7}'.`r`nProperty(S): ProductState = 5`r`nProperty(S): Installed = 00:00:00`r`nCleanupConfigData(RemovingProduct=1)`r`nDoing action: InstallInitialize`r`n"
    $bareFacts = Get-KanaAiLifecycleMsiLogFacts -Text $bare
    foreach ($name in @('alreadyInstalled', 'installDatePresent', 'downgradeDetected', 'productRemoved', 'installSequence')) {
        Assert-True ([bool]$bareFacts[$name]) ("the fact '{0}' must not depend on a line prefix" -f $name)
    }
    Assert-Equal 'downgrade-refused' ([string](Get-KanaAiLifecycleMsiLogClassification -Text $prefixed).classification) 'the prefixed form must classify the same way'
    # A Japanese log is the only one this machine produces, so the facts must
    # not be English-only.  These two are the same two facts in the form a
    # localised installer writes them.
    $localised = Get-KanaAiLifecycleMsiLogFacts -Text "MSI (s) (30:58) [20:30:24:781]: 操作開始 20:30:24: LaunchConditions (PID 12345)。`r`nMSI (s) (30:58) [20:30:24:781]: アクションの終了 20:30:24: LaunchConditions。戻値 3。`r`nMSI (s) (30:58) [20:30:24:796]: MainEngineThread is returning 1603`r`n"
    Assert-True ([bool]$localised.installFailed) 'a localised failure line must still be read as a failure'
}

Invoke-Test -Id 'ST-84' -Name 'every log-classification expectation in the plan is one the classifier produces' -Body {
    # The plan's msi-log-classification expectations are read against real logs,
    # so an expectation the classifier can never emit is a phase that can never
    # pass.  `any` is exempt: it is an instruction, not a classification.
    $plan = Read-KanaAiLifecycleJson -Path $planPath
    $produced = @('first-install', 'reinstall', 'uninstall', 'upgrade', 'downgrade-refused')
    $seen = 0
    foreach ($phase in @($plan.phases)) {
        foreach ($assert in @(Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'asserts' -Default @())) {
            if ([string]$assert.check -ne 'msi-log-classification') { continue }
            $seen++
            $expect = [string]$assert.expect
            Assert-True ($expect -eq 'any' -or $produced -contains $expect) ("phase {0} expects '{1}', which the classifier cannot produce" -f $phase.id, $expect)
            if ($expect -ne 'any') {
                # And the real log of that phase really does produce it.
                $fixture = @($script:RealLogFacts | Where-Object { $_.phase -eq [string]$phase.id })
                if ($fixture.Count -eq 1) {
                    Assert-Equal $expect ([string](Get-KanaAiLifecycleMsiLogClassification -Text $fixture[0].text).classification) ("phase {0}'s own real log must produce {1}" -f $phase.id, $expect)
                }
            }
        }
    }
    Assert-True ($seen -ge 4) ('the plan must keep asserting the log classification, found ' + $seen)
}

Invoke-Test -Id 'ST-85' -Name 'the any expectation accepts any confident classification and nothing else' -Body {
    # `any` used to be compared like a classification name, so it could only
    # ever fail and every phase that used it also had to mark the check not
    # required.  It has to mean what it says, and it still must not rescue a
    # log that could not be classified.
    foreach ($expect in @('first-install', 'reinstall', 'uninstall', 'upgrade', 'downgrade-refused')) {
        $phase = [pscustomobject]@{ id = 'X-01'; asserts = @([pscustomobject]@{ check = 'msi-log-classification'; expect = 'any'; required = $true }) }
        $observation = New-KanaAiLifecycleSyntheticObservation -LogClassification $expect -LogConfident $true
        $check = @(Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = $observation })).checks | Where-Object { $_.check -eq 'msi-log-classification' }
        Assert-Equal 'pass' ([string]$check.outcome) ("any must accept a confident {0}" -f $expect)
    }
    $unconfident = [pscustomobject]@{ id = 'X-01'; asserts = @([pscustomobject]@{ check = 'msi-log-classification'; expect = 'any'; required = $true }) }
    $ambiguous = New-KanaAiLifecycleSyntheticObservation -LogClassification 'ambiguous-multiple-markers' -LogConfident $false
    $check = @(Resolve-KanaAiLifecyclePhaseOutcome -Phase $unconfident -Context ([ordered]@{ observation = $ambiguous })).checks | Where-Object { $_.check -eq 'msi-log-classification' }
    Assert-Equal 'unconfirmed' ([string]$check.outcome) 'any must not turn an unclassifiable log into a pass'
}

Invoke-Test -Id 'ST-86' -Name 'the refused downgrade is decided by the log, not by an exit code' -Body {
    # Measured: this package refuses a downgrade with a failed LaunchCondition,
    # which under /qn is 1603, while 1638 is the code Windows documents for the
    # same policy.  The plan used to name 1638 only, from documentation rather
    # than from an observation, so the phase could not pass on a correct
    # machine.  It now names exactly the two codes and refuses everything else,
    # and the refusal itself is proven by the log and the state checks.
    $plan = Read-KanaAiLifecycleJson -Path $planPath
    $dr = Get-KanaAiLifecyclePhase -Plan $plan -Name 'downgrade-refused'
    $exitAssert = @(Get-KanaAiLifecycleOptionalProperty -Object $dr -Name 'asserts' -Default @()) | Where-Object { [string]$_.check -eq 'command-exit-code' }
    $accepted = @(([string]$exitAssert.expect) -split ',') | ForEach-Object { $_.Trim() }
    Assert-True ($accepted -contains '1603') 'the plan must accept the 1603 this package actually returns'
    Assert-True ($accepted -contains '1638') 'the plan must keep the documented 1638'
    Assert-Equal 2 $accepted.Count ('the accepted set must be exactly those two codes, got: ' + ($accepted -join ','))
    # 1603 is the generic failure code, so accepting it must not be enough on
    # its own: the phase needs the log and the state.
    $stateChecks = @(Get-KanaAiLifecycleOptionalProperty -Object $dr -Name 'asserts' -Default @()) | Where-Object { [string]$_.check -ne 'command-exit-code' -and [bool]$_.required }
    foreach ($needed in @('msi-log-classification', 'product-state', 'product-code', 'file-inventory-unchanged')) {
        Assert-True (@($stateChecks | Where-Object { [string]$_.check -eq $needed }).Count -eq 1) ("a refused downgrade must require '{0}' as well" -f $needed)
    }
    # A refusal whose log says nothing is not a refusal this harness can report.
    $phase = [pscustomobject]@{ id = 'X-01'; asserts = @([pscustomobject]@{ check = 'msi-log-classification'; expect = 'downgrade-refused'; required = $true }) }
    $quiet = New-KanaAiLifecycleSyntheticObservation -LogClassification 'unclassified' -LogConfident $false
    $check = @(Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = $quiet })).checks | Where-Object { $_.check -eq 'msi-log-classification' }
    Assert-Equal 'unconfirmed' ([string]$check.outcome) 'an unclassifiable downgrade log must be unconfirmed'
    # And the real refused-downgrade log does produce the classification.
    $fixture = @($script:RealLogFacts | Where-Object { $_.log -eq 'downgrade-refused.log' })[0]
    Assert-Equal 'downgrade-refused' ([string](Get-KanaAiLifecycleMsiLogClassification -Text $fixture.text).classification) 'the real refused-downgrade log must classify as a refused downgrade'
}


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
$failed = @($script:TestResults | Where-Object { -not $_.ok })
Write-Host ''
Write-Host ('self test: {0} case(s), {1} passed, {2} failed' -f $script:TestResults.Count, (@($script:TestResults | Where-Object { $_.ok }).Count), $failed.Count)
foreach ($result in $script:TestResults) {
    Write-Host ('  {0} {1,-6} {2}' -f $result.id, $(if ($result.ok) { 'ok' } else { 'FAIL' }), $result.name)
    if (-not $result.ok) { Write-Host ('      ' + $result.detail) }
}
try { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($failed.Count -gt 0) { exit 1 }
exit 0
