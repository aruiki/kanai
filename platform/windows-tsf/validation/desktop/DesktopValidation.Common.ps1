# KanaAI desktop validation harness - shared, side-effect-free helpers.
#
# Contract for this file (deliberate, and enforced by the self-test):
#   * Dot-sourcing must NOT touch a window station, a desktop, the registry, the
#     clipboard, the network, or any external process. Every function here is
#     in-process logic over values the caller already has.
#   * Windows PowerShell 5.1 is the guaranteed host. There is no Get-FileHash
#     guarantee in this environment, so SHA-256 uses System.Security.Cryptography.
#   * This file is ASCII-only on purpose. Windows PowerShell 5.1 decodes a
#     BOM-less script with the system ANSI code page, so a kana literal here
#     would be silently corrupted on a machine whose code page is not UTF-8.
#     All non-ASCII expectations live in the UTF-8 JSON plan and are validated
#     by code point (see Test-KanaAiValidationPlan / PLAN-KANA-CODEPOINT-MISMATCH).

Set-StrictMode -Version Latest

$script:KanaAiValidationSchemaVersion = 1

# ---------------------------------------------------------------------------
# Fixed, documented canary. This is the ONLY text the harness ever types.
# Romaji and ASCII forms are deliberately identical: the same injected bytes
# must produce kana with the IME active and ASCII with the IME inactive. That
# difference is the harness's primary discriminator between "the injection path
# is broken" and "the input processor is broken".
# ---------------------------------------------------------------------------
$script:KanaAiValidationCanaryRomaji = 'kanaai'
# U+304B U+306A U+3042 U+3044  ->  "kanaai" in hiragana (six romaji keys, four kana)
$script:KanaAiValidationCanaryKanaCodePoints = @(0x304B, 0x306A, 0x3042, 0x3044)

$script:KanaAiValidationKnownActions = @(
    'capture-preflight'
    'launch-target'
    'focus-target'
    'loopback-canary'
    'press-key'
    'type-text'
    'wait'
    'observe-candidates'
    'observe-processes'
    'observe-environment'
    'close-target'
    'cleanup'
)

$script:KanaAiValidationKnownObservables = @(
    'environment'
    'injector-loopback-text'
    'document-text'
    'document-kana'
    'document-ascii'
    'document-unchanged'
    'document-changed'
    'candidate-window'
    'process-list'
    'foreground-window'
    'target-alive'
    'none'
)

$script:KanaAiValidationKnownReadbackMethods = @(
    'static-capture'
    'native-preflight'
    'loopback-wm-gettext'
    'uia-text-pattern'
    'wm-gettext'
    'candidate-window-enumeration'
    'process-enumeration'
    'focus-readback'
    'target-state-file'
    'none'
)

# A step may be gated on the IME being in the "on" direction. The harness never
# assumes a starting IME state: it toggles, commits, toggles back and commits
# again, and lets the two results calibrate the direction. Steps that need the
# calibrated direction are blocked, never silently passed, when the calibration
# did not converge.
$script:KanaAiValidationKnownDirections = @('any', 'ime-on')

$script:KanaAiValidationKnownMatches = @('equals', 'contains', 'not-contains', 'predicate', 'true', 'false')

$script:KanaAiValidationKnownPredicates = @(
    'kana-present'
    'ascii-only'
    'non-empty'
    'empty'
    'candidate-window-present'
)

$script:KanaAiValidationKnownAssertions = @('assert', 'record_only')

# Virtual-key tokens the run script is allowed to name in a plan. The C# side
# owns the real mapping; this list exists so plan validation can reject typos in
# pure logic, and so Test-KanaAiValidationKeyTokenParity can prove the two
# lists agree without loading any native code.
$script:KanaAiValidationKnownKeyTokens = @(
    'VK_SHIFT', 'VK_CONTROL', 'VK_MENU', 'VK_SPACE', 'VK_RETURN', 'VK_ESCAPE',
    'VK_TAB', 'VK_BACK', 'VK_A', 'VK_B', 'VK_C', 'VK_D', 'VK_E', 'VK_F',
    'VK_G', 'VK_H', 'VK_I', 'VK_J', 'VK_K', 'VK_L', 'VK_M', 'VK_N', 'VK_O',
    'VK_P', 'VK_Q', 'VK_R', 'VK_S', 'VK_T', 'VK_U', 'VK_V', 'VK_W', 'VK_X',
    'VK_Y', 'VK_Z', 'VK_F6', 'VK_CAPITAL', 'VK_HANKAKU', 'VK_ZENKAKU',
    'VK_CONVERT', 'VK_NONCONVERT', 'VK_OEM_3'
)

# Exit codes. Documented in README.md; the coordinator maps these to a verdict.
$script:KanaAiValidationExitPassed = 0
$script:KanaAiValidationExitFailed = 1
$script:KanaAiValidationExitUnconfirmed = 2
$script:KanaAiValidationExitIncomplete = 3
$script:KanaAiValidationExitHarnessError = 4

function Get-KanaAiValidationSchemaVersion { return $script:KanaAiValidationSchemaVersion }

function Get-KanaAiValidationCanaryRomaji { return $script:KanaAiValidationCanaryRomaji }

function Get-KanaAiValidationCanaryKana {
    $builder = New-Object System.Text.StringBuilder
    foreach ($cp in $script:KanaAiValidationCanaryKanaCodePoints) {
        [void]$builder.Append([char][int]$cp)
    }
    return $builder.ToString()
}

function Get-KanaAiValidationCanaryKanaCodePoints {
    return @($script:KanaAiValidationCanaryKanaCodePoints)
}

function Get-KanaAiValidationKnownKeyTokens { return @($script:KanaAiValidationKnownKeyTokens) }

# Pure character to key-token mapping for the canary. The native injector owns
# the real virtual-key table; this exists so plan-only and the self-test can
# prove the canary is typable without loading any native code.
function ConvertTo-KanaAiValidationKeyTokens {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($character in $Text.ToCharArray()) {
        if (($character -ge 'a') -and ($character -le 'z')) {
            [void]$tokens.Add(('VK_' + ([string]$character).ToUpperInvariant()))
        }
        elseif ($character -eq ' ') {
            [void]$tokens.Add('VK_SPACE')
        }
        elseif (($character -eq "`r") -or ($character -eq "`n")) {
            [void]$tokens.Add('VK_RETURN')
        }
        else {
            # Fail closed. An uppercase letter would need a shift chord and a
            # character with no US-layout key would need KEYEVENTF_UNICODE;
            # neither is part of the canary, so neither is silently accepted.
            throw ("The canary contains a character with no unambiguous US-layout key token: U+{0:X4}" -f [int]$character)
        }
    }
    return $tokens.ToArray()
}

