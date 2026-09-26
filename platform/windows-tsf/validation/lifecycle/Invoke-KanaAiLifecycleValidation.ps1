# KanaAI installer lifecycle verification harness - entry point.
#
# This script performs the product's second verification stage (W2): on a real
# machine, for one fixed-hash candidate, install from Setup.exe and from the MSI,
# observe that the TSF registration is really there, uninstall cleanly, reinstall
# over the same product code, and check the declared upgrade and downgrade
# behaviour.  It emits a JSON receipt and never decides a phase from a command
# exit code alone.
#
# Mode contract, enforced by an early return and by the receipt itself:
#   -PlanOnly   validates the plan, the pinned product identity, the phase
#               ordering and this harness's own comparison and receipt logic
#               using synthetic data, then writes a plan copy and a receipt
#               marked plan-only.  It returns BEFORE any Windows Installer COM
#               object is created, any MSI database is opened, any registry key
#               is read, any process is started and any install or uninstall is
#               attempted.  The action ledger is sealed at the top of this mode
#               and every observation helper throws if it is called.
#   -SelfTest   runs the pure-logic self test: no machine interaction.
#   -Execute    the real lifecycle run.  Refuses to start without operator
#               consent, the machine lock acknowledgement, elevation, and a
#               candidate MSI whose own identity matches the pinned KanaAI
#               identity.  One phase at a time, resumable with -ResumeFrom.
# A mode must be given explicitly.  There is no default, because the default
# must never be a machine-modifying one.
#
# Windows PowerShell 5.1 is the guaranteed host.  This file is ASCII-only.

[CmdletBinding()]
param(
    [switch]$PlanOnly,
    [switch]$SelfTest,
    [switch]$Execute,
    [string]$Plan = '',
    [string]$OutputDirectory = '',
    [string]$ReceiptPath = '',
    [string]$CandidateMsi = '',
    [string]$CandidateSetup = '',
    [string]$CandidateMsiOlder = '',
    [string]$CandidateMsiNewer = '',
    [string]$ResumeFrom = '',
    [string]$PriorReceiptPath = '',
    [switch]$AllowLifecycle,
    [switch]$LockConfirmed,
    [switch]$AllowUnexpectedExistingInstall,
    [switch]$AllowDestructiveRerun,
    [switch]$AllowPreexistingTarget,
    [switch]$SkipHarnessOwnedCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HarnessRoot = $PSScriptRoot
$script:HarnessVersion = '1.0.0'
$script:CommonPath = Join-Path $script:HarnessRoot 'LifecycleValidation.Common.ps1'
$script:SelfTestPath = Join-Path $script:HarnessRoot 'Invoke-KanaAiLifecycleValidationSelfTest.ps1'
$script:DefaultPlanPath = Join-Path $script:HarnessRoot 'lifecycle-validation-plan.json'
$script:RunScriptPath = $PSCommandPath
$script:CurrentOutputDirectory = $null
$script:Findings = New-Object System.Collections.Generic.List[object]

if (-not (Test-Path -LiteralPath $script:CommonPath -PathType Leaf)) {
    Write-Error "Shared helpers are missing: $script:CommonPath"
    exit 4
}
. $script:CommonPath

# The ledger exists from the first line that can create it, and it starts
# SEALED.  A mistake in a mode branch therefore cannot reach the machine before
# the mode branch has decided it is allowed to.  It is created after the shared
# helpers are dot-sourced, because that is where the constructor lives.
$script:Ledger = Close-KanaAiLifecycleActionLedger -Ledger (New-KanaAiLifecycleActionLedger) -Reason 'initialised before the mode was known'

# ---------------------------------------------------------------------------
# static, in-process helpers
# ---------------------------------------------------------------------------
function Test-KanaAiLifecycleHarnessFiles {
    $required = [ordered]@{
        common    = $script:CommonPath
        selfTest  = $script:SelfTestPath
        plan      = $script:DefaultPlanPath
        runScript = $script:RunScriptPath
    }
    $missing = @()
    $described = @()
    foreach ($entry in $required.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) { $missing += $entry.Key }
        # Only a repository-relative name ever reaches the receipt.  An absolute
        # path here would carry the operator's home directory into a shareable
        # artifact, which the privacy scan would then have to reject.
        $described += [ordered]@{ name = [string]$entry.Key; fileName = [System.IO.Path]::GetFileName([string]$entry.Value) }
    }
    return [ordered]@{ ok = ($missing.Count -eq 0); missing = @($missing); files = $described }
}

function Get-KanaAiLifecycleHostEnvironment {
    <#
        Static, read-only description of the host.  Nothing here reads the
        registry, starts a process or mutates anything, which is why it is safe
        in plan-only mode.
    #>
    $isAdministrator = $false
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $isAdministrator = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $isAdministrator = $false }
    $account = ''
    try { $account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $account = '' }
    return [ordered]@{
        osDescription          = [System.Environment]::OSVersion.VersionString
        osVersion              = [System.Environment]::OSVersion.Version.ToString()
        osBuild                = [string][System.Environment]::OSVersion.Version.Build
        osRevision             = [string][System.Environment]::OSVersion.Version.Revision
        is64BitOperatingSystem = [System.Environment]::Is64BitOperatingSystem
        is64BitProcess         = [System.Environment]::Is64BitProcess
        powershellVersion      = [string]$PSVersionTable.PSVersion
        powershellEdition      = [string]$PSVersionTable.PSEdition
        clrVersion             = [string]$PSVersionTable.CLRVersion
        harnessVersion         = $script:HarnessVersion
        account                = $account
        isAdministrator        = $isAdministrator
        elevationState         = if ($isAdministrator) { 'elevated-administrator' } else { 'not-elevated' }
        collectedWithoutMachineMutation = $true
    }
}

function Add-RunFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('info', 'warning', 'critical')][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Message,
        $Evidence = $null
    )
    [void]$script:Findings.Add((New-KanaAiLifecycleFinding -Id $Id -Severity $Severity -Message $Message -Evidence $Evidence))
}

function Get-PhaseLogPath {
    param([Parameter(Mandatory = $true)]$Phase, [Parameter(Mandatory = $true)][string]$OutputRoot)
    $logName = [string](Get-KanaAiLifecycleOptionalProperty -Object (Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'command' -Default $null) -Name 'logFile' -Default '')
    if ([string]::IsNullOrWhiteSpace($logName)) { return '' }
    return (Join-Path $OutputRoot $logName)
}

function Resolve-KanaAiLifecycleCandidatePath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("The candidate does not exist: {0}" -f $Path)
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function New-PhaseResultRecord {
    param(
        [Parameter(Mandatory = $true)]$Phase,
        [Parameter(Mandatory = $true)][string]$Decision,
        [Parameter(Mandatory = $true)][string]$DecisionReason,
        [string]$PriorOutcome = 'not_run'
    )
    return [ordered]@{
        id             = [string](Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'id' -Default '')
        phase          = [string](Get-KanaAiLifecycleProperty -Object $Phase -Name 'name' -Context 'phase')
        title          = [string](Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'title' -Default '')
        destructive    = (Get-KanaAiLifecycleBoolProperty -Object $Phase -Name 'destructive')
        decision       = $Decision
        decisionReason = $DecisionReason
        priorOutcome   = $PriorOutcome
        requires       = @(Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'requires' -Default @())
        preconditions  = @(Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'preconditions' -Default @())
        preconditionResult = $null
        renderedCommand   = $null
        command           = $null
        observation       = $null
        checks            = @()
        outcome           = 'not_run'
        reason            = 'the phase did not run'
        startedAtUtc      = ''
        endedAtUtc        = ''
        proves            = @(Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'proves' -Default @())
        cannotProve       = @(Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'cannotProve' -Default @())
    }
}

# ===========================================================================
# Main
# ===========================================================================
$files = Test-KanaAiLifecycleHarnessFiles
if (-not $files.ok) {
    Write-Error ("Missing harness files: " + ($files.missing -join ', '))
    exit 4
}

$selectedModes = @()
if ($PlanOnly) { $selectedModes += 'plan-only' }
if ($SelfTest) { $selectedModes += 'self-test' }
if ($Execute) { $selectedModes += 'execute' }
if ($selectedModes.Count -ne 1) {
    # Not Write-Error: under $ErrorActionPreference = 'Stop' that would become an
    # unhandled terminating error and report exit 1 instead of the refusal code.
    [Console]::Error.WriteLine('Pass exactly one mode: -PlanOnly, -SelfTest or -Execute. There is no default mode, because the default must never modify the machine.')
    exit 2
}

