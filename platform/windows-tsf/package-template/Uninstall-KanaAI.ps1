[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [string]$DataRoot = '',
    [Alias('RemoveData')]
    [switch]$RemoveUserData,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultInstallRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA 'Programs\KanaAI')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return (Join-Path $env:USERPROFILE 'AppData\Local\Programs\KanaAI')
    }
    throw 'Neither LOCALAPPDATA nor USERPROFILE is available.'
}

function Get-DefaultDataRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA 'KanaAI')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return (Join-Path $env:USERPROFILE 'AppData\Local\KanaAI')
    }
    throw 'Neither LOCALAPPDATA nor USERPROFILE is available.'
}

function Assert-SafeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd([char[]]'\/') -eq $root.TrimEnd([char[]]'\/')) {
        throw "Refusing to remove a filesystem root: $full"
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to operate on a reparse-point directory: $full"
        }
    }
    return $full
}

function Assert-DistinctTrees {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )

    $firstFull = [System.IO.Path]::GetFullPath($First).TrimEnd([char[]]'\/')
    $secondFull = [System.IO.Path]::GetFullPath($Second).TrimEnd([char[]]'\/')
    $firstPrefix = $firstFull + [System.IO.Path]::DirectorySeparatorChar
    $secondPrefix = $secondFull + [System.IO.Path]::DirectorySeparatorChar
    if ($firstFull -ieq $secondFull -or
        $firstFull.StartsWith($secondPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $secondFull.StartsWith($firstPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Install and data directories must be separate trees: $firstFull / $secondFull"
    }
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Get-DefaultInstallRoot
}
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Get-DefaultDataRoot
}
$installFull = Assert-SafeDirectory -Path $InstallRoot
$dataFull = Assert-SafeDirectory -Path $DataRoot
Assert-DistinctTrees -First $installFull -Second $dataFull

if (-not (Test-Path -LiteralPath $installFull -PathType Container)) {
    throw "Install directory does not exist: $installFull"
}

$manifestPath = Join-Path $installFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -and -not $Force) {
    throw "Refusing to remove an unrecognized directory without -Force: $installFull"
}

# Validate a custom data target before removing the application.  A failed
# safety check must not leave a half-uninstalled installation.
if ($RemoveUserData) {
    $leaf = [System.IO.Path]::GetFileName($dataFull.TrimEnd([char[]]'\/'))
    if ($leaf -ine 'KanaAI' -and -not $Force) {
        throw "Refusing to remove custom data directory without -Force: $dataFull"
    }
}

$stopScript = Join-Path $installFull 'Stop-KanaAI.ps1'
if (Test-Path -LiteralPath $stopScript -PathType Leaf) {
    & $stopScript -DataRoot $dataFull | Out-Null
}

Remove-Item -LiteralPath $installFull -Recurse -Force

$dataRemoved = $false
if ($RemoveUserData -and (Test-Path -LiteralPath $dataFull -PathType Container)) {
    Remove-Item -LiteralPath $dataFull -Recurse -Force
    $dataRemoved = $true
}

[pscustomobject]@{
    InstallRoot = $installFull
    InstallRemoved = $true
    DataRoot = $dataFull
    UserDataRemoved = $dataRemoved
    UserDataRetained = -not $dataRemoved
}
