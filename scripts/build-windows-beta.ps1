# Builds the explicitly unsigned KanaAI Windows Workbench/CLI phase-1 beta
# payload on a Windows x64 MSVC developer host.  It stages the Rust API/CLI,
# the web workbench, and (by default) the pinned Mozc bridge.  It does not
# build or register a TSF DLL; TSF is explicitly outside this phase.
#
# A source archive must pass -SourceDateEpoch explicitly.  A Git checkout may
# derive the same value from HEAD's commit timestamp, but the value is always
# validated and exported before any build command runs.

[CmdletBinding()]
param(
    [ValidateSet('release', 'debug')]
    [string]$Profile = 'release',
    [string]$Target = 'x86_64-pc-windows-msvc',
    [string]$OutputDirectory = '',
    [string]$PackageOutputDirectory = '',
    [string]$Version = '',
    [string]$ApiExecutable = '',
    [string]$CliExecutable = '',
    [string]$MozcBridgeExecutable = '',
    [string]$ShellExecutable = '',
    [switch]$SkipWebBuild,
    [switch]$SkipCargoBuild,
    [switch]$SkipMozcBuild,
    [switch]$BuildShell,
    [switch]$AllowIncomplete,
    [switch]$Package,
    [switch]$Force,
    [string]$SourceDateEpoch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command was not found on PATH: $Name"
    }
    return $command.Source
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-CommandVersion {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    try {
        $output = & $FilePath '--version' 2>&1
        if ($LASTEXITCODE -eq 0 -and $null -ne $output) {
            return ([string]($output | Select-Object -First 1)).Trim()
        }
    }
    catch {
        # Tool version metadata is best effort; the build result remains useful.
    }
    return 'unavailable'
}

function Get-RepositoryVersion {
    param([Parameter(Mandatory = $true)][string]$CargoManifest)

    $content = Get-Content -LiteralPath $CargoManifest -Raw
    $match = [regex]::Match($content, '(?m)^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)')
    if (-not $match.Success) {
        throw "Could not read a workspace version from $CargoManifest"
    }
    return $match.Groups[1].Value
}

function Get-GitRevision {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $git = Get-Command 'git' -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return 'unknown'
    }
    try {
        $revision = (& $git.Source -C $RepositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$revision)) {
            return ([string]$revision).Trim()
        }
    }
    catch {
        # A source archive may not contain git metadata.
    }
    return 'unknown'
}

function Get-GitCommitEpoch {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $git = Get-Command 'git' -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return $null
    }
    try {
        $epoch = (& $git.Source -C $RepositoryRoot show -s --format=%ct HEAD 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$epoch)) {
            return ([string]$epoch).Trim()
        }
    }
    catch {
        # Source archives may not contain git metadata.
    }
    return $null
}

function Resolve-SourceDateEpoch {
    param(
        [string]$Value,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [switch]$UseGitCommitFallback
    )

    $candidate = $Value
    if ([string]::IsNullOrWhiteSpace($candidate) -and
        -not [string]::IsNullOrWhiteSpace($env:SOURCE_DATE_EPOCH)) {
        $candidate = [string]$env:SOURCE_DATE_EPOCH
    }
    if ([string]::IsNullOrWhiteSpace($candidate) -and $UseGitCommitFallback) {
        $candidate = [string](Get-GitCommitEpoch -RepositoryRoot $RepositoryRoot)
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw 'SOURCE_DATE_EPOCH is required. Pass -SourceDateEpoch (or set SOURCE_DATE_EPOCH) so packaging is deterministic.'
    }
    if ($candidate -notmatch '^(0|[1-9][0-9]*)$') {
        throw "SOURCE_DATE_EPOCH must be a non-negative integer number of seconds: $candidate"
    }
    try {
        $seconds = [long]$candidate
        if ($seconds -lt 0) {
            throw 'negative'
        }
        # Fail before a build if the value cannot be represented by the
        # timestamp formatter used in the package manifest.
        [void]([DateTime]::SpecifyKind([DateTime]'1970-01-01', [DateTimeKind]::Utc).AddSeconds($seconds))
    }
    catch {
        throw "SOURCE_DATE_EPOCH is outside the supported timestamp range: $candidate"
    }
    return ([string]$seconds)
}