$planPath = if ([string]::IsNullOrWhiteSpace($Plan)) { $script:DefaultPlanPath } else { [System.IO.Path]::GetFullPath($Plan) }
$planObject = $null
$planValidation = $null
try {
    $planObject = Read-KanaAiLifecycleJson -Path $planPath
    $planValidation = Test-KanaAiLifecyclePlan -Plan $planObject
}
catch {
    Write-Error ("Harness preflight failed: " + $_.Exception.Message)
    exit 4
}

if ($SelfTest) {
    & $script:SelfTestPath
    exit ([int]$LASTEXITCODE)
}

$runId = New-KanaAiLifecycleRunId
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
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $script:HarnessRoot '..\..\..\..'))

$baseReceipt = [ordered]@{
    schemaVersion      = Get-KanaAiLifecycleSchemaVersion
    runId              = $runId
    mode               = $selectedModes[0]
    verificationStage  = 'W2'
    harness            = [ordered]@{
        version            = $script:HarnessVersion
        entryPoint         = (Get-KanaAiLifecycleRepositoryRelativePath -Path $script:RunScriptPath -RepositoryRoot $repositoryRoot)
        plan               = (Get-KanaAiLifecycleRepositoryRelativePath -Path $planPath -RepositoryRoot $repositoryRoot)
        files              = $files.files
        host               = [System.Environment]::OSVersion.VersionString
        powershell         = [string]$PSVersionTable.PSVersion
    }
    startedAtUtc       = Get-KanaAiLifecycleUtcNow
    completedAtUtc     = ''
    environment        = Get-KanaAiLifecycleHostEnvironment
    planValidation     = [ordered]@{
        ok         = [bool]$planValidation.Ok
        phaseCount = [int]$planValidation.PhaseCount
        phaseNames = @($planValidation.PhaseNames)
        phaseIds   = @($planValidation.PhaseIds)
        errors     = @($planValidation.Errors)
        warnings   = @($planValidation.Warnings)
    }
    pinnedIdentity     = Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'pinnedIdentity' -Default $null
    registrationIdentity = Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'registrationIdentity' -Default $null
    candidate          = [ordered]@{}
    candidateIdentity  = $null
    expectedFilePlan   = $null
    safety             = [ordered]@{ gates = @(); decisions = @() }
    machineInteraction = (Get-KanaAiLifecycleInteractionCounters -Ledger $script:Ledger)
    baseline           = $null
    inventory          = [ordered]@{ baseline = $null; final = $null }
    phases             = @()
    artifacts          = @()
    findings           = @()
    scopeLimits        = @(Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'nonGoals' -Default @())
    privacy            = [ordered]@{
        policy         = Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'privacy' -Default $null
        sanity         = $null
    }
    w2                 = [ordered]@{
        planStatus        = [string](Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'w2Status' -Default 'UNVERIFIED')
        planStatusNote    = [string](Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'w2StatusNote' -Default '')
        lifecycleRunCount = 0
        claim             = 'This receipt makes no W2 claim. W2 is UNVERIFIED until an -Execute receipt for one fixed-hash candidate exists.'
    }
    overall            = 'failed'
    exitCode           = 4
}

# --- plan-only -------------------------------------------------------------
# Everything below this banner is pure.  The ledger was already sealed before
# the mode was known; it is re-sealed here with the reason a reviewer can check.
if ($PlanOnly) {
    [void](Close-KanaAiLifecycleActionLedger -Ledger $script:Ledger -Reason 'plan-only mode: no Windows Installer COM object, no MSI database, no registry read, no process launch and no install or uninstall')
    $baseReceipt.machineInteraction = (Get-KanaAiLifecycleInteractionCounters -Ledger $script:Ledger)

    $synthetic = New-KanaAiLifecycleSyntheticSelfCheck
    $baseReceipt.phaseOrder = @(
        Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'phases' -Default @() | ForEach-Object {
            [ordered]@{
                id          = [string](Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'id' -Default '')
                phase       = [string](Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'name' -Default '')
                title       = [string](Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'title' -Default '')
                destructive = (Get-KanaAiLifecycleBoolProperty -Object $_ -Name 'destructive')
                requires    = @(Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'requires' -Default @())
                checks      = @(
                    foreach ($assert in @(Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'asserts' -Default @())) {
                        [ordered]@{
                            check    = [string](Get-KanaAiLifecycleOptionalProperty -Object $assert -Name 'check' -Default '')
                            expect   = [string](Get-KanaAiLifecycleOptionalProperty -Object $assert -Name 'expect' -Default '')
                            required = (Get-KanaAiLifecycleBoolProperty -Object $assert -Name 'required' -Default $true)
                        }
                    }
                )
                command = (Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'command' -Default $null)
            }
        }
    )
    $baseReceipt.commandDryRender = @(
        foreach ($phase in @(Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'phases' -Default @())) {
            $command = Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'command' -Default $null
            if ($null -eq $command) { continue }
            $name = [string](Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'name' -Default '')
            [ordered]@{
                phase   = $name
                rendered = $false
                outcome = 'not-rendered-in-plan-only'
                note    = 'A real render needs the candidate paths, which are operator-supplied per run. Plan-only validates the template shape and that the declared accepted exit codes are a non-empty explicit list.'
                executableTemplate = [string](Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'executable' -Default '')
                argumentTemplates  = @(
                    foreach ($argument in @(Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'arguments' -Default @())) { [string]$argument }
                )
                acceptedExitCodes = [string](Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'acceptedExitCodes' -Default '')
            }
        }
    )
    # The template must at least be well formed here, with placeholder names that
    # are all known, so a typo in a template is caught before a real run.
    $templateProblems = New-Object System.Collections.Generic.List[string]
    $knownPlaceholders = @('msiPath', 'setupPath', 'newerMsiPath', 'olderMsiPath', 'productCode', 'logPath', 'msiexec')
    foreach ($phase in @(Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'phases' -Default @())) {
        $command = Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'command' -Default $null
        if ($null -eq $command) { continue }
        $name = [string](Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'name' -Default '')
        $tokens = @()
        foreach ($text in @([string](Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'executable' -Default '')) +
            @(Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'arguments' -Default @() | ForEach-Object { [string]$_ })) {
            foreach ($match in [System.Text.RegularExpressions.Regex]::Matches([string]$text, '\{([A-Za-z][A-Za-z0-9_]*)\}')) {
                $tokens += $match.Groups[1].Value
            }
        }
        foreach ($token in @($tokens | Select-Object -Unique)) {
            if ($knownPlaceholders -notcontains $token) { $templateProblems.Add(("phase '{0}' uses unknown placeholder '{1}'" -f $name, $token)) }
        }
        $accepted = [string](Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'acceptedExitCodes' -Default '')
        if ($accepted -notmatch '^\d+(,\d+)*$') { $templateProblems.Add(("phase '{0}' has a malformed accepted exit code list '{1}'" -f $name, $accepted)) }
    }
    $baseReceipt.commandDryRenderProblems = @($templateProblems.ToArray())

    $baseReceipt.syntheticSelfCheck = $synthetic
    $baseReceipt.candidate = [ordered]@{
        msi    = $null
        setup  = $null
        older  = $null
        newer  = $null
        note   = 'plan-only mode reads no candidate, because reading one means opening an MSI database through the Windows Installer automation interface.'
    }
    $baseReceipt.w2.claim = 'plan-only mode. No install, uninstall, registry read or process launch was performed, so this receipt proves nothing about the candidate. W2 remains UNVERIFIED.'
    Add-RunFinding -Id 'W2-UNVERIFIED' -Severity 'warning' -Message 'No lifecycle run has been performed. W2 is UNVERIFIED. This receipt validates the plan and this harness only.' -Evidence ([string](Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'w2StatusNote' -Default ''))
    if ($templateProblems.Count -gt 0) {
        Add-RunFinding -Id 'PLAN-TEMPLATE' -Severity 'critical' -Message 'A command template in the plan is malformed.' -Evidence @($templateProblems.ToArray())
    }

    $planCopy = [ordered]@{
        schemaVersion  = Get-KanaAiLifecycleSchemaVersion
        planId         = [string](Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'planId' -Default '')
        runId          = $runId
        sourcePlan     = (Get-KanaAiLifecycleRepositoryRelativePath -Path $planPath -RepositoryRoot $repositoryRoot)
        mode           = 'plan-only'
        validatedAtUtc = Get-KanaAiLifecycleUtcNow
        validation     = $baseReceipt.planValidation
        phaseOrder     = $baseReceipt.phaseOrder
        commandDryRender = $baseReceipt.commandDryRender
        plan           = $planObject
    }
    [void](Write-KanaAiLifecycleJson -Path $planCopyPath -Value $planCopy)
    $artifacts = @((New-KanaAiLifecycleArtifactEntry -Path $planCopyPath -Root $script:CurrentOutputDirectory -Role 'validated-plan-copy'))
    $artifacts += New-KanaAiLifecycleArtifactEntry -Path $planPath -Root $script:CurrentOutputDirectory -Role 'source-plan'
    $baseReceipt.artifacts = $artifacts
    $baseReceipt.findings = @($script:Findings.ToArray())
    $baseReceipt.overall = if ($planValidation.Ok -and $templateProblems.Count -eq 0 -and [bool]$synthetic.ok) { 'plan_only' } else { 'failed' }
    $baseReceipt.exitCode = Get-KanaAiLifecycleExitCodeForStatus -Status $baseReceipt.overall
    $baseReceipt.completedAtUtc = Get-KanaAiLifecycleUtcNow

    $sanitySubject = New-KanaAiLifecycleSanitySubject -Receipt $baseReceipt -Exclude @('privacy')
    $sanityJson = ($sanitySubject.subject | ConvertTo-Json -Depth 40)
    $sanity = Test-KanaAiLifecycleReceiptSanity -Json $sanityJson
    $baseReceipt.privacy.sanity = [ordered]@{
        ok                     = [bool]$sanity.ok
        problems               = @($sanity.problems)
        method                 = $sanity.method
        excludedTopLevelFields = @($sanitySubject.excluded)
        excludedReason         = "the plan's own privacy policy names the categories it never collects, so quoting it verbatim would always trip the scan. The excluded field is recorded here with the SHA-256 of its text."
        policyTextSha256       = (Get-KanaAiLifecycleTextSha256 -Text (($baseReceipt.privacy.policy | ConvertTo-Json -Depth 20)))
    }
    if (-not $sanity.ok) {
        $baseReceipt.overall = 'failed'
        $baseReceipt.exitCode = 1
    }
    [void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $baseReceipt)

    Write-Host ("plan-only: plan '{0}' with {1} phases validated; ledger sealed ({2})" -f [string](Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'planId' -Default ''), $planValidation.PhaseCount, $script:Ledger.SealedReason)
    Write-Host ("  machine interaction counters: {0}" -f (($baseReceipt.machineInteraction.GetEnumerator() | Where-Object { $_.Key -notmatch '^gate' } | ForEach-Object { $_.Key + '=' + $_.Value }) -join ' '))
    Write-Host ("  synthetic self check: {0}" -f [string]$synthetic.ok)
    foreach ($warning in @($planValidation.Warnings)) { Write-Host ('  warning: ' + $warning) }
    foreach ($problem in @($templateProblems)) { Write-Host ('  error: ' + $problem) }
    if (-not $planValidation.Ok) {
        foreach ($item in $planValidation.Errors) { Write-Host ('  error: ' + $item) }
        exit 1
    }
    if (-not $sanity.ok) {
        foreach ($item in $sanity.problems) { Write-Host ('  error: ' + $item) }
        exit 1
    }
    Write-Host ('  receipt: ' + (Get-KanaAiLifecycleRepositoryRelativePath -Path $receiptPath -RepositoryRoot $repositoryRoot))
    exit 0
}

