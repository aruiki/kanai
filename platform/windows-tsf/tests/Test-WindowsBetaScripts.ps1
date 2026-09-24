[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$Smoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TestPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Relative
    )

    $current = $Root
    foreach ($part in ($Relative -split '/')) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }
        $current = Join-Path $current $part
    }
    return $current
}

function New-TestPeFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = New-Object byte[] 512
    $bytes[0] = 0x4d
    $bytes[1] = 0x5a
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3c) | Out-Null
    $coff = 0x80
    $bytes[$coff] = 0x50
    $bytes[$coff + 1] = 0x45
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($bytes, $coff + 4) | Out-Null
    [BitConverter]::GetBytes([uint16]1).CopyTo($bytes, $coff + 6) | Out-Null
    [BitConverter]::GetBytes([uint16]0xf0).CopyTo($bytes, $coff + 20) | Out-Null
    [BitConverter]::GetBytes([uint16]0x0022).CopyTo($bytes, $coff + 22) | Out-Null
    [BitConverter]::GetBytes([uint16]0x020b).CopyTo($bytes, $coff + 24) | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') '..'))
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$scriptPaths = @(
    (Join-Path $RepoRoot 'scripts\build-windows-beta.ps1'),
    (Join-Path $RepoRoot 'scripts\package-windows-beta.ps1')
)
$templateRoot = Join-Path $RepoRoot 'platform\windows-tsf\package-template'
$scriptPaths += @(Get-ChildItem -LiteralPath $templateRoot -Recurse -Force -File -Filter '*.ps1' | ForEach-Object { $_.FullName })
$scriptPaths += @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'platform\windows-tsf\tests') -Recurse -Force -File -Filter '*.ps1' | ForEach-Object { $_.FullName })

$parseFailures = @()
foreach ($path in $scriptPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $parseFailures += "missing: $path"
        continue
    }
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($null -ne $errors -and $errors.Count -gt 0) {
        foreach ($error in $errors) {
            $parseFailures += ("{0}:{1}:{2}: {3}" -f $path, $error.Extent.StartLineNumber, $error.Extent.StartColumnNumber, $error.Message)
        }
    }
}
if ($parseFailures.Count -gt 0) {
    throw ("PowerShell syntax check failed:`n" + ($parseFailures -join "`n"))
}

$requiredPaths = @(
    (Join-Path $templateRoot 'BETA-NOTICE.txt'),
    (Join-Path $templateRoot 'THIRD-PARTY-NOTICES.txt'),
    (Join-Path $templateRoot 'config\kanai.env.example'),
    (Join-Path $templateRoot 'Install-KanaAI.ps1'),
    (Join-Path $templateRoot 'Uninstall-KanaAI.ps1'),
    (Join-Path $templateRoot 'Start-KanaAI.ps1'),
    (Join-Path $templateRoot 'Stop-KanaAI.ps1'),
    (Join-Path $templateRoot 'Run-KanaAI-Cli.ps1'),
    (Join-Path $templateRoot 'Verify-KanaAI.ps1'),
    (Join-Path $RepoRoot 'platform\windows-tsf\shell\bridge-contract.json'),
    (Join-Path $RepoRoot 'platform\windows-tsf\shell\kanai_shell_bridge.h'),
    (Join-Path $RepoRoot 'platform\windows-tsf\shell\kanai_windows_shell_bridge.cpp')
)
foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required Windows beta file is missing: $path"
    }
}

