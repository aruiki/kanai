# KanaAI desktop validation harness - self test.
#
# What this exercises: the harness own logic, using synthetic data only.
#   * plan validation, including the negative cases
#   * the verdict rule, including the case that made W1 unreadable
#   * readback comparison, including unavailable readbacks
#   * SHA-256, JSON writing and reading, the privacy scan
#   * cleanup planning and its idempotency
#   * the static native-wiring check
#
# What this deliberately does NOT do: touch a window station, touch a desktop,
# launch a process, read the registry, read the clipboard, or read anything
# outside this directory and a private temporary folder. The last test in the
# file asserts that the native type is still not loaded when the run finishes.
#
# Run:  powershell -NoProfile -File Invoke-KanaAIDesktopValidationSelfTest.ps1
# Exit: 0 when every test passed, 1 otherwise.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$commonPath = Join-Path $root 'DesktopValidation.Common.ps1'
$nativePath = Join-Path $root 'DesktopValidation.Native.cs'
$planPath = Join-Path $root 'desktop-validation-plan.json'
foreach ($required in @($commonPath, $nativePath, $planPath, (Join-Path $root 'Invoke-KanaAIDesktopValidation.ps1'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "self-test cannot run: missing $required" }
}
. $commonPath

$script:TestResults = New-Object System.Collections.Generic.List[object]
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('kanai-desktop-selftest-' + [Guid]::NewGuid().ToString('n').Substring(0, 12))
[void](New-Item -ItemType Directory -Path $script:TempRoot -Force)

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Ok,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    $script:TestResults.Add([pscustomobject]@{
            id     = $Id
            name   = $Name
            ok     = $Ok
            detail = $Detail
        })
}

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Detail)
    if (-not $Condition) { throw $Detail }
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Detail)
    if ([string]$Expected -ne [string]$Actual) { throw ("$Detail (expected '$Expected', got '$Actual')") }
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

function New-SyntheticPlan {
    <#
        A minimal but structurally complete plan. Tests mutate a fresh copy of
        it so each negative case is independent of the others.

        The kana canary is taken from the harness constants rather than from the
        here-string below. That keeps the reference plan self-consistent whatever
        code page this file happens to be read with, which is the same class of
        defect the code-point check in Test-KanaAiValidationPlan exists to catch.
    #>
    $plan = (@'
{
  "schemaVersion": 1,
  "planId": "synthetic",
  "canary": { "romaji": "kanaai", "kana": "replaced-below", "kanaCodePoints": [] },
  "steps": [
    { "id": "S-01", "phase": "preflight", "action": "capture-preflight", "assertion": "assert", "direction": "any", "readbackMethod": "static-capture",
      "expected": { "observable": "environment", "match": "true" } },
    { "id": "S-02", "phase": "injection", "action": "loopback-canary", "assertion": "assert", "direction": "any", "readbackMethod": "loopback-wm-gettext",
      "input": { "text": "kanaai" }, "expected": { "observable": "injector-loopback-text", "match": "contains", "value": "kanaai" } },
    { "id": "S-03", "phase": "toggle-a", "action": "press-key", "assertion": "assert", "direction": "any", "calibratesDirection": true, "readbackMethod": "wm-gettext",
      "input": { "keys": ["VK_RETURN"] }, "expected": { "observable": "document-kana", "match": "predicate", "predicate": "kana-present" } },
    { "id": "S-04", "phase": "toggle-b", "action": "press-key", "assertion": "assert", "direction": "any", "calibratesDirection": true, "readbackMethod": "wm-gettext",
      "input": { "keys": ["VK_RETURN"] }, "expected": { "observable": "document-ascii", "match": "equals", "value": "kanaai" } },
    { "id": "S-05", "phase": "ime-on", "action": "press-key", "assertion": "assert", "direction": "ime-on", "imeSetup": { "targetState": "on" }, "readbackMethod": "wm-gettext",
      "input": { "keys": ["VK_RETURN"] }, "expected": { "observable": "document-kana", "match": "predicate", "predicate": "kana-present" } }
  ]
}
'@) | ConvertFrom-Json
    $plan.canary.kana = Get-KanaAiValidationCanaryKana
    $plan.canary.kanaCodePoints = @(Get-KanaAiValidationCanaryKanaCodePoints)
    return $plan
}

function Get-PlanErrorCodes {
    param([Parameter(Mandatory = $true)]$Validation)
    $codes = @()
    foreach ($entry in @($Validation.Errors)) {
        $index = ([string]$entry).IndexOf(':')
        if ($index -gt 0) { $codes += ([string]$entry).Substring(0, $index) } else { $codes += [string]$entry }
    }
    return $codes
}

function New-SyntheticArtifact {
    <#
        A stand-in for the run script artifact builder, which the self test
        cannot call because the run script is only parsed, never executed here.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $info = Get-Item -LiteralPath $Path
    return [ordered]@{
        pathRelative = [System.IO.Path]::GetFileName($Path)
        bytes        = [int64]$info.Length
        sha256       = Get-KanaAiValidationSha256 -Path $Path
    }
}

# ---------------------------------------------------------------------------
# 1. Canary and key tokens
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-01' -Name 'canary constants and code points' -Body {
    Assert-Equal 'kanaai' (Get-KanaAiValidationCanaryRomaji) 'romaji canary drifted'
    $kana = Get-KanaAiValidationCanaryKana
    Assert-Equal 4 $kana.Length 'kana canary length'
    $points = Get-KanaAiValidationCanaryKanaCodePoints
    Assert-Equal 4 $points.Count 'kana code point count'
    $rebuilt = ''
    foreach ($point in $points) { $rebuilt += [char][int]$point }
    Assert-Equal $kana $rebuilt 'kana canary does not match its declared code points'
}