# ===========================================================================
# -Execute: the real lifecycle run.  The coordinator runs this after notifying
# the user.  Nothing below has been executed as part of preparing this harness.
# ===========================================================================
if ($WhatIfPreference) {
    $baseReceipt.mode = 'execute-whatif'
}

# --- gates ----------------------------------------------------------------
$gateReport = New-Object System.Collections.Generic.List[object]
$gateRefusals = New-Object System.Collections.Generic.List[string]

function Add-Gate {
    param([string]$Id, [string]$Rule, [bool]$Satisfied, [string]$Detail)
    [void]$gateReport.Add([ordered]@{ id = $Id; rule = $Rule; satisfied = $Satisfied; detail = $Detail })
    if (-not $Satisfied) { [void]$gateRefusals.Add(("gate '{0}': {1}" -f $Id, $Detail)) }
}

$consent = [bool]$AllowLifecycle
Add-Gate -Id 'consent' -Rule 'operator consent' -Satisfied $consent -Detail $(if ($consent) { '-AllowLifecycle was passed' } else { '-AllowLifecycle was not passed; this run installs, uninstalls and re-registers a per-machine TSF' })
$lock = [bool]$LockConfirmed
Add-Gate -Id 'machine-lock' -Rule 'machine lock acknowledgement' -Satisfied $lock -Detail $(if ($lock) { '-LockConfirmed was passed; the coordinator holds the machine lock' } else { '-LockConfirmed was not passed; docs/PARALLEL_DEVELOPMENT.md reserves real machine install and uninstall for one holder of the machine lock' })

$environment = Get-KanaAiLifecycleHostEnvironment
$elevated = [bool]$environment.isAdministrator
Add-Gate -Id 'elevation' -Rule 'elevated 64-bit PowerShell' -Satisfied ($elevated -and [bool]$environment.is64BitOperatingSystem -and [bool]$environment.is64BitProcess) -Detail ("account='{0}', isAdministrator={1}, is64BitOperatingSystem={2}, is64BitProcess={3}" -f $environment.account, $environment.isAdministrator, $environment.is64BitOperatingSystem, $environment.is64BitProcess)
$baseReceipt.safety.gates = @($gateReport.ToArray())

if ($gateRefusals.Count -gt 0) {
    foreach ($refusal in $gateRefusals) {
        Write-Host ('  REFUSED: ' + $refusal)
        Add-RunFinding -Id 'GATE-REFUSED' -Severity 'critical' -Message $refusal
    }
    $baseReceipt.safety.decisions = @($gateRefusals.ToArray())
    $baseReceipt.overall = 'refused'
    $baseReceipt.exitCode = Get-KanaAiLifecycleExitCodeForStatus -Status 'refused'
    $baseReceipt.completedAtUtc = Get-KanaAiLifecycleUtcNow
    $baseReceipt.findings = @($script:Findings.ToArray())
    $baseReceipt.artifacts = @((New-KanaAiLifecycleArtifactEntry -Path $planCopyPath -Root $script:CurrentOutputDirectory -Role 'validated-plan-copy'))
    [void](Write-KanaAiLifecycleJson -Path $planCopyPath -Value ([ordered]@{
            schemaVersion = Get-KanaAiLifecycleSchemaVersion
            planId        = [string](Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'planId' -Default '')
            runId         = $runId
            sourcePlan    = (Get-KanaAiLifecycleRepositoryRelativePath -Path $planPath -RepositoryRoot $repositoryRoot)
            mode          = 'refused'
            validatedAtUtc = Get-KanaAiLifecycleUtcNow
            validation    = $baseReceipt.planValidation
            plan          = $planObject
        }))
    [void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $baseReceipt)
    Write-Host 'refused: no machine state was touched.'
    exit 2
}

# From here on the machine may be observed and modified.  Unseal the ledger.
# This must be Open-, not Close-: Close- sets Sealed = $true, and a measured run
# sealed itself here and was then refused by its own gate on the next helper.
$script:Ledger = Open-KanaAiLifecycleActionLedger -Ledger $script:Ledger -Reason 'unsealed by -Execute after every gate passed'