$buildText = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\build-windows-beta.ps1') -Raw
$packageText = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\package-windows-beta.ps1') -Raw
$staticChecks = @(
    @{ Name = 'exact Rust target'; Text = $buildText; Needle = "x86_64-pc-windows-msvc" },
    @{ Name = 'patch path'; Text = $buildText; Needle = "patches\mozc-kanai-bridge.patch" },
    @{ Name = 'patch verification'; Text = $buildText; Needle = 'Ensure-MozcPatch' },
    @{ Name = 'Mozc dependency bootstrap'; Text = $buildText; Needle = 'build_tools\update_deps.py' },
    @{ Name = 'forced Mozc platform'; Text = $buildText; Needle = '--platforms=//:windows-x86_64' },
    @{ Name = 'forced x64 CPU'; Text = $buildText; Needle = '--cpu=x64' },
    @{ Name = 'PE machine check'; Text = $packageText; Needle = '0x8664' },
    @{ Name = 'deterministic epoch'; Text = $packageText; Needle = 'SOURCE_DATE_EPOCH is required' },
    @{ Name = 'exact manifest file set'; Text = $packageText; Needle = 'fileSet' },
    @{ Name = 'unimplemented TSF'; Text = $packageText; Needle = "status = 'unimplemented'" }
)
foreach ($check in $staticChecks) {
    if ($check.Text.IndexOf($check.Needle, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Static Windows beta check failed ($($check.Name)); missing: $($check.Needle)"
    }
}
$staleLauncherPattern = ('KanaAi' + 'Beta|KanaAI-' + 'Beta|Verify-KanaAi' + 'Beta|Stop-KanaAi' + 'Beta|Run-KanaAi' + 'Cli')
foreach ($path in $scriptPaths) {
    if ($path -ieq $PSCommandPath) {
        continue
    }
    $text = Get-Content -LiteralPath $path -Raw
    if ($text -match $staleLauncherPattern) {
        throw "A Windows beta script still references a stale launcher name: $path"
    }
}
$notice = Get-Content -LiteralPath (Join-Path $templateRoot 'BETA-NOTICE.txt') -Raw
if ($notice -notmatch 'unsigned' -or $notice -notmatch 'not a registered Windows TSF' -or
    $notice -notmatch 'runtimeVerified remain false') {
    throw 'BETA-NOTICE.txt does not state the unsigned/TSF/readiness boundary.'
}
$buildShellText = Get-Content -LiteralPath (Join-Path $RepoRoot 'platform\windows-tsf\shell\BUILD.bazel') -Raw
if ($buildShellText -notmatch 'not a' -or $buildShellText -notmatch 'TSF DLL' -or
    $buildShellText -match 'name\s*=\s*"[^"]+\.dll"') {
    throw 'The optional Windows shell seam is not explicitly non-TSF.'
}

if (-not $Smoke) {
    [pscustomobject]@{
        ParsedScripts = $scriptPaths.Count
        RequiredFiles = $requiredPaths.Count
        StaticChecks = $staticChecks.Count
        SmokeTest = $false
    }
    return
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('kanai-beta-test-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $testRoot 'payload'
$output = Join-Path $testRoot 'output'
$install = Join-Path $testRoot 'installed'
$data = Join-Path $testRoot 'data'
$extracted = Join-Path $testRoot 'extracted'
New-Item -ItemType Directory -Path (Get-TestPath -Root $payload -Relative 'bin') -Force | Out-Null
New-Item -ItemType Directory -Path (Get-TestPath -Root $payload -Relative 'dist') -Force | Out-Null
try {
    New-TestPeFile -Path (Get-TestPath -Root $payload -Relative 'bin/kanai-api.exe')
    New-TestPeFile -Path (Get-TestPath -Root $payload -Relative 'bin/kanai.exe')
    New-TestPeFile -Path (Get-TestPath -Root $payload -Relative 'bin/kanai-mozc-bridge.exe')
    [System.IO.File]::WriteAllText((Get-TestPath -Root $payload -Relative 'dist/index.html'), '<!doctype html><title>KanaAI test</title>')
    $metadata = [ordered]@{
        version = '0.1.0'
        target = 'x86_64-pc-windows-msvc'
        architecture = 'x64'
        sourceRevision = 'test-revision'
        sourceDateEpoch = '0'
        conversionReady = $false
        runtimeVerified = $false
        tsfStatus = 'unimplemented'
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Get-TestPath -Root $payload -Relative '.build-inputs.json'), $metadata)

    $packageScript = Join-Path $RepoRoot 'scripts\package-windows-beta.ps1'
    $result = & $packageScript -PayloadRoot $payload -OutputDirectory $output -Version '0.1.0' -Target 'x86_64-pc-windows-msvc' -Architecture 'x64' -SourceRevision 'test-revision' -SourceDateEpoch '0' -Force
    if ($null -eq $result -or $result.Status -ne 'beta-workbench-unverified' -or
        $result.PayloadFilesPresent -ne $true -or $result.ConversionReady -ne $false -or
        $result.RuntimeVerified -ne $false) {
        throw 'Package smoke test did not produce an explicitly unverified beta-workbench package.'
    }
    $packageDirectory = [string]$result.PackageDirectory
    $archive = [string]$result.Archive
    if (-not (Test-Path -LiteralPath $packageDirectory -PathType Container)) {
        throw "Package directory was not created: $packageDirectory"
    }
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw "Archive was not created: $archive"
    }

    $verifyScript = Get-TestPath -Root $packageDirectory -Relative 'Verify-KanaAI.ps1'
    & $verifyScript -PackageRoot $packageDirectory | Out-Null
    $manifest = Get-Content -LiteralPath (Get-TestPath -Root $packageDirectory -Relative 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.tsf.status -ne 'unimplemented' -or $manifest.tsf.registered -ne $false -or $manifest.tsf.dllIncluded -ne $false) {
        throw 'Package manifest makes an unsupported TSF claim.'
    }
    if ($manifest.conversionReady -ne $false -or $manifest.runtimeVerified -ne $false -or
        $manifest.payloadFilesPresent -ne $true -or $manifest.modelBundled -ne $false) {
        throw 'Package manifest has unexpected readiness/model fields.'
    }
    if ($manifest.fileSet.count -ne @($manifest.files).Count -or
        $manifest.fileSet.paths.Count -ne @($manifest.files).Count) {
        throw 'Package manifest does not describe the exact payload file set.'
    }
    foreach ($legalName in @('Mozc-LICENSE.txt', 'Mozc-AUTHORS.txt', 'Mozc-CONTRIBUTORS.txt', 'THIRD-PARTY-NOTICES.txt', 'THIRD-PARTY-INVENTORY.json')) {
        if (-not (Test-Path -LiteralPath (Get-TestPath -Root $packageDirectory -Relative ('legal/' + $legalName)) -PathType Leaf)) {
            throw "Package is missing a required third-party notice: $legalName"
        }
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archive, $extracted)
    $topLevel = Get-ChildItem -LiteralPath $extracted -Directory | Select-Object -First 1
    if ($null -eq $topLevel) {
        throw 'Archive did not contain a top-level package directory.'
    }
    $installScript = Get-TestPath -Root $topLevel.FullName -Relative 'Install-KanaAI.ps1'
    & $installScript -InstallRoot $install -DataRoot $data | Out-Null
    if (-not (Test-Path -LiteralPath (Get-TestPath -Root $install -Relative 'manifest.json') -PathType Leaf)) {
        throw 'Install smoke test did not copy the manifest.'
    }
    if (-not (Test-Path -LiteralPath (Get-TestPath -Root $data -Relative 'config/kanai.env') -PathType Leaf)) {
        throw 'Install smoke test did not create the user configuration template.'
    }

    $uninstallScript = Get-TestPath -Root $install -Relative 'Uninstall-KanaAI.ps1'
    & $uninstallScript -InstallRoot $install -DataRoot $data | Out-Null
    if (Test-Path -LiteralPath $install) {
        throw 'Uninstall smoke test left the install directory behind.'
    }
    if (-not (Test-Path -LiteralPath $data -PathType Container)) {
        throw 'Uninstall without RemoveUserData removed retained user data.'
    }

    & $installScript -InstallRoot $install -DataRoot $data | Out-Null
    & $uninstallScript -InstallRoot $install -DataRoot $data -RemoveUserData -Force | Out-Null
    if (Test-Path -LiteralPath $data) {
        throw 'Uninstall with RemoveUserData left the data directory behind.'
    }

    $tampered = Join-Path $testRoot 'tampered'
    Copy-Item -LiteralPath $packageDirectory -Destination $tampered -Recurse -Force
    [System.IO.File]::WriteAllText((Get-TestPath -Root $tampered -Relative 'unexpected.txt'), 'tampered')
    $tamperRejected = $false
    try {
        & $verifyScript -PackageRoot $tampered | Out-Null
    }
    catch {
        $tamperRejected = $true
    }
    if (-not $tamperRejected) {
        throw 'Exact file-set verification accepted an unlisted package file.'
    }

    [pscustomobject]@{
        ParsedScripts = $scriptPaths.Count
        RequiredFiles = $requiredPaths.Count
        StaticChecks = $staticChecks.Count
        SmokeTest = $true
        TamperRejected = $tamperRejected
        RetainedDataSemantics = $true
        Archive = $archive
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