function Test-KanaAiValidationCanaryKeyTokens {
    $tokens = @(ConvertTo-KanaAiValidationKeyTokens -Text $script:KanaAiValidationCanaryRomaji)
    $missing = @($tokens | Where-Object { $script:KanaAiValidationKnownKeyTokens -notcontains $_ })
    return [pscustomobject]@{
        Ok         = ($missing.Count -eq 0)
        Tokens     = $tokens
        TokenCount = $tokens.Count
        Missing    = $missing
    }
}

function Get-KanaAiValidationExitCodeForStatus {
    param([Parameter(Mandatory = $true)][string]$Status)
    switch ($Status) {
        'passed' { return $script:KanaAiValidationExitPassed }
        'plan_only' { return $script:KanaAiValidationExitPassed }
        'self_test_passed' { return $script:KanaAiValidationExitPassed }
        'failed' { return $script:KanaAiValidationExitFailed }
        'unconfirmed' { return $script:KanaAiValidationExitUnconfirmed }
        'incomplete' { return $script:KanaAiValidationExitIncomplete }
        default { return $script:KanaAiValidationExitHarnessError }
    }
}

function Get-KanaAiValidationUtcNow { return [DateTime]::UtcNow.ToString('o') }

# ---------------------------------------------------------------------------
# Strict-mode-safe property access. Windows PowerShell 5.1 throws on a missing
# PSCustomObject property under Set-StrictMode -Version Latest, and plan files
# are data, so every read goes through here.
# ---------------------------------------------------------------------------
# Host quirk that shapes this whole file: on this Windows PowerShell build,
# `@($someListObject)` throws "Argument types do not match" when the list element
# type is object. Every list is therefore converted with ToArray() and every
# enumeration uses foreach, never an array subexpression. ST-52 guards this.
function ConvertTo-KanaAiValidationArray {
    <#
        .SYNOPSIS
        Turn any value into a real PowerShell array without tripping the
        `@($list)` bug described above.
        .DESCRIPTION
        The result is returned unrolled, which is what the pipeline expects, so
        callers that need a guaranteed array (for indexing, or for .Count) should
        wrap the call: @(ConvertTo-KanaAiValidationArray $value).
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        $copy = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$copy.Add($item) }
        return $copy.ToArray()
    }
    return @($Value)
}

function Get-KanaAiValidationProperty {
    <#
        .SYNOPSIS
        Read a named value from a PSCustomObject, a hashtable or an ordered
        dictionary, without throwing when the name is absent.
        .DESCRIPTION
        Hashtables and ordered dictionaries do not expose their keys through
        PSObject.Properties, so they need the IDictionary path. Everything in
        this harness passes one or the other, and "absent" must never be an
        error: a missing field in a plan is a validation finding, not a crash.
    #>
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        # hashtables in PowerShell are case-insensitive by default, but an
        # explicitly case-sensitive dictionary must still be tolerated.
        foreach ($key in $Object.Keys) {
            if (([string]$key) -eq $Name) { return $Object[$key] }
        }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-KanaAiValidationArrayProperty {
    <#
        .SYNOPSIS
        Read a field as an array.
        .DESCRIPTION
        The result is returned unrolled, which is what the pipeline expects, so
        an empty or absent field yields nothing at all. A caller that needs
        .Count or indexing must wrap the call in @(), exactly as with
        ConvertTo-KanaAiValidationArray.
    #>
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $value = Get-KanaAiValidationProperty -Object $Object -Name $Name
    return (ConvertTo-KanaAiValidationArray $value)
}

function Get-KanaAiValidationStringProperty {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ''
    )
    $value = Get-KanaAiValidationProperty -Object $Object -Name $Name
    if ($null -eq $value) { return $Default }
    if ($value -is [string]) { return $value }
    return [string]$value
}

function Get-KanaAiValidationBoolProperty {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Default = $false
    )
    $value = Get-KanaAiValidationProperty -Object $Object -Name $Name
    if ($null -eq $value) { return $Default }
    if ($value -is [bool]) { return $value }
    $text = [string]$value
    if ($text -ieq 'true') { return $true }
    if ($text -ieq 'false') { return $false }
    return $Default
}

function Get-KanaAiValidationIntProperty {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Default = 0
    )
    $value = Get-KanaAiValidationProperty -Object $Object -Name $Name
    if ($null -eq $value) { return $Default }
    try { return [int]$value } catch { return $Default }
}

function Test-KanaAiValidationHasProperty {
    <#
        .SYNOPSIS
        True when the field is present, even when its value is an empty string.
        .DESCRIPTION
        The plan uses "expected.value": "" to mean "the document must be empty",
        which is a real assertion. Distinguishing an absent field from an empty
        one is therefore not cosmetic.
    #>
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $true }
        foreach ($key in $Object.Keys) { if (([string]$key) -eq $Name) { return $true } }
        return $false
    }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

# ---------------------------------------------------------------------------
# Hashing. No Get-FileHash: this environment does not guarantee that cmdlet.
# ---------------------------------------------------------------------------
function Get-KanaAiValidationSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Cannot hash a missing file: $Path"
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $bytes = $sha.ComputeHash($stream)
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-KanaAiValidationTextSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ---------------------------------------------------------------------------
# JSON. ReadAllText/WriteAllText with an explicit UTF-8 codec: no BOM, and the
# plan's kana literals survive the round trip regardless of the console or
# system code page.
# ---------------------------------------------------------------------------
function Read-KanaAiValidationJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file is missing: $Path"
    }
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { throw "JSON file is empty: $Path" }
    return ($text | ConvertFrom-Json)
}

function Write-KanaAiValidationJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 30
    )
    $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $json = ($Value | ConvertTo-Json -Depth $Depth)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($Path), ($json + [System.Environment]::NewLine), $encoding)
    return [System.IO.Path]::GetFullPath($Path)
}

# ---------------------------------------------------------------------------
# Text comparison for readbacks.
# ---------------------------------------------------------------------------
function ConvertTo-KanaAiValidationNormalizedText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    $value = $Text -replace "`0", ''
    $value = $value -replace "`r`n", "`n"
    $value = $value -replace "`r", "`n"
    return $value
}