$msiPath = ''
$setupPath = ''
$olderMsiPath = ''
$newerMsiPath = ''
$identity = $null
$filePlan = $null
$expectedInstallPath = ''
$resolveFailures = New-Object System.Collections.Generic.List[string]
foreach ($pair in @(
        [pscustomobject]@{ Label = '-CandidateMsi'; Value = $CandidateMsi; Target = 'msi' },
        [pscustomobject]@{ Label = '-CandidateSetup'; Value = $CandidateSetup; Target = 'setup' },
        [pscustomobject]@{ Label = '-CandidateMsiOlder'; Value = $CandidateMsiOlder; Target = 'older' },
        [pscustomobject]@{ Label = '-CandidateMsiNewer'; Value = $CandidateMsiNewer; Target = 'newer' }
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$pair.Value)) { continue }
    try {
        $resolved = Resolve-KanaAiLifecycleCandidatePath -Path ([string]$pair.Value)
        switch ([string]$pair.Target) {
            'msi' { $msiPath = $resolved }
            'setup' { $setupPath = $resolved }
            'older' { $olderMsiPath = $resolved }
            'newer' { $newerMsiPath = $resolved }
        }
    }
    catch {
        [void]$resolveFailures.Add(("{0}: {1}" -f $pair.Label, $_.Exception.Message))
    }
}
if ([string]::IsNullOrWhiteSpace($msiPath)) { [void]$resolveFailures.Add('-CandidateMsi is required: it is the one fixed-hash candidate this run verifies.') }

function New-CandidateRecord {
    param([string]$Path, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $record = [ordered]@{
        label       = $Label
        leafName    = [System.IO.Path]::GetFileName($Path)
        pathRelative = (Get-KanaAiLifecycleRepositoryRelativePath -Path $Path -RepositoryRoot $repositoryRoot)
        bytes       = 0
        sha256      = ''
        absolutePathRecorded = $false
        note        = 'The absolute path is deliberately not recorded: the receipt is a shareable artifact and the digest identifies the candidate unambiguously.'
    }
    try {
        $record.bytes = [int64]([System.IO.FileInfo]$Path).Length
        $record.sha256 = Get-KanaAiLifecycleSha256 -Path $Path
    }
    catch { $record.note = $record.note + ' The candidate could not be hashed: ' + $_.Exception.Message }
    return $record
}

$baseReceipt.candidate = [ordered]@{
    msi   = (New-CandidateRecord -Path $msiPath -Label 'candidate MSI (the fixed-hash candidate of this run)')
    setup = (New-CandidateRecord -Path $setupPath -Label 'Setup.exe launcher for the same candidate')
    older = (New-CandidateRecord -Path $olderMsiPath -Label 'optional older MSI for the downgrade phase')
    newer = (New-CandidateRecord -Path $newerMsiPath -Label 'optional newer MSI for the forward upgrade phase')
    resolveFailures = @($resolveFailures.ToArray())
}

if ($resolveFailures.Count -gt 0) {
    foreach ($failure in $resolveFailures) {
        Write-Host ('  REFUSED: ' + $failure)
        Add-RunFinding -Id 'CANDIDATE-MISSING' -Severity 'critical' -Message $failure
    }
    $baseReceipt.safety.decisions = @($resolveFailures.ToArray())
    $baseReceipt.overall = 'refused'
    $baseReceipt.exitCode = Get-KanaAiLifecycleExitCodeForStatus -Status 'refused'
    $baseReceipt.completedAtUtc = Get-KanaAiLifecycleUtcNow
    $baseReceipt.findings = @($script:Findings.ToArray())
    [void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $baseReceipt)
    Write-Host 'refused: the candidate could not be resolved, so no MSI database was opened.'
    exit 2
}

# --- candidate identity, read from the MSI itself --------------------------
$pinnedIdentity = Get-KanaAiLifecycleProperty -Object $planObject -Name 'pinnedIdentity' -Context 'plan'
$registrationIdentity = Get-KanaAiLifecycleProperty -Object $planObject -Name 'registrationIdentity' -Context 'plan'
$installFolderId = [string](Get-KanaAiLifecycleProperty -Object (Get-KanaAiLifecycleProperty -Object $pinnedIdentity -Name 'installFolder' -Context 'pinned identity') -Name 'directoryId' -Context 'pinned install folder')

try {
    $propertyMap = Get-KanaAiLifecycleMsiPropertyMap -Ledger $script:Ledger -Path $msiPath
    $templatePlatform = Get-KanaAiLifecycleMsiTemplatePlatform -Ledger $script:Ledger -Path $msiPath
    $identity = Test-KanaAiLifecycleCandidateIdentity -PropertyMap $propertyMap -TemplatePlatform $templatePlatform -Pinned $pinnedIdentity
    $baseReceipt.candidateIdentity = $identity
}
catch {
    $failure = "The candidate MSI could not be read through the Windows Installer automation interface: $($_.Exception.Message)"
    Write-Host ('  REFUSED: ' + $failure)
    Add-RunFinding -Id 'CANDIDATE-UNREADABLE' -Severity 'critical' -Message $failure
    $baseReceipt.overall = 'refused'
    $baseReceipt.exitCode = Get-KanaAiLifecycleExitCodeForStatus -Status 'refused'
    $baseReceipt.completedAtUtc = Get-KanaAiLifecycleUtcNow
    $baseReceipt.findings = @($script:Findings.ToArray())
    [void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $baseReceipt)
    exit 2
}

if (-not $identity.Ok) {
    foreach ($errorText in $identity.Errors) {
        Write-Host ('  REFUSED: ' + $errorText)
        Add-RunFinding -Id 'CANDIDATE-IDENTITY' -Severity 'critical' -Message $errorText
    }
    $baseReceipt.overall = 'refused'
    $baseReceipt.exitCode = Get-KanaAiLifecycleExitCodeForStatus -Status 'refused'
    $baseReceipt.completedAtUtc = Get-KanaAiLifecycleUtcNow
    $baseReceipt.findings = @($script:Findings.ToArray())
    [void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $baseReceipt)
    Write-Host 'refused: the target is not the expected KanaAI MSI. Nothing was installed, uninstalled or written.'
    exit 2
}
Add-RunFinding -Id 'CANDIDATE-ACCEPTED' -Severity 'info' -Message ("Candidate accepted: ProductCode {0}, ProductVersion {1}, UpgradeCode {2}, template '{3}', SHA-256 {4}" -f $identity.ProductCode, $identity.ProductVersion, $identity.UpgradeCode, $identity.TemplatePlatform, [string]$baseReceipt.candidate.msi.sha256)

# --- what is already on this machine ---------------------------------------
$existingProducts = Find-KanaAiLifecycleInstalledProducts -Ledger $script:Ledger -UpgradeCode $identity.UpgradeCode
$targetState = Get-KanaAiLifecycleProductState -Ledger $script:Ledger -ProductCode $identity.ProductCode
# The harness may only reason about a machine whose installer answers.  Both
# Installer.ProductInfo('InstallState') and MsiQueryProductState refuse on a
# machine whose per-machine component registration is missing, and 'unknown'
# is not evidence of absence: it is the absence of evidence.  Measured on the
# development machine, the query returned ERROR_ACCESS_DENIED for every valid
# product code, elevated and unelevated and across three P/Invoke variants,
# while an invalid product name returned -1 and an empty GUID returned -2, so
# the call dispatched correctly and the installer declined to answer.  If that
# state were carried on, the target check below would not fire, the
# ^(DEFAULT|LOCAL)$ filter in the later phases would match nothing, and every
# phase would report an installed product as absent.  Refusing is the only
# honest outcome, and it is the same rule the helper's own contract states:
# unknown is never treated as absent.
$undeterminedState = @($existingProducts.found | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.installState) })
if ($targetState -eq 'unknown' -or $undeterminedState.Count -gt 0) {
    $failure = ("The Windows Installer did not report an install state on this machine: candidate state '{0}', {1} product(s) sharing the pinned UpgradeCode returned no state. An unanswered state is not an absent state, so the clean-install baseline cannot be established and no phase may run. Repair the machine's per-machine installer registration, or run this gate on a machine whose installer answers." -f $targetState, $undeterminedState.Count)
    Write-Host ('  REFUSED: ' + $failure)
    Add-RunFinding -Id 'INSTALL-STATE-UNDETERMINED' -Severity 'critical' -Message $failure -Evidence $existingProducts.found
    $baseReceipt.overall = 'refused'
    $baseReceipt.exitCode = Get-KanaAiLifecycleExitCodeForStatus -Status 'refused'
    $baseReceipt.completedAtUtc = Get-KanaAiLifecycleUtcNow
    $baseReceipt.findings = @($script:Findings.ToArray())
    $baseReceipt.baseline = [ordered]@{
        existingKanaAiProducts = $existingProducts
        targetProductState     = $targetState
        undeterminedStates     = @($undeterminedState | ForEach-Object { [string]$_.productCode })
        note                   = 'No install, uninstall, reinstall or rollback was attempted. The observation could not be completed, so nothing was changed.'
    }
    [void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $baseReceipt)
    exit 2
}
$unexpectedPresent = @($existingProducts.found | Where-Object { $_ -ne $identity.ProductCode })
if ($existingProducts.count -gt 0 -and -not $AllowUnexpectedExistingInstall -and $unexpectedPresent.Count -gt 0) {
    $failure = ("{0} product(s) sharing the pinned KanaAI UpgradeCode are already installed on this machine and -AllowUnexpectedExistingInstall was not passed. This harness will not uninstall or overwrite machine state it did not create." -f $unexpectedPresent.Count)
    Write-Host ('  REFUSED: ' + $failure)
    Add-RunFinding -Id 'UNEXPECTED-EXISTING-INSTALL' -Severity 'critical' -Message $failure -Evidence $unexpectedPresent
    $baseReceipt.overall = 'refused'
    $baseReceipt.exitCode = Get-KanaAiLifecycleExitCodeForStatus -Status 'refused'
    $baseReceipt.completedAtUtc = Get-KanaAiLifecycleUtcNow
    $baseReceipt.findings = @($script:Findings.ToArray())
    $baseReceipt.baseline = [ordered]@{
        existingKanaAiProducts = $existingProducts
        targetProductState     = $targetState
        unexpectedProducts     = $unexpectedPresent
    }
    [void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $baseReceipt)
    exit 2
}
if ($targetState -eq 'installed' -and -not $AllowPreexistingTarget) {
    $failure = 'The candidate product code is already installed and -AllowPreexistingTarget was not passed. A clean-install run would have no clean baseline.'
    Write-Host ('  REFUSED: ' + $failure)
    Add-RunFinding -Id 'PREEXISTING-TARGET-INSTALL' -Severity 'critical' -Message $failure
    $baseReceipt.overall = 'refused'
    $baseReceipt.exitCode = Get-KanaAiLifecycleExitCodeForStatus -Status 'refused'
    $baseReceipt.completedAtUtc = Get-KanaAiLifecycleUtcNow
    $baseReceipt.findings = @($script:Findings.ToArray())
    [void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $baseReceipt)
    exit 2
}
if ($targetState -eq 'installed') {
    Add-RunFinding -Id 'PREEXISTING-TARGET-ACKNOWLEDGED' -Severity 'warning' -Message 'The operator acknowledged a pre-existing install of the candidate product code. The clean-install baseline is forfeited: the phases that require an absent product are reported unconfirmed, not passed.'
}

