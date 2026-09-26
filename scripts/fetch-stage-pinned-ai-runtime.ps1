# Validate and stage the pinned local AI runtime.
#
# The default mode is an offline validation/plan operation.  This file does
# not implement network access.  A future fetch implementation must preserve
# the same digest and path checks and must be introduced explicitly.
[CmdletBinding()]
param(
    [Alias('Manifest')][string]$ManifestPath = '',
    [Alias('ModelFile', 'Model')][string]$ModelPath = '',
    [Alias('RuntimeArchive', 'RuntimeZip')][string]$RuntimeArchivePath = '',
    [Alias('StagingDirectory')][string]$OutputDirectory = '',
    [switch]$Stage,
    [Alias('ValidateOnly')][switch]$PlanOnly,
    [switch]$Fetch,
    [switch]$FixtureMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Fetch) {
    throw 'Network fetch is intentionally not implemented in this checkout. The default plan path is offline; a later explicit fetch implementation is required.'
}
if ($PlanOnly -and $Stage) {
    throw 'Choose either -PlanOnly or -Stage, not both.'
}

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$defaultManifest = Join-Path $repository 'platform\windows-tsf\ai-runtime\manifest-v1.json'
if (-not $ManifestPath) { $ManifestPath = $defaultManifest }

function Get-RequiredProperty {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Context
    )
    if ($null -eq $Object) { throw "Missing object while reading $Context." }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "Manifest field is required: $Context.$Name"
    }
    return $property.Value
}

function Get-FullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty filesystem path is not allowed.' }
    try { return [IO.Path]::GetFullPath($Path) } catch { throw "Invalid filesystem path: $Path`n$($_.Exception.Message)" }
}

