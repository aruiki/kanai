[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86')]
    [string]$Architecture = 'x64',
    [ValidateSet('PerUser', 'Machine', 'Admin', 'Administrator', 'User', 'AllUsers', 'System')]
    [string]$Scope = 'PerUser',
    [Alias('RegistrationMetadata')]
    [string]$MetadataPath = '',
    [string]$InstallRoot = '',
    [string]$ProgramFilesRoot = '',
    [string]$TipDll = '',
    [Alias('TestReceipt')]
    [string]$WindowsTestReceipt = '',
    [switch]$SkipUserActivation,
    [switch]$DryRun,
    [switch]$WhatIf,
    [switch]$Apply,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common-TsfRegistration.ps1')

if ($WhatIf) {
    $DryRun = $true
}
if ($DryRun -and $Apply) {
    throw 'Choose either -DryRun/-WhatIf or -Apply; dry-run is the default and never writes the registry.'
}

$scopeName = Get-TsfScopeName -Scope $Scope
$metadata = Get-TsfRegistrationMetadata -Path $MetadataPath
$architectureSpec = Get-TsfArchitectureSpec -Metadata $metadata -Architecture $Architecture
$location = Get-TsfInstallLocation -Metadata $metadata -ArchitectureSpec $architectureSpec -InstallRoot $InstallRoot -ProgramFilesRoot $ProgramFilesRoot
if (-not [string]::IsNullOrWhiteSpace($TipDll)) {
    if ($TipDll -match '^<[^>]+>$') {
        throw "TIP DLL path must be an actual path, not a placeholder: $TipDll"
    }
    $location.TipDllPath = ConvertTo-TsfPath -Path $TipDll
}

$plan = New-TsfInstallPlan -Metadata $metadata -ArchitectureSpec $architectureSpec -Scope $scopeName -Location $location -WindowsTestReceipt $WindowsTestReceipt -SkipUserActivation:$SkipUserActivation
if (-not $Json) {
    Write-TsfPlan -Plan $plan
}

if ($Json) {
    Write-Output (ConvertTo-TsfPlanJson -Plan $plan)
}

if (-not $Apply) {
    # No registry provider, registry key, or file is touched in the default
    # mode. This is the only mode available to the source-only slice today.
    if ($Json) {
        return
    }
    return $plan
}

Assert-TsfApplyEnvironment -ArchitectureSpec $architectureSpec -Scope $scopeName -Readiness $plan.Readiness -TipDllPath $location.TipDllPath -InstallRoot $InstallRoot
if (-not $plan.CanApply) {
    $reasonText = (@($plan.BlockingReasons) -join '; ')
    throw "The install projection is blocked: $reasonText"
}

Write-Warning 'This applies only the reviewed registry projection. TSF API registration, category registration, activation, and runtime verification remain required; registration is not complete yet.'
$applied = @()
foreach ($operation in @($plan.RegistryOperations)) {
    Set-TsfRegistryOperation -Operation $operation
    $applied += $operation
}

$result = [pscustomobject]@{
    Status = 'registry-projection-applied-unverified'
    Mode = 'apply'
    DryRun = $false
    Applied = $true
    Action = 'install'
    Scope = $scopeName
    Architecture = $Architecture
    RegistryView = $architectureSpec.RegistryView
    AppliedOperations = @($applied)
    Plan = $plan
    Registered = $false
    RegistrationComplete = $false
    RuntimeVerified = $false
    NextGate = 'Run the Windows registration, COM, language-profile, and application tests against the real TIP.'
}
if ($Json) {
    Write-Output ($result | ConvertTo-Json -Depth 20)
}
else {
    Write-Output $result
}
