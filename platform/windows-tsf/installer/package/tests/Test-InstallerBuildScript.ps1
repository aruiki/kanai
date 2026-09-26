[CmdletBinding()]
param(
    # A full WiX/Setup run is intentionally opt-in.  The normal test is
    # offline/source-only and never generates MSI or Setup artifacts.
    [switch]$RunFullBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..'))
$stageScript = Join-Path $repository 'scripts\stage-tsf-runtime.ps1'
$buildScript = Join-Path $repository 'scripts\build-windows-installer.ps1'
$fetchStageScript = Join-Path $repository 'scripts\fetch-stage-pinned-ai-runtime.ps1'
$aiRuntimeManifestPath = Join-Path $repository 'platform\windows-tsf\ai-runtime\manifest-v1.json'
$aiNoticeSourcePath = Join-Path $repository 'platform\windows-tsf\ai-runtime\THIRD-PARTY-NOTICES.txt'
$aiModelLicenseSourcePath = Join-Path $repository 'platform\windows-tsf\ai-runtime\licenses\Qwen-Apache-2.0.txt'
$aiRuntimeLicenseSourcePath = Join-Path $repository 'platform\windows-tsf\ai-runtime\licenses\llama.cpp-MIT.txt'
$packageWxs = Join-Path $repository 'platform\windows-tsf\installer\package\KanaAI.wxs'
foreach ($path in @($stageScript, $buildScript, $fetchStageScript, $aiRuntimeManifestPath, $aiNoticeSourcePath, $aiModelLicenseSourcePath, $aiRuntimeLicenseSourcePath, $packageWxs)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required installer source is missing: $path" }
}

foreach ($scriptPath in @($stageScript, $buildScript, $fetchStageScript, $PSCommandPath)) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw (($parseErrors | ForEach-Object { "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)" }) -join "`n")
    }
}
$buildText = Get-Content -LiteralPath $buildScript -Raw
$stageText = Get-Content -LiteralPath $stageScript -Raw
foreach ($marker in @(
    '[switch]$RequireCleanSource',
    '[switch]$ValidateOnly',
    'function Get-Sha256',
    'function Get-PeImage',
    'function Get-PeExports',
    'function Assert-SnapshotInputs',
    'function New-ImmutableSnapshot',
    'RuntimeManifestSelfHashEmbedded',
    'sourceIdentity',
    'hostOverlayFingerprint',
    'requiredPatchNames',
    'reparse',
    'PE DLL/EXE mismatch',
    '[string]$BrokerExecutable',
    '[string]$AiRuntimeDirectory',
    '[string]$AiManifestPath',
    '[string]$AiReceiptPath',
    'function Assert-AiManifest',
    'function Assert-AiStagedTree',
    'function Assert-AiReceipt',
    'function Assert-AiBroker',
    'function Assert-AiCallerInputs',
    'function New-AiPayloadPlan',
    'function New-AiSanitizedPackageManifest',
    'function Assert-NoAbsolutePathLeak',
    'function New-InstallerWxsFragment',
    'staged-verified-local-ai-runtime',
    'all-or-none',
    'aiOperationVerified',
    'aiStartupTested',
    'llama-server.exe'
)) {
    if ($buildText.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) { throw "Installer build source is missing marker: $marker" }
}
foreach ($marker in @('sourceIdentity', 'hostOverlayFingerprint', 'requiredPatchNames', 'Get-OverlayIdentity', 'Get-PeImage')) {
    if ($stageText.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) { throw "Runtime staging source is missing marker: $marker" }
}
if ($buildText.IndexOf('Get-FileHash', [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Installer build source must not depend on the unavailable Get-FileHash cmdlet.' }
if ($stageText.IndexOf('Get-FileHash', [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Runtime staging source must not depend on the unavailable Get-FileHash cmdlet.' }

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToUpperInvariant() }
    finally { $sha256.Dispose(); $stream.Dispose() }
}

function Set-U16([byte[]]$Bytes, [int]$Offset, [uint16]$Value) {
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 2)
}
function Set-U32([byte[]]$Bytes, [int]$Offset, [uint32]$Value) {
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 4)
}
function Set-U64([byte[]]$Bytes, [int]$Offset, [uint64]$Value) {
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 8)
}

# Generate a small but structurally complete PE image locally.  It has real
# DOS/NT bounds, one bounded section, PE32/PE32+ headers, and (when requested)
# a complete export directory/name/ordinal table.  No binary fixture is
# committed to the repository.
function Write-SyntheticPe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Machine = 0x8664,
        [ValidateSet('Dll', 'Exe')][string]$Type = 'Dll',
        [string[]]$Exports = @()
    )
    $isX64 = $Machine -eq 0x8664
    $isX86 = $Machine -eq 0x014c
    if (-not $isX64 -and -not $isX86) { throw "Synthetic PE machine is unsupported: $Machine" }
    $peOffset = 0x80
    $optionalSize = if ($isX64) { 0xF0 } else { 0xE0 }
    $headerSize = 0x200
    $rawOffset = 0x200
    $rawSize = 0x200
    $bytes = New-Object byte[] 0x400
    Set-U16 $bytes 0 0x5a4d
    Set-U32 $bytes 0x3c ([uint32]$peOffset)
    Set-U32 $bytes $peOffset 0x4550
    Set-U16 $bytes ($peOffset + 4) ([uint16]$Machine)
    Set-U16 $bytes ($peOffset + 6) 1
    Set-U16 $bytes ($peOffset + 20) ([uint16]$optionalSize)
    $characteristics = if ($Type -eq 'Dll') { [uint16]0x2002 } else { [uint16]0x0002 }
    Set-U16 $bytes ($peOffset + 22) $characteristics
    $optional = $peOffset + 24
    if ($isX64) {
        Set-U16 $bytes $optional 0x20b
        Set-U64 $bytes ($optional + 24) 0x140000000
    }
    else {
        Set-U16 $bytes $optional 0x10b
        Set-U32 $bytes ($optional + 28) 0x10000000
    }
    Set-U16 $bytes ($optional + 2) 14
    Set-U32 $bytes ($optional + 4) $rawSize
    Set-U32 $bytes ($optional + 16) 0x1000
    Set-U32 $bytes ($optional + 20) 0x1000
    Set-U32 $bytes ($optional + 32) 0x1000
    Set-U32 $bytes ($optional + 36) 0x200
    Set-U16 $bytes ($optional + 40) 6
    Set-U16 $bytes ($optional + 48) 3
    Set-U32 $bytes ($optional + 56) 0x2000
    Set-U32 $bytes ($optional + 60) $headerSize
    Set-U16 $bytes ($optional + 68) 3
    if ($isX64) {
        Set-U64 $bytes ($optional + 72) 0x100000
        Set-U64 $bytes ($optional + 80) 0x1000
        Set-U64 $bytes ($optional + 88) 0x100000
        Set-U32 $bytes ($optional + 108) 16
    }
    else {
        Set-U32 $bytes ($optional + 72) 0x100000
        Set-U32 $bytes ($optional + 76) 0x1000
        Set-U32 $bytes ($optional + 80) 0x100000
        Set-U32 $bytes ($optional + 92) 16
    }
    $section = $optional + $optionalSize
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('.text' + [char]0), 0, $bytes, $section, 6)
    Set-U32 $bytes ($section + 8) $rawSize
    Set-U32 $bytes ($section + 12) 0x1000
    Set-U32 $bytes ($section + 16) $rawSize
    Set-U32 $bytes ($section + 20) $rawOffset

    if ($Exports.Count -gt 0) {
        $directory = $rawOffset
        $functionRva = 0x1040
        $namesRva = 0x1060
        $ordinalsRva = 0x1080
        $stringsRva = 0x10a0
        $moduleNameRva = 0x11f0
        Set-U32 $bytes ($directory + 12) $moduleNameRva
        Set-U32 $bytes ($directory + 16) 1
        Set-U32 $bytes ($directory + 20) $Exports.Count
        Set-U32 $bytes ($directory + 24) $Exports.Count
        Set-U32 $bytes ($directory + 28) $functionRva
        Set-U32 $bytes ($directory + 32) $namesRva
        Set-U32 $bytes ($directory + 36) $ordinalsRva
        for ($index = 0; $index -lt $Exports.Count; $index++) {
            $name = [string]$Exports[$index]
            $nameRva = [uint32]($stringsRva + ($index * 0x20))
            $nameOffset = $rawOffset + ($nameRva - 0x1000)
            $nameBytes = [Text.Encoding]::ASCII.GetBytes($name)
            [Array]::Copy($nameBytes, 0, $bytes, $nameOffset, $nameBytes.Length)
            $bytes[$nameOffset + $nameBytes.Length] = 0
            Set-U32 $bytes ($rawOffset + ($functionRva - 0x1000) + ($index * 4)) ([uint32](0x1100 + $index))
            Set-U32 $bytes ($rawOffset + ($namesRva - 0x1000) + ($index * 4)) $nameRva
            Set-U16 $bytes ($rawOffset + ($ordinalsRva - 0x1000) + ($index * 2)) ([uint16]$index)
        }
        $moduleOffset = $rawOffset + ($moduleNameRva - 0x1000)
        $moduleBytes = [Text.Encoding]::ASCII.GetBytes('synthetic.dll')
        [Array]::Copy($moduleBytes, 0, $bytes, $moduleOffset, $moduleBytes.Length)
        $bytes[$moduleOffset + $moduleBytes.Length] = 0
        $directoryOffset = if ($isX64) { 112 } else { 96 }
        Set-U32 $bytes ($optional + $directoryOffset) 0x1000
        Set-U32 $bytes ($optional + $directoryOffset + 4) 0x200
    }
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-TextSha256([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Write-Utf8Json {
    param([string]$Path, $Value)
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine), $utf8)
}

