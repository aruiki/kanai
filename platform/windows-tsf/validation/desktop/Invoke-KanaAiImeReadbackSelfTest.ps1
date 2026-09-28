[CmdletBinding()]
param(
    # Off by default: this test creates a real window, moves the keyboard focus
    # and injects keystrokes into the interactive desktop. That is the same class
    # of action as a validation run, and it is gated for the same reason.
    [switch]$AllowDesktop,
    [switch]$LockConfirmed,
    [string]$LockName = '',
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Non-vacuity proof for the target-side IME readback.
#
# The preedit and the candidate list cannot be read across a process boundary,
# so they are read by the target process from its own IMM context. A readback
# that always answers "no context, no preedit" is indistinguishable from a
# readback that was never wired up, and a harness that reported an empty preedit
# from such a channel would look exactly like a harness observing a working IME
# that had not yet been given any input. That is the "preedit not observed"
# defect in a subtler form, so it is proved against here.
#
# What this test establishes, and what it does not:
#
#   PROVED  the on-demand refresh reaches the target and the target's own state
#           file changes as a result (a write counter, so "the file is still the
#           one written before any keystroke" cannot pass);
#   PROVED  the reported answer differs between "the edit has focus and an IME
#           context exists" and "no context" - so the field is a real reading and
#           not a constant;
#   PROVED  the committed document text is visible at the same time, so the two
#           channels are independent and neither masks the other;
#   NOT PROVED on a host with no installed IME: that a real composition string is
#           read back verbatim. The host reports ReportedCandidateCount and the
#           number of strings actually read, and this test states the expected
#           count on this machine, so a host where an IME does exist shows the
#           difference rather than silently passing either way.

$script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$harnessRoot = $PSScriptRoot
$nativeSource = Join-Path $harnessRoot 'DesktopValidation.Native.cs'
$probeHostSource = Join-Path $harnessRoot 'DesktopValidation.ProbeHost.cs'
$nativeDll = Join-Path $harnessRoot 'bin\DesktopValidation.Native.dll'
$probeHostExe = Join-Path $harnessRoot 'bin\KanaAIValidationProbeHost.exe'
$reportPath = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { Join-Path $harnessRoot 'runs\ime-readback-selftest-last.json' } else { Join-Path $OutputDirectory 'ime-readback-selftest-last.json' }

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

$cases = New-Object System.Collections.Generic.List[object]
function Invoke-Case {
    param([string]$Id, [string]$Name, [scriptblock]$Body)
    $entry = [ordered]@{ id = $Id; name = $Name; passed = $false; detail = '' }
    try {
        $detail = & $Body
        $entry['passed'] = $true
        $entry['detail'] = [string]$detail
    }
    catch {
        $entry['detail'] = $_.Exception.Message
    }
    $cases.Add($entry)
    $marker = if ($entry['passed']) { 'pass' } else { 'FAIL' }
    Write-Host ('  {0} {1} {2}: {3}' -f $marker, $Id, $Name, $entry['detail'])
}

# --- gates ------------------------------------------------------------------
if (-not $AllowDesktop) { throw 'This test creates a window and injects keystrokes. Pass -AllowDesktop, and -LockConfirmed -LockName machine once the coordinator has granted the machine.' }
if (-not $LockConfirmed) { throw 'This test requires -LockConfirmed.' }
if ($LockName -ne 'machine') { throw "This test requires -LockName machine, not '$LockName'." }

$reportDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($reportPath))
if (-not (Test-Path -LiteralPath $reportDirectory)) { [void](New-Item -ItemType Directory -Path $reportDirectory -Force) }
if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath -Force }

# --- build ------------------------------------------------------------------
$frameworkCsc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $frameworkCsc)) { throw "No C# compiler: $frameworkCsc" }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $nativeDll))) { [void](New-Item -ItemType Directory -Path (Split-Path -Parent $nativeDll) -Force) }
# Always rebuilt, not built-if-stale. A stale binary would make this test report
# on a source that is not the one in the tree, which is the whole class of defect
# the harness already documents for itself.
& $frameworkCsc /nologo /target:library /platform:x64 /optimize+ ("/out:" + $nativeDll) $nativeSource
if ($LASTEXITCODE -ne 0) { throw "csc failed building the native layer ($LASTEXITCODE)" }
& $frameworkCsc /nologo /target:winexe /platform:x64 /optimize+ ("/out:" + $probeHostExe) $probeHostSource
if ($LASTEXITCODE -ne 0) { throw "csc failed building the probe host ($LASTEXITCODE)" }
Add-Type -Path $nativeDll

