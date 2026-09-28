# KanaAI desktop validation harness - entry point.
#
# This script produces a machine-readable receipt and never infers success from
# an API return code. Every asserted step is backed by an independent readback
# of observable state:
#
#   injection API  ->  a window message, UI Automation, the target's own state
#                      file written at exit, window enumeration, or the target's
#                      own loaded-module list.
#
# Mode contract, enforced by an early return and by the receipt itself:
#   -PlanOnly     validates the plan and the harness wiring, writes a plan and a
#                 plan-only receipt, and returns BEFORE any native type is
#                 loaded, any process is started, any window is created, any key
#                 is injected and any registry key is read. It performs no
#                 desktop interaction whatsoever.
#   -SelfTest     runs the pure-logic self-test: no window station, no desktop,
#                 no process launch.
#   -CleanupOnly  re-runs cleanup for a previous run from its launch ledger.
#   (default)     a real run. Refuses to start unless the operator passes both
#                 -AllowDesktop and -LockConfirmed with -LockName machine,
#                 because a run injects keystrokes into a shared desktop.
#
# Windows PowerShell 5.1 is the supported host. This file is ASCII-only so it
# cannot be corrupted by the system ANSI code page; every non-ASCII expectation
# comes from the UTF-8 plan file.

[CmdletBinding()]
param(
    [switch]$PlanOnly,
    [switch]$SelfTest,
    [switch]$CleanupOnly,
    [string]$Plan,
    [string]$OutputDirectory,
    [string]$ReceiptPath,
    [ValidateSet('probehost', 'notepad')]
    [string]$Target = 'probehost',
    [switch]$AllowDesktop,
    [switch]$LockConfirmed,
    [string]$LockName = 'machine',
    [switch]$AllowMachineInspection,
    [switch]$AllowExternalTarget,
    [switch]$AllowExternalTextCapture,
    [switch]$AllowScreenshots,
    [switch]$SkipCompile,
    [string]$NativeDll,
    [string]$ProbeHostExe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HarnessRoot = $PSScriptRoot
$script:HarnessVersion = '1.0.0'
$script:CommonPath = Join-Path $script:HarnessRoot 'DesktopValidation.Common.ps1'
$script:NativeSourcePath = Join-Path $script:HarnessRoot 'DesktopValidation.Native.cs'
$script:ProbeHostSourcePath = Join-Path $script:HarnessRoot 'DesktopValidation.ProbeHost.cs'
$script:RunScriptPath = $PSCommandPath
$script:SelfTestPath = Join-Path $script:HarnessRoot 'Invoke-KanaAIDesktopValidationSelfTest.ps1'
$script:DefaultPlanPath = Join-Path $script:HarnessRoot 'desktop-validation-plan.json'
$script:BinDirectory = Join-Path $script:HarnessRoot 'bin'
$script:DefaultNativeDll = Join-Path $script:BinDirectory 'DesktopValidation.Native.dll'
$script:DefaultProbeHostExe = Join-Path $script:BinDirectory 'KanaAIValidationProbeHost.exe'
$script:CurrentOutputDirectory = $null
$script:ProbeHostExePath = $null
$script:ProbeHostProcess = $null
$script:LoopbackHwnd = 0L
$script:TargetPid = 0
# Every probe host process this harness launched, in launch order. A single-valued
# variable was not enough: a run launches the target at TGT-01 and again at RST-02,
# and cleanup that only knew the current one left the first one running.
$script:LaunchedProbeHostPids = New-Object System.Collections.Generic.List[int]
$script:LedgerRef = $null
$script:Screenshots = New-Object System.Collections.Generic.List[object]
# The target's own state-write counter as of the last read. Compared on every
# refresh so a readback that did not actually happen cannot be mistaken for a
# fresh one; see Get-TargetImeObservation.
$script:LastTargetStateWriteCount = $null

if (-not (Test-Path -LiteralPath $script:CommonPath -PathType Leaf)) {
    Write-Error "Shared helpers are missing: $script:CommonPath"
    exit 4
}
. $script:CommonPath

# ---------------------------------------------------------------------------
# Static, side-effect-free checks. These run in every mode, including -PlanOnly,
# and read nothing outside this directory and the plan file.
# ---------------------------------------------------------------------------
function Get-StaticHostEnvironment {
    return [ordered]@{
        osDescription           = [System.Environment]::OSVersion.VersionString
        osVersion               = [System.Environment]::OSVersion.Version.ToString()
        is64BitOperatingSystem  = [System.Environment]::Is64BitOperatingSystem
        is64BitProcess          = [System.Environment]::Is64BitProcess
        powershellVersion       = [string]$PSVersionTable.PSVersion
        powershellEdition       = [string]$PSVersionTable.PSEdition
        clrVersion              = [string]$PSVersionTable.CLRVersion
        harnessVersion          = $script:HarnessVersion
        collectedWithoutDesktop = $true
        note                    = 'Registry, install and TIP-DLL inspection is a separate, explicitly opt-in section; see machineInspection.'
    }
}

function Test-HarnessFiles {
    $required = [ordered]@{
        common       = $script:CommonPath
        nativeSource = $script:NativeSourcePath
        probeHost    = $script:ProbeHostSourcePath
        selfTest     = $script:SelfTestPath
        runScript    = $script:RunScriptPath
    }
    $missing = @()
    foreach ($entry in $required.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) { $missing += $entry.Key }
    }
    return [pscustomobject]@{ Ok = ($missing.Count -eq 0); Missing = $missing }
}

function Get-WiringReport {
    $wiring = Test-KanaAiValidationNativeWiring -NativeSourcePath $script:NativeSourcePath -ScriptPaths @($script:RunScriptPath, $script:CommonPath)
    $canaryKeys = Test-KanaAiValidationCanaryKeyTokens
    return [ordered]@{
        ok              = $wiring.Ok
        missing         = $wiring.Missing
        calledMembers   = $wiring.CalledMembers
        declaredMembers = $wiring.DeclaredMemberCount
        keyTokenCount   = $wiring.KeyTokenCount
        canaryKeyTokens = $wiring.CanaryTokens
        canaryTypable   = $canaryKeys.Ok
        method          = 'static source scan of DesktopValidation.Native.cs against the native call sites in the PowerShell scripts; no compile, no load, no process'
    }
}

function Get-RelativeArtifactPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($script:HarnessRoot)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ($full.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/')
    }
    # Absolute paths outside the harness directory are never written to a
    # receipt: on a developer machine they contain the operator's user name.
    return [System.IO.Path]::GetFileName($full)
}

function New-ArtifactEntry {
    param([Parameter(Mandatory = $true)][string]$Path)
    $info = Get-Item -LiteralPath $Path
    return [ordered]@{
        pathRelative = Get-RelativeArtifactPath -Path $Path
        bytes        = [int64]$info.Length
        sha256       = Get-KanaAiValidationSha256 -Path $Path
        writtenAtUtc = Get-KanaAiValidationUtcNow
    }
}

# ---------------------------------------------------------------------------
# Machine inspection: registry and installed-file reads only. No install, no
# registration, no unregistration, no process launch, no desktop access. Skipped
# entirely unless the operator asks for it.
# ---------------------------------------------------------------------------
function Get-MachineInspection {
    $inspection = [ordered]@{
        collected = $false
        reason    = 'not requested; pass -AllowMachineInspection to collect registry and installed-file data'
        windows   = $null
        install   = $null
        tip       = $null
    }
    if (-not $AllowMachineInspection) { return $inspection }

    $inspection['collected'] = $true
    $inspection['reason'] = 'read-only registry and file reads; nothing was installed, registered or unregistered'

    $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $inspection['windows'] = [ordered]@{
        productName    = [string](Get-KanaAiValidationProperty -Object $currentVersion -Name 'ProductName')
        displayVersion = [string](Get-KanaAiValidationProperty -Object $currentVersion -Name 'DisplayVersion')
        currentBuild   = [string](Get-KanaAiValidationProperty -Object $currentVersion -Name 'CurrentBuild')
        ubr            = [string](Get-KanaAiValidationProperty -Object $currentVersion -Name 'UBR')
        buildLab       = [string](Get-KanaAiValidationProperty -Object $currentVersion -Name 'BuildLabEx')
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $products = @()
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $displayName = [string](Get-KanaAiValidationProperty -Object $entry -Name 'DisplayName')
            if ($displayName -like 'KanaAI*') {
                $products += [ordered]@{
                    displayName     = $displayName
                    displayVersion  = [string](Get-KanaAiValidationProperty -Object $entry -Name 'DisplayVersion')
                    publisher       = [string](Get-KanaAiValidationProperty -Object $entry -Name 'Publisher')
                    productCode     = [string](Get-KanaAiValidationProperty -Object $entry -Name 'ProductCode')
                    upgradeCode     = [string](Get-KanaAiValidationProperty -Object $entry -Name 'UpgradeCode')
                    installLocation = [string](Get-KanaAiValidationProperty -Object $entry -Name 'InstallLocation')
                    installDate     = [string](Get-KanaAiValidationProperty -Object $entry -Name 'InstallDate')
                }
            }
        }
    }
    $inspection['install'] = [ordered]@{ products = $products; queryMethod = 'uninstall registry keys only; Win32_Product was never used' }

    $tip = [ordered]@{ clsid = ''; inprocServer32 = ''; dllPath = ''; dllSha256 = ''; dllPresent = $false; probe = 'not probed' }
    try {
        $tipRoot = 'HKLM:\SOFTWARE\Classes\CLSID'
        foreach ($clsidKey in @(Get-ChildItem -LiteralPath $tipRoot -ErrorAction SilentlyContinue)) {
            $serverKey = Join-Path $clsidKey.PSPath 'InprocServer32'
            if (-not (Test-Path -LiteralPath $serverKey)) { continue }
            $server = Get-ItemProperty -LiteralPath $serverKey -ErrorAction SilentlyContinue
            $serverPath = [string](Get-KanaAiValidationProperty -Object $server -Name '(default)')
            if ([string]::IsNullOrWhiteSpace($serverPath)) { $serverPath = [string](Get-KanaAiValidationProperty -Object $server -Name 'Server') }
            if ($serverPath -like '*KanaAI*mozc_tip*.dll') {
                $tip['clsid'] = $clsidKey.PSChildName
                $tip['inprocServer32'] = $serverPath
                $tip['dllPath'] = $serverPath
                if (Test-Path -LiteralPath $serverPath -PathType Leaf) {
                    $tip['dllPresent'] = $true
                    $tip['dllSha256'] = Get-KanaAiValidationSha256 -Path $serverPath
                    $fileVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($serverPath)
                    $tip['fileVersion'] = [string]$fileVersion.FileVersion
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$tip['dllPath'])) {
            $tip['probe'] = 'no CLSID with an InprocServer32 pointing at a KanaAI mozc_tip DLL was found'
        }
        else { $tip['probe'] = 'KanaAI TIP InprocServer32 resolved from the registry' }
    }
    catch {
        $tip['probe'] = ('registry read failed: ' + $_.Exception.Message)
    }
    $inspection['tip'] = $tip
    return $inspection
}

# ---------------------------------------------------------------------------
# Receipt assembly
# ---------------------------------------------------------------------------
function New-RunId {
    return ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('n').Substring(0, 8))
}

function New-BaseReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$PlanObject,
        [Parameter(Mandatory = $true)]$PlanValidation,
        [Parameter(Mandatory = $true)]$Wiring
    )
    return [ordered]@{
        schemaVersion     = Get-KanaAiValidationSchemaVersion
        harness           = [ordered]@{
            name          = 'KanaAI desktop validation harness'
            version       = $script:HarnessVersion
            host          = 'Windows PowerShell 5.1'
            runId         = $RunId
            mode          = $Mode
            startedAtUtc  = Get-KanaAiValidationUtcNow
            planId        = [string](Get-KanaAiValidationProperty -Object $PlanObject -Name 'planId')
            targetProfile = $Target
        }
        desktopInteraction = [ordered]@{
            performed          = $false
            keystrokesInjected = 0
            processesLaunched  = 0
            windowsCreated     = 0
            registryWrites     = 0
            statement          = 'no desktop interaction in this mode'
        }
        gates              = [ordered]@{
            allowDesktopSwitch   = [bool]$AllowDesktop
            lockConfirmedSwitch = [bool]$LockConfirmed
            lockName            = $LockName
            machineLockNote     = 'The harness cannot verify that scripts/with-development-lock.ps1 -Name machine is held. It only records that the operator asserted it. Only the coordinator can grant that.'
        }
        environmentStatic  = Get-StaticHostEnvironment
        machineInspection  = [ordered]@{ collected = $false; reason = 'not requested; pass -AllowMachineInspection' }
        wiring             = $Wiring
        planValidation     = [ordered]@{
            ok        = $PlanValidation.Ok
            stepCount = $PlanValidation.StepCount
            errors    = $PlanValidation.Errors
            warnings  = $PlanValidation.Warnings
            checks    = $PlanValidation.Checks
        }
        findings           = @()
        steps              = @()
        cleanup            = $null
        artifacts          = @()
        artifactNotes      = 'Paths are relative to the harness directory. Absolute paths under the operator profile are never written to a receipt.'
        privacy            = [ordered]@{
            canaryRomaji = Get-KanaAiValidationCanaryRomaji
            canaryKana   = Get-KanaAiValidationCanaryKana
            canaryRule   = 'The harness types only the canary. Document text is recorded only for a harness-owned target, or when -AllowExternalTextCapture is given.'
            notCollected = @('environment variables', 'clipboard contents', 'user documents and their paths', 'window titles of applications other than the target')
        }
        overall            = 'incomplete'
        exitCode           = 4
        completedAtUtc     = $null
    }
}