Invoke-Test -Id 'ST-02' -Name 'canary maps entirely to known key tokens' -Body {
    $check = Test-KanaAiValidationCanaryKeyTokens
    Assert-True $check.Ok ('canary is not typable: ' + ($check.Missing -join ', '))
    Assert-Equal 6 $check.TokenCount 'six romaji keys make four kana; the token count must be six'
    Assert-Equal 'VK_K' $check.Tokens[0] 'first canary token'
    Assert-Equal 'VK_I' $check.Tokens[5] 'last canary token'
    Assert-Equal 4 (Get-KanaAiValidationCanaryKana).Length 'four kana'
}

Invoke-Test -Id 'ST-03' -Name 'an uppercase character is refused rather than silently mapped' -Body {
    $threw = $false
    try { [void](ConvertTo-KanaAiValidationKeyTokens -Text 'Kanaai') } catch { $threw = $true }
    Assert-True $threw 'an uppercase character must fail closed instead of inventing a shift chord'
}

# ---------------------------------------------------------------------------
# 2. Hashing, against published vectors
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-04' -Name 'SHA-256 matches the published vectors' -Body {
    Assert-Equal 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' (Get-KanaAiValidationTextSha256 -Text '') 'empty-string SHA-256'
    Assert-Equal 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' (Get-KanaAiValidationTextSha256 -Text 'abc') 'abc SHA-256'
    $empty = Join-Path $script:TempRoot 'empty.bin'
    [System.IO.File]::WriteAllBytes($empty, @())
    Assert-Equal 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' (Get-KanaAiValidationSha256 -Path $empty) 'empty-file SHA-256'
    $text = Join-Path $script:TempRoot 'abc.bin'
    [System.IO.File]::WriteAllText($text, 'abc', (New-Object System.Text.UTF8Encoding($false)))
    Assert-Equal 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' (Get-KanaAiValidationSha256 -Path $text) 'abc-file SHA-256'
}

Invoke-Test -Id 'ST-05' -Name 'hashing a missing file throws instead of returning an empty digest' -Body {
    $threw = $false
    try { [void](Get-KanaAiValidationSha256 -Path (Join-Path $script:TempRoot 'does-not-exist.bin')) } catch { $threw = $true }
    Assert-True $threw 'a missing file must not silently hash to something'
}

# ---------------------------------------------------------------------------
# 3. JSON
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-06' -Name 'a receipt survives a write and read round trip' -Body {
    $receipt = [ordered]@{
        schemaVersion = 1
        overall       = 'plan_only'
        steps         = @([ordered]@{ id = 'A-1'; verdict = 'not_run' }, [ordered]@{ id = 'A-2'; verdict = 'not_run' })
        nested        = [ordered]@{ flag = $true; count = 3; text = (Get-KanaAiValidationCanaryKana) }
    }
    $path = Join-Path $script:TempRoot 'roundtrip.json'
    [void](Write-KanaAiValidationJson -Path $path -Value $receipt)
    $bytes = [System.IO.File]::ReadAllBytes($path)
    Assert-Equal 123 $bytes[0] 'the receipt must be UTF-8 with no byte order mark, so it starts with the opening brace'
    Assert-True ($bytes[0] -ne 239) 'a byte order mark would make the receipt ambiguous on some readers'
    $read = Read-KanaAiValidationJson -Path $path
    Assert-Equal 'plan_only' (Get-KanaAiValidationStringProperty -Object $read -Name 'overall') 'overall did not survive the round trip'
    Assert-Equal 2 (@(Get-KanaAiValidationArrayProperty -Object $read -Name 'steps')).Count 'the step array lost an element'
    Assert-True (Test-KanaAiValidationHasProperty -Object $read -Name 'overall') 'HasProperty missed a present field'
    Assert-True (-not (Test-KanaAiValidationHasProperty -Object $read -Name 'notThere')) 'HasProperty invented a field'
}

Invoke-Test -Id 'ST-07' -Name 'a missing JSON file is an error, not an empty result' -Body {
    $threw = $false
    try { [void](Read-KanaAiValidationJson -Path (Join-Path $script:TempRoot 'nope.json')) } catch { $threw = $true }
    Assert-True $threw 'reading a missing plan must fail loudly'
}

Invoke-Test -Id 'ST-08' -Name 'absent and empty fields are distinguishable' -Body {
    $synthetic = [ordered]@{ present = '' }
    Assert-True (Test-KanaAiValidationHasProperty -Object $synthetic -Name 'present') 'an empty string field must count as present'
    $read = [ordered]@{ a = 1 }
    Assert-Equal 1 (Get-KanaAiValidationIntProperty -Object $read -Name 'a' -Default 9) 'ordered dictionary read failed'
    Assert-Equal 9 (Get-KanaAiValidationIntProperty -Object $read -Name 'b' -Default 9) 'default was not applied'
    Assert-Equal $null (Get-KanaAiValidationProperty -Object $read -Name 'b') 'absent field must read as null, not throw'
}

# ---------------------------------------------------------------------------
# 4. Plan validation
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-09' -Name 'the shipped plan validates' -Body {
    $plan = Read-KanaAiValidationJson -Path $planPath
    $validation = Test-KanaAiValidationPlan -Plan $plan
    if (-not $validation.Ok) { throw ('shipped plan is invalid: ' + ($validation.Errors -join ' | ')) }
    Assert-True ($validation.StepCount -ge 20) ('the shipped plan only has ' + $validation.StepCount + ' steps')
    Assert-Equal 0 $validation.Errors.Count 'the shipped plan reported errors'
}

Invoke-Test -Id 'ST-10' -Name 'the synthetic reference plan validates' -Body {
    $validation = Test-KanaAiValidationPlan -Plan (New-SyntheticPlan)
    if (-not $validation.Ok) { throw ('synthetic plan is invalid: ' + ($validation.Errors -join ' | ')) }
}