function Test-KanaAiValidationPredicate {
    <#
        .SYNOPSIS
        Evaluate a named predicate over an observed value.
        .DESCRIPTION
        An unknown predicate returns Known = $false. Callers MUST NOT treat an
        unknown predicate as a match; fail closed instead.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Text = $null,
        [AllowNull()]$BooleanObservation = $null
    )
    switch ($Name) {
        'non-empty' {
            return [pscustomobject]@{ Known = $true; Result = (-not [string]::IsNullOrEmpty($Text)); Reason = 'non-empty' }
        }
        'empty' {
            return [pscustomobject]@{ Known = $true; Result = [string]::IsNullOrEmpty($Text); Reason = 'empty' }
        }
        'kana-present' {
            $hiragana = [regex]::IsMatch([string]$Text, '[\u3041-\u309F]')
            $katakana = [regex]::IsMatch([string]$Text, '[\u30A1-\u30FF]')
            return [pscustomobject]@{
                Known   = $true
                Result  = ($hiragana -or $katakana)
                Reason  = ('hiragana={0};katakana={1}' -f $hiragana, $katakana)
            }
        }
        'contains-hiragana' {
            $hit = [regex]::IsMatch([string]$Text, '[\u3041-\u309F]')
            return [pscustomobject]@{ Known = $true; Result = $hit; Reason = 'hiragana' }
        }
        'contains-katakana' {
            $hit = [regex]::IsMatch([string]$Text, '[\u30A1-\u30FF]')
            return [pscustomobject]@{ Known = $true; Result = $hit; Reason = 'katakana' }
        }
        'ascii-only' {
            $text = [string]$Text
            $nonAscii = ([regex]::Matches($text, '[^\x00-\x7F]')).Count
            return [pscustomobject]@{
                Known  = $true
                Result = (($text.Length -gt 0) -and ($nonAscii -eq 0))
                Reason  = ('length={0};nonAsciiCount={1}' -f $text.Length, $nonAscii)
            }
        }
        'candidate-window-present' {
            $present = $false
            if ($null -ne $BooleanObservation) { $present = [bool]$BooleanObservation }
            return [pscustomobject]@{ Known = $true; Result = $present; Reason = 'candidateWindowPresent' }
        }
        default {
            return [pscustomobject]@{ Known = $false; Result = $false; Reason = ("unknown predicate '{0}'" -f $Name) }
        }
    }
}

function Compare-KanaAiValidationReadback {
    <#
        .SYNOPSIS
        Compare an independently observed value against the plan's expectation.
        .DESCRIPTION
        -Available is the honest signal. When the readback could not be obtained
        the comparison is a non-match with a reason, never a silent pass.
        This function knows nothing about any injection API return value; the API
        return value is recorded as metadata only and can never make a step pass.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Match,
        [AllowEmptyString()][string]$Expected = '',
        [AllowNull()][AllowEmptyString()][string]$Observed = $null,
        [bool]$Available = $true,
        [AllowNull()]$BooleanObservation = $null,
        [string]$Predicate = '',
        [switch]$Ordinal
    )
    if (-not $Available) {
        return [pscustomobject]@{ Match = $false; Reason = 'readback was not available; no observation exists'; MatchMode = $Match; NormalizedExpected = ''; NormalizedObserved = $null }
    }

    $expectedNorm = ConvertTo-KanaAiValidationNormalizedText -Text ([string]$Expected)
    $observedNorm = ConvertTo-KanaAiValidationNormalizedText -Text ([string]$Observed)

    switch ($Match) {
        'equals' {
            $same = if ($Ordinal) { [string]::Equals($expectedNorm, $observedNorm, [System.StringComparison]::Ordinal) }
                    else { $expectedNorm -ceq $observedNorm }
            $reason = if ($same) { 'equals' } else { ('expected length {0}, observed length {1}' -f $expectedNorm.Length, $observedNorm.Length) }
            return [pscustomobject]@{ Match = $same; Reason = $reason; MatchMode = $Match; NormalizedExpected = $expectedNorm; NormalizedObserved = $observedNorm }
        }
        'contains' {
            $hit = $observedNorm.Contains($expectedNorm)
            $reason = if ($hit) { 'contains' } else { 'expected substring not present in observation' }
            return [pscustomobject]@{ Match = $hit; Reason = $reason; MatchMode = $Match; NormalizedExpected = $expectedNorm; NormalizedObserved = $observedNorm }
        }
        'not-contains' {
            $hit = $observedNorm.Contains($expectedNorm)
            $reason = if (-not $hit) { 'substring absent as required' } else { 'forbidden substring present in observation' }
            return [pscustomobject]@{ Match = (-not $hit); Reason = $reason; MatchMode = $Match; NormalizedExpected = $expectedNorm; NormalizedObserved = $observedNorm }
        }
        'true' {
            $value = $false
            if ($null -ne $BooleanObservation) { $value = [bool]$BooleanObservation }
            else { $value = ($observedNorm -ieq 'true') }
            return [pscustomobject]@{ Match = $value; Reason = ('expected true, observed {0}' -f $observedNorm); MatchMode = $Match; NormalizedExpected = 'true'; NormalizedObserved = $observedNorm }
        }
        'false' {
            $value = $false
            if ($null -ne $BooleanObservation) { $value = (-not [bool]$BooleanObservation) }
            else { $value = ($observedNorm -ieq 'false') }
            return [pscustomobject]@{ Match = $value; Reason = ('expected false, observed {0}' -f $observedNorm); MatchMode = $Match; NormalizedExpected = 'false'; NormalizedObserved = $observedNorm }
        }
        'predicate' {
            $result = Test-KanaAiValidationPredicate -Name $Predicate -Text ([string]$Observed) -BooleanObservation $BooleanObservation
            if (-not $result.Known) {
                return [pscustomobject]@{ Match = $false; Reason = $result.Reason; MatchMode = $Match; NormalizedExpected = $Predicate; NormalizedObserved = $observedNorm }
            }
            return [pscustomobject]@{ Match = [bool]$result.Result; Reason = ('predicate {0}: {1}' -f $Predicate, $result.Reason); MatchMode = $Match; NormalizedExpected = $Predicate; NormalizedObserved = $observedNorm }
        }
        default {
            return [pscustomobject]@{ Match = $false; Reason = ("unsupported match mode '{0}'" -f $Match); MatchMode = $Match; NormalizedExpected = $expectedNorm; NormalizedObserved = $observedNorm }
        }
    }
}