function Add-ReceiptFinding {
    param(
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Message,
        $Evidence = $null
    )
    $findings = @(Get-KanaAiValidationArrayProperty -Object $Receipt -Name 'findings')
    $findings += [ordered]@{
        id       = $Id
        severity = $Severity
        message  = $Message
        evidence = $Evidence
        atUtc    = Get-KanaAiValidationUtcNow
    }
    $Receipt['findings'] = $findings
    return $Receipt
}

function Get-CriticalFindingCount {
    param([Parameter(Mandatory = $true)]$Receipt)
    $count = 0
    foreach ($finding in @(Get-KanaAiValidationArrayProperty -Object $Receipt -Name 'findings')) {
        if ([string](Get-KanaAiValidationProperty -Object $finding -Name 'severity') -eq 'critical') { $count++ }
    }
    return $count
}

# ---------------------------------------------------------------------------
# Native layer and probe host. Only reachable from the real-run branch.
# ---------------------------------------------------------------------------
function Find-CscPath {
    $framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (Test-Path -LiteralPath $framework -PathType Leaf) { return $framework }
    $csc = @(Get-Command -Name 'csc.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($csc.Count -gt 0) { return $csc[0].Path }
    return $null
}

function Initialize-NativeLayer {
    $csc = Find-CscPath
    if (-not (Test-Path -LiteralPath $script:BinDirectory)) { [void](New-Item -ItemType Directory -Path $script:BinDirectory -Force) }

    $dll = $NativeDll
    if ([string]::IsNullOrWhiteSpace($dll)) { $dll = $script:DefaultNativeDll }

    # Recompile when the output is missing OR older than its source.  The
    # missing-only check that was here before meant an edit to the C# source
    # was silently ignored as long as a stale DLL sat in bin/, so two wrong
    # DllImport library names were "fixed" in source and still failed at run
    # time.  A binary that does not reflect its source is not a binary that can
    # be reported on.
    $needsCompile = (-not (Test-Path -LiteralPath $dll -PathType Leaf)) -or
                   ((Get-Item -LiteralPath $script:NativeSourcePath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $dll).LastWriteTimeUtc)
    if ($needsCompile) {
        if ($SkipCompile) { throw "Native DLL is missing or older than its source, and -SkipCompile was given: $dll" }
        if ([string]::IsNullOrWhiteSpace($csc)) {
            # No command-line compiler: fall back to the in-process compiler that
            # Add-Type has always used on Windows PowerShell 5.1.
            Add-Type -TypeDefinition ([System.IO.File]::ReadAllText($script:NativeSourcePath)) -ErrorAction Stop
        }
        else {
            & $csc /nologo /target:library /platform:x64 /optimize+ ("/out:" + $dll) $script:NativeSourcePath
            if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE while building the native layer" }
        }
    }

    if (-not ('KanaAI.DesktopValidation.Native' -as [type])) {
        if (Test-Path -LiteralPath $dll -PathType Leaf) { Add-Type -Path $dll }
        else { Add-Type -TypeDefinition ([System.IO.File]::ReadAllText($script:NativeSourcePath)) }
    }
    if (-not ('KanaAI.DesktopValidation.Native' -as [type])) { throw 'The native layer did not load.' }
    return $dll
}

function Initialize-ProbeHost {
    $exe = $ProbeHostExe
    if ([string]::IsNullOrWhiteSpace($exe)) { $exe = $script:DefaultProbeHostExe }
    # Same staleness rule as the native layer: an existing binary is not a
    # current one.  This returned early on existence alone, so the probe host
    # kept running a window class registration that could not resolve.
    $exists = Test-Path -LiteralPath $exe -PathType Leaf
    if ($exists -and ((Get-Item -LiteralPath $script:ProbeHostSourcePath).LastWriteTimeUtc -le (Get-Item -LiteralPath $exe).LastWriteTimeUtc)) { return $exe }
    if ($SkipCompile) { throw "Probe host is missing or older than its source, and -SkipCompile was given: $exe" }
    $csc = Find-CscPath
    if ([string]::IsNullOrWhiteSpace($csc)) { throw 'No C# compiler is available and the probe host is not prebuilt.' }
    if (-not (Test-Path -LiteralPath $script:BinDirectory)) { [void](New-Item -ItemType Directory -Path $script:BinDirectory -Force) }
    & $csc /nologo /target:winexe /platform:x64 /optimize+ ("/out:" + $exe) $script:ProbeHostSourcePath
    if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE while building the probe host" }
    return $exe
}

# ---------------------------------------------------------------------------
# Readbacks. Each of these reads state the injection API did not write.
# ---------------------------------------------------------------------------
function Get-UiaDocumentText {
    param([Parameter(Mandatory = $true)][long]$Hwnd)
    $result = [ordered]@{ available = $false; reason = 'not attempted'; value = $null; via = $null }
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
        if ($null -eq $root) { $result['reason'] = 'AutomationElement.FromHandle returned null'; return $result }
        foreach ($controlTypeName in @('Document', 'Edit', 'Text')) {
            $condition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::$controlTypeName)
            $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($null -eq $element) { continue }
            try {
                $pattern = $element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
                $text = $pattern.DocumentRange.GetText(-1)
                $result['available'] = $true
                $result['value'] = $text
                $result['via'] = ('uia-' + $controlTypeName)
                $result['reason'] = 'ok'
                return $result
            }
            catch {
                $result['reason'] = ('TextPattern unavailable on ' + $controlTypeName + ': ' + $_.Exception.Message)
            }
        }
        if ([string]$result['reason'] -eq 'not attempted') { $result['reason'] = 'no Document, Edit or Text descendant exposed a TextPattern' }
    }
    catch {
        $result['reason'] = $_.Exception.Message
    }
    return $result
}

function Get-TargetText {
    <#
        .SYNOPSIS
        Read the target document through up to two independent channels and
        report which answered. A channel that cannot answer is reported, never
        treated as empty text.
    #>
    param(
        [Parameter(Mandatory = $true)][long]$WindowHandle,
        [Parameter(Mandatory = $true)][long]$EditHandle,
        [Parameter(Mandatory = $true)][bool]$RecordText
    )
    $channels = @()

    $wmGetText = [KanaAI.DesktopValidation.Native]::SendWindowTextRequest($EditHandle, 2000)
    $channels += [ordered]@{
        method    = 'wm-gettext'
        available = ($null -ne $wmGetText)
        text      = $wmGetText
        note      = 'SendMessageTimeout WM_GETTEXT. A live edit control always answers this, so an empty string here means an empty document, not a missing readback.'
    }

    $uia = Get-UiaDocumentText -Hwnd $WindowHandle
    $channels += [ordered]@{
        method    = 'uia-text-pattern'
        available = [bool]$uia['available']
        text      = $uia['value']
        note      = [string]$uia['reason']
    }

    $primary = $null
    $agreements = 0
    $disagreements = @()
    $answered = 0
    foreach ($channel in $channels) {
        if (-not $channel['available']) { continue }
        $answered++
        $text = [string]$channel['text']
        if ($null -eq $primary) { $primary = $text; continue }
        if ((ConvertTo-KanaAiValidationNormalizedText -Text $text) -ceq (ConvertTo-KanaAiValidationNormalizedText -Text $primary)) { $agreements++ }
        else { $disagreements += [string]$channel['method'] }
    }

    $observation = New-KanaAiValidationTextObservation -Text $primary -Available ($answered -gt 0) -RecordText $RecordText -Method 'wm-gettext+uia'
    return [ordered]@{
        observation           = $observation
        rawText               = $primary
        availableTextCount    = $answered
        corroboratingChannels = $agreements
        disagreeingChannels   = $disagreements
        channels              = $channels
        note                  = if ($disagreements.Count -gt 0) { 'the readback channels disagree, so the step must not be reported as a pass' } else { ('{0} independent readback channel(s) answered' -f $answered) }
    }
}

function Get-CandidateWindowObservation {
    param(
        [Parameter(Mandatory = $true)][uint32]$ProcessId,
        [Parameter(Mandatory = $true)][string[]]$ClassNames
    )
    $all = @([KanaAI.DesktopValidation.Native]::EnumerateWindows($true))
    $matched = @()
    foreach ($window in $all) {
        $className = [string]$window.ClassName
        if ($ClassNames -contains $className) {
            $matched += [ordered]@{
                hwnd                = ('0x{0:X}' -f [long]$window.Hwnd)
                processId           = [int]$window.ProcessId
                className           = $className
                visible             = [bool]$window.Visible
                ownedByTargetProcess = ([int]$window.ProcessId -eq [int]$ProcessId)
                rect                = ('{0},{1}-{2},{3}' -f $window.Left, $window.Top, $window.Right, $window.Bottom)
            }
        }
    }
    $ownedByTarget = @($matched | Where-Object { $_['ownedByTargetProcess'] -and $_['visible'] })

    $textChannels = @()
    foreach ($window in $ownedByTarget) {
        $handle = [Convert]::ToInt64(([string]$window['hwnd']).Substring(2), 16)
        $wmText = [KanaAI.DesktopValidation.Native]::SendWindowTextRequest($handle, 500)
        $textChannels += [ordered]@{ method = 'wm-gettext'; hwnd = $window['hwnd']; producedText = (-not [string]::IsNullOrEmpty($wmText)) }
        $uia = Get-UiaDocumentText -Hwnd $handle
        $textChannels += [ordered]@{ method = 'uia-text-pattern'; hwnd = $window['hwnd']; producedText = [bool]$uia['available'] }
    }
    $readable = @($textChannels | Where-Object { $_['producedText'] -eq $true }).Count -gt 0

    # The cross-process channels above are the wrong place to look for candidate
    # *text*, and the receipt used to say so while offering nothing else. That is
    # the "vacuous pass" defect: an observation that only ever records which
    # windows exist cannot distinguish a candidate list the AI re-ranked from one
    # it left alone, because neither is visible through it.
    #
    # The candidate strings are read from the target's own IMM context instead.
    # That is a genuine observation - the strings the input processor is holding
    # right now - and it is the only channel that can answer the question the
    # run actually needs to ask: did the candidate order change?
    $ime = Get-TargetImeObservation
    $imeCandidates = @()
    if ([bool]$ime['available']) { $imeCandidates = @($ime['candidates']) }
    $imeCandidateCount = [int]$ime['candidateCount']

    return [ordered]@{
        available               = $true
        present                 = ($ownedByTarget.Count -gt 0)
        observedWindowCount     = $ownedByTarget.Count
        searchedClassNames      = $ClassNames
        windows                 = $matched
        candidateTextReadable   = $readable
        candidateTextChannels   = $textChannels
        # Read by the target process itself, from its own IMM context. This is
        # the channel that carries candidate strings.
        imeReadbackAvailable    = [bool]$ime['available']
        imeReadbackReason       = [string]$ime['reason']
        imeOpen                 = $ime['imeOpen']
        imeDescription          = [string]$ime['imeDescription']
        preedit                 = $ime['preedit']
        preeditReading          = $ime['preeditReading']
        candidateStrings        = $imeCandidates
        candidateCount          = $imeCandidateCount
        reportedCandidateCount  = [int]$ime['reportedCandidateCount']
        selectionIndex          = $ime['selectionIndex']
        candidateReadbackSources = @($ime['readbackSources'])
        stateWriteCount         = $ime['stateWriteCount']
        # True only when strings were actually read. "A candidate window exists"
        # and "the candidate list is readable" are different claims and are not
        # allowed to stand in for one another.
        candidateTextObserved   = ($imeCandidateCount -gt 0)
        statement               = 'Candidate windows are located by class name and ownership, which is a fact about windows and says nothing about their contents. The candidate strings come from the target process reading its own IMM context; the count reported by the IME and the number of strings actually read are recorded separately so a truncated read cannot look like a short candidate list.'
    }
}

