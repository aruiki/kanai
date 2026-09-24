[CmdletBinding()]
param(
    [string]$DataRoot = '',
    [int]$TimeoutSeconds = 10
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

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Get-DefaultDataRoot
}
$dataFull = [System.IO.Path]::GetFullPath($DataRoot)
$pidFile = Join-Path $dataFull 'api-process.json'
if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
    Write-Output 'KanaAI is not recorded as running.'
    return
}

$record = $null
try {
    $record = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
}
catch {
    Remove-Item -LiteralPath $pidFile -Force
    throw 'The KanaAI process record is invalid and was removed.'
}
$recordPid = Get-JsonProperty -Object $record -Name 'pid'
$recordStartedAt = Get-JsonProperty -Object $record -Name 'startedAtUtc'
if ($null -eq $record -or $null -eq $recordPid) {
    Remove-Item -LiteralPath $pidFile -Force
    throw 'The KanaAI process record has no PID.'
}

$process = Get-Process -Id ([int]$recordPid) -ErrorAction SilentlyContinue
if ($null -eq $process) {
    Remove-Item -LiteralPath $pidFile -Force
    Write-Output 'The recorded KanaAI process is no longer running.'
    return
}

$sameProcess = $true
if ($null -ne $recordStartedAt -and $recordStartedAt -ne '') {
    $sameProcess = ((Get-ProcessStartUtc -Process $process) -eq [string]$recordStartedAt)
}
if (-not $sameProcess) {
    Remove-Item -LiteralPath $pidFile -Force
    throw 'The recorded PID now belongs to a different process; refusing to stop it.'
}

$executableProperty = $record.PSObject.Properties['executable']
if ($null -ne $executableProperty -and $executableProperty.Value -ne '') {
    $actualPath = ''
    try {
        $actualPath = [System.IO.Path]::GetFullPath($process.Path)
    }
    catch {
        # Some protected processes do not expose Path. The start-time check
        # above still prevents the common PID-reuse case.
    }
    if ($actualPath -ne '') {
        $expectedPath = [System.IO.Path]::GetFullPath([string]$executableProperty.Value)
        if ($actualPath -ine $expectedPath) {
            throw "The recorded PID points to $actualPath, not $expectedPath; refusing to stop it."
        }
    }
}

$stoppedChildren = @()
$bridgePath = ''
$bridgeProperty = $record.PSObject.Properties['mozcBridge']
if ($null -ne $bridgeProperty) {
    $bridgePath = [string]$bridgeProperty.Value
}
if (-not [string]::IsNullOrWhiteSpace($bridgePath)) {
    try {
        $children = @(Get-CimInstance -ClassName Win32_Process -Filter ("ParentProcessId=" + $process.Id) -ErrorAction Stop)
        foreach ($child in $children) {
            $childPath = [string]$child.ExecutablePath
            if (-not [string]::IsNullOrWhiteSpace($childPath) -and
                $childPath -ine $bridgePath) {
                continue
            }
            if ($null -ne $child.ProcessId -and [int]$child.ProcessId -ne $process.Id) {
                Stop-Process -Id ([int]$child.ProcessId) -Force -ErrorAction SilentlyContinue
                $stoppedChildren += [int]$child.ProcessId
            }
        }
    }
    catch {
        # Process-tree cleanup is best effort; the owned API process is still
        # stopped below and can be inspected by the user if a child remains.
    }
}

Stop-Process -Id $process.Id -Force
$process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000) | Out-Null
Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
[pscustomobject]@{
    ProcessId = $process.Id
    Stopped = $true
    StoppedBridgeProcesses = $stoppedChildren
}