Invoke-Test -Id 'ST-11' -Name 'a duplicate step id is rejected' -Body {
    $plan = New-SyntheticPlan
    $allSteps = @(ConvertTo-KanaAiValidationArray $plan.steps)
    $duplicate = $allSteps[1] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $duplicate.id = 'S-01'
    $plan.steps = @((ConvertTo-KanaAiValidationArray $plan.steps)) + @($duplicate)
    $validation = Test-KanaAiValidationPlan -Plan $plan
    Assert-True (-not $validation.Ok) 'a duplicate id must fail validation'
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-STEP-ID-DUPLICATE') 'PLAN-STEP-ID-DUPLICATE was not reported'
}

Invoke-Test -Id 'ST-12' -Name 'an unknown action is rejected' -Body {
    $plan = New-SyntheticPlan
    $plan.steps[0].action = 'teleport-cursor'
    $validation = Test-KanaAiValidationPlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-STEP-ACTION-UNKNOWN') 'an unimplemented action must be rejected'
}

Invoke-Test -Id 'ST-13' -Name 'typing anything but the canary is rejected' -Body {
    $plan = New-SyntheticPlan
    $plan.steps[1].input.text = 'password123'
    $validation = Test-KanaAiValidationPlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-CANARY-TEXT-FORBIDDEN') 'a non-canary typed string must be rejected'
}

Invoke-Test -Id 'ST-14' -Name 'a plan with no injector loopback is rejected' -Body {
    $plan = New-SyntheticPlan
    $plan.steps = @(@(ConvertTo-KanaAiValidationArray $plan.steps) | Where-Object { $_.id -ne 'S-02' })
    $validation = Test-KanaAiValidationPlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-MISSING-LOOPBACK') 'a plan without a loopback must be rejected'
}

Invoke-Test -Id 'ST-15' -Name 'launching the target before the loopback is rejected' -Body {
    $plan = New-SyntheticPlan
    $launch = [pscustomobject]@{ id = 'S-00b'; phase = 'target'; action = 'launch-target'; assertion = 'assert'; direction = 'any'; readbackMethod = 'focus-readback'; expected = [pscustomobject]@{ observable = 'target-alive'; match = 'true' } }
    $allSteps = @(ConvertTo-KanaAiValidationArray $plan.steps)
    $plan.steps = @($allSteps[0], $launch) + @($allSteps[1..($allSteps.Count - 1)])
    $validation = Test-KanaAiValidationPlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-LOOPBACK-ORDER') 'the loopback must run before the first launch'
}

Invoke-Test -Id 'ST-16' -Name 'an ime-on step before any calibration is rejected' -Body {
    $plan = New-SyntheticPlan
    $ordered = @()
    foreach ($step in (ConvertTo-KanaAiValidationArray $plan.steps)) { if ($step.id -eq 'S-05') { $ordered += $step } }
    $ordered += @(@(ConvertTo-KanaAiValidationArray $plan.steps) | Where-Object { $_.id -ne 'S-05' })
    $plan.steps = $ordered
    $validation = Test-KanaAiValidationPlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-IMEON-WITHOUT-CALIBRATION') 'a direction-gated step must follow the calibration'
}

Invoke-Test -Id 'ST-17' -Name 'kana that disagrees with its declared code points is rejected' -Body {
    $plan = New-SyntheticPlan
    $plan.canary.kana = ([string](Get-KanaAiValidationCanaryKana)) + [char]0x3059
    $validation = Test-KanaAiValidationPlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-KANA-CODEPOINT-MISMATCH') 'a kana string that does not match its code points means the plan file was decoded with the wrong code page'
}

Invoke-Test -Id 'ST-18' -Name 'an unknown key token is rejected' -Body {
    $plan = New-SyntheticPlan
    $plan.steps[2].input.keys = @('VK_FUNCTION')
    $validation = Test-KanaAiValidationPlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-STEP-KEY-UNKNOWN') 'an unimplemented key token must be rejected'
}

Invoke-Test -Id 'ST-19' -Name 'a plan without the IME-off ASCII assertion is rejected' -Body {
    $plan = New-SyntheticPlan
    $plan.steps = @(@(ConvertTo-KanaAiValidationArray $plan.steps) | Where-Object { $_.id -ne 'S-04' })
    $validation = Test-KanaAiValidationPlan -Plan $plan
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-MISSING-IME-OFF-ASCII') 'the plan must keep both discriminating assertions'
    Assert-True ((Get-PlanErrorCodes -Validation $validation) -contains 'PLAN-CALIBRATION-INCOMPLETE') 'removing the calibration assertion must also be reported'
}

Invoke-Test -Id 'ST-20' -Name 'an unknown predicate and an unknown readback method are rejected' -Body {
    $plan = New-SyntheticPlan
    $plan.steps[2].expected.predicate = 'looks-about-right'
    $plan.steps[3].readbackMethod = 'ask-the-user'
    $validation = Test-KanaAiValidationPlan -Plan $plan
    $codes = Get-PlanErrorCodes -Validation $validation
    Assert-True ($codes -contains 'PLAN-STEP-PREDICATE-UNKNOWN') 'an unknown predicate must be rejected'
    Assert-True ($codes -contains 'PLAN-STEP-READBACK-UNKNOWN') 'an unknown readback method must be rejected'
}

# ---------------------------------------------------------------------------
# 5. The verdict rule. This is the regression test for the W1 defect.
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-21' -Name 'a readback that never arrived is delivery_unconfirmed even when the comparison says true' -Body {
    $verdict = Resolve-KanaAiValidationStepVerdict -Assertion 'assert' -Executed $true -ReadbackAvailable $false -Match $true
    Assert-Equal 'delivery_unconfirmed' $verdict 'without a readback nothing may pass'
}