function Get-BazelCommand {
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:BAZEL)) {
        if (Test-Path -LiteralPath $env:BAZEL -PathType Leaf) {
            return (Resolve-Path -LiteralPath $env:BAZEL).Path
        }
        $configuredCommand = Get-Command $env:BAZEL -ErrorAction SilentlyContinue
        if ($null -ne $configuredCommand) {
            return $configuredCommand.Source
        }
        throw "BAZEL does not point to a file or command: $env:BAZEL"
    }
    foreach ($name in @('bazelisk', 'bazel')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }
    throw 'Bazelisk or Bazel is required to build the Mozc bridge.'
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Assert-SafeOutputDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]'\/')
    $protected = @(
        [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'third_party')).TrimEnd([char[]]'\/'),
        [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'target')).TrimEnd([char[]]'\/'),
        [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'dist')).TrimEnd([char[]]'\/')
    )
    if ($full -ieq $root -or $protected -contains $full) {
        throw "Refusing to use a protected source/build directory as output: $full"
    }
    return $full
}

function Copy-Tree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Directory does not exist: $Source"
    }
    $sourceItem = Get-Item -LiteralPath $Source -Force
    if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse points are not allowed in a portable payload: $Source"
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not allowed in a portable payload: $($_.FullName)"
        }
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Find-BuiltFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }
    $file = Get-ChildItem -LiteralPath $Root -Recurse -File -Force -Filter $Name -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $file) {
        return $null
    }
    return $file.FullName
}

function Assert-X64PeExecutable {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Payload executable is missing: $Path"
    }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 64) {
            throw "Payload executable is too small to contain a PE header: $Path"
        }
        $mz = New-Object -TypeName byte[] -ArgumentList 2
        if ($stream.Read($mz, 0, 2) -ne 2 -or $mz[0] -ne 0x4d -or $mz[1] -ne 0x5a) {
            throw "Payload executable is not a Windows PE image (MZ header missing): $Path"
        }
        $stream.Position = 0x3c
        $offsetBytes = New-Object -TypeName byte[] -ArgumentList 4
        if ($stream.Read($offsetBytes, 0, 4) -ne 4) {
            throw "Payload PE header offset is truncated: $Path"
        }
        $peOffset = [BitConverter]::ToInt32($offsetBytes, 0)
        if ($peOffset -lt 0 -or ($peOffset + 26) -gt $stream.Length) {
            throw "Payload PE header offset is invalid: $Path"
        }
        $stream.Position = $peOffset
        $coff = New-Object -TypeName byte[] -ArgumentList 24
        if ($stream.Read($coff, 0, 24) -ne 24 -or
            $coff[0] -ne 0x50 -or $coff[1] -ne 0x45 -or
            $coff[2] -ne 0x00 -or $coff[3] -ne 0x00) {
            throw "Payload executable has no PE signature: $Path"
        }
        $machine = [BitConverter]::ToUInt16($coff, 4)
        if ($machine -ne 0x8664) {
            throw ("Payload executable is not x64 PE (machine 0x{0:X4}): {1}" -f $machine, $Path)
        }
        $optionalSize = [BitConverter]::ToUInt16($coff, 20)
        if ($optionalSize -lt 2 -or ($peOffset + 24 + $optionalSize) -gt $stream.Length) {
            throw "Payload PE optional header is invalid: $Path"
        }
        $optionalMagic = New-Object -TypeName byte[] -ArgumentList 2
        $stream.Position = $peOffset + 24
        if ($stream.Read($optionalMagic, 0, 2) -ne 2) {
            throw "Payload PE optional header is truncated: $Path"
        }
        $magic = [BitConverter]::ToUInt16($optionalMagic, 0)
        if ($magic -ne 0x20b) {
            throw ("Payload executable is not a PE32+ image (optional magic 0x{0:X4}): {1}" -f $magic, $Path)
        }
        $characteristics = [BitConverter]::ToUInt16($coff, 18)
        if (($characteristics -band 0x2000) -ne 0) {
            throw "Payload executable is a DLL, which is not allowed in this phase-1 package: $Path"
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-GitApplyCheck {
    param(
        [Parameter(Mandatory = $true)][string]$GitCommand,
        [Parameter(Mandatory = $true)][string]$MozcSourceRoot,
        [Parameter(Mandatory = $true)][string]$PatchFile,
        [switch]$Reverse
    )

    $arguments = @('-C', $MozcSourceRoot, 'apply')
    if ($Reverse) {
        $arguments += '--reverse'
    }
    $arguments += @('--check', '--whitespace=error', '--', $PatchFile)
    $output = & $GitCommand @arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ([string]($output -join [Environment]::NewLine)).Trim()
    }
}

