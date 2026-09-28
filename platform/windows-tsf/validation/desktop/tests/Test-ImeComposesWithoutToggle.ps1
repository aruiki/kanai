# Must the installed KanaAI compose romaji into kana with no keystroke but typing?
#
# The requirement
# ---------------
# A one-click install has to leave the user able to type Japanese. Typing romaji
# and getting kana back is the minimum: if the input method starts closed, the
# user types "kanaai" and gets "kanaai", which is not a Japanese input method.
#
# Order matters, and it is not cosmetic
# ------------------------------------
# The arms run in this order, deliberately:
#
#   1. baseline, no toggle. This is the product measurement, and it has to happen
#      before anything in this test perturbs the input method's state.
#   2. control, toggled. This proves the harness can observe composition at all.
#
# The first version of this test did the opposite and it was wrong in a way that
# produced a false verdict. Alt+backtick is a *toggle*, not a switch, and the
# test assumed it turned the input method on. When an earlier experiment had
# already left the input method open, the control arm turned it off, the canary
# stayed ASCII, and the test reported HARNESS-BROKEN - a claim about the harness
# that was really a claim about unexamined starting state. The control now drives
# to a known-open state by toggling until ime.open reads true, so it does not
# depend on where the previous run left things.
#
# Why the control arm exists at all
# ---------------------------------
# The measurement this replaces reported romaji committing as ASCII, with no
# preedit and no candidate window, while the TIP was loaded, the TSF calls were
# succeeding and every keystroke was arriving. That is a report about the
# product, but it is equally consistent with a harness that cannot observe
# composition. A test that only asserted "the baseline composes" could not tell
# a broken input method from a blind harness. So if the control arm fails to
# compose, this test reports HARNESS-BROKEN and stops: a baseline result could not
# be interpreted.
#
# Each arm gets a fresh probe host, so one arm's state cannot leak into the next.
# A rich edit control is required: a plain EDIT hosts no TSF text service, so an
# input method is never handed its keystrokes there and the test would be
# measuring the control instead.
#
# What this does not verify
# -------------------------
# Candidate list contents. The probe host reports a candidate count and it has
# been 0 even in runs where composition succeeded, so candidate *display* is
# outside this instrument. Composition to kana is what is asserted.
#
# ASCII only on purpose: Windows PowerShell 5.1 decodes a BOM-less .ps1 with
# this machine's code page. Cleanup is in a finally; a diagnostic that leaks the
# process it launched is a defect in its own right.
param(
    [ValidateSet('plain', 'rich')][string]$Edit = 'rich'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = $PSScriptRoot
$desktop = Split-Path -Parent $here
$sourceDll = Join-Path $desktop 'bin\DesktopValidation.Native.dll'
$probeExe = Join-Path $desktop 'bin\KanaAIValidationProbeHost.exe'
foreach ($p in @($sourceDll, $probeExe)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "missing prerequisite: $p" }
}

# The native layer is loaded from an ASCII copy: this repository lives under a
# path containing Japanese characters, which Add-Type mangles on PS 5.1. The
# digest is checked so the measurement is of the binary in the tree.
$asciiRoot = Join-Path $env:TEMP 'kanai-ime-composes'
if (-not (Test-Path -LiteralPath $asciiRoot)) { [void](New-Item -ItemType Directory -Path $asciiRoot -Force) }
$dll = Join-Path $asciiRoot 'DesktopValidation.Native.dll'
Copy-Item -LiteralPath $sourceDll -Destination $dll -Force
$sourceSha = (Get-FileHash -LiteralPath $sourceDll -Algorithm SHA256).Hash
$copySha = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
if ($copySha -ne $sourceSha) { throw "staged copy digest $copySha does not match the tree's $sourceSha" }
Add-Type -Path $dll