# Build a small deterministic runtime fixture archive whose entries are
# structurally valid PE images.  No real model, weight, or llama.cpp runtime is
# downloaded or committed for this test.
function New-FixtureArchive {
    param([string]$Path, [object[]]$Entries)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($spec in $Entries) {
            $entry = $zip.CreateEntry([string]$spec.Name)
            $stream = $entry.Open()
            try {
                $bytes = [byte[]]$spec.Bytes
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally { $stream.Dispose() }
        }
    }
    finally { if ($null -ne $zip) { $zip.Dispose() } }
}

function Get-SortedEntryNameDigest([string[]]$Names) {
    [string[]]$ordered = @($Names)
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    return Get-TextSha256 ((($ordered -join "`n") + "`n"))
}

function Invoke-BuildValidation {
    param(
        [string]$RuntimePath,
        [string]$HelperPath,
        [string]$ManifestPath,
        [string]$OutputPath = '',
        [switch]$RequireCleanSource,
        [string]$BrokerPath = '',
        [string]$AiRootPath = '',
        [string]$AiManifestPath = '',
        [string]$AiReceiptPath = '',
        [switch]$AiFixtureMode,
        [switch]$SkipSourceIdentity
    )
    $parameters = @{
        RuntimeDirectory = $RuntimePath
        InstallerHelper = $HelperPath
        RuntimeManifestPath = $ManifestPath
        ValidateOnly = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { $parameters['OutputDirectory'] = $OutputPath }
    if ($RequireCleanSource) { $parameters['RequireCleanSource'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($BrokerPath)) { $parameters['BrokerExecutable'] = $BrokerPath }
    if (-not [string]::IsNullOrWhiteSpace($AiRootPath)) { $parameters['AiRuntimeDirectory'] = $AiRootPath }
    if (-not [string]::IsNullOrWhiteSpace($AiManifestPath)) { $parameters['AiManifestPath'] = $AiManifestPath }
    if (-not [string]::IsNullOrWhiteSpace($AiReceiptPath)) { $parameters['AiReceiptPath'] = $AiReceiptPath }
    if ($AiFixtureMode) { $parameters['AiFixtureMode'] = $true }
    # Negative payload cases must reach the validator under test. Re-checking
    # the repository source identity first would mask the intended failure with
    # an unrelated "source changed" error, because this very test file and the
    # builder are part of the recorded build-input identity.
    if ($SkipSourceIdentity) { $parameters['SkipSourceIdentity'] = $true }
    return (& $buildScript @parameters)
}

function Get-FailureMessage {
    param([scriptblock]$Action)
    try {
        & $Action | Out-Null
        return ''
    }
    catch { return [string]$_.Exception.Message }
}

function Save-FileBytes([string]$Path) { return ,([IO.File]::ReadAllBytes($Path)) }
function Restore-FileBytes([string]$Path, [byte[]]$Bytes) { [IO.File]::WriteAllBytes($Path, $Bytes) }
function Remove-TestJunction([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    # A junction is a reparse point, not a real directory. On PowerShell 5.1
    # Remove-Item without -Recurse reports "the item at ... has children" and
    # raises a confirmation prompt. -ErrorAction does NOT suppress that prompt
    # (only -Confirm does), so a non-interactive run blocks forever and the
    # catch fallback below is never reached. Adding -Recurse instead is worse:
    # it can walk into the link target and delete the real runtime files.
    # Measured this session: the run hung on runtime-junction, and deleting the
    # reparse point with Directory::Delete(path, $false) removed the junction
    # while leaving the target's 12 files intact.
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) {
        try { [IO.Directory]::Delete($Path, $false); return } catch { }
    }
    try { Remove-Item -LiteralPath $Path -Force -Recurse -Confirm:$false -ErrorAction Stop }
    catch {
        try { [IO.Directory]::Delete($Path, $false) } catch { }
    }
}

$localRoot = [IO.Path]::GetFullPath((Join-Path $repository '.local')).TrimEnd('\') + '\'
$testRoot = [IO.Path]::GetFullPath((Join-Path $localRoot ('test-results\installer-build-' + [Guid]::NewGuid().ToString('N'))))
if (-not $testRoot.StartsWith($localRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe installer test directory: $testRoot" }
$runtime = Join-Path $testRoot 'runtime'
$helperDirectory = Join-Path $testRoot 'helper'
$redist = Join-Path $testRoot 'redist'
$bazelRoot = Join-Path $testRoot 'bazel-output'
$output = Join-Path $testRoot 'installer-output'
$manifestPath = Join-Path $testRoot 'runtime-manifest.json'
$junctionPath = Join-Path $testRoot 'runtime-junction'
$reparseStatus = 'not-run'
$fullBuildStatus = 'not-run (offline test; -RunFullBuild is an explicit opt-in)'
$sourceBytes = $null
$patchBytes = $null
$overlayBytes = $null
$sourcePath = Join-Path $repository 'platform\windows-tsf\installer\package\KanaAI.wxs'
$patchPath = Join-Path $repository 'platform\windows-tsf\tsf\patches\0001-install-kanai-supplemental-model.patch'
$overlayPath = Join-Path $repository 'platform\windows-tsf\tsf\host_overlay\engine\kanai_ai\rank_policy.h'
# Declared before the try block so the finally block can always clean up.
$aiFixtureId = [Guid]::NewGuid().ToString('N')
$aiFixtureRoot = Join-Path $localRoot ('test-results\airuntime-staging-' + $aiFixtureId)
$aiStageRoot = $aiFixtureRoot + '-stage'
$aiJunction = Join-Path $aiStageRoot 'licenses-junction'
try {
    New-Item -ItemType Directory -Path $runtime, $helperDirectory, $redist, $bazelRoot, $output -Force | Out-Null
    $runtimeSpec = @(
        @{ Name = 'mozc_tip64.dll'; Machine = 0x8664; Type = 'Dll'; Exports = @('DllGetClassObject', 'DllCanUnloadNow') }
        @{ Name = 'mozc_tip32.dll'; Machine = 0x014c; Type = 'Dll'; Exports = @('DllGetClassObject', 'DllCanUnloadNow') }
        @{ Name = 'mozc_server.exe'; Machine = 0x8664; Type = 'Exe'; Exports = @() }
        @{ Name = 'mozc_renderer.exe'; Machine = 0x8664; Type = 'Exe'; Exports = @() }
        @{ Name = 'mozc_broker.exe'; Machine = 0x8664; Type = 'Exe'; Exports = @() }
    )
    foreach ($spec in $runtimeSpec) { Write-SyntheticPe -Path (Join-Path $bazelRoot $spec.Name) -Machine $spec.Machine -Type $spec.Type -Exports $spec.Exports }
    foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) { Write-SyntheticPe -Path (Join-Path $redist $name) -Machine 0x8664 -Type 'Dll' }
    $helperExports = @('RegisterTIP', 'RegisterTIPRollback', 'UnregisterTIP', 'UnregisterTIPRollback', 'EnableTipProfile', 'RestoreUserIMEEnvironment', 'ShutdownServer')
    Write-SyntheticPe -Path (Join-Path $bazelRoot 'mozc_installer_helper.dll') -Machine 0x8664 -Type 'Dll' -Exports $helperExports

    # The real staging script is exercised with synthetic build outputs.  It
    # reads only local files and writes the provenance-bound manifest.
    $staged = & $stageScript -BazelOutputRoot $bazelRoot -OutputDirectory $runtime -InstallerHelperDirectory $helperDirectory -RedistDirectory $redist -ManifestPath $manifestPath
    $helper = Join-Path $helperDirectory 'mozc_installer_helper.dll'
    $manifestHash = Get-Sha256 -Path $manifestPath
    if ($staged.ManifestSha256 -ne $manifestHash -or $staged.FileCount -ne 12) { throw 'Offline runtime staging did not return the expected manifest receipt.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.sourceIdentity.status -notin @('verified', 'verified-dirty') -or
        [string]$manifest.sourceIdentity.hostOverlayFingerprint -notmatch '^[0-9A-Fa-f]{64}$' -or
        @($manifest.sourceIdentity.patches).Count -ne 6 -or
        [string]$manifest.sourceIdentity.artifactBuildLinkage.status -ne 'unverified') { throw ("Staged manifest is missing required provenance identity (status={0}, overlay={1}, patches={2}, reasons={3})." -f $manifest.sourceIdentity.status, $manifest.sourceIdentity.hostOverlayFingerprint, @($manifest.sourceIdentity.patches).Count, (@($manifest.sourceIdentity.reasons) -join ' || ')) }
    $expectedPatchNames = @('0001-install-kanai-supplemental-model.patch', '0002-kanai-tsf-identity.patch', '0003-session-generation-binding.patch', '0004-windows-python-toolchain.patch', '0005-windows-runtime-identity.patch', '0006-windows-installer-runtime-path.patch')
    $actualPatchNames = @($manifest.sourceIdentity.patches | ForEach-Object { [string]$_.name })
    if ((($actualPatchNames -join '|') -ne ($expectedPatchNames -join '|')) -or @($manifest.sourceIdentity.patches | Where-Object { [string]$_.sha256 -notmatch '^[0-9A-Fa-f]{64}$' }).Count -gt 0) { throw 'Staged manifest does not name and hash the exact required patch set.' }

    $validated = Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath
    if ($validated.Validated -ne $true -or $validated.SnapshotValidation -ne 'passed' -or
        $validated.RuntimeManifestSha256 -ne $manifestHash -or $validated.RuntimeManifestSelfHashEmbedded -ne $false -or
        $validated.SourceCommit -notmatch '^[0-9a-f]{40}$' -or $validated.MozcCommit -notmatch '^[0-9a-f]{40}$' -or
        $validated.PatchCount -ne 6 -or $validated.HostOverlayFingerprint -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'Installer ValidateOnly did not return the expected immutable-input receipt.'
    }
    # The traditional invocation is still the exact non-AI path.
    if ($validated.AiMode -ne $false -or $validated.LocalAiIncluded -ne $false -or
        $validated.AiOperationVerified -ne $false -or $validated.AiStartupTested -ne $false -or
        $validated.InstalledInputVerified -ne $false -or $validated.Verified -ne $false -or
        $validated.AiPayloadCount -ne 0 -or @($validated.AiPayloadRelativePaths).Count -ne 0 -or
        $null -ne $validated.AiManifestSha256 -or $null -ne $validated.AiReceiptSha256 -or
        $null -ne $validated.AiPackageManifestSha256 -or $null -ne $validated.AiSnapshotRoot) {
        throw 'The AI-less ValidateOnly receipt does not report the exact non-AI shape.'
    }
    if ($validated.AiFragmentText -match 'AIFOLDER|kanai-broker|<DirectoryRef') { throw 'The AI-less fragment unexpectedly declares local-AI payload.' }
    if (Test-Path -LiteralPath (Join-Path $output 'KanaAI-0.1.0-x64.msi')) { throw 'ValidateOnly generated an MSI.' }
    if (Test-Path -LiteralPath (Join-Path $output 'KanaAI-0.1.0-Setup.exe')) { throw 'ValidateOnly generated Setup.exe.' }

    $path = Join-Path $runtime 'mozc_tip64.dll'; $original = Save-FileBytes $path; try { $bytes = [IO.File]::ReadAllBytes($path); $bytes[0] = 0; [IO.File]::WriteAllBytes($path, $bytes); $badMagic = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $path $original }
    if ($badMagic -notmatch 'DOS magic|MZ signature|PE') { throw "Bad PE magic was not rejected: $badMagic" }

    $path = Join-Path $runtime 'mozc_server.exe'; $original = Save-FileBytes $path; try { [IO.File]::WriteAllBytes($path, (New-Object byte[] 64)); $truncated = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $path $original }
    if ($truncated -notmatch 'Truncated|DOS|PE') { throw "Truncated PE headers were not rejected: $truncated" }

    $path = Join-Path $runtime 'mozc_tip64.dll'; $original = Save-FileBytes $path; try { Write-SyntheticPe -Path $path -Machine 0x014c -Type 'Dll' -Exports @('DllGetClassObject', 'DllCanUnloadNow'); $wrongMachine = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $path $original }
    if ($wrongMachine -notmatch 'architecture|machine|optional') { throw "Wrong PE machine was not rejected: $wrongMachine" }

    $path = Join-Path $runtime 'mozc_tip64.dll'; $original = Save-FileBytes $path; try { $bytes = [IO.File]::ReadAllBytes($path); [Array]::Copy([BitConverter]::GetBytes([uint16]0x10b), 0, $bytes, 0x98, 2); [IO.File]::WriteAllBytes($path, $bytes); $optionalMagic = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $path $original }
    if ($optionalMagic -notmatch 'optional-header|optional|magic|architecture') { throw "PE32/PE32+ optional magic mismatch was not rejected: $optionalMagic" }

    $path = Join-Path $runtime 'mozc_tip64.dll'; $original = Save-FileBytes $path; try { Write-SyntheticPe -Path $path -Machine 0x8664 -Type 'Exe'; $typeMismatch = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $path $original }
    if ($typeMismatch -notmatch 'DLL/EXE|DLL|EXE') { throw "DLL/EXE mismatch was not rejected: $typeMismatch" }

    $originalHelper = Save-FileBytes $helper; try { Write-SyntheticPe -Path $helper -Machine 0x8664 -Type 'Dll' -Exports @('RegisterTIP'); $missingExport = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $helper $originalHelper }
    if ($missingExport -notmatch 'Missing required export|export') { throw "Missing helper export was not rejected: $missingExport" }

    $path = Join-Path $runtime 'mozc_server.exe'; $original = Save-FileBytes $path; try { [IO.File]::AppendAllText($path, 'payload-mutation'); $payloadMutation = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $path $original }
    if ($payloadMutation -notmatch 'does not match its staged manifest|payload') { throw "Payload mutation was not rejected: $payloadMutation" }

    $originalHelper = Save-FileBytes $helper; try { [IO.File]::AppendAllText($helper, 'helper-mutation'); $helperMutation = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $helper $originalHelper }
    if ($helperMutation -notmatch 'does not match its staged manifest|helper') { throw "Helper mutation was not rejected: $helperMutation" }

    $sourceBytes = Save-FileBytes $sourcePath
    try { [IO.File]::AppendAllText($sourcePath, "`n<!-- RV2 mutation probe -->`n"); $sourceMutation = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $sourcePath $sourceBytes }
    if ($sourceMutation -notmatch 'source identity|source|build configuration') { throw "Source mutation was not rejected: $sourceMutation" }

    $patchBytes = Save-FileBytes $patchPath
    try { [IO.File]::AppendAllText($patchPath, "`n# RV2 mutation probe`n"); $patchMutation = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $patchPath $patchBytes }
    if ($patchMutation -notmatch 'source identity|patch|build configuration') { throw "Patch mutation was not rejected: $patchMutation" }

    $overlayBytes = Save-FileBytes $overlayPath
    try { [IO.File]::AppendAllText($overlayPath, "`n// RV2 overlay mutation probe`n"); $overlayMutation = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity } } finally { Restore-FileBytes $overlayPath $overlayBytes }
    if ($overlayMutation -notmatch 'source identity|overlay|build configuration') { throw "Overlay mutation was not rejected: $overlayMutation" }

    $originalManifest = Save-FileBytes $manifestPath
    try {
        $manifestObject = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifestObject | Add-Member -NotePropertyName manifestSha256 -NotePropertyValue ('0' * 64)
        $manifestObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $selfHash = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity }
    } finally { Restore-FileBytes $manifestPath $originalManifest }
    if ($selfHash -notmatch 'own SHA-256|self.*hash') { throw "Manifest self-hash was not rejected: $selfHash" }

    # Reparse roots are rejected before any snapshot is made.  Junction
    # creation is not available on every Windows account, so this explicit
    # negative remains opt-in-by-capability rather than faking a pass.
    try {
        New-Item -ItemType Junction -Path $junctionPath -Target $runtime -ErrorAction Stop | Out-Null
        $junctionMessage = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $junctionPath -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output }
        if ($junctionMessage -notmatch 'Reparse|reparse|path') { throw "Reparse runtime root was not rejected: $junctionMessage" }
        $reparseStatus = 'rejected'
    }
    catch {
        if ($_.Exception.Message -match 'not recognized|cannot create|not supported|access is denied') { $reparseStatus = 'not-supported-on-this-host' }
        else { throw }
    }
    finally {
        Remove-TestJunction $junctionPath
    }

    $sourceDirty = @(git -C $repository status --porcelain=v1 --untracked-files=normal).Count -ne 0
    if ($LASTEXITCODE -ne 0) { throw "git status failed with exit code $LASTEXITCODE" }
    $cleanGuardRejected = $false
    if ($sourceDirty) {
        $cleanMessage = Get-FailureMessage { Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity -RequireCleanSource }
        $cleanGuardRejected = $cleanMessage -match 'clean source tree'
        if (-not $cleanGuardRejected) { throw ("RequireCleanSource did not reject a dirty tree (manifestDirty={0}, gitStatusCount={1}, message={2})." -f [bool]$manifest.sourceIdentity.repositoryDirty, @(git -C $repository status --porcelain=v1 --untracked-files=normal).Count, $cleanMessage) }
    }

    # ------------------------------------------------------------------
    # Local AI payload.  Everything below is synthetic and offline: a small
    # fixture weight, a three-entry PE runtime closure, the real pinned license
    # and notice text, and a structurally valid synthetic x64 broker.  No real
    # 1.1 GB weight, no llama.cpp runtime, and no large binary is used or added.
    # ------------------------------------------------------------------
    $aiFixtureManifestPath = Join-Path $aiFixtureRoot 'manifest.json'
    $aiBrokerDirectory = Join-Path $testRoot 'ai-broker'
    $aiBrokerPath = Join-Path $aiBrokerDirectory 'kanai-broker.exe'
    $aiRejectionOutput = Join-Path $testRoot 'never-created-output'
    $aiModelFixturePath = Join-Path $aiFixtureRoot 'model-fixture.bin'
    $aiArchiveFixturePath = Join-Path $aiFixtureRoot 'runtime-fixture.zip'
    $aiReceiptPath = Join-Path $aiStageRoot 'STAGING-RECEIPT.json'
    $aiSanitizedPath = Join-Path $aiStageRoot 'PACKAGE-MANIFEST.json'
    $aiServerEntry = 'llama-server.exe'
    $aiModelFixtureName = 'model-fixture.bin'
    $aiClosureNames = @('ggml.dll', 'llama-server-impl.dll', $aiServerEntry)
    $aiModelFixtureBytes = 4096
    $aiModelFixtureSha256 = $null
    $aiPayloadVerified = $false
    $aiRejections = [ordered]@{}
    New-Item -ItemType Directory -Path $aiFixtureRoot, $aiBrokerDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $aiFixtureRoot 'licenses') -Force | Out-Null
    Copy-Item -LiteralPath $aiModelLicenseSourcePath -Destination (Join-Path $aiFixtureRoot 'licenses\Qwen-Apache-2.0.txt')
    Copy-Item -LiteralPath $aiRuntimeLicenseSourcePath -Destination (Join-Path $aiFixtureRoot 'licenses\llama.cpp-MIT.txt')
    Copy-Item -LiteralPath $aiNoticeSourcePath -Destination (Join-Path $aiFixtureRoot 'THIRD-PARTY-NOTICES.txt')
    $aiModelFixtureContent = New-Object byte[] $aiModelFixtureBytes
    for ($aiIndex = 0; $aiIndex -lt $aiModelFixtureBytes; $aiIndex++) { $aiModelFixtureContent[$aiIndex] = [byte](($aiIndex * 7) % 251) }
    [IO.File]::WriteAllBytes($aiModelFixturePath, $aiModelFixtureContent)
    $aiModelFixtureSha256 = Get-Sha256 -Path $aiModelFixturePath
    $aiServerPePath = Join-Path $aiFixtureRoot 'llama-server.exe.synthetic'
    $aiServerImplPePath = Join-Path $aiFixtureRoot 'llama-server-impl.dll.synthetic'
    $aiGgmlPePath = Join-Path $aiFixtureRoot 'ggml.dll.synthetic'
    Write-SyntheticPe -Path $aiServerPePath -Machine 0x8664 -Type 'Exe' -Exports @()
    Write-SyntheticPe -Path $aiServerImplPePath -Machine 0x8664 -Type 'Dll' -Exports @('llamaServerImpl')
    Write-SyntheticPe -Path $aiGgmlPePath -Machine 0x8664 -Type 'Dll' -Exports @('ggmlInitialize')
    # The Rust broker is a distinct x64 executable, not a renamed copy of any
    # Mozc payload file or of llama-server.exe.
    Write-SyntheticPe -Path $aiBrokerPath -Machine 0x8664 -Type 'Exe' -Exports @('KanaiBrokerEntry')
    New-FixtureArchive $aiArchiveFixturePath @(
        [pscustomobject]@{ Name = 'ggml.dll'; Bytes = ([IO.File]::ReadAllBytes($aiGgmlPePath)) },
        [pscustomobject]@{ Name = 'llama-server-impl.dll'; Bytes = ([IO.File]::ReadAllBytes($aiServerImplPePath)) },
        [pscustomobject]@{ Name = $aiServerEntry; Bytes = ([IO.File]::ReadAllBytes($aiServerPePath)) }
    )
    $aiFixtureManifest = [IO.File]::ReadAllText($aiRuntimeManifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $aiFixtureManifest.model.weight.fileName = $aiModelFixtureName
    $aiFixtureManifest.model.weight.bytes = $aiModelFixtureBytes
    $aiFixtureManifest.model.weight.sha256 = $aiModelFixtureSha256
    $aiFixtureManifest.model.weight.lfsSha256 = $aiModelFixtureSha256
    $aiFixtureManifest.runtime.asset.fileName = 'runtime-fixture.zip'
    $aiFixtureManifest.runtime.asset.bytes = (Get-Item -LiteralPath $aiArchiveFixturePath -Force).Length
    $aiFixtureManifest.runtime.asset.sha256 = Get-Sha256 -Path $aiArchiveFixturePath
    $aiFixtureManifest.runtime.archive.entryPolicy.allowedExactEntries = @($aiClosureNames)
    $aiFixtureManifest.runtime.archive.entryPolicy.requiredEntries = @('llama-server-impl.dll', $aiServerEntry)
    $aiFixtureManifest.runtime.archive.entryPolicy.entryCount = $aiClosureNames.Count
    $aiFixtureManifest.runtime.archive.entryPolicy.entryNamesSha256 = Get-SortedEntryNameDigest $aiClosureNames
    # The broker is a pinned part of the shipped AI bundle. Bind the fixture
    # manifest to the synthetic broker bytes so the digest check stays
    # meaningful without depending on a real release build.
    $aiFixtureManifest.broker.bytes = (Get-Item -LiteralPath $aiBrokerPath -Force).Length
    $aiFixtureManifest.broker.sha256 = Get-Sha256 -Path $aiBrokerPath
    Write-Utf8Json $aiFixtureManifestPath $aiFixtureManifest

    # The real A2-01 staging script produces the staged tree and the raw
    # receipt, so the builder is checked against that exact receipt shape.
    $aiStaged = & $fetchStageScript -ManifestPath $aiFixtureManifestPath -ModelPath $aiModelFixturePath -RuntimeArchivePath $aiArchiveFixturePath -OutputDirectory $aiStageRoot -Stage -FixtureMode
    if (-not ($aiStaged.Mode -eq 'stage' -and $aiStaged.NetworkUsed -eq $false -and $aiStaged.RuntimeEntries -eq 3)) {
        throw 'The synthetic local AI staging did not produce the expected receipt.'
    }
    if (-not (Test-Path -LiteralPath $aiReceiptPath -PathType Leaf)) { throw 'The synthetic local AI staging receipt is missing.' }
    $aiRawReceiptText = [IO.File]::ReadAllText($aiReceiptPath, [Text.Encoding]::UTF8)
    # A2-01 now emits a portable, relative-only receipt. It must carry no host
    # absolute path and no serialized PowerShell object graph, so the builder
    # can validate it without ever copying build-machine identity.
    foreach ($leak in @('[A-Za-z]:\\', '\\\\', '"PSDrive"', '"Credential"', '"Password"', '"MetadataToken"', '"DirectoryName"')) {
        if ($aiRawReceiptText.IndexOf($leak, [StringComparison]::Ordinal) -ge 0) {
            throw "The staging receipt leaks build-machine identity: $leak"
        }
    }
    # A2-01 also produced a sanitized, relative-only package manifest beside the
    # receipt.  The builder validates it when it is present.
    $aiSanitizedManifest = [ordered]@{
        schemaVersion = 1
        status = 'staged-verified-local-ai-runtime-sanitized'
        sourceManifest = [ordered]@{ fileName = 'manifest.json'; sha256 = (Get-Sha256 -Path $aiFixtureManifestPath) }
        rawReceiptSha256 = (Get-Sha256 -Path $aiReceiptPath)
        model = [ordered]@{ path = ('model/' + $aiModelFixtureName); bytes = $aiModelFixtureBytes; sha256 = $aiModelFixtureSha256; license = 'Apache-2.0' }
        runtime = [ordered]@{
            path = 'runtime'
            bytes = $aiFixtureManifest.runtime.asset.bytes
            sha256 = $aiFixtureManifest.runtime.asset.sha256
            release = 'b11146'
            revision = '7fe450e19305b828c199d602c23a8337aaa1f03b'
            license = 'MIT'
            entries = @($aiFixtureManifest.runtime.archive.entryPolicy.allowedExactEntries | Sort-Object | ForEach-Object {
                $stagedEntry = Join-Path (Join-Path $aiStageRoot 'runtime') ([string]$_)
                [ordered]@{ path = ('runtime/' + [string]$_); bytes = [int64](Get-Item -LiteralPath $stagedEntry -Force).Length; sha256 = (Get-Sha256 -Path $stagedEntry) }
            })
        }
        licenses = @()
        networkUsed = $false
        aiOperationVerified = $false
        installedInputVerified = $false
        containsAbsolutePaths = $false
    }
    foreach ($license in @(
        [pscustomobject]@{ Path = 'licenses\Qwen-Apache-2.0.txt'; Install = 'licenses/Qwen-Apache-2.0.txt' },
        [pscustomobject]@{ Path = 'licenses\llama.cpp-MIT.txt'; Install = 'licenses/llama.cpp-MIT.txt' },
        [pscustomobject]@{ Path = 'THIRD-PARTY-NOTICES.txt'; Install = 'THIRD-PARTY-NOTICES.txt' }
    )) {
        $licenseSource = Join-Path $aiStageRoot $license.Path
        $aiSanitizedManifest.licenses += [ordered]@{ path = $license.Install; bytes = [int64](Get-Item -LiteralPath $licenseSource -Force).Length; sha256 = (Get-Sha256 -Path $licenseSource) }
    }
    Write-Utf8Json $aiSanitizedPath $aiSanitizedManifest

    $aiExpectedPayload = @(
        'kanai-broker.exe',
        ('ai/model/' + $aiModelFixtureName),
        'ai/runtime/ggml.dll',
        'ai/runtime/llama-server-impl.dll',
        ('ai/runtime/' + $aiServerEntry),
        'ai/licenses/Qwen-Apache-2.0.txt',
        'ai/licenses/llama.cpp-MIT.txt',
        'ai/THIRD-PARTY-NOTICES.txt'
    )
    $aiValidation = Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity -BrokerPath $aiBrokerPath -AiRootPath $aiStageRoot -AiManifestPath $aiFixtureManifestPath -AiReceiptPath $aiReceiptPath -AiFixtureMode
    if ($aiValidation.AiMode -ne $true -or $aiValidation.LocalAiIncluded -ne $true -or
        $aiValidation.AiOperationVerified -ne $false -or $aiValidation.AiStartupTested -ne $false -or
        $aiValidation.InstalledInputVerified -ne $false -or $aiValidation.Verified -ne $false) {
        throw 'The local AI ValidateOnly receipt does not separate included bytes from verified AI operation.'
    }
    if ($aiValidation.AiPayloadCount -ne $aiExpectedPayload.Count -or
        ((@($aiValidation.AiPayloadRelativePaths) -join '|') -ne ($aiExpectedPayload -join '|'))) {
        throw ("The local AI payload plan is not the expected relative payload set: {0}" -f (@($aiValidation.AiPayloadRelativePaths) -join ', '))
    }
    if ($aiValidation.AiManifestSha256 -ne (Get-Sha256 -Path $aiFixtureManifestPath) -or
        $aiValidation.AiReceiptSha256 -ne (Get-Sha256 -Path $aiReceiptPath) -or
        $aiValidation.AiPackageManifestSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
        $aiValidation.AiRuntimeEntryCount -ne 3 -or
        $aiValidation.AiModelInstallPath -ne ('ai/model/' + $aiModelFixtureName) -or
        $aiValidation.AiBrokerInstallPath -ne 'kanai-broker.exe' -or
        $aiValidation.AiBrokerName -ne 'kanai-broker.exe' -or
        $aiValidation.AiBrokerSha256 -ne (Get-Sha256 -Path $aiBrokerPath)) {
        throw 'The local AI ValidateOnly receipt does not record the reviewed identities.'
    }
    $aiFragmentText = [string]$aiValidation.AiFragmentText
    foreach ($expected in @(
        '<DirectoryRef Id="INSTALLFOLDER">',
        '<Directory Id="AIFOLDER" Name="ai">',
        '<Directory Id="AIMODELFOLDER" Name="model" />',
        '<Directory Id="AIRUNTIMEFOLDER" Name="runtime" />',
        '<Directory Id="AILICENSEFOLDER" Name="licenses" />',
        ('Name="kanai-broker.exe"'),
        ('Name="' + $aiModelFixtureName + '"'),
        ('Name="' + $aiServerEntry + '"'),
        ('Name="THIRD-PARTY-NOTICES.txt"'),
        ('Name="Qwen-Apache-2.0.txt"'),
        ('Name="llama.cpp-MIT.txt"')
    )) {
        if ($aiFragmentText.IndexOf($expected, [StringComparison]::Ordinal) -lt 0) { throw "The generated local AI fragment is missing an expected declaration: $expected" }
    }
    if ($aiFragmentText -match 'STAGING-RECEIPT|PACKAGE-MANIFEST|ai-source') {
        throw 'The generated local AI fragment references a build input instead of reviewed payload bytes.'
    }
    if ($aiFragmentText.IndexOf($aiStageRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $aiFragmentText.IndexOf($aiFixtureRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $aiFragmentText.IndexOf($aiBrokerDirectory, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw 'The generated local AI fragment references a caller source path outside the immutable snapshot.'
    }
    foreach ($sourceMatch in [regex]::Matches($aiFragmentText, 'Source="([^"]*)"')) {
        if (-not ([string]$sourceMatch.Groups[1].Value).StartsWith([string]$aiValidation.SnapshotRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The generated fragment references a source outside the immutable snapshot: $($sourceMatch.Groups[1].Value)"
        }
    }
    foreach ($sourceMatch in [regex]::Matches($aiFragmentText, 'Source="([^"]*)"')) {
        if (([string]$sourceMatch.Groups[1].Value).IndexOf('ai-source', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "The generated fragment references the local AI build-input directory: $($sourceMatch.Groups[1].Value)"
        }
    }
    $aiComponentCount = ([regex]::Matches($aiFragmentText, '<Component\b')).Count
    if ($aiComponentCount -ne (12 + $aiExpectedPayload.Count)) { throw "The generated fragment has an unexpected component count: $aiComponentCount" }
    # The sanitized public AI record is relative-only: no drive, UNC, URL, user
    # name, repository path, or staging path may appear in it.
    $aiPackageText = [string]$aiValidation.AiPackageManifestText
    if ($aiPackageText -match '(?i)([a-z]:[\\/]|\\\\[a-z0-9._-]+\\|/users/|/home/|file://)') { throw 'The sanitized local AI package manifest contains an absolute or URL path.' }
    foreach ($token in @($env:USERNAME, $env:USERPROFILE, $repository, $aiStageRoot, $aiFixtureRoot, 'platform/windows-tsf', 'third_party', '.local', 'STAGING-RECEIPT.json')) {
        if ([string]::IsNullOrWhiteSpace([string]$token)) { continue }
        if ($aiPackageText.IndexOf([string]$token, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "The sanitized local AI package manifest leaks a build-machine token: $token" }
    }
    foreach ($needle in @('"status":  "staged-verified-local-ai-runtime-sanitized"', '"included":  true', '"aiOperationVerified":  false', '"aiStartupTested":  false', '"installedInputVerified":  false', '"verified":  false', '"containsAbsolutePaths":  false', '"networkUsed":  false', '"payloadFileCount":  8')) {
        if ($aiPackageText.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) { throw "The sanitized local AI package manifest is missing an expected non-claim field: $needle" }
    }
    if ($aiPackageText -notmatch '"payload"') { throw 'The sanitized local AI package manifest does not list the payload plan.' }
    if (Test-Path -LiteralPath (Join-Path $output 'KanaAI-0.1.0-x64.msi')) { throw 'The local AI ValidateOnly generated an MSI.' }
    if (Test-Path -LiteralPath (Join-Path $output 'KanaAI-0.1.0-Setup.exe')) { throw 'The local AI ValidateOnly generated Setup.exe.' }
    if (@(Get-ChildItem -LiteralPath $output -Force -File).Count -ne 0) { throw 'The local AI ValidateOnly published files into the output directory.' }
    $aiPayloadVerified = $true

    function Get-AiRejection {
        param([scriptblock]$Action, [string]$Pattern, [string]$Label)
        $message = Get-FailureMessage $Action
        if ($message -eq '') { throw "The local AI negative case was not rejected: $Label" }
        if ($message -notmatch $Pattern) { throw "The local AI negative case '$Label' produced an unexpected message: $message" }
        $script:aiRejections[$Label] = $true
    }

    $aiOriginal = [ordered]@{}
    # The manifest is restored too: a negative case that mutates and re-writes
    # it must not leave a document missing the pinned broker identity for the
    # cases that follow.
    $aiOriginal['manifest'] = Save-FileBytes $aiFixtureManifestPath
    $aiOriginal['receipt'] = Save-FileBytes $aiReceiptPath
    $aiOriginal['sanitized'] = Save-FileBytes $aiSanitizedPath
    $aiOriginal['broker'] = Save-FileBytes $aiBrokerPath
    $aiOriginal['model'] = Save-FileBytes (Join-Path $aiStageRoot ('model/' + $aiModelFixtureName))
    $aiOriginal['server'] = Save-FileBytes (Join-Path $aiStageRoot ('runtime/' + $aiServerEntry))
    $aiOriginal['modelLicense'] = Save-FileBytes (Join-Path $aiStageRoot 'licenses\Qwen-Apache-2.0.txt')
    $aiOriginal['runtimeLicense'] = Save-FileBytes (Join-Path $aiStageRoot 'licenses\llama.cpp-MIT.txt')
    $aiOriginal['notice'] = Save-FileBytes (Join-Path $aiStageRoot 'THIRD-PARTY-NOTICES.txt')
    $aiManifestObject = $null
    $aiReceiptObject = $null
    $aiSanitizedObject = $null
    $aiRestoreFixture = {
        # Restore every mutated byte, then re-read the fixture documents so the
        # next negative case starts from the on-disk state. Mutating a parsed
        # PSCustomObject can drop sibling blocks (the broker pin in
        # particular), which would mask the intended failure.
        Restore-FileBytes $aiFixtureManifestPath $aiOriginal['manifest']
        Restore-FileBytes $aiReceiptPath $aiOriginal['receipt']
        Restore-FileBytes $aiSanitizedPath $aiOriginal['sanitized']
        Restore-FileBytes $aiBrokerPath $aiOriginal['broker']
        Restore-FileBytes (Join-Path $aiStageRoot ('model/' + $aiModelFixtureName)) $aiOriginal['model']
        Restore-FileBytes (Join-Path $aiStageRoot ('runtime/' + $aiServerEntry)) $aiOriginal['server']
        Restore-FileBytes (Join-Path $aiStageRoot 'licenses\Qwen-Apache-2.0.txt') $aiOriginal['modelLicense']
        Restore-FileBytes (Join-Path $aiStageRoot 'licenses\llama.cpp-MIT.txt') $aiOriginal['runtimeLicense']
        Restore-FileBytes (Join-Path $aiStageRoot 'THIRD-PARTY-NOTICES.txt') $aiOriginal['notice']
        $script:aiManifestObject = [IO.File]::ReadAllText($aiFixtureManifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $script:aiReceiptObject = [IO.File]::ReadAllText($aiReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $script:aiSanitizedObject = [IO.File]::ReadAllText($aiSanitizedPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    $aiWriteFixture = {
        Write-Utf8Json $aiFixtureManifestPath $aiManifestObject
        Write-Utf8Json $aiReceiptPath $aiReceiptObject
        # Keep the sanitized sibling bound to the current receipt bytes so a
        # receipt negative is not masked by the sanitized binding check.
        $aiSanitizedObject.rawReceiptSha256 = (Get-Sha256 -Path $aiReceiptPath)
        $aiSanitizedObject.sourceManifest.sha256 = (Get-Sha256 -Path $aiFixtureManifestPath)
        Write-Utf8Json $aiSanitizedPath $aiSanitizedObject
    }
    $aiInvoke = {
        # Re-read the fixture documents before every invocation. A previous
        # negative case mutates the shared PSCustomObject, and re-serialising
        # it can drop sibling blocks such as the pinned broker identity, which
        # would mask the failure this case is meant to prove.
        $script:aiManifestObject = [IO.File]::ReadAllText($aiFixtureManifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $script:aiReceiptObject = [IO.File]::ReadAllText($aiReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $script:aiSanitizedObject = [IO.File]::ReadAllText($aiSanitizedPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity -BrokerPath $aiBrokerPath -AiRootPath $aiStageRoot -AiManifestPath $aiFixtureManifestPath -AiReceiptPath $aiReceiptPath -AiFixtureMode | Out-Null
    }
    & $aiRestoreFixture

    # Partial input combinations are rejected before anything is written.
    $aiPartialCases = @(
        [pscustomobject]@{ Label = 'broker-only'; Broker = $aiBrokerPath; Root = ''; Manifest = ''; Receipt = '' },
        [pscustomobject]@{ Label = 'no-broker'; Broker = ''; Root = $aiStageRoot; Manifest = $aiFixtureManifestPath; Receipt = $aiReceiptPath },
        [pscustomobject]@{ Label = 'manifest-only'; Broker = ''; Root = ''; Manifest = $aiFixtureManifestPath; Receipt = '' },
        [pscustomobject]@{ Label = 'receipt-only'; Broker = ''; Root = ''; Manifest = ''; Receipt = $aiReceiptPath },
        [pscustomobject]@{ Label = 'no-receipt'; Broker = $aiBrokerPath; Root = $aiStageRoot; Manifest = $aiFixtureManifestPath; Receipt = '' },
        [pscustomobject]@{ Label = 'no-manifest'; Broker = $aiBrokerPath; Root = $aiStageRoot; Manifest = ''; Receipt = $aiReceiptPath }
    )
    foreach ($case in $aiPartialCases) {
        Get-AiRejection -Label $case.Label -Pattern 'all-or-none' -Action {
            Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $aiRejectionOutput -BrokerPath $case.Broker -AiRootPath $case.Root -AiManifestPath $case.Manifest -AiReceiptPath $case.Receipt -AiFixtureMode | Out-Null
        }
    }
    if (Test-Path -LiteralPath $aiRejectionOutput) { throw 'A partial local AI input combination created the output directory.' }

    # -AiFixtureMode is confined to a disposable test-results fixture manifest.
    # Point it at a copy outside that boundary so the path rule is what fails.
    $aiOutOfBoundaryManifest = Join-Path $testRoot 'ai-manifest-outside-fixture.json'
    Copy-Item -LiteralPath $aiFixtureManifestPath -Destination $aiOutOfBoundaryManifest -Force
    Get-AiRejection -Label 'fixture-boundary' -Pattern 'fixture mode is restricted' -Action {
        Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity -BrokerPath $aiBrokerPath -AiRootPath $aiStageRoot -AiManifestPath $aiOutOfBoundaryManifest -AiReceiptPath $aiReceiptPath -AiFixtureMode | Out-Null
    }

    # A receipt that is not the manifest-declared staged receipt is rejected.
    $aiForeignReceipt = Join-Path $testRoot 'foreign-receipt.json'
    Copy-Item -LiteralPath $aiReceiptPath -Destination $aiForeignReceipt -Force
    Get-AiRejection -Label 'foreign-receipt' -Pattern 'receipt file declared by the pinned manifest' -Action {
        Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity -BrokerPath $aiBrokerPath -AiRootPath $aiStageRoot -AiManifestPath $aiFixtureManifestPath -AiReceiptPath $aiForeignReceipt -AiFixtureMode | Out-Null
    }
    Get-AiRejection -Label 'missing-receipt' -Pattern 'Path does not exist|Expected a file|Cannot find' -Action {
        Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity -BrokerPath $aiBrokerPath -AiRootPath $aiStageRoot -AiManifestPath $aiFixtureManifestPath -AiReceiptPath (Join-Path $aiStageRoot 'no-such-receipt.json') -AiFixtureMode | Out-Null
    }

    # Manifest identity, status, and digest binding.
    $aiManifestObject.model.revision = ('0' * 40)
    & $aiWriteFixture
    Get-AiRejection -Label 'manifest-model-revision' -Pattern 'model revision is not the pinned pairing' -Action $aiInvoke
    & $aiRestoreFixture
    $aiManifestObject.status = 'staged-something-else'
    & $aiWriteFixture
    Get-AiRejection -Label 'manifest-status' -Pattern 'status is not the reviewed staging input status' -Action $aiInvoke
    & $aiRestoreFixture
    $aiManifestObject.model.weight.sha256 = ('a' * 64)
    $aiManifestObject.model.weight.lfsSha256 = ('a' * 64)
    & $aiWriteFixture
    Get-AiRejection -Label 'manifest-model-digest' -Pattern 'model weight does not match the pinned manifest' -Action $aiInvoke
    & $aiRestoreFixture
    $aiManifestObject.runtime.release = 'b99999'
    & $aiWriteFixture
    Get-AiRejection -Label 'manifest-runtime-release' -Pattern 'runtime release is not the pinned pairing' -Action $aiInvoke
    & $aiRestoreFixture
    $aiManifestObject.platform.cpuOnly = $false
    & $aiWriteFixture
    Get-AiRejection -Label 'manifest-cpu-only-flag' -Pattern 'Windows x64 CPU-only' -Action $aiInvoke
    & $aiRestoreFixture
    $aiManifestObject.runtime.archive.entryPolicy.allowedExactEntries = @('ggml.dll', 'llama-server-impl.dll')
    & $aiWriteFixture
    Get-AiRejection -Label 'manifest-missing-server-entry' -Pattern 'closure must contain llama-server\.exe|required local AI runtime closure entry is not in the allowlist' -Action $aiInvoke
    & $aiRestoreFixture
    $aiManifestObject.runtime.archive.entryPolicy.entryNamesSha256 = ('b' * 64)
    & $aiWriteFixture
    Get-AiRejection -Label 'manifest-closure-digest' -Pattern 'closure name digest does not match' -Action $aiInvoke
    & $aiRestoreFixture
    $aiManifestObject.staging.noticeFile = 'C:/absolute/THIRD-PARTY-NOTICES.txt'
    & $aiWriteFixture
    Get-AiRejection -Label 'manifest-absolute-path' -Pattern 'must be a relative path, not an absolute path' -Action $aiInvoke
    & $aiRestoreFixture
    $aiManifestObject.staging.licenseDirectory = '../licenses'
    & $aiWriteFixture
    Get-AiRejection -Label 'manifest-traversal' -Pattern 'path traversal or an empty segment' -Action $aiInvoke
    & $aiRestoreFixture

    # Receipt status, digest, and network binding.
    $aiReceiptObject.status = 'staged-unverified'
    & $aiWriteFixture
    Get-AiRejection -Label 'receipt-status' -Pattern 'receipt status is not the reviewed staged-verified status' -Action $aiInvoke
    & $aiRestoreFixture
    $aiReceiptObject.networkUsed = $true
    & $aiWriteFixture
    Get-AiRejection -Label 'receipt-network-used' -Pattern 'does not record networkUsed=false' -Action $aiInvoke
    & $aiRestoreFixture
    $aiReceiptObject.manifest.sha256 = ('c' * 64)
    & $aiWriteFixture
    Get-AiRejection -Label 'manifest-hash-mismatch' -Pattern 'does not name the pinned AI manifest digest' -Action $aiInvoke
    & $aiRestoreFixture
    $aiReceiptObject.runtime.entries[0].sha256 = ('d' * 64)
    & $aiWriteFixture
    Get-AiRejection -Label 'receipt-runtime-entry-digest' -Pattern 'records the wrong digest for a staged runtime entry' -Action $aiInvoke
    & $aiRestoreFixture
    $aiReceiptObject.notice.sha256 = ('e' * 64)
    & $aiWriteFixture
    Get-AiRejection -Label 'receipt-notice-digest' -Pattern 'receipt notice digest does not match' -Action $aiInvoke
    & $aiRestoreFixture
    $aiReceiptObject.model.license = 'MIT'
    & $aiWriteFixture
    Get-AiRejection -Label 'receipt-model-license' -Pattern 'receipt model license does not match' -Action $aiInvoke
    & $aiRestoreFixture

    # The broker ships as part of the reviewed AI bundle, so an unpinned or
    # altered broker must be refused rather than merely recorded.
    $aiBrokerOriginal = Save-FileBytes $aiBrokerPath
    try {
        $aiBrokerBytes = [byte[]]::new($aiBrokerOriginal.Length + 1)
        [Array]::Copy($aiBrokerOriginal, $aiBrokerBytes, $aiBrokerOriginal.Length)
        [IO.File]::WriteAllBytes($aiBrokerPath, $aiBrokerBytes)
        Get-AiRejection -Label 'broker-pinned-size' -Pattern 'broker size does not match the pinned manifest' -Action $aiInvoke
    }
    finally { [IO.File]::WriteAllBytes($aiBrokerPath, $aiBrokerOriginal) }
    $aiBrokerFlip = [byte[]]$aiBrokerOriginal.Clone()
    $aiBrokerFlip[64] = [byte]($aiBrokerFlip[64] -bxor 0xFF)
    [IO.File]::WriteAllBytes($aiBrokerPath, $aiBrokerFlip)
    Get-AiRejection -Label 'broker-pinned-digest' -Pattern 'broker SHA-256 does not match the pinned manifest' -Action $aiInvoke
    [IO.File]::WriteAllBytes($aiBrokerPath, $aiBrokerOriginal)

    # Staged payload mutation.
    [IO.File]::AppendAllText((Join-Path $aiStageRoot ('model/' + $aiModelFixtureName)), 'tamper')
    Get-AiRejection -Label 'model-mutation' -Pattern 'model weight does not match the pinned manifest' -Action $aiInvoke
    & $aiRestoreFixture
    [IO.File]::AppendAllText((Join-Path $aiStageRoot ('runtime/' + $aiServerEntry)), 'tamper')
    Get-AiRejection -Label 'runtime-mutation' -Pattern 'records the wrong size for a staged runtime entry' -Action $aiInvoke
    & $aiRestoreFixture
    [IO.File]::AppendAllText((Join-Path $aiStageRoot 'licenses\llama.cpp-MIT.txt'), 'tamper')
    Get-AiRejection -Label 'license-mutation' -Pattern 'runtime license does not match the pinned manifest identity' -Action $aiInvoke
    & $aiRestoreFixture
    [IO.File]::AppendAllText((Join-Path $aiStageRoot 'THIRD-PARTY-NOTICES.txt'), 'tamper')
    Get-AiRejection -Label 'notice-mutation' -Pattern 'third-party notice does not match the pinned manifest identity' -Action $aiInvoke
    & $aiRestoreFixture
    Copy-Item -LiteralPath (Join-Path $bazelRoot 'mozc_broker.exe') -Destination $aiBrokerPath -Force
    Get-AiRejection -Label 'broker-is-mozc-broker' -Pattern "byte-for-byte copy of the Mozc payload 'mozc_broker\.exe'" -Action $aiInvoke
    & $aiRestoreFixture
    Write-SyntheticPe -Path $aiBrokerPath -Machine 0x014c -Type 'Exe' -Exports @('KanaiBrokerEntry')
    Get-AiRejection -Label 'broker-x86' -Pattern 'PE architecture mismatch' -Action $aiInvoke
    & $aiRestoreFixture
    [IO.File]::WriteAllBytes($aiBrokerPath, (New-Object byte[] 64))
    Get-AiRejection -Label 'broker-mutation' -Pattern 'Truncated PE DOS header|Invalid PE DOS magic' -Action $aiInvoke
    & $aiRestoreFixture
    $aiBrokerRenamed = Join-Path $aiBrokerDirectory 'kanai-broker-x64.exe'
    Copy-Item -LiteralPath $aiBrokerPath -Destination $aiBrokerRenamed -Force
    Get-AiRejection -Label 'broker-wrong-name' -Pattern 'broker must be named kanai-broker\.exe' -Action {
        Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity -BrokerPath $aiBrokerRenamed -AiRootPath $aiStageRoot -AiManifestPath $aiFixtureManifestPath -AiReceiptPath $aiReceiptPath -AiFixtureMode | Out-Null
    }
    Remove-Item -LiteralPath $aiBrokerRenamed -Force

    # Staged tree membership: missing, unknown, and extra entries.
    $aiServerStaged = Join-Path $aiStageRoot ('runtime/' + $aiServerEntry)
    $aiServerStagedBytes = Save-FileBytes $aiServerStaged
    Remove-Item -LiteralPath $aiServerStaged -Force
    Get-AiRejection -Label 'missing-llama-server' -Pattern 'Staged local AI file is missing: runtime/llama-server\.exe' -Action $aiInvoke
    [IO.File]::WriteAllBytes($aiServerStaged, $aiServerStagedBytes)
    $aiExtraEntry = Join-Path $aiStageRoot 'unexpected-extra.txt'
    [IO.File]::WriteAllText($aiExtraEntry, 'unmanaged staged entry')
    Get-AiRejection -Label 'unknown-staged-entry' -Pattern 'Unknown staged local AI entry: unexpected-extra\.txt' -Action $aiInvoke
    Remove-Item -LiteralPath $aiExtraEntry -Force
    $aiExtraRuntimeEntry = Join-Path $aiStageRoot 'runtime\extra-closure.dll'
    Copy-Item -LiteralPath $aiGgmlPePath -Destination $aiExtraRuntimeEntry
    Get-AiRejection -Label 'unknown-staged-closure-entry' -Pattern 'Unknown staged local AI entry: runtime/extra-closure\.dll' -Action $aiInvoke
    Remove-Item -LiteralPath $aiExtraRuntimeEntry -Force
    $aiExtraDirectory = Join-Path $aiStageRoot 'unexpected-directory'
    New-Item -ItemType Directory -Path $aiExtraDirectory | Out-Null
    Get-AiRejection -Label 'unknown-staged-directory' -Pattern 'Unknown staged local AI directory: unexpected-directory' -Action $aiInvoke
    Remove-Item -LiteralPath $aiExtraDirectory -Force

    # The sanitized package manifest must not claim to be free of absolute paths.
    $aiSanitizedObject.containsAbsolutePaths = $true
    Write-Utf8Json $aiSanitizedPath $aiSanitizedObject
    Get-AiRejection -Label 'sanitized-absolute-path-claim' -Pattern 'does not declare containsAbsolutePaths=false' -Action $aiInvoke
    & $aiRestoreFixture
    $aiSanitizedObject.rawReceiptSha256 = ('f' * 64)
    Write-Utf8Json $aiSanitizedPath $aiSanitizedObject
    Get-AiRejection -Label 'sanitized-receipt-binding' -Pattern 'does not bind the staged receipt bytes' -Action $aiInvoke
    & $aiRestoreFixture
    $aiSanitizedObject.sourceManifest.sha256 = ('1' * 64)
    Write-Utf8Json $aiSanitizedPath $aiSanitizedObject
    Get-AiRejection -Label 'sanitized-manifest-binding' -Pattern 'does not bind the pinned manifest bytes' -Action $aiInvoke
    & $aiRestoreFixture

    # A reparse point anywhere in the staged tree is refused.  Junction creation
    # is capability-dependent, so this negative is reported rather than faked.
    $aiReparseStatus = 'not-supported-on-this-host'
    try {
        New-Item -ItemType Junction -Path $aiJunction -Target (Join-Path $aiStageRoot 'licenses') -ErrorAction Stop | Out-Null
        $aiJunctionMessage = Get-FailureMessage $aiInvoke
        if ($aiJunctionMessage -notmatch 'Reparse point|reparse') { throw "A reparse point in the staged local AI tree was not rejected: $aiJunctionMessage" }
        $aiReparseStatus = 'rejected'
    }
    catch {
        if ($_.Exception.Message -notmatch 'not recognized|cannot create|not supported|access is denied|Reparse point|reparse') { throw }
        $aiReparseStatus = 'not-supported-on-this-host'
    }
    finally { Remove-TestJunction $aiJunction }
    & $aiRestoreFixture

    # The restored fixture must still validate, so every negative above really
    # restored the staged bytes.
    $aiRevalidated = Invoke-BuildValidation -RuntimePath $runtime -HelperPath $helper -ManifestPath $manifestPath -OutputPath $output -SkipSourceIdentity -BrokerPath $aiBrokerPath -AiRootPath $aiStageRoot -AiManifestPath $aiFixtureManifestPath -AiReceiptPath $aiReceiptPath -AiFixtureMode
    if ($aiRevalidated.LocalAiIncluded -ne $true -or $aiRevalidated.AiPayloadCount -ne $aiExpectedPayload.Count) {
        throw 'The synthetic local AI fixture did not return to a valid state after the negative cases.'
    }
    $aiRejections['revalidated-after-negatives'] = $true
    if (Test-Path -LiteralPath (Join-Path $output 'KanaAI-0.1.0-x64.msi')) { throw 'A local AI negative case generated an MSI.' }
    if (Test-Path -LiteralPath (Join-Path $output 'KanaAI-0.1.0-Setup.exe')) { throw 'A local AI negative case generated Setup.exe.' }
    if (@(Get-ChildItem -LiteralPath $output -Force -File).Count -ne 0) { throw 'A local AI negative case published files into the output directory.' }

    if ($RunFullBuild) {
        $wixPath = Join-Path $repository '.local\wix\wix.exe'
        if (-not (Test-Path -LiteralPath $wixPath -PathType Leaf)) { $fullBuildStatus = 'not-run (WiX 5.0.2 executable is unavailable)' }
        else { $fullBuildStatus = 'requested (not run by this ticket)' }
    }

    [pscustomobject]@{
        Status = 'PASS'
        OfflineStage = 'PASS (synthetic local artifacts)'
        RuntimeFiles = 12
        StagedPatchCount = @($manifest.sourceIdentity.patches).Count
        SourceCommit = $validated.SourceCommit
        MozcCommit = $validated.MozcCommit
        HostOverlayFingerprint = $validated.HostOverlayFingerprint
        RuntimeManifestSha256 = $manifestHash
        ValidateOnly = $true
        BadMagicRejected = $true
        TruncatedHeadersRejected = $true
        WrongMachineRejected = $true
        OptionalMagicRejected = $true
        DllExeMismatchRejected = $true
        MissingExportRejected = $true
        PayloadMutationRejected = $true
        HelperMutationRejected = $true
        SourceMutationRejected = $true
        PatchMutationRejected = $true
        OverlayMutationRejected = $true
        ManifestSelfHashRejected = $true
        ReparseRoot = $reparseStatus
        SourceDirty = $sourceDirty
        CleanGuardRejected = $cleanGuardRejected
        AiLessLocalAiIncluded = [bool]$validated.LocalAiIncluded
        AiLessPayloadFileCount = [int]$validated.AiPayloadCount
        AiModeValidated = [bool]$aiPayloadVerified
        AiModelFixtureBytes = $aiModelFixtureBytes
        AiRuntimeClosureEntries = $aiClosureNames.Count
        AiPayloadFileCount = [int]$aiRevalidated.AiPayloadCount
        AiPayloadRelativePaths = @($aiRevalidated.AiPayloadRelativePaths)
        AiBrokerName = [string]$aiRevalidated.AiBrokerName
        AiBrokerSha256 = [string]$aiRevalidated.AiBrokerSha256
        AiManifestSha256 = [string]$aiRevalidated.AiManifestSha256
        AiReceiptSha256 = [string]$aiRevalidated.AiReceiptSha256
        AiPackageManifestSha256 = [string]$aiRevalidated.AiPackageManifestSha256
        AiOperationVerified = [bool]$aiRevalidated.AiOperationVerified
        AiStartupTested = [bool]$aiRevalidated.AiStartupTested
        AiNegativeCases = $aiRejections.Keys.Count
        AiNegativeCaseNames = @($aiRejections.Keys)
        AiReparse = $aiReparseStatus
        AiMsiOrSetupGenerated = $false
        AiRealWeightOrRuntimeUsed = $false
        FullBuild = $fullBuildStatus
    }
}
finally {
    # Restore shared tracked files even if an assertion aborts.  This test
    # never uses git checkout/reset/clean/stash and preserves pre-existing
    # uncommitted bytes.
    if ($null -ne $sourceBytes -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { Restore-FileBytes $sourcePath $sourceBytes }
    if ($null -ne $patchBytes -and (Test-Path -LiteralPath $patchPath -PathType Leaf)) { Restore-FileBytes $patchPath $patchBytes }
    if ($null -ne $overlayBytes -and (Test-Path -LiteralPath $overlayPath -PathType Leaf)) { Restore-FileBytes $overlayPath $overlayBytes }
    Remove-TestJunction $junctionPath
    Remove-TestJunction $aiJunction
    foreach ($managed in @($aiFixtureRoot, $aiStageRoot, $testRoot)) {
        if ([string]::IsNullOrWhiteSpace([string]$managed)) { continue }
        $resolvedManaged = [IO.Path]::GetFullPath($managed)
        if ($resolvedManaged.StartsWith($localRoot, [StringComparison]::OrdinalIgnoreCase) -and
            ((Split-Path -Leaf $resolvedManaged) -like 'installer-build-*' -or (Split-Path -Leaf $resolvedManaged) -like 'airuntime-staging-*')) {
            # -Confirm:$false keeps the sweep non-interactive; a leftover link
            # would otherwise raise a confirmation prompt and hang the run.
            Remove-Item -LiteralPath $resolvedManaged -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}