function Ensure-MozcPatch {
    param(
        [Parameter(Mandatory = $true)][string]$GitCommand,
        [Parameter(Mandatory = $true)][string]$MozcSourceRoot,
        [Parameter(Mandatory = $true)][string]$PatchFile
    )

    if (-not (Test-Path -LiteralPath $MozcSourceRoot -PathType Container)) {
        throw "Mozc source directory is missing: $MozcSourceRoot"
    }
    if (-not (Test-Path -LiteralPath $PatchFile -PathType Leaf)) {
        throw "The Mozc bridge patch is missing: $PatchFile"
    }

    $reverse = Invoke-GitApplyCheck -GitCommand $GitCommand -MozcSourceRoot $MozcSourceRoot -PatchFile $PatchFile -Reverse
    if ($reverse.ExitCode -eq 0) {
        return 'already-applied'
    }

    $forward = Invoke-GitApplyCheck -GitCommand $GitCommand -MozcSourceRoot $MozcSourceRoot -PatchFile $PatchFile
    if ($forward.ExitCode -ne 0) {
        $detail = $forward.Output
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = $reverse.Output
        }
        throw "The pinned Mozc KanaAI bridge patch is neither applied nor cleanly applicable: $detail"
    }

    $applyOutput = & $GitCommand -C $MozcSourceRoot apply --whitespace=error -- $PatchFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "The Mozc bridge patch could not be applied: $([string]($applyOutput -join [Environment]::NewLine))"
    }
    $verified = Invoke-GitApplyCheck -GitCommand $GitCommand -MozcSourceRoot $MozcSourceRoot -PatchFile $PatchFile -Reverse
    if ($verified.ExitCode -ne 0) {
        throw "The Mozc bridge patch was applied but could not be verified: $($verified.Output)"
    }
    return 'applied-and-verified'
}

function Update-MozcDependencies {
    param(
        [Parameter(Mandatory = $true)][string]$PythonCommand,
        [Parameter(Mandatory = $true)][string]$MozcSourceRoot
    )

    $dependencyScript = Join-Path $MozcSourceRoot 'build_tools\update_deps.py'
    if (-not (Test-Path -LiteralPath $dependencyScript -PathType Leaf)) {
        throw "Mozc dependency bootstrap script is missing: $dependencyScript"
    }
    Invoke-Checked -FilePath $PythonCommand -Arguments @($dependencyScript) -WorkingDirectory $MozcSourceRoot
    return $dependencyScript
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$targetTriple = 'x86_64-pc-windows-msvc'
if ($Target -cne $targetTriple) {
    throw "This beta supports only $targetTriple, not: $Target"
}
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'build-windows-beta.ps1 is a Windows-only build. Use a Windows x64 MSVC developer environment; package-windows-beta.ps1 can package an already staged payload on another host.'
}
Write-Host 'Windows beta prerequisites: Visual Studio 2022 MSVC v143 + Windows SDK, Python 3.12+, Bazelisk, Rust, Node.js, and npm.'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'windows-beta\build'
}
if ([string]::IsNullOrWhiteSpace($PackageOutputDirectory)) {
    $PackageOutputDirectory = Join-Path $repositoryRoot 'windows-beta\dist'
}
$outputFull = Assert-SafeOutputDirectory -Path $OutputDirectory -RepositoryRoot $repositoryRoot
$packageOutputFull = Assert-SafeOutputDirectory -Path $PackageOutputDirectory -RepositoryRoot $repositoryRoot

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-RepositoryVersion -CargoManifest (Join-Path $repositoryRoot 'Cargo.toml')
}
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$') {
    throw "Version must look like 0.1.0: $Version"
}
$SourceDateEpoch = Resolve-SourceDateEpoch -Value $SourceDateEpoch -RepositoryRoot $repositoryRoot -UseGitCommitFallback
$env:SOURCE_DATE_EPOCH = $SourceDateEpoch