function Get-PathKey {
    param([string]$Path)
    $full = Get-FullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        return $full.TrimEnd([char[]]@('\', '/'))
    }
    return $full
}

function Test-PathWithin {
    param(
        [string]$Path,
        [string]$Boundary
    )
    $full = Get-PathKey $Path
    $root = Get-PathKey $Boundary
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    return $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

# Produce a portable, relative identity for a staged artifact. Absolute
# developer paths and PowerShell object graphs (FileInfo/DirectoryInfo) must
# never reach a receipt that may be packaged, compared, or re-parsed on another
# machine. Paths inside the repository keep their repository-relative form;
# anything else degrades to the leaf name so no host path can leak.
function Get-PortableRelativePath {
    param(
        [string]$Path,
        [string]$RepositoryRoot
    )
    $full = Get-FullPath $Path
    $root = Get-PathKey $RepositoryRoot
    $key = Get-PathKey $full
    if ($key.Length -gt $root.Length -and
        $key.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $full.Substring($root.Length).TrimStart([char[]]@('\', '/'))
        $relative = $relative.Replace('\', '/')
        return (Assert-SafeRelativePath $relative).Relative
    }
    $leaf = Split-Path -Leaf $full
    if ([string]::IsNullOrWhiteSpace($leaf)) { throw 'Cannot derive a portable relative identity.' }
    return (Assert-SafeRelativePath $leaf).Relative
}

# Canonical portable spelling for an identity that leaves this machine. The
# managed on-disk paths stay Windows-native, but anything recorded in a receipt
# uses forward slashes so the Rust launch-plan seam and other platforms compare
# byte-for-byte.
function ConvertTo-PortableRelativeString {
    param([string]$Relative)
    return (Assert-SafeRelativePath $Relative).Relative.Replace('\', '/')
}

function Assert-NoReparseChain {
    param(
        [string]$Path,
        [switch]$AllowMissingLeaf
    )
    $full = Get-FullPath $Path
    $current = $full
    $missingLeaf = $false
    while ($true) {
        $item = $null
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        } catch {
            if ($AllowMissingLeaf -and -not $missingLeaf -and $current.Equals($full, [StringComparison]::OrdinalIgnoreCase)) {
                $missingLeaf = $true
            } else {
                throw "Path is missing or inaccessible: $full"
            }
        }
        if ($null -ne $item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Reparse points are not allowed in managed paths: $current"
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrEmpty($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $parent
    }
}

function Assert-ExistingFile {
    param(
        [string]$Path,
        [string]$Description
    )
    Assert-NoReparseChain $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing $Description`: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) { throw "Expected a file for $Description`: $Path" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point is not allowed for $Description`: $Path" }
    return $item
}

function Assert-ExistingDirectory {
    param(
        [string]$Path,
        [string]$Description
    )
    Assert-NoReparseChain $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Missing $Description`: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { throw "Expected a directory for $Description`: $Path" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point is not allowed for $Description`: $Path" }
    return $item
}

function Assert-SafeRelativePath {
    param(
        [string]$Relative,
        [switch]$AllowDirectory
    )
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw 'An empty relative path is not allowed.' }
    if ($Relative -match '[\x00-\x1f\x7f-\x9f]') { throw 'Control characters are not allowed in managed relative paths.' }
    $normalized = $Relative.Replace('/', '\')
    $isDirectory = $normalized.EndsWith('\')
    if ([IO.Path]::IsPathRooted($normalized) -or $normalized.StartsWith('\') -or $normalized -match '^[A-Za-z]:') {
        throw "Absolute paths are not allowed in manifest/archive paths: $Relative"
    }
    $body = $normalized.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($body)) { throw 'An empty relative path is not allowed.' }
    $segments = @($body -split '\\')
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Path traversal or empty path segment is not allowed: $Relative"
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment.Contains('*') -or $segment.Contains('?')) {
            throw "Windows-ambiguous path segment is not allowed: $Relative"
        }
        $deviceName = ($segment -split '\.')[0]
        if ($deviceName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw "Windows device path segments are not allowed: $Relative"
        }
        if ($segment.Contains(':')) { throw "Alternate data streams are not allowed: $Relative" }
    }
    if ($isDirectory -and -not $AllowDirectory) { throw "Directory paths are not allowed here: $Relative" }
    if ($body.Length -gt 240) { throw "Managed relative path is too long: $Relative" }
    return [pscustomobject]@{ Relative = $body; IsDirectory = $isDirectory }
}

function Assert-NoDotDotPathToken {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $normalized = $Path.Replace('/', '\')
    foreach ($segment in @($normalized -split '\\')) {
        if ($segment -eq '..') { throw "Path traversal is not allowed in a caller path: $Path" }
    }
}

function Get-Sha256 {
    param([string]$Path)
    $stream = $null
    $sha = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sha = [Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-TextSha256 {
    param([string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Assert-FileDigest {
    param(
        [string]$Path,
        [int64]$ExpectedBytes,
        [string]$ExpectedSha256,
        [string]$Description
    )
    $item = Assert-ExistingFile $Path $Description
    if ($item.Length -ne $ExpectedBytes) {
        throw "Wrong size for $Description`: expected $ExpectedBytes bytes, found $($item.Length)."
    }
    $actual = Get-Sha256 $Path
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "Wrong SHA-256 for $Description`: expected $ExpectedSha256, found $actual."
    }
    $after = Get-Item -LiteralPath $Path -Force
    if ($after.Length -ne $ExpectedBytes) { throw "Input changed while hashing: $Path" }
    return $actual
}

function Assert-HttpsUrl {
    param(
        [string]$Value,
        [string]$Description
    )
    if ($Value -notmatch '^https://') { throw "$Description must use HTTPS: $Value" }
    try { $uri = [Uri]$Value } catch { throw "$Description is not a valid URL: $Value" }
    if ($uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "$Description must be an HTTPS URL without embedded credentials: $Value"
    }
}

function Assert-StringArray {
    param(
        [object]$Value,
        [string]$Description,
        [switch]$AllowEmpty
    )
    if ($null -eq $Value) { throw "$Description must be an array." }
    if ($Value -is [string]) { return @($Value) }
    $items = @($Value)
    if (-not $AllowEmpty -and $items.Count -eq 0) { throw "$Description must not be empty." }
    foreach ($item in $items) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) { throw "$Description contains an invalid item." }
    }
    return $items
}

function Assert-NoSecretProperties {
    param(
        [object]$Value,
        [string]$Path
    )
    if ($null -eq $Value) { return }
    if ($Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            if ($name -notmatch '^noSecrets$' -and $name -match '(?i)(api.?key|password|passwd|secret|token|credential|authorization|private.?key)') {
                throw "Secret-like manifest field is forbidden: $Path.$name"
            }
            Assert-NoSecretProperties $Value[$key] "$Path.$name"
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $index = 0
        foreach ($item in $Value) {
            Assert-NoSecretProperties $item "$Path[$index]"
            $index++
        }
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        $name = [string]$property.Name
        if ($name -notmatch '^noSecrets$' -and $name -match '(?i)(api.?key|password|passwd|secret|token|credential|authorization|private.?key)') {
            throw "Secret-like manifest field is forbidden: $Path.$name"
        }
        Assert-NoSecretProperties $property.Value "$Path.$name"
    }
}

function Assert-ManifestRelativeFile {
    param(
        [object]$ManifestRoot,
        [string]$Relative,
        [string]$Description,
        [int64]$ExpectedBytes = 0,
        [string]$ExpectedSha256 = ''
    )
    $safe = Assert-SafeRelativePath $Relative
    $root = Get-PathKey $ManifestRoot
    $full = Get-FullPath (Join-Path $root $safe.Relative)
    if (-not (Test-PathWithin $full $root)) { throw "$Description escapes the manifest directory: $Relative" }
    $item = Assert-ExistingFile $full $Description
    if ($ExpectedBytes -gt 0 -and $item.Length -ne $ExpectedBytes) {
        throw "Wrong size for $Description`: expected $ExpectedBytes bytes, found $($item.Length)."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $actual = Get-Sha256 $full
        if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw "Wrong SHA-256 for $Description`: $full" }
    }
    return $full
}

function Assert-ArchiveEntryAllowed {
    param(
        [string]$Relative,
        [object]$Policy
    )
    $exact = Assert-StringArray (Get-RequiredProperty $Policy 'allowedExactEntries' 'runtime.archive.entryPolicy') 'runtime.archive.entryPolicy.allowedExactEntries'
    $patterns = Assert-StringArray (Get-RequiredProperty $Policy 'allowedEntryPatterns' 'runtime.archive.entryPolicy') 'runtime.archive.entryPolicy.allowedEntryPatterns' -AllowEmpty
    foreach ($candidate in $exact) {
        $safe = Assert-SafeRelativePath $candidate
        if ($safe.Relative.Equals($Relative, [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    foreach ($pattern in $patterns) {
        if ($pattern -notmatch '^\^' -or $pattern -notmatch '\$$') { throw "Archive entry patterns must be anchored: $pattern" }
        if ([regex]::IsMatch($Relative, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            return
        }
    }
    throw "Unexpected runtime archive entry: $Relative"
}

function Assert-Manifest {
    param(
        [object]$Manifest,
        [string]$ManifestRoot,
        [switch]$Fixture
    )
    if ((Get-RequiredProperty $Manifest 'schema' 'manifest') -ne 'kanai.ai.runtime.manifest/v1') { throw 'Unsupported AI runtime manifest schema.' }
    if ([int](Get-RequiredProperty $Manifest 'schemaVersion' 'manifest') -ne 1) { throw 'Unsupported AI runtime manifest schemaVersion.' }
    if ([int](Get-RequiredProperty $Manifest 'manifestVersion' 'manifest') -ne 1) { throw 'Unsupported AI runtime manifest manifestVersion.' }
    if ((Get-RequiredProperty $Manifest 'noSecrets' 'manifest') -ne $true) { throw 'Manifest must explicitly declare noSecrets=true.' }
    Assert-NoSecretProperties $Manifest 'manifest'

    $product = Get-RequiredProperty $Manifest 'product' 'manifest'
    if ((Get-RequiredProperty $product 'offlineOnly' 'product') -ne $true -or
        (Get-RequiredProperty $product 'networkAtRuntime' 'product') -ne $false) {
        throw 'The local AI runtime must be marked offline-only.'
    }
    $platform = Get-RequiredProperty $Manifest 'platform' 'manifest'
    if ((Get-RequiredProperty $platform 'os' 'platform') -ne 'windows' -or
        (Get-RequiredProperty $platform 'architecture' 'platform') -ne 'x64' -or
        (Get-RequiredProperty $platform 'cpuOnly' 'platform') -ne $true -or
        (Get-RequiredProperty $platform 'gpuRequired' 'platform') -ne $false) {
        throw 'The pinned runtime platform must be Windows x64 CPU-only.'
    }

    $model = Get-RequiredProperty $Manifest 'model' 'manifest'
    if ((Get-RequiredProperty $model 'repository' 'model') -ne 'Qwen/Qwen2.5-1.5B-Instruct-GGUF' -or
        (Get-RequiredProperty $model 'revision' 'model') -ne '91cad51170dc346986eccefdc2dd33a9da36ead9' -or
        (Get-RequiredProperty $model 'license' 'model') -ne 'Apache-2.0') {
        throw 'The model identity or license is not the coordinator-approved pairing.'
    }
    if ((Get-RequiredProperty $model 'expectedRole' 'model') -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string](Get-RequiredProperty $model 'expectedRole' 'model')) -or
        (Get-RequiredProperty $model 'cpuOnly' 'model') -ne $true -or
        (Get-RequiredProperty $model 'offlineOnly' 'model') -ne $true) {
        throw 'Model role and offline CPU flags are missing or invalid.'
    }
    $modelSource = [string](Get-RequiredProperty $model 'sourceUrl' 'model')
    $modelMetadata = [string](Get-RequiredProperty $model 'metadataUrl' 'model')
    $modelLicenseUrl = [string](Get-RequiredProperty $model 'licenseUrl' 'model')
    Assert-HttpsUrl $modelSource 'model.sourceUrl'
    Assert-HttpsUrl $modelMetadata 'model.metadataUrl'
    Assert-HttpsUrl $modelLicenseUrl 'model.licenseUrl'
    if ($modelSource -ne 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true' -or
        $modelMetadata -ne 'https://huggingface.co/api/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/revision/91cad51170dc346986eccefdc2dd33a9da36ead9' -or
        $modelLicenseUrl -ne 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/blob/91cad51170dc346986eccefdc2dd33a9da36ead9/LICENSE') {
        throw 'The model URLs are not pinned to the approved revision.'
    }
    $weight = Get-RequiredProperty $model 'weight' 'model'
    $weightName = [string](Get-RequiredProperty $weight 'fileName' 'model.weight')
    $weightBytes = [int64](Get-RequiredProperty $weight 'bytes' 'model.weight')
    $weightSha = [string](Get-RequiredProperty $weight 'sha256' 'model.weight')
    $weightLfsSha = [string](Get-RequiredProperty $weight 'lfsSha256' 'model.weight')
    $weightCommit = [string](Get-RequiredProperty $weight 'fileCommit' 'model.weight')
    $weightUrl = [string](Get-RequiredProperty $weight 'url' 'model.weight')
    Assert-HttpsUrl $weightUrl 'model.weight.url'
    $safeWeightName = Assert-SafeRelativePath $weightName
    if ($safeWeightName.Relative -ne $weightName -or $weightBytes -le 0 -or $weightSha -notmatch '^[0-9a-fA-F]{64}$' -or
        $weightLfsSha -ne $weightSha -or $weightUrl -ne $modelSource -or
        (Get-RequiredProperty $weight 'lfs' 'model.weight') -ne $true -or
        (Get-RequiredProperty $weight 'cpuOnly' 'model.weight') -ne $true -or
        (Get-RequiredProperty $weight 'offlineOnly' 'model.weight') -ne $true -or
        $weightCommit -ne 'dd26da440ef0330c47919d1ecae0966d24022222') {
        throw 'The model weight record is malformed.'
    }
    if (-not $Fixture -and ($weightName -ne 'qwen2.5-1.5b-instruct-q4_k_m.gguf' -or $weightBytes -ne 1117320736 -or
        $weightSha -ne '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e')) {
        throw 'The model weight does not match the coordinator-approved digest.'
    }

    $runtime = Get-RequiredProperty $Manifest 'runtime' 'manifest'
    if ((Get-RequiredProperty $runtime 'repository' 'runtime') -ne 'ggml-org/llama.cpp' -or
        (Get-RequiredProperty $runtime 'release' 'runtime') -ne 'b11146' -or
        (Get-RequiredProperty $runtime 'revision' 'runtime') -ne '7fe450e19305b828c199d602c23a8337aaa1f03b' -or
        (Get-RequiredProperty $runtime 'license' 'runtime') -ne 'MIT') {
        throw 'The runtime identity or license is not the coordinator-approved pairing.'
    }
    $runtimeSource = [string](Get-RequiredProperty $runtime 'sourceUrl' 'runtime')
    $runtimeMetadata = [string](Get-RequiredProperty $runtime 'metadataUrl' 'runtime')
    $runtimeLicenseUrl = [string](Get-RequiredProperty $runtime 'licenseUrl' 'runtime')
    Assert-HttpsUrl $runtimeSource 'runtime.sourceUrl'
    Assert-HttpsUrl $runtimeMetadata 'runtime.metadataUrl'
    Assert-HttpsUrl $runtimeLicenseUrl 'runtime.licenseUrl'
    if ($runtimeSource -ne 'https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-bin-win-cpu-x64.zip' -or
        $runtimeMetadata -ne 'https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/b11146' -or
        $runtimeLicenseUrl -ne 'https://github.com/ggml-org/llama.cpp/blob/7fe450e19305b828c199d602c23a8337aaa1f03b/LICENSE') {
        throw 'The runtime URLs are not pinned to the approved release.'
    }
    $asset = Get-RequiredProperty $runtime 'asset' 'runtime'
    $assetName = [string](Get-RequiredProperty $asset 'fileName' 'runtime.asset')
    $assetBytes = [int64](Get-RequiredProperty $asset 'bytes' 'runtime.asset')
    $assetSha = [string](Get-RequiredProperty $asset 'sha256' 'runtime.asset')
    $assetUrl = [string](Get-RequiredProperty $asset 'url' 'runtime.asset')
    $safeAssetName = Assert-SafeRelativePath $assetName
    if ((Get-RequiredProperty $runtime 'expectedRole' 'runtime') -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string](Get-RequiredProperty $runtime 'expectedRole' 'runtime')) -or
        (Get-RequiredProperty $runtime 'cpuOnly' 'runtime') -ne $true -or
        (Get-RequiredProperty $runtime 'offlineOnly' 'runtime') -ne $true) {
        throw 'Runtime role and offline CPU flags are missing or invalid.'
    }
    Assert-HttpsUrl $assetUrl 'runtime.asset.url'
    if ($safeAssetName.Relative -ne $assetName -or $assetBytes -le 0 -or $assetSha -notmatch '^[0-9a-fA-F]{64}$' -or
        $assetUrl -ne $runtimeSource -or (Get-RequiredProperty $asset 'cpuOnly' 'runtime.asset') -ne $true -or
        (Get-RequiredProperty $asset 'offlineOnly' 'runtime.asset') -ne $true) { throw 'The runtime asset record is malformed.' }
    if (-not $Fixture -and ($assetName -ne 'llama-b11146-bin-win-cpu-x64.zip' -or $assetBytes -ne 18560055 -or
        $assetSha -ne '14cf1303ca9ac3abd94816850532f9f9a69ac66fbaca3776fc6f9061c2fac1d1')) {
        throw 'The runtime asset does not match the coordinator-approved digest.'
    }

    $archive = Get-RequiredProperty $runtime 'archive' 'runtime'
    if ((Get-RequiredProperty $archive 'format' 'runtime.archive') -ne 'zip') { throw 'The runtime archive must be a ZIP.' }
    $policy = Get-RequiredProperty $archive 'entryPolicy' 'runtime.archive'
    $entryMode = [string](Get-RequiredProperty $policy 'mode' 'runtime.archive.entryPolicy')
    if ($entryMode -notin @('allowlist', 'exact-allowlist')) { throw 'The runtime archive must use an entry allowlist.' }
    $exact = @(Assert-StringArray (Get-RequiredProperty $policy 'allowedExactEntries' 'runtime.archive.entryPolicy') 'runtime.archive.entryPolicy.allowedExactEntries')
    $patterns = @(Assert-StringArray (Get-RequiredProperty $policy 'allowedEntryPatterns' 'runtime.archive.entryPolicy') 'runtime.archive.entryPolicy.allowedEntryPatterns' -AllowEmpty)
    foreach ($entry in $exact) { [void](Assert-SafeRelativePath $entry) }
    foreach ($pattern in $patterns) {
        if ($pattern -notmatch '^\^' -or $pattern -notmatch '\$$') { throw "Archive entry pattern is not anchored: $pattern" }
    }
    $requiredEntries = @(Assert-StringArray (Get-RequiredProperty $policy 'requiredEntries' 'runtime.archive.entryPolicy') 'runtime.archive.entryPolicy.requiredEntries')
    foreach ($entry in $requiredEntries) { [void](Assert-SafeRelativePath $entry) }
    $maxEntries = [int](Get-RequiredProperty $archive 'maxEntries' 'runtime.archive')
    $maxExtracted = [int64](Get-RequiredProperty $archive 'maxExtractedBytes' 'runtime.archive')
    $maxEntry = [int64](Get-RequiredProperty $archive 'maxEntryBytes' 'runtime.archive')
    if ($maxEntries -lt 1 -or $maxExtracted -lt 1 -or $maxEntry -lt 1 -or $maxEntry -gt $maxExtracted) {
        throw 'Runtime archive extraction limits are invalid.'
    }

    $licenseNotice = Get-RequiredProperty $Manifest 'licenseNotice' 'manifest'
    if ((Get-RequiredProperty $licenseNotice 'dependencyNoticeStatus' 'licenseNotice') -ne 'unverified-incomplete' -or
        (Get-RequiredProperty $licenseNotice 'sbomStatus' 'licenseNotice') -ne 'not-generated') {
        throw 'Dependency notice and SBOM status must remain explicitly incomplete.'
    }
    $noticePath = [string](Get-RequiredProperty $licenseNotice 'path' 'licenseNotice')
    [void](Assert-ManifestRelativeFile $ManifestRoot $noticePath 'third-party notice' ([int64](Get-RequiredProperty $licenseNotice 'bytes' 'licenseNotice')) ([string](Get-RequiredProperty $licenseNotice 'sha256' 'licenseNotice')))
    if (-not $Fixture -and ($noticePath -ne 'THIRD-PARTY-NOTICES.txt' -or
        [int64]$licenseNotice.bytes -ne 3613 -or [string]$licenseNotice.sha256 -ne '2fa9a4c66b97ca5ae42de7f9372514d866c3e824f4f27ef08ebd07adf76dbae4')) {
        throw 'The production third-party notice path or digest is not pinned.'
    }
    $modelLicensePath = [string](Get-RequiredProperty $model 'licensePath' 'model')
    $runtimeLicensePath = [string](Get-RequiredProperty $runtime 'licensePath' 'runtime')
    $modelLicenseFull = Assert-ManifestRelativeFile $ManifestRoot $modelLicensePath 'model license' ([int64](Get-RequiredProperty $model 'licenseFileBytes' 'model')) ([string](Get-RequiredProperty $model 'licenseFileSha256' 'model'))
    $runtimeLicenseFull = Assert-ManifestRelativeFile $ManifestRoot $runtimeLicensePath 'runtime license' ([int64](Get-RequiredProperty $runtime 'licenseFileBytes' 'runtime')) ([string](Get-RequiredProperty $runtime 'licenseFileSha256' 'runtime'))
    if (-not $Fixture -and ($modelLicensePath -ne 'licenses/Qwen-Apache-2.0.txt' -or
        [int64]$model.licenseFileBytes -ne 11927 -or [string]$model.licenseFileSha256 -ne '425153e94d7d7ebb80995e7efd8713b7ca2c98d38d3bad54781a9fab848069e8' -or
        $runtimeLicensePath -ne 'licenses/llama.cpp-MIT.txt' -or
        [int64]$runtime.licenseFileBytes -ne 1396 -or [string]$runtime.licenseFileSha256 -ne 'b63f92bb31389f53ce2b005be8f59e59f43b6117c0d41bd94749eb4b5b7518f8')) {
        throw 'The production license paths or digests are not pinned.'
    }
    $modelText = [IO.File]::ReadAllText($modelLicenseFull, [Text.Encoding]::UTF8)
    $runtimeText = [IO.File]::ReadAllText($runtimeLicenseFull, [Text.Encoding]::UTF8)
    if ($modelText.IndexOf('Apache License', [StringComparison]::Ordinal) -lt 0 -or $modelText.IndexOf('Version 2.0', [StringComparison]::Ordinal) -lt 0 -or
        $modelText.IndexOf('TERMS AND CONDITIONS', [StringComparison]::Ordinal) -lt 0) { throw 'The model license is not a complete Apache-2.0 text.' }
    if ($runtimeText.IndexOf('MIT License', [StringComparison]::Ordinal) -lt 0 -or
        $runtimeText.IndexOf('Copyright (c) 2023-2026 The ggml authors', [StringComparison]::Ordinal) -lt 0 -or
        $runtimeText.IndexOf('Permission is hereby granted', [StringComparison]::Ordinal) -lt 0) { throw 'The runtime license is not a complete attributed MIT text.' }

    $staging = Get-RequiredProperty $Manifest 'staging' 'manifest'
    $defaultOutput = [string](Get-RequiredProperty $staging 'defaultOutputDirectory' 'staging')
    [void](Assert-SafeRelativePath $defaultOutput -AllowDirectory)
    foreach ($name in @('modelDirectory', 'runtimeDirectory', 'licenseDirectory', 'noticeFile', 'receiptFile')) {
        [void](Assert-SafeRelativePath ([string](Get-RequiredProperty $staging $name "staging.$name")))
    }
    if ((Get-RequiredProperty $staging 'deletePolicy' 'staging') -ne 'never-delete-caller-paths') {
        throw 'Staging policy must prohibit deletion of caller paths.'
    }
    $fetch = Get-RequiredProperty $Manifest 'fetchPolicy' 'manifest'
    if ((Get-RequiredProperty $fetch 'defaultMode' 'fetchPolicy') -ne 'plan' -or
        (Get-RequiredProperty $fetch 'networkImplemented' 'fetchPolicy') -ne $false -or
        (Get-RequiredProperty $fetch 'explicitFetchSwitch' 'fetchPolicy') -ne '-Fetch') {
        throw 'The manifest must keep fetching disabled by default and unimplemented in this script.'
    }
    $schemes = @(Assert-StringArray (Get-RequiredProperty $fetch 'allowedSchemes' 'fetchPolicy') 'fetchPolicy.allowedSchemes')
    if ($schemes.Count -ne 1 -or $schemes[0] -ne 'https') { throw 'Only HTTPS may appear in the future fetch policy.' }
    $verification = Get-RequiredProperty $Manifest 'verification' 'manifest'
    $artifactDigests = Get-RequiredProperty $verification 'artifactDigests' 'verification'
    $localDownload = Get-RequiredProperty $verification 'localDownload' 'verification'
    if ((Get-RequiredProperty $verification 'upstreamMetadata' 'verification') -ne 'verified-by-coordinator' -or
        (Get-RequiredProperty $artifactDigests 'model' 'verification.artifactDigests') -ne 'local-weight-verified' -or
        (Get-RequiredProperty $artifactDigests 'runtime' 'verification.artifactDigests') -ne 'local-archive-verified' -or
        (Get-RequiredProperty $verification 'conversionReproducibility' 'verification') -ne 'unverified' -or
        (Get-RequiredProperty $localDownload 'model' 'verification.localDownload') -ne 'performed-and-verified' -or
        (Get-RequiredProperty $localDownload 'runtime' 'verification.localDownload') -ne 'performed-and-verified' -or
        (Get-RequiredProperty $verification 'windowsExecution' 'verification') -ne 'not-performed') {
        throw 'The manifest must distinguish verified upstream metadata from unverified local reproduction.'
    }
    return $Manifest
}

function Resolve-OutputDirectory {
    param(
        [string]$Requested,
        [object]$Manifest,
        [string]$RepositoryRoot,
        [string]$LocalRoot
    )
    $staging = Get-RequiredProperty $Manifest 'staging' 'manifest'
    if (-not $Requested) { $Requested = Join-Path $RepositoryRoot ([string](Get-RequiredProperty $staging 'defaultOutputDirectory' 'staging')) }
    Assert-NoDotDotPathToken $Requested
    $full = Get-FullPath $Requested
    if (-not (Test-PathWithin $full $LocalRoot) -or $full.Equals((Get-PathKey $LocalRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Staging output must be a dedicated directory below the repository .local boundary: $full"
    }
    if (-not (Test-PathWithin $full $RepositoryRoot)) { throw "Staging output is outside the repository: $full" }
    return $full
}

function Ensure-DirectoryTreeSafe {
    param(
        [string]$Path,
        [string]$Boundary
    )
    $full = Get-FullPath $Path
    if (-not (Test-PathWithin $full $Boundary)) { throw "Directory escapes its managed boundary: $full" }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    $current = $full
    while (-not (Test-Path -LiteralPath $current)) {
        $missing.Add($current)
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrEmpty($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $parent
    }
    if ($missing.Count -gt 0) {
        Assert-NoReparseChain $current
        for ($i = $missing.Count - 1; $i -ge 0; $i--) {
            $directory = $missing[$i]
            Assert-NoReparseChain $directory -AllowMissingLeaf
            [void][IO.Directory]::CreateDirectory($directory)
            [void](Assert-ExistingDirectory $directory 'managed staging directory')
        }
    } else {
        [void](Assert-ExistingDirectory $full 'managed staging directory')
    }
    [void](Assert-ExistingDirectory $full 'managed staging directory')
}

function Get-SafeChildPath {
    param(
        [string]$Root,
        [string]$Relative
    )
    $safe = Assert-SafeRelativePath $Relative
    $root = Get-PathKey $Root
    $full = Get-FullPath (Join-Path $root $safe.Relative)
    if (-not (Test-PathWithin $full $root)) { throw "Managed child path escapes its root: $Relative" }
    return $full
}

function Get-RelativeWithin {
    param(
        [string]$Root,
        [string]$Path
    )
    $rootKey = (Get-PathKey $Root).TrimEnd('\') + '\'
    $pathKey = Get-PathKey $Path
    if (-not $pathKey.StartsWith($rootKey, [StringComparison]::OrdinalIgnoreCase)) { throw "Path is outside the staging root: $Path" }
    return $pathKey.Substring($rootKey.Length)
}

function Get-SafeTreeEntries {
    param(
        [string]$Root,
        [int]$MaximumEntries = 10000
    )
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    [void](Assert-ExistingDirectory $Root 'staging root')
    $rootKey = Get-PathKey $Root
    $result = New-Object 'System.Collections.Generic.List[object]'
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($rootKey)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        [void](Assert-ExistingDirectory $directory 'staging directory')
        $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
        foreach ($child in $children) {
            if ($result.Count -ge $MaximumEntries) { throw "Staging tree exceeds the bounded entry limit ($MaximumEntries)." }
            $full = Get-FullPath $child.FullName
            if (-not (Test-PathWithin $full $rootKey)) { throw "Staging entry escaped the staging root: $full" }
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point is not allowed in staging: $full" }
            $relative = Get-RelativeWithin $rootKey $full
            $result.Add([pscustomobject]@{
                Relative = $relative
                FullName = $full
                IsDirectory = [bool]$child.PSIsContainer
            })
            if ($child.PSIsContainer) { $queue.Enqueue($full) }
        }
    }
    return @($result.ToArray())
}

function Add-ParentRelativePaths {
    param(
        [object]$Set,
        [string]$Relative
    )
    $parts = @($Relative -split '\\')
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $parent = ($parts[0..($i - 1)] -join '\')
        [void]$Set.Add($parent)
    }
}

function Assert-ManagedStagingTree {
    param(
        [string]$Output,
        [string[]]$ExpectedFiles,
        [string[]]$ExpectedDirectories
    )
    if (-not (Test-Path -LiteralPath $Output)) { return }
    [void](Assert-ExistingDirectory $Output 'staging output')
    $fileSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $ExpectedFiles) { [void]$fileSet.Add($file) }
    $directorySet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($directory in $ExpectedDirectories) { [void]$directorySet.Add($directory) }
    foreach ($entry in @(Get-SafeTreeEntries $Output)) {
        if ($entry.IsDirectory) {
            if (-not $directorySet.Contains($entry.Relative)) { throw "Unmanaged staging directory: $($entry.FullName)" }
        } elseif (-not $fileSet.Contains($entry.Relative)) {
            throw "Unmanaged staging entry: $($entry.FullName)"
        }
    }
}

function Read-ArchivePlan {
    param(
        [string]$Path,
        [object]$Archive
    )
    $policy = Get-RequiredProperty $Archive 'entryPolicy' 'runtime.archive'
    $maxEntries = [int](Get-RequiredProperty $Archive 'maxEntries' 'runtime.archive')
    $maxExtracted = [int64](Get-RequiredProperty $Archive 'maxExtractedBytes' 'runtime.archive')
    $maxEntry = [int64](Get-RequiredProperty $Archive 'maxEntryBytes' 'runtime.archive')
    $directoryAllowed = [bool](Get-RequiredProperty $policy 'directoryEntriesAllowed' 'runtime.archive.entryPolicy')
    $required = @(Assert-StringArray (Get-RequiredProperty $policy 'requiredEntries' 'runtime.archive.entryPolicy') 'runtime.archive.entryPolicy.requiredEntries')
    $expectedEntryCount = [int](Get-RequiredProperty $policy 'entryCount' 'runtime.archive.entryPolicy')
    $expectedEntryNamesSha256 = ([string](Get-RequiredProperty $policy 'entryNamesSha256' 'runtime.archive.entryPolicy')).ToLowerInvariant()
    if ($expectedEntryCount -lt 1 -or $expectedEntryNamesSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Runtime archive entry count/name digest are invalid.'
    }
    foreach ($entry in $required) { [void](Assert-SafeRelativePath $entry) }
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    } catch { throw "ZIP support is unavailable: $($_.Exception.Message)" }
    $archiveHandle = $null
    try {
        $archiveHandle = [IO.Compression.ZipFile]::OpenRead($Path)
        $entries = @($archiveHandle.Entries)
        if ($entries.Count -gt $maxEntries) { throw "Runtime archive has too many entries: $($entries.Count)." }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $plan = New-Object 'System.Collections.Generic.List[object]'
        [int64]$total = 0
        foreach ($entry in $entries) {
            $raw = [string]$entry.FullName
            if ($raw.Length -gt 512) { throw 'Runtime archive entry name exceeds the bounded path limit.' }
            $relativeInfo = Assert-SafeRelativePath $raw
            $relative = $relativeInfo.Relative
            if (-not $seen.Add($relative)) { throw "Duplicate runtime archive entry: $relative" }
            $external = [uint32]([int64]$entry.ExternalAttributes -band 0xffffffffL)
            $unixType = ($external -shr 16) -band 0xF000
            $isDirectory = $raw.EndsWith('/') -or $raw.EndsWith('\') -or (($external -band 0x10) -ne 0)
            if (($external -band 0x400) -ne 0 -or $unixType -eq 0xA000) { throw "Reparse/symlink archive entry is not allowed: $relative" }
            if ($isDirectory) {
                if (-not $directoryAllowed) { throw "Directory archive entries are not allowed: $relative" }
                throw "Directory archive entries are not supported by this staging policy: $relative"
            }
            Assert-ArchiveEntryAllowed $relative $policy
            if ([int64]$entry.Length -lt 0 -or [int64]$entry.Length -gt $maxEntry) { throw "Archive entry exceeds its size limit: $relative" }
            if ([int64]$entry.CompressedLength -lt 0) { throw "Archive entry has an invalid compressed size: $relative" }
            $total += [int64]$entry.Length
            if ($total -gt $maxExtracted) { throw 'Runtime archive exceeds the bounded extracted-size limit.' }
            $plan.Add([pscustomobject]@{
                OriginalName = $raw
                RelativeName = $relative
                Length = [int64]$entry.Length
                CompressedLength = [int64]$entry.CompressedLength
            })
        }
        foreach ($entry in $required) {
            $canonical = (Assert-SafeRelativePath $entry).Relative
            if (-not (@($plan | Where-Object { $_.RelativeName.Equals($canonical, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)) {
                throw "Required runtime archive entry is missing: $canonical"
            }
        }
        if ($plan.Count -ne $expectedEntryCount) {
            throw "Runtime archive entry count mismatch: expected $expectedEntryCount, found $($plan.Count)."
        }
        $canonicalNameArray = [string[]]@($plan | ForEach-Object { $_.RelativeName })
        [Array]::Sort($canonicalNameArray, [StringComparer]::Ordinal)
        $canonicalNames = ($canonicalNameArray -join "`n") + "`n"
        $actualEntryNamesSha256 = Get-TextSha256 $canonicalNames
        if ($actualEntryNamesSha256 -ne $expectedEntryNamesSha256) {
            throw "Runtime archive entry-name digest mismatch: expected $expectedEntryNamesSha256, found $actualEntryNamesSha256."
        }
        return @($plan.ToArray())
    } finally {
        if ($null -ne $archiveHandle) { $archiveHandle.Dispose() }
    }
}

function Copy-FileBounded {
    param(
        [string]$Source,
        [string]$Destination,
        [int64]$ExpectedBytes,
        [string]$Boundary,
        [string]$ExpectedSha256 = ''
    )
    if ([string]::IsNullOrWhiteSpace($Boundary)) { throw 'A managed staging boundary is required for file copy.' }
    $sourceItem = Assert-ExistingFile $Source 'staging source file'
    if ($sourceItem.Length -ne $ExpectedBytes) { throw "Staging source changed size: $Source" }
    $parent = [IO.Path]::GetDirectoryName($Destination)
    Ensure-DirectoryTreeSafe $parent (Get-PathKey $Boundary)
    Assert-NoReparseChain $Destination -AllowMissingLeaf
    if (Test-Path -LiteralPath $Destination -PathType Container) { throw "Staging destination is a directory: $Destination" }
    if (Test-Path -LiteralPath $Destination) {
        [void](Assert-ExistingFile $Destination 'existing managed staging file')
    }
    $input = $null
    $output = $null
    try {
        $input = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $output = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 1048576
        [int64]$written = 0
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($written + $read -gt $ExpectedBytes) { throw "Staging source exceeded its declared size: $Source" }
            $output.Write($buffer, 0, $read)
            $written += $read
        }
        if ($written -ne $ExpectedBytes) { throw "Staging source ended at an unexpected size: $Source" }
    } finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $input) { $input.Dispose() }
    }
    $destinationItem = Assert-ExistingFile $Destination 'staged file'
    if ($destinationItem.Length -ne $ExpectedBytes) { throw "Staged file has the wrong size: $Destination" }
    $destinationHash = Get-Sha256 $Destination
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $destinationHash -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "Staged file has the wrong SHA-256: $Destination"
    }
    return $destinationHash
}

function Extract-ArchiveBounded {
    param(
        [string]$ArchivePath,
        [object[]]$Plan,
        [string]$RuntimeRoot
    )
    [void](Assert-ExistingFile $ArchivePath 'runtime archive input')
    [void](Assert-ExistingDirectory $RuntimeRoot 'runtime staging directory')
    $archiveHandle = $null
    try {
        $archiveHandle = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        $archiveEntries = @($archiveHandle.Entries)
        foreach ($planned in $Plan) {
            $matches = @($archiveEntries | Where-Object {
                $safe = Assert-SafeRelativePath ([string]$_.FullName)
                $safe.Relative.Equals($planned.RelativeName, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($matches.Count -ne 1) { throw "Runtime archive changed while staging: $($planned.RelativeName)" }
            $entry = $matches[0]
            $external = [uint32]([int64]$entry.ExternalAttributes -band 0xffffffffL)
            $unixType = ($external -shr 16) -band 0xF000
            if (($external -band 0x400) -ne 0 -or $unixType -eq 0xA000) { throw "Archive entry became a symlink/reparse point: $($planned.RelativeName)" }
            $destination = Get-SafeChildPath $RuntimeRoot $planned.RelativeName
            $parent = [IO.Path]::GetDirectoryName($destination)
            Ensure-DirectoryTreeSafe $parent (Get-PathKey $RuntimeRoot)
            Assert-NoReparseChain $Destination -AllowMissingLeaf
            if (Test-Path -LiteralPath $Destination -PathType Container) { throw "Archive destination is a directory: $destination" }
            if (Test-Path -LiteralPath $Destination) { [void](Assert-ExistingFile $Destination 'existing managed runtime entry') }
            $input = $null
            $output = $null
            try {
                $input = $entry.Open()
                $output = [IO.File]::Open($destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $buffer = New-Object byte[] 1048576
                [int64]$written = 0
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    if ($written + $read -gt $planned.Length) { throw "Archive entry expanded beyond its declared length: $($planned.RelativeName)" }
                    $output.Write($buffer, 0, $read)
                    $written += $read
                }
                if ($written -ne $planned.Length) { throw "Archive entry ended at an unexpected length: $($planned.RelativeName)" }
            } finally {
                if ($null -ne $output) { $output.Dispose() }
                if ($null -ne $input) { $input.Dispose() }
            }
            $resultItem = Assert-ExistingFile $destination 'staged runtime entry'
            if ($resultItem.Length -ne $planned.Length) { throw "Staged runtime entry has the wrong size: $destination" }
        }
    } finally {
        if ($null -ne $archiveHandle) { $archiveHandle.Dispose() }
    }
}

function Write-Utf8Json {
    param(
        [string]$Path,
        [object]$Value
    )
    # Depth 4 truncated the pinned manifest: `broker` and `runtime` are the
    # fourth level under the root, so their children were silently dropped and a
    # re-serialised manifest lost pinned identities. 12 is ample for this
    # document and keeps the receipt/manifest round-trip lossless.
    $json = ConvertTo-Json -InputObject $Value -Depth 12
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8)
}

# FixtureMode exists only for the offline synthetic test.  Keep it confined to
# the disposable test-results namespace so it cannot relax the production pin.
# Validate the manifest and resolve its fixed license/notice inputs.
Assert-NoDotDotPathToken $ManifestPath
$manifestFull = Assert-ExistingFile (Get-FullPath $ManifestPath) 'AI runtime manifest'
if ($FixtureMode) {
    $fixtureBoundary = Get-FullPath (Join-Path $repository '.local\test-results')
    $fixtureParent = Split-Path -Leaf (Split-Path -Parent $manifestFull)
    if (-not (Test-PathWithin $manifestFull $fixtureBoundary) -or $fixtureParent -notlike 'airuntime-staging-*') {
        throw 'FixtureMode is restricted to a disposable .local/test-results/airuntime-staging-* manifest.'
    }
}
$manifestHash = Get-Sha256 $manifestFull
try {
    $manifestText = [IO.File]::ReadAllText($manifestFull, [Text.Encoding]::UTF8)
    $manifest = $manifestText | ConvertFrom-Json
} catch {
    throw "AI runtime manifest is not valid UTF-8 JSON: $($_.Exception.Message)"
}
[void](Assert-Manifest $manifest (Split-Path -Parent $manifestFull) -Fixture:$FixtureMode)
$manifestRoot = Split-Path -Parent $manifestFull
$model = Get-RequiredProperty $manifest 'model' 'manifest'
$runtime = Get-RequiredProperty $manifest 'runtime' 'manifest'
$staging = Get-RequiredProperty $manifest 'staging' 'manifest'
$weight = Get-RequiredProperty $model 'weight' 'model'
$asset = Get-RequiredProperty $runtime 'asset' 'runtime'
$archive = Get-RequiredProperty $runtime 'archive' 'runtime'
$localRoot = Get-FullPath (Join-Path $repository '.local')
if ($Stage) {
    Ensure-DirectoryTreeSafe $localRoot (Get-PathKey $repository)
} elseif (Test-Path -LiteralPath $localRoot) {
    [void](Assert-ExistingDirectory $localRoot 'repository .local boundary')
} else {
    Assert-NoReparseChain $localRoot -AllowMissingLeaf
}
$output = Resolve-OutputDirectory $OutputDirectory $manifest $repository $localRoot

$modelDirectory = [string](Get-RequiredProperty $staging 'modelDirectory' 'staging')
$runtimeDirectory = [string](Get-RequiredProperty $staging 'runtimeDirectory' 'staging')
$licenseDirectory = [string](Get-RequiredProperty $staging 'licenseDirectory' 'staging')
$noticeFile = [string](Get-RequiredProperty $staging 'noticeFile' 'staging')
$receiptFile = [string](Get-RequiredProperty $staging 'receiptFile' 'staging')
$modelRelative = Join-Path $modelDirectory ([string]$weight.fileName)
$modelRelative = (Assert-SafeRelativePath $modelRelative).Relative
$modelLicenseRelative = Join-Path $licenseDirectory (Split-Path -Leaf ([string]$model.licensePath))
$modelLicenseRelative = (Assert-SafeRelativePath $modelLicenseRelative).Relative
$runtimeLicenseRelative = Join-Path $licenseDirectory (Split-Path -Leaf ([string]$runtime.licensePath))
$runtimeLicenseRelative = (Assert-SafeRelativePath $runtimeLicenseRelative).Relative
$noticeRelative = (Assert-SafeRelativePath $noticeFile).Relative
$receiptRelative = (Assert-SafeRelativePath $receiptFile).Relative
$expectedFiles = New-Object 'System.Collections.Generic.List[string]'
$expectedDirectories = New-Object 'System.Collections.Generic.List[string]'
foreach ($relative in @($modelRelative, $modelLicenseRelative, $runtimeLicenseRelative, $noticeRelative, $receiptRelative)) {
    [void]$expectedFiles.Add($relative)
    Add-ParentRelativePaths $expectedDirectories $relative
}
$modelInputStatus = 'not-supplied'
$runtimeInputStatus = 'not-supplied'
$modelInput = $null
$runtimeInput = $null
$archivePlan = @()
if ($ModelPath) {
    Assert-NoDotDotPathToken $ModelPath
    $modelInput = Get-FullPath $ModelPath
    [void](Assert-ExistingFile $modelInput 'model weight input')
    if ((Split-Path -Leaf $modelInput) -ne [string]$weight.fileName -and -not $FixtureMode) { throw 'Model input file name does not match the manifest.' }
    [void](Assert-FileDigest $modelInput ([int64]$weight.bytes) ([string]$weight.sha256) 'model weight input')
    $modelInputStatus = 'verified'
}
if ($RuntimeArchivePath) {
    Assert-NoDotDotPathToken $RuntimeArchivePath
    $runtimeInput = Get-FullPath $RuntimeArchivePath
    [void](Assert-ExistingFile $runtimeInput 'runtime archive input')
    if ((Split-Path -Leaf $runtimeInput) -ne [string]$asset.fileName -and -not $FixtureMode) { throw 'Runtime archive input file name does not match the manifest.' }
    [void](Assert-FileDigest $runtimeInput ([int64]$asset.bytes) ([string]$asset.sha256) 'runtime archive input')
    $archivePlan = @(Read-ArchivePlan $runtimeInput $archive)
    foreach ($entry in $archivePlan) {
        $runtimeRelative = Join-Path $runtimeDirectory $entry.RelativeName
        $runtimeRelative = (Assert-SafeRelativePath $runtimeRelative).Relative
        [void]$expectedFiles.Add($runtimeRelative)
        Add-ParentRelativePaths $expectedDirectories $runtimeRelative
    }
    $runtimeInputStatus = 'verified'
}
# The archive plan, when present, is the complete set of runtime files allowed
# in an existing staging directory.  No unknown file is silently removed.
if ($archivePlan.Count -eq 0) { [void]$expectedDirectories.Add($runtimeDirectory) }
Assert-ManagedStagingTree $output @($expectedFiles.ToArray()) @($expectedDirectories.ToArray())

if (-not $Stage) {
    return [pscustomobject]@{
        Mode = 'plan'
        Manifest = $manifestFull
        ManifestSha256 = $manifestHash
        ModelInput = $modelInputStatus
        RuntimeArchiveInput = $runtimeInputStatus
        OutputDirectory = $output
        OutputExists = (Test-Path -LiteralPath $output)
        Staged = $false
        NetworkUsed = $false
        ArchiveEntryCount = $archivePlan.Count
        Notice = 'Offline validation/plan only. No files were downloaded, extracted, copied, or deleted.'
    }
}

if ($modelInputStatus -ne 'verified' -or $runtimeInputStatus -ne 'verified') {
    throw 'Staging requires both a model weight input and a runtime archive input. Use the default plan mode to inspect missing inputs.'
}

# All paths are checked again immediately before any write.
Ensure-DirectoryTreeSafe $output (Get-PathKey $localRoot)
foreach ($relative in @($modelDirectory, $runtimeDirectory, $licenseDirectory)) {
    $directory = Get-SafeChildPath $output $relative
    Ensure-DirectoryTreeSafe $directory (Get-PathKey $output)
}
$modelDestination = Get-SafeChildPath $output $modelRelative
$modelLicenseDestination = Get-SafeChildPath $output $modelLicenseRelative
$runtimeLicenseDestination = Get-SafeChildPath $output $runtimeLicenseRelative
$noticeDestination = Get-SafeChildPath $output $noticeRelative
$receiptDestination = Get-SafeChildPath $output $receiptRelative
Assert-ManagedStagingTree $output @($expectedFiles.ToArray()) @($expectedDirectories.ToArray())
[void](Copy-FileBounded $modelInput $modelDestination ([int64]$weight.bytes) $output ([string]$weight.sha256))
$modelStagedHash = Assert-FileDigest $modelDestination ([int64]$weight.bytes) ([string]$weight.sha256) 'staged model weight'

$modelLicenseSource = Assert-ManifestRelativeFile $manifestRoot ([string]$model.licensePath) 'model license' ([int64]$model.licenseFileBytes) ([string]$model.licenseFileSha256)
$runtimeLicenseSource = Assert-ManifestRelativeFile $manifestRoot ([string]$runtime.licensePath) 'runtime license' ([int64]$runtime.licenseFileBytes) ([string]$runtime.licenseFileSha256)
$noticeSource = Assert-ManifestRelativeFile $manifestRoot ([string]$manifest.licenseNotice.path) 'third-party notice' ([int64]$manifest.licenseNotice.bytes) ([string]$manifest.licenseNotice.sha256)
[void](Copy-FileBounded $modelLicenseSource $modelLicenseDestination ([int64]$model.licenseFileBytes) $output ([string]$model.licenseFileSha256))
[void](Copy-FileBounded $runtimeLicenseSource $runtimeLicenseDestination ([int64]$runtime.licenseFileBytes) $output ([string]$runtime.licenseFileSha256))
[void](Copy-FileBounded $noticeSource $noticeDestination ([int64]$manifest.licenseNotice.bytes) $output ([string]$manifest.licenseNotice.sha256))
Extract-ArchiveBounded $runtimeInput $archivePlan (Get-SafeChildPath $output $runtimeDirectory)
$postArchiveHash = Assert-FileDigest $runtimeInput ([int64]$asset.bytes) ([string]$asset.sha256) 'runtime archive after extraction'
if ($postArchiveHash -ne (Get-Sha256 $runtimeInput)) { throw 'Runtime archive changed during extraction.' }

$runtimeRecords = @()
foreach ($entry in ($archivePlan | Sort-Object RelativeName)) {
    $runtimeRelative = Join-Path $runtimeDirectory $entry.RelativeName
    $runtimeRelative = (Assert-SafeRelativePath $runtimeRelative).Relative
    $stagedPath = Get-SafeChildPath $output $runtimeRelative
    $runtimeRecords += [pscustomobject]@{
        RelativePath = (ConvertTo-PortableRelativeString $runtimeRelative)
        Bytes = (Get-Item -LiteralPath $stagedPath -Force).Length
        Sha256 = Get-Sha256 $stagedPath
    }
}
$receipt = [ordered]@{
    schemaVersion = 1
    status = 'staged-verified-local-ai-runtime'
    manifest = [ordered]@{
        path = (ConvertTo-PortableRelativeString (Get-PortableRelativePath $manifestFull $repository))
        sha256 = $manifestHash
        schemaVersion = 1
    }
    model = [ordered]@{
        source = (ConvertTo-PortableRelativeString (Get-PortableRelativePath $modelInput $repository))
        staged = (ConvertTo-PortableRelativeString $modelRelative)
        bytes = [int64]$weight.bytes
        sha256 = $modelStagedHash
        license = [string]$model.license
        licensePath = (ConvertTo-PortableRelativeString $modelLicenseRelative)
    }
    runtime = [ordered]@{
        source = (ConvertTo-PortableRelativeString (Get-PortableRelativePath $runtimeInput $repository))
        stagedDirectory = (ConvertTo-PortableRelativeString $runtimeDirectory)
        bytes = [int64]$asset.bytes
        sha256 = $postArchiveHash
        release = [string]$runtime.release
        revision = [string]$runtime.revision
        license = [string]$runtime.license
        licensePath = (ConvertTo-PortableRelativeString $runtimeLicenseRelative)
        entries = $runtimeRecords
    }
    notice = [ordered]@{
        path = (ConvertTo-PortableRelativeString $noticeRelative)
        bytes = (Get-Item -LiteralPath $noticeDestination -Force).Length
        sha256 = Get-Sha256 $noticeDestination
    }
    conversionReproducibility = 'unverified'
    networkUsed = $false
    deletePolicy = 'no recursive or caller-path deletion'
}
Write-Utf8Json $receiptDestination $receipt
[void](Assert-ExistingFile $receiptDestination 'staging receipt')
return [pscustomobject]@{
    Mode = 'stage'
    Manifest = $manifestFull
    ManifestSha256 = $manifestHash
    OutputDirectory = $output
    Model = $modelDestination
    RuntimeDirectory = (Get-SafeChildPath $output $runtimeDirectory)
    Receipt = $receiptDestination
    RuntimeEntries = $runtimeRecords.Count
    NetworkUsed = $false
}