function Get-TargetImeObservation {
    <#
        .SYNOPSIS
        Ask the target process what its own IME state is, and read the answer.
        .DESCRIPTION
        The preedit and the candidate list cannot be observed from outside the
        target. IMM32 contexts belong to the thread that owns the focused
        window, so a harness-process call against the target's edit control does
        not read the target's composition - it returns either a null context or
        another context. The observation therefore comes *from* the target: the
        harness sends one message, the target writes its own state file, and the
        harness reads it.

        The write counter is checked, not assumed. The target deliberately
        swallows its own write failures so it never dies, which means a
        successful message send does not imply a successful write. A missing
        counter check would let a failed refresh pass off the state written
        before any keystroke as a live reading - and an empty document read that
        way is exactly what this function exists to stop being ambiguous.
    #>
    param([int]$TimeoutMilliseconds = 2000)

    $unavailable = [ordered]@{
        available        = $false
        reason           = 'not attempted'
        refreshed        = $false
        stateWriteCount  = $null
        previousWriteCount = $null
        ime              = $null
        preedit          = $null
        preeditReading   = $null
        candidates       = @()
        candidateCount   = 0
        reportedCandidateCount = 0
        selectionIndex   = $null
        readbackSources  = @()
        imeOpen          = $null
        imeDescription   = $null
        committedText    = $null
        statement        = 'no IME readback was taken from the target process'
    }

    if ($targetHwnd -eq 0) {
        $unavailable['reason'] = 'the target window handle is 0, so no request was sent'
        return $unavailable
    }

    $previous = $script:LastTargetStateWriteCount
    $reported = 0L
    $refreshed = 0L
    try {
        $refreshed = [long][KanaAI.DesktopValidation.Native]::RequestStateRefresh($targetHwnd, $TimeoutMilliseconds, [ref]$reported)
    }
    catch {
        $unavailable['reason'] = ('the state-refresh request raised: ' + $_.Exception.Message)
        return $unavailable
    }
    if ($refreshed -le 0) {
        $unavailable['reason'] = ('the target did not answer the state-refresh request within {0} ms, so its IME state was not re-read and the previous state file is stale' -f $TimeoutMilliseconds)
        return $unavailable
    }
    if (($null -ne $previous) -and ($refreshed -le [long]$previous)) {
        # The counter did not advance. Either the target wrote nothing or it
        # answered from a stale queue. Either way this is not a fresh reading.
        $unavailable['reason'] = ('the target answered but its state-write counter did not advance (before {0}, now {1}), so this is not a fresh reading and the file on disk must not be used as one' -f $previous, $refreshed)
        $unavailable['stateWriteCount'] = $refreshed
        $unavailable['previousWriteCount'] = $previous
        return $unavailable
    }
    $script:LastTargetStateWriteCount = $refreshed

    try { $state = Read-KanaAiValidationJson -Path $targetStatePath }
    catch {
        $unavailable['reason'] = ('the target reported a state write but its state file could not be read: ' + $_.Exception.Message)
        $unavailable['stateWriteCount'] = $refreshed
        return $unavailable
    }

    $ime = Get-KanaAiValidationProperty -Object $state -Name 'ime'
    if ($null -eq $ime) {
        $unavailable['reason'] = 'the target wrote its state without an ime block, so this build of the probe host cannot observe the preedit; rebuild the probe host from the current source'
        $unavailable['stateWriteCount'] = $refreshed
        $unavailable['refreshed'] = $true
        return $unavailable
    }

    $candidates = @()
    $candidateArray = Get-KanaAiValidationArrayProperty -Object $ime -Name 'candidates'
    foreach ($candidate in $candidateArray) { $candidates += [string]$candidate }

    $contextAvailable = [bool](Get-KanaAiValidationProperty -Object $ime -Name 'contextAvailable')
    $sources = @()
    foreach ($source in @(Get-KanaAiValidationArrayProperty -Object $ime -Name 'readbackSources')) { $sources += [string]$source }

    return [ordered]@{
        available               = $true
        reason                  = $(if ($contextAvailable) { 'the target read its own IME context and reported the composition state' } else { 'the target has no IME context on its focused control, so there is no composition to observe' })
        refreshed               = $true
        stateWriteCount         = $refreshed
        previousWriteCount      = $previous
        ime                     = $ime
        preedit                 = [string](Get-KanaAiValidationProperty -Object $ime -Name 'preedit')
        preeditReading          = [string](Get-KanaAiValidationProperty -Object $ime -Name 'preeditReading')
        candidates              = $candidates
        candidateCount          = [int](Get-KanaAiValidationProperty -Object $ime -Name 'candidateCount')
        reportedCandidateCount  = [int](Get-KanaAiValidationProperty -Object $ime -Name 'reportedCandidateCount')
        selectionIndex          = [int](Get-KanaAiValidationProperty -Object $ime -Name 'selectionIndex')
        readbackSources         = $sources
        imeOpen                 = [bool](Get-KanaAiValidationProperty -Object $ime -Name 'open')
        imeDescription          = [string](Get-KanaAiValidationProperty -Object $ime -Name 'description')
        contextNote             = [string](Get-KanaAiValidationProperty -Object $ime -Name 'contextNote')
        committedText           = [string](Get-KanaAiValidationProperty -Object $state -Name 'textAtPhase')
        statement               = 'The preedit and the candidate strings are read by the target process from its own IMM context. They cannot be read across a process boundary, so a harness that reports them is reading what the target itself says about its composition, not a guess about it.'
    }
}

function Get-TargetModuleObservation {
    param([Parameter(Mandatory = $true)][uint32]$ProcessId)
    $interesting = @()
    $count = 0
    $errorText = ''
    foreach ($module in @([KanaAI.DesktopValidation.Native]::GetLoadedModules($ProcessId))) {
        $count++
        $path = [string]$module.Path
        $name = [string]$module.Name
        if (($path -like '*KanaAI*') -or ($path -like '*mozc*') -or ($name -like 'mozc_*')) {
            $interesting += [ordered]@{ name = $name; path = $path }
        }
        if ($name -like '<*') { $errorText = $path }
    }
    $tipLoaded = (@($interesting | Where-Object { $_.name -like 'mozc_tip*' }).Count -gt 0)
    return [ordered]@{
        available              = ($errorText -eq '')
        moduleCount            = $count
        enumerationError       = $errorText
        kanaAiOrMozcModules    = $interesting
        tipDllLoaded           = $tipLoaded
        statement              = 'A TSF text service is loaded into the application that owns the focused window, so no mozc_tip module here means the installed TIP was never the active input processor for this process.'
    }
}

function Get-RuntimeProcessObservation {
    param([Parameter(Mandatory = $true)][string[]]$Names)
    $found = @()
    foreach ($name in $Names) {
        $processName = [System.IO.Path]::GetFileNameWithoutExtension($name)
        foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            $startedUtc = 'unavailable'
            $path = 'unavailable'
            try { $startedUtc = $process.StartTime.ToUniversalTime().ToString('o') } catch { }
            try { $path = $process.Path } catch { }
            $found += [ordered]@{
                name         = $process.ProcessName
                processId    = [int]$process.Id
                startedAtUtc = $startedUtc
                path         = $path
            }
        }
    }
    return [ordered]@{
        available    = $true
        processCount = $found.Count
        processes    = $found
        statement    = 'Observation only. A pinned Mozc TIP can convert inside the application process, so the absence of a server or broker process is reported, never asserted.'
    }
}

function Save-TargetScreenshot {
    param(
        [Parameter(Mandatory = $true)][long]$Hwnd,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $record = [ordered]@{ name = $Name; captured = $false; reason = ''; pathRelative = ''; sha256 = '' }
    try {
        $window = [KanaAI.DesktopValidation.Native]::GetWindowThreadInfo($Hwnd)
        $width = [int]$window.Right - [int]$window.Left
        $height = [int]$window.Bottom - [int]$window.Top
        if (($width -le 0) -or ($height -le 0)) { $record['reason'] = 'the target window has an empty rectangle'; return $record }
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $bitmap = New-Object System.Drawing.Bitmap($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen([int]$window.Left, [int]$window.Top, 0, 0, $bitmap.Size)
            $path = Join-Path $script:CurrentOutputDirectory ($Name + '.png')
            $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            $record['captured'] = $true
            $record['pathRelative'] = Get-RelativeArtifactPath -Path $path
            $record['sha256'] = Get-KanaAiValidationSha256 -Path $path
        }
        finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
    catch {
        $record['reason'] = $_.Exception.Message
    }
    $script:Screenshots.Add($record)
    return $record
}

# ---------------------------------------------------------------------------
# Step result shape
# ---------------------------------------------------------------------------
function New-StepResult {
    param(
        [Parameter(Mandatory = $true)]$Step,
        [Parameter(Mandatory = $true)][string]$Verdict,
        [string]$MatchMode = '',
        [string]$Reason = '',
        $Readback = $null,
        $ApiResults = $null,
        $Corroboration = $null,
        [bool]$Executed = $true
    )
    return [ordered]@{
        id             = [string](Get-KanaAiValidationProperty -Object $Step -Name 'id')
        phase          = [string](Get-KanaAiValidationProperty -Object $Step -Name 'phase')
        action         = [string](Get-KanaAiValidationProperty -Object $Step -Name 'action')
        title          = [string](Get-KanaAiValidationProperty -Object $Step -Name 'title')
        assertion      = [string](Get-KanaAiValidationProperty -Object $Step -Name 'assertion' -Default 'assert')
        direction      = [string](Get-KanaAiValidationProperty -Object $Step -Name 'direction' -Default 'any')
        executed       = $Executed
        expected       = Get-KanaAiValidationProperty -Object $Step -Name 'expected'
        input          = Get-KanaAiValidationProperty -Object $Step -Name 'input'
        apiResults     = $ApiResults
        apiResultNote  = 'The values above are raw injection API results. They are recorded for diagnosis only and are deliberately not an input to the verdict.'
        readback       = $Readback
        readbackMethod = [string](Get-KanaAiValidationProperty -Object $Step -Name 'readbackMethod')
        matchMode      = $MatchMode
        reason         = $Reason
        corroboration  = $Corroboration
        verdict        = $Verdict
        atUtc          = Get-KanaAiValidationUtcNow
    }
}

function ConvertTo-ApiResultRecord {
    param($Outcomes)
    $records = @()
    foreach ($outcome in @($Outcomes)) {
        if ($null -eq $outcome) { continue }
        $records += [ordered]@{
            token           = [string]$outcome.Token
            requestedEvents = [int]$outcome.RequestedEvents
            sentEvents      = [int]$outcome.SentEvents
            lastError       = [int]$outcome.LastError
            apiOk           = [bool]$outcome.ApiOk
            detail          = [string]$outcome.Detail
        }
    }
    return $records
}

function Get-CorroborationBundle {
    param([Parameter(Mandatory = $true)][uint32]$ThreadId)
    return [ordered]@{
        caret      = [KanaAI.DesktopValidation.Native]::GetCaretRecord($ThreadId)
        lastInput  = [KanaAI.DesktopValidation.Native]::GetLastInputRecord()
        foreground = [KanaAI.DesktopValidation.Native]::GetForegroundRecord()
    }
}

# ===========================================================================
# Main
# ===========================================================================
$files = Test-HarnessFiles
if (-not $files.Ok) {
    Write-Error ("Missing harness files: " + ($files.Missing -join ', '))
    exit 4
}

$planPath = if ([string]::IsNullOrWhiteSpace($Plan)) { $script:DefaultPlanPath } else { [System.IO.Path]::GetFullPath($Plan) }
$planObject = $null
$planValidation = $null
$wiring = $null
try {
    $planObject = Read-KanaAiValidationJson -Path $planPath
    $planValidation = Test-KanaAiValidationPlan -Plan $planObject
    $wiring = Get-WiringReport
}
catch {
    Write-Error ("Harness preflight failed: " + $_.Exception.Message)
    exit 4
}

if ($SelfTest) {
    & $script:SelfTestPath
    exit $LASTEXITCODE
}

$runId = New-RunId
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $script:HarnessRoot ('runs\' + $runId)
}
$script:CurrentOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $script:CurrentOutputDirectory)) {
    [void](New-Item -ItemType Directory -Path $script:CurrentOutputDirectory -Force)
}
if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $ReceiptPath = Join-Path $script:CurrentOutputDirectory 'receipt.json'
}
$receiptPath = [System.IO.Path]::GetFullPath($ReceiptPath)
$planCopyPath = Join-Path $script:CurrentOutputDirectory 'plan.json'
$ledgerPath = Join-Path $script:CurrentOutputDirectory 'launch-ledger.json'

# --- plan-only -------------------------------------------------------------
# Nothing below this banner touches the desktop. The receipt says so, and the
# self-test proves the native type is not loaded in this mode.
if ($PlanOnly) {
    $receipt = New-BaseReceipt -Mode 'plan-only' -RunId $runId -PlanObject $planObject -PlanValidation $planValidation -Wiring $wiring
    $receipt['desktopInteraction']['statement'] = 'plan-only mode: no native type was loaded, no process was started, no window was created, no key was injected and no registry key was read'
    $receipt['machineInspection'] = Get-MachineInspection
    $planCopy = [ordered]@{
        schemaVersion  = Get-KanaAiValidationSchemaVersion
        planId         = [string](Get-KanaAiValidationProperty -Object $planObject -Name 'planId')
        runId          = $runId
        sourcePlan     = Get-RelativeArtifactPath -Path $planPath
        validatedAtUtc = Get-KanaAiValidationUtcNow
        validation     = $receipt['planValidation']
        plan           = $planObject
    }
    [void](Write-KanaAiValidationJson -Path $planCopyPath -Value $planCopy)
    # A list, not +=: adding one dictionary to another dictionary merges keys
    # instead of collecting artifacts, which fails in a very confusing way.
    $artifacts = New-Object System.Collections.Generic.List[object]
    [void]$artifacts.Add((New-ArtifactEntry -Path $planCopyPath))
    [void]$artifacts.Add((New-ArtifactEntry -Path $planPath))
    $receipt['artifacts'] = $artifacts.ToArray()
    $receipt['overall'] = if ($planValidation.Ok -and $wiring.ok) { 'plan_only' } else { 'failed' }
    $receipt['exitCode'] = Get-KanaAiValidationExitCodeForStatus -Status $receipt['overall']
    $receipt['completedAtUtc'] = Get-KanaAiValidationUtcNow
    [void](Write-KanaAiValidationJson -Path $receiptPath -Value $receipt)

    Write-Host ("plan-only: plan '{0}' with {1} steps validated" -f [string](Get-KanaAiValidationProperty -Object $planObject -Name 'planId'), $planValidation.StepCount)
    foreach ($warning in $planValidation.Warnings) { Write-Host ("  warning: " + $warning) }
    if (-not $planValidation.Ok) {
        foreach ($item in $planValidation.Errors) { Write-Host ("  error: " + $item) }
        exit 1
    }
    if (-not $wiring.ok) {
        foreach ($item in $wiring.missing) { Write-Host ("  error: " + $item) }
        exit 1
    }
    Write-Host ("  receipt: " + (Get-RelativeArtifactPath -Path $receiptPath))
    exit 0
}

# --- real run gates --------------------------------------------------------
# A run injects keystrokes into a shared interactive desktop. Fail closed.
$targetDefinition = Get-KanaAiValidationProperty -Object (Get-KanaAiValidationProperty -Object $planObject -Name 'targets') -Name $Target
# The native layer is loaded HERE, before the gate, and not only further down
# where it used to be loaded. Measured: asking Native::KeyTokenMap before the load
# raised "type name KanaAI.DesktopValidation.Native not found", so the gate threw
# instead of refusing - a broken injector reported as a harness crash, which is the
# same category of wrong answer as a broken injector reported as a product defect.
# Initialize-NativeLayer is idempotent (it compiles only when the DLL is missing
# or older than its source, and loads the type only when it is absent), so the
# call further down stays.
$nativeDllPath = Initialize-NativeLayer