Invoke-Test -Id 'ST-22' -Name 'a readback that disagrees with the plan is failed, never passed' -Body {
    $verdict = Resolve-KanaAiValidationStepVerdict -Assertion 'assert' -Executed $true -ReadbackAvailable $true -Match $false -Reason 'the document did not change'
    Assert-Equal 'failed' $verdict 'a mismatched readback must fail'
}

Invoke-Test -Id 'ST-23' -Name 'only an agreeing readback can pass' -Body {
    $verdict = Resolve-KanaAiValidationStepVerdict -Assertion 'assert' -Executed $true -ReadbackAvailable $true -Match $true
    Assert-Equal 'passed' $verdict 'an agreeing readback must pass'
}

Invoke-Test -Id 'ST-24' -Name 'a record-only step is never reported as passed' -Body {
    $verdict = Resolve-KanaAiValidationStepVerdict -Assertion 'record_only' -Executed $true -ReadbackAvailable $true -Match $true
    Assert-Equal 'record_only' $verdict 'an observation-only step must not claim a pass'
}

Invoke-Test -Id 'ST-25' -Name 'a blocked step and an unrun step are distinct from a pass' -Body {
    Assert-Equal 'blocked' (Resolve-KanaAiValidationStepVerdict -Assertion 'assert' -Executed $false -ReadbackAvailable $false -BlockedReason 'calibration missing') 'blocked'
    Assert-Equal 'not_run' (Resolve-KanaAiValidationStepVerdict -Assertion 'assert' -Executed $false -ReadbackAvailable $false) 'not_run'
}

Invoke-Test -Id 'ST-26' -Name 'a perfect injection API result plus a mismatched readback is a failure (the W1 defect)' -Body {
    # This is the exact shape of the W1 mistake: SendInput reported 2 events per
    # key and the operator-visible state never changed.
    $apiResult = [ordered]@{ token = 'VK_A'; requestedEvents = 2; sentEvents = 2; lastError = 0; apiOk = $true }
    $readback = Compare-KanaAiValidationReadback -Match 'contains' -Expected 'kanaai' -Observed '' -Available $true
    Assert-True $apiResult['apiOk'] 'the synthetic API result should look successful'
    Assert-Equal 'false' ([string]$readback.Match) 'the synthetic readback should not match'
    $verdict = Resolve-KanaAiValidationStepVerdict -Assertion 'assert' -Executed $true -ReadbackAvailable $true -Match ([bool]$readback.Match) -Reason $readback.Reason
    Assert-Equal 'failed' $verdict 'a successful API result must not turn a mismatched readback into a pass'
    # And the same API result with no readback at all must not pass either.
    $verdictNoReadback = Resolve-KanaAiValidationStepVerdict -Assertion 'assert' -Executed $true -ReadbackAvailable $false -Match $false
    Assert-Equal 'delivery_unconfirmed' $verdictNoReadback 'no readback means unconfirmed'
}

Invoke-Test -Id 'ST-27' -Name 'the verdict function has no parameter that could carry an API return value' -Body {
    $command = Get-Command -Name 'Resolve-KanaAiValidationStepVerdict'
    $names = @($command.Parameters.Keys)
    foreach ($forbidden in @('apiOk', 'sentEvents', 'requestedEvents', 'lastError', 'apiResult', 'returnCount')) {
        Assert-True ($names -notcontains $forbidden) ("the verdict function must not accept '$forbidden'")
    }
}

# ---------------------------------------------------------------------------
# 6. Readback comparison
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-28' -Name 'line-ending differences do not decide an equals comparison' -Body {
    $a = Compare-KanaAiValidationReadback -Match 'equals' -Expected "one`n" -Observed "one`r`n"
    Assert-True $a.Match 'CRLF and LF must compare equal'
    $b = Compare-KanaAiValidationReadback -Match 'equals' -Expected 'kanaai' -Observed 'kanaai '
    Assert-True (-not $b.Match) 'a trailing space is a real difference and must not be forgiven'
}

Invoke-Test -Id 'ST-29' -Name 'contains and not-contains behave symmetrically' -Body {
    Assert-True ((Compare-KanaAiValidationReadback -Match 'contains' -Expected 'ai' -Observed 'kanaai').Match) 'contains'
    Assert-True (-not ((Compare-KanaAiValidationReadback -Match 'contains' -Expected 'zz' -Observed 'kanaai').Match)) 'contains must fail when absent'
    Assert-True ((Compare-KanaAiValidationReadback -Match 'not-contains' -Expected 'zz' -Observed 'kanaai').Match) 'not-contains'
    Assert-True (-not ((Compare-KanaAiValidationReadback -Match 'not-contains' -Expected 'ai' -Observed 'kanaai').Match)) 'not-contains must fail when present'
}

Invoke-Test -Id 'ST-30' -Name 'an unavailable readback never compares true' -Body {
    foreach ($mode in @('equals', 'contains', 'not-contains', 'true', 'false', 'predicate')) {
        $comparison = Compare-KanaAiValidationReadback -Match $mode -Expected 'kanaai' -Observed $null -Available $false -Predicate 'kana-present'
        Assert-True (-not $comparison.Match) ("mode '$mode' reported a match for an unavailable readback")
        Assert-True ($comparison.Reason -like '*not available*') ("mode '$mode' did not explain itself")
    }
}

Invoke-Test -Id 'ST-31' -Name 'an unknown predicate fails closed' -Body {
    $comparison = Compare-KanaAiValidationReadback -Match 'predicate' -Expected '' -Observed 'kanaai' -Available $true -Predicate 'probably-fine'
    Assert-True (-not $comparison.Match) 'an unknown predicate must not produce a match'
    Assert-True ($comparison.Reason -like '*unknown predicate*') 'an unknown predicate must say so'
}

