[CmdletBinding()]
param(
    [string]$StageDirectory = '',
    [string]$Python = 'python',
    [string]$Bazelisk = 'bazelisk',
    [ValidateSet('release_build', 'opt', 'dbg')]
    [string]$Configuration = 'release_build',
    [switch]$SkipDependencyFetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

if ([string]::IsNullOrWhiteSpace($StageDirectory)) {
    $StageDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'kanai-tsf-mozc-13c98988247aa711d99db9e348ec2a597d14b5cd'
}
$StageDirectory = [System.IO.Path]::GetFullPath($StageDirectory)
$sourceDirectory = Join-Path $StageDirectory 'src'
if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory 'MODULE.bazel') -PathType Leaf)) {
    throw "Not a prepared Mozc source tree: $sourceDirectory"
}
if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory 'engine\kanai_ai\BUILD.bazel') -PathType Leaf)) {
    throw "KanaAI overlay is missing: $sourceDirectory\engine\kanai_ai"
}
$engineText = Get-Content -LiteralPath (Join-Path $sourceDirectory 'engine\modules.cc') -Raw
if (-not $engineText.Contains('kanai::tsf::KanaAiSupplementalModel')) {
    throw 'The staged Mozc tree does not contain the KanaAI supplemental-model patch.'
}

if (-not $SkipDependencyFetch) {
    Invoke-Native -FilePath $Python -WorkingDirectory $sourceDirectory -ArgumentList @(
        'build_tools/update_deps.py'
    )
}

$targets = @(
    '//win32/tip:mozc_tip64',
    '//server:mozc_server_win'
)
$arguments = @('build') + $targets + @(
    "--config=$Configuration",
    '--platforms=//:windows-x86_64'
)
Invoke-Native -FilePath $Bazelisk -WorkingDirectory $sourceDirectory -ArgumentList $arguments

[pscustomobject]@{
    Status = 'built'
    Target = $targets -join ','
    Platform = 'windows-x86_64'
    Configuration = $Configuration
    PinnedMozcCommit = '13c98988247aa711d99db9e348ec2a597d14b5cd'
    PublicBeta = $false
}