# Key-token parity, measured against the resolver that will actually be used.
#
# The static wiring check above compares two lists of token NAMES, and it passed
# while GetVirtualKeyForToken resolved 26 of the 41 advertised tokens to 0. A
# measured run then injected nothing at all for any letter: every token came back
# as "unknown key token", so the canary never appeared, no romaji ever reached the
# IME, no composition was ever opened, the IME direction could never be
# calibrated, and the twelve AI-on candidate assertions were all correctly
# reported as blocked. Nothing in the receipt said "the injector cannot type".
#
# So the gate asks the resolver. It is placed before the run, not inside it,
# because a harness that cannot type a letter cannot produce evidence about
# anything, and a blocked-step receipt looks like a product problem rather than
# like a broken instrument.
$keyTokenParity = Test-KanaAiValidationKeyTokenParity -Tokens ([KanaAI.DesktopValidation.Native]::KeyTokenMap) -Resolve {
    param([string]$Token)
    [int][KanaAI.DesktopValidation.Native]::GetVirtualKeyForToken($Token)
}

$gateErrors = @()
if (-not $AllowDesktop) { $gateErrors += 'a real run requires -AllowDesktop' }
if (-not $LockConfirmed) { $gateErrors += 'a real run requires -LockConfirmed, asserting the coordinator granted the go-ahead' }
if ($LockName -ne 'machine') { $gateErrors += "a real run requires -LockName machine, not '$LockName'" }
if (-not $planValidation.Ok) { $gateErrors += ('the plan is invalid: ' + ($planValidation.Errors -join '; ')) }
if (-not $wiring.ok) { $gateErrors += ('the harness wiring is invalid: ' + ($wiring.missing -join '; ')) }
if (-not $keyTokenParity.Ok) { $gateErrors += ('the injector cannot resolve every key token it advertises: ' + ($keyTokenParity.Reasons -join '; ')) }
if ($null -eq $targetDefinition) {
    $gateErrors += ("the plan has no target profile named '{0}'" -f $Target)
}
elseif ((Get-KanaAiValidationBoolProperty -Object $targetDefinition -Name 'requiresOperatorConsent' -Default $false) -and (-not $AllowExternalTarget)) {
    $gateErrors += ("the '{0}' target is an external application; pass -AllowExternalTarget to use it" -f $Target)
}

if ($gateErrors.Count -gt 0) {
    $receipt = New-BaseReceipt -Mode 'run-refused' -RunId $runId -PlanObject $planObject -PlanValidation $planValidation -Wiring $wiring
    $receipt['desktopInteraction']['statement'] = 'the run was refused before any desktop interaction'
    $receipt['gateErrors'] = $gateErrors
    $receipt['keyTokenParity'] = [ordered]@{
        checked    = $keyTokenParity.Checked
        ok         = $keyTokenParity.Ok
        unresolved = @($keyTokenParity.Unresolved)
        method     = 'every token in Native::KeyTokenMap was passed to Native::GetVirtualKeyForToken and the returned virtual key was required to be non-zero'
    }
    if ($CleanupOnly) { $receipt['harness']['mode'] = 'cleanup-refused' }
    $receipt['overall'] = 'incomplete'
    $receipt['exitCode'] = 3
    $receipt['completedAtUtc'] = Get-KanaAiValidationUtcNow
    [void](Write-KanaAiValidationJson -Path $receiptPath -Value $receipt)
    foreach ($item in $gateErrors) { Write-Host ("refused: " + $item) }
    Write-Host ("  receipt: " + (Get-RelativeArtifactPath -Path $receiptPath))
    exit 3
}

# ===========================================================================
# REAL RUN. Everything below this banner may touch the desktop.
# ===========================================================================
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue

$receipt = New-BaseReceipt -Mode 'run' -RunId $runId -PlanObject $planObject -PlanValidation $planValidation -Wiring $wiring
$receipt['keyTokenParity'] = [ordered]@{
    checked    = $keyTokenParity.Checked
    ok         = $keyTokenParity.Ok
    unresolved = @($keyTokenParity.Unresolved)
    method     = 'every token in Native::KeyTokenMap was passed to Native::GetVirtualKeyForToken and the returned virtual key was required to be non-zero'
}
if ($CleanupOnly) { $receipt['harness']['mode'] = 'cleanup-only' }
$receipt['desktopInteraction']['performed'] = $true
$receipt['desktopInteraction']['statement'] = 'a real run was authorised by the operator for this interactive session'
$receipt['machineInspection'] = Get-MachineInspection

$recordText = Get-KanaAiValidationBoolProperty -Object $targetDefinition -Name 'recordText' -Default $false
if ((-not $recordText) -and $AllowExternalTextCapture) { $recordText = $true }
$receipt['privacy']['textRecordingForTarget'] = $recordText

$script:LedgerRef = New-KanaAiValidationLedger -RunId $runId -Mode $(if ($CleanupOnly) { 'cleanup' } else { 'run' })
function Save-Ledger {
    [void](Write-KanaAiValidationJson -Path $ledgerPath -Value $script:LedgerRef.Ledger)
}

# A trace line for every native call the run makes.
#
# Measured need: a real run of this harness reaches `INJ-00` (`loopback-canary`)
# and never leaves it - 0.28 s of total CPU, the three busiest threads all in
# `Wait / UserRequest`, and no AI process running at all. "INJ-00 hangs" names a
# step, not a call, and `INJ-00` makes six native calls in order, so the step
# boundary above cannot say which one. Each call therefore brackets itself, and
# the last `enter` with no matching `leave` is the call that blocked.
#
# stderr, and `[Console]::Error` rather than `Write-Host`, for the same reason
# the step progress lines use it: on Windows PowerShell 5.1 a child process's
# `Write-Host` does not reliably reach a redirected stdout file, and a trace that
# does not survive redirection is not a trace.
function Write-KanaAiValidationTrace {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$Detail = ''
    )
    [Console]::Error.WriteLine(
        'KANAI_DESKTOP_TRACE utc=' + [DateTime]::UtcNow.ToString('HH:mm:ss.fff') +
        ' ' + $Stage + $(if ($Detail) { ' ' + $Detail } else { '' }))
}

$steps = @(Get-KanaAiValidationArrayProperty -Object $planObject -Name 'steps')
$canaryKana = Get-KanaAiValidationCanaryKana
$canaryRomaji = Get-KanaAiValidationCanaryRomaji
$candidateClassNames = @(Get-KanaAiValidationArrayProperty -Object (Get-KanaAiValidationProperty -Object $planObject -Name 'candidateWindow') -Name 'classNames' | ForEach-Object { [string]$_ })
$runtimeProcessNames = @(Get-KanaAiValidationArrayProperty -Object $planObject -Name 'runtimeProcessesOfInterest' | ForEach-Object { [string]$_ })
$targetClass = [string](Get-KanaAiValidationProperty -Object $targetDefinition -Name 'windowClass')

$loopbackHwnd = 0L
$loopbackEditHwnd = 0L
$targetHwnd = 0L
$targetEditHwnd = 0L
$targetPid = 0
$targetThreadId = 0
$targetStatePath = Join-Path $script:CurrentOutputDirectory 'probehost-state.json'
$baselineText = ''
$injectedKeyCount = 0
$imeCalibration = [ordered]@{
    determined              = $false
    kanaDirectionAtToggleA  = $null
    togglesNeededToReachOn  = 0
    note                    = 'not calibrated yet'
}
$lastCandidateObservation = $null
$lastRuntimeObservation = $null
$lastModules = $null
$cleanupResults = @()
$stepResults = New-Object System.Collections.Generic.List[object]

function Read-TargetTextNow {
    if (($targetHwnd -eq 0) -or ($targetEditHwnd -eq 0)) {
        return [ordered]@{
            observation           = New-KanaAiValidationTextObservation -Text $null -Available $false -RecordText $recordText -Method 'none'
            rawText               = $null
            availableTextCount    = 0
            corroboratingChannels = 0
            disagreeingChannels   = @()
            channels              = @()
            note                  = 'the target is not available, so there is no readback'
        }
    }
    return Get-TargetText -WindowHandle $targetHwnd -EditHandle $targetEditHwnd -RecordText $recordText
}

function Start-ProbeHost {
    if (Test-Path -LiteralPath $targetStatePath) { Remove-Item -LiteralPath $targetStatePath -Force }
    # The probe host must NOT be started with -WindowStyle Hidden.  Measured:
    # with -WindowStyle Hidden the host's window never becomes visible, so
    # TGT-02 fails and every step that needs keystrokes is blocked.  The cause
    # is STARTF_USESHOWWINDOW with wShowWindow = SW_HIDE, which Windows applies
    # to the first ShowWindow call the new process makes - and the host calls
    # ShowWindow(mainWindow, SW_SHOW) as that first call.  Launching it normally
    # leaves SW_SHOW in effect.  The host is a windowed test target by design;
    # hiding it defeats the only thing this harness observes.
    $process = Start-Process -FilePath $script:ProbeHostExePath -ArgumentList @('--state', $targetStatePath, '--runid', $runId) -PassThru
    $script:ProbeHostProcess = $process
    # Every launched host is remembered, not just the current one.
    #
    # Measured: a real run launches the target at TGT-01 and again at RST-02.
    # RST-01 closes the first window, and the cleanup pass then terminated only
    # `$script:TargetPid`, which by then was the SECOND host. The first process
    # was never recorded anywhere, so it survived the run, and the self test's
    # "no probe host process may exist" case caught it on the next invocation.
    # A cleanup that only knows the most recent child is not cleanup.
    if (-not $script:LaunchedProbeHostPids.Contains([int]$process.Id)) {
        [void]$script:LaunchedProbeHostPids.Add([int]$process.Id)
    }
    Write-KanaAiValidationTrace -Stage 'probehost' -Detail ('launched pid=' + $process.Id + ' waitingFor=ready deadlineSeconds=20')
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $targetStatePath -PathType Leaf) {
            try {
                $state = Read-KanaAiValidationJson -Path $targetStatePath
                if ([string](Get-KanaAiValidationProperty -Object $state -Name 'phase') -eq 'ready') {
                    Write-KanaAiValidationTrace -Stage 'probehost' -Detail 'ready'
                    return $state
                }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 200
    }
    Write-KanaAiValidationTrace -Stage 'probehost' -Detail 'NOT-READY within 20s'
    throw 'The probe host did not report itself ready within 20 seconds.'
}

function Invoke-CleanupPass {
    param([string]$Pass = 'first')
    $live = [ordered]@{}
    $processAlive = $false
    if ($null -ne $script:ProbeHostProcess) {
        try { $processAlive = (-not $script:ProbeHostProcess.HasExited) } catch { $processAlive = $false }
    }
    $live['probehost'] = @{ present = $processAlive }

    # The live state has to be keyed by the LEDGER'S OWN IDS, because that is what
    # Resolve-KanaAiValidationCleanupPlan looks each entry up by.
    #
    # Measured: this published a single key 'probehost', while the ledger records
    # 'probehost-<pid>' for every launch. Every process entry therefore missed the
    # lookup, fell into the "no live-state entry" branch, and was planned as
    # `verify-absent` - "assume already gone and verify only". Across a real run
    # with two launched hosts that produced zero `terminate-by-pid` actions and
    # twenty `verify-absent` ones, and both probe host processes survived. The
    # harness had never once terminated a process it launched, while its README
    # claimed a stray process was impossible.
    #
    # A cleanup that cannot name what it must clean is not a cleanup, so every
    # launched pid is published under the id the ledger used for it.
    foreach ($pidLaunched in $script:LaunchedProbeHostPids) {
        $alive = $false
        try { $alive = ($null -ne (Get-Process -Id ([int]$pidLaunched) -ErrorAction SilentlyContinue)) } catch { $alive = $false }
        $live[('probehost-' + $pidLaunched)] = @{ present = $alive }
    }
    if (($script:TargetPid -ne 0) -and (-not $live.Contains(('probehost-' + $script:TargetPid)))) {
        $aliveTarget = $false
        try { $aliveTarget = ($null -ne (Get-Process -Id ([int]$script:TargetPid) -ErrorAction SilentlyContinue)) } catch { $aliveTarget = $false }
        $live[('probehost-' + $script:TargetPid)] = @{ present = $aliveTarget }
    }

    $live['probehost-loopback'] = @{ present = [KanaAI.DesktopValidation.Native]::IsWindowAlive($script:LoopbackHwnd) }
    $live['probehost-state'] = @{ present = (Test-Path -LiteralPath $targetStatePath -PathType Leaf) }

    $plan = Resolve-KanaAiValidationCleanupPlan -Ledger $script:LedgerRef.Ledger -LiveState $live
    $executed = @()
    foreach ($action in $plan.Actions) {
        $entry = [ordered]@{ kind = $action.kind; id = $action.id; identity = $action.identity; action = $action.action; reason = $action.reason; performed = $false; outcome = 'nothing to do' }
        if ($action.action -eq 'close-window') {
            $closed = [KanaAI.DesktopValidation.Native]::CloseWindowIfOwned($script:LoopbackHwnd, 'KanaAIValidationLoopbackClass')
            $entry['performed'] = $true
            $entry['outcome'] = if ($closed) { 'closed by window-class match' } else { 'refused: the window class did not match the class the harness registered' }
        }
        elseif ($action.action -eq 'terminate-by-pid') {
            # Every host this harness launched, not only the current target pid.
            # See Start-ProbeHost: a run launches the target more than once, and a
            # cleanup that only knows the latest one leaks the earlier ones.
            $candidates = New-Object System.Collections.Generic.List[int]
            foreach ($known in $script:LaunchedProbeHostPids) { [void]$candidates.Add([int]$known) }
            if (($script:TargetPid -ne 0) -and (-not $candidates.Contains([int]$script:TargetPid))) {
                [void]$candidates.Add([int]$script:TargetPid)
            }
            $outcomes = New-Object System.Collections.Generic.List[string]
            $performedAny = $false
            foreach ($pidToStop in $candidates) {
                $target = $null
                try { $target = Get-Process -Id $pidToStop -ErrorAction Stop } catch { $target = $null }
                if ($null -eq $target) { [void]$outcomes.Add(("{0}: already gone" -f $pidToStop)); continue }
                $pathMatches = $false
                try { $pathMatches = ([string]$target.Path -eq [string]$script:ProbeHostExePath) } catch { $pathMatches = $false }
                if (-not $pathMatches) {
                    [void]$outcomes.Add(("{0}: refused, the live process is not the executable the harness launched" -f $pidToStop))
                    continue
                }
                if (($pidToStop -eq [int]$script:TargetPid) -and ($script:TargetPid -ne 0) -and ($targetHwnd -ne 0)) {
                    # Assigned, not cast to [void] and piped: `[void]$call | Out-Null`
                    # puts System.Void on the pipeline and raises "Cannot convert
                    # System.Void to a value", which is what one version of this
                    # line did. It surfaced as a critical STEP-EXECUTION-ERROR on
                    # CLN-01 and CLN-02, so the harness reported my mistake instead
                    # of swallowing it.
                    $null = [KanaAI.DesktopValidation.Native]::CloseWindowIfOwned($targetHwnd, $targetClass)
                }
                $deadline = (Get-Date).AddSeconds(3)
                while ((Get-Date) -lt $deadline) {
                    try { $target.Refresh() } catch { break }
                    if ($target.HasExited) { break }
                    Start-Sleep -Milliseconds 100
                }
                if (-not $target.HasExited) {
                    Stop-Process -Id ([int]$target.Id) -Force -ErrorAction SilentlyContinue
                    $performedAny = $true
                    [void]$outcomes.Add(("{0}: terminated by pid after its path matched" -f $pidToStop))
                }
                else {
                    [void]$outcomes.Add(("{0}: exited on its own" -f $pidToStop))
                }
            }
            $entry['performed'] = $performedAny
            $entry['outcome'] = ($outcomes -join '; ')
            $entry['pidsConsidered'] = $candidates.ToArray()
        }
        $executed += $entry
    }
    return [ordered]@{
        pass             = $Pass
        plan             = $plan
        executed         = $executed
        idempotencyNote  = 'A repeated pass must resolve every ledger entry to already-clean, verify-absent or refused. Any other outcome is a cleanup defect.'
    }
}