# --- the expected file set, read from the candidate MSI itself -------------
$filePlan = Get-KanaAiLifecycleMsiFilePlan -Ledger $script:Ledger -Path $msiPath -InstallFolderId $installFolderId
$baseReceipt.expectedFilePlan = [ordered]@{
    installFolderId = $filePlan.installFolderId
    expectedFileCount = @($filePlan.expectedPaths).Count
    expectedPaths   = @($filePlan.expectedPaths)
    directories     = $filePlan.directories
    outOfScope      = @($filePlan.outOfScope)
    note            = $filePlan.note
}
if (@($filePlan.outOfScope).Count -gt 0) {
    Add-RunFinding -Id 'MSI-OUT-OF-SCOPE-FILES' -Severity 'warning' -Message ("{0} MSI object(s) resolve outside INSTALLFOLDER and are therefore not compared against the install directory inventory." -f @($filePlan.outOfScope).Count) -Evidence @($filePlan.outOfScope)
}
$expectedPathInfo = Get-KanaAiLifecycleExpectedInstallPath -Ledger $script:Ledger -Path $msiPath -InstallFolderId $installFolderId
if ($expectedPathInfo.resolvable) { $expectedInstallPath = [string]$expectedPathInfo.expectedPath }
Add-RunFinding -Id 'INSTALL-PATH' -Severity 'info' -Message ("Install directory resolution: expectedPath='{0}', resolvable={1}, reason='{2}'. The authoritative post-install path is read back from the Windows Installer, not assumed." -f (Protect-KanaAiLifecyclePath -Path $expectedInstallPath), [bool]$expectedPathInfo.resolvable, [string]$expectedPathInfo.reason)

# --- run state -------------------------------------------------------------
$productExecutables = @(Get-KanaAiLifecycleProperty -Object $planObject -Name 'productExecutables' -Context 'plan')
$msiexecPath = Join-Path ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::System)) 'msiexec.exe'

$state = @{
    productState      = $targetState
    installedProductCode = if ($targetState -eq 'installed') { $identity.ProductCode } else { '' }
    installedVersion   = if ($targetState -eq 'installed') { $identity.ProductVersion } else { '' }
    installDirectory   = if ($targetState -eq 'installed') { $expectedInstallPath } else { $expectedInstallPath }
    installDate        = ''
    newerIsNewer       = 'false'
    olderIsOlder       = 'false'
}
if (-not [string]::IsNullOrWhiteSpace($newerMsiPath)) {
    try {
        $newerMap = Get-KanaAiLifecycleMsiPropertyMap -Ledger $script:Ledger -Path $newerMsiPath
        $newerVersion = [string](Get-KanaAiLifecycleOptionalProperty -Object $newerMap -Name 'ProductVersion' -Default '')
        $newerCode = [string](Get-KanaAiLifecycleOptionalProperty -Object $newerMap -Name 'ProductCode' -Default '')
        $newerUpgrade = [string](Get-KanaAiLifecycleOptionalProperty -Object $newerMap -Name 'UpgradeCode' -Default '')
        $newerIdentity = Test-KanaAiLifecycleCandidateIdentity -PropertyMap $newerMap -TemplatePlatform (Get-KanaAiLifecycleMsiTemplatePlatform -Ledger $script:Ledger -Path $newerMsiPath) -Pinned $pinnedIdentity
        $baseReceipt.candidate.newerIdentity = $newerIdentity
        $state.newerIsNewer = if ($newerIdentity.Ok -and ([version]$newerVersion -gt [version]$identity.ProductVersion)) { 'true' } else { 'false' }
        $state.newerProductCode = (ConvertTo-KanaAiLifecycleGuid -Value $newerCode)
        $state.newerVersion = $newerVersion
    }
    catch { $state.newerIsNewer = 'false' }
}
if (-not [string]::IsNullOrWhiteSpace($olderMsiPath)) {
    try {
        $olderMap = Get-KanaAiLifecycleMsiPropertyMap -Ledger $script:Ledger -Path $olderMsiPath
        $olderVersion = [string](Get-KanaAiLifecycleOptionalProperty -Object $olderMap -Name 'ProductVersion' -Default '')
        $baseReceipt.candidate.olderVersion = $olderVersion
        $state.olderIsOlder = if ([version]$olderVersion -lt [version]$identity.ProductVersion) { 'true' } else { 'false' }
    }
    catch { $state.olderIsOlder = 'false' }
}

# --- baseline observation --------------------------------------------------
$baselineProcesses = Get-KanaAiLifecycleProductProcessObservation -Ledger $script:Ledger -Names $productExecutables -HarnessStartedPids @() -BaselinePids @()
$baselinePids = @(
    foreach ($entry in @($baselineProcesses.observed)) { if ($entry -match '#(\d+):') { [int]$Matches[1] } }
)
$baselineRegistration = Get-KanaAiLifecycleRegistrationObservation -Ledger $script:Ledger -Registration $registrationIdentity -InstallDirectory $expectedInstallPath
$baselineDirectory = Get-KanaAiLifecycleInstallDirectoryObservation -Ledger $script:Ledger -Path $expectedInstallPath
$baseReceipt.baseline = [ordered]@{
    capturedAtUtc           = Get-KanaAiLifecycleUtcNow
    existingKanaAiProducts  = $existingProducts
    targetProductState      = $targetState
    unexpectedProducts      = $unexpectedPresent
    expectedInstallPath     = (Protect-KanaAiLifecyclePath -Path $expectedInstallPath)
    expectedInstallPathSource = [string]$expectedPathInfo.reason
    installDirectory        = $baselineDirectory
    registration            = $baselineRegistration
    productProcesses        = $baselineProcesses
    note                    = 'This is the before-picture. Every later "nothing changed" or "is gone" claim in this receipt is compared against exactly these values.'
}

