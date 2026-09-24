# WSL-interop-friendly entry point for the pinned-Mozc Windows TSF smoke test.
# Invoke this file with Windows PowerShell (powershell.exe), not Linux pwsh.

<#
.SYNOPSIS
WSL-interop entry point for the pinned-Mozc Windows TSF smoke test.
.DESCRIPTION
Translates a Linux repository argument when needed, starts from a Windows-local
working directory, and forwards all smoke parameters to the owned harness.
#>

[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [Alias('MozcWorkspace', 'PinnedMozcStage')]
    [string]$MozcStage = '',
    [Alias('ArtifactPath', 'MozcTipDll', 'TipDllPath')]
    [string]$TipDll = '',
    [string]$RuntimeRoot = '',
    [Alias('OutputPath', 'SmokeResultPath', 'ReceiptPath')]
    [string]$ResultPath = '',
    [Alias('HostPath', 'TestHostPath')]
    [string]$HostTestPath = '',
    [Alias('AppPath', 'TestAppPath')]
    [string]$ApplicationPath = '',
    [string]$ExpectedTipSha256 = '',
    [Alias('StaticOnly', 'SourceOnly')]
    [switch]$PreflightOnly,
    [Alias('NoVsDevCmd')]
    [switch]$SkipVsDevCmd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-WslInputPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $windowsRoot = [string][System.Environment]::GetEnvironmentVariable('WINDIR')
    $systemWsl = if ([string]::IsNullOrWhiteSpace($windowsRoot)) { '' } else { Join-Path $windowsRoot 'System32\wsl.exe' }
    if (-not [string]::IsNullOrWhiteSpace($systemWsl) -and (Test-Path -LiteralPath $systemWsl -PathType Leaf)) {
        $wslPath = [System.IO.Path]::GetFullPath($systemWsl)
    }
    else {
        $wslCommands = @(Get-Command -Name 'wsl.exe' -CommandType Application -ErrorAction SilentlyContinue)
        if ($wslCommands.Count -eq 0) {
            throw "A WSL path was supplied but wsl.exe is unavailable: $Path"
        }
        $wslPath = [string]$wslCommands[0].Path
        if ([string]::IsNullOrWhiteSpace($wslPath)) {
            $wslPath = [string]$wslCommands[0].Source
        }
    }
    $translated = @()
    $exitCode = 1
    Push-Location -LiteralPath 'C:\Windows'
    try {
        $translated = @(& $wslPath 'wslpath' '-w' $Path)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    $value = ([string]($translated | Select-Object -First 1)).Trim()
    if ($exitCode -ne 0 -or $value.Length -eq 0) {
        throw "WSL interop could not translate '$Path' to a Windows path."
    }
    return $value
}

$repository = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}
else {
    if ($RepositoryRoot.StartsWith('/')) {
        $RepositoryRoot = ConvertFrom-WslInputPath -Path $RepositoryRoot
    }
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}
$harness = Join-Path $repository 'platform\windows-tsf\smoke\Invoke-TsfWindowsSmoke.ps1'
if (-not (Test-Path -LiteralPath $harness -PathType Leaf)) {
    throw "Pinned-Mozc Windows TSF smoke harness is missing: $harness"
}

$arguments = @{
    RepositoryRoot = $repository
    PreflightOnly = [bool]$PreflightOnly
    SkipVsDevCmd = [bool]$SkipVsDevCmd
}
foreach ($entry in @(
    @{ Name = 'MozcStage'; Value = $MozcStage },
    @{ Name = 'TipDll'; Value = $TipDll },
    @{ Name = 'RuntimeRoot'; Value = $RuntimeRoot },
    @{ Name = 'ResultPath'; Value = $ResultPath },
    @{ Name = 'HostTestPath'; Value = $HostTestPath },
    @{ Name = 'ApplicationPath'; Value = $ApplicationPath },
    @{ Name = 'ExpectedTipSha256'; Value = $ExpectedTipSha256 }
)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        $value = [string]$entry.Value
        if ($value.StartsWith('/')) {
            $value = ConvertFrom-WslInputPath -Path $value
        }
        $arguments[$entry.Name] = $value
    }
}

# A WSL UNC current directory is not a safe base for cmd/VsDevCmd or a child
# host process. The harness itself uses absolute paths; this wrapper starts it
# from a Windows-local directory while preserving $PSScriptRoot semantics.
Push-Location -LiteralPath 'C:\Windows'
try {
    & $harness @arguments
}
catch {
    Write-Error -Message ("Pinned-Mozc Windows TSF smoke command failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
finally {
    Pop-Location
}