# --- native layer + probe host --------------------------------------------
try {
    $nativeDllPath = Initialize-NativeLayer
    if ($Target -eq 'probehost') { $script:ProbeHostExePath = Initialize-ProbeHost }
    $builtArtifacts = New-Object System.Collections.Generic.List[object]
    foreach ($built in (ConvertTo-KanaAiValidationArray @($nativeDllPath, $script:ProbeHostExePath))) {
        if ([string]::IsNullOrWhiteSpace([string]$built)) { continue }
        if (Test-Path -LiteralPath $built -PathType Leaf) { [void]$builtArtifacts.Add((New-ArtifactEntry -Path $built)) }
    }
    $receipt['artifacts'] = $builtArtifacts.ToArray()
}
catch {
    $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'NATIVE-LOAD-FAILED' -Severity 'critical' -Message $_.Exception.Message
    $receipt['overall'] = 'incomplete'
    $receipt['exitCode'] = 4
    $receipt['completedAtUtc'] = Get-KanaAiValidationUtcNow
    [void](Write-KanaAiValidationJson -Path $receiptPath -Value $receipt)
    Write-Host ("native layer failed: " + $_.Exception.Message)
    exit 4
}

# --- cleanup-only mode -----------------------------------------------------
if ($CleanupOnly) {
    $previousLedgerPath = Join-Path $script:CurrentOutputDirectory 'launch-ledger.json'
    if (-not (Test-Path -LiteralPath $previousLedgerPath -PathType Leaf)) {
        $receipt['overall'] = 'incomplete'
        $receipt['exitCode'] = 3
        $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'LEDGER-MISSING' -Severity 'critical' -Message ("No launch ledger was found at {0}, so there is nothing that can be safely closed. The harness will not guess." -f $previousLedgerPath)
        $receipt['completedAtUtc'] = Get-KanaAiValidationUtcNow
        [void](Write-KanaAiValidationJson -Path $receiptPath -Value $receipt)
        Write-Host 'refused: no launch ledger in the given output directory'
        exit 3
    }
    $script:LedgerRef = [pscustomobject]@{ Entries = $null; Ledger = (Read-KanaAiValidationJson -Path $previousLedgerPath) }
    $pass = Invoke-CleanupPass -Pass 'cleanup-only'
    $receipt['cleanup'] = $pass
    $receipt['overall'] = 'passed'
    $receipt['exitCode'] = 0
    $receipt['completedAtUtc'] = Get-KanaAiValidationUtcNow
    [void](Write-KanaAiValidationJson -Path $receiptPath -Value $receipt)
    Write-Host ("cleanup-only: {0} ledger entr(ies), {1} action(s) that would mutate state" -f @($pass['plan'].Actions).Count, $pass['plan'].WillMutate)
    foreach ($entry in @($pass['executed'])) { Write-Host ("  {0,-18} {1}" -f $entry['action'], $entry['outcome']) }
    exit 0
}