# --- resume ----------------------------------------------------------------
$priorResults = $null
$priorReceiptInfo = $null
if (-not [string]::IsNullOrWhiteSpace($PriorReceiptPath)) {
    try {
        $priorReceipt = Read-KanaAiLifecycleJson -Path ([System.IO.Path]::GetFullPath($PriorReceiptPath))
        $priorResults = @($priorReceipt.phases)
        $priorReceiptInfo = [ordered]@{
            pathRelative = (Get-KanaAiLifecycleRepositoryRelativePath -Path $PriorReceiptPath -RepositoryRoot $repositoryRoot)
            sha256       = (Get-KanaAiLifecycleSha256 -Path ([System.IO.Path]::GetFullPath($PriorReceiptPath)))
            runId        = [string](Get-KanaAiLifecycleOptionalProperty -Object $priorReceipt -Name 'runId' -Default '')
            mode         = [string](Get-KanaAiLifecycleOptionalProperty -Object $priorReceipt -Name 'mode' -Default '')
        }
        $baseReceipt.resumedFrom = $priorReceiptInfo
        Add-RunFinding -Id 'RESUMED' -Severity 'warning' -Message ("This run resumes from receipt {0} (sha256 {1}). A phase marked 'pass' here by way of 'skip-completed' was proven by THAT receipt, not by this one. A complete W2 claim needs both." -f $priorReceiptInfo.pathRelative, $priorReceiptInfo.sha256)
    }
    catch {
        Write-Error ('The prior receipt could not be read: ' + $_.Exception.Message)
        exit 4
    }
}
$resumePlan = Resolve-KanaAiLifecycleResumePlan -Plan $planObject -PriorResults $priorResults -ResumeFrom $ResumeFrom -AllowDestructiveRerun ([bool]$AllowDestructiveRerun)
if (-not $resumePlan.Ok) {
    foreach ($errorText in $resumePlan.Errors) {
        Write-Host ('  REFUSED: ' + $errorText)
        Add-RunFinding -Id 'RESUME-REFUSED' -Severity 'critical' -Message $errorText
    }
    $baseReceipt.overall = 'refused'
    $baseReceipt.exitCode = Get-KanaAiLifecycleExitCodeForStatus -Status 'refused'
    $baseReceipt.completedAtUtc = Get-KanaAiLifecycleUtcNow
    $baseReceipt.findings = @($script:Findings.ToArray())
    [void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $baseReceipt)
    exit 2
}
$baseReceipt.resume = $resumePlan
if ($resumePlan.RefusedPhases.Count -gt 0) {
    Add-RunFinding -Id 'RESUME-DESTRUCTIVE-REFUSED' -Severity 'critical' -Message ("{0} destructive phase(s) will not be re-run without -AllowDestructiveRerun: {1}" -f $resumePlan.RefusedPhases.Count, ($resumePlan.RefusedPhases -join ', ')) -Evidence @($resumePlan.RefusedPhases)
}

# --- the phase loop --------------------------------------------------------
$phaseResults = New-Object System.Collections.Generic.List[object]
$dryRun = [bool]$WhatIfPreference
$installDateBeforeCommand = ''
$inventoryBeforeCommand = @()
$registration = $null
$directoryObservation = $null
$processObservation = $null
$lastInstalledProductCode = ''

