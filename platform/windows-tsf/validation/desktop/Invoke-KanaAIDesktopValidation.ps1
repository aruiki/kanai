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
$script:LedgerRef = $null
$script:Screenshots = New-Object System.Collections.Generic.List[object]

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

    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        if ($SkipCompile) { throw "Native DLL is missing and -SkipCompile was given: $dll" }
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
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    if ($SkipCompile) { throw "Probe host is missing and -SkipCompile was given: $exe" }
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

    return [ordered]@{
        available               = $true
        present                 = ($ownedByTarget.Count -gt 0)
        observedWindowCount     = $ownedByTarget.Count
        searchedClassNames      = $ClassNames
        windows                 = $matched
        candidateTextReadable   = $readable
        candidateTextChannels   = $textChannels
        statement               = 'Candidate text is recorded only when a readback actually produced it. Mozc and the OS candidate windows normally expose nothing through WM_GETTEXT or UI Automation, and this harness does not guess at their contents.'
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
$gateErrors = @()
if (-not $AllowDesktop) { $gateErrors += 'a real run requires -AllowDesktop' }
if (-not $LockConfirmed) { $gateErrors += 'a real run requires -LockConfirmed, asserting the coordinator granted the go-ahead' }
if ($LockName -ne 'machine') { $gateErrors += "a real run requires -LockName machine, not '$LockName'" }
if (-not $planValidation.Ok) { $gateErrors += ('the plan is invalid: ' + ($planValidation.Errors -join '; ')) }
if (-not $wiring.ok) { $gateErrors += ('the harness wiring is invalid: ' + ($wiring.missing -join '; ')) }
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
    $process = Start-Process -FilePath $script:ProbeHostExePath -ArgumentList @('--state', $targetStatePath, '--runid', $runId) -PassThru
    $script:ProbeHostProcess = $process
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $targetStatePath -PathType Leaf) {
            try {
                $state = Read-KanaAiValidationJson -Path $targetStatePath
                if ([string](Get-KanaAiValidationProperty -Object $state -Name 'phase') -eq 'ready') { return $state }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 200
    }
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
            $target = $null
            try { $target = Get-Process -Id ([int]$script:TargetPid) -ErrorAction Stop } catch { $target = $null }
            if ($null -eq $target) { $entry['outcome'] = 'already gone' }
            else {
                $pathMatches = $false
                try { $pathMatches = ([string]$target.Path -eq [string]$script:ProbeHostExePath) } catch { $pathMatches = $false }
                if (-not $pathMatches) {
                    $entry['outcome'] = 'refused: the live process is not the executable the harness launched, so it was left alone'
                }
                else {
                    $closedWindow = $false
                    if ($script:TargetPid -ne 0 -and $targetHwnd -ne 0) {
                        $closedWindow = [KanaAI.DesktopValidation.Native]::CloseWindowIfOwned($targetHwnd, $targetClass)
                    }
                    $deadline = (Get-Date).AddSeconds(3)
                    while ((Get-Date) -lt $deadline) {
                        try { $target.Refresh() } catch { break }
                        if ($target.HasExited) { break }
                        Start-Sleep -Milliseconds 100
                    }
                    if (-not $target.HasExited) {
                        Stop-Process -Id ([int]$target.Id) -Force -ErrorAction SilentlyContinue
                        $entry['performed'] = $true
                        $entry['outcome'] = 'window closed and the process terminated by pid after its path matched'
                    }
                    else {
                        $entry['performed'] = $closedWindow
                        $entry['outcome'] = 'window closed and the process exited on its own'
                    }
                }
            }
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
                $loopbackHwnd = [KanaAI.DesktopValidation.Native]::CreateLoopbackWindow(('KanaAI injector loopback ' + $runId), 520, 160)
                $loopbackEditHwnd = [KanaAI.DesktopValidation.Native]::GetLoopbackEditHwnd()
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
                    $before = [KanaAI.DesktopValidation.Native]::GetLoopbackText()
                    $focused = [KanaAI.DesktopValidation.Native]::ShowLoopbackAndFocusEdit()
                    if ($textMode -eq 'unicode') {
                        $apiResults = ConvertTo-ApiResultRecord -Outcomes ([KanaAI.DesktopValidation.Native]::SendTextAsUnicode($canaryRomaji, $interKeyDelay))
                    }
                    else {
                        $apiResults = ConvertTo-ApiResultRecord -Outcomes ([KanaAI.DesktopValidation.Native]::SendKeySequence($canaryTokens, $interKeyDelay, $scanCode))
                    }
                    $injectedKeyCount += @($apiResults).Count
                    $receipt['desktopInteraction']['keystrokesInjected'] = $injectedKeyCount
                    [void][KanaAI.DesktopValidation.Native]::PumpMessages($settle)
                    $after = [KanaAI.DesktopValidation.Native]::GetLoopbackText()
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
                $reason = ('document length before {0}, after {1}; {2} independent readback channel(s) answered' -f $readback['observation']['length'], $readback['observation']['length'], $readback['availableTextCount'])
                $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed ([string]$readback['rawText']) -Available ([bool]$readback['observation']['available']) -Predicate $predicate
                $booleanObservation = $comparison.Match
                $reason = $comparison.Reason
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
                        $booleanObservation = [bool]$lastCandidateObservation['present']
                        $reason = if ($booleanObservation) { ('{0} visible candidate window(s) of a known IME class belong to the target process' -f $lastCandidateObservation['observedWindowCount']) }
                                  else { 'no visible top-level window of a known IME class belongs to the target process' }
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
                        $observation = $textAfter['observation']
                        $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed ([string]$textAfter['rawText']) -Available ([bool]$textAfter['observation']['available']) -Predicate $predicate
                        $booleanObservation = $comparison.Match
                        $reason = $comparison.Reason
                    }
                    'document-ascii' {
                        $observation = $textAfter['observation']
                        $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed ([string]$textAfter['rawText']) -Available ([bool]$textAfter['observation']['available']) -Predicate $predicate
                        $booleanObservation = $comparison.Match
                        $reason = $comparison.Reason
                    }
                    default {
                        $observation = $textAfter['observation']
                        $changed = ($textBefore['rawText'] -cne [string]$textAfter['rawText'])
                        $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed ([string]$textAfter['rawText']) -Available ([bool]$textAfter['observation']['available']) -Predicate $predicate
                        $booleanObservation = $comparison.Match
                        $reason = $comparison.Reason
                        if ($changed) { $reason = $reason + '; the document text changed' }
                        elseif ($matchMode -eq 'equals' -and [string]::IsNullOrEmpty($expectedValue)) { $reason = 'the document is still empty, as expected' }
                        else { $reason = $reason + '; the document text did not change at all, which is consistent with the key not being delivered' }
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
                    $booleanObservation = (-not $alive)
                    $observation = [ordered]@{
                        available             = $true
                        windowClosedByClassMatch = $closed
                        windowAlive           = $alive
                        requiredClass         = $targetClass
                        note                  = 'A window is closed only when its class name equals the class the harness registered, so this can never reach a window the harness did not create.'
                    }
                    $reason = if ($booleanObservation) { 'the target window is gone' } else { 'the target window is still present' }
                    if (-not $booleanObservation) {
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
                $booleanObservation = (-not $alive)
                $observation = [ordered]@{
                    available    = $true
                    targetWindowAlive = $alive
                    willMutate   = $pass['plan'].WillMutate
                    alreadyClean = $pass['plan'].AlreadyClean
                    executed     = $pass['executed']
                }
                $reason = if ($booleanObservation) { 'the target window is gone after cleanup' } else { 'the target window survived cleanup' }
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
            continue
        }

        $readbackAvailable = $true
        $availableFlag = Get-KanaAiValidationProperty -Object $observation -Name 'available'
        if ($null -ne $availableFlag) { $readbackAvailable = [bool]$availableFlag }

        $match = $false
        if ($null -ne $booleanObservation) {
            $comparison = Compare-KanaAiValidationReadback -Match $matchMode -Expected $expectedValue -Observed '' -Available $readbackAvailable -BooleanObservation $booleanObservation -Predicate $predicate
            $match = $comparison.Match
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = $comparison.Reason }
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
    }
    catch {
        $stepResults.Add((New-StepResult -Step $step -Verdict 'failed' -Reason ('harness error while executing the step: ' + $_.Exception.Message)))
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
        $lastModules = Get-TargetModuleObservation -ProcessId ([uint32]$targetPid)
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
        if (-not [bool]$lastModules['tipDllLoaded']) {
            $receipt = Add-ReceiptFinding -Receipt $receipt -Id 'TIP-DLL-NOT-LOADED' -Severity 'critical' -Message 'No mozc_tip module was loaded into the target process, so the installed KanaAI TIP was never the active input processor for it. No conversion result in this receipt can be attributed to this product build.' -Evidence $lastModules['kanaAiOrMozcModules']
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