# ---------------------------------------------------------------------------
# The verdict rule. This is the single place where a step becomes pass/fail.
# Note what is NOT a parameter: the SendInput return count. Delivery is decided
# only by an independent readback, so no API return value can promote a step.
# ---------------------------------------------------------------------------
function Resolve-KanaAiValidationStepVerdict {
    param(
        [string]$Assertion = 'assert',
        [bool]$Executed = $false,
        [bool]$ReadbackAvailable = $false,
        [bool]$Match = $false,
        [string]$BlockedReason = '',
        [string]$Reason = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($BlockedReason)) {
        return 'blocked'
    }
    if ($Assertion -eq 'record_only') {
        return 'record_only'
    }
    if (-not $Executed) {
        return 'not_run'
    }
    if (-not $ReadbackAvailable) {
        return 'delivery_unconfirmed'
    }
    if ($Match) {
        return 'passed'
    }
    if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = 'readback did not match the planned expectation' }
    return 'failed'
}

function Resolve-KanaAiValidationOverallStatus {
    param(
        [Parameter(Mandatory = $true)]$Results,
        [string]$Mode = 'run',
        [int]$CriticalFindings = 0
    )
    if ($Mode -eq 'plan-only') { return 'plan_only' }
    if ($Mode -eq 'self-test') { return 'self_test_passed' }

    $verdicts = @()
    foreach ($result in @($Results)) {
        $verdicts += [string](Get-KanaAiValidationProperty -Object $result -Name 'verdict')
    }
    if ($verdicts.Count -eq 0) { return 'incomplete' }
    if ($verdicts -contains 'failed') { return 'failed' }
    if (($verdicts -contains 'blocked') -or ($verdicts -contains 'not_run')) { return 'incomplete' }
    if ($CriticalFindings -gt 0) { return 'unconfirmed' }
    if ($verdicts -contains 'delivery_unconfirmed') { return 'unconfirmed' }
    return 'passed'
}

# ---------------------------------------------------------------------------
# Receipt text observations. Privacy invariant: the harness records document
# text only for a harness-owned target, or when the operator explicitly allowed
# external text capture. Otherwise it records a hash and a length only.
# ---------------------------------------------------------------------------
function New-KanaAiValidationTextObservation {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text = $null,
        [bool]$Available = $true,
        [bool]$RecordText = $false,
        [string]$Method = ''
    )
    if (-not $Available -or $null -eq $Text) {
        return [ordered]@{
            method     = $Method
            available  = $false
            recorded   = $false
            reason     = 'readback unavailable'
            value      = $null
            sha256     = $null
            length     = $null
            nonEmpty   = $null
        }
    }
    $normalized = ConvertTo-KanaAiValidationNormalizedText -Text $Text
    $observation = [ordered]@{
        method    = $Method
        available = $true
        recorded  = $RecordText
        value     = $(if ($RecordText) { $normalized } else { $null })
        sha256    = Get-KanaAiValidationTextSha256 -Text $normalized
        length    = $normalized.Length
        nonEmpty  = (-not [string]::IsNullOrEmpty($normalized))
        reason    = $(if ($RecordText) { 'text recorded under an explicit recording policy' } else { 'text withheld by recording policy; hash and length only' })
    }
    return $observation
}