$payloadRoot = Join-Path $outputFull ('payload-' + $Version + '-' + $Target)
if (Test-Path -LiteralPath $payloadRoot) {
    if (-not $Force) {
        throw "Build payload already exists: $payloadRoot (use -Force to replace it)"
    }
    Remove-Item -LiteralPath $payloadRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
$binRoot = Join-Path $payloadRoot 'bin'
New-Item -ItemType Directory -Path $binRoot -Force | Out-Null

$toolMetadata = [ordered]@{}
$toolMetadata['profile'] = $Profile
$toolMetadata['target'] = $targetTriple
$toolMetadata['architecture'] = 'x64'
$toolMetadata['version'] = $Version
$toolMetadata['sourceRevision'] = Get-GitRevision -RepositoryRoot $repositoryRoot
$toolMetadata['sourceDateEpoch'] = $SourceDateEpoch
$toolMetadata['packagePhase'] = 'workbench-cli-phase-1'
$toolMetadata['tsfStatus'] = 'unimplemented'
$toolMetadata['shellStatus'] = 'not-built'
$toolMetadata['conversionReady'] = $false
$toolMetadata['runtimeVerified'] = $false
$toolMetadata['allowIncomplete'] = [bool]$AllowIncomplete

$webRoot = Join-Path $repositoryRoot 'dist'
$webBuilt = $false
if ($SkipWebBuild) {
    if (-not (Test-Path -LiteralPath (Join-Path $webRoot 'index.html') -PathType Leaf) -and -not $AllowIncomplete) {
        throw "dist\index.html is missing. Run the web build or pass -AllowIncomplete for a scaffold."
    }
    if (Test-Path -LiteralPath (Join-Path $webRoot 'index.html') -PathType Leaf) {
        $webBuilt = $true
        $toolMetadata['webBuild'] = 'reused'
    }
    else {
        $toolMetadata['webBuild'] = 'missing-scaffold'
    }
}
else {
    $nodeCommand = Get-RequiredCommand -Name 'node'
    $npmCommand = Get-RequiredCommand -Name 'npm'
    $toolMetadata['node'] = Get-CommandVersion -FilePath $nodeCommand
    $toolMetadata['npm'] = Get-CommandVersion -FilePath $npmCommand
    Invoke-Checked -FilePath $npmCommand -Arguments @('ci') -WorkingDirectory $repositoryRoot
    Invoke-Checked -FilePath $npmCommand -Arguments @('run', 'build') -WorkingDirectory $repositoryRoot
    if (-not (Test-Path -LiteralPath (Join-Path $webRoot 'index.html') -PathType Leaf)) {
        throw 'The web build completed without producing dist\index.html.'
    }
    $webBuilt = $true
    $toolMetadata['webBuild'] = 'npm-ci-and-build'
}

$apiSource = $null
$cliSource = $null
if ($SkipCargoBuild) {
    if (-not [string]::IsNullOrWhiteSpace($ApiExecutable)) {
        $apiSource = (Resolve-Path -LiteralPath $ApiExecutable).Path
    }
    if (-not [string]::IsNullOrWhiteSpace($CliExecutable)) {
        $cliSource = (Resolve-Path -LiteralPath $CliExecutable).Path
    }
    if (($null -eq $apiSource -or $null -eq $cliSource) -and -not $AllowIncomplete) {
        throw 'SkipCargoBuild requires -ApiExecutable and -CliExecutable, or an explicit -AllowIncomplete scaffold.'
    }
    $toolMetadata['cargoBuild'] = 'skipped'
}
else {
    $cargoCommand = Get-RequiredCommand -Name 'cargo'
    $rustcCommand = Get-RequiredCommand -Name 'rustc'
    $toolMetadata['cargo'] = Get-CommandVersion -FilePath $cargoCommand
    $toolMetadata['rustc'] = Get-CommandVersion -FilePath $rustcCommand
    $cargoArguments = @('build', '--locked')
    if ($Profile -eq 'release') {
        $cargoArguments += '--release'
    }
    $cargoArguments += @('--target', $targetTriple, '-p', 'kanai-api', '-p', 'kanai-cli')
    Invoke-Checked -FilePath $cargoCommand -Arguments $cargoArguments -WorkingDirectory $repositoryRoot
    $cargoOutput = Join-Path $repositoryRoot ('target\' + $targetTriple + '\' + $(if ($Profile -eq 'release') { 'release' } else { 'debug' }))
    $apiSource = Find-BuiltFile -Root $cargoOutput -Name 'kanai-api.exe'
    $cliSource = Find-BuiltFile -Root $cargoOutput -Name 'kanai-cli.exe'
    $toolMetadata['cargoBuild'] = 'cargo-locked-x86_64-pc-windows-msvc'
}

if ($null -ne $apiSource) {
    Assert-X64PeExecutable -Path $apiSource
    Copy-Item -LiteralPath $apiSource -Destination (Join-Path $binRoot 'kanai-api.exe') -Force
}
if ($null -ne $cliSource) {
    Assert-X64PeExecutable -Path $cliSource
    Copy-Item -LiteralPath $cliSource -Destination (Join-Path $binRoot 'kanai.exe') -Force
}

$mozcSourceRoot = Join-Path $repositoryRoot 'third_party\mozc\src'
$bridgeTarget = Join-Path $mozcSourceRoot 'bazel-bin'
$bridgeSource = $null
$patchFile = Join-Path $repositoryRoot 'patches\mozc-kanai-bridge.patch'
if (-not [string]::IsNullOrWhiteSpace($MozcBridgeExecutable)) {
    $bridgeSource = (Resolve-Path -LiteralPath $MozcBridgeExecutable).Path
    Assert-X64PeExecutable -Path $bridgeSource
    $toolMetadata['mozcBuild'] = 'prebuilt-x64'
    if (Test-Path -LiteralPath $mozcSourceRoot -PathType Container -and (Test-Path -LiteralPath $patchFile -PathType Leaf)) {
        $gitForPatch = Get-RequiredCommand -Name 'git'
        $toolMetadata['mozcPatch'] = Ensure-MozcPatch -GitCommand $gitForPatch -MozcSourceRoot $mozcSourceRoot -PatchFile $patchFile
        $toolMetadata['mozcPatchSha256'] = (Get-FileHash -LiteralPath $patchFile -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
elseif ($SkipMozcBuild) {
    if (-not $AllowIncomplete) {
        throw 'SkipMozcBuild requires -AllowIncomplete. The default package contract requires the Mozc bridge.'
    }
    $toolMetadata['mozcBuild'] = 'skipped-scaffold'
    Write-Warning 'Mozc bridge build was skipped. The resulting package is explicitly a scaffold and cannot convert text.'
}
else {
    $clCommand = Get-RequiredCommand -Name 'cl.exe'
    $pythonCommand = Get-RequiredCommand -Name 'python'
    $gitCommand = Get-RequiredCommand -Name 'git'
    $bazelCommand = Get-BazelCommand
    $toolMetadata['msvc'] = Get-CommandVersion -FilePath $clCommand
    $toolMetadata['python'] = Get-CommandVersion -FilePath $pythonCommand
    $toolMetadata['git'] = Get-CommandVersion -FilePath $gitCommand
    $toolMetadata['bazel'] = Get-CommandVersion -FilePath $bazelCommand

    $toolMetadata['mozcPatch'] = Ensure-MozcPatch -GitCommand $gitCommand -MozcSourceRoot $mozcSourceRoot -PatchFile $patchFile
    $toolMetadata['mozcPatchSha256'] = (Get-FileHash -LiteralPath $patchFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $dependencyScript = Update-MozcDependencies -PythonCommand $pythonCommand -MozcSourceRoot $mozcSourceRoot
    $toolMetadata['mozcDependencies'] = 'build_tools/update_deps.py'
    $toolMetadata['mozcDependencyScript'] = $dependencyScript

    # The platform is explicit on every Bazel invocation.  A host default must
    # never silently select ARM64 or a 32-bit Windows toolchain.
    $bazelArguments = @(
        'build',
        '//kanai:kanai_mozc_bridge',
        '--config=oss_windows',
        '--config=release_build',
        '--platforms=//:windows-x86_64',
        '--cpu=x64'
    )
    Invoke-Checked -FilePath $bazelCommand -Arguments $bazelArguments -WorkingDirectory $mozcSourceRoot
    $bridgeSource = Find-BuiltFile -Root $bridgeTarget -Name 'kanai_mozc_bridge.exe'
    if ($null -eq $bridgeSource) {
        $bridgeSource = Find-BuiltFile -Root (Join-Path $repositoryRoot 'third_party\mozc') -Name 'kanai_mozc_bridge.exe'
    }
    if ($null -eq $bridgeSource) {
        throw 'The x64 Mozc bridge build completed without producing kanai_mozc_bridge.exe.'
    }
    Assert-X64PeExecutable -Path $bridgeSource
    $toolMetadata['mozcBuild'] = 'bazel-msvc-x86_64'
}
if ($null -ne $bridgeSource) {
    Copy-Item -LiteralPath $bridgeSource -Destination (Join-Path $binRoot 'kanai-mozc-bridge.exe') -Force
}

if (-not [string]::IsNullOrWhiteSpace($ShellExecutable)) {
    $shellSource = (Resolve-Path -LiteralPath $ShellExecutable).Path
    Assert-X64PeExecutable -Path $shellSource
    Copy-Item -LiteralPath $shellSource -Destination (Join-Path $binRoot 'kanai-windows-shell.exe') -Force
    $toolMetadata['shellStatus'] = 'prebuilt-x64-console-seam'
}
elseif ($BuildShell) {
    $bazelCommand = Get-BazelCommand
    $shellRoot = Join-Path $repositoryRoot 'platform\windows-tsf\shell'
    $shellArguments = @(
        'build',
        '//:kanai_windows_shell_bridge',
        '--platforms=//:windows-x86_64',
        '--cpu=x64'
    )
    Invoke-Checked -FilePath $bazelCommand -Arguments $shellArguments -WorkingDirectory $shellRoot
    $shellSource = Find-BuiltFile -Root (Join-Path $shellRoot 'bazel-bin') -Name 'kanai_windows_shell_bridge.exe'
    if ($null -eq $shellSource) {
        throw 'The x64 Windows shell seam build completed without producing kanai_windows_shell_bridge.exe.'
    }
    Assert-X64PeExecutable -Path $shellSource
    Copy-Item -LiteralPath $shellSource -Destination (Join-Path $binRoot 'kanai-windows-shell.exe') -Force
    $toolMetadata['shellStatus'] = 'bazel-console-seam-x64'
}
else {
    Write-Warning 'The optional native Windows shell seam was not built; PowerShell Start-KanaAI.ps1 remains the runnable workbench launcher.'
}

if ($webBuilt) {
    Copy-Tree -Source $webRoot -Destination (Join-Path $payloadRoot 'dist')
}
else {
    New-Item -ItemType Directory -Path (Join-Path $payloadRoot 'dist') -Force | Out-Null
    Write-Warning 'No web bundle was staged. Start-KanaAI.ps1 can run the API but the workbench page is incomplete.'
}

$legalRoot = Join-Path $payloadRoot 'legal'
New-Item -ItemType Directory -Path $legalRoot -Force | Out-Null
$legalInputs = @(
    @{ Source = (Join-Path $repositoryRoot 'LICENSE'); Destination = 'LICENSE' },
    @{ Source = (Join-Path $repositoryRoot 'LICENSE-MIT'); Destination = 'LICENSE-MIT' },
    @{ Source = (Join-Path $repositoryRoot 'LICENSE-APACHE'); Destination = 'LICENSE-APACHE' },
    @{ Source = (Join-Path $repositoryRoot 'third_party\mozc\LICENSE'); Destination = 'Mozc-LICENSE.txt' },
    @{ Source = (Join-Path $repositoryRoot 'third_party\mozc\AUTHORS'); Destination = 'Mozc-AUTHORS.txt' },
    @{ Source = (Join-Path $repositoryRoot 'third_party\mozc\CONTRIBUTORS'); Destination = 'Mozc-CONTRIBUTORS.txt' },
    @{ Source = (Join-Path $repositoryRoot 'third_party\mozc\README.md'); Destination = 'Mozc-README.md' },
    @{ Source = (Join-Path $repositoryRoot 'third_party\mozc\VOCABULARY_POLICY.md'); Destination = 'Mozc-VOCABULARY-POLICY.md' },
    @{ Source = (Join-Path $repositoryRoot 'third_party\mozc\src\data\dictionary_oss\README.txt'); Destination = 'Mozc-dictionary-README.txt' },
    @{ Source = (Join-Path $repositoryRoot 'third_party\mozc\src\data\dictionary_manual\README.md'); Destination = 'Mozc-dictionary-manual-README.md' },
    @{ Source = (Join-Path $repositoryRoot 'third_party\mozc\src\README.md'); Destination = 'Mozc-src-README.md' },
    @{ Source = (Join-Path $repositoryRoot 'patches\mozc-kanai-bridge.patch'); Destination = 'mozc-kanai-bridge.patch' },
    @{ Source = (Join-Path $repositoryRoot 'Cargo.lock'); Destination = 'Cargo.lock' },
    @{ Source = (Join-Path $repositoryRoot 'package-lock.json'); Destination = 'package-lock.json' }
)
foreach ($legalInput in $legalInputs) {
    if (Test-Path -LiteralPath $legalInput.Source -PathType Leaf) {
        Copy-Item -LiteralPath $legalInput.Source -Destination (Join-Path $legalRoot $legalInput.Destination) -Force
    }
}
$noticeTemplate = Join-Path $repositoryRoot 'platform\windows-tsf\package-template\THIRD-PARTY-NOTICES.txt'
if (Test-Path -LiteralPath $noticeTemplate -PathType Leaf) {
    Copy-Item -LiteralPath $noticeTemplate -Destination (Join-Path $legalRoot 'THIRD-PARTY-NOTICES.txt') -Force
}

$toolMetadata['payloadFilesPresent'] = ((Test-Path -LiteralPath (Join-Path $binRoot 'kanai-api.exe') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $binRoot 'kanai.exe') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $binRoot 'kanai-mozc-bridge.exe') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $payloadRoot 'dist\index.html') -PathType Leaf))
$toolMetadata['payloadPresent'] = $toolMetadata['payloadFilesPresent']
$metadataJson = $toolMetadata | ConvertTo-Json -Depth 12
Write-Utf8NoBom -Path (Join-Path $payloadRoot '.build-inputs.json') -Content ($metadataJson + [Environment]::NewLine)

if (-not $AllowIncomplete -and -not [bool]$toolMetadata['payloadFilesPresent']) {
    throw 'The staged payload is incomplete. Use -AllowIncomplete only for an explicitly labeled non-runtime scaffold.'
}

if ($Package) {
    $packageScript = Join-Path $repositoryRoot 'scripts\package-windows-beta.ps1'
    if (-not (Test-Path -LiteralPath $packageScript -PathType Leaf)) {
        throw "Package script is missing: $packageScript"
    }
    $packageArguments = @(
        '-PayloadRoot', $payloadRoot,
        '-OutputDirectory', $packageOutputFull,
        '-Version', $Version,
        '-Target', $targetTriple,
        '-Architecture', 'x64',
        '-SourceDateEpoch', $SourceDateEpoch
    )
    if ($AllowIncomplete) {
        $packageArguments += '-AllowIncomplete'
    }
    if ($Force) {
        $packageArguments += '-Force'
    }
    & $packageScript @packageArguments
}
else {
    Write-Output "Windows beta payload staged at $payloadRoot"
    if (-not [bool]$toolMetadata['payloadFilesPresent']) {
        Write-Warning 'This is a beta packaging scaffold, not a complete Windows IME or conversion runtime.'
    }
    else {
        Write-Warning 'The expected files are staged, but this build has not passed a Windows API/Mozc runtime smoke test; conversionReady and runtimeVerified remain false.'
    }
}