Invoke-Test -Id 'ST-32' -Name 'the kana and ascii predicates separate the two input directions' -Body {
    $kana = Get-KanaAiValidationCanaryKana
    Assert-True ((Test-KanaAiValidationPredicate -Name 'kana-present' -Text $kana).Result) 'kana must be detected'
    Assert-True (-not ((Test-KanaAiValidationPredicate -Name 'kana-present' -Text 'kanaai').Result)) 'ASCII romaji is not kana'
    Assert-True ((Test-KanaAiValidationPredicate -Name 'ascii-only' -Text 'kanaai').Result) 'ASCII must be detected'
    Assert-True (-not ((Test-KanaAiValidationPredicate -Name 'ascii-only' -Text $kana).Result)) 'kana is not ASCII'
    Assert-True (-not ((Test-KanaAiValidationPredicate -Name 'ascii-only' -Text '').Result)) 'empty text is not ASCII text'
    Assert-True ((Test-KanaAiValidationPredicate -Name 'non-empty' -Text 'x').Result) 'non-empty'
    Assert-True ((Test-KanaAiValidationPredicate -Name 'empty' -Text '').Result) 'empty'
    Assert-True (-not ((Test-KanaAiValidationPredicate -Name 'no-such-predicate' -Text 'x').Known)) 'an unknown predicate must report itself unknown'
}

# ---------------------------------------------------------------------------
# 7. Overall status
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-33' -Name 'overall status is the worst outcome in the run' -Body {
    $allPassed = @([pscustomobject]@{ verdict = 'passed' }, [pscustomobject]@{ verdict = 'record_only' })
    Assert-Equal 'passed' (Resolve-KanaAiValidationOverallStatus -Results $allPassed) 'all passed'
    $oneUnconfirmed = @([pscustomobject]@{ verdict = 'passed' }, [pscustomobject]@{ verdict = 'delivery_unconfirmed' })
    Assert-Equal 'unconfirmed' (Resolve-KanaAiValidationOverallStatus -Results $oneUnconfirmed) 'one unconfirmed'
    $oneFailed = @([pscustomobject]@{ verdict = 'delivery_unconfirmed' }, [pscustomobject]@{ verdict = 'failed' })
    Assert-Equal 'failed' (Resolve-KanaAiValidationOverallStatus -Results $oneFailed) 'a failure outranks an unconfirmed'
    $oneBlocked = @([pscustomobject]@{ verdict = 'passed' }, [pscustomobject]@{ verdict = 'blocked' })
    Assert-Equal 'incomplete' (Resolve-KanaAiValidationOverallStatus -Results $oneBlocked) 'one blocked'
    $withCritical = @([pscustomobject]@{ verdict = 'passed' })
    Assert-Equal 'unconfirmed' (Resolve-KanaAiValidationOverallStatus -Results $withCritical -CriticalFindings 1) 'a critical finding caps the run at unconfirmed'
    Assert-Equal 'incomplete' (Resolve-KanaAiValidationOverallStatus -Results @()) 'an empty result set is not a pass'
}

Invoke-Test -Id 'ST-34' -Name 'exit codes are stable and documented' -Body {
    Assert-Equal 0 (Get-KanaAiValidationExitCodeForStatus -Status 'passed') 'passed'
    Assert-Equal 0 (Get-KanaAiValidationExitCodeForStatus -Status 'plan_only') 'plan_only'
    Assert-Equal 0 (Get-KanaAiValidationExitCodeForStatus -Status 'self_test_passed') 'self_test_passed'
    Assert-Equal 1 (Get-KanaAiValidationExitCodeForStatus -Status 'failed') 'failed'
    Assert-Equal 2 (Get-KanaAiValidationExitCodeForStatus -Status 'unconfirmed') 'unconfirmed'
    Assert-Equal 3 (Get-KanaAiValidationExitCodeForStatus -Status 'incomplete') 'incomplete'
    Assert-Equal 4 (Get-KanaAiValidationExitCodeForStatus -Status 'anything-else') 'unknown'
}

# ---------------------------------------------------------------------------
# 8. Privacy
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-35' -Name 'text is withheld unless the recording policy allows it' -Body {
    $withheld = New-KanaAiValidationTextObservation -Text 'kanaai' -Available $true -RecordText $false -Method 'wm-gettext'
    Assert-True (-not $withheld['recorded']) 'the recording flag must be false'
    Assert-Equal $null $withheld['value'] 'withheld text must not be present'
    Assert-Equal 64 ([string]$withheld['sha256']).Length 'a withheld value still needs a digest'
    Assert-Equal 6 $withheld['length'] 'a withheld value still needs a length'
    $recorded = New-KanaAiValidationTextObservation -Text 'kanaai' -Available $true -RecordText $true -Method 'wm-gettext'
    Assert-True $recorded['recorded'] 'the recording flag must be true when allowed'
    Assert-Equal 'kanaai' $recorded['value'] 'recorded text must be present'
}

Invoke-Test -Id 'ST-36' -Name 'an unavailable readback is not an empty document' -Body {
    $observation = New-KanaAiValidationTextObservation -Text $null -Available $false -RecordText $true -Method 'wm-gettext'
    Assert-True (-not $observation['available']) 'an unavailable readback must stay unavailable'
    Assert-Equal $null $observation['nonEmpty'] 'an unavailable readback must not report an empty document'
}

Invoke-Test -Id 'ST-37' -Name 'the privacy scan rejects a planted environment variable' -Body {
    $planted = [ordered]@{ note = 'the run copied %KANAI_BUILD_TOKEN% into the receipt' }
    $json = $planted | ConvertTo-Json -Depth 10
    $sanity = Test-KanaAiValidationReceiptSanity -Json $json -AllowedTextValues @()
    Assert-True (-not $sanity.Ok) 'an environment variable reference must be rejected'
    Assert-True (($sanity.Problems -join ' ').ToLowerInvariant() -like '*forbidden pattern*') 'the reason should name the pattern'
}