function Read-ProbeState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}
function Get-Field {
    param($State, [string]$Name, $Default = '<absent>')
    if ($null -eq $State) { return $Default }
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

# One arm: a fresh probe host, whatever keys $PreChord/$PreKeys ask for, then the
# canary, then the committed text.
function Invoke-CanaryArm {
    param(
        [string]$Label,
        [string[]]$PreChord = @(),
        [string[]]$PreKeys = @(),
        [int]$DriveOpen = 0
    )

    $runId = 'ime-composes-' + $Label + '-' + [Guid]::NewGuid().ToString('n').Substring(0, 6)
    $statePath = Join-Path $asciiRoot ($runId + '.json')
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    $proc = $null
    try {
        $proc = Start-Process -FilePath $probeExe -ArgumentList @('--state', $statePath, '--runid', $runId, '--edit', $Edit) -PassThru
        $deadline = (Get-Date).AddSeconds(20)
        $ready = $null
        while ((Get-Date) -lt $deadline) {
            $ready = Read-ProbeState -Path $statePath
            if ($null -ne $ready -and [string](Get-Field $ready 'phase' '') -eq 'ready') { break }
            Start-Sleep -Milliseconds 200
        }
        if ($null -eq $ready -or [string](Get-Field $ready 'phase' '') -ne 'ready') { throw 'probe host did not become ready within 20s' }
        $hwnd = [int64](Get-Field $ready 'hwnd' 0)
        $editClass = [string](Get-Field $ready 'editClass' '<not reported>')
        if ($editClass -notmatch 'RICHEDIT') {
            throw ("the probe host granted '{0}', which hosts no TSF text service. A plain EDIT would measure the control rather than the input method, so this test refuses to run on it. Pass -Edit rich." -f $editClass)
        }
        [void][KanaAI.DesktopValidation.Native]::ForceForeground($hwnd, 300)
        Start-Sleep -Milliseconds 250

        $toggles = 0
        if ($PreChord.Count -gt 0) {
            [void][KanaAI.DesktopValidation.Native]::SendKeyChord($PreChord, 60, $false)
            $toggles++
            Start-Sleep -Milliseconds 400
        }
        if ($PreKeys.Count -gt 0) {
            [void][KanaAI.DesktopValidation.Native]::SendKeySequence($PreKeys, 60, $false)
            Start-Sleep -Milliseconds 300
        }

        $n = [int64]0
        [void][KanaAI.DesktopValidation.Native]::RequestStateRefresh($hwnd, 2000, [ref]$n)
        $st = Read-ProbeState -Path $statePath
        $openNow = [string](Get-Field $st.ime 'open' '<absent>')
        $openStart = $openNow

        # Drive to a known-open state rather than assuming the toggle turns it on.
        # Alt+backtick is a toggle: one press can open or close the input method
        # depending on what the previous run left behind.
        for ($i = 0; $i -lt $DriveOpen -and $openNow -ne 'True'; $i++) {
            [void][KanaAI.DesktopValidation.Native]::SendKeyChord($PreChord, 60, $false)
            $toggles++
            Start-Sleep -Milliseconds 400
            $n = [int64]0
            [void][KanaAI.DesktopValidation.Native]::RequestStateRefresh($hwnd, 2000, [ref]$n)
            $st = Read-ProbeState -Path $statePath
            $openNow = [string](Get-Field $st.ime 'open' '<absent>')
        }

        $tokens = @('VK_K', 'VK_A', 'VK_N', 'VK_A', 'VK_A', 'VK_I')
        $outcomes = [KanaAI.DesktopValidation.Native]::SendKeySequence($tokens, 60, $false)
        $canarySent = @($outcomes | Where-Object { $_.SentEvents -gt 0 }).Count

        $maxPreedit = 0
        $kanaPreedit = $false
        for ($i = 0; $i -lt 10; $i++) {
            $m = [int64]0
            [void][KanaAI.DesktopValidation.Native]::RequestStateRefresh($hwnd, 2000, [ref]$m)
            $s = Read-ProbeState -Path $statePath
            if ($null -ne $s) {
                $pre = [string](Get-Field $s.ime 'preedit' '')
                if ($pre.Length -gt $maxPreedit) { $maxPreedit = $pre.Length }
                if ($pre -match '[\u3040-\u309F\u30A0-\u30FF]') { $kanaPreedit = $true }
            }
            Start-Sleep -Milliseconds 100
        }

        [void][KanaAI.DesktopValidation.Native]::SendKeySequence(@('VK_RETURN'), 60, $false)
        Start-Sleep -Milliseconds 300
        $c = [int64]0
        [void][KanaAI.DesktopValidation.Native]::RequestStateRefresh($hwnd, 2000, [ref]$c)
        $st = Read-ProbeState -Path $statePath
        $committed = [string](Get-Field $st 'textAtPhase' '')

        [pscustomobject]@{
            Label         = $Label
            EditClass     = $editClass
            OpenAtStart   = $openStart
            OpenWhenTyped = $openNow
            TogglesSent   = $toggles
            CanarySent    = $canarySent
            MaxPreedit    = $maxPreedit
            KanaPreedit   = $kanaPreedit
            Committed     = $committed
            CommittedKana = ($committed -match '[\u3040-\u309F\u30A0-\u30FF]')
        }
    }
    finally {
        if ($null -ne $proc) {
            try { if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(5000) | Out-Null } } catch { }
            try { [Runtime.InteropServices.Marshal]::ReleaseComObject($proc) | Out-Null } catch { }
        }
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ("native layer : {0}" -f $copySha)
Write-Host ("edit control : {0}" -f $Edit)
Write-Host ''

# 1. The product measurement, before this test perturbs anything.
Write-Host '--- arm 1 (product): canary with no toggle at all ---'
$baseline = Invoke-CanaryArm -Label 'baseline'
Write-Host ("  editClass={0} ime.open={1} canarySent={2}/6 maxPreedit={3} kanaPreedit={4}" -f $baseline.EditClass, $baseline.OpenAtStart, $baseline.CanarySent, $baseline.MaxPreedit, $baseline.KanaPreedit)
Write-Host ("  committed='{0}' hasKana={1}" -f $baseline.Committed, $baseline.CommittedKana)
Write-Host ''

# 2. Prove the harness can observe composition, driving to a known-open state.
Write-Host '--- arm 2 (control): canary with the input method driven open ---'
$control = Invoke-CanaryArm -Label 'control' -PreChord @('VK_MENU', 'VK_OEM_3') -DriveOpen 3
Write-Host ("  editClass={0} ime.open start={1} whenTyped={2} toggles={3} canarySent={4}/6 maxPreedit={5}" -f $control.EditClass, $control.OpenAtStart, $control.OpenWhenTyped, $control.TogglesSent, $control.CanarySent, $control.MaxPreedit)
Write-Host ("  committed='{0}' hasKana={1}" -f $control.Committed, $control.CommittedKana)
Write-Host ''

Write-Host '=== summary ==='
Write-Host ("  product (no toggle) : ime.open={0}  kana={1}  committed='{2}'" -f $baseline.OpenAtStart, $baseline.CommittedKana, $baseline.Committed)
Write-Host ("  control (driven open): ime.open={0}  kana={1}  committed='{2}'" -f $control.OpenWhenTyped, $control.CommittedKana, $control.Committed)
Write-Host ''

if (-not $control.CommittedKana) {
    Write-Host 'Status           : HARNESS-BROKEN'
    throw ('The control arm did not produce kana even with the input method driven open (ime.open={0} after {1} toggle(s), maxPreedit={2}), so this harness cannot observe composition. Nothing can be concluded about the product from the product arm, and reporting that as a product failure would be wrong. Control committed=''{3}''.' -f $control.OpenWhenTyped, $control.TogglesSent, $control.MaxPreedit, $control.Committed)
}

if ($baseline.CommittedKana) {
    Write-Host 'Status           : PASS'
    if ($baseline.OpenAtStart -ne 'False') {
        Write-Host ("Note: ime.open read '{0}' before typing rather than the shipped 'False', because a previous run left it that way. The composition requirement is met either way, but this run does not by itself establish the shipped initial state." -f $baseline.OpenAtStart)
    }
    exit 0
}

Write-Host 'Status           : FAIL'
throw ('The installed input method does not compose romaji into kana unless it is first toggled on. A one-click install must not leave the user in that state. The control arm proves this harness can observe composition: the same canary, with the input method driven open (ime.open={0}, {1} toggle(s)), committed kana. The product arm found ime.open={2} before typing, maxPreedit={3}, and committed ''{4}''. Patch 0007 seeds the TSF open/close compartment at activation so that this arm is expected to pass once that build is installed.' -f $control.OpenWhenTyped, $control.TogglesSent, $baseline.OpenAtStart, $baseline.MaxPreedit, $baseline.Committed)
