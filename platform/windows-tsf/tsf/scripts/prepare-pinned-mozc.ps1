[CmdletBinding()]
param(
    [string]$MozcRoot = '',
    [string]$OutputDirectory = '',
    [string]$ExpectedCommit = '13c98988247aa711d99db9e348ec2a597d14b5cd',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NativeOutput {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )

    $output = @(& $FilePath @ArgumentList)
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
    return ($output -join "`n").Trim()
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

if ([string]::IsNullOrWhiteSpace($MozcRoot)) {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    $MozcRoot = Join-Path $repoRoot 'third_party\mozc'
}
$MozcRoot = [System.IO.Path]::GetFullPath($MozcRoot)
if (-not (Test-Path -LiteralPath (Join-Path $MozcRoot '.git') -PathType Leaf) -and
    -not (Test-Path -LiteralPath (Join-Path $MozcRoot '.git') -PathType Container)) {
    throw "MozcRoot is not a Git checkout: $MozcRoot"
}

$actualCommit = Get-NativeOutput -FilePath 'git' -ArgumentList @(
    '-C', $MozcRoot, 'rev-parse', 'HEAD'
)
if ($actualCommit -ne $ExpectedCommit) {
    throw "Pinned Mozc commit mismatch. Expected $ExpectedCommit, found $actualCommit"
}
$trackedChanges = @(& git -C $MozcRoot status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect the pinned Mozc checkout.'
}
if ($trackedChanges.Count -ne 0) {
    throw "Pinned Mozc has tracked changes; refusing to create a non-reproducible overlay:`n$($trackedChanges -join "`n")"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "kanai-tsf-mozc-$ExpectedCommit"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$sourceDirectory = Join-Path $OutputDirectory 'src'
if (Test-Path -LiteralPath $OutputDirectory) {
    if (-not $Force) {
        throw "OutputDirectory already exists. Use -Force to replace it: $OutputDirectory"
    }
    $resolvedMozc = [System.IO.Path]::GetFullPath($MozcRoot).TrimEnd('\')
    $resolvedOutput = $OutputDirectory.TrimEnd('\')
    $filesystemRoot = [System.IO.Path]::GetPathRoot($OutputDirectory).TrimEnd('\')
    if ($resolvedOutput -eq $filesystemRoot) {
        throw 'OutputDirectory must not be a filesystem root.'
    }
    if ($resolvedOutput -eq $resolvedMozc -or $resolvedOutput.StartsWith($resolvedMozc + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputDirectory must not be the pinned checkout or one of its descendants.'
    }
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $sourceDirectory -Force | Out-Null

$archivePath = Join-Path $OutputDirectory 'mozc-source.tar'
try {
    Invoke-Native -FilePath 'git' -WorkingDirectory $MozcRoot -ArgumentList @(
        'archive', '--format=tar', '--output', $archivePath, $ExpectedCommit
    )
    Invoke-Native -FilePath 'tar' -WorkingDirectory $OutputDirectory -ArgumentList @(
        '-xf', $archivePath, '-C', $OutputDirectory
    )

    $overlaySource = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\host_overlay\engine\kanai_ai'))
    $overlayDestination = Join-Path $sourceDirectory 'engine\kanai_ai'
    Copy-Item -LiteralPath $overlaySource -Destination $overlayDestination -Recurse

    $patchPaths = @(
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\patches\0001-install-kanai-supplemental-model.patch')),
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\patches\0002-kanai-tsf-identity.patch')),
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\patches\0003-session-generation-binding.patch')),
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\patches\0004-windows-python-toolchain.patch')),
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\patches\0005-windows-runtime-identity.patch'))
    )
    foreach ($patchPath in $patchPaths) {
        Invoke-Native -FilePath 'git' -WorkingDirectory $sourceDirectory -ArgumentList @(
            '-c', 'core.autocrlf=false', 'apply', '--check', $patchPath
        )
        Invoke-Native -FilePath 'git' -WorkingDirectory $sourceDirectory -ArgumentList @(
            '-c', 'core.autocrlf=false', 'apply', $patchPath
        )
    }
}
finally {
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
}

[pscustomobject]@{
    Status = 'staged'
    PinnedCommit = $ExpectedCommit
    Source = $MozcRoot
    StagedMozcRoot = $sourceDirectory
    PatchedFiles = @(
        'src/MODULE.bazel',
        'src/engine/BUILD.bazel',
        'src/engine/modules.cc',
        'src/session/BUILD.bazel',
        'src/session/session_handler.cc',
        'src/win32/base/tsf_profile.cc',
        'src/win32/tip/tip_keyevent_handler.cc'
    )
    AddedOverlay = 'src/engine/kanai_ai'
    PublicBeta = $false
}