Invoke-Test -Id 'ST-38' -Name 'the privacy scan rejects a forbidden key' -Body {
    $planted = [ordered]@{ harness = [ordered]@{ clipBoard = 'x' } }
    $json = $planted | ConvertTo-Json -Depth 10
    $sanity = Test-KanaAiValidationReceiptSanity -Json $json -AllowedTextValues @()
    Assert-True (-not $sanity.Ok) 'a forbidden receipt key must be rejected'
}

Invoke-Test -Id 'ST-39' -Name 'the privacy scan accepts a clean synthetic receipt' -Body {
    $clean = [ordered]@{
        schemaVersion = 1
        overall       = 'plan_only'
        desktopInteraction = [ordered]@{ performed = $false; keystrokesInjected = 0; statement = 'no desktop interaction in this mode' }
        steps         = @([ordered]@{ id = 'A-1'; verdict = 'not_run'; readback = (New-KanaAiValidationTextObservation -Text 'kanaai' -Available $true -RecordText $true -Method 'loopback') })
    }
    $json = $clean | ConvertTo-Json -Depth 20
    $sanity = Test-KanaAiValidationReceiptSanity -Json $json -AllowedTextValues @('kanaai', (Get-KanaAiValidationCanaryKana))
    if (-not $sanity.Ok) { throw ('a clean receipt was rejected: ' + ($sanity.Problems -join ' | ')) }
}

Invoke-Test -Id 'ST-40' -Name 'recorded text with no declared canary values is rejected' -Body {
    $clean = [ordered]@{
        steps = @([ordered]@{ readback = (New-KanaAiValidationTextObservation -Text 'kanaai' -Available $true -RecordText $true -Method 'loopback') })
    }
    $json = $clean | ConvertTo-Json -Depth 20
    $sanity = Test-KanaAiValidationReceiptSanity -Json $json -AllowedTextValues @()
    Assert-True (-not $sanity.Ok) 'recording text without a declared canary allow list must be rejected'
}

# ---------------------------------------------------------------------------
# 9. Cleanup
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-41' -Name 'cleanup plans terminate only what the harness launched' -Body {
    $ledger = [ordered]@{
        entries = @(
            [ordered]@{ kind = 'process'; id = 'probehost-1234'; identity = 'pid:1234|exe:C:\probe.exe' }
            [ordered]@{ kind = 'window'; id = 'probehost-loopback'; identity = 'class:KanaAIValidationLoopbackClass' }
        )
    }
    $live = [ordered]@{
        'probehost-1234'        = @{ present = $true }
        'probehost-loopback'    = @{ present = $true }
    }
    $first = Resolve-KanaAiValidationCleanupPlan -Ledger $ledger -LiveState $live
    Assert-Equal 2 $first.WillMutate 'both entries should act on the first pass'
    $second = Resolve-KanaAiValidationCleanupPlan -Ledger $ledger -LiveState $live
    Assert-Equal 2 $second.WillMutate 'planning is a pure function, so a repeated plan is identical'
    $already = Resolve-KanaAiValidationCleanupPlan -Ledger $ledger -LiveState ([ordered]@{ 'probehost-1234' = @{ present = $false }; 'probehost-loopback' = @{ present = $false } })
    Assert-Equal 0 $already.WillMutate 'a second pass after a clean first pass must mutate nothing'
    Assert-Equal 2 $already.AlreadyClean 'both entries should report already clean'
    $unknown = Resolve-KanaAiValidationCleanupPlan -Ledger $ledger -LiveState $live
    Assert-Equal 0 $unknown.UnresolvedKinds 'no ledger kind should be unhandled'
}

Invoke-Test -Id 'ST-42' -Name 'cleanup never acts on an entry the ledger does not contain' -Body {
    $ledger = [ordered]@{ entries = @() }
    $live = [ordered]@{ 'someone-elses-process' = @{ present = $true } }
    $plan = Resolve-KanaAiValidationCleanupPlan -Ledger $ledger -LiveState $live
    Assert-Equal 0 $plan.Actions.Count 'an empty ledger must produce no actions'
    Assert-Equal 0 $plan.WillMutate 'an empty ledger must not mutate anything'
}

Invoke-Test -Id 'ST-43' -Name 'an unknown ledger kind is reported instead of guessed at' -Body {
    $ledger = [ordered]@{ entries = @([ordered]@{ kind = 'registry-value'; id = 'x'; identity = 'y' }) }
    $plan = Resolve-KanaAiValidationCleanupPlan -Ledger $ledger -LiveState ([ordered]@{})
    Assert-Equal 1 $plan.UnresolvedKinds 'an unknown ledger kind must be surfaced'
    Assert-Equal 'unsupported-ledger-kind' $plan.Actions[0].action 'the action must be flagged'
}

Invoke-Test -Id 'ST-44' -Name 'the ledger records identity, not just a name' -Body {
    $ref = New-KanaAiValidationLedger -RunId 'r1' -Mode 'run'
    [void](Add-KanaAiValidationLedgerEntry -LedgerRef $ref -Kind 'process' -Id 'probehost-1' -Identity 'pid:1|startUtc:z|exe:e' -Note 'n')
    [void](Add-KanaAiValidationLedgerEntry -LedgerRef $ref -Kind 'window' -Id 'loopback' -Identity 'class:C' -Note 'n')
    $entries = Get-KanaAiValidationArrayProperty -Object $ref.Ledger -Name 'entries'
    Assert-Equal 2 $entries.Count 'ledger entry count'
    Assert-True ($entries[0].identity -like 'pid:*') 'a process entry must carry a verifiable identity'
}