# ---------------------------------------------------------------------------
# Plan validation. Pure: it reads the plan object and nothing else.
# ---------------------------------------------------------------------------
function Test-KanaAiValidationPlan {
    param([Parameter(Mandatory = $true)]$Plan)

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $checks = New-Object System.Collections.Generic.List[string]
    $addError = { param($c, $m) $errors.Add(('{0}: {1}' -f $c, $m)) }
    $addWarning = { param($c, $m) $warnings.Add(('{0}: {1}' -f $c, $m)) }
    $addCheck = { param($m) $checks.Add($m) }

    $schema = Get-KanaAiValidationIntProperty -Object $Plan -Name 'schemaVersion' -Default -1
    if ($schema -ne $script:KanaAiValidationSchemaVersion) {
        & $addError 'PLAN-SCHEMA' ("schemaVersion is {0}, expected {1}" -f $schema, $script:KanaAiValidationSchemaVersion)
    }
    else { & $addCheck 'schemaVersion' }

    $planId = Get-KanaAiValidationStringProperty -Object $Plan -Name 'planId'
    if ([string]::IsNullOrWhiteSpace($planId)) { & $addError 'PLAN-ID-MISSING' 'planId is empty' } else { & $addCheck 'planId' }

    $canary = Get-KanaAiValidationProperty -Object $Plan -Name 'canary'
    $canaryRomaji = Get-KanaAiValidationStringProperty -Object $canary -Name 'romaji'
    $canaryKana = Get-KanaAiValidationStringProperty -Object $canary -Name 'kana'
    if ([string]::IsNullOrWhiteSpace($canaryRomaji)) {
        & $addError 'PLAN-CANARY-ROMAJI' 'canary.romaji is empty'
    }
    elseif ($canaryRomaji -ne $script:KanaAiValidationCanaryRomaji) {
        & $addWarning 'PLAN-CANARY-DRIFT' ("canary.romaji '{0}' differs from the harness constant '{1}'" -f $canaryRomaji, $script:KanaAiValidationCanaryRomaji)
    }
    else { & $addCheck 'canary.romaji' }

    $declaredPoints = Get-KanaAiValidationArrayProperty -Object $canary -Name 'kanaCodePoints'
    if ($declaredPoints.Count -gt 0) {
        $rebuilt = New-Object System.Text.StringBuilder
        foreach ($point in $declaredPoints) {
            $value = [int]$point
            if ($value -lt 0 -or $value -gt 0x10FFFF) {
                & $addError 'PLAN-KANA-CODEPOINT-RANGE' ("canary.kanaCodePoints contains an out-of-range value {0}" -f $value)
                break
            }
            [void]$rebuilt.Append([char]$value)
        }
        if ($errors.Count -eq 0 -or $rebuilt.Length -gt 0) {
            if ([string]::IsNullOrWhiteSpace($canaryKana)) {
                & $addError 'PLAN-CANARY-KANA' 'canary.kana is empty'
            }
            elseif ($rebuilt.ToString() -cne $canaryKana) {
                & $addError 'PLAN-KANA-CODEPOINT-MISMATCH' ("canary.kana does not match canary.kanaCodePoints; the file was probably decoded with the wrong code page")
            }
            else { & $addCheck 'canary.kana code points' }
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($canaryKana)) {
        & $addError 'PLAN-CANARY-KANA' 'canary.kana is empty and no code points are declared'
    }

    $steps = @(ConvertTo-KanaAiValidationArray (Get-KanaAiValidationProperty -Object $Plan -Name 'steps'))
    if ($steps.Count -eq 0) {
        & $addError 'PLAN-NO-STEPS' 'the plan declares no steps'
        return [pscustomobject]@{ Ok = $false; StepCount = 0; Errors = $errors.ToArray(); Warnings = $warnings.ToArray(); Checks = $checks.ToArray() }
    }

    $seenIds = @{}
    $imeOnKanaSeen = $false
    $imeOffAsciiSeen = $false
    $candidateStepSeen = $false
    $firstLoopbackIndex = -1
    $firstLaunchIndex = -1
    $calibrationKanaIndex = -1
    $calibrationAsciiIndex = -1
    $firstImeOnStepIndex = -1
    $imeOnSetupSeen = $false
    $selfReportStepSeen = $false

    for ($index = 0; $index -lt $steps.Count; $index++) {
        $step = $steps[$index]
        $id = Get-KanaAiValidationStringProperty -Object $step -Name 'id'
        $action = Get-KanaAiValidationStringProperty -Object $step -Name 'action'
        $assertion = Get-KanaAiValidationStringProperty -Object $step -Name 'assertion' -Default 'assert'
        $expected = Get-KanaAiValidationProperty -Object $step -Name 'expected'
        $observable = Get-KanaAiValidationStringProperty -Object $expected -Name 'observable'
        $match = Get-KanaAiValidationStringProperty -Object $expected -Name 'match'
        $predicate = Get-KanaAiValidationStringProperty -Object $expected -Name 'predicate'
        $expectedValue = Get-KanaAiValidationStringProperty -Object $expected -Name 'value'
        $readbackMethod = Get-KanaAiValidationStringProperty -Object $step -Name 'readbackMethod'
        $direction = Get-KanaAiValidationStringProperty -Object $step -Name 'direction' -Default 'any'
        $calibrates = Get-KanaAiValidationBoolProperty -Object $step -Name 'calibratesDirection' -Default $false
        $imeSetup = Get-KanaAiValidationProperty -Object $step -Name 'imeSetup'

        if ([string]::IsNullOrWhiteSpace($id)) {
            & $addError 'PLAN-STEP-ID-MISSING' ("steps[{0}] has no id" -f $index)
            continue
        }
        if ($seenIds.ContainsKey($id)) {
            & $addError 'PLAN-STEP-ID-DUPLICATE' ("step id '{0}' appears more than once" -f $id)
        }
        else { $seenIds[$id] = $true }

        if ($script:KanaAiValidationKnownActions -notcontains $action) {
            & $addError 'PLAN-STEP-ACTION-UNKNOWN' ("step '{0}' has action '{1}' which the harness does not implement" -f $id, $action)
        }
        if ($script:KanaAiValidationKnownAssertions -notcontains $assertion) {
            & $addError 'PLAN-STEP-ASSERTION-UNKNOWN' ("step '{0}' has assertion '{1}'" -f $id, $assertion)
        }
        if ($script:KanaAiValidationKnownObservables -notcontains $observable) {
            & $addError 'PLAN-STEP-OBSERVABLE-UNKNOWN' ("step '{0}' expects observable '{1}' which the harness does not implement" -f $id, $observable)
        }
        if ($script:KanaAiValidationKnownReadbackMethods -notcontains $readbackMethod) {
            & $addError 'PLAN-STEP-READBACK-UNKNOWN' ("step '{0}' names readback method '{1}' which the harness does not implement" -f $id, $readbackMethod)
        }
        if ($script:KanaAiValidationKnownMatches -notcontains $match) {
            & $addError 'PLAN-STEP-MATCH-UNKNOWN' ("step '{0}' has match '{1}'" -f $id, $match)
        }
        if ($script:KanaAiValidationKnownDirections -notcontains $direction) {
            & $addError 'PLAN-STEP-DIRECTION-UNKNOWN' ("step '{0}' has direction '{1}'" -f $id, $direction)
        }
        if (($match -eq 'equals') -or ($match -eq 'contains') -or ($match -eq 'not-contains')) {
            if ($assertion -eq 'assert' -and (-not (Test-KanaAiValidationHasProperty -Object $expected -Name 'value'))) {
                & $addError 'PLAN-STEP-EXPECTED-VALUE-MISSING' ("step '{0}' uses match '{1}' but declares no expected value field" -f $id, $match)
            }
            elseif (($match -ne 'equals') -and ($assertion -eq 'assert') -and [string]::IsNullOrEmpty($expectedValue)) {
                & $addWarning 'PLAN-STEP-DEGENERATE-MATCH' ("step '{0}' uses match '{1}' with an empty expected value, which every observation satisfies" -f $id, $match)
            }
        }
        if ($match -eq 'predicate') {
            if ($script:KanaAiValidationKnownPredicates -notcontains $predicate) {
                & $addError 'PLAN-STEP-PREDICATE-UNKNOWN' ("step '{0}' names predicate '{1}'" -f $id, $predicate)
            }
        }

        $input = Get-KanaAiValidationProperty -Object $step -Name 'input'
        if ($null -ne $input) {
            $keys = Get-KanaAiValidationArrayProperty -Object $input -Name 'keys'
            foreach ($key in $keys) {
                if ($script:KanaAiValidationKnownKeyTokens -notcontains [string]$key) {
                    & $addError 'PLAN-STEP-KEY-UNKNOWN' ("step '{0}' names key token '{1}' which the native injector does not implement" -f $id, $key)
                }
            }
            # Only a step that actually declares typed text is subject to the
            # canary rule. A press-key step has keys and no text, and "" is not
            # an attempt to type the empty string.
            if (Test-KanaAiValidationHasProperty -Object $input -Name 'text') {
                $text = Get-KanaAiValidationStringProperty -Object $input -Name 'text'
                if ($text -ne $script:KanaAiValidationCanaryRomaji) {
                    & $addError 'PLAN-CANARY-TEXT-FORBIDDEN' ("step '{0}' would type '{1}'; the harness may only type the documented canary '{2}'" -f $id, $text, $script:KanaAiValidationCanaryRomaji)
                }
            }
        }

        # The two discriminating assertions. Without both, the receipt cannot
        # separate a broken injector from a broken input processor, which is
        # exactly the defect that made W1 unreadable.
        $isKanaAssertion = ($observable -eq 'document-kana') -and ($assertion -eq 'assert') -and ($match -eq 'predicate') -and ($predicate -eq 'kana-present')
        $isAsciiAssertion = ($observable -eq 'document-ascii') -and ($assertion -eq 'assert') -and ($match -eq 'equals') -and ($expectedValue -ceq $script:KanaAiValidationCanaryRomaji)
        if ($isKanaAssertion) { $imeOnKanaSeen = $true }
        if ($isAsciiAssertion) { $imeOffAsciiSeen = $true }
        if ($observable -eq 'candidate-window') { $candidateStepSeen = $true }
        if ($readbackMethod -eq 'target-state-file') { $selfReportStepSeen = $true }

        if ($calibrates) {
            if ($isKanaAssertion) { $calibrationKanaIndex = $index }
            if ($isAsciiAssertion) { $calibrationAsciiIndex = $index }
        }
        if ($action -eq 'loopback-canary') { if ($firstLoopbackIndex -lt 0) { $firstLoopbackIndex = $index } }
        if ($action -eq 'launch-target') { if ($firstLaunchIndex -lt 0) { $firstLaunchIndex = $index } }
        if ($direction -eq 'ime-on') {
            if ($firstImeOnStepIndex -lt 0) { $firstImeOnStepIndex = $index }
            if ($null -ne $imeSetup) {
                $targetState = Get-KanaAiValidationStringProperty -Object $imeSetup -Name 'targetState'
                if ($targetState -eq 'on') { $imeOnSetupSeen = $true }
                else { & $addError 'PLAN-IME-SETUP-UNKNOWN' ("step '{0}' declares imeSetup.targetState '{1}'" -f $id, $targetState) }
            }
        }
    }

    if (-not $imeOnKanaSeen) {
        & $addError 'PLAN-MISSING-IME-ON-KANA' 'the plan must assert that a committed canary is read back as kana; otherwise an unconfirmed input result is ambiguous'
    }
    if (-not $imeOffAsciiSeen) {
        & $addError 'PLAN-MISSING-IME-OFF-ASCII' ("the plan must assert that a committed canary is read back as exactly '{0}' while the input processor is inactive" -f $script:KanaAiValidationCanaryRomaji)
    }
    if (-not $candidateStepSeen) {
        & $addWarning 'PLAN-NO-CANDIDATE-STEP' 'the plan never observes a candidate window; conversion display would stay unverified'
    }
    if (-not $selfReportStepSeen) {
        & $addWarning 'PLAN-NO-SELF-REPORT-STEP' 'the plan has no step that reads the target own account of itself; the strongest independent readback would go unused'
    }
    if ($firstLoopbackIndex -lt 0) {
        & $addError 'PLAN-MISSING-LOOPBACK' 'the plan has no injector loopback step; without it a delivery failure cannot be attributed'
    }
    elseif (($firstLaunchIndex -ge 0) -and ($firstLaunchIndex -lt $firstLoopbackIndex)) {
        & $addError 'PLAN-LOOPBACK-ORDER' 'the injector loopback must run before the first launch-target step'
    }
    if (($calibrationKanaIndex -lt 0) -or ($calibrationAsciiIndex -lt 0)) {
        & $addError 'PLAN-CALIBRATION-INCOMPLETE' 'the plan must calibrate the IME direction with one committed kana assertion and one committed ASCII assertion, both marked calibratesDirection'
    }
    if ($firstImeOnStepIndex -ge 0) {
        $latestCalibration = [Math]::Max($calibrationKanaIndex, $calibrationAsciiIndex)
        if ($latestCalibration -lt 0) {
            & $addError 'PLAN-IMEON-WITHOUT-CALIBRATION' "a step needs direction 'ime-on' but no calibration step precedes it"
        }
        elseif ($firstImeOnStepIndex -lt $latestCalibration) {
            & $addError 'PLAN-IMEON-WITHOUT-CALIBRATION' "a step needs direction 'ime-on' but runs before the calibration that determines that direction"
        }
        if (-not $imeOnSetupSeen) {
            & $addError 'PLAN-IME-ON-SETUP-MISSING' "a step needs direction 'ime-on' but no step declares imeSetup.targetState 'on'"
        }
    }

    $ok = $errors.Count -eq 0
    return [pscustomobject]@{
        Ok        = $ok
        StepCount = $steps.Count
        Errors    = $errors.ToArray()
        Warnings  = $warnings.ToArray()
        Checks    = $checks.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Native wiring checks, performed by reading the C# source as text. No compile,
# no load, no process: this is why -PlanOnly can prove the run script and the
# native layer agree without touching anything.
# ---------------------------------------------------------------------------
function Get-KanaAiValidationNativeSymbols {
    <#
        .SYNOPSIS
        Read the exported P/Invoke and method names out of the C# source.
    #>
    param([Parameter(Mandatory = $true)][string]$NativeSourcePath)
    if (-not (Test-Path -LiteralPath $NativeSourcePath -PathType Leaf)) {
        throw "Native source is missing: $NativeSourcePath"
    }
    $text = [System.IO.File]::ReadAllText($NativeSourcePath)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($text, '\[DllImport\(\s*"([^"]+)"[^\]]*\)\]\s*(?:\[[^\]]*\]\s*)*(?:public|internal)\s+static\s+extern\s+[A-Za-z0-9_<>\[\]\.]+\s+([A-Za-z0-9_]+)\s*\(')) {
        [void]$names.Add($match.Groups[2].Value)
    }
    foreach ($match in [regex]::Matches($text, 'public\s+static\s+[A-Za-z0-9_<>\[\]\.]+\s+([A-Za-z0-9_]+)\s*\(')) {
        [void]$names.Add($match.Groups[1].Value)
    }
    return ($names.ToArray() | Select-Object -Unique)
}

function Test-KanaAiValidationNativeWiring {
    <#
        .SYNOPSIS
        Prove that every native member the run script calls is declared in the
        C# source, and that the key-token list on both sides agrees.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$NativeSourcePath,
        [AllowEmptyCollection()][string[]]$ScriptPaths = @()
    )
    $declared = Get-KanaAiValidationNativeSymbols -NativeSourcePath $NativeSourcePath
    $missing = New-Object System.Collections.Generic.List[string]
    $called = New-Object System.Collections.Generic.List[string]

    foreach ($scriptPath in $ScriptPaths) {
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            [void]$missing.Add(('script file is missing: {0}' -f $scriptPath))
            continue
        }
        $text = [System.IO.File]::ReadAllText($scriptPath)
        foreach ($match in [regex]::Matches($text, '\[KanaAI\.DesktopValidation\.Native\]::([A-Za-z0-9_]+)')) {
            $member = $match.Groups[1].Value
            [void]$called.Add($member)
            if ($declared -notcontains $member) {
                [void]$missing.Add(("'{0}' calls Native::{1}, which is not declared in {2}" -f (Split-Path -Leaf $scriptPath), $member, (Split-Path -Leaf $NativeSourcePath)))
            }
        }
    }

    # Key-token parity: the pure plan validator and the native injector must know
    # the same token set, otherwise a plan could validate and then fail to run.
    $tokenBlock = [regex]::Match([System.IO.File]::ReadAllText($NativeSourcePath), 'KeyTokenMap\s*=\s*new\s+string\[\]\s*\{(?<body>[^}]*)\}')
    $nativeTokens = @()
    if ($tokenBlock.Success) {
        foreach ($match in [regex]::Matches($tokenBlock.Groups['body'].Value, '"([A-Z0-9_]+)"')) {
            $nativeTokens += $match.Groups[1].Value
        }
    }
    else {
        [void]$missing.Add('the native source does not declare a KeyTokenMap array, so key-token parity cannot be checked')
    }
    $scriptTokens = @($script:KanaAiValidationKnownKeyTokens)
    $onlyInScript = @($scriptTokens | Where-Object { $nativeTokens -notcontains $_ })
    $onlyInNative = @($nativeTokens | Where-Object { $scriptTokens -notcontains $_ })
    foreach ($token in $onlyInScript) { [void]$missing.Add(('key token {0} is accepted by the plan validator but is not in the native KeyTokenMap' -f $token)) }
    foreach ($token in $onlyInNative) { [void]$missing.Add(('key token {0} is in the native KeyTokenMap but is rejected by the plan validator' -f $token)) }

    # The canary must be typable with the tokens the native injector knows.
    $canaryCheck = Test-KanaAiValidationCanaryKeyTokens
    if (-not $canaryCheck.Ok) {
        foreach ($token in $canaryCheck.Missing) {
            [void]$missing.Add(('the canary needs key token {0}, which the native injector does not implement' -f $token))
        }
    }
    foreach ($token in $canaryCheck.Tokens) {
        if ($nativeTokens -notcontains $token) {
            [void]$missing.Add(('the canary needs key token {0}, which is not in the native KeyTokenMap' -f $token))
        }
    }

    return [pscustomobject]@{
        Ok                  = ($missing.Count -eq 0)
        Missing             = $missing.ToArray()
        CalledMembers       = ($called.ToArray() | Select-Object -Unique)
        DeclaredMemberCount = @($declared).Count
        KeyTokenCount       = $nativeTokens.Count
        CanaryTokens        = $canaryCheck.Tokens
    }
}

