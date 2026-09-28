# Is the KanaAI AI engine linked into the binary that actually converts?
#
# The subject is the ENGINE HOST, not mozc_tip64.dll.
#
# Why the subject changed, and why that matters
# ----------------------------------------------
# An earlier version of this test asserted the AI was in mozc_tip64.dll and
# reported the shipped product as having no AI. That conclusion was wrong, and
# the way it was wrong is the reason this file is shaped the way it is.
#
# Measured, with cquery on the configuration the release build uses:
#
#   deps(//win32/tip:mozc_tip64)        1815 labels,  0 of them //engine/kanai_ai
#   deps(//server:mozc_server_win)      2493 labels, 12 of them //engine/kanai_ai
#   deps(//engine:modules)              1775 labels, 12 of them //engine/kanai_ai
#
# mozc_tip64.dll is the TSF front end plus the client. It does not link
# //engine at all - not one //engine label appears in its closure. The
# conversion engine, and therefore the supplemental model that patch 0001
# installs, lives in the out-of-process server. Scanning the TIP for engine
# literals therefore returns zero whether or not the AI was ever built, so that
# scan could not distinguish the two states. It was a measurement that could
# not fail.
#
# What is actually shipped, measured against the installed files:
#
#   C:\Program Files\KanaAI\mozc_server.exe   8 of 9 AI probes present
#   C:\Program Files\KanaAI\mozc_tip64.dll    0 of 9, and cannot have any
#
# So the AI candidate ordering has been in the installed product. This test now
# checks the binary where the decision is made.
#
# Why it is built the way it is
# -----------------------------
# A scan that reports zero cannot be told apart from a scan that is looking in
# the wrong place, and a scan that reports a hit cannot be told apart from one
# matching an unrelated string. Both mistakes have already produced wrong
# conclusions in this log, so this test refuses to report either without
# evidence:
#
#   1. Two encodings. An /utf-8 opt build stores many literals as UTF-16.
#      "kanai.protected" appears in mozc_tip64.dll only in UTF-16, and an
#      ASCII-only scan reports zero for it. Every probe counts both.
#
#   2. An instrument check inside the subject. "kanai.protected" is a literal
#      added by patch 0003 and appears nowhere else in the tree. Every KanaAI
#      build contains it. If it is missing, this test has not shown it can read
#      that binary's strings, so it reports NOT CHECKED and fails rather than
#      reporting a clean zero.
#
#   3. A control binary that must contain nothing, so a positive result is not
#      simply what this routine always says.
#
#   4. Both binaries of the pair are reported. The engine host is expected to
#      carry the AI and the TIP is expected not to, because the second fact is
#      what makes the first meaningful: if either binary could carry it, the
#      check would not be able to tell a working build from a broken one.
param(
    # The binary that hosts the conversion engine, where candidate order is
    # decided. This is the subject of the test.
    [Parameter(Mandatory = $true)][string]$EngineHostPath,

    # The TSF front end. Reported for contrast; it is expected to hold none of
    # the engine literals, and that expectation is part of what is asserted.
    [string]$TipPath = '',

    # A binary that certainly contains no KanaAI code.
    [string]$ControlPath = "$env:SystemRoot\System32\notepad.exe"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Every probe is a string literal in engine/kanai_ai that appears nowhere else
# in the tree, so a hit is evidence that translation unit was linked. Header
# paths and Bazel package names are deliberately NOT used: those live only in
# debug information, which an opt build does not emit, so probing for them
# reports zero whether or not the AI is present.
$aiProbes = [ordered]@{
    'KanaAI.TsfBroker.v1'     = 'pipe_broker_client.cc'
    'KANAI_AI_TSF_PIPE'       = 'pipe_broker_client.cc, kanai_supplemental_model.cc'
    'kanai-broker.exe'        = 'pipe_broker_client.cc'
    'KanaAI.Tsf.TokenPeer.v1' = 'kanai_supplemental_model.cc'
    'aiCandidateCount'        = 'kanai_supplemental_model.cc, rank_policy.cc'
    'candidateRerank'         = 'rank_policy.cc'
    'consentRequired'         = 'kanai_supplemental_model.cc'
    'KanaAiSupplementalModel' = 'kanai_supplemental_model.h, RTTI'
}

# From patch 0003, not from the AI engine, and present in every KanaAI build.
$instrumentProbes = [ordered]@{
    'kanai.protected' = 'patch 0003, session_handler.cc / tip_keyevent_handler.cc'
}

function Get-OccurrenceCount {
    param([byte[]]$Bytes, [string]$Needle)
    $total = 0
    foreach ($encoding in @([Text.Encoding]::ASCII, [Text.Encoding]::Unicode)) {
        $total += ([regex]::Matches($encoding.GetString($Bytes), [regex]::Escape($Needle))).Count
    }
    return $total
}

# One row per probe, emitted to the pipeline. The call site wraps this in @() so
# that a single-row result is still an array: PowerShell unrolls a one-element
# array on return, and a scalar has no Count under Set-StrictMode, which would
# make the one-probe instrument check fail on its own arity rather than on
# anything about the binary.
function Measure-Probes {
    param([byte[]]$Bytes, [System.Collections.Specialized.OrderedDictionary]$Probes)
    foreach ($name in $Probes.Keys) {
        $found = Get-OccurrenceCount -Bytes $Bytes -Needle $name
        [pscustomobject]@{ Probe = $name; Source = $Probes[$name]; Found = $found; Present = ($found -gt 0) }
    }
}

if (-not (Test-Path -LiteralPath $EngineHostPath -PathType Leaf)) {
    throw "No engine host at '$EngineHostPath'."
}
$engineResolved = (Resolve-Path -LiteralPath $EngineHostPath).Path
$engineBytes = [IO.File]::ReadAllBytes($engineResolved)
$engineRows = @(Measure-Probes -Bytes $engineBytes -Probes $aiProbes)
$engineInstrument = @(Measure-Probes -Bytes $engineBytes -Probes $instrumentProbes)

Write-Host ''
Write-Host '=== engine host: AI engine literals (ASCII and UTF-16 counted) ==='
$engineRows | Format-Table -AutoSize
Write-Host '=== engine host: instrument check ==='
$engineInstrument | Format-Table -AutoSize

# The TIP, for contrast.
$tipRows = $null
if ($TipPath -and (Test-Path -LiteralPath $TipPath -PathType Leaf)) {
    $tipResolved = (Resolve-Path -LiteralPath $TipPath).Path
    if ($tipResolved -ne $engineResolved) {
        $tipBytes = [IO.File]::ReadAllBytes($tipResolved)
        $tipRows = @(Measure-Probes -Bytes $tipBytes -Probes $aiProbes)
        Write-Host ''
        Write-Host '=== the TIP front end, for contrast: it must hold none of them ==='
        Write-Host ("TIP                 : {0}" -f $tipResolved)
        $tipRows | Format-Table -AutoSize
    }
}

# The control.
$controlReport = $null
if ($ControlPath -and (Test-Path -LiteralPath $ControlPath -PathType Leaf)) {
    $controlResolved = (Resolve-Path -LiteralPath $ControlPath).Path
    if ($controlResolved -ne $engineResolved) {
        $controlBytes = [IO.File]::ReadAllBytes($controlResolved)
        $controlReport = @(Measure-Probes -Bytes $controlBytes -Probes $aiProbes)
        Write-Host ''
        Write-Host '=== the same probes against a control with no KanaAI code ==='
        Write-Host ("Control             : {0}" -f $controlResolved)
        $controlReport | Format-Table -AutoSize
    }
}

$missing = @($engineRows | Where-Object { -not $_.Present })
$instrumentOk = @($engineInstrument | Where-Object { $_.Present })
$tipLeaks = @()
if ($null -ne $tipRows) { $tipLeaks = @($tipRows | Where-Object { $_.Present }) }

Write-Host ''
Write-Host ("Engine host         : {0}" -f $engineResolved)
Write-Host ("Bytes               : {0}" -f $engineBytes.Length)
Write-Host ("AI probes           : {0}" -f $engineRows.Count)
Write-Host ("AI found            : {0}" -f ($engineRows.Count - $missing.Count))
Write-Host ("AI missing          : {0}" -f $missing.Count)
foreach ($row in $missing) { Write-Host ("  missing           : {0}   ({1})" -f $row.Probe, $row.Source) }
Write-Host ("Instrument readable : {0} of {1}" -f $instrumentOk.Count, $engineInstrument.Count)
if ($null -ne $tipRows) { Write-Host ("TIP holds AI probes : {0} of {1}   (expected 0)" -f $tipLeaks.Count, $tipRows.Count) }

if ($instrumentOk.Count -eq 0) {
    Write-Host ''
    Write-Host 'Status              : NOT CHECKED'
    throw ("None of the instrument literals are in {0}, so this test has not shown it can read that binary's strings. A zero here is not a measurement." -f $engineResolved)
}
if ($null -ne $controlReport) {
    $controlHits = @($controlReport | Where-Object { $_.Present })
    if ($controlHits.Count -gt 0) {
        Write-Host ''
        Write-Host 'Status              : NOT CHECKED'
        throw ("The control binary matched {0} AI probe string(s), so a positive result here could not be attributed to the AI." -f $controlHits.Count)
    }
}
if ($tipLeaks.Count -gt 0) {
    Write-Host ''
    Write-Host 'Status              : NOT CHECKED'
    throw ("The TIP front end holds {0} engine literal(s). Either the TIP has started linking //engine, or the build graph has changed, and this test's contrast no longer holds." -f $tipLeaks.Count)
}

$status = if ($missing.Count -eq 0) { 'PASS' } else { 'FAIL' }
Write-Host ''
Write-Host ("Status              : {0}" -f $status)
Write-Host 'Question            : does the binary that performs conversion carry the KanaAI AI engine?'

if ($missing.Count -gt 0) {
    throw ("{0} of {1} AI engine literals are absent from {2}. The AI engine is not linked into the conversion host, so the IME cannot reorder candidates with it." -f $missing.Count, $engineRows.Count, $engineResolved)
}
exit 0