# ---------------------------------------------------------------------------
# 10. Native wiring, by static source scan
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-45' -Name 'the shipped sources and the run script agree on the native surface' -Body {
    $wiring = Test-KanaAiValidationNativeWiring -NativeSourcePath $nativePath -ScriptPaths @((Join-Path $root 'Invoke-KanaAIDesktopValidation.ps1'), $commonPath)
    if (-not $wiring.Ok) { throw ('native wiring is broken: ' + ($wiring.Missing -join ' | ')) }
    Assert-True ($wiring.DeclaredMemberCount -gt 30) ('only ' + $wiring.DeclaredMemberCount + ' members were found in the native source')
    Assert-True ($wiring.CalledMembers.Count -ge 15) ('the run script only calls ' + $wiring.CalledMembers.Count + ' native members')
    Assert-True ($wiring.KeyTokenCount -ge 40) 'the key token map looks truncated'
}

Invoke-Test -Id 'ST-46' -Name 'a call to a member that does not exist is detected' -Body {
    $fakeScript = Join-Path $script:TempRoot 'fake-callers.ps1'
    $body = "[KanaAI.DesktopValidation.Native]::NotARealMember(1)`n[KanaAI.DesktopValidation.Native]::SendInput(1, 2, 3)`n"
    [System.IO.File]::WriteAllText($fakeScript, $body, (New-Object System.Text.UTF8Encoding($false)))
    $wiring = Test-KanaAiValidationNativeWiring -NativeSourcePath $nativePath -ScriptPaths @($fakeScript)
    Assert-True (-not $wiring.Ok) 'a call to a missing member must fail the wiring check'
    Assert-True (($wiring.Missing -join ' ') -like '*NotARealMember*') 'the missing member must be named'
}

Invoke-Test -Id 'ST-47' -Name 'a key token the native layer does not know is detected' -Body {
    $fakeNative = Join-Path $script:TempRoot 'fake-native.cs'
    $body = @'
namespace KanaAI.DesktopValidation {
  public static class Native {
    public static readonly string[] KeyTokenMap = new string[] { "VK_A" };
    public static uint SendInput(uint a, System.IntPtr[] b, int c) { return 0; }
  }
}
'@
    [System.IO.File]::WriteAllText($fakeNative, $body, (New-Object System.Text.UTF8Encoding($false)))
    $wiring = Test-KanaAiValidationNativeWiring -NativeSourcePath $fakeNative -ScriptPaths @()
    Assert-True (-not $wiring.Ok) 'a truncated key token map must fail the wiring check'
    Assert-True (($wiring.Missing -join ' ') -like '*VK_RETURN*') 'the tokens the canary needs must be named'
}

Invoke-Test -Id 'ST-48' -Name 'the canary text in the shipped plan is the documented canary' -Body {
    $plan = Read-KanaAiValidationJson -Path $planPath
    Assert-Equal (Get-KanaAiValidationCanaryRomaji) (Get-KanaAiValidationStringProperty -Object $plan.canary -Name 'romaji') 'plan romaji canary'
    Assert-Equal (Get-KanaAiValidationCanaryKana) (Get-KanaAiValidationStringProperty -Object $plan.canary -Name 'kana') 'plan kana canary survived the UTF-8 read'
}

# ---------------------------------------------------------------------------
# 11. Receipt shape
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-49' -Name 'a plan-only receipt has the required fields and claims no desktop interaction' -Body {
    $plan = Read-KanaAiValidationJson -Path $planPath
    $validation = Test-KanaAiValidationPlan -Plan $plan
    $wiring = Test-KanaAiValidationNativeWiring -NativeSourcePath $nativePath -ScriptPaths @((Join-Path $root 'Invoke-KanaAIDesktopValidation.ps1'), $commonPath)
    $receipt = [ordered]@{
        schemaVersion     = Get-KanaAiValidationSchemaVersion
        harness           = [ordered]@{ mode = 'plan-only'; runId = 'selftest'; planId = [string](Get-KanaAiValidationProperty -Object $plan -Name 'planId') }
        desktopInteraction = [ordered]@{ performed = $false; keystrokesInjected = 0; processesLaunched = 0; windowsCreated = 0; statement = 'no desktop interaction in this mode' }
        environmentStatic = [ordered]@{ powershellVersion = [string]$PSVersionTable.PSVersion }
        machineInspection = [ordered]@{ collected = $false; reason = 'not requested' }
        wiring            = [ordered]@{ ok = $wiring.Ok; missing = $wiring.Missing }
        planValidation    = [ordered]@{ ok = $validation.Ok; stepCount = $validation.StepCount; errors = $validation.Errors; warnings = $validation.Warnings }
        findings          = @()
        steps             = @()
        artifacts         = (New-SyntheticArtifact -Path $planPath)
        privacy           = [ordered]@{ canaryRomaji = (Get-KanaAiValidationCanaryRomaji); canaryKana = (Get-KanaAiValidationCanaryKana) }
        overall           = 'plan_only'
        exitCode          = Get-KanaAiValidationExitCodeForStatus -Status 'plan_only'
    }
    foreach ($field in @('schemaVersion', 'harness', 'desktopInteraction', 'environmentStatic', 'machineInspection', 'wiring', 'planValidation', 'findings', 'steps', 'artifacts', 'privacy', 'overall', 'exitCode')) {
        Assert-True (Test-KanaAiValidationHasProperty -Object $receipt -Name $field) ("the receipt is missing '$field'")
    }
    foreach ($artifact in @($receipt['artifacts'])) {
        Assert-True ($artifact.pathRelative -notmatch '\\Users\\') 'an artifact path must stay relative to the harness directory'
        Assert-Equal 64 ([string]$artifact.sha256).Length 'every artifact needs a SHA-256'
    }
    $path = Join-Path $script:TempRoot 'plan-only-receipt.json'
    [void](Write-KanaAiValidationJson -Path $path -Value $receipt)
    $read = Read-KanaAiValidationJson -Path $path
    Assert-Equal 'plan_only' (Get-KanaAiValidationStringProperty -Object $read -Name 'overall') 'overall'
    Assert-True (-not (Get-KanaAiValidationBoolProperty -Object $read.desktopInteraction -Name 'performed')) 'plan-only must claim no desktop interaction'
    Assert-Equal 0 $read.exitCode 'plan-only exits 0'
    $sanity = Test-KanaAiValidationReceiptSanity -Json ([System.IO.File]::ReadAllText($path)) -AllowedTextValues @()
    Assert-True $sanity.Ok ('the plan-only receipt failed the privacy scan: ' + ($sanity.Problems -join ' | '))
}

