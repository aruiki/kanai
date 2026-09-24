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
    [switch]$RemoveUserActivation,
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

$plan = New-TsfUninstallPlan -Metadata $metadata -ArchitectureSpec $architectureSpec -Scope $scopeName -Location $location -RemoveUserActivation:$RemoveUserActivation
if (-not $Json) {
    Write-TsfPlan -Plan $plan
}
if ($Json) {
    Write-Output (ConvertTo-TsfPlanJson -Plan $plan)
}

if (-not $Apply) {
    if ($Json) {
        return
    }
    return $plan
}

if (-not $architectureSpec.Supported) {
    throw "Architecture '$Architecture' is not implemented: $($architectureSpec.BlockedReason)"
}
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'Applying TSF unregistration is Windows-only. Use the default dry-run on non-Windows hosts.'
}
if ($Architecture -eq 'x64' -and
    (-not [System.Environment]::Is64BitOperatingSystem -or -not [System.Environment]::Is64BitProcess)) {
    throw 'The x64 TIP must be unregistered from a 64-bit PowerShell process on 64-bit Windows so the correct registry view is selected.'
}
if ($scopeName -eq 'Machine') {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Machine-wide TSF unregistration requires an elevated administrator PowerShell session.'
    }
}

$removed = @()
foreach ($operation in @($plan.RegistryOperations)) {
    if (Remove-TsfRegistryOperation -Operation $operation) {
        $removed += $operation
    }
}

Write-Warning 'This removes only the reviewed KanaAI registry projection. It does not prove that a prior TIP registration was complete or that Windows no longer has stale TSF state.'
$result = [pscustomobject]@{
    Status = 'registry-projection-removed-unverified'
    Mode = 'apply'
    DryRun = $false
    Applied = $true
    Action = 'uninstall'
    Scope = $scopeName
    Architecture = $Architecture
    RegistryView = $architectureSpec.RegistryView
    RemovedOperations = @($removed)
    Plan = $plan
    Registered = $false
    RegistrationComplete = $false
    RuntimeVerified = $false
    NextGate = 'Restart or sign out and run the Windows TSF cleanup/application tests.'
}
if ($Json) {
    Write-Output ($result | ConvertTo-Json -Depth 20)
}
else {
    Write-Output $result
}