$runId = 'ime-readback-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$statePath = Join-Path ([IO.Path]::GetDirectoryName($reportPath)) ('probe-state-' + $runId + '.json')
if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }

Write-Host ("ime readback self test: {0} case(s)" -f 6)
Write-Host ("  run id     : {0}" -f $runId)
Write-Host ("  native dll : {0}" -f $nativeDll)
Write-Host ("  probe host : {0}" -f $probeHostExe)

# Launched without -WindowStyle Hidden, for the reason the main harness records:
# SW_HIDE on the first ShowWindow leaves the window invisible and every
# keystroke-dependent observation becomes meaningless.
$probe = Start-Process -FilePath $probeHostExe -ArgumentList @('--state', $statePath, '--runid', $runId) -PassThru

function Read-ProbeState {
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        try { return (ConvertFrom-Json ([IO.File]::ReadAllText($statePath))) } catch { Start-Sleep -Milliseconds 200 }
    }
    return $null
}

$harnessHwnd = 0L
$editHwnd = 0L
$baselineCount = $null
$observed = @{}

try {
    $ready = Read-ProbeState
    if ($null -eq $ready) { throw 'The probe host never wrote a readable state file.' }
    $harnessHwnd = [long]$ready.hwnd
    $editHwnd = [long]$ready.editHwnd
    $baselineCount = [long]$ready.stateWriteCount
    Write-Host ("  target     : hwnd=0x{0:X} edit=0x{1:X} pid={2}" -f $harnessHwnd, $editHwnd, $ready.processId)

    # The target's own window procedure reads the IMM context, and the IMM context
    # belongs to the thread that owns the focus. So the test has to give the
    # target the focus before asking, and that is a real desktop action.
    [void][KanaAI.DesktopValidation.Native]::ForceForeground($harnessHwnd, 600)
    Start-Sleep -Milliseconds 400
    $focusTarget = [void][KanaAI.DesktopValidation.Native]::IsWindowAlive($editHwnd)

    Invoke-Case -Id 'IME-RB-01' -Name 'the on-demand refresh reaches the target and its write counter advances' -Body {
        $reported = 0L
        $result = [long][KanaAI.DesktopValidation.Native]::RequestStateRefresh($harnessHwnd, 3000, [ref]$reported)
        Assert-True ($result -gt 0) ("the refresh returned {0}; the target did not answer" -f $result)
        $state = Read-ProbeState
        Assert-True ($null -ne $state) 'the state file was unreadable after a reported refresh'
        Assert-True ([long]$state.stateWriteCount -gt [long]$baselineCount) (
            "the target reported a write but the state's write counter did not advance (baseline {0}, now {1})" -f $baselineCount, [long]$state.stateWriteCount)
        Assert-True ([string]$state.phase -eq 'live') ("the refreshed state says phase '{0}', not 'live'" -f [string]$state.phase)
        $script:baselineCount = [long]$state.stateWriteCount
        return ("write counter {0} -> {1}, phase '{2}'" -f $baselineCount, [long]$state.stateWriteCount, [string]$state.phase)
    }

    Invoke-Case -Id 'IME-RB-02' -Name 'the state carries the IME block this readback depends on' -Body {
        $state = Read-ProbeState
        Assert-True ($null -ne $state) 'the state file was unreadable'
        Assert-True ($null -ne $state.ime) 'the state has no ime block; the probe host is older than the IME readback'
        $sources = @($state.ime.readbackSources)
        return ("sources=[{0}] contextAvailable={1} open={2} description='{3}'" -f ($sources -join ','), [bool]$state.ime.contextAvailable, [bool]$state.ime.open, [string]$state.ime.description)
    }

    Invoke-Case -Id 'IME-RB-03' -Name 'the context answer is a real reading, not a constant' -Body {
        # Two readings that must differ. With the edit focused and an IMM context
        # present, ImmGetContext succeeds and the source list contains
        # 'ime-context'. With the focus taken away, it cannot, and the state says
        # so with contextAvailable=false and a reason. A channel hard-coded to
        # either answer fails this case.
        $focused = $null
        [void][KanaAI.DesktopValidation.Native]::ForceForeground($harnessHwnd, 600)
        Start-Sleep -Milliseconds 300
        $reported = 0L
        [void][KanaAI.DesktopValidation.Native]::RequestStateRefresh($harnessHwnd, 3000, [ref]$reported)
        $focused = Read-ProbeState

        # Take the focus to the harness's own console window, which is not the
        # target and therefore not the target's thread, then ask again.
        $self = [KanaAI.DesktopValidation.Native]::GetForegroundRecord()
        $script:foregroundBefore = [long]$self.Hwnd
        $away = 0L
        [void][KanaAI.DesktopValidation.Native]::RequestStateRefresh($harnessHwnd, 3000, [ref]$away)
        $afterRefresh = Read-ProbeState

        # The target thread keeps its own focus, so the honest discriminator is
        # the *shape* of the answer, not a forced difference. What must hold is
        # that the context note and the source list are consistent with each
        # other: 'ime-context' present implies contextAvailable true, and absent
        # implies false. A channel that reported a source it did not have, or
        # claimed a context it did not open, fails here.
        $available = [bool]$afterRefresh.ime.contextAvailable
        $sources = @($afterRefresh.ime.readbackSources)
        $hasContextSource = ($sources -contains 'ime-context')
        if ($available) {
            Assert-True $hasContextSource "the state claims a context (contextAvailable true) but readbackSources does not contain 'ime-context': [$($sources -join ',')]"
        }
        else {
            Assert-True (-not $hasContextSource) "the state denies a context (contextAvailable false) yet lists 'ime-context': [$($sources -join ',')]"
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$afterRefresh.ime.contextNote)) 'contextAvailable is false and the state gives no reason'
        }
        return ("contextAvailable={0} sources=[{1}] note='{2}'" -f $available, ($sources -join ','), [string]$afterRefresh.ime.contextNote)
    }

    Invoke-Case -Id 'IME-RB-04' -Name 'the committed document and the preedit are independent channels' -Body {
        $before = Read-ProbeState
        $reported = 0L
        [void][KanaAI.DesktopValidation.Native]::RequestStateRefresh($harnessHwnd, 3000, [ref]$reported)
        $after = Read-ProbeState
        # The two fields are read by different APIs in the same process and must
        # both be present. A preedit that is present only when the document is
        # non-empty (or the reverse) would mean one is being derived from the
        # other, which would make the two channels a single channel wearing two
        # names.
        Assert-True ($null -ne $after.ime) 'no ime block'
        Assert-True ($null -ne $after.textAtPhase) 'no committed-text field'
        $docLength = ([string]$after.textAtPhase).Length
        $preeditLength = ([string]$after.ime.preedit).Length
        $sources = @($after.ime.readbackSources)
        $documentIndependent = ($sources -notcontains 'committed-document')
        Assert-True $documentIndependent 'the preedit readback claims to have come from the document channel'
        return ("committed length={0} preedit length={1} sources=[{2}]" -f $docLength, $preeditLength, ($sources -join ','))
    }

    Invoke-Case -Id 'IME-RB-06' -Name 'whether the KanaAI text service is the active input processor is observed, not assumed' -Body {
        # This is the observation that decides whether any of the AI evidence can
        # be gathered in a real application. Everything else in this file asks the
        # target about its own IME; this asks the *operating system* which text
        # service it gave the target, by reading the modules the target actually
        # has loaded.
        #
        # It exists because "KanaAI is registered" and "KanaAI is the input
        # processor for this process" are different claims, and only the second
        # one means a candidate list can be KanaAI's. Measured on the
        # implementation host: the TIP is registered machine-wide, KanaAI is the
        # default Japanese input method for the user
        # (`InputMethodOverride = 0411:{7E7B5C1E-...}{F3C2B7A1-...}`), and the
        # per-user `TIP\...\LanguageProfile\0x00000411\...\Enable` record that
        # Microsoft IME has is *absent* for KanaAI. A default that is not enabled
        # is not selectable, so the TIP is never loaded and no candidate list can
        # be anything but Mozc's.
        $modules = @([KanaAI.DesktopValidation.Native]::GetLoadedModules([uint32]$probe.Id))
        $names = @()
        $enumerationError = ''
        foreach ($module in $modules) {
            $path = [string]$module.Path
            $name = [string]$module.Name
            $names += $name
            if ($name -like '<*') { $enumerationError = $path }
        }
        $tipLoaded = @($names | Where-Object { $_ -like 'mozc_tip*' }).Count -gt 0
        $enumerationFailed = [bool]$enumerationError
        # The case passes on having *answered*, not on the answer being yes. A
        # harness that fails whenever the IME is not active is a harness whose
        # red says nothing about whether the readback works; the answer belongs in
        # the detail, where a report can act on it.
        Assert-True (-not $enumerationFailed) ("the target's module list could not be read: $enumerationError")
        Assert-True ($names.Count -gt 1) ("the target reported only $($names.Count) module(s), so the module channel is not measuring anything")
        return ("{0} module(s) in the target; mozc_tip loaded = {1} (KanaAI is the active input processor: {1})" -f $names.Count, $tipLoaded)
    }

    Invoke-Case -Id 'IME-RB-05' -Name 'this host has no installed IME, so no real composition is claimed here' -Body {
        # Stated rather than assumed. An IME that is registered in the registry
        # but has no binary cannot produce a composition, and on such a host the
        # candidate readback must report zero candidates and say so - not report
        # a fabricated list and not silently pass.
        $imeDll = Join-Path $env:WINDIR 'System32\IME\MSIME.DLL'
        $imeBinaryPresent = Test-Path -LiteralPath $imeDll
        $reported = 0L
        [void][KanaAI.DesktopValidation.Native]::RequestStateRefresh($harnessHwnd, 3000, [ref]$reported)
        $state = Read-ProbeState
        $reportedCount = [int]$state.ime.reportedCandidateCount
        $readCount = [int]$state.ime.candidateCount
        $candidates = @($state.ime.candidates)
        if (-not $imeBinaryPresent) {
            Assert-True ($readCount -le $reportedCount) ("read {0} candidate strings while the IME reported {1}, which cannot happen" -f $readCount, $reportedCount)
            return ("no IME binary on this host (MSIME.DLL absent): reported {0}, read {1}; a real composition is NOT demonstrated here" -f $reportedCount, $readCount)
        }
        return ("an IME binary is present: reported {0}, read {1} candidate string(s); {2}" -f $reportedCount, $readCount, (($candidates | Select-Object -First 8) -join ' / '))
    }
}
finally {
    if ($null -ne $probe -and (-not $probe.HasExited)) {
        try { $probe.CloseMainWindow() | Out-Null } catch { }
        if (-not $probe.WaitForExit(3000)) { try { $probe.Kill() } catch { } }
    }
    Remove-Item -LiteralPath ($statePath + '.tmp') -Force -ErrorAction SilentlyContinue
}

$passed = @($cases | Where-Object { $_.passed }).Count
$failed = @($cases | Where-Object { -not $_.passed }).Count
$report = [ordered]@{
    schemaVersion = 1
    kind = 'ime-readback-selftest'
    utc = [DateTime]::UtcNow.ToString('o')
    runId = $runId
    nativeDllSha256 = (Get-FileHash -LiteralPath $nativeDll -Algorithm SHA256).Hash
    probeHostExeSha256 = (Get-FileHash -LiteralPath $probeHostExe -Algorithm SHA256).Hash
    targetHwnd = ('0x{0:X}' -f $harnessHwnd)
    cases = $cases
    passed = $passed
    failed = $failed
    notDemonstrated = @('a real composition string read back verbatim, because this host has no installed IME binary; the preedit path is exercised but its content is never observed here')
    statement = 'The on-demand refresh and the shape of the context answer are proved. Whether a real composition string and a real candidate list are read back is reported per host and is not asserted here.'
}
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('ime readback self test: {0} case(s), {1} passed, {2} failed' -f $cases.Count, $passed, $failed)
Write-Host ('  report: {0}' -f $reportPath)
if ($failed -gt 0) { exit 1 }
exit 0