Invoke-Test -Id 'ST-50' -Name 'the file-name token helper never leaks a path' -Body {
    Assert-Equal 'abc-def' (ConvertTo-KanaAiValidationSafeFileToken -Text 'abc:def') 'a colon must become a dash'
    Assert-Equal 'empty' (ConvertTo-KanaAiValidationSafeFileToken -Text '') 'empty input'
    $long = ConvertTo-KanaAiValidationSafeFileToken -Text ('x' * 100)
    Assert-True ($long.Length -le 40) 'a long token must be truncated'
}

Invoke-Test -Id 'ST-52' -Name 'list conversion survives this host quirk (ST-52)' -Body {
    # On this Windows PowerShell build `@($listObject)` throws "Argument types do
    # not match" when the list element type is object. Every harness list goes
    # through ConvertTo-KanaAiValidationArray instead, so guard that path.
    $list = New-Object System.Collections.Generic.List[object]
    [void]$list.Add([pscustomobject]@{ id = 'a' })
    [void]$list.Add([pscustomobject]@{ id = 'b' })
    $asArray = @(ConvertTo-KanaAiValidationArray $list)
    Assert-Equal 2 $asArray.Count 'a two-element list must convert to a two-element array'
    Assert-Equal 'a' $asArray[0].id 'element order must survive'
    Assert-Equal 0 @(ConvertTo-KanaAiValidationArray $null).Count 'null converts to an empty array'
    Assert-Equal 1 @(ConvertTo-KanaAiValidationArray ([pscustomobject]@{ id = 'solo' })).Count 'a scalar stays one element'
    $fromProperty = Get-KanaAiValidationArrayProperty -Object ([pscustomobject]@{ items = $list }) -Name 'items'
    Assert-Equal 2 $fromProperty.Count 'Get-KanaAiValidationArrayProperty must handle a list value'
    $hashKeys = [ordered]@{ first = 1; second = 2 }
    Assert-Equal 2 @(ConvertTo-KanaAiValidationArray $hashKeys.Keys).Count 'ordered dictionary keys must convert'
}

Invoke-Test -Id 'ST-53' -Name 'property accessors tolerate a null object instead of crashing' -Body {
    # A missing registry key or an absent plan field must read as null, not as a
    # parameter binding failure. The live machine-inspection path depends on it.
    Assert-Equal $null (Get-KanaAiValidationProperty -Object $null -Name 'anything') 'property read of null'
    $emptyArray = @(Get-KanaAiValidationArrayProperty -Object $null -Name 'anything')
    Assert-Equal 0 $emptyArray.Count 'array read of null'
    Assert-Equal '' (Get-KanaAiValidationStringProperty -Object $null -Name 'anything') 'string read of null'
    Assert-True (Get-KanaAiValidationBoolProperty -Object $null -Name 'anything' -Default $true) 'bool read of null uses the default'
    Assert-Equal 7 (Get-KanaAiValidationIntProperty -Object $null -Name 'anything' -Default 7) 'int read of null uses the default'
    Assert-True (-not (Test-KanaAiValidationHasProperty -Object $null -Name 'anything')) 'presence check of null'
    $converted = @(ConvertTo-KanaAiValidationArray $emptyArray)
    Assert-Equal 0 $converted.Count 'null array through the converter'
}

# ---------------------------------------------------------------------------
# 12. The promise this file makes
# ---------------------------------------------------------------------------
Invoke-Test -Id 'ST-51' -Name 'this self test loaded no native code and touched no desktop' -Body {
    Assert-True ($null -eq ('KanaAI.DesktopValidation.Native' -as [type])) 'the native type must not be loaded by the self test'
    Assert-True ($null -eq ('KanaAIValidationProbeHost.ProbeHost' -as [type])) 'the probe host type must not be loaded by the self test'
    $loaded = @([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'WindowsBase' })
    Assert-True ($loaded.Count -eq 0) 'UI Automation assemblies must not be loaded by the self test'
    Assert-True ($null -eq (Get-Process -Name 'KanaAIValidationProbeHost' -ErrorAction SilentlyContinue)) 'no probe host process may exist'
}

# ---------------------------------------------------------------------------
try {
    $failed = @($script:TestResults.ToArray() | Where-Object { -not $_.ok })
    Write-Host ('self test: {0} case(s), {1} passed, {2} failed' -f $script:TestResults.Count, ($script:TestResults.Count - $failed.Count), $failed.Count)
    foreach ($result in $script:TestResults.ToArray()) {
        if (-not $result.ok) { Write-Host ('  FAIL {0} {1}: {2}' -f $result.id, $result.name, $result.detail) }
    }
    $reportPath = Join-Path $root 'runs\self-test-last.json'
    [void](Write-KanaAiValidationJson -Path $reportPath -Value ([ordered]@{
            schemaVersion  = Get-KanaAiValidationSchemaVersion
            completedAtUtc = Get-KanaAiValidationUtcNow
            caseCount      = $script:TestResults.Count
            failedCount    = $failed.Count
            cases          = @($script:TestResults.ToArray() | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; ok = $_.ok; detail = $_.detail } })
        }))
    Write-Host ('  report: {0}' -f (Join-Path 'runs' 'self-test-last.json'))
    exit $(if ($failed.Count -eq 0) { 0 } else { 1 })
}
finally {
    if (Test-Path -LiteralPath $script:TempRoot) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
