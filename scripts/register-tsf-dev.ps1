[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86')]
    [string]$Architecture = 'x64',
    [ValidateSet('PerUser', 'Machine', 'Admin', 'Administrator', 'User', 'AllUsers', 'System')]
    [string]$Scope = 'PerUser',
    [switch]$PerUser,
    [switch]$Admin,
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

if ($PerUser -and $Admin) {
    throw 'Choose only one of -PerUser or -Admin.'
}
if ($PerUser) {
    $Scope = 'PerUser'
}
elseif ($Admin) {
    $Scope = 'Machine'
}
if ($WhatIf) {
    $DryRun = $true
}
if ($DryRun -and $Apply) {
    throw 'Choose either -DryRun/-WhatIf or -Apply. The development wrapper is dry-run by default.'
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installer = Join-Path $repositoryRoot 'platform\windows-tsf\installer\Install-TsfRegistration.ps1'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "TSF registration installer is missing: $installer"
}

$arguments = @{
    Architecture = $Architecture
    Scope = $Scope
    InstallRoot = $InstallRoot
    ProgramFilesRoot = $ProgramFilesRoot
    TipDll = $TipDll
    WindowsTestReceipt = $WindowsTestReceipt
    DryRun = $DryRun
    Apply = $Apply
    Json = $Json
}
if ($SkipUserActivation) { $arguments['SkipUserActivation'] = $true }

if (-not $Json) {
    Write-Host 'KanaAI TSF development registration wrapper: source-only by default.'
    Write-Host 'Registration is not complete until a real TIP DLL exists and Windows tests pass.'
    Write-Host 'No registry change is made unless -Apply is explicitly supplied and all DLL/Windows-test gates pass.'
}
& $installer @arguments
