[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [string]$DataRoot = '',
    [switch]$Force,
    [switch]$SkipIntegrityCheck
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
        throw "Refusing to use a filesystem root as a directory: $full"
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to use a reparse-point directory: $full"
        }
    }
    return $full
}

$sourceRoot = Assert-SafeDirectory -Path $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Get-DefaultInstallRoot
}
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Get-DefaultDataRoot
}
$installFull = Assert-SafeDirectory -Path $InstallRoot
$dataFull = Assert-SafeDirectory -Path $DataRoot
if ($installFull.TrimEnd([char[]]'\/') -ieq $sourceRoot.TrimEnd([char[]]'\/')) {
    throw 'The install directory must be different from the extracted package directory.'
}
if ($installFull.TrimEnd([char[]]'\/') -ieq $dataFull.TrimEnd([char[]]'\/')) {
    throw 'The install directory and data directory must be different.'
}
$installPrefix = $installFull.TrimEnd([char[]]'\/') + [System.IO.Path]::DirectorySeparatorChar
$dataPrefix = $dataFull.TrimEnd([char[]]'\/') + [System.IO.Path]::DirectorySeparatorChar
if ($installFull.StartsWith($dataPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
    $dataFull.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The install and data directories must be separate trees.'
}

$forbidden = Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File |
    Where-Object {
        $_.Name -eq '.env' -or
        $_.Name -like '*.log' -or
        $_.FullName -match '[\\/]node_modules[\\/]' -or
        $_.FullName -match '[\\/]\.git[\\/]'
    }
if ($null -ne $forbidden -and @($forbidden).Count -gt 0) {
    throw "The package contains a forbidden developer/runtime file: $($forbidden[0].FullName)"
}

if (-not $SkipIntegrityCheck) {
    $verifyScript = Join-Path $sourceRoot 'Verify-KanaAI.ps1'
    if (-not (Test-Path -LiteralPath $verifyScript -PathType Leaf)) {
        throw "Integrity verification script is missing: $verifyScript"
    }
    & $verifyScript -PackageRoot $sourceRoot | Out-Null
}

$parent = Split-Path -Parent $installFull
if ([string]::IsNullOrWhiteSpace($parent)) {
    throw "Could not determine the install parent for $installFull"
}
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$staging = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($installFull) + '.install-' + [guid]::NewGuid().ToString('N'))
$backup = $null
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    Get-ChildItem -LiteralPath $sourceRoot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $staging -Recurse -Force
    }

    if (Test-Path -LiteralPath $installFull) {
        if (-not $Force) {
            throw "Install directory already exists: $installFull (use -Force to replace it)"
        }
        $backup = $installFull + '.backup-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N')
        Move-Item -LiteralPath $installFull -Destination $backup
    }

    Move-Item -LiteralPath $staging -Destination $installFull
    $staging = $null
}
catch {
    if ($null -ne $staging -and (Test-Path -LiteralPath $staging)) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $backup -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $installFull)) {
        Move-Item -LiteralPath $backup -Destination $installFull
    }
    throw
}

New-Item -ItemType Directory -Path $dataFull -Force | Out-Null
$userConfigDirectory = Join-Path $dataFull 'config'
New-Item -ItemType Directory -Path $userConfigDirectory -Force | Out-Null
$userConfig = Join-Path $userConfigDirectory 'kanai.env'
$packagedConfig = Join-Path $installFull 'config\kanai.env.example'
if (-not (Test-Path -LiteralPath $userConfig) -and (Test-Path -LiteralPath $packagedConfig)) {
    Copy-Item -LiteralPath $packagedConfig -Destination $userConfig
}

$installRecord = [ordered]@{
    schemaVersion = 1
    installedAtUtc = [DateTime]::UtcNow.ToString('o')
    installRoot = $installFull
    dataRoot = $dataFull
    sourcePackage = $sourceRoot
}
$recordJson = $installRecord | ConvertTo-Json -Depth 5
$encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
[System.IO.File]::WriteAllText((Join-Path $dataFull 'install.json'), $recordJson + [Environment]::NewLine, $encoding)

[pscustomobject]@{
    InstallRoot = $installFull
    DataRoot = $dataFull
    Configuration = $userConfig
    Backup = $backup
}