foreach ($action in @($resumePlan.Actions)) {
    $phaseName = [string]$action.phase
    $phase = Get-KanaAiLifecyclePhase -Plan $planObject -Name $phaseName
    $record = New-PhaseResultRecord -Phase $phase -Decision ([string]$action.decision) -DecisionReason ([string]$action.reason) -PriorOutcome ([string]$action.priorOutcome)
    $record.startedAtUtc = Get-KanaAiLifecycleUtcNow
    Write-Host ("[{0}] {1}: {2}" -f $record.id, $phaseName, [string]$action.decision)

    if ($action.decision -eq 'refused') {
        $record.outcome = 'refused'
        $record.reason = [string]$action.reason
        $record.endedAtUtc = Get-KanaAiLifecycleUtcNow
        [void]$phaseResults.Add($record)
        continue
    }
    if ($action.decision -eq 'skip-not-run') {
        $record.outcome = 'not_run'
        $record.reason = [string]$action.reason
        $record.endedAtUtc = Get-KanaAiLifecycleUtcNow
        [void]$phaseResults.Add($record)
        continue
    }
    if ($action.decision -eq 'skip-completed') {
        $record.outcome = 'pass'
        $record.reason = [string]$action.reason
        $record.provenByPriorReceipt = if ($null -ne $priorReceiptInfo) { [string]$priorReceiptInfo.sha256 } else { '' }
        $record.endedAtUtc = Get-KanaAiLifecycleUtcNow
        [void]$phaseResults.Add($record)
        continue
    }

    # These two phases observe the state the harness's own cleanup leaves behind,
    # so they are evaluated after the cleanup passes rather than in this loop.
    if ($phaseName -eq 'absent-final' -or $phaseName -eq 'cleanup') {
        $record.decision = 'run-post-cleanup'
        $record.reason = 'deferred: this phase is decided on the state after the harness-owned cleanup passes'
        $record.outcome = 'not_run'
        $record.endedAtUtc = Get-KanaAiLifecycleUtcNow
        [void]$phaseResults.Add($record)
        continue
    }

    # A phase whose optional candidate was not supplied runs no command and is
    # reported unconfirmed.  It is never silently skipped.
    $missingCandidates = @()
    foreach ($requires in @(Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'requires' -Default @())) {
        switch ([string]$requires) {
            'msi' { if ([string]::IsNullOrWhiteSpace($msiPath)) { $missingCandidates += '-CandidateMsi' } }
            'setup' { if ([string]::IsNullOrWhiteSpace($setupPath)) { $missingCandidates += '-CandidateSetup' } }
            'msi-newer' { if ([string]::IsNullOrWhiteSpace($newerMsiPath)) { $missingCandidates += '-CandidateMsiNewer' } }
            'msi-older' { if ([string]::IsNullOrWhiteSpace($olderMsiPath)) { $missingCandidates += '-CandidateMsiOlder' } }
            default { $missingCandidates += ('unknown requirement ' + [string]$requires) }
        }
    }
    if ($missingCandidates.Count -gt 0) {
        $record.outcome = 'unconfirmed'
        $record.reason = ("the candidate for this phase was not supplied ({0}); no command was run and nothing is claimed" -f ($missingCandidates -join ', '))
        $record.endedAtUtc = Get-KanaAiLifecycleUtcNow
        [void]$phaseResults.Add($record)
        Write-Host ('    unconfirmed: ' + $record.reason)
        continue
    }

    $preconditionResult = Resolve-KanaAiLifecyclePreconditions -Phase $phase -State $state
    $record.preconditionResult = $preconditionResult
    if (-not $preconditionResult.met) {
        $record.outcome = 'unconfirmed'
        $record.reason = ("a precondition was not met ({0}); no command was run and nothing is claimed" -f ($preconditionResult.unmet -join '; '))
        $record.endedAtUtc = Get-KanaAiLifecycleUtcNow
        [void]$phaseResults.Add($record)
        Write-Host ('    unconfirmed: ' + $record.reason)
        continue
    }

    # --- render the command, before anything runs --------------------------
    $commandTemplate = Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'command' -Default $null
    $logPath = Get-PhaseLogPath -Phase $phase -OutputRoot $script:CurrentOutputDirectory
    $productCodeForCommand = if ([string]::IsNullOrWhiteSpace($lastInstalledProductCode)) { $state.installedProductCode } else { $lastInstalledProductCode }
    if ([string]::IsNullOrWhiteSpace($productCodeForCommand)) { $productCodeForCommand = $identity.ProductCode }
    $values = @{
        msiPath      = $msiPath
        setupPath    = $setupPath
        newerMsiPath = $newerMsiPath
        olderMsiPath = $olderMsiPath
        productCode  = $productCodeForCommand
        logPath      = $logPath
        msiexec      = $msiexecPath
    }
    $commandRecord = $null
    if ($null -ne $commandTemplate) {
        try {
            $rendered = Resolve-KanaAiLifecycleCommand -Command $commandTemplate -Values $values
            $record.renderedCommand = $rendered
            $timeout = [int](Get-KanaAiLifecycleOptionalProperty -Object $commandTemplate -Name 'timeoutSeconds' -Default 1800)
            $commandRecord = Invoke-KanaAiLifecycleCommand -Ledger $script:Ledger -Rendered $rendered -TimeoutSeconds $timeout -DryRender $dryRun
        }
        catch {
            $commandRecord = [ordered]@{
                rendered = $false; executed = $false; commandLine = ''; exitCode = ''; exitMeaning = 'harness-error'
                timedOut = $false; error = $_.Exception.Message
            }
        }
    }
    $record.command = $commandRecord

    # --- independent observation ------------------------------------------
    $expectedFilesObject = $null
    $resolvedDirectory = ''
    $installedCode = ''
    $installedState = 'unknown'
    $installDateNow = ''
    $tryAgain = Find-KanaAiLifecycleInstalledProducts -Ledger $script:Ledger -UpgradeCode $identity.UpgradeCode
    $locallyInstalled = @($tryAgain.found | Where-Object { [string]$_.installState -match '^(DEFAULT|LOCAL)$' })
    if ($locallyInstalled.Count -eq 1) {
        $installedCode = [string]$locallyInstalled[0].productCode
        $installedState = 'installed'
        $resolvedDirectory = [string]$locallyInstalled[0].installLocation
        if ([string]::IsNullOrWhiteSpace($resolvedDirectory)) { $resolvedDirectory = $expectedInstallPath }
    }
    elseif ($locallyInstalled.Count -gt 1) {
        $installedState = 'unknown'
        Add-RunFinding -Id 'MULTIPLE-KANAI-PRODUCTS' -Severity 'critical' -Message ("{0} locally installed products share the pinned UpgradeCode, so no single installed product code can be named. Every product-code assertion is unconfirmed." -f $locallyInstalled.Count) -Evidence @($locallyInstalled | ForEach-Object { [string]$_.productCode })
    }
    else {
        $installedState = 'absent'
    }
    if (-not [string]::IsNullOrWhiteSpace($installedCode)) {
        $installDateNow = [string](Get-KanaAiLifecycleProductInfo -Ledger $script:Ledger -ProductCode $installedCode -PropertyName 'InstallDate')
    }
    $registration = Get-KanaAiLifecycleRegistrationObservation -Ledger $script:Ledger -Registration $registrationIdentity -InstallDirectory $resolvedDirectory
    $directoryObservation = Get-KanaAiLifecycleInstallDirectoryObservation -Ledger $script:Ledger -Path $resolvedDirectory
    $processObservation = Get-KanaAiLifecycleProductProcessObservation -Ledger $script:Ledger -Names $productExecutables -HarnessStartedPids @($script:Ledger.StartedProcesses.ToArray() | ForEach-Object { [int]$_.pid }) -BaselinePids $baselinePids
    if ($installedState -eq 'installed' -and -not [string]::IsNullOrWhiteSpace($resolvedDirectory)) {
        $planFor = $filePlan
        if ($phaseName -eq 'upgrade-forward' -and -not [string]::IsNullOrWhiteSpace($newerMsiPath)) {
            $planFor = Get-KanaAiLifecycleMsiFilePlan -Ledger $script:Ledger -Path $newerMsiPath -InstallFolderId $installFolderId
        }
        $expectedFilesObject = Compare-KanaAiLifecycleFileInventory -Expected @($planFor.expectedPaths) -Observed @($directoryObservation.files)
    }
    $msiLogClassification = $null
    if (-not [string]::IsNullOrWhiteSpace($logPath)) {
        $logText = Read-KanaAiLifecycleMsiLogText -Ledger $script:Ledger -Path $logPath
        $msiLogClassification = Get-KanaAiLifecycleMsiLogClassification -Text $logText
    }
    $inventoryDelta = $null
    if ($inventoryBeforeCommand.Count -gt 0 -or $commandRecord -ne $null) {
        $inventoryDelta = Compare-KanaAiLifecycleInventories -Before $inventoryBeforeCommand -After @($directoryObservation.files)
    }
    $expectedProductCodeForPhase = $identity.ProductCode
    if ($phaseName -eq 'upgrade-forward' -and $state.ContainsKey('newerProductCode')) { $expectedProductCodeForPhase = [string]$state.newerProductCode }

    $observation = [ordered]@{
        command                 = $commandRecord
        productState            = $installedState
        installedProductCode    = $installedCode
        expectedProductCode     = $expectedProductCodeForPhase
        installDate             = $installDateNow
        installDateBefore       = $installDateBeforeCommand
        registration            = $registration
        installDirectory        = $directoryObservation
        expectedFiles           = $expectedFilesObject
        inventoryDelta          = $inventoryDelta
        processes               = $processObservation
        msiLog                  = $msiLogClassification
        observedKanaAiProducts  = $tryAgain
        note                    = 'Every field in this observation was read independently of the command that ran in this phase.'
    }
    $context = [ordered]@{ observation = $observation }
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context $context
    $record.observation = $observation
    $record.checks = $outcome.checks
    $record.outcome = $outcome.outcome
    $record.reason = $outcome.reason
    [void]$phaseResults.Add($record)
    Write-Host ('    {0}: {1}' -f $record.outcome, $record.reason)

    # --- carry the state forward -------------------------------------------
    $state.productState = $installedState
    $state.installedProductCode = $installedCode
    if ($installedState -eq 'installed' -and -not [string]::IsNullOrWhiteSpace($installedCode)) { $lastInstalledProductCode = $installedCode }
    $state.installDirectory = $resolvedDirectory
    $state.installDate = $installDateNow
    if ($phaseName -eq 'install-msi' -or $phaseName -eq 'install-setup' -or $phaseName -eq 'upgrade-forward') {
        $installDateBeforeCommand = $installDateNow
        $inventoryBeforeCommand = @($directoryObservation.files)
    }
    elseif ($phaseName -eq 'reinstall-same' -or $phaseName -eq 'downgrade-refused') {
        # Keep the before-picture from the install that is currently in place.
    }
    $record.endedAtUtc = Get-KanaAiLifecycleUtcNow
}

# --- harness-owned cleanup -------------------------------------------------
$cleanupPass = @()
if (-not $SkipHarnessOwnedCleanup) {
    foreach ($pass in @(1, 2)) {
        $stopped = @()
        $refused = @()
        foreach ($entry in $script:Ledger.StartedProcesses) {
            $processId = [int]$entry.pid
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -eq $process) { $refused += ("pid {0} already exited" -f $processId); continue }
            $imageName = $process.ProcessName + '.exe'
            if (-not (Test-KanaAiLifecycleOwnedByHarness -ProcessId $processId -ExpectedImageName $imageName -Ledger $script:Ledger)) {
                $refused += ("pid {0} is not provably this harness's own process" -f $processId)
                continue
            }
            try {
                $process.Kill()
                [void]$process.WaitForExit(10000)
                $stopped += $processId
                [void]$script:Ledger.StoppedProcesses.Add([ordered]@{ pid = $processId; stoppedAtUtc = Get-KanaAiLifecycleUtcNow })
            }
            catch { $refused += ("pid {0} could not be stopped: {1}" -f $processId, $_.Exception.Message) }
        }
        $cleanupPass += [ordered]@{
            pass        = $pass
            stoppedPids = @($stopped)
            refused     = @($refused)
            note        = 'Cleanup terminates a process only when its pid is in this run launch ledger and the live image name matches. A recycled pid belonging to something else is never killed.'
        }
    }
}
$baseReceipt.cleanupPasses = @($cleanupPass)

