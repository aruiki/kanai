param(
    [Parameter(Mandatory=$true)][ValidateSet('build','machine')][string]$Name,
    [Parameter(Mandatory=$true)][scriptblock]$Action
)
$ErrorActionPreference = 'Stop'
# Shared by worktrees on this Windows account. File handle releases on process exit.
$lockRoot = Join-Path $env:LOCALAPPDATA 'KanaAI/development-locks'
[void][System.IO.Directory]::CreateDirectory($lockRoot)
$lockPath = Join-Path $lockRoot ($Name + '.lock')
try {
    $handle = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch [System.IO.IOException] {
    throw "Resource '$Name' is in use. Do other work and retry after its owner finishes. $lockPath"
}
try {
    & $Action
    # Action must check native command exit codes and throw on failure.
} finally {
    $handle.Dispose()
}
