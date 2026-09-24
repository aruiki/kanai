[CmdletBinding(PositionalBinding = $true)]
param(
    [string]$ConfigPath = '',
    [string]$DataRoot = '',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultDataRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA 'KanaAI')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return (Join-Path $env:USERPROFILE 'AppData\Local\KanaAI')
    }
    throw 'Neither LOCALAPPDATA nor USERPROFILE is available.'
}

function Read-EnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file does not exist: $Path"
    }
    $settings = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $text = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($text) -or $text.StartsWith('#')) {
            continue
        }
        $separator = $text.IndexOf('=')
        if ($separator -le 0) {
            throw "Invalid KEY=VALUE configuration line: $text"
        }
        $key = $text.Substring(0, $separator).Trim()
        $value = $text.Substring($separator + 1).Trim()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid configuration key: $key"
        }
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $settings[$key] = $value
    }
    return $settings
}

$packageRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Get-DefaultDataRoot
}
$dataFull = [System.IO.Path]::GetFullPath($DataRoot)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $userConfig = Join-Path $dataFull 'config\kanai.env'
    if (Test-Path -LiteralPath $userConfig -PathType Leaf) {
        $ConfigPath = $userConfig
    }
    else {
        $ConfigPath = Join-Path $packageRoot 'config\kanai.env.example'
    }
}
$configFull = [System.IO.Path]::GetFullPath($ConfigPath)
$cliPath = Join-Path $packageRoot 'bin\kanai.exe'
if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
    throw "kanai.exe is missing from $packageRoot"
}

$verifyScript = Join-Path $packageRoot 'Verify-KanaAI.ps1'
if (-not (Test-Path -LiteralPath $verifyScript -PathType Leaf)) {
    throw "Integrity verification script is missing: $verifyScript"
}
& $verifyScript -PackageRoot $packageRoot | Out-Null

$settings = Read-EnvFile -Path $configFull
$expanded = @{}
foreach ($key in $settings.Keys) {
    $value = [string]$settings[$key]
    $value = $value.Replace('__PACKAGE_ROOT__', $packageRoot)
    $value = $value.Replace('__USER_DATA__', $dataFull)
    $expanded[$key] = $value
}
if (-not $expanded.ContainsKey('KANAI_MOZC_PROFILE') -or [string]::IsNullOrWhiteSpace($expanded['KANAI_MOZC_PROFILE'])) {
    $expanded['KANAI_MOZC_PROFILE'] = Join-Path $dataFull 'mozc'
}
New-Item -ItemType Directory -Path $expanded['KANAI_MOZC_PROFILE'] -Force | Out-Null

$environmentKeys = @(
    'KANAI_PORT',
    'KANAI_MOZC_BRIDGE',
    'KANAI_MOZC_PROFILE',
    'KANA_AI_BASE_URL',
    'KANA_AI_MODEL',
    'KANA_AI_API_KEY',
    'KANA_AI_ALLOW_REMOTE',
    'KANAI_DIAGNOSTICS'
)
$previousEnvironment = @{}
foreach ($key in $environmentKeys) {
    $previousEnvironment[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
}
$exitCode = 1
try {
    foreach ($key in $environmentKeys) {
        if ($expanded.ContainsKey($key)) {
            [System.Environment]::SetEnvironmentVariable($key, $expanded[$key], 'Process')
        }
    }
    & $cliPath @CommandArguments
    $exitCode = $LASTEXITCODE
}
finally {
    foreach ($key in $environmentKeys) {
        [System.Environment]::SetEnvironmentVariable($key, $previousEnvironment[$key], 'Process')
    }
}
exit $exitCode