# --- the final observation phase ------------------------------------------
# The cleanup phase's own observations are taken after both cleanup passes, so
# the plan's cleanup and absent-final phases are decided on post-cleanup state.
# They are re-evaluated here from the same engine rather than by hand.
$phasesByName = @{}
foreach ($record in @($phaseResults)) { $phasesByName[[string]$record.phase] = $record }
foreach ($name in @('absent-final', 'cleanup')) {
    if (-not $phasesByName.ContainsKey($name)) { continue }
    $record = $phasesByName[$name]
    if ([string]$record.decision -ne 'run-post-cleanup') { continue }
    $record.decision = 'run'
    $finalProcesses = Get-KanaAiLifecycleProductProcessObservation -Ledger $script:Ledger -Names $productExecutables -HarnessStartedPids @() -BaselinePids $baselinePids
    $finalInstalled = Find-KanaAiLifecycleInstalledProducts -Ledger $script:Ledger -UpgradeCode $identity.UpgradeCode
    $finalLocal = @($finalInstalled.found | Where-Object { [string]$_.installState -match '^(DEFAULT|LOCAL)$' })
    $finalState = if ($finalLocal.Count -eq 0) { 'absent' } else { 'installed' }
    $finalCode = if ($finalLocal.Count -eq 1) { [string]$finalLocal[0].productCode } else { '' }
    $finalDirectory = if ($finalLocal.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$finalLocal[0].installLocation)) { [string]$finalLocal[0].installLocation } else { $expectedInstallPath }
    $finalRegistration = Get-KanaAiLifecycleRegistrationObservation -Ledger $script:Ledger -Registration $registrationIdentity -InstallDirectory $finalDirectory
    $finalDirectoryObservation = Get-KanaAiLifecycleInstallDirectoryObservation -Ledger $script:Ledger -Path $finalDirectory
    $finalObservation = [ordered]@{
        command              = $record.command
        productState         = $finalState
        installedProductCode = $finalCode
        expectedProductCode  = $identity.ProductCode
        installDate          = ''
        installDateBefore    = ''
        registration         = $finalRegistration
        installDirectory     = $finalDirectoryObservation
        expectedFiles        = $null
        inventoryDelta       = $null
        processes            = $finalProcesses
        msiLog               = $null
        observedKanaAiProducts = $finalInstalled
        note                 = 'Post-cleanup observation, taken after both harness-owned cleanup passes.'
    }
    $phase = Get-KanaAiLifecyclePhase -Plan $planObject -Name $name
    $outcome = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = $finalObservation })
    $record.observation = $finalObservation
    $record.checks = $outcome.checks
    $record.outcome = $outcome.outcome
    $record.reason = $outcome.reason
    Write-Host ('[{0}] {1}: {2}: {3}' -f $record.id, $name, $record.outcome, $record.reason)
}
$baseReceipt.phases = @($phaseResults.ToArray())

# --- final inventory, receipt, verdict -------------------------------------
$finalDirectoryForReceipt = if ([string]::IsNullOrWhiteSpace($state.installDirectory)) { $expectedInstallPath } else { $state.installDirectory }
$baseReceipt.inventory = [ordered]@{
    baseline = [ordered]@{
        path       = (Protect-KanaAiLifecyclePath -Path $expectedInstallPath)
        existed    = [bool]$baselineDirectory.exists
        fileCount  = [int]$baselineDirectory.fileCount
        files      = @($baselineDirectory.files)
    }
    final = (Get-KanaAiLifecycleInstallDirectoryObservation -Ledger $script:Ledger -Path $finalDirectoryForReceipt)
    policy = 'Only the install directory the candidate declares is inventoried. The harness never walks, and never deletes, anywhere else on the machine.'
}
if ($baseReceipt.overall -ne 'refused') {
    $overall = Resolve-KanaAiLifecycleOverallStatus -Results $phaseResults -Mode 'run'
    $baseReceipt.overall = $overall
}
$baseReceipt.exitCode = Get-KanaAiLifecycleExitCodeForStatus -Status $baseReceipt.overall
$baseReceipt.w2.lifecycleRunCount = 1
$baseReceipt.w2.claim = if ([string]$baseReceipt.overall -eq 'passed') {
    'This -Execute receipt is a W2 lifecycle observation for the candidate SHA-256 recorded in candidate.msi.sha256. It covers install, registration, uninstall, reinstall and the upgrade/downgrade phases that were supplied. It does not cover romaji conversion, AI behaviour, or any machine other than this one.'
}
else {
    ('This -Execute receipt did not reach a clean pass (overall={0}). W2 remains UNVERIFIED. The failing or unconfirmed phase is named above and must not be reported as passing.' -f [string]$baseReceipt.overall)
}
if ($baseReceipt.overall -ne 'passed') {
    Add-RunFinding -Id 'W2-NOT-PASSED' -Severity 'critical' -Message ('This run did not pass. overall=' + [string]$baseReceipt.overall + '. No part of W2 may be reported as verified from this receipt.') -Evidence @($phaseResults | ForEach-Object { ([string]$_.id) + ' ' + [string]$_.phase + '=' + [string]$_.outcome })
}

$artifacts = @()
$artifacts += New-KanaAiLifecycleArtifactEntry -Path $planCopyPath -Root $script:CurrentOutputDirectory -Role 'validated-plan-copy'
$artifacts += New-KanaAiLifecycleArtifactEntry -Path $planPath -Root $script:CurrentOutputDirectory -Role 'source-plan'
foreach ($phase in @($phaseResults)) {
    $logName = [string](Get-KanaAiLifecycleOptionalProperty -Object (Get-KanaAiLifecyclePhase -Plan $planObject -Name ([string]$phase.phase)) -Name 'command' -Default $null)
    if ($null -eq $logName) { continue }
    $logFile = [string](Get-KanaAiLifecycleOptionalProperty -Object $logName -Name 'logFile' -Default '')
    if ([string]::IsNullOrWhiteSpace($logFile)) { continue }
    $artifacts += New-KanaAiLifecycleArtifactEntry -Path (Join-Path $script:CurrentOutputDirectory $logFile) -Root $script:CurrentOutputDirectory -Role ('windows-installer-verbose-log:' + [string]$phase.phase)
}
$baseReceipt.artifacts = $artifacts
$baseReceipt.findings = @($script:Findings.ToArray())
$baseReceipt.completedAtUtc = Get-KanaAiLifecycleUtcNow
$baseReceipt.machineInteraction = (Get-KanaAiLifecycleInteractionCounters -Ledger $script:Ledger)

$planCopyRun = [ordered]@{
    schemaVersion  = Get-KanaAiLifecycleSchemaVersion
    planId         = [string](Get-KanaAiLifecycleOptionalProperty -Object $planObject -Name 'planId' -Default '')
    runId          = $runId
    sourcePlan     = (Get-KanaAiLifecycleRepositoryRelativePath -Path $planPath -RepositoryRoot $repositoryRoot)
    mode           = [string]$baseReceipt.mode
    validatedAtUtc = $baseReceipt.startedAtUtc
    validation     = $baseReceipt.planValidation
    resume         = $resumePlan
    plan           = $planObject
}
[void](Write-KanaAiLifecycleJson -Path $planCopyPath -Value $planCopyRun)

$sanitySubject = New-KanaAiLifecycleSanitySubject -Receipt $baseReceipt -Exclude @('privacy')
$preSanityJson = ($sanitySubject.subject | ConvertTo-Json -Depth 40)
$sanity = Test-KanaAiLifecycleReceiptSanity -Json $preSanityJson
$baseReceipt.privacy.sanity = [ordered]@{
    ok                     = [bool]$sanity.ok
    problems               = @($sanity.problems)
    method                 = $sanity.method
    excludedTopLevelFields = @($sanitySubject.excluded)
    excludedReason         = "the plan's own privacy policy names the categories it never collects, so quoting it verbatim would always trip the scan. The excluded field is recorded here with the SHA-256 of its text."
    policyTextSha256       = (Get-KanaAiLifecycleTextSha256 -Text (($baseReceipt.privacy.policy | ConvertTo-Json -Depth 20)))
}
if (-not $sanity.ok) {
    Add-RunFinding -Id 'PRIVACY-SANITY' -Severity 'critical' -Message 'The serialized receipt contains something the privacy policy forbids. The receipt is written anyway so the defect is visible, but the run is marked failed.' -Evidence @($sanity.problems)
    $baseReceipt.overall = 'failed'
    $baseReceipt.exitCode = 1
}
[void](Write-KanaAiLifecycleJson -Path $receiptPath -Value $baseReceipt)

Write-Host ('run {0}: mode={1} overall={2} exit={3}' -f $runId, [string]$baseReceipt.mode, [string]$baseReceipt.overall, [int]$baseReceipt.exitCode)
foreach ($record in @($phaseResults)) { Write-Host ('  {0,-8} {1,-20} {2,-12} {3}' -f [string]$record.id, [string]$record.phase, [string]$record.outcome, [string]$record.reason) }
foreach ($finding in @($baseReceipt.findings)) {
    if ([string]$finding.severity -ne 'info') { Write-Host ('  finding [{0}] {1}: {2}' -f [string]$finding.severity, [string]$finding.id, [string]$finding.message) }
}
Write-Host ('  receipt: ' + (Get-KanaAiLifecycleRepositoryRelativePath -Path $receiptPath -RepositoryRoot $repositoryRoot))
exit ([int]$baseReceipt.exitCode)