# --- step loop -------------------------------------------------------------
foreach ($step in $steps) {
    $id = [string](Get-KanaAiValidationProperty -Object $step -Name 'id')
    $action = [string](Get-KanaAiValidationProperty -Object $step -Name 'action')
    $assertion = [string](Get-KanaAiValidationProperty -Object $step -Name 'assertion' -Default 'assert')
    $direction = [string](Get-KanaAiValidationProperty -Object $step -Name 'direction' -Default 'any')
    $expected = Get-KanaAiValidationProperty -Object $step -Name 'expected'
    $observable = [string](Get-KanaAiValidationProperty -Object $expected -Name 'observable')
    $matchMode = [string](Get-KanaAiValidationProperty -Object $expected -Name 'match')
    $predicate = [string](Get-KanaAiValidationProperty -Object $expected -Name 'predicate')
    $expectedValue = [string](Get-KanaAiValidationProperty -Object $expected -Name 'value')
    $calibrates = Get-KanaAiValidationBoolProperty -Object $step -Name 'calibratesDirection' -Default $false
    $imeSetup = Get-KanaAiValidationProperty -Object $step -Name 'imeSetup'
    $input = Get-KanaAiValidationProperty -Object $step -Name 'input'

    $blockedReason = ''
    if (($direction -eq 'ime-on') -and (-not [bool]$imeCalibration['determined'])) {
        $blockedReason = 'the IME direction was never calibrated, so no assertion that depends on it may be reported as anything but blocked'
    }

    # Progress, one line per step, before the step runs.
    #
    # This exists because a run that stalls is otherwise unobservable. Measured:
    # a real run of this harness sat at 0% CPU for eleven minutes, the only file it
    # left was a launch ledger holding one loopback window, and stdout was empty -
    # because every progress line this script writes is on a path that runs only
    # when the run finishes. The result was that "where did it stop" could not be
    # answered from the artifact at all, and the answer had to be guessed at from
    # the source.
    #
    # stderr rather than Write-Host, because Write-Host from a child PowerShell
    # does not reliably reach a redirected stdout file on Windows PowerShell 5.1,
    # and the whole point is that the line exists in the log a reader gets.
    $stepStarted = [DateTime]::UtcNow
    [Console]::Error.WriteLine(
        "KANAI_DESKTOP_STEP start id=" + $id + " action=" + $action +
        " total=" + $steps.Count + " completed=" + $stepResults.Count)

    $apiResults = @()
    $readbackDetail = $null
    $observation = $null
    $booleanObservation = $null
    $reason = ''
    $executed = $true

    try {
        $interKeyDelay = 60
        $settle = 400
        $scanCode = $false
        $textMode = 'vk'
        $repeat = 1
        $chord = $false
        $keys = @()
        $canaryTokens = @()
        $focusTo = 'target'
        if ($null -ne $input) {
            $interKeyDelay = Get-KanaAiValidationIntProperty -Object $input -Name 'interKeyDelayMs' -Default 60
            $settle = Get-KanaAiValidationIntProperty -Object $input -Name 'settleMs' -Default 400
            $repeat = [Math]::Max(1, (Get-KanaAiValidationIntProperty -Object $input -Name 'repeat' -Default 1))
            $inputMode = [string](Get-KanaAiValidationProperty -Object $input -Name 'mode')
            if ($inputMode -eq 'vksc') { $scanCode = $true }
            if ($inputMode -eq 'unicode') { $textMode = 'unicode' }
            $chord = Get-KanaAiValidationBoolProperty -Object $input -Name 'chord' -Default $false
            $keys = @(Get-KanaAiValidationArrayProperty -Object $input -Name 'keys' | ForEach-Object { [string]$_ })
            $canaryTokens = @(ConvertTo-KanaAiValidationKeyTokens -Text (Get-KanaAiValidationStringProperty -Object $input -Name 'text'))
            $focusTo = [string](Get-KanaAiValidationProperty -Object $input -Name 'focusTo' -Default 'target')
        }

        switch ($action) {

            'capture-preflight' {
                $observation = Get-StaticHostEnvironment
                $booleanObservation = $true
                $reason = 'static host description collected with no desktop access'
            }

            'observe-environment' {
                $preflight = [KanaAI.DesktopValidation.Native]::CapturePreflight()
                $executable = ''
                try { $executable = [string][System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
                $uiAccess = [KanaAI.DesktopValidation.Native]::GetManifestUiAccessFlag($executable)
                $imm = [KanaAI.DesktopValidation.Native]::GetImmRecord($loopbackHwnd)
                $observation = [ordered]@{
                    available = $true
                    injector  = [ordered]@{
                        processId          = $preflight.ProcessId
                        threadId           = $preflight.ThreadId
                        sessionId          = $preflight.SessionId
                        is64BitProcess     = ($preflight.Is64BitProcess -eq 1)
                        windowStation      = $preflight.WindowStation
                        windowStationError = $preflight.WindowStationError
                        desktop            = $preflight.Desktop
                        desktopError       = $preflight.DesktopError
                        integrityLevel     = $preflight.IntegrityLevel
                        integritySid       = $preflight.IntegritySid
                        integrityError     = $preflight.IntegrityError
                        isElevated         = $preflight.IsElevated
                        elevationType      = $preflight.ElevationType
                        uiAccess           = $uiAccess
                        uiAccessMethod     = 'scan of the injector executable for a uiAccess manifest declaration. Windows exposes no direct Win32 query for this, so -1 means unknown and must not be read as "not UIAccess".'
                        dpiAwareness       = $preflight.DpiAwareness
                        dpiAwarenessMethod = $preflight.DpiAwarenessDetail
                        foreground         = [ordered]@{
                            hwnd      = ('0x{0:X}' -f [long]$preflight.ForegroundHwnd)
                            processId = [int]$preflight.ForegroundProcessId
                            className = $preflight.ForegroundClass
                            process   = $preflight.ForegroundProcessName
                            titleRecorded = $false
                            titleNote     = 'the foreground window title is deliberately not recorded; it can contain the operator document name'
                        }
                    }
                    harnessLoopbackInputContext = [ordered]@{
                        available   = $imm.Ok
                        open        = $imm.Open
                        contextName = $imm.ContextName
                        note         = 'Only a window this harness owns can be queried for IME state. There is no honest cross-process way to read another application IME open/closed state, and the harness does not guess: the IME-on and IME-off steps are decided by the committed text instead.'
                    }
                    machineInspection = $receipt['machineInspection']
                }
                $booleanObservation = ((-not [string]::IsNullOrWhiteSpace([string]$preflight.WindowStation)) -and (-not [string]::IsNullOrWhiteSpace([string]$preflight.Desktop)))
                $reason = if ($booleanObservation) { ("window station '{0}', desktop '{1}'" -f $preflight.WindowStation, $preflight.Desktop) }
                          else { 'the injector could not read its own window station or desktop name, so it cannot know which input queue it feeds' }

                if ($id -eq 'TGT-03') {
                    $targetThread = [KanaAI.DesktopValidation.Native]::CaptureTargetThread($targetHwnd)
                    $observation['targetThread'] = [ordered]@{
                        processId     = [int]$targetThread.ProcessId
                        threadId      = [int]$targetThread.ThreadId
                        desktop       = $targetThread.Desktop
                        desktopError  = $targetThread.DesktopError
                        windowStation = $targetThread.WindowStation
                    }
                    $sameDesktop = ($targetThread.Desktop -ceq [string]$preflight.Desktop)
                    $sameStation = ($targetThread.WindowStation -ceq [string]$preflight.WindowStation)
                    $booleanObservation = ($sameDesktop -and $sameStation)
                    $reason = if ($booleanObservation) { 'the injector and the target thread report the same window station and desktop' }
                              else { ('injector desktop {0} against target desktop {1}; injector window station {2} against {3}' -f $preflight.Desktop, $targetThread.Desktop, $preflight.WindowStation, $targetThread.WindowStation) }
                    if (-not $booleanObservation) {
                        $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'WINSTA-DESKTOP-MISMATCH' -Severity 'critical' -Message 'The injector and the target do not share a window station and desktop. Injected input cannot reach a window on another desktop, and no API return value would ever show that.' -Evidence $observation['targetThread']
                    }
                    else {
                        $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'WINSTA-DESKTOP-PARITY' -Severity 'info' -Message ("The injector and the target share window station '{0}' and desktop '{1}'." -f $preflight.WindowStation, $preflight.Desktop)
                    }
                }
            }

            'loopback-canary' {
                Write-KanaAiValidationTrace -Stage 'native-call-enter' -Detail 'CreateLoopbackWindow'
                $loopbackHwnd = [KanaAI.DesktopValidation.Native]::CreateLoopbackWindow(('KanaAI injector loopback ' + $runId), 520, 160)
                Write-KanaAiValidationTrace -Stage 'native-call-leave' -Detail 'CreateLoopbackWindow'
                Write-KanaAiValidationTrace -Stage 'native-call-enter' -Detail 'GetLoopbackEditHwnd'
                $loopbackEditHwnd = [KanaAI.DesktopValidation.Native]::GetLoopbackEditHwnd()
                Write-KanaAiValidationTrace -Stage 'native-call-leave' -Detail 'GetLoopbackEditHwnd'
                $script:LoopbackHwnd = $loopbackHwnd
                $receipt['desktopInteraction']['windowsCreated'] = [int]$receipt['desktopInteraction']['windowsCreated'] + 1
                if ($loopbackHwnd -eq 0) {
                    $blockedReason = 'the harness could not create its own loopback window'
                    $executed = $false
                    $observation = [ordered]@{ available = $false }
                }
                else {
                    [void](Add-KanaAiValidationLedgerEntry -LedgerRef $script:LedgerRef -Kind 'window' -Id 'probehost-loopback' -Identity 'class:KanaAIValidationLoopbackClass' -Note 'created by the harness in the injector process')
                    Save-Ledger
                    Write-KanaAiValidationTrace -Stage 'native-call-enter' -Detail 'GetLoopbackText#before'
                    $before = [KanaAI.DesktopValidation.Native]::GetLoopbackText()
                    Write-KanaAiValidationTrace -Stage 'native-call-leave' -Detail 'GetLoopbackText#before'
                    Write-KanaAiValidationTrace -Stage 'native-call-enter' -Detail 'ShowLoopbackAndFocusEdit'
                    $focused = [KanaAI.DesktopValidation.Native]::ShowLoopbackAndFocusEdit()
                    Write-KanaAiValidationTrace -Stage 'native-call-leave' -Detail ('ShowLoopbackAndFocusEdit foreground=' + $focused)
                    if ($textMode -eq 'unicode') {
                        Write-KanaAiValidationTrace -Stage 'native-call-enter' -Detail 'SendTextAsUnicode'
                        $apiResults = ConvertTo-ApiResultRecord -Outcomes ([KanaAI.DesktopValidation.Native]::SendTextAsUnicode($canaryRomaji, $interKeyDelay))
                        Write-KanaAiValidationTrace -Stage 'native-call-leave' -Detail 'SendTextAsUnicode'
                    }
                    else {
                        Write-KanaAiValidationTrace -Stage 'native-call-enter' -Detail ('SendKeySequence tokens=' + @($canaryTokens).Count + ' delayMs=' + $interKeyDelay + ' scanCode=' + $scanCode)
                        $apiResults = ConvertTo-ApiResultRecord -Outcomes ([KanaAI.DesktopValidation.Native]::SendKeySequence($canaryTokens, $interKeyDelay, $scanCode))
                        Write-KanaAiValidationTrace -Stage 'native-call-leave' -Detail 'SendKeySequence'
                    }
                    $injectedKeyCount += @($apiResults).Count
                    $receipt['desktopInteraction']['keystrokesInjected'] = $injectedKeyCount
                    Write-KanaAiValidationTrace -Stage 'native-call-enter' -Detail ('PumpMessages settleMs=' + $settle)
                    [void][KanaAI.DesktopValidation.Native]::PumpMessages($settle)
                    Write-KanaAiValidationTrace -Stage 'native-call-leave' -Detail 'PumpMessages'
                    Write-KanaAiValidationTrace -Stage 'native-call-enter' -Detail 'GetLoopbackText#after'
                    $after = [KanaAI.DesktopValidation.Native]::GetLoopbackText()
                    Write-KanaAiValidationTrace -Stage 'native-call-leave' -Detail 'GetLoopbackText#after'
                    $observation = New-KanaAiValidationTextObservation -Text $after -Available $true -RecordText $true -Method 'loopback-own-window'
                    $readbackDetail = [ordered]@{
                        before               = New-KanaAiValidationTextObservation -Text $before -Available $true -RecordText $true -Method 'loopback-own-window'
                        loopbackIsForeground = $focused
                        note                 = 'The canary was typed into a window this harness created and read back with a window message. Nothing in this readback shares a code path with the injection API, which is what makes it evidence rather than an echo.'
                    }
                    $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed $after -Available $true
                    $booleanObservation = $comparison.Match
                    $reason = $comparison.Reason
                }
            }

            'launch-target' {
                if ($Target -ne 'probehost') {
                    $blockedReason = ("the '{0}' target profile is declared by the plan but this harness run does not implement it; the harness will not attach to an application it did not launch" -f $Target)
                    $observation = [ordered]@{ available = $false }
                }
                else {
                    $state = Start-ProbeHost
                    $targetHwnd = [int64](Get-KanaAiValidationProperty -Object $state -Name 'hwnd')
                    $targetEditHwnd = [int64](Get-KanaAiValidationProperty -Object $state -Name 'editHwnd')
                    $script:TargetPid = [int](Get-KanaAiValidationProperty -Object $state -Name 'processId')
                    $targetPid = $script:TargetPid
                    $targetThreadId = [uint32](Get-KanaAiValidationProperty -Object $state -Name 'threadId')
                    $startedUtc = 'unavailable'
                    try { $startedUtc = $script:ProbeHostProcess.StartTime.ToUniversalTime().ToString('o') } catch { }
                    [void](Add-KanaAiValidationLedgerEntry -LedgerRef $script:LedgerRef -Kind 'process' -Id ('probehost-' + $targetPid) -Identity ('pid:' + $targetPid + '|startUtc:' + $startedUtc + '|exe:' + $script:ProbeHostExePath) -Note 'launched by this harness')
                    Save-Ledger
                    $receipt['desktopInteraction']['processesLaunched'] = [int]$receipt['desktopInteraction']['processesLaunched'] + 1
                    $observation = [ordered]@{
                        available   = $true
                        processId   = $targetPid
                        threadId    = [int]$targetThreadId
                        hwnd        = ('0x{0:X}' -f $targetHwnd)
                        editHwnd    = ('0x{0:X}' -f $targetEditHwnd)
                        windowClass = [string](Get-KanaAiValidationProperty -Object $state -Name 'windowClass')
                        startedAtUtc = $startedUtc
                        identifiedBy = 'the target reported its own window handle and class in a state file, so the harness identified it from the target own account rather than by guessing from a title'
                    }
                    $booleanObservation = ($targetHwnd -ne 0) -and ([KanaAI.DesktopValidation.Native]::IsWindowAlive($targetHwnd))
                    $reason = if ($booleanObservation) { 'the target is running and its window answers' } else { 'the target did not report a live window' }
                }
            }

            'focus-target' {
                if ($focusTo -eq 'loopback') {
                    $requested = [KanaAI.DesktopValidation.Native]::ShowLoopbackAndFocusEdit()
                }
                else {
                    $requested = [KanaAI.DesktopValidation.Native]::ForceForeground($targetHwnd, 400)
                }
                $foreground = [KanaAI.DesktopValidation.Native]::GetForegroundRecord()
                $observation = [ordered]@{
                    available         = $true
                    focusTo           = $focusTo
                    requestedSuccess  = $requested
                    foregroundHwnd    = ('0x{0:X}' -f [long]$foreground.Hwnd)
                    foregroundPid     = [int]$foreground.ProcessId
                    foregroundClass   = [string]$foreground.ClassName
                    injectorPid       = [KanaAI.DesktopValidation.Native]::CapturePreflight().ProcessId
                    targetPid         = $targetPid
                }
                if ($focusTo -eq 'loopback') {
                    $booleanObservation = ($requested -and ([int]$foreground.ProcessId -eq [int]$observation['injectorPid']))
                    $reason = if ($booleanObservation) { 'the foreground window now belongs to the harness injector process' } else { ('focus stayed on pid {0}' -f [int]$foreground.ProcessId) }
                }
                else {
                    $booleanObservation = ($requested -and ([int]$foreground.ProcessId -eq $targetPid))
                    $reason = if ($booleanObservation) { 'the foreground window belongs to the target process' } else { ('the foreground window is pid {0}, not the target pid {1}' -f [int]$foreground.ProcessId, $targetPid) }
                }
            }

            'type-text' {
                $before = Read-TargetTextNow
                if ($textMode -eq 'unicode') {
                    $apiResults = ConvertTo-ApiResultRecord -Outcomes ([KanaAI.DesktopValidation.Native]::SendTextAsUnicode($canaryRomaji, $interKeyDelay))
                }
                else {
                    $apiResults = ConvertTo-ApiResultRecord -Outcomes ([KanaAI.DesktopValidation.Native]::SendKeySequence($canaryTokens, $interKeyDelay, $scanCode))
                }
                $injectedKeyCount += @($apiResults).Count
                $receipt['desktopInteraction']['keystrokesInjected'] = $injectedKeyCount
                Start-Sleep -Milliseconds $settle
                $readback = Read-TargetTextNow
                $readbackDetail = $readback
                $observation = $readback['observation']
                # Typing leaves kana in the composition, not the document, so the
                # target's own preedit is the observation that can see it. CAL-02
                # and CAL-06 were "record_only" precisely because the document
                # could not witness this step; with the preedit readback they no
                # longer have to be blind, and the receipt says which channel
                # answered.
                $imeAfter = Get-TargetImeObservation
                $preedit = [string]$imeAfter['preedit']
                $imeReadable = [bool]$imeAfter['available']
                $source = 'committed-document'
                $observedValue = [string]$readback['rawText']
                if ($imeReadable -and (-not [string]::IsNullOrEmpty($preedit))) {
                    $source = 'target-preedit'
                    $observedValue = $preedit
                }
                $observation['textObservation'] = [ordered]@{
                    source            = $source
                    committedBefore   = [string]$before['rawText']
                    committedAfter    = [string]$readback['rawText']
                    preedit           = $preedit
                    preeditReading    = [string]$imeAfter['preeditReading']
                    imeReadback       = $imeAfter
                }
                $reason = ('the observation came from ' + $source + '; {0} independent document channel(s) answered' -f $readback['availableTextCount'])
                $evidence = @()
                if ($imeReadable) { $evidence += ('the target answered its own IME readback (sources: ' + (@($imeAfter['readbackSources']) -join ',') + ')') }
                if ([bool]$readback['observation']['available'] -and -not [string]::IsNullOrEmpty([string]$readback['rawText'])) {
                    $evidence += 'the document holds committed text'
                }
                $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed $observedValue -Available ([bool]$readback['observation']['available']) -Predicate $predicate -AllowVacuousEmptyMatch:($evidence.Count -gt 0) -ObservedSource ($evidence -join '; ')
                $booleanObservation = $comparison.Match
                $reason = $comparison.Reason + ('; the observation came from ' + $source)
            }

            'press-key' {
                $chords = @()
                $useCalibratedToggles = ($null -ne $imeSetup) -and ((Get-KanaAiValidationStringProperty -Object $imeSetup -Name 'targetState' -Default '') -eq 'on')
                if ($useCalibratedToggles) {
                    $toggles = [int]$imeCalibration['togglesNeededToReachOn']
                    for ($t = 0; $t -lt $toggles; $t++) { $chords += , @('VK_CONTROL', 'VK_SPACE') }
                    if ($toggles -eq 0) { $reason = 'the calibrated direction was already IME-on, so this step deliberately injects no toggle key' }
                }
                elseif ($chord -and $keys.Count -gt 1) {
                    $chords += , $keys
                }
                else {
                    for ($r = 0; $r -lt $repeat; $r++) { $chords += , $keys }
                }

                $textBefore = Read-TargetTextNow
                foreach ($keySet in $chords) {
                    if (@($keySet).Count -eq 0) { continue }
                    if (@($keySet).Count -gt 1) { $apiResults += ConvertTo-ApiResultRecord -Outcomes ([KanaAI.DesktopValidation.Native]::SendKeyChord(@($keySet), $interKeyDelay, $scanCode)) }
                    else { $apiResults += ConvertTo-ApiResultRecord -Outcomes ([KanaAI.DesktopValidation.Native]::SendKeySequence(@($keySet), $interKeyDelay, $scanCode)) }
                }
                $injectedKeyCount += @($apiResults).Count
                $receipt['desktopInteraction']['keystrokesInjected'] = $injectedKeyCount
                Start-Sleep -Milliseconds $settle
                $textAfter = Read-TargetTextNow
                $readbackDetail = $textAfter

                switch ($observable) {
                    'candidate-window' {
                        $lastCandidateObservation = Get-CandidateWindowObservation -ProcessId ([uint32]$targetPid) -ClassNames $candidateClassNames
                        $observation = $lastCandidateObservation
                        $windowPresent = [bool]$lastCandidateObservation['present']
                        $textObserved = [bool]$lastCandidateObservation['candidateTextObserved']
                        # "A candidate window exists" and "candidates are
                        # readable" are separate claims. Before the preedit
                        # readback existed, a visible window with unreadable
                        # contents was the only thing obtainable, and a plan
                        # asserting on candidate text matched that observation
                        # without ever seeing a candidate. The plan's expected
                        # value now decides which claim is being made: an
                        # expected string is a claim about contents and cannot
                        # be satisfied by a window; an empty expected value with
                        # no predicate is a claim about windows only, and is
                        # labelled as such in the reason.
                        $claimsContents = ($matchMode -ne 'equals') -or (-not [string]::IsNullOrEmpty($expectedValue)) -or (-not [string]::IsNullOrEmpty($predicate))
                        if ($claimsContents) {
                            $booleanObservation = $textObserved
                            $reason = if ($textObserved) {
                                ('{0} candidate string(s) were read from the target''s own IME context' -f [int]$lastCandidateObservation['candidateCount'])
                            }
                            elseif (-not [bool]$lastCandidateObservation['imeReadbackAvailable']) {
                                ('the step asserts candidate contents, but the target could not read its own IME context: ' + [string]$lastCandidateObservation['imeReadbackReason'])
                            }
                            else {
                                ('the step asserts candidate contents, but the target''s IME holds {0} candidate(s) and none were read, so nothing was compared' -f [int]$lastCandidateObservation['reportedCandidateCount'])
                            }
                        }
                        else {
                            $booleanObservation = $windowPresent
                            $reason = ('{0} visible candidate window(s) of a known IME class belong to the target process; this step asserts only that a window exists, and says nothing about its contents ({1} candidate string(s) were read separately)' -f [int]$lastCandidateObservation['observedWindowCount'], [int]$lastCandidateObservation['candidateCount'])
                        }
                        $observation['claimsCandidateContents'] = $claimsContents
                    }
                    'target-alive' {
                        $alive = [KanaAI.DesktopValidation.Native]::IsWindowAlive($targetHwnd)
                        $booleanObservation = $alive
                        $observation = [ordered]@{ available = $true; targetWindowAlive = $alive; targetPid = $targetPid }
                        $reason = if ($alive) { 'the target window still exists' } else { 'the target window is gone' }
                    }
                    'document-unchanged' {
                        $same = ($textAfter['rawText'] -ceq [string]$baselineText)
                        $booleanObservation = $same
                        $observation = $textAfter['observation']
                        $reason = if ($same) { 'the document returned to the baseline captured before the composition' }
                                  else { 'the document differs from the baseline captured before the composition' }
                    }
                    'document-kana' {
                        # Committed text and the preedit are different facts and
                        # this observable is about kana reaching the composition
                        # at all. With the IME in the on direction, kana sits in
                        # the composition string and nothing is committed until
                        # the operator converts, so reading only the document
                        # could not distinguish "the IME produced kana" from "the
                        # keystrokes never arrived" - both read as an empty
                        # document. The preedit is read from the target itself.
                        $imeAfter = Get-TargetImeObservation
                        $preedit = [string]$imeAfter['preedit']
                        $imeReadable = [bool]$imeAfter['available']
                        $source = 'committed-document'
                        $observedValue = [string]$textAfter['rawText']
                        if ($imeReadable -and (-not [string]::IsNullOrEmpty($preedit))) {
                            $source = 'target-preedit+committed-document'
                            $observedValue = $preedit
                        }
                        $observation = $textAfter['observation']
                        $observation['kanaObservation'] = [ordered]@{
                            source            = $source
                            committedDocument = [string]$textAfter['rawText']
                            preedit           = $preedit
                            preeditReading    = [string]$imeAfter['preeditReading']
                            imeReadback       = $imeAfter
                        }
                        $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed $observedValue -Available ([bool]$textAfter['observation']['available']) -Predicate $predicate
                        $booleanObservation = $comparison.Match
                        $reason = $comparison.Reason + ('; the kana observation came from ' + $source)
                    }
                    'document-ascii' {
                        # ASCII in the IME-on direction also accumulates in the
                        # composition, so the preedit is consulted here for the
                        # same reason. Which of the two strings carried the
                        # observation is recorded, because a kana observable that
                        # actually read the preedit and an ASCII observable that
                        # read the preedit are different claims.
                        $imeAfter = Get-TargetImeObservation
                        $preedit = [string]$imeAfter['preedit']
                        $imeReadable = [bool]$imeAfter['available']
                        $source = 'committed-document'
                        $observedValue = [string]$textAfter['rawText']
                        if ($imeReadable -and (-not [string]::IsNullOrEmpty($preedit))) {
                            $source = 'target-preedit+committed-document'
                            $observedValue = $preedit
                        }
                        $observation = $textAfter['observation']
                        $observation['kanaObservation'] = [ordered]@{
                            source            = $source
                            committedDocument = [string]$textAfter['rawText']
                            preedit           = $preedit
                            preeditReading    = [string]$imeAfter['preeditReading']
                            imeReadback       = $imeAfter
                        }
                        $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed $observedValue -Available ([bool]$textAfter['observation']['available']) -Predicate $predicate
                        $booleanObservation = $comparison.Match
                        $reason = $comparison.Reason + ('; the ASCII observation came from ' + $source)
                    }
                    default {
                        $observation = $textAfter['observation']
                        # The preedit is consulted here too, because in the IME-on
                        # direction a keystroke that produced a composition leaves
                        # the committed document untouched. Treating an unchanged
                        # document as "the key was not delivered" was wrong in that
                        # case, and it was one of the two ways this harness could
                        # declare a live IME dead.
                        $imeAfter = Get-TargetImeObservation
                        $preedit = [string]$imeAfter['preedit']
                        $imeReadable = [bool]$imeAfter['available']
                        $observedValue = [string]$textAfter['rawText']
                        $source = 'committed-document'
                        if ($imeReadable -and (-not [string]::IsNullOrEmpty($preedit))) {
                            $observedValue = $preedit
                            $source = 'target-preedit'
                        }
                        $observation['textObservation'] = [ordered]@{
                            source            = $source
                            committedBefore   = [string]$textBefore['rawText']
                            committedAfter    = [string]$textAfter['rawText']
                            preedit           = $preedit
                            imeReadback       = $imeAfter
                        }
                        # Committed text before/after is the change signal. A
                        # non-empty preedit after the input is itself evidence
                        # that the keys were consumed, so it is folded in
                        # separately rather than compared against a "before"
                        # preedit that was never captured on this path.
                        $changed = ($textBefore['rawText'] -cne [string]$textAfter['rawText']) -or
                                   ($imeReadable -and (-not [string]::IsNullOrEmpty($preedit)))

                        # An equality against the empty string is refused by the
                        # comparison unless a caller can name the positive
                        # readback that makes the emptiness meaningful. This is
                        # the CAL-04/CAL-08 shape: "press backspace twelve times,
                        # the document is now empty". Those steps used to pass on
                        # two empty strings, which is also exactly what a run in
                        # which nothing was ever typed produced.
                        #
                        # Two observations do make the emptiness meaningful, and
                        # both are named so the receipt shows what the pass rested
                        # on: the document held content immediately before the
                        # keys (so the readback demonstrably works and this is a
                        # "cleared" result), or the target answered its own IME
                        # readback (so the target was demonstrably read and holds
                        # nothing). If neither holds, the emptiness carries no
                        # information and the step is reported as unproven.
                        $evidence = @()
                        if ([bool]$textBefore['observation']['available'] -and -not [string]::IsNullOrEmpty([string]$textBefore['rawText'])) {
                            $evidence += ('the document held {0} character(s) immediately before these keys, so an empty result is a clearing rather than an absence' -f [int]$textBefore['observation']['length'])
                        }
                        if ($imeReadable) {
                            $evidence += ('the target answered its own IME readback (sources: ' + (@($imeAfter['readbackSources']) -join ',') + '), so the target was demonstrably read and holds no committed text')
                        }
                        $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed $observedValue -Available ([bool]$textAfter['observation']['available']) -Predicate $predicate -AllowVacuousEmptyMatch:($evidence.Count -gt 0) -ObservedSource ($evidence -join '; ')
                        $booleanObservation = $comparison.Match
                        $reason = $comparison.Reason
                        if ($evidence.Count -gt 0) { $reason = $reason + ('; empty-match evidence: ' + ($evidence -join '; ')) }
                        if ($changed) { $reason = $reason + '; the observed text changed' }
                        else { $reason = $reason + '; the observed text did not change' }
                    }
                }

                # Calibration bookkeeping: whichever direction committed kana is
                # the IME-on direction. Nothing else in the plan assumes it.
                if ($calibrates -and ($observable -eq 'document-kana') -and $booleanObservation) {
                    $imeCalibration['determined'] = $true
                    $imeCalibration['kanaDirectionAtToggleA'] = $true
                    $imeCalibration['togglesNeededToReachOn'] = 0
                    $imeCalibration['note'] = 'the first committed text was kana, so the input processor was already in the IME-on direction before the second toggle'
                }
                if ($calibrates -and ($observable -eq 'document-ascii') -and $booleanObservation -and (-not [bool]$imeCalibration['determined'])) {
                    $imeCalibration['determined'] = $true
                    $imeCalibration['kanaDirectionAtToggleA'] = $false
                    $imeCalibration['togglesNeededToReachOn'] = 1
                    $imeCalibration['note'] = 'the first committed text was not kana and the second was ASCII, so one further toggle is needed to reach the IME-on direction'
                }
                if ($calibrates -and ($observable -eq 'document-ascii') -and (-not $booleanObservation) -and (-not [bool]$imeCalibration['determined'])) {
                    $imeCalibration['note'] = 'the second direction also did not commit the ASCII canary, so the toggle did not change the input processor and the IME-on direction is unknown'
                }
            }

            'observe-candidates' {
                $lastCandidateObservation = Get-CandidateWindowObservation -ProcessId ([uint32]$targetPid) -ClassNames $candidateClassNames
                $observation = $lastCandidateObservation
                $booleanObservation = $true
                $reason = 'observation only; the receipt records the searched class names, the ownership rule and whether any text readback produced candidate content'
            }

            'observe-processes' {
                $lastRuntimeObservation = Get-RuntimeProcessObservation -Names $runtimeProcessNames
                $observation = $lastRuntimeObservation
                $booleanObservation = $true
                $reason = 'observation only; presence or absence of a server or broker process is reported, never asserted'
                # The target's module list is read HERE, while the process is still
                # alive, and cached for the receipt.
                #
                # Measured: reading it at the end of the run, after the cleanup pass
                # had terminated the process, returned
                # `EnumProcessModules error 299 after EnumProcessModulesEx error 87`
                # - 299 is ERROR_PARTIAL_COPY, which is what reading a dead process
                # looks like - with moduleCount 1. That produced
                # `TIP-DLL-NOT-LOADED`, a critical finding asserting the KanaAI TIP
                # "was never the active input processor", on a process that had
                # demonstrably loaded mozc_tip64.dll minutes earlier. Cleanup working
                # correctly turned a measurement into a lie.
                if ($targetPid -ne 0) {
                    try { $lastModules = Get-TargetModuleObservation -ProcessId ([uint32]$targetPid) }
                    catch { $lastModules = $null }
                }
            }

            'close-target' {
                if ($Target -ne 'probehost') {
                    $blockedReason = 'the harness will not close a window it did not open'
                    $observation = [ordered]@{ available = $false }
                }
                else {
                    $closed = $false
                    if ($targetHwnd -ne 0) { $closed = [KanaAI.DesktopValidation.Native]::CloseWindowIfOwned($targetHwnd, $targetClass) }
                    $deadline = (Get-Date).AddSeconds(3)
                    $alive = $true
                    while ((Get-Date) -lt $deadline) {
                        $alive = [KanaAI.DesktopValidation.Native]::IsWindowAlive($targetHwnd)
                        if (-not $alive) { break }
                        Start-Sleep -Milliseconds 100
                    }
                    # The raw observation, not its negation.
                    #
                    # `match: 'false'` asks Compare-KanaAiValidationReadback for the
                    # observation to be false, and it computes that as
                    # `(-not [bool]$BooleanObservation)`. Handing it `(-not $alive)`
                    # applies the expectation twice, so the step's verdict is the
                    # opposite of what it observed.
                    #
                    # Measured, and the two directions both went the wrong way:
                    # RST-01 expects `false` and reported `failed - the target window
                    # is gone` while the window was indeed gone, and CLN-01/CLN-02
                    # expect `false` and reported `passed - the target window survived
                    # cleanup` while the window was still there because cleanup had
                    # never terminated a process. One step failed on a true
                    # observation and two passed on a false one.
                    $booleanObservation = $alive
                    $observation = [ordered]@{
                        available             = $true
                        windowClosedByClassMatch = $closed
                        windowAlive           = $alive
                        requiredClass         = $targetClass
                        note                  = 'A window is closed only when its class name equals the class the harness registered, so this can never reach a window the harness did not create.'
                    }
                    $reason = if ($alive) { 'the target window is still present' } else { 'the target window is gone' }
                    if ($alive) {
                        $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'TARGET-CLOSE-REFUSED' -Severity 'critical' -Message 'The target window did not close. The harness refused to force-kill anything it could not identify as its own.' -Evidence $observation
                    }
                    $targetHwnd = 0
                    $targetEditHwnd = 0
                }
            }

            'cleanup' {
                $pass = Invoke-CleanupPass -Pass 'plan-cleanup'
                $cleanupResults += $pass
                $receipt['cleanup'] = $pass
                $baselineText = ''
                $alive = [KanaAI.DesktopValidation.Native]::IsWindowAlive($targetHwnd)
                # The raw observation, for the same reason as close-target: the
                # plan's `match: 'false'` is applied by the shared tail, so
                # negating here would apply the expectation twice. These two steps
                # passed while the target was still alive and cleanup had done
                # nothing, which is what made that visible.
                $booleanObservation = $alive
                $observation = [ordered]@{
                    available    = $true
                    targetWindowAlive = $alive
                    willMutate   = $pass['plan'].WillMutate
                    alreadyClean = $pass['plan'].AlreadyClean
                    executed     = $pass['executed']
                }
                # The reason states the observation, not the verdict, so it reads the
                # same way whichever way the expectation is written.
                $reason = if ($alive) { 'the target window survived cleanup' } else { 'the target window is gone after cleanup' }
            }

            'wait' {
                Start-Sleep -Milliseconds $settle
                $observation = [ordered]@{ available = $true; waitedMs = $settle }
                $booleanObservation = $true
                $reason = 'waited'
            }

            default {
                $blockedReason = ("the harness has no implementation branch for action '{0}'" -f $action)
                $observation = [ordered]@{ available = $false }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($blockedReason)) {
            $verdict = Resolve-KanaAiValidationStepVerdict -Assertion $assertion -Executed $false -ReadbackAvailable $false -BlockedReason $blockedReason
            $stepResults.Add((New-StepResult -Step $step -Verdict $verdict -MatchMode $matchMode -Reason $blockedReason -Readback $observation -Executed $false))
            # The end line belongs here too, not only on the success and catch
            # paths. Without it a step that was *refused* is indistinguishable in
            # the progress log from a step that *stalled*: both show a start line
            # and no end line. Measured - the first traced run reported twelve
            # consecutive "stalled" steps (ON-00..FOC-04) that were in fact all
            # correctly blocked because the IME direction was never calibrated.
            [Console]::Error.WriteLine(
                "KANAI_DESKTOP_STEP end   id=" + $id + " verdict=" + $verdict +
                " ms=" + [int]([DateTime]::UtcNow - $stepStarted).TotalMilliseconds)
            $receipt['steps'] = $stepResults.ToArray()
            try { [void](Write-KanaAiValidationJson -Path $receiptPath -Value $receipt) } catch { }
            continue
        }

        $readbackAvailable = $true
        $availableFlag = Get-KanaAiValidationProperty -Object $observation -Name 'available'
        if ($null -ne $availableFlag) { $readbackAvailable = [bool]$availableFlag }

        $match = $false
        if ($null -ne $booleanObservation) {
            # A text match mode is decided by the step, against the observation the
            # step actually read. Re-running the comparison here cannot reproduce
            # that answer, because this call is handed an EMPTY observation: the
            # text lives in $observation, which is not passed in. So the empty
            # string was compared against the expected text, the result was false,
            # and it replaced a correct match.
            #
            # Measured: INJ-00 typed the canary into the harness's own window, read
            # back "kanaai" (bytes 6b 61 6e 61 61 69), and was reported failed with
            # the reason "contains" - the reason from the correct first comparison,
            # beside a verdict from the wrong second one. A step that observes a true
            # match and is reported as a failure is not evidence of a product fault;
            # it is the harness losing its own observation. The same path made every
            # text assertion in the plan structurally unable to pass.
            $textMatchModes = @('equals', 'contains', 'not-contains')
            if ($textMatchModes -contains $matchMode) {
                $match = [bool]$booleanObservation
                if ([string]::IsNullOrWhiteSpace($reason)) {
                    $reason = ("the step's own comparison against its own readback reported {0}" -f $match)
                }
            }
            else {
                # true / false / predicate take a boolean as INPUT, so they are
                # only decidable here, and they are decided correctly because they
                # do not read the observation text.
                $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed '' -Available $readbackAvailable -BooleanObservation $booleanObservation -Predicate $predicate
                $match = $comparison.Match
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason = $comparison.Reason }
            }
        }

        $verdict = Resolve-KanaAiValidationStepVerdict -Assertion $assertion -Executed $executed -ReadbackAvailable $readbackAvailable -Match $match -Reason $reason
        $corroboration = $null
        if (($targetPid -ne 0) -and ($targetThreadId -ne 0)) { $corroboration = Get-CorroborationBundle -ThreadId $targetThreadId }
        if ($null -ne $readbackDetail) {
            $corroboration = [ordered]@{
                textChannels = $readbackDetail['channels']
                agree        = $readbackDetail['corroboratingChannels']
                disagree     = $readbackDetail['disagreeingChannels']
                note         = $readbackDetail['note']
            }
            if ($null -eq $corroboration['textChannels']) { $corroboration = $readbackDetail }
        }
        $stepResults.Add((New-StepResult -Step $step -Verdict $verdict -MatchMode $matchMode -Reason $reason -Readback $observation -ApiResults $apiResults -Corroboration $corroboration -Executed $executed))
        # Progress, one line per step, after the step finished. Paired with the
        # "start" line above: a step with a start line and no end line is the step
        # that stalled, and that is answerable from the log alone.
        [Console]::Error.WriteLine(
            "KANAI_DESKTOP_STEP end   id=" + $id + " verdict=" + $verdict +
            " ms=" + [int]([DateTime]::UtcNow - $stepStarted).TotalMilliseconds)
        # And the receipt is rewritten after every step, so a run that dies or
        # stalls leaves behind the steps it did complete. A receipt that only
        # appears on success is a receipt that is absent precisely when it is
        # needed.
        $receipt['steps'] = $stepResults.ToArray()
        $receipt['desktopInteraction']['keystrokesInjected'] = $injectedKeyCount
        $receipt['desktopInteraction']['windowsCreated'] = [int]$receipt['desktopInteraction']['windowsCreated']
        try { [void](Write-KanaAiValidationJson -Path $receiptPath -Value $receipt) } catch { }
    }
    catch {
        $stepResults.Add((New-StepResult -Step $step -Verdict 'failed' -Reason ('harness error while executing the step: ' + $_.Exception.Message)))
        [Console]::Error.WriteLine(
            "KANAI_DESKTOP_STEP end   id=" + $id + " verdict=failed ms=" +
            [int]([DateTime]::UtcNow - $stepStarted).TotalMilliseconds +
            " error=" + $_.Exception.Message)
        $receipt['steps'] = $stepResults.ToArray()
        try { [void](Write-KanaAiValidationJson -Path $receiptPath -Value $receipt) } catch { }
        $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'STEP-EXECUTION-ERROR' -Severity 'critical' -Message ("step {0} raised: {1}" -f $id, $_.Exception.Message)
    }
}

# --- final cleanup pass and post-run observations --------------------------
$finalCleanup = Invoke-CleanupPass -Pass 'final'
$cleanupResults += $finalCleanup
if ($null -eq $receipt['cleanup']) { $receipt['cleanup'] = $finalCleanup }
$receipt['cleanupPasses'] = $cleanupResults
$receipt['imeCalibration'] = $imeCalibration

if (($targetPid -ne 0) -and (Test-Path -LiteralPath $targetStatePath -PathType Leaf)) {
    try {
        $selfReport = Read-KanaAiValidationJson -Path $targetStatePath
        $selfText = [string](Get-KanaAiValidationProperty -Object $selfReport -Name 'textAtPhase')
        # Reuse the reading taken while the target was alive. Reading a terminated
        # process returns ERROR_PARTIAL_COPY and a module count of 1, which says
        # nothing about which modules the process had.
        if ($null -eq $lastModules) {
            try { $lastModules = Get-TargetModuleObservation -ProcessId ([uint32]$targetPid) }
            catch { $lastModules = $null }
        }
        $receipt['targetSelfReport'] = [ordered]@{
            phase        = [string](Get-KanaAiValidationProperty -Object $selfReport -Name 'phase')
            processId    = [int](Get-KanaAiValidationProperty -Object $selfReport -Name 'processId')
            windowClass  = [string](Get-KanaAiValidationProperty -Object $selfReport -Name 'windowClass')
            textLength   = $selfText.Length
            textSha256   = Get-KanaAiValidationTextSha256 -Text $selfText
            containsKana = [regex]::IsMatch($selfText, '[\u3041-\u309F\u30A1-\u30FF]')
            note         = 'Written by the target process itself while it exited. It carries no window message, no UI Automation and no API return value, which makes it the most independent readback in the run.'
        }
        $receipt['targetModules'] = $lastModules
        # A failed enumeration is not evidence of an absent module.
        #
        # This finding was raised from `tipDllLoaded = false` without asking whether
        # the enumeration had worked at all. When cleanup began working and the
        # module list was read from an already-terminated target, the enumeration
        # failed with error 299, the count came back as 1, and the receipt asserted
        # as a critical fact that the KanaAI TIP "was never the active input
        # processor" - about a process that had been observed holding
        # mozc_tip64.dll. An instrument that cannot read must say it could not
        # read; it must never convert "I saw nothing" into "there was nothing".
        $moduleEnumerationFailed = $false
        $moduleErrorText = ''
        if ($null -ne $lastModules) {
            $moduleErrorText = [string](Get-KanaAiValidationProperty -Object $lastModules -Name 'enumerationError' -Default '')
            $moduleEnumerationFailed = (-not [string]::IsNullOrWhiteSpace($moduleErrorText))
        }
        if ($null -eq $lastModules) {
            $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'TARGET-MODULES-UNAVAILABLE' -Severity 'critical' -Message ("The target's module list was never read successfully, so this receipt cannot say whether the KanaAI TIP was loaded. Last enumeration error: '{0}'" -f $moduleErrorText)
        }
        elseif ($moduleEnumerationFailed) {
            $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'TARGET-MODULES-UNAVAILABLE' -Severity 'critical' -Message ("The target's module list could not be read ('{0}'), so this receipt CANNOT say whether the KanaAI TIP was loaded. An unreadable list is not an empty one, and no claim is made about the input processor." -f $moduleErrorText)
        }
        elseif (-not [bool]$lastModules['tipDllLoaded']) {
            $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'TIP-DLL-NOT-LOADED' -Severity 'critical' -Message 'The target module list WAS read successfully and contains no mozc_tip module, so the installed KanaAI TIP was not loaded into the target process. No conversion result in this receipt can be attributed to this product build.' -Evidence $lastModules['kanaAiOrMozcModules']
        }
    }
    catch {
        $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'TARGET-SELF-REPORT-UNREADABLE' -Severity 'critical' -Message $_.Exception.Message
    }
}
if ($null -ne $lastCandidateObservation) { $receipt['candidateWindowObservation'] = $lastCandidateObservation }
if ($null -ne $lastRuntimeObservation) { $receipt['runtimeProcessObservation'] = $lastRuntimeObservation }
if ($AllowScreenshots -and ($targetHwnd -ne 0)) {
    $receipt['screenshots'] = (Save-TargetScreenshot -Hwnd $targetHwnd -Name ('target-' + $runId))
}

# --- verdict ---------------------------------------------------------------
$verdictList = @($stepResults.ToArray() | ForEach-Object { $_['verdict'] })
$receipt['verdictCounts'] = [ordered]@{
    passed               = @($verdictList | Where-Object { $_ -eq 'passed' }).Count
    failed               = @($verdictList | Where-Object { $_ -eq 'failed' }).Count
    delivery_unconfirmed = @($verdictList | Where-Object { $_ -eq 'delivery_unconfirmed' }).Count
    blocked              = @($verdictList | Where-Object { $_ -eq 'blocked' }).Count
    not_run              = @($verdictList | Where-Object { $_ -eq 'not_run' }).Count
    record_only          = @($verdictList | Where-Object { $_ -eq 'record_only' }).Count
}
$receipt['steps'] = $stepResults.ToArray()
$critical = Get-CriticalFindingCount -Receipt $receipt
$overall = Resolve-KanaAiValidationOverallStatus -Results $stepResults -Mode 'run' -CriticalFindings $critical
if ($overall -eq 'passed') {
    $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'SCOPE-LIMIT' -Severity 'info' -Message 'Every asserted step in this plan passed. That covers romaji to kana, conversion display, commit, cancel, a focus round trip, an application restart, and cleanup. It does not cover secure fields, app-container hosts, the handwriting path or the AI ranking path, and no such claim may be made from this receipt.'
}
$receipt['overall'] = $overall
$receipt['exitCode'] = Get-KanaAiValidationExitCodeForStatus -Status $overall

# The privacy invariant, enforced on the actual serialized receipt.
$allowedTexts = @()
if ($recordText) { $allowedTexts += $canaryRomaji; $allowedTexts += $canaryKana }
$sanityJson = ($receipt | ConvertTo-Json -Depth 30)
$sanity = Test-KanaAiValidationReceiptSanity -Json $sanityJson -AllowedTextValues $allowedTexts
$receipt['privacy']['sanity'] = [ordered]@{
    ok       = $sanity.Ok
    problems = $sanity.Problems
    method   = 'scan of the serialized receipt for forbidden keys and forbidden value patterns, with the text-recording policy of this run as the allow list'
}
if (-not $sanity.Ok) {
    $receipt['overall'] = 'failed'
    $receipt['exitCode'] = 1
}

[void](Write-KanaAiValidationJson -Path $planCopyPath -Value ([ordered]@{
        schemaVersion  = Get-KanaAiValidationSchemaVersion
        planId         = [string](Get-KanaAiValidationProperty -Object $planObject -Name 'planId')
        runId          = $runId
        sourcePlan     = Get-RelativeArtifactPath -Path $planPath
        validatedAtUtc = Get-KanaAiValidationUtcNow
        validation     = [ordered]@{ ok = $planValidation.Ok; stepCount = $planValidation.StepCount; errors = $planValidation.Errors; warnings = $planValidation.Warnings }
        plan           = $planObject
    }))
$finalArtifacts = New-Object System.Collections.Generic.List[object]
foreach ($artifact in (ConvertTo-KanaAiValidationArray $receipt['artifacts'])) { [void]$finalArtifacts.Add($artifact) }
[void]$finalArtifacts.Add((New-ArtifactEntry -Path $planCopyPath))
foreach ($shot in $script:Screenshots.ToArray()) {
    if (-not [bool]$shot['captured']) { continue }
    $shotPath = Join-Path $script:CurrentOutputDirectory (([string]$shot['pathRelative']) -replace '^[^/]*/', '')
    if (Test-Path -LiteralPath $shotPath -PathType Leaf) { [void]$finalArtifacts.Add((New-ArtifactEntry -Path $shotPath)) }
}
$receipt['artifacts'] = $finalArtifacts.ToArray()
$receipt['desktopInteraction']['keystrokesInjected'] = $injectedKeyCount
$receipt['completedAtUtc'] = Get-KanaAiValidationUtcNow
[void](Write-KanaAiValidationJson -Path $receiptPath -Value $receipt)

Write-Host ("run {0}: overall={1} exit={2}" -f $runId, $receipt['overall'], $receipt['exitCode'])
foreach ($result in $stepResults.ToArray()) { Write-Host ("  {0,-20} {1,-8} {2}" -f $result['id'], $result['verdict'], $result['reason']) }
foreach ($finding in @($receipt['findings'])) {
    if ([string]$finding['severity'] -ne 'info') { Write-Host ("  finding [{0}] {1}: {2}" -f $finding['severity'], $finding['id'], $finding['message']) }
}
Write-Host ("  receipt: " + (Get-RelativeArtifactPath -Path $receiptPath))
exit ([int]$receipt['exitCode'])