# ---------------------------------------------------------------------------
# Receipt sanity. Two invariants:
#   1. No environment variable, clipboard content, credential, or user-document
#      path may appear in the receipt.
#   2. Any recorded document text must be canary-only. A text that the operator
#      did not explicitly consent to capture must appear as a hash only.
# ---------------------------------------------------------------------------
$script:KanaAiValidationForbiddenReceiptKeys = @(
    'env', 'envvar', 'envvars', 'env_vars', 'environmentvariables', 'environmentvariable',
    'clipboard', 'password', 'passwd', 'secret', 'token', 'accesstoken', 'apikey', 'api_key',
    'credential', 'credentials', 'userprofile', 'homedir', 'appdata', 'documents',
    'mydocuments', 'recentfiles', 'typedtext', 'keystrokes'
)

$script:KanaAiValidationForbiddenReceiptValuePatterns = @(
    '(?i)%[A-Za-z_][A-Za-z0-9_]*%',
    '(?i)\b[A-Za-z_][A-Za-z0-9_]*TOKEN\b',
    '(?i)\bBearer\s+[A-Za-z0-9._\-]+',
    '(?i)\\Users\\[^\\]+\\Documents\\',
    '(?i)\\AppData\\',
    '(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

function Test-KanaAiValidationReceiptSanity {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [string[]]$AllowedTextValues = @()
    )
    $problems = New-Object System.Collections.Generic.List[string]

    $parsed = $null
    try { $parsed = $Json | ConvertFrom-Json }
    catch { [void]$problems.Add(('the receipt is not valid JSON: ' + $_.Exception.Message)) }
    if ($null -eq $parsed) {
        return [pscustomobject]@{ Ok = $false; Problems = $problems.ToArray() }
    }

    # Walk the whole tree. A forbidden key nested three levels down is just as
    # much of a leak as one at the top.
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($parsed, '$'))
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $node = $item[0]
        $path = $item[1]
        if ($node -is [System.Collections.IDictionary]) {
            foreach ($key in @($node.Keys)) {
                $name = [string]$key
                $childPath = $path + '.' + $name
                if ($script:KanaAiValidationForbiddenReceiptKeys -contains $name.ToLowerInvariant()) {
                    [void]$problems.Add(("forbidden receipt key '{0}' at {1}" -f $name, $childPath))
                }
                $stack.Push(@($node[$key], $childPath))
            }
            continue
        }
        if (($node -is [string]) -or ($node -is [System.Collections.IEnumerable]) -or ($null -eq $node)) { continue }
        foreach ($property in $node.PSObject.Properties) {
            $childPath = $path + '.' + $property.Name
            if ($script:KanaAiValidationForbiddenReceiptKeys -contains $property.Name.ToLowerInvariant()) {
                [void]$problems.Add(("forbidden receipt key '{0}' at {1}" -f $property.Name, $childPath))
            }
            $stack.Push(@($property.Value, $childPath))
        }
    }

    foreach ($pattern in $script:KanaAiValidationForbiddenReceiptValuePatterns) {
        if ([regex]::IsMatch($Json, $pattern)) {
            [void]$problems.Add(("the receipt text matches a forbidden pattern: {0}" -f $pattern))
        }
    }

    $allowed = @($AllowedTextValues | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($allowed.Count -eq 0 -and [regex]::IsMatch($Json, '"recorded"\s*:\s*true')) {
        [void]$problems.Add('the receipt contains a recorded text observation but the run declared no canary-only text values, so recording it was not permitted')
    }

    return [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = $problems.ToArray() }
}

