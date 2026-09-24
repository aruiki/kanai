[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$DataRoot = '',
    [int]$TimeoutSeconds = 30,
    [switch]$NoBrowser,
    [switch]$AllowDegraded,
    [switch]$SkipIntegrityCheck,
    [switch]$Wait
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

function Get-JsonProperty {
    param(
        [Parameter(Mandatory = $false)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-ProcessStartUtc {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)
    try {
        return $Process.StartTime.ToUniversalTime().ToString('o')
    }
    catch {
        return ''
    }
}

function Stop-OwnedApi {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$PidFile
    )
    try {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            $Process.WaitForExit(5000) | Out-Null
        }
    }
    catch {
        # The original startup error is more useful than a cleanup error.
    }
    if (Test-Path -LiteralPath $PidFile) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
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

if (-not $SkipIntegrityCheck) {
    $verifyScript = Join-Path $packageRoot 'Verify-KanaAI.ps1'
    if (-not (Test-Path -LiteralPath $verifyScript -PathType Leaf)) {
        throw "Integrity verification script is missing: $verifyScript"
    }
    & $verifyScript -PackageRoot $packageRoot | Out-Null
}

$apiPath = Join-Path $packageRoot 'bin\kanai-api.exe'
$bridgePath = Join-Path $packageRoot 'bin\kanai-mozc-bridge.exe'
if (-not (Test-Path -LiteralPath $apiPath -PathType Leaf)) {
    throw "kanai-api.exe is missing from $packageRoot"
}
$settings = Read-EnvFile -Path $configFull
$expanded = @{}
foreach ($key in $settings.Keys) {
    $value = [string]$settings[$key]
    $value = $value.Replace('__PACKAGE_ROOT__', $packageRoot)
    $value = $value.Replace('__USER_DATA__', $dataFull)
    $expanded[$key] = $value
}

$port = 8787
if ($expanded.ContainsKey('KANAI_PORT') -and -not [string]::IsNullOrWhiteSpace($expanded['KANAI_PORT'])) {
    $parsedPort = 0
    if (-not [int]::TryParse([string]$expanded['KANAI_PORT'], [ref]$parsedPort) -or
        $parsedPort -lt 1 -or $parsedPort -gt 65535) {
        throw "KANAI_PORT must be an integer from 1 through 65535: $($expanded['KANAI_PORT'])"
    }
    $port = $parsedPort
}
if ($expanded.ContainsKey('KANAI_MOZC_BRIDGE') -and
    -not [string]::IsNullOrWhiteSpace($expanded['KANAI_MOZC_BRIDGE'])) {
    $bridgePath = [System.IO.Path]::GetFullPath($expanded['KANAI_MOZC_BRIDGE'])
}
if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf) -and -not $AllowDegraded) {
    throw "Mozc bridge is missing: $bridgePath (use -AllowDegraded only for workbench diagnostics)"
}
if (-not $expanded.ContainsKey('KANAI_MOZC_PROFILE') -or [string]::IsNullOrWhiteSpace($expanded['KANAI_MOZC_PROFILE'])) {
    $expanded['KANAI_MOZC_PROFILE'] = Join-Path $dataFull 'mozc'
}

New-Item -ItemType Directory -Path $dataFull -Force | Out-Null
if (-not [string]::IsNullOrWhiteSpace($expanded['KANAI_MOZC_PROFILE'])) {
    New-Item -ItemType Directory -Path $expanded['KANAI_MOZC_PROFILE'] -Force | Out-Null
}
$pidFile = Join-Path $dataFull 'api-process.json'
if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
    $oldRecord = $null
    try {
        $oldRecord = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
    }
    catch {
        $oldRecord = $null
    }
    $oldPid = Get-JsonProperty -Object $oldRecord -Name 'pid'
    $oldStartedAt = Get-JsonProperty -Object $oldRecord -Name 'startedAtUtc'
    if ($null -ne $oldPid) {
        $oldProcess = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
        if ($null -ne $oldProcess) {
            $sameProcess = $true
            if ($null -ne $oldStartedAt -and $oldStartedAt -ne '') {
                $sameProcess = ((Get-ProcessStartUtc -Process $oldProcess) -eq [string]$oldStartedAt)
            }
            if ($sameProcess) {
                throw "KanaAI is already running (PID $($oldProcess.Id)). Run Stop-KanaAI.ps1 first."
            }
        }
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

$logDirectory = Join-Path $dataFull 'logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$stdoutPath = Join-Path $logDirectory 'api.stdout.log'
$stderrPath = Join-Path $logDirectory 'api.stderr.log'

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
$apiProcess = $null
try {
    [System.Environment]::SetEnvironmentVariable('KANAI_PORT', [string]$port, 'Process')
    [System.Environment]::SetEnvironmentVariable('KANAI_MOZC_BRIDGE', $bridgePath, 'Process')
    if ($expanded.ContainsKey('KANAI_MOZC_PROFILE')) {
        [System.Environment]::SetEnvironmentVariable('KANAI_MOZC_PROFILE', $expanded['KANAI_MOZC_PROFILE'], 'Process')
    }
    foreach ($key in @('KANA_AI_BASE_URL', 'KANA_AI_MODEL', 'KANA_AI_API_KEY', 'KANA_AI_ALLOW_REMOTE', 'KANAI_DIAGNOSTICS')) {
        if ($expanded.ContainsKey($key)) {
            [System.Environment]::SetEnvironmentVariable($key, $expanded[$key], 'Process')
        }
    }

    $apiProcess = Start-Process -FilePath $apiPath -WorkingDirectory $packageRoot -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru
    $record = [ordered]@{
        pid = [int]$apiProcess.Id
        executable = $apiPath
        mozcBridge = $bridgePath
        startedAtUtc = Get-ProcessStartUtc -Process $apiProcess
        port = $port
    }
    $recordJson = $record | ConvertTo-Json -Depth 5
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($pidFile, $recordJson + [Environment]::NewLine, $encoding)

    $baseUrl = "http://127.0.0.1:$port"
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $health = $null
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        if ($apiProcess.HasExited) {
            throw "kanai-api.exe exited before becoming ready. See $stderrPath"
        }
        try {
            $health = Invoke-RestMethod -Uri ($baseUrl + '/api/health') -TimeoutSec 2
            if ($null -ne $health -and $health.available -eq $true) {
                $ready = $true
                break
            }
        }
        catch {
            # Startup races and a missing bridge are reported below with context.
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $ready -and $AllowDegraded -and $null -ne $health) {
        $ready = $true
        Write-Warning 'KanaAI started in degraded mode; the Mozc bridge is not ready.'
    }
    if (-not $ready) {
        throw "KanaAI did not become ready within $TimeoutSeconds seconds. See $stderrPath"
    }

    if (-not $NoBrowser) {
        Start-Process -FilePath $baseUrl | Out-Null
    }
    if ($Wait) {
        $apiProcess.WaitForExit()
    }
    [pscustomobject]@{
        ProcessId = $apiProcess.Id
        Url = $baseUrl
        Health = $health
        Logs = $logDirectory
        Configuration = $configFull
    }
}
catch {
    if ($null -ne $apiProcess) {
        Stop-OwnedApi -Process $apiProcess -PidFile $pidFile
    }
    throw
}
finally {
    foreach ($key in $environmentKeys) {
        [System.Environment]::SetEnvironmentVariable($key, $previousEnvironment[$key], 'Process')
    }
}