# ---------------------------------------------------------------------------
# Cleanup planning. Pure: it takes a ledger of everything the harness created
# plus a snapshot of the live state, and returns the actions a run should take.
# Idempotency is a property of this function, so the self-test can prove it
# without starting or stopping any process.
# ---------------------------------------------------------------------------
function Resolve-KanaAiValidationCleanupPlan {
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)]$LiveState
    )
    $actions = New-Object System.Collections.Generic.List[object]

    $entries = Get-KanaAiValidationArrayProperty -Object $Ledger -Name 'entries'
    foreach ($entry in $entries) {
        $kind = Get-KanaAiValidationStringProperty -Object $entry -Name 'kind'
        $id = Get-KanaAiValidationStringProperty -Object $entry -Name 'id'
        $identity = Get-KanaAiValidationStringProperty -Object $entry -Name 'identity'
        $live = $null
        $state = Get-KanaAiValidationProperty -Object $LiveState -Name $id
        if ($null -ne $state) { $live = Get-KanaAiValidationProperty -Object $state -Name 'present' }

        if ($kind -eq 'process') {
            if ($null -eq $live) {
                [void]$actions.Add([pscustomobject]@{ kind = $kind; id = $id; identity = $identity; action = 'verify-absent'; reason = 'no live-state entry; assume already gone and verify only' })
            }
            elseif ([bool]$live) {
                [void]$actions.Add([pscustomobject]@{ kind = $kind; id = $id; identity = $identity; action = 'terminate-by-pid'; reason = 'process the harness launched is still running' })
            }
            else {
                [void]$actions.Add([pscustomobject]@{ kind = $kind; id = $id; identity = $identity; action = 'already-clean'; reason = 'process is not running' })
            }
        }
        elseif ($kind -eq 'window') {
            if ($null -eq $live) {
                [void]$actions.Add([pscustomobject]@{ kind = $kind; id = $id; identity = $identity; action = 'verify-absent'; reason = 'no live-state entry; assume already closed and verify only' })
            }
            elseif ([bool]$live) {
                [void]$actions.Add([pscustomobject]@{ kind = $kind; id = $id; identity = $identity; action = 'close-window'; reason = 'window the harness created is still open' })
            }
            else {
                [void]$actions.Add([pscustomobject]@{ kind = $kind; id = $id; identity = $identity; action = 'already-clean'; reason = 'window is gone' })
            }
        }
        elseif ($kind -eq 'file') {
            if ($null -eq $live) {
                [void]$actions.Add([pscustomobject]@{ kind = $kind; id = $id; identity = $identity; action = 'verify-absent'; reason = 'no live-state entry; assume already deleted and verify only' })
            }
            elseif ([bool]$live) {
                [void]$actions.Add([pscustomobject]@{ kind = $kind; id = $id; identity = $identity; action = 'delete-file'; reason = 'file the harness created still exists' })
            }
            else {
                [void]$actions.Add([pscustomobject]@{ kind = $kind; id = $id; identity = $identity; action = 'already-clean'; reason = 'file is gone' })
            }
        }
        else {
            [void]$actions.Add([pscustomobject]@{ kind = $kind; id = $id; identity = $identity; action = 'unsupported-ledger-kind'; reason = ("the ledger kind '{0}' has no cleanup rule" -f $kind) })
        }
    }

    $unresolved = @($actions | Where-Object { $_.action -eq 'unsupported-ledger-kind' })
    $actionArray = $actions.ToArray()
    return [pscustomobject]@{
        Actions         = $actionArray
        AlreadyClean    = @($actionArray | Where-Object { $_.action -eq 'already-clean' }).Count
        WillMutate      = @($actionArray | Where-Object { $_.action -in @('terminate-by-pid', 'close-window', 'delete-file') }).Count
        UnresolvedKinds = $unresolved.Count
    }
}

function New-KanaAiValidationLedger {
    param([string]$RunId = '', [string]$Mode = 'run')
    $entries = New-Object System.Collections.Generic.List[object]
    $ledger = [ordered]@{
        schemaVersion = $script:KanaAiValidationSchemaVersion
        runId         = $RunId
        mode          = $Mode
        createdAtUtc  = Get-KanaAiValidationUtcNow
        note          = 'Only objects the harness itself created are ever recorded here. Nothing is tracked by process name alone, so cleanup can never reach a process the harness did not start.'
        entries       = @()
    }
    $script:KanaAiValidationLedgerRef = [pscustomobject]@{ Entries = $entries; Ledger = $ledger }
    return $script:KanaAiValidationLedgerRef
}

function Add-KanaAiValidationLedgerEntry {
    param(
        [Parameter(Mandatory = $true)]$LedgerRef,
        [Parameter(Mandatory = $true)][ValidateSet('process', 'window', 'file')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Identity,
        [string]$Note = ''
    )
    [void]$LedgerRef.Entries.Add([pscustomobject]@{
            kind     = $Kind
            id       = $Id
            identity = $Identity
            note     = $Note
            atUtc    = Get-KanaAiValidationUtcNow
        })
    $LedgerRef.Ledger['entries'] = $LedgerRef.Entries.ToArray()
    return $LedgerRef
}

function ConvertTo-KanaAiValidationSafeFileToken {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 'empty' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Text.ToCharArray()) {
        if (($character -ge 'a') -and ($character -le 'z')) { [void]$builder.Append($character) }
        elseif (($character -ge 'A') -and ($character -le 'Z')) { [void]$builder.Append($character.ToLowerInvariant()) }
        elseif (($character -ge '0') -and ($character -le '9')) { [void]$builder.Append($character) }
        else { [void]$builder.Append('-') }
    }
    $token = $builder.ToString()
    if ($token.Length -gt 40) { $token = $token.Substring(0, 40) }
    return $token
}
