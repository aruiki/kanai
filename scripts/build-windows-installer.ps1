# Build the KanaAI Windows MSI/Setup candidate from a validated, immutable
# runtime snapshot.  This script does not download, install, register, or
# publish anything.  The default output is a local candidate directory; the
# generated files are explicitly unverified and unsigned unless independently
# verified later.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
    [Parameter(Mandatory = $true)][string]$InstallerHelper,
    [string]$Version = '0.1.0',
    [string]$OutputDirectory = '',
    [string]$WixPath = '',
    [string]$RuntimeManifestPath = '',
    # Optional local-AI payload inputs.  They are all-or-none: supplying any
    # subset is rejected before this script writes anything.  With none of them
    # the build is exactly the historical non-AI path.
    [string]$BrokerExecutable = '',
    [string]$AiRuntimeDirectory = '',
    [string]$AiManifestPath = '',
    [string]$AiReceiptPath = '',
    # Offline structural fixture mode for the synthetic installer test.  It is
    # confined to a disposable .local/test-results manifest and only relaxes the
    # large artifact digests; identity, status, flag, license, notice, PE, and
    # path contracts are still enforced.  It is not a production input.
    [switch]$AiFixtureMode,
    [switch]$RequireCleanSource,
    # Test-only: skip the repository source-identity comparison so a negative
    # payload fixture reaches the validator under test. Never set this for a
    # release candidate; -RequireCleanSource still fails closed independently.
    [switch]$SkipSourceIdentity,
    [switch]$ValidateOnly,
    # Publishing renames the built MSI/Setup into the output directory. A
    # freshly written MSI is picked up asynchronously by Windows Defender (or
    # any other real-time scanner) and stays locked for as long as the scan
    # runs. Measured here: an 18 MB Mozc-only MSI was still un-renamable after
    # 5 attempts / 2 s, and only became free once the build had been running
    # longer. The window must therefore cover a scan, not a scheduling hiccup,
    # and must be raisable for a multi-gigabyte payload without editing this.
    [int]$PublishRetryCount = 60,
    [int]$PublishRetryDelayMilliseconds = 500
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$packageSource = Join-Path $repository 'platform\windows-tsf\installer\package'

if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be an MSI major.minor.build version.' }
if ($PublishRetryCount -lt 1 -or $PublishRetryCount -gt 1000) { throw 'PublishRetryCount must be between 1 and 1000.' }
if ($PublishRetryDelayMilliseconds -lt 0 -or $PublishRetryDelayMilliseconds -gt 60000) { throw 'PublishRetryDelayMilliseconds must be between 0 and 60000.' }

# Resolve the local-AI input mode before this script creates, copies, or writes
# anything.  All four inputs travel together; a partial combination is a
# configuration error, not a reduced payload.
$aiInputNames = @('BrokerExecutable', 'AiRuntimeDirectory', 'AiManifestPath', 'AiReceiptPath')
$aiInputValues = @([string]$BrokerExecutable, [string]$AiRuntimeDirectory, [string]$AiManifestPath, [string]$AiReceiptPath)
$aiProvided = @()
for ($aiIndex = 0; $aiIndex -lt $aiInputValues.Count; $aiIndex++) {
    if (-not [string]::IsNullOrWhiteSpace($aiInputValues[$aiIndex])) { $aiProvided += $aiInputNames[$aiIndex] }
}
$aiMode = [pscustomobject]@{ Enabled = ($aiProvided.Count -gt 0); Provided = @($aiProvided) }
if ($aiMode.Enabled -and $aiProvided.Count -ne $aiInputNames.Count) {
    $aiMissing = @($aiInputNames | Where-Object { $aiProvided -notcontains $_ })
    throw ("Local AI payload inputs are all-or-none. Supply all four of " + ($aiInputNames -join ', ') + " or none. Missing: " + ($aiMissing -join ', ') + '.')
}
if ($AiFixtureMode -and -not $aiMode.Enabled) { throw '-AiFixtureMode requires the four local AI payload inputs.' }
if ($AiFixtureMode) {
    $aiFixturePrefix = [System.IO.Path]::GetFullPath((Join-Path $repository '.local\test-results\airuntime-staging-'))
    $aiFixtureManifest = [System.IO.Path]::GetFullPath($AiManifestPath)
    if (-not $aiFixtureManifest.StartsWith($aiFixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'AI fixture mode is restricted to a disposable .local/test-results/airuntime-staging-* manifest.'
    }
}

$requiredPatchNames = @(
    '0001-install-kanai-supplemental-model.patch'
    '0002-kanai-tsf-identity.patch'
    '0003-session-generation-binding.patch'
    '0004-windows-python-toolchain.patch'
    '0005-windows-runtime-identity.patch'
    '0006-windows-installer-runtime-path.patch'
)
$mutationPrefixes = @('platform\windows-tsf\', 'scripts\', 'patches\')
$runtimeSpecs = @(
    @{ Name = 'mozc_tip64.dll'; Machine = 0x8664; Type = 'Dll'; Exports = @('DllGetClassObject', 'DllCanUnloadNow') },
    @{ Name = 'mozc_tip32.dll'; Machine = 0x014c; Type = 'Dll'; Exports = @('DllGetClassObject', 'DllCanUnloadNow') },
    @{ Name = 'mozc_server.exe'; Machine = 0x8664; Type = 'Exe'; Exports = @() },
    @{ Name = 'mozc_renderer.exe'; Machine = 0x8664; Type = 'Exe'; Exports = @() },
    @{ Name = 'mozc_broker.exe'; Machine = 0x8664; Type = 'Exe'; Exports = @() }
)
$helperSpec = @{
    Name = 'mozc_installer_helper.dll'
    Machine = 0x8664
    Type = 'Dll'
    Exports = @('RegisterTIP', 'RegisterTIPRollback', 'UnregisterTIP', 'UnregisterTIPRollback', 'EnableTipProfile', 'RestoreUserIMEEnvironment', 'ShutdownServer')
}
$redistNames = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$noticeNames = @('LICENSE.txt', 'MOZC-LICENSE.txt', 'credits_en.html', 'README.txt')

# ---------------------------------------------------------------------------
# Local-AI payload contract.  These are build-time constants, not values taken
# from the caller: the supplied AI manifest is cross-checked against them so a
# rewritten manifest cannot silently change what would be packaged.  Nothing
# here asserts that the AI runtime starts, works, or is acceptable in quality.
$aiBrokerFileName = 'kanai-broker.exe'
$aiPayloadRootDirectory = 'ai'
$aiModelDirectoryName = 'model'
$aiRuntimeDirectoryName = 'runtime'
$aiLicenseDirectoryName = 'licenses'
$aiServerEntry = 'llama-server.exe'
$aiSanitizedManifestFileName = 'PACKAGE-MANIFEST.json'
$aiSanitizedManifestStatus = 'staged-verified-local-ai-runtime-sanitized'
$aiDirectoryIds = [ordered]@{
    root = 'AIFOLDER'
    model = 'AIMODELFOLDER'
    runtime = 'AIRUNTIMEFOLDER'
    license = 'AILICENSEFOLDER'
}
$aiPinned = [ordered]@{
    schema = 'kanai.ai.runtime.manifest/v1'
    schemaVersion = 1
    manifestVersion = 1
    status = 'pinned-assets-verified-not-staged'
    receiptStatus = 'staged-verified-local-ai-runtime'
    receiptSchemaVersion = 1
    modelRepository = 'Qwen/Qwen2.5-1.5B-Instruct-GGUF'
    modelRevision = '91cad51170dc346986eccefdc2dd33a9da36ead9'
    modelLicense = 'Apache-2.0'
    modelLicenseRelative = 'licenses/Qwen-Apache-2.0.txt'
    modelLicenseBytes = 11927
    modelLicenseSha256 = '425153e94d7d7ebb80995e7efd8713b7ca2c98d38d3bad54781a9fab848069e8'
    modelFileName = 'qwen2.5-1.5b-instruct-q4_k_m.gguf'
    modelBytes = 1117320736
    modelSha256 = '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e'
    modelFileCommit = 'dd26da440ef0330c47919d1ecae0966d24022222'
    # The shipped Rust broker is part of the reviewed AI bundle. Pinning it here
    # means the manifest and the builder cannot drift apart, and an arbitrary
    # non-Mozc executable can never satisfy the broker slot.
    brokerFileName = 'kanai-broker.exe'
    brokerBytes = 2817024
    brokerSha256 = '85f4930d5976b5339de10216d53c20bea4d68d3bae6d25e2668ed24de101dac4'
    brokerMachine = '0x8664'
    brokerOptionalMagic = '0x020B'
    brokerArchitecture = 'x64'
    brokerKind = 'Exe'
    runtimeRepository = 'ggml-org/llama.cpp'
    runtimeRelease = 'b11146'
    runtimeRevision = '7fe450e19305b828c199d602c23a8337aaa1f03b'
    runtimeLicense = 'MIT'
    runtimeLicenseRelative = 'licenses/llama.cpp-MIT.txt'
    runtimeLicenseBytes = 1396
    runtimeLicenseSha256 = 'b63f92bb31389f53ce2b005be8f59e59f43b6117c0d41bd94749eb4b5b7518f8'
    runtimeAssetFileName = 'llama-b11146-bin-win-cpu-x64.zip'
    runtimeAssetBytes = 18560055
    runtimeAssetSha256 = '14cf1303ca9ac3abd94816850532f9f9a69ac66fbaca3776fc6f9061c2fac1d1'
    runtimeEntryCount = 51
    runtimeEntryNamesSha256 = '68da91a595ea841f87c7f7f34aff23bdf0a9910f129cf0fd3a06264205b61f0c'
    noticeRelative = 'THIRD-PARTY-NOTICES.txt'
    noticeBytes = 3613
    noticeSha256 = '2fa9a4c66b97ca5ae42de7f9372514d866c3e824f4f27ef08ebd07adf76dbae4'
    dependencyNoticeStatus = 'unverified-incomplete'
    sbomStatus = 'not-generated'
    modelDirectory = 'model'
    runtimeDirectory = 'runtime'
    licenseDirectory = 'licenses'
    receiptFile = 'STAGING-RECEIPT.json'
    conversionReproducibility = 'unverified'
    receiptDeletePolicy = 'no recursive or caller-path deletion'
    stagingDeletePolicy = 'never-delete-caller-paths'
}
$buildInputRelativePaths = @(
    'platform\windows-tsf\installer\package\KanaAI.wxs'
    'platform\windows-tsf\installer\package\Setup.cs'
    'platform\windows-tsf\installer\package\Setup.manifest'
    'platform\windows-tsf\build\toolchain.json'
    'scripts\stage-tsf-runtime.ps1'
    'scripts\build-windows-installer.ps1'
)

function Get-FullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is not allowed.' }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([char[]]'\/') }
    return $full
}

function Test-PathWithin([string]$Path, [string]$Root) {
    $pathFull = Get-FullPath $Path
    $rootFull = Get-FullPath $Root
    if ($pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePath([string]$Path, [switch]$AllowMissing) {
    $full = Get-FullPath $Path
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { throw "Path has no filesystem root: $full" }
    $current = $root
    try {
        $rootItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse-point filesystem root is not allowed: $current"
        }
    }
    catch {
        if (-not $AllowMissing) { throw }
    }
    $remainder = $full.Substring($root.Length)
    foreach ($part in @($remainder -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $current = Join-Path $current $part
        $item = $null
        try { $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop }
        catch {
            if ($AllowMissing) { break }
            throw "Path does not exist: $current"
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse-point path is not allowed: $current"
        }
    }
}

function Get-ExistingPath([string]$Path, [string]$PathType) {
    Assert-NoReparsePath -Path $Path
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $full = [System.IO.Path]::GetFullPath($resolved.Path)
    Assert-NoReparsePath -Path $full
    if ($PathType -eq 'Leaf' -and -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Expected a file: $full" }
    if ($PathType -eq 'Container' -and -not (Test-Path -LiteralPath $full -PathType Container)) { throw "Expected a directory: $full" }
    return $full
}

function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToUpperInvariant() }
    finally { $sha256.Dispose(); $stream.Dispose() }
}

function Get-TextSha256([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant() }
    finally { $sha256.Dispose() }
}

# Sort with the framework's ordinal comparer rather than culture-dependent
# Sort-Object behavior; Windows PowerShell 5.1 and PowerShell 7 must bind the
# same overlay/source file set.
function Sort-OrdinalStrings([string[]]$Values) {
    if ($null -eq $Values -or $Values.Count -eq 0) { return @() }
    [string[]]$copy = @($Values)
    [Array]::Sort($copy, [System.StringComparer]::Ordinal)
    return @($copy)
}

function Get-ObjectFingerprint($Value) {
    return Get-TextSha256 (($Value | ConvertTo-Json -Depth 30 -Compress))
}

function Get-JsonProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-GitCapture([string[]]$Arguments) {
    $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) { throw 'git is required to identify the installer source.' }
    $lines = @(& $git.Path -c 'core.safecrlf=false' @Arguments 2>$null)
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $code" }
    return (($lines | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-RepositoryMutationFingerprint([string]$RepositoryRoot, [string[]]$StatusLines) {
    $paths = @()
    try {
        $diffPaths = @(Invoke-GitCapture @('-C', $RepositoryRoot, 'diff', '--name-only', 'HEAD', '--') -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $untrackedPaths = @(Invoke-GitCapture @('-C', $RepositoryRoot, 'ls-files', '--others', '--exclude-standard') -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $relevantUntracked = @($untrackedPaths | Where-Object {
            $candidate = ([string]$_).Trim().Replace('/', '\')
            ($candidate -ieq 'LICENSE') -or @($mutationPrefixes | Where-Object { $candidate.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        })
        $paths = @($diffPaths + $relevantUntracked | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique -CaseSensitive)
        [string[]]$orderedPaths = @($paths)
        [Array]::Sort($orderedPaths, [System.StringComparer]::Ordinal)
        $paths = @($orderedPaths)
    }
    catch { throw "Unable to fingerprint repository mutations: $($_.Exception.Message)" }
    $records = @()
    foreach ($relative in $paths) {
        $relative = $relative.Replace('/', '\')
        $isRelevant = ($relative -ieq 'LICENSE') -or @($mutationPrefixes | Where-Object { $relative.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $isRelevant) { continue }
        $full = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relative))
        if (-not (Test-PathWithin $full $RepositoryRoot)) { throw "Git returned a path outside the repository: $relative" }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            Assert-NoReparsePath -Path $full
            $item = Get-Item -LiteralPath $full -Force
            $records += ($relative + '|file|' + [string]$item.Length + '|' + (Get-Sha256 -Path $full))
        }
        elseif (Test-Path -LiteralPath $full -PathType Container) { $records += ($relative + '|directory') }
        else { $records += ($relative + '|missing') }
    }
    return Get-TextSha256 ("status`n" + (($StatusLines | ForEach-Object { [string]$_ }) -join "`n") + "`nfiles`n" + ($records -join "`n"))
}

function Get-OverlayIdentity([string]$RepositoryRoot) {
    $overlayRoot = Join-Path $RepositoryRoot 'platform\windows-tsf\tsf\host_overlay'
    $result = [ordered]@{ status = 'unverified'; root = $overlayRoot; fingerprint = $null; fileCount = 0; files = @(); reason = '' }
    try {
        Assert-NoReparsePath -Path $overlayRoot
        if (-not (Test-Path -LiteralPath $overlayRoot -PathType Container)) { $result.reason = 'host overlay directory is unavailable'; return [pscustomobject]$result }
        $rootFull = Get-FullPath $overlayRoot
        $stack = New-Object System.Collections.Stack
        $stack.Push($rootFull)
        $records = @()
        while ($stack.Count -gt 0) {
            $directory = [string]$stack.Pop()
            foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point in host overlay is not allowed: $($item.FullName)" }
                if ($item.PSIsContainer) { $stack.Push($item.FullName) }
                else {
                    $relative = $item.FullName.Substring($rootFull.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
                    $records += [pscustomobject]@{ Path = $relative; Bytes = [int64]$item.Length; Sha256 = Get-Sha256 -Path $item.FullName }
                }
            }
        }
        $byPath = @{}
        foreach ($record in $records) { $byPath[[string]$record.Path] = $record }
        $orderedPaths = @(Sort-OrdinalStrings ([string[]]@($records | ForEach-Object { [string]$_.Path })))
        $records = @($orderedPaths | ForEach-Object { $byPath[[string]$_] })
        if ($records.Count -eq 0) { throw 'host overlay contains no files' }
        $text = ($records | ForEach-Object { ([string]$_.Path) + '|' + ([string]$_.Bytes) + '|' + ([string]$_.Sha256) }) -join "`n"
        $result.status = 'verified'; $result.root = $rootFull; $result.fingerprint = Get-TextSha256 $text; $result.fileCount = $records.Count
        $result.files = @($records | ForEach-Object { [ordered]@{ path = [string]$_.Path; bytes = [int64]$_.Bytes; sha256 = [string]$_.Sha256 } })
    }
    catch { $result.status = 'unverified'; $result.reason = $_.Exception.Message }
    return [pscustomobject]$result
}

function Get-PatchIdentity([string]$RepositoryRoot) {
    $patchRoot = Join-Path $RepositoryRoot 'platform\windows-tsf\tsf\patches'
    $result = [ordered]@{ status = 'unverified'; root = $patchRoot; requiredNames = @($requiredPatchNames); records = @(); reason = '' }
    try {
        Assert-NoReparsePath -Path $patchRoot
        if (-not (Test-Path -LiteralPath $patchRoot -PathType Container)) { $result.reason = 'patch directory is unavailable'; return [pscustomobject]$result }
        $actualNames = @(Get-ChildItem -LiteralPath $patchRoot -Force -File -Filter '*.patch' | ForEach-Object { $_.Name } | Sort-Object)
        $unexpected = @($actualNames | Where-Object { $requiredPatchNames -notcontains $_ })
        $missing = @($requiredPatchNames | Where-Object { $actualNames -notcontains $_ })
        if ($unexpected.Count -gt 0 -or $missing.Count -gt 0) {
            $result.reason = ('patch set mismatch; missing=[' + ($missing -join ',') + '] unexpected=[' + ($unexpected -join ',') + ']')
            return [pscustomobject]$result
        }
        $records = @()
        foreach ($name in $requiredPatchNames) {
            $path = Join-Path $patchRoot $name
            Assert-NoReparsePath -Path $path
            $item = Get-Item -LiteralPath $path -Force
            $records += [ordered]@{ name = $name; bytes = [int64]$item.Length; sha256 = Get-Sha256 -Path $path; required = $true }
        }
        $result.status = 'verified'; $result.root = Get-FullPath $patchRoot; $result.records = @($records | ForEach-Object { [pscustomobject]$_ })
    }
    catch { $result.status = 'unverified'; $result.reason = $_.Exception.Message }
    return [pscustomobject]$result
}

function Get-BuildConfigurationIdentity([string]$RepositoryRoot) {
    $path = Join-Path $RepositoryRoot 'platform\windows-tsf\build\toolchain.json'
    $result = [ordered]@{ status = 'unverified'; path = $path; sha256 = $null; schemaVersion = $null; platform = $null; architecture = $null; target = $null; configuration = $null; generator = $null; bazelVersion = $null; releaseConfig = $null; msvcConfig = $null; msvcToolchain = $null; reason = '' }
    try {
        Assert-NoReparsePath -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $result.reason = 'pinned toolchain configuration is unavailable'; return [pscustomobject]$result }
        $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $bazel = Get-JsonProperty $config 'bazel'
        $result.sha256 = Get-Sha256 -Path $path
        $result.schemaVersion = Get-JsonProperty $config 'schemaVersion'
        $result.platform = Get-JsonProperty $config 'platform'
        $result.architecture = Get-JsonProperty $config 'architecture'
        $result.target = Get-JsonProperty $config 'target'
        $result.configuration = Get-JsonProperty $config 'configuration'
        $result.generator = Get-JsonProperty $config 'generator'
        $result.bazelVersion = Get-JsonProperty $bazel 'version'
        $result.releaseConfig = Get-JsonProperty $bazel 'releaseConfig'
        $result.msvcConfig = Get-JsonProperty $bazel 'msvcConfig'
        $result.msvcToolchain = Get-JsonProperty $bazel 'msvcToolchain'
        if ($null -eq $result.schemaVersion -or [string]::IsNullOrWhiteSpace([string]$result.platform) -or [string]::IsNullOrWhiteSpace([string]$result.architecture) -or [string]::IsNullOrWhiteSpace([string]$result.target) -or [string]::IsNullOrWhiteSpace([string]$result.configuration) -or [string]::IsNullOrWhiteSpace([string]$result.bazelVersion)) { $result.reason = 'pinned toolchain configuration is incomplete'; return [pscustomobject]$result }
        $result.status = 'verified'
    }
    catch { $result.status = 'unverified'; $result.reason = $_.Exception.Message }
    return [pscustomobject]$result
}

function Get-BuildInputIdentity([string]$RepositoryRoot) {
    $records = @(); $status = 'verified'; $reason = ''
    try {
        foreach ($relative in $buildInputRelativePaths) {
            $path = Join-Path $RepositoryRoot $relative
            Assert-NoReparsePath -Path $path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $status = 'unverified'; $reason = "build input is unavailable: $relative"; continue }
            $item = Get-Item -LiteralPath $path -Force
            $records += [ordered]@{ path = $relative.Replace('\', '/'); bytes = [int64]$item.Length; sha256 = Get-Sha256 -Path $path }
        }
    }
    catch { $status = 'unverified'; $reason = $_.Exception.Message }
    $fingerprint = if ($records.Count -eq $buildInputRelativePaths.Count) { Get-TextSha256 (($records | ForEach-Object { ([string]$_.path) + '|' + ([string]$_.bytes) + '|' + ([string]$_.sha256) }) -join "`n") } else { $null }
    return [pscustomobject]@{ status = $status; records = @($records | ForEach-Object { [pscustomobject]$_ }); fingerprint = $fingerprint; reason = $reason }
}

function Get-SourceIdentity([string]$RepositoryRoot) {
    $reasons = @(); $head = $null; $statusLines = @(); $repositoryStatusAvailable = $false; $statusFingerprint = $null; $mutationFingerprint = $null
    $mozc = [ordered]@{ status = 'unverified'; gitlink = $null; commit = $null; clean = $null; reason = '' }
    try {
        $head = Invoke-GitCapture @('-C', $RepositoryRoot, 'rev-parse', 'HEAD')
        if ($head -notmatch '^[0-9a-fA-F]{40}$') { throw "repository HEAD is not a full commit: $head" }
        $statusText = Invoke-GitCapture @('-C', $RepositoryRoot, 'status', '--porcelain=v1', '--untracked-files=normal')
        # A clean tree produces no status output at all. An empty array returned
        # from an `if` expression is unrolled by the PowerShell pipeline into
        # $null, and StrictMode then throws PropertyNotFoundStrict on $null.Count
        # below. Assign the empty collection directly so a clean tree stays an
        # empty array. Measured: this made every clean-source release candidate
        # build impossible while dirty trees kept working.
        $statusLines = @()
        if (-not [string]::IsNullOrWhiteSpace($statusText)) { $statusLines = @($statusText -split "`n") }
        $statusFingerprint = Get-TextSha256 ($statusLines -join "`n")
        $mutationFingerprint = Get-RepositoryMutationFingerprint -RepositoryRoot $RepositoryRoot -StatusLines $statusLines
        $repositoryStatusAvailable = $true
    }
    catch { $reasons += $_.Exception.Message }
    try {
        $gitlink = Invoke-GitCapture @('-C', $RepositoryRoot, 'rev-parse', 'HEAD:third_party/mozc')
        $commit = Invoke-GitCapture @('-C', (Join-Path $RepositoryRoot 'third_party\mozc'), 'rev-parse', 'HEAD')
        $subStatusText = Invoke-GitCapture @('-C', (Join-Path $RepositoryRoot 'third_party\mozc'), 'status', '--porcelain=v1', '--untracked-files=normal')
        if ($gitlink -notmatch '^[0-9a-fA-F]{40}$' -or $commit -notmatch '^[0-9a-fA-F]{40}$' -or $gitlink -ne $commit) { throw "Mozc gitlink/commit is not an exact pinned pair (gitlink=$gitlink commit=$commit)." }
        $mozc.status = 'verified'; $mozc.gitlink = $gitlink.ToLowerInvariant(); $mozc.commit = $commit.ToLowerInvariant(); $mozc.clean = [string]::IsNullOrWhiteSpace($subStatusText)
    }
    catch { $mozc.reason = $_.Exception.Message; $reasons += $mozc.reason }
    $patchIdentity = Get-PatchIdentity -RepositoryRoot $RepositoryRoot
    $overlayIdentity = Get-OverlayIdentity -RepositoryRoot $RepositoryRoot
    $buildConfiguration = Get-BuildConfigurationIdentity -RepositoryRoot $RepositoryRoot
    $buildInputs = Get-BuildInputIdentity -RepositoryRoot $RepositoryRoot
    if ($patchIdentity.status -ne 'verified') { $reasons += [string]$patchIdentity.reason }
    if ($overlayIdentity.status -ne 'verified') { $reasons += [string]$overlayIdentity.reason }
    if ($buildConfiguration.status -ne 'verified') { $reasons += [string]$buildConfiguration.reason }
    if ($buildInputs.status -ne 'verified') { $reasons += [string]$buildInputs.reason }
    $dirty = if ($repositoryStatusAvailable) { (@($statusLines).Count -gt 0) -or ($mozc.status -eq 'verified' -and -not [bool]$mozc.clean) } else { $null }
    $overall = if ($reasons.Count -eq 0) { if ($dirty) { 'verified-dirty' } else { 'verified' } } else { 'unverified' }
    return [pscustomobject]@{
        status = $overall
        repositoryHead = if ($null -eq $head) { $null } else { $head.ToLowerInvariant() }
        repositoryDirty = $dirty
        repositoryStatusLines = @($statusLines)
        repositoryStatusSha256 = $statusFingerprint
        repositoryMutationSha256 = $mutationFingerprint
        mozc = [pscustomobject]$mozc
        mozcGitlink = if ($null -eq $mozc.gitlink) { $null } else { [string]$mozc.gitlink }
        mozcCommit = if ($null -eq $mozc.commit) { $null } else { [string]$mozc.commit }
        requiredPatchNames = @($requiredPatchNames)
        patches = @($patchIdentity.records)
        patchSetSha256 = if ($patchIdentity.status -eq 'verified') { Get-ObjectFingerprint @($patchIdentity.records) } else { $null }
        hostOverlay = $overlayIdentity
        hostOverlayFingerprint = if ($null -eq $overlayIdentity) { $null } else { $overlayIdentity.fingerprint }
        buildConfiguration = $buildConfiguration
        buildInputs = $buildInputs
        artifactBuildLinkage = [pscustomobject]@{
            status = 'unverified'
            verified = $false
            reason = 'This pipeline binds the current pinned source/configuration but does not assert which cached Bazel artifact was compiled from it.'
        }
        reasons = @($reasons)
    }
}

function Read-ExactBytes([byte[]]$Bytes, [int]$Offset, [int]$Count, [string]$Description) {
    if ($Offset -lt 0 -or $Count -lt 0 -or $Offset -gt $Bytes.Length - $Count) { throw "Truncated PE $Description at offset $Offset (requested $Count bytes)." }
    $result = New-Object byte[] $Count
    [Array]::Copy($Bytes, $Offset, $result, 0, $Count)
    return ,$result
}

function Convert-RvaToFileOffset($Image, [uint32]$Rva) {
    if ($Rva -eq 0) { return -1 }
    if ($Rva -lt [uint32]$Image.SizeOfHeaders) {
        if ($Rva -ge [uint32]$Image.Bytes.Length) { throw "PE header RVA is outside the file: 0x{0:X8}" -f $Rva }
        return [int]$Rva
    }
    foreach ($section in @($Image.Sections)) {
        $span = [Math]::Max([uint64]$section.VirtualSize, [uint64]$section.RawSize)
        $start = [uint64]$section.VirtualAddress
        $end = $start + $span
        if ([uint64]$Rva -ge $start -and [uint64]$Rva -lt $end) {
            $delta = [uint64]$Rva - $start
            if ($delta -ge [uint64]$section.RawSize) { throw "PE RVA points into uninitialized section data: 0x{0:X8}" -f $Rva }
            $offset = [uint64]$section.RawPointer + $delta
            if ($offset -gt [uint64]$Image.Bytes.Length) { throw "PE RVA is outside the file: 0x{0:X8}" -f $Rva }
            return [int]$offset
        }
    }
    throw "PE RVA cannot be mapped to a file offset: 0x{0:X8}" -f $Rva
}

function Get-PeExports($Image) {
    if ($Image.ExportRva -eq 0 -or $Image.ExportSize -eq 0) { return @() }
    if ($Image.ExportSize -lt 40) { throw "PE export directory is truncated: $($Image.Path)" }
    $directoryOffset = Convert-RvaToFileOffset $Image $Image.ExportRva
    $directory = Read-ExactBytes $Image.Bytes $directoryOffset 40 'export directory'
    if ([uint64]$directoryOffset + [uint64]$Image.ExportSize -gt [uint64]$Image.Bytes.Length) { throw "PE export directory extends beyond the file: $($Image.Path)" }
    $moduleNameRva = [BitConverter]::ToUInt32($directory, 12)
    $moduleNameOffset = Convert-RvaToFileOffset $Image $moduleNameRva
    $moduleNameEnd = $moduleNameOffset
    while ($moduleNameEnd -lt $Image.Bytes.Length -and $Image.Bytes[$moduleNameEnd] -ne 0) { $moduleNameEnd++ }
    if ($moduleNameRva -eq 0 -or $moduleNameEnd -ge $Image.Bytes.Length -or $moduleNameEnd -le $moduleNameOffset) { throw "PE export module name is truncated or empty: $($Image.Path)" }
    $functionCount = [BitConverter]::ToUInt32($directory, 20)
    $nameCount = [BitConverter]::ToUInt32($directory, 24)
    $functionsRva = [BitConverter]::ToUInt32($directory, 28)
    $namesRva = [BitConverter]::ToUInt32($directory, 32)
    $ordinalsRva = [BitConverter]::ToUInt32($directory, 36)
    if ($functionCount -eq 0 -or $functionCount -gt 65535 -or $nameCount -gt 65535 -or $nameCount -gt $functionCount) { throw "PE export table has invalid counts: $($Image.Path)" }
    $functionOffset = Convert-RvaToFileOffset $Image $functionsRva
    $namesOffset = Convert-RvaToFileOffset $Image $namesRva
    $ordinalsOffset = Convert-RvaToFileOffset $Image $ordinalsRva
    [void](Read-ExactBytes $Image.Bytes $functionOffset ([int]($functionCount * 4)) 'export function table')
    [void](Read-ExactBytes $Image.Bytes $namesOffset ([int]($nameCount * 4)) 'export name table')
    [void](Read-ExactBytes $Image.Bytes $ordinalsOffset ([int]($nameCount * 2)) 'export ordinal table')
    $names = @()
    for ($index = 0; $index -lt $nameCount; $index++) {
        $ordinalBytes = Read-ExactBytes $Image.Bytes ($ordinalsOffset + ($index * 2)) 2 'export ordinal'
        if ([BitConverter]::ToUInt16($ordinalBytes, 0) -ge $functionCount) { throw "PE export ordinal is outside the function table: $($Image.Path)" }
        $namePointerBytes = Read-ExactBytes $Image.Bytes ($namesOffset + ($index * 4)) 4 'export name pointer'
        $nameOffset = Convert-RvaToFileOffset $Image ([BitConverter]::ToUInt32($namePointerBytes, 0))
        $end = $nameOffset
        while ($end -lt $Image.Bytes.Length -and $Image.Bytes[$end] -ne 0) { $end++ }
        if ($end -ge $Image.Bytes.Length -or $end -le $nameOffset -or ($end - $nameOffset) -gt 4096) { throw "PE export name is truncated or empty: $($Image.Path)" }
        $names += [Text.Encoding]::ASCII.GetString($Image.Bytes, $nameOffset, $end - $nameOffset)
    }
    return @($names)
}

function Get-PeImage([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "PE image is missing: $Path" }
    Assert-NoReparsePath -Path $Path
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64) { throw "Truncated PE DOS header: $Path" }
    if ($bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "Invalid PE DOS magic (MZ signature missing): $Path" }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($peOffset -lt 64 -or $peOffset -gt $bytes.Length - 24) { throw "Truncated or invalid PE NT header offset: $Path" }
    $coff = Read-ExactBytes $bytes $peOffset 24 'COFF header'
    if ($coff[0] -ne 0x50 -or $coff[1] -ne 0x45 -or $coff[2] -ne 0 -or $coff[3] -ne 0) { throw "Invalid PE signature: $Path" }
    $machine = [BitConverter]::ToUInt16($coff, 4)
    $sectionCount = [BitConverter]::ToUInt16($coff, 6)
    $optionalSize = [BitConverter]::ToUInt16($coff, 20)
    $characteristics = [BitConverter]::ToUInt16($coff, 22)
    if ($sectionCount -eq 0 -or $sectionCount -gt 96) { throw "Invalid PE section count: $Path" }
    if ($optionalSize -lt 2) { throw "Truncated PE optional header: $Path" }
    $optionalOffset = $peOffset + 24
    $optional = Read-ExactBytes $bytes $optionalOffset $optionalSize 'optional header'
    $magic = [BitConverter]::ToUInt16($optional, 0)
    if ($magic -eq 0x20b -and $optionalSize -lt 112) { throw "Truncated PE32+ optional header: $Path" }
    if ($magic -eq 0x10b -and $optionalSize -lt 96) { throw "Truncated PE32 optional header: $Path" }
    if ($magic -ne 0x20b -and $magic -ne 0x10b) { throw ("Unsupported PE optional-header magic 0x{0:X4}: {1}" -f $magic, $Path) }
    $sizeOfHeaders = [BitConverter]::ToUInt32($optional, 60)
    $sectionTableOffset = $optionalOffset + $optionalSize
    $sectionTableBytes = [int64]$sectionCount * 40
    if ($sectionTableOffset -gt $bytes.Length - $sectionTableBytes) { throw "Truncated PE section table: $Path" }
    if ($sizeOfHeaders -lt [uint32]($sectionTableOffset + $sectionTableBytes) -or $sizeOfHeaders -gt [uint32]$bytes.Length) { throw "PE SizeOfHeaders is outside the file: $Path" }
    $sections = @()
    for ($index = 0; $index -lt $sectionCount; $index++) {
        $entry = Read-ExactBytes $bytes ($sectionTableOffset + ($index * 40)) 40 'section table'
        $name = [Text.Encoding]::ASCII.GetString($entry, 0, 8).Trim([char]0)
        $virtualSize = [BitConverter]::ToUInt32($entry, 8)
        $virtualAddress = [BitConverter]::ToUInt32($entry, 12)
        $rawSize = [BitConverter]::ToUInt32($entry, 16)
        $rawPointer = [BitConverter]::ToUInt32($entry, 20)
        if ($rawSize -gt 0 -and ([uint64]$rawPointer + [uint64]$rawSize) -gt [uint64]$bytes.Length) { throw "PE section raw data is outside the file: $Path ($name)" }
        if ($rawSize -eq 0 -and $rawPointer -gt [uint32]$bytes.Length) { throw "PE zero-size section pointer is outside the file: $Path ($name)" }
        $sections += [pscustomobject]@{ Name = $name; VirtualSize = $virtualSize; VirtualAddress = $virtualAddress; RawSize = $rawSize; RawPointer = $rawPointer }
    }
    $exportRva = [uint32]0; $exportSize = [uint32]0
    $directoryOffset = if ($magic -eq 0x20b) { 112 } else { 96 }
    if ($optionalSize -ge ($directoryOffset + 8)) { $exportRva = [BitConverter]::ToUInt32($optional, $directoryOffset); $exportSize = [BitConverter]::ToUInt32($optional, $directoryOffset + 4) }
    return [pscustomobject]@{ Path = [IO.Path]::GetFullPath($Path); Bytes = $bytes; Machine = $machine; MachineName = ('0x{0:X4}' -f $machine); Characteristics = $characteristics; IsDll = (($characteristics -band 0x2000) -ne 0); IsExe = (($characteristics -band 0x0002) -ne 0 -and ($characteristics -band 0x2000) -eq 0); OptionalMagic = $magic; OptionalMagicHex = ('0x{0:X4}' -f $magic); SizeOfHeaders = $sizeOfHeaders; ExportRva = $exportRva; ExportSize = $exportSize; Sections = @($sections) }
}

function Assert-Pe([string]$Path, [int]$Machine, [string]$Type, [string[]]$Exports) {
    $image = Get-PeImage $Path
    if ($image.Machine -ne $Machine) { throw ("PE architecture mismatch: {0} is {1}, expected 0x{2:X4}" -f (Split-Path -Leaf $Path), $image.MachineName, $Machine) }
    $expectedMagic = if ($Machine -eq 0x8664) { 0x20b } elseif ($Machine -eq 0x014c) { 0x10b } else { 0 }
    if ($expectedMagic -ne 0 -and $image.OptionalMagic -ne $expectedMagic) { throw ("PE optional-header architecture mismatch: {0} is {1}, expected 0x{2:X4}" -f (Split-Path -Leaf $Path), $image.OptionalMagicHex, $expectedMagic) }
    if ($Type -eq 'Dll' -and -not $image.IsDll) { throw "PE DLL/EXE mismatch: $(Split-Path -Leaf $Path) is not marked IMAGE_FILE_DLL." }
    if ($Type -eq 'Exe' -and -not $image.IsExe) { throw "PE DLL/EXE mismatch: $(Split-Path -Leaf $Path) is not a non-DLL executable." }
    if ($Exports.Count -gt 0) {
        $actual = @(Get-PeExports $image)
        $missing = @($Exports | Where-Object { $actual -cnotcontains $_ })
        if ($missing.Count -gt 0) { throw ("Missing required export(s) {0} in {1}; found: {2}" -f ($missing -join ', '), (Split-Path -Leaf $Path), ($actual -join ', ')) }
    }
    return $image
}

function Get-AuthenticodeStatus([string]$Path) {
    if (-not ('KanaAIWinTrustStatus' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KanaAIWinTrustStatus {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct FileInfo { public uint cbStruct; public IntPtr pcwszFilePath; public IntPtr hFile; public IntPtr pgKnownSubject; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Data { public uint cbStruct; public IntPtr pPolicyCallbackData; public IntPtr pSIPClientData; public uint dwUIChoice; public uint fdwRevocationChecks; public uint dwUnionChoice; public IntPtr pFile; public uint dwStateAction; public IntPtr hWVTStateData; public IntPtr pwszURLReference; public uint dwProvFlags; public uint dwUIContext; }
  [DllImport("wintrust.dll", CharSet = CharSet.Unicode)] private static extern uint WinVerifyTrust(IntPtr hwnd, ref Guid action, IntPtr data);
  public static string Get(string path) { Guid action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE"); IntPtr file = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(FileInfo))); IntPtr data = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Data))); IntPtr filePath = IntPtr.Zero; bool initialized = false; try { filePath = Marshal.StringToCoTaskMemUni(path); FileInfo fi = new FileInfo { cbStruct = (uint)Marshal.SizeOf(typeof(FileInfo)), pcwszFilePath = filePath }; Marshal.StructureToPtr(fi, file, false); Data d = new Data { cbStruct = (uint)Marshal.SizeOf(typeof(Data)), dwUIChoice = 2, fdwRevocationChecks = 0, dwUnionChoice = 1, pFile = file, dwStateAction = 1 }; Marshal.StructureToPtr(d, data, false); initialized = true; uint result = WinVerifyTrust(IntPtr.Zero, ref action, data); if (result == 0) return "Valid"; if (result == 0x800B0100) return "NotSigned"; if (result == 0x800B0004) return "NotTrusted"; return "Error(0x" + result.ToString("X8") + ")"; } finally { if (initialized) { Data current = (Data)Marshal.PtrToStructure(data, typeof(Data)); if (current.hWVTStateData != IntPtr.Zero) { current.dwStateAction = 2; Marshal.StructureToPtr(current, data, false); WinVerifyTrust(IntPtr.Zero, ref action, data); } } if (filePath != IntPtr.Zero) Marshal.FreeCoTaskMem(filePath); Marshal.FreeHGlobal(file); Marshal.FreeHGlobal(data); } }
}
'@
    }
    return [KanaAIWinTrustStatus]::Get($Path)
}

function Get-MsiPropertyMap([string]$Path) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $null
    try {
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @("SELECT ``Property``,``Value`` FROM ``Property``"))
        try {
            [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $properties = @{}
            while ($null -ne ($record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null))) {
                $name = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
                $value = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(2))
                $properties[$name] = $value
            }
            return $properties
        }
        finally { [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) }
    }
    finally {
        if ($null -ne $database) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
    }
}

function Get-ManifestResourceSha256([string]$AssemblyPath, [string]$ResourceName) {
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($AssemblyPath))
    $stream = $assembly.GetManifestResourceStream($ResourceName)
    if ($null -eq $stream) { throw "Setup resource is missing: $ResourceName" }
    try {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToUpperInvariant() }
        finally { $sha256.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-ExpectedFileSpec([string]$Name) {
    foreach ($spec in $runtimeSpecs) { if ($spec.Name -eq $Name) { return $spec } }
    if ($redistNames -contains $Name) { return @{ Name = $Name; Machine = 0x8664; Type = 'Dll'; Exports = @() } }
    if ($noticeNames -contains $Name) { return @{ Name = $Name; Machine = 0; Type = 'Notice'; Exports = @() } }
    return $null
}

function Get-FileRecord([string]$Path, [string]$Name, [string]$Type, [int]$Machine, [string[]]$Exports) {
    $item = Get-Item -LiteralPath $Path -Force
    return [pscustomobject]@{ Name = $Name; Bytes = [int64]$item.Length; Sha256 = Get-Sha256 -Path $Path; Machine = ('0x{0:x4}' -f $Machine); Type = $Type; Exports = @($Exports) }
}

function Assert-RecordMatchesFile($Record, [string]$Path, [string]$Name, [string]$Type, [int]$Machine, [string[]]$Exports) {
    if ([string]$Record.Name -cne $Name -or [string]$Record.Type -cne $Type -or [string]$Record.Machine -ine ('0x{0:x4}' -f $Machine)) { throw "Runtime manifest record metadata does not match $Name." }
    if ([int64]$Record.Bytes -ne [int64](Get-Item -LiteralPath $Path -Force).Length -or [string]$Record.Sha256 -ine (Get-Sha256 -Path $Path)) { throw "Runtime payload does not match its staged manifest: $Name" }
    $recordedExports = @(Get-JsonProperty $Record 'Exports')
    if ($recordedExports.Count -ne $Exports.Count -or @($Exports | Where-Object { $recordedExports -cnotcontains $_ }).Count -gt 0) { throw "Runtime manifest export contract does not match $Name." }
}

function Assert-SourceIdentityMatches($Expected, [string]$Context) {
    if ($null -eq $Expected -or [string]$Expected.status -notin @('verified', 'verified-dirty')) { throw "$Context source identity is unverified; release-candidate validation fails closed." }
    $current = Get-SourceIdentity -RepositoryRoot $repository
    if ([string]$current.status -notin @('verified', 'verified-dirty')) { throw 'Current repository source identity is unverified; release-candidate validation fails closed.' }
    if ((Get-ObjectFingerprint $current) -ne (Get-ObjectFingerprint $Expected)) {
        $changed = New-Object 'System.Collections.Generic.List[string]'
        foreach ($name in @($current.PSObject.Properties.Name)) {
            $a = (Get-ObjectFingerprint (Get-JsonProperty $Expected $name)); $b = (Get-ObjectFingerprint (Get-JsonProperty $current $name))
            if ($a -ne $b) { [void]$changed.Add([string]$name) }
        }
        throw ("{0} source identity changed (repository, patch, overlay, or build configuration). Changed: {1}" -f $Context, ($changed -join ', '))
    }
    return $current
}

function Assert-ManifestHasNoSelfHash($Manifest) {
    foreach ($name in @('manifestSha256', 'manifestSelfSha256', 'selfSha256', 'sha256')) {
        if ($null -ne $Manifest.PSObject.Properties[$name]) { throw 'Runtime manifest must not contain its own SHA-256; the consumer must record that hash separately.' }
    }
}

function Get-RequiredJsonProperty($Object, [string]$Name, [string]$Context) {
    if ($null -eq $Object) { throw "AI runtime manifest is missing the $Context object." }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { throw "AI runtime manifest field is required: $Context.$Name" }
    return $property.Value
}

function Get-AiStringArray($Value, [string]$Description, [switch]$AllowEmpty) {
    if ($null -eq $Value) { throw "AI runtime manifest field is required: $Description" }
    $items = @($Value)
    if (-not $AllowEmpty -and $items.Count -eq 0) { throw "AI runtime manifest field must not be empty: $Description" }
    foreach ($item in $items) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) { throw "AI runtime manifest field contains an invalid item: $Description" }
    }
    return @($items)
}

function Assert-AiHttpsUrl([string]$Value, [string]$Description) {
    if ($Value -notmatch '^https://') { throw "The pinned local AI $Description must use HTTPS." }
    try { $uri = [Uri]$Value } catch { throw "The pinned local AI $Description is not a valid URL." }
    if ($uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "The pinned local AI $Description must be an HTTPS URL without embedded credentials."
    }
}

# A managed relative path only.  This is the single gate for every path that
# reaches the AI payload, the generated fragment, or the public manifest.
function Assert-AiSafeRelativePath([string]$Relative, [string]$Description, [switch]$AllowDirectory) {
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw "The local AI $Description is an empty path." }
    if ($Relative -match '[\x00-\x1f\x7f-\x9f]') { throw "The local AI $Description contains control characters." }
    $normalized = $Relative.Replace('/', '\')
    $isDirectory = $normalized.EndsWith('\')
    if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized.StartsWith('\') -or $normalized -match '^[A-Za-z]:') {
        throw "The local AI $Description must be a relative path, not an absolute path: $Relative"
    }
    $body = $normalized.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($body)) { throw "The local AI $Description is an empty path." }
    foreach ($segment in @($body -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "The local AI $Description contains path traversal or an empty segment: $Relative"
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment.Contains('*') -or $segment.Contains('?') -or $segment.Contains(':')) {
            throw "The local AI $Description contains a Windows-ambiguous segment: $Relative"
        }
        if ((($segment -split '\.')[0]) -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw "The local AI $Description contains a reserved device name: $Relative"
        }
    }
    if ($isDirectory -and -not $AllowDirectory) { throw "The local AI $Description must name a file, not a directory: $Relative" }
    return $body.Replace('\', '/')
}

function Get-AiFileRecord([string]$Path, [string]$Relative, [string]$Kind, [int]$Machine) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) { throw "The local AI payload entry is a directory: $Relative" }
    return [pscustomobject]@{
        Path = $Relative
        Bytes = [int64]$item.Length
        Sha256 = (Get-Sha256 -Path $Path)
        Kind = $Kind
        Machine = ('0x{0:x4}' -f $Machine)
    }
}

# Validate the pinned local-AI manifest against build-time pins.  Only file
# digests/sizes of the large model weight and runtime archive, and the runtime
# closure entry count/name digest, are relaxed for the offline fixture.
function Assert-AiManifest([string]$Path, [switch]$Fixture) {
    $manifestSha256 = Get-Sha256 -Path $Path
    try { $manifest = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { throw "The pinned local AI manifest is not valid UTF-8 JSON: $($_.Exception.Message)" }
    $root = 'aiManifest'
    if ([string](Get-RequiredJsonProperty $manifest 'schema' $root) -ne $aiPinned.schema) { throw 'The pinned local AI manifest schema is not the reviewed local-AI manifest schema.' }
    if ([int](Get-RequiredJsonProperty $manifest 'schemaVersion' $root) -ne $aiPinned.schemaVersion) { throw 'The pinned local AI manifest schemaVersion is not supported.' }
    if ([int](Get-RequiredJsonProperty $manifest 'manifestVersion' $root) -ne $aiPinned.manifestVersion) { throw 'The pinned local AI manifest manifestVersion is not supported.' }
    if ((Get-RequiredJsonProperty $manifest 'noSecrets' $root) -ne $true) { throw 'The pinned local AI manifest must declare noSecrets=true.' }
    $status = [string](Get-RequiredJsonProperty $manifest 'status' $root)
    if ($status -ne $aiPinned.status) { throw "The pinned local AI manifest status is not the reviewed staging input status: $status" }
    $product = Get-RequiredJsonProperty $manifest 'product' $root
    if ((Get-RequiredJsonProperty $product 'offlineOnly' 'aiManifest.product') -ne $true -or
        (Get-RequiredJsonProperty $product 'networkAtRuntime' 'aiManifest.product') -ne $false) {
        throw 'The pinned local AI runtime must be declared offline-only with no runtime network use.'
    }
    $platform = Get-RequiredJsonProperty $manifest 'platform' $root
    if ([string](Get-RequiredJsonProperty $platform 'os' 'aiManifest.platform') -ne 'windows' -or
        [string](Get-RequiredJsonProperty $platform 'architecture' 'aiManifest.platform') -ne 'x64' -or
        (Get-RequiredJsonProperty $platform 'cpuOnly' 'aiManifest.platform') -ne $true -or
        (Get-RequiredJsonProperty $platform 'gpuRequired' 'aiManifest.platform') -ne $false) {
        throw 'The pinned local AI runtime must be Windows x64 CPU-only.'
    }

    $model = Get-RequiredJsonProperty $manifest 'model' $root
    $modelContext = 'aiManifest.model'
    if ([string](Get-RequiredJsonProperty $model 'repository' $modelContext) -ne $aiPinned.modelRepository) { throw 'The local AI model repository is not the pinned pairing.' }
    if ([string](Get-RequiredJsonProperty $model 'revision' $modelContext) -ne $aiPinned.modelRevision) { throw 'The local AI model revision is not the pinned pairing.' }
    if ([string](Get-RequiredJsonProperty $model 'license' $modelContext) -ne $aiPinned.modelLicense) { throw 'The local AI model license is not the pinned pairing.' }
    if ([string]::IsNullOrWhiteSpace([string](Get-RequiredJsonProperty $model 'id' $modelContext))) { throw 'The local AI model identity is missing.' }
    if ((Get-RequiredJsonProperty $model 'cpuOnly' $modelContext) -ne $true -or
        (Get-RequiredJsonProperty $model 'offlineOnly' $modelContext) -ne $true) {
        throw 'The local AI model must be declared CPU-only and offline.'
    }
    Assert-AiHttpsUrl ([string](Get-RequiredJsonProperty $model 'sourceUrl' $modelContext)) 'model sourceUrl'
    $modelLicenseRelative = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $model 'licensePath' $modelContext)) 'model licensePath'
    if ($modelLicenseRelative -ne $aiPinned.modelLicenseRelative) { throw "The local AI model license path is not the pinned file: $modelLicenseRelative" }
    $modelLicenseBytes = [int64](Get-RequiredJsonProperty $model 'licenseFileBytes' $modelContext)
    $modelLicenseSha256 = ([string](Get-RequiredJsonProperty $model 'licenseFileSha256' $modelContext)).ToLowerInvariant()
    if ($modelLicenseBytes -ne $aiPinned.modelLicenseBytes -or $modelLicenseSha256 -ne $aiPinned.modelLicenseSha256) {
        throw 'The local AI model license text is not the pinned identity.'
    }
    $weight = Get-RequiredJsonProperty $model 'weight' $modelContext
    $weightContext = 'aiManifest.model.weight'
    $weightFileName = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $weight 'fileName' $weightContext)) 'model weight fileName'
    if ((Split-Path -Leaf $weightFileName) -cne $weightFileName) { throw 'The local AI model weight fileName must be a single path segment.' }
    $weightBytes = [int64](Get-RequiredJsonProperty $weight 'bytes' $weightContext)
    $weightSha256 = ([string](Get-RequiredJsonProperty $weight 'sha256' $weightContext)).ToLowerInvariant()
    $weightLfsSha256 = ([string](Get-RequiredJsonProperty $weight 'lfsSha256' $weightContext)).ToLowerInvariant()
    $weightCommit = ([string](Get-RequiredJsonProperty $weight 'fileCommit' $weightContext)).ToLowerInvariant()
    $weightUrl = [string](Get-RequiredJsonProperty $weight 'url' $weightContext)
    Assert-AiHttpsUrl $weightUrl 'model weight url'
    if ($weightBytes -le 0 -or $weightSha256 -notmatch '^[0-9a-f]{64}$' -or $weightLfsSha256 -ne $weightSha256) { throw 'The local AI model weight digest record is malformed.' }
    if ($weightCommit -notmatch '^[0-9a-f]{40}$' -or $weightUrl -ne [string](Get-RequiredJsonProperty $model 'sourceUrl' $modelContext)) { throw 'The local AI model weight provenance record is malformed.' }
    if ((Get-RequiredJsonProperty $weight 'lfs' $weightContext) -ne $true -or
        (Get-RequiredJsonProperty $weight 'cpuOnly' $weightContext) -ne $true -or
        (Get-RequiredJsonProperty $weight 'offlineOnly' $weightContext) -ne $true) {
        throw 'The local AI model weight flags are not CPU-only/offline.'
    }
    if (-not $Fixture) {
        if ($weightFileName -ne $aiPinned.modelFileName -or $weightBytes -ne $aiPinned.modelBytes -or $weightSha256 -ne $aiPinned.modelSha256) {
            throw 'The local AI model weight is not the pinned coordinator-approved artifact.'
        }
        if ($weightCommit -ne $aiPinned.modelFileCommit) { throw 'The local AI model weight commit is not the pinned value.' }
    }

    $runtime = Get-RequiredJsonProperty $manifest 'runtime' $root
    $runtimeContext = 'aiManifest.runtime'
    if ([string](Get-RequiredJsonProperty $runtime 'repository' $runtimeContext) -ne $aiPinned.runtimeRepository) { throw 'The local AI runtime repository is not the pinned pairing.' }
    if ([string](Get-RequiredJsonProperty $runtime 'release' $runtimeContext) -ne $aiPinned.runtimeRelease) { throw 'The local AI runtime release is not the pinned pairing.' }
    if ([string](Get-RequiredJsonProperty $runtime 'revision' $runtimeContext) -ne $aiPinned.runtimeRevision) { throw 'The local AI runtime commit is not the pinned pairing.' }
    if ([string](Get-RequiredJsonProperty $runtime 'license' $runtimeContext) -ne $aiPinned.runtimeLicense) { throw 'The local AI runtime license is not the pinned pairing.' }
    if ([string]::IsNullOrWhiteSpace([string](Get-RequiredJsonProperty $runtime 'id' $runtimeContext))) { throw 'The local AI runtime identity is missing.' }
    if ((Get-RequiredJsonProperty $runtime 'cpuOnly' $runtimeContext) -ne $true -or
        (Get-RequiredJsonProperty $runtime 'offlineOnly' $runtimeContext) -ne $true) {
        throw 'The local AI runtime must be declared CPU-only and offline.'
    }
    Assert-AiHttpsUrl ([string](Get-RequiredJsonProperty $runtime 'sourceUrl' $runtimeContext)) 'runtime sourceUrl'
    $runtimeLicenseRelative = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $runtime 'licensePath' $runtimeContext)) 'runtime licensePath'
    if ($runtimeLicenseRelative -ne $aiPinned.runtimeLicenseRelative) { throw "The local AI runtime license path is not the pinned file: $runtimeLicenseRelative" }
    $runtimeLicenseBytes = [int64](Get-RequiredJsonProperty $runtime 'licenseFileBytes' $runtimeContext)
    $runtimeLicenseSha256 = ([string](Get-RequiredJsonProperty $runtime 'licenseFileSha256' $runtimeContext)).ToLowerInvariant()
    if ($runtimeLicenseBytes -ne $aiPinned.runtimeLicenseBytes -or $runtimeLicenseSha256 -ne $aiPinned.runtimeLicenseSha256) {
        throw 'The local AI runtime license text is not the pinned identity.'
    }
    $asset = Get-RequiredJsonProperty $runtime 'asset' $runtimeContext
    $assetContext = 'aiManifest.runtime.asset'
    $assetFileName = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $asset 'fileName' $assetContext)) 'runtime asset fileName'
    if ((Split-Path -Leaf $assetFileName) -cne $assetFileName) { throw 'The local AI runtime asset fileName must be a single path segment.' }
    $assetBytes = [int64](Get-RequiredJsonProperty $asset 'bytes' $assetContext)
    $assetSha256 = ([string](Get-RequiredJsonProperty $asset 'sha256' $assetContext)).ToLowerInvariant()
    $assetUrl = [string](Get-RequiredJsonProperty $asset 'url' $assetContext)
    Assert-AiHttpsUrl $assetUrl 'runtime asset url'
    if ($assetBytes -le 0 -or $assetSha256 -notmatch '^[0-9a-f]{64}$' -or $assetUrl -ne [string](Get-RequiredJsonProperty $runtime 'sourceUrl' $runtimeContext)) {
        throw 'The local AI runtime asset digest record is malformed.'
    }
    if ((Get-RequiredJsonProperty $asset 'cpuOnly' $assetContext) -ne $true -or
        (Get-RequiredJsonProperty $asset 'offlineOnly' $assetContext) -ne $true) {
        throw 'The local AI runtime asset flags are not CPU-only/offline.'
    }
    if (-not $Fixture -and ($assetFileName -ne $aiPinned.runtimeAssetFileName -or $assetBytes -ne $aiPinned.runtimeAssetBytes -or $assetSha256 -ne $aiPinned.runtimeAssetSha256)) {
        throw 'The local AI runtime archive is not the pinned coordinator-approved artifact.'
    }

    $archive = Get-RequiredJsonProperty $runtime 'archive' $runtimeContext
    $archiveContext = 'aiManifest.runtime.archive'
    if ([string](Get-RequiredJsonProperty $archive 'format' $archiveContext) -ne 'zip') { throw 'The local AI runtime archive must be a ZIP.' }
    $policy = Get-RequiredJsonProperty $archive 'entryPolicy' $archiveContext
    $policyContext = 'aiManifest.runtime.archive.entryPolicy'
    if ([string](Get-RequiredJsonProperty $policy 'mode' $policyContext) -ne 'exact-allowlist') { throw 'The local AI runtime archive must use the exact-allowlist entry policy.' }
    if ((Get-RequiredJsonProperty $policy 'directoryEntriesAllowed' $policyContext) -ne $false) { throw 'The local AI runtime archive must not contain directory entries.' }
    $allowedEntries = @(Get-AiStringArray (Get-RequiredJsonProperty $policy 'allowedExactEntries' $policyContext) 'entryPolicy.allowedExactEntries')
    $requiredEntries = @(Get-AiStringArray (Get-RequiredJsonProperty $policy 'requiredEntries' $policyContext) 'entryPolicy.requiredEntries')
    $entryPatterns = @(Get-AiStringArray (Get-RequiredJsonProperty $policy 'allowedEntryPatterns' $policyContext) 'entryPolicy.allowedEntryPatterns')
    if ($allowedEntries.Count -lt 1 -or $requiredEntries.Count -lt 1 -or $entryPatterns.Count -ne 1 -or $entryPatterns[0] -ne '^$') {
        throw 'The local AI runtime entry policy is not the reviewed exact allowlist.'
    }
    $closure = @()
    foreach ($entry in $allowedEntries) {
        $safe = Assert-AiSafeRelativePath ([string]$entry) 'runtime closure entry'
        if ($closure -ccontains $safe) { throw "The local AI runtime closure allowlist contains a duplicate entry: $safe" }
        $closure += $safe
    }
    foreach ($entry in $requiredEntries) {
        $safe = Assert-AiSafeRelativePath ([string]$entry) 'required runtime closure entry'
        if ($closure -cnotcontains $safe) { throw "A required local AI runtime closure entry is not in the allowlist: $safe" }
    }
    if ($closure -cnotcontains $aiServerEntry) { throw "The local AI runtime closure must contain $aiServerEntry." }
    $entryCount = [int](Get-RequiredJsonProperty $policy 'entryCount' $policyContext)
    $entryNamesSha256 = ([string](Get-RequiredJsonProperty $policy 'entryNamesSha256' $policyContext)).ToLowerInvariant()
    if ($entryCount -ne $closure.Count) { throw 'The local AI runtime entry count does not match the reviewed closure allowlist.' }
    if ($entryNamesSha256 -notmatch '^[0-9a-f]{64}$') { throw 'The local AI runtime entry-name digest is malformed.' }
    if (-not $Fixture -and ($entryCount -ne $aiPinned.runtimeEntryCount -or $entryNamesSha256 -ne $aiPinned.runtimeEntryNamesSha256)) {
        throw 'The local AI runtime closure is not the pinned reviewed entry layout.'
    }

    $licenseNotice = Get-RequiredJsonProperty $manifest 'licenseNotice' $root
    $noticeContext = 'aiManifest.licenseNotice'
    if ([string](Get-RequiredJsonProperty $licenseNotice 'dependencyNoticeStatus' $noticeContext) -ne $aiPinned.dependencyNoticeStatus) {
        throw 'The local AI dependency-notice status must remain explicitly incomplete.'
    }
    if ([string](Get-RequiredJsonProperty $licenseNotice 'sbomStatus' $noticeContext) -ne $aiPinned.sbomStatus) {
        throw 'The local AI SBOM status must remain not-generated.'
    }
    $noticeRelative = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $licenseNotice 'path' $noticeContext)) 'third-party notice path'
    if ($noticeRelative -ne $aiPinned.noticeRelative) { throw "The local AI third-party notice path is not the pinned file: $noticeRelative" }
    $noticeBytes = [int64](Get-RequiredJsonProperty $licenseNotice 'bytes' $noticeContext)
    $noticeSha256 = ([string](Get-RequiredJsonProperty $licenseNotice 'sha256' $noticeContext)).ToLowerInvariant()
    if ($noticeBytes -ne $aiPinned.noticeBytes -or $noticeSha256 -ne $aiPinned.noticeSha256) { throw 'The local AI third-party notice text is not the pinned identity.' }

    $staging = Get-RequiredJsonProperty $manifest 'staging' $root
    $stagingContext = 'aiManifest.staging'
    $modelDirectoryRelative = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $staging 'modelDirectory' $stagingContext)) 'staging modelDirectory' -AllowDirectory
    $runtimeDirectoryRelative = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $staging 'runtimeDirectory' $stagingContext)) 'staging runtimeDirectory' -AllowDirectory
    $licenseDirectoryRelative = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $staging 'licenseDirectory' $stagingContext)) 'staging licenseDirectory' -AllowDirectory
    $stagingNoticeRelative = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $staging 'noticeFile' $stagingContext)) 'staging noticeFile'
    $receiptRelative = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $staging 'receiptFile' $stagingContext)) 'staging receiptFile'
    if ($modelDirectoryRelative -ne $aiPinned.modelDirectory -or $runtimeDirectoryRelative -ne $aiPinned.runtimeDirectory -or
        $licenseDirectoryRelative -ne $aiPinned.licenseDirectory -or $receiptRelative -ne $aiPinned.receiptFile) {
        throw 'The local AI staging layout is not the reviewed one.'
    }
    if ($stagingNoticeRelative -ne $noticeRelative) { throw 'The local AI staged notice file name does not match the pinned notice identity.' }
    if ([string](Get-RequiredJsonProperty $staging 'deletePolicy' $stagingContext) -ne $aiPinned.stagingDeletePolicy) {
        throw 'The local AI staging policy must prohibit deleting caller paths.'
    }
    if ($modelDirectoryRelative -ceq $runtimeDirectoryRelative -or $modelDirectoryRelative -ceq $licenseDirectoryRelative -or
        $runtimeDirectoryRelative -ceq $licenseDirectoryRelative -or $receiptRelative -ceq $noticeRelative) {
        throw 'The local AI staging layout reuses the same name for different roles.'
    }

    $fetch = Get-RequiredJsonProperty $manifest 'fetchPolicy' $root
    $fetchContext = 'aiManifest.fetchPolicy'
    if ([string](Get-RequiredJsonProperty $fetch 'defaultMode' $fetchContext) -ne 'plan' -or
        (Get-RequiredJsonProperty $fetch 'networkImplemented' $fetchContext) -ne $false -or
        (Get-RequiredJsonProperty $fetch 'offlineAtRuntime' $fetchContext) -ne $true) {
        throw 'The pinned local AI manifest must keep network fetching disabled and the runtime offline.'
    }
    $schemes = @(Get-AiStringArray (Get-RequiredJsonProperty $fetch 'allowedSchemes' $fetchContext) 'fetchPolicy.allowedSchemes')
    if ($schemes.Count -ne 1 -or $schemes[0] -ne 'https') { throw 'Only HTTPS may appear in the local AI fetch policy.' }
    $verification = Get-RequiredJsonProperty $manifest 'verification' $root
    $verificationContext = 'aiManifest.verification'
    if ([string](Get-RequiredJsonProperty $verification 'upstreamMetadata' $verificationContext) -ne 'verified-by-coordinator' -or
        [string](Get-RequiredJsonProperty $verification 'conversionReproducibility' $verificationContext) -ne $aiPinned.conversionReproducibility -or
        [string](Get-RequiredJsonProperty $verification 'windowsExecution' $verificationContext) -ne 'not-performed') {
        throw 'The pinned local AI manifest must keep upstream metadata, conversion reproducibility, and Windows execution statuses distinct.'
    }
    $artifactDigests = Get-RequiredJsonProperty $verification 'artifactDigests' $verificationContext
    if ([string](Get-RequiredJsonProperty $artifactDigests 'model' 'aiManifest.verification.artifactDigests') -ne 'local-weight-verified' -or
        [string](Get-RequiredJsonProperty $artifactDigests 'runtime' 'aiManifest.verification.artifactDigests') -ne 'local-archive-verified') {
        throw 'The pinned local AI manifest must record the local artifact digest status for both inputs.'
    }
    $localDownload = Get-RequiredJsonProperty $verification 'localDownload' $verificationContext
    if ([string](Get-RequiredJsonProperty $localDownload 'model' 'aiManifest.verification.localDownload') -ne 'performed-and-verified' -or
        [string](Get-RequiredJsonProperty $localDownload 'runtime' 'aiManifest.verification.localDownload') -ne 'performed-and-verified') {
        throw 'The pinned local AI manifest must record the local download status for both inputs.'
    }

    # The license and notice files that ship beside the manifest are the exact
    # bytes the package will contain; verify them here, not by name.
    $manifestRoot = Split-Path -Parent $Path
    # The shipped Rust broker is part of the reviewed AI bundle, so its bytes
    # are pinned here. Without this block an arbitrary non-Mozc x64 executable
    # would satisfy the broker check and be recorded into a release candidate.
    $brokerIdentity = $null
    $brokerNode = $manifest.PSObject.Properties['broker']
    if ($null -eq $brokerNode -or $null -eq $brokerNode.Value) {
        throw 'The pinned local AI manifest must declare the broker identity; an unpinned broker may not enter a release candidate.'
    }
    $brokerContext = 'manifest.broker'
    $brokerFileName = [string](Get-RequiredJsonProperty $brokerNode.Value 'fileName' $brokerContext)
    if ($brokerFileName -cne $aiPinned.brokerFileName) {
        throw ("The pinned broker file name must be {0}." -f $aiPinned.brokerFileName)
    }
    if ([string](Get-RequiredJsonProperty $brokerNode.Value 'architecture' $brokerContext) -ne $aiPinned.brokerArchitecture -or
        [string](Get-RequiredJsonProperty $brokerNode.Value 'kind' $brokerContext) -ne $aiPinned.brokerKind) {
        throw 'The pinned broker must be an x64 executable.'
    }
    $brokerBytes = [int64](Get-RequiredJsonProperty $brokerNode.Value 'bytes' $brokerContext)
    $brokerSha256 = ([string](Get-RequiredJsonProperty $brokerNode.Value 'sha256' $brokerContext)).ToLowerInvariant()
    $brokerMagic = ([string](Get-RequiredJsonProperty $brokerNode.Value 'optionalHeaderMagic' $brokerContext)).ToUpperInvariant()
    if ($brokerBytes -lt 1 -or $brokerSha256 -notmatch '^[0-9a-f]{64}$' -or $brokerMagic -notmatch '^0x[0-9A-F]{4}$') {
        throw 'The pinned broker identity is malformed.'
    }
    # The production digest is pinned in the builder itself. Fixture mode binds
    # the manifest to synthetic bytes so the offline test stays hermetic.
    if (-not $Fixture) {
        if ($brokerBytes -ne [int64]$aiPinned.brokerBytes -or $brokerSha256 -ne [string]$aiPinned.brokerSha256) {
            throw 'The pinned local AI manifest broker digest does not match the builder pin; rebuild the broker and update both together.'
        }
        if ($brokerMagic -ne [string]$aiPinned.brokerOptionalMagic -or
            [string](Get-RequiredJsonProperty $brokerNode.Value 'machine' $brokerContext) -ne [string]$aiPinned.brokerMachine) {
            throw 'The pinned local AI manifest broker PE identity does not match the builder pin.'
        }
    }
    $brokerIdentity = [pscustomobject]@{
        FileName = $brokerFileName
        Bytes = $brokerBytes
        Sha256 = $brokerSha256
        Machine = [string](Get-RequiredJsonProperty $brokerNode.Value 'machine' $brokerContext)
        OptionalMagicHex = $brokerMagic
    }

    foreach ($identity in @(
        [pscustomobject]@{ Relative = $modelLicenseRelative; Bytes = $modelLicenseBytes; Sha256 = $modelLicenseSha256; Label = 'model license' },
        [pscustomobject]@{ Relative = $runtimeLicenseRelative; Bytes = $runtimeLicenseBytes; Sha256 = $runtimeLicenseSha256; Label = 'runtime license' },
        [pscustomobject]@{ Relative = $noticeRelative; Bytes = $noticeBytes; Sha256 = $noticeSha256; Label = 'third-party notice' }
    )) {
        $full = [IO.Path]::GetFullPath((Join-Path $manifestRoot $identity.Relative))
        if (-not (Test-PathWithin $full $manifestRoot)) { throw "The pinned local AI $($identity.Label) escapes the manifest directory." }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "The pinned local AI $($identity.Label) is missing: $($identity.Relative)" }
        Assert-NoReparsePath -Path $full
        $item = Get-Item -LiteralPath $full -Force
        if ([int64]$item.Length -ne [int64]$identity.Bytes) { throw "The pinned local AI $($identity.Label) has the wrong size: $($identity.Relative)" }
        if ((Get-Sha256 -Path $full) -ine [string]$identity.Sha256) { throw "The pinned local AI $($identity.Label) has the wrong SHA-256: $($identity.Relative)" }
    }

    return [pscustomobject]@{
        Path = $Path
        Sha256 = $manifestSha256
        Schema = $aiPinned.schema
        Status = $status
        ModelId = [string](Get-RequiredJsonProperty $model 'id' $modelContext)
        ModelRepository = $aiPinned.modelRepository
        ModelRevision = $aiPinned.modelRevision
        ModelLicense = $aiPinned.modelLicense
        ModelFileName = $weightFileName
        ModelBytes = $weightBytes
        ModelSha256 = $weightSha256
        ModelLicenseRelative = $modelLicenseRelative
        ModelLicenseBytes = $modelLicenseBytes
        ModelLicenseSha256 = $modelLicenseSha256
        RuntimeId = [string](Get-RequiredJsonProperty $runtime 'id' $runtimeContext)
        RuntimeRepository = $aiPinned.runtimeRepository
        RuntimeRelease = $aiPinned.runtimeRelease
        RuntimeRevision = $aiPinned.runtimeRevision
        RuntimeLicense = $aiPinned.runtimeLicense
        RuntimeArchiveBytes = $assetBytes
        RuntimeArchiveSha256 = $assetSha256
        RuntimeLicenseRelative = $runtimeLicenseRelative
        RuntimeLicenseBytes = $runtimeLicenseBytes
        RuntimeLicenseSha256 = $runtimeLicenseSha256
        RuntimeEntryCount = $entryCount
        RuntimeEntryNamesSha256 = $entryNamesSha256
        RuntimeClosure = @($closure)
        NoticeRelative = $noticeRelative
        NoticeBytes = $noticeBytes
        NoticeSha256 = $noticeSha256
        ModelDirectoryRelative = $modelDirectoryRelative
        RuntimeDirectoryRelative = $runtimeDirectoryRelative
        LicenseDirectoryRelative = $licenseDirectoryRelative
        ReceiptRelative = $receiptRelative
        BrokerIdentity = $brokerIdentity
    }
}

# Enumerate the staged local-AI tree and require it to be exactly the reviewed
# file/directory set.  Unknown, missing, extra, reparse, and traversal entries
# all fail closed.
function Assert-AiStagedLayout([string]$Root, [string[]]$ExpectedFiles, [string[]]$ExpectedDirectories) {
    $rootKey = (Get-FullPath $Root).TrimEnd([char[]]@('\', '/'))
    $fileSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $ExpectedFiles) { [void]$fileSet.Add([string]$entry) }
    $directorySet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $ExpectedDirectories) { [void]$directorySet.Add([string]$entry) }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($rootKey)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "A reparse point is not allowed in the staged local AI tree: $($child.Name)" }
            $full = [IO.Path]::GetFullPath($child.FullName)
            if (-not (Test-PathWithin $full $rootKey)) { throw "A staged local AI entry escaped the staged root: $($child.Name)" }
            $relative = $full.Substring($rootKey.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
            if (-not $seen.Add($relative)) { throw "A staged local AI entry is reachable more than once: $relative" }
            if ($child.PSIsContainer) {
                if (-not $directorySet.Contains($relative)) { throw "Unknown staged local AI directory: $relative" }
                $queue.Enqueue($full)
            }
            elseif (-not $fileSet.Contains($relative)) {
                throw "Unknown staged local AI entry: $relative"
            }
        }
    }
    foreach ($entry in $ExpectedFiles) { if (-not $seen.Contains([string]$entry)) { throw "Staged local AI file is missing: $entry" } }
}

function Assert-AiStagedTree($ManifestInfo, [string]$Root, [switch]$Fixture, [switch]$PayloadOnly) {
    $rootKey = Get-FullPath $Root
    $modelRelative = $ManifestInfo.ModelDirectoryRelative + '/' + $ManifestInfo.ModelFileName
    $modelLicenseStaged = $ManifestInfo.LicenseDirectoryRelative + '/' + (Split-Path -Leaf $ManifestInfo.ModelLicenseRelative)
    $runtimeLicenseStaged = $ManifestInfo.LicenseDirectoryRelative + '/' + (Split-Path -Leaf $ManifestInfo.RuntimeLicenseRelative)
    $expectedFiles = @($modelRelative, $modelLicenseStaged, $runtimeLicenseStaged, $ManifestInfo.NoticeRelative)
    $expectedDirectories = @($ManifestInfo.ModelDirectoryRelative, $ManifestInfo.RuntimeDirectoryRelative, $ManifestInfo.LicenseDirectoryRelative)
    # The runtime closure is staged as a flat set of files under the runtime
    # directory. Declare every expected entry up front so an undeclared or
    # renamed file is rejected instead of silently tolerated.
    foreach ($closureEntry in @($ManifestInfo.RuntimeClosure)) {
        $expectedFiles += $ManifestInfo.RuntimeDirectoryRelative + '/' + [string]$closureEntry
    }
    $sanitizedRelative = $null
    $sanitizedSha256 = $null
    $receiptFull = $null
    if (-not $PayloadOnly) {
        # The receipt (and an optional already-sanitized package manifest) are
        # staging inputs, not payload, so they live beside the payload files.
        $expectedFiles += [string]$ManifestInfo.ReceiptRelative
        $receiptFull = [IO.Path]::GetFullPath((Join-Path $rootKey $ManifestInfo.ReceiptRelative))
        $sanitizedPath = Join-Path $rootKey $aiSanitizedManifestFileName
        if (Test-Path -LiteralPath $sanitizedPath) {
            $sanitizedRelative = $aiSanitizedManifestFileName
            $expectedFiles += $sanitizedRelative
        }
    }
    Assert-AiStagedLayout -Root $rootKey -ExpectedFiles $expectedFiles -ExpectedDirectories $expectedDirectories
    $runtimeRoot = Join-Path $rootKey $ManifestInfo.RuntimeDirectoryRelative
    if (@(Get-ChildItem -LiteralPath $runtimeRoot -Force | Where-Object { $_.PSIsContainer }).Count -gt 0) {
        throw 'The staged local AI runtime closure must be a flat directory.'
    }

    $modelPath = [IO.Path]::GetFullPath((Join-Path $rootKey $modelRelative))
    $modelRecord = Get-AiFileRecord -Path $modelPath -Relative $modelRelative -Kind 'ModelWeight' -Machine 0
    if ($modelRecord.Bytes -ne [int64]$ManifestInfo.ModelBytes -or $modelRecord.Sha256 -ine [string]$ManifestInfo.ModelSha256) {
        throw "The staged local AI model weight does not match the pinned manifest: $modelRelative"
    }

    $closureNames = @()
    $runtimeRecords = @()
    foreach ($entry in @($ManifestInfo.RuntimeClosure)) {
        $relative = $ManifestInfo.RuntimeDirectoryRelative + '/' + $entry
        $full = [IO.Path]::GetFullPath((Join-Path $rootKey $relative))
        if (-not (Test-PathWithin $full $rootKey)) { throw "A staged local AI runtime entry escapes the staged root: $entry" }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "The staged local AI runtime closure entry is missing: $entry" }
        $kind = 'RuntimeFile'
        $machine = 0
        if ($entry.EndsWith('.dll', [StringComparison]::OrdinalIgnoreCase)) { $kind = 'RuntimeDll'; $machine = 0x8664; [void](Assert-Pe -Path $full -Machine 0x8664 -Type 'Dll' -Exports @()) }
        elseif ($entry.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $kind = 'RuntimeExe'; $machine = 0x8664; [void](Assert-Pe -Path $full -Machine 0x8664 -Type 'Exe' -Exports @()) }
        $runtimeRecords += Get-AiFileRecord -Path $full -Relative $relative -Kind $kind -Machine $machine
        $closureNames += $entry
    }
    [string[]]$sortedClosure = @($closureNames)
    [Array]::Sort($sortedClosure, [StringComparer]::Ordinal)
    $actualEntryNamesSha256 = Get-TextSha256 ((($sortedClosure -join "`n") + "`n"))
    if ($actualEntryNamesSha256 -ne [string]$ManifestInfo.RuntimeEntryNamesSha256) {
        throw ("The staged local AI runtime closure name digest does not match the pinned layout digest: expected {0}, found {1}." -f $ManifestInfo.RuntimeEntryNamesSha256, $actualEntryNamesSha256)
    }
    $onDiskNames = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $runtimeRoot -Force -File)) { $onDiskNames += $item.Name }
    [string[]]$sortedOnDisk = @($onDiskNames)
    [Array]::Sort($sortedOnDisk, [StringComparer]::Ordinal)
    if ((Get-TextSha256 ((($sortedOnDisk -join "`n") + "`n"))) -ne [string]$ManifestInfo.RuntimeEntryNamesSha256) {
        throw 'The staged local AI runtime directory contents do not match the pinned closure name digest.'
    }

    $licenses = @()
    foreach ($identity in @(
        [pscustomobject]@{ Staged = $modelLicenseStaged; Bytes = $ManifestInfo.ModelLicenseBytes; Sha256 = $ManifestInfo.ModelLicenseSha256; Label = 'model license' },
        [pscustomobject]@{ Staged = $runtimeLicenseStaged; Bytes = $ManifestInfo.RuntimeLicenseBytes; Sha256 = $ManifestInfo.RuntimeLicenseSha256; Label = 'runtime license' }
    )) {
        $full = [IO.Path]::GetFullPath((Join-Path $rootKey $identity.Staged))
        $record = Get-AiFileRecord -Path $full -Relative $identity.Staged -Kind 'License' -Machine 0
        if ($record.Bytes -ne [int64]$identity.Bytes -or $record.Sha256 -ine [string]$identity.Sha256) {
            throw "The staged local AI $($identity.Label) does not match the pinned manifest identity: $($identity.Staged)"
        }
        $licenses += $record
    }
    $noticePath = [IO.Path]::GetFullPath((Join-Path $rootKey $ManifestInfo.NoticeRelative))
    $noticeRecord = Get-AiFileRecord -Path $noticePath -Relative $ManifestInfo.NoticeRelative -Kind 'Notice' -Machine 0
    if ($noticeRecord.Bytes -ne [int64]$ManifestInfo.NoticeBytes -or $noticeRecord.Sha256 -ine [string]$ManifestInfo.NoticeSha256) {
        throw "The staged local AI third-party notice does not match the pinned manifest identity: $($ManifestInfo.NoticeRelative)"
    }
    if ($null -ne $sanitizedRelative) {
        $sanitizedPath = [IO.Path]::GetFullPath((Join-Path $rootKey $sanitizedRelative))
        $sanitizedSha256 = Get-Sha256 -Path $sanitizedPath
        try { $sanitizedObject = [IO.File]::ReadAllText($sanitizedPath, [Text.Encoding]::UTF8) | ConvertFrom-Json }
        catch { throw "The staged local AI sanitized package manifest is not valid UTF-8 JSON: $($_.Exception.Message)" }
        if ([int](Get-RequiredJsonProperty $sanitizedObject 'schemaVersion' 'aiSanitizedPackageManifest') -ne 1) { throw 'The staged local AI sanitized package manifest schemaVersion is not supported.' }
        if ([string](Get-RequiredJsonProperty $sanitizedObject 'status' 'aiSanitizedPackageManifest') -ne $aiSanitizedManifestStatus) { throw 'The staged local AI sanitized package manifest status is not the reviewed one.' }
        if ((Get-RequiredJsonProperty $sanitizedObject 'containsAbsolutePaths' 'aiSanitizedPackageManifest') -ne $false) { throw 'The staged local AI sanitized package manifest does not declare containsAbsolutePaths=false.' }
        if ((Get-RequiredJsonProperty $sanitizedObject 'networkUsed' 'aiSanitizedPackageManifest') -ne $false) { throw 'The staged local AI sanitized package manifest does not record networkUsed=false.' }
        if (([string](Get-RequiredJsonProperty $sanitizedObject 'rawReceiptSha256' 'aiSanitizedPackageManifest')).ToLowerInvariant() -ne (Get-Sha256 -Path $receiptFull)) {
            throw 'The staged local AI sanitized package manifest does not bind the staged receipt bytes.'
        }
        $sanitizedSource = Get-RequiredJsonProperty $sanitizedObject 'sourceManifest' 'aiSanitizedPackageManifest'
        if (([string](Get-RequiredJsonProperty $sanitizedSource 'sha256' 'aiSanitizedPackageManifest.sourceManifest')).ToLowerInvariant() -ne [string]$ManifestInfo.Sha256) {
            throw 'The staged local AI sanitized package manifest does not bind the pinned manifest bytes.'
        }
        $sanitizedModel = Get-RequiredJsonProperty $sanitizedObject 'model' 'aiSanitizedPackageManifest'
        if ([int64](Get-RequiredJsonProperty $sanitizedModel 'bytes' 'aiSanitizedPackageManifest.model') -ne $modelRecord.Bytes -or
            (([string](Get-RequiredJsonProperty $sanitizedModel 'sha256' 'aiSanitizedPackageManifest.model')).ToLowerInvariant() -ine $modelRecord.Sha256)) {
            throw 'The staged local AI sanitized package manifest model identity does not match the staged weight bytes.'
        }
        $sanitizedRuntime = Get-RequiredJsonProperty $sanitizedObject 'runtime' 'aiSanitizedPackageManifest'
        $sanitizedEntries = @(Get-JsonProperty $sanitizedRuntime 'entries')
        if ($sanitizedEntries.Count -ne $runtimeRecords.Count) { throw 'The staged local AI sanitized package manifest runtime entry count does not match the staged closure.' }
    }
    return [pscustomobject]@{
        Root = $rootKey
        ReceiptFullPath = $receiptFull
        ModelRecord = $modelRecord
        RuntimeRecords = @($runtimeRecords)
        RuntimeEntryNamesSha256 = $actualEntryNamesSha256
        LicenseRecords = @($licenses)
        NoticeRecord = $noticeRecord
        SanitizedRelative = $sanitizedRelative
        SanitizedSha256 = $sanitizedSha256
    }
}

function Assert-AiReceipt([string]$Path, $ManifestInfo, $Staged) {
    $receiptSha256 = Get-Sha256 -Path $Path
    try { $receipt = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { throw "The local AI staging receipt is not valid UTF-8 JSON: $($_.Exception.Message)" }
    $root = 'aiReceipt'
    if ([int](Get-RequiredJsonProperty $receipt 'schemaVersion' $root) -ne $aiPinned.receiptSchemaVersion) { throw 'The local AI staging receipt schemaVersion is not supported.' }
    $status = [string](Get-RequiredJsonProperty $receipt 'status' $root)
    if ($status -ne $aiPinned.receiptStatus) { throw "The local AI staging receipt status is not the reviewed staged-verified status: $status" }
    $receiptManifest = Get-RequiredJsonProperty $receipt 'manifest' $root
    if ([int](Get-RequiredJsonProperty $receiptManifest 'schemaVersion' 'aiReceipt.manifest') -ne $aiPinned.schemaVersion) { throw 'The local AI staging receipt names an unsupported manifest schemaVersion.' }
    if (([string](Get-RequiredJsonProperty $receiptManifest 'sha256' 'aiReceipt.manifest')).ToLowerInvariant() -ne [string]$ManifestInfo.Sha256) {
        throw 'The local AI staging receipt does not name the pinned AI manifest digest.'
    }
    $receiptModel = Get-RequiredJsonProperty $receipt 'model' $root
    if ([int64](Get-RequiredJsonProperty $receiptModel 'bytes' 'aiReceipt.model') -ne [int64]$ManifestInfo.ModelBytes) { throw 'The local AI staging receipt model size does not match the pinned manifest.' }
    if (([string](Get-RequiredJsonProperty $receiptModel 'sha256' 'aiReceipt.model')).ToLowerInvariant() -ne [string]$ManifestInfo.ModelSha256) { throw 'The local AI staging receipt model digest does not match the pinned manifest.' }
    if ([string](Get-RequiredJsonProperty $receiptModel 'license' 'aiReceipt.model') -ne [string]$ManifestInfo.ModelLicense) { throw 'The local AI staging receipt model license does not match the pinned manifest.' }
    $receiptModelLicense = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $receiptModel 'licensePath' 'aiReceipt.model')) 'staged model licensePath'
    $stagedLicensePaths = @($Staged.LicenseRecords | ForEach-Object { [string]$_.Path })
    if ($stagedLicensePaths -cnotcontains $receiptModelLicense) { throw 'The local AI staging receipt model license path does not match a staged license file.' }
    $receiptRuntime = Get-RequiredJsonProperty $receipt 'runtime' $root
    if ([int64](Get-RequiredJsonProperty $receiptRuntime 'bytes' 'aiReceipt.runtime') -ne [int64]$ManifestInfo.RuntimeArchiveBytes) { throw 'The local AI staging receipt runtime archive size does not match the pinned manifest.' }
    if (([string](Get-RequiredJsonProperty $receiptRuntime 'sha256' 'aiReceipt.runtime')).ToLowerInvariant() -ne [string]$ManifestInfo.RuntimeArchiveSha256) { throw 'The local AI staging receipt runtime archive digest does not match the pinned manifest.' }
    if ([string](Get-RequiredJsonProperty $receiptRuntime 'release' 'aiReceipt.runtime') -ne [string]$ManifestInfo.RuntimeRelease) { throw 'The local AI staging receipt runtime release does not match the pinned manifest.' }
    if ([string](Get-RequiredJsonProperty $receiptRuntime 'revision' 'aiReceipt.runtime') -ne [string]$ManifestInfo.RuntimeRevision) { throw 'The local AI staging receipt runtime commit does not match the pinned manifest.' }
    if ([string](Get-RequiredJsonProperty $receiptRuntime 'license' 'aiReceipt.runtime') -ne [string]$ManifestInfo.RuntimeLicense) { throw 'The local AI staging receipt runtime license does not match the pinned manifest.' }
    $receiptRuntimeLicense = Assert-AiSafeRelativePath ([string](Get-RequiredJsonProperty $receiptRuntime 'licensePath' 'aiReceipt.runtime')) 'staged runtime licensePath'
    if ($stagedLicensePaths -cnotcontains $receiptRuntimeLicense) { throw 'The local AI staging receipt runtime license path does not match a staged license file.' }
    $receiptEntries = @(Get-JsonProperty $receiptRuntime 'entries')
    $stagedRuntime = @($Staged.RuntimeRecords)
    if ($receiptEntries.Count -ne $stagedRuntime.Count) { throw 'The local AI staging receipt runtime entry count does not match the staged closure.' }
    foreach ($record in $stagedRuntime) {
        $matches = @($receiptEntries | Where-Object { (Assert-AiSafeRelativePath ([string](Get-JsonProperty $_ 'RelativePath')) 'staged runtime entry') -ceq [string]$record.Path })
        if ($matches.Count -ne 1) { throw "The local AI staging receipt has no unique record for the staged runtime entry: $($record.Path)" }
        if ([int64](Get-RequiredJsonProperty $matches[0] 'Bytes' 'aiReceipt.runtime.entries') -ne [int64]$record.Bytes) { throw "The local AI staging receipt records the wrong size for a staged runtime entry: $($record.Path)" }
        if (([string](Get-RequiredJsonProperty $matches[0] 'Sha256' 'aiReceipt.runtime.entries')).ToLowerInvariant() -ine [string]$record.Sha256) { throw "The local AI staging receipt records the wrong digest for a staged runtime entry: $($record.Path)" }
    }
    $receiptNotice = Get-RequiredJsonProperty $receipt 'notice' $root
    if ([int64](Get-RequiredJsonProperty $receiptNotice 'bytes' 'aiReceipt.notice') -ne [int64]$ManifestInfo.NoticeBytes) { throw 'The local AI staging receipt notice size does not match the pinned manifest.' }
    if (([string](Get-RequiredJsonProperty $receiptNotice 'sha256' 'aiReceipt.notice')).ToLowerInvariant() -ne [string]$ManifestInfo.NoticeSha256) { throw 'The local AI staging receipt notice digest does not match the pinned manifest.' }
    if ((Get-RequiredJsonProperty $receipt 'networkUsed' $root) -ne $false) { throw 'The local AI staging receipt does not record networkUsed=false.' }
    if ([string](Get-RequiredJsonProperty $receipt 'conversionReproducibility' $root) -ne $aiPinned.conversionReproducibility) { throw 'The local AI staging receipt must keep conversion reproducibility unverified.' }
    if ([string](Get-RequiredJsonProperty $receipt 'deletePolicy' $root) -ne $aiPinned.receiptDeletePolicy) { throw 'The local AI staging receipt does not record the no-caller-path-deletion policy.' }
    return [pscustomobject]@{ Path = $Path; Sha256 = $receiptSha256; Status = $status }
}

# The Rust KanaAI broker is a distinct x64 executable.  Reusing the Mozc
# broker, the installer helper, or a renamed llama-server binary is rejected.
function Assert-AiBroker([string]$Path, $RuntimeValidation, $Staged, $PinnedBrokerIdentity) {
    if ((Split-Path -Leaf $Path) -ine $aiBrokerFileName) { throw "The local AI broker must be named $aiBrokerFileName." }
    $image = Assert-Pe -Path $Path -Machine 0x8664 -Type 'Exe' -Exports @()
    $item = Get-Item -LiteralPath $Path -Force
    $sha256 = Get-Sha256 -Path $Path
    # A byte-for-byte copy of a Mozc payload is never the Rust broker. Check
    # that first so the message names the real mistake rather than reporting a
    # digest mismatch against the pinned bundle.
    foreach ($record in @($RuntimeValidation.Records)) {
        if ([string]$record.Sha256 -ieq $sha256) { throw "The local AI broker is a byte-for-byte copy of the Mozc payload '$($record.Name)'; the Rust KanaAI broker is required." }
    }
    if ([string]$RuntimeValidation.HelperRecord.Sha256 -ieq $sha256) { throw 'The local AI broker is a byte-for-byte copy of the Mozc installer helper.' }
    if ($null -ne $Staged) {
        foreach ($record in @($Staged.RuntimeRecords)) {
            if ([string]$record.Sha256 -ieq $sha256) { throw "The local AI broker is a byte-for-byte copy of the staged local AI runtime entry '$($record.Path)'." }
        }
    }
    # The broker is part of the shipped AI bundle, so its bytes are pinned by
    # the reviewed manifest rather than merely recorded. Recording an
    # arbitrary non-Mozc executable would let an unreviewed binary into a
    # release candidate.
    if ($null -ne $PinnedBrokerIdentity) {
        if ([int64]$item.Length -ne [int64]$PinnedBrokerIdentity.Bytes) {
            throw ("The local AI broker size does not match the pinned manifest: expected {0}, found {1}." -f $PinnedBrokerIdentity.Bytes, $item.Length)
        }
        if ($sha256 -ine [string]$PinnedBrokerIdentity.Sha256) {
            throw "The local AI broker SHA-256 does not match the pinned manifest."
        }
        if ([string]$image.OptionalMagicHex -ine [string]$PinnedBrokerIdentity.OptionalMagicHex) {
            throw "The local AI broker optional-header magic does not match the pinned manifest."
        }
    }
    return [pscustomobject]@{
        Path = $Path
        Name = $aiBrokerFileName
        Bytes = [int64]$item.Length
        Sha256 = $sha256
        Machine = ('0x{0:x4}' -f 0x8664)
        Type = 'Exe'
        OptionalMagicHex = [string]$image.OptionalMagicHex
    }
}

# Install-relative payload plan.  Every record names an expected relative MSI
# destination, the reviewed bytes, and the generated Component/Directory ids.
function New-AiPayloadPlan($ManifestInfo, $Staged, $Broker) {
    $plan = New-Object 'System.Collections.Generic.List[object]'
    [void]$plan.Add([pscustomobject]@{
        InstallRelative = $aiBrokerFileName
        StagedRelative = $null
        DirectoryId = 'INSTALLFOLDER'
        Kind = 'Broker'
        Machine = [string]$Broker.Machine
        Bytes = [int64]$Broker.Bytes
        Sha256 = [string]$Broker.Sha256
    })
    [void]$plan.Add([pscustomobject]@{
        InstallRelative = $aiPayloadRootDirectory + '/' + [string]$Staged.ModelRecord.Path
        StagedRelative = [string]$Staged.ModelRecord.Path
        DirectoryId = $aiDirectoryIds.model
        Kind = 'ModelWeight'
        Machine = [string]$Staged.ModelRecord.Machine
        Bytes = [int64]$Staged.ModelRecord.Bytes
        Sha256 = [string]$Staged.ModelRecord.Sha256
    })
    foreach ($record in @($Staged.RuntimeRecords)) {
        [void]$plan.Add([pscustomobject]@{
            InstallRelative = $aiPayloadRootDirectory + '/' + [string]$record.Path
            StagedRelative = [string]$record.Path
            DirectoryId = $aiDirectoryIds.runtime
            Kind = [string]$record.Kind
            Machine = [string]$record.Machine
            Bytes = [int64]$record.Bytes
            Sha256 = [string]$record.Sha256
        })
    }
    foreach ($record in @($Staged.LicenseRecords)) {
        [void]$plan.Add([pscustomobject]@{
            InstallRelative = $aiPayloadRootDirectory + '/' + [string]$record.Path
            StagedRelative = [string]$record.Path
            DirectoryId = $aiDirectoryIds.license
            Kind = 'License'
            Machine = [string]$record.Machine
            Bytes = [int64]$record.Bytes
            Sha256 = [string]$record.Sha256
        })
    }
    [void]$plan.Add([pscustomobject]@{
        InstallRelative = $aiPayloadRootDirectory + '/' + [string]$Staged.NoticeRecord.Path
        StagedRelative = [string]$Staged.NoticeRecord.Path
        DirectoryId = $aiDirectoryIds.root
        Kind = 'Notice'
        Machine = [string]$Staged.NoticeRecord.Machine
        Bytes = [int64]$Staged.NoticeRecord.Bytes
        Sha256 = [string]$Staged.NoticeRecord.Sha256
    })
    $installPaths = @($plan | ForEach-Object { [string]$_.InstallRelative })
    $seen = @()
    foreach ($path in $installPaths) {
        $safe = Assert-AiSafeRelativePath $path 'AI install-relative payload path'
        if ($seen -ccontains $safe) { throw "The local AI payload plan contains a duplicate destination: $safe" }
        $seen += $safe
    }
    if ($installPaths -ccontains $aiPayloadRootDirectory + '/' + $ManifestInfo.ReceiptRelative) { throw 'The raw local AI staging receipt must never become an MSI payload file.' }
    if ($installPaths -ccontains $aiPayloadRootDirectory + '/' + $aiSanitizedManifestFileName) { throw 'The sanitized local AI package manifest must never become an MSI payload file.' }
    return @($plan.ToArray())
}

# The published/local record of the reviewed AI bytes.  It contains only
# relative paths, digests, and non-claims; no source path, username, repository
# path, or raw staging receipt content is ever copied into it.
function New-AiSanitizedPackageManifest($ManifestInfo, $Staged, $ReceiptInfo, $Broker, $Payload) {
    $manifest = [ordered]@{
        schemaVersion = 1
        status = $aiSanitizedManifestStatus
        included = $true
        localAiIncluded = $true
        aiOperationVerified = $false
        aiStartupTested = $false
        installedInputVerified = $false
        verified = $false
        networkUsed = $false
        containsAbsolutePaths = $false
        conversionReproducibility = $aiPinned.conversionReproducibility
        windowsExecution = 'not-performed'
        dependencyNoticeStatus = $aiPinned.dependencyNoticeStatus
        sbomStatus = $aiPinned.sbomStatus
        sourceManifest = [ordered]@{
            fileName = (Split-Path -Leaf $ManifestInfo.Path)
            sha256 = [string]$ManifestInfo.Sha256
            schema = [string]$ManifestInfo.Schema
            schemaVersion = $aiPinned.schemaVersion
            status = [string]$ManifestInfo.Status
        }
        rawStagingReceiptSha256 = [string]$ReceiptInfo.Sha256
        broker = [ordered]@{
            installPath = $aiBrokerFileName
            name = $aiBrokerFileName
            bytes = [int64]$Broker.Bytes
            sha256 = [string]$Broker.Sha256
            machine = [string]$Broker.Machine
            type = [string]$Broker.Type
        }
        model = [ordered]@{
            id = [string]$ManifestInfo.ModelId
            repository = [string]$ManifestInfo.ModelRepository
            revision = [string]$ManifestInfo.ModelRevision
            path = [string]$Staged.ModelRecord.Path
            installPath = $aiPayloadRootDirectory + '/' + [string]$Staged.ModelRecord.Path
            bytes = [int64]$Staged.ModelRecord.Bytes
            sha256 = [string]$Staged.ModelRecord.Sha256
            license = [string]$ManifestInfo.ModelLicense
        }
        runtime = [ordered]@{
            id = [string]$ManifestInfo.RuntimeId
            repository = [string]$ManifestInfo.RuntimeRepository
            release = [string]$ManifestInfo.RuntimeRelease
            revision = [string]$ManifestInfo.RuntimeRevision
            path = [string]$ManifestInfo.RuntimeDirectoryRelative
            archiveBytes = [int64]$ManifestInfo.RuntimeArchiveBytes
            archiveSha256 = [string]$ManifestInfo.RuntimeArchiveSha256
            license = [string]$ManifestInfo.RuntimeLicense
            entryCount = @($Staged.RuntimeRecords).Count
            entryNamesSha256 = [string]$Staged.RuntimeEntryNamesSha256
            entries = @($Staged.RuntimeRecords | ForEach-Object { [ordered]@{ path = [string]$_.Path; bytes = [int64]$_.Bytes; sha256 = [string]$_.Sha256; machine = [string]$_.Machine } })
        }
        licenses = @($Staged.LicenseRecords | ForEach-Object { [ordered]@{ path = [string]$_.Path; installPath = $aiPayloadRootDirectory + '/' + [string]$_.Path; bytes = [int64]$_.Bytes; sha256 = [string]$_.Sha256 } })
        notice = [ordered]@{
            path = [string]$Staged.NoticeRecord.Path
            installPath = $aiPayloadRootDirectory + '/' + [string]$Staged.NoticeRecord.Path
            bytes = [int64]$Staged.NoticeRecord.Bytes
            sha256 = [string]$Staged.NoticeRecord.Sha256
        }
        payload = @($Payload | ForEach-Object { [ordered]@{ installPath = [string]$_.InstallRelative; kind = [string]$_.Kind; bytes = [int64]$_.Bytes; sha256 = [string]$_.Sha256; machine = [string]$_.Machine } })
        payloadFileCount = @($Payload).Count
    }
    $text = ($manifest | ConvertTo-Json -Depth 12)
    Assert-NoAbsolutePathLeak -Text $text -Description 'The sanitized local AI package manifest'
    return [pscustomobject]@{ Manifest = $manifest; Text = $text; Sha256 = (Get-TextSha256 $text) }
}

# Nothing that leaves this script may name a build-machine location.  This is
# applied to the generated fragment and to the public AI manifest/record only.
function Assert-NoAbsolutePathLeak([string]$Text, [string]$Description) {
    if ($Text -match '(?i)([a-z]:[\\/]|\\\\[a-z0-9._-]+\\|/users/|/home/|file://)') { throw "$Description contains an absolute, UNC, or URL path." }
    if ($Text -match '[\x00-\x08\x0b\x0c\x0e-\x1f]') { throw "$Description contains control characters." }
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME) -and $Text.IndexOf($env:USERNAME, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "$Description contains the local user name." }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and $Text.IndexOf($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "$Description contains a user profile path." }
    if ($Text.IndexOf($repository, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "$Description contains a repository path." }
    foreach ($relative in @('platform/windows-tsf', 'platform\windows-tsf', 'third_party', '.local')) {
        if ($Text.IndexOf($relative, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "$Description contains a repository-relative path: $relative" }
    }
}

function ConvertTo-AiWixIdentifier([string]$Value, [int]$Index) {
    $safe = ($Value -replace '[^A-Za-z0-9]', '_')
    if ($safe.Length -gt 32) { $safe = $safe.Substring(0, 32) }
    return ('AI{0:D4}_{1}' -f $Index, $safe)
}

# The generated fragment may only reference payload files inside the immutable
# snapshot, and may only name reviewed payload files.
function Assert-FragmentIsSnapshotLocal([string]$Text, [string]$SnapshotRoot, [string[]]$AllowedLeafNames) {
    foreach ($match in [regex]::Matches($Text, 'Source="([^"]*)"')) {
        $value = $match.Groups[1].Value
        if (-not (Test-PathWithin $value $SnapshotRoot)) { throw "The generated installer fragment references a source outside the immutable snapshot: $value" }
    }
    foreach ($match in [regex]::Matches($Text, '<File\b[^>]*\sName="([^"]*)"')) {
        $value = $match.Groups[1].Value
        if (@($AllowedLeafNames) -cnotcontains $value) { throw "The generated installer fragment names an unreviewed payload file: $value" }
    }
    foreach ($match in [regex]::Matches($Text, '<Component\b[^>]*\sId="([^"]*)"')) {
        $value = $match.Groups[1].Value
        if ($value -notmatch '^[A-Za-z_][A-Za-z0-9_.]*$' -or $value.Length -gt 72) { throw "The generated installer fragment uses an unsafe Component id: $value" }
    }
    foreach ($match in [regex]::Matches($Text, '<File\b[^>]*\sId="([^"]*)"')) {
        $value = $match.Groups[1].Value
        if ($value -notmatch '^[A-Za-z_][A-Za-z0-9_.]*$' -or $value.Length -gt 72) { throw "The generated installer fragment uses an unsafe File id: $value" }
    }
}

function Assert-CallerInputs([string]$Runtime, [string]$Helper, [string]$Manifest, [switch]$SkipSourceIdentity) {
    $runtimeFull = Get-ExistingPath $Runtime ('Container')
    $helperFull = Get-ExistingPath $Helper ('Leaf')
    $manifestFull = Get-ExistingPath $Manifest ('Leaf')
    if (Test-PathWithin $helperFull $runtimeFull) { throw 'Installer helper must not be inside the runtime payload.' }
    if ((Split-Path -Leaf $helperFull) -cne $helperSpec.Name) { throw "Installer helper must be named $($helperSpec.Name)." }
    $manifestObject = Get-Content -LiteralPath $manifestFull -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int](Get-JsonProperty $manifestObject 'schemaVersion') -ne 2) { throw 'Runtime manifest schemaVersion 2 is required for provenance-bound staging.' }
    if ([string](Get-JsonProperty $manifestObject 'status') -ne 'staged-unverified-runtime-payload') { throw "Runtime manifest status is not buildable: $(Get-JsonProperty $manifestObject 'status')" }
    Assert-ManifestHasNoSelfHash $manifestObject
    $manifestPayload = Get-FullPath ([string](Get-JsonProperty $manifestObject 'payloadDirectory'))
    $manifestHelperDirectory = Get-FullPath ([string](Get-JsonProperty $manifestObject 'helperDirectory'))
    if ($manifestPayload -ine $runtimeFull -or $manifestHelperDirectory -ine (Split-Path -Parent $helperFull)) { throw ("Runtime manifest directories do not match the caller payload/helper (manifest payload={0}, runtime={1}, manifest helper={2}, helper={3})." -f $manifestPayload, $runtimeFull, $manifestHelperDirectory, (Split-Path -Parent $helperFull)) }
    $sourceIdentity = Get-JsonProperty $manifestObject 'sourceIdentity'
    $manifestMozc = Get-JsonProperty $sourceIdentity 'mozc'
    # Check the clean-tree requirement first so an explicitly requested release
    # candidate reports the actionable reason, rather than the downstream
    # symptom of the source having moved since staging.
    if ($RequireCleanSource -and ([bool](Get-JsonProperty $sourceIdentity 'repositoryDirty') -or
        ($null -ne $manifestMozc -and $manifestMozc.status -eq 'verified' -and -not [bool]$manifestMozc.clean))) {
        throw 'A clean source tree is required for a release installer candidate.'
    }
    if (-not $SkipSourceIdentity) { [void](Assert-SourceIdentityMatches $sourceIdentity 'Runtime manifest') }
    elseif ($RequireCleanSource) { throw 'A clean source tree is required for a release installer candidate.' }

    $records = @(Get-JsonProperty $manifestObject 'files')
    $expectedNames = @($runtimeSpecs | ForEach-Object { $_.Name }) + $redistNames + $noticeNames
    $actualFiles = @(Get-ChildItem -LiteralPath $runtimeFull -Force)
    if (@($actualFiles | Where-Object { $_.PSIsContainer }).Count -gt 0) { throw 'Only a flat, reviewed runtime payload is accepted.' }
    if (@($actualFiles | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) { throw 'Reparse points are not allowed in the runtime payload.' }
    if ($records.Count -ne $expectedNames.Count -or $actualFiles.Count -ne $expectedNames.Count) { throw "Runtime manifest/payload file count does not match the reviewed $($expectedNames.Count)-file contract." }
    foreach ($name in $expectedNames) {
        $matches = @($records | Where-Object { [string]$_.Name -ceq $name })
        if ($matches.Count -ne 1) { throw "Runtime manifest must contain exactly one record for $name." }
        $spec = Get-ExpectedFileSpec $name
        $path = Join-Path $runtimeFull $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Runtime payload file is missing: $name" }
        if ($spec.Type -ne 'Notice') { [void](Assert-Pe -Path $path -Machine $spec.Machine -Type $spec.Type -Exports $spec.Exports) }
        Assert-RecordMatchesFile $matches[0] $path $name $spec.Type $spec.Machine $spec.Exports
    }
    $helperRecord = Get-JsonProperty $manifestObject 'helper'
    if ($null -eq $helperRecord -or [string]$helperRecord.Name -cne $helperSpec.Name) { throw 'Runtime manifest helper record is missing or has the wrong name.' }
    [void](Assert-Pe -Path $helperFull -Machine $helperSpec.Machine -Type $helperSpec.Type -Exports $helperSpec.Exports)
    Assert-RecordMatchesFile $helperRecord $helperFull $helperSpec.Name $helperSpec.Type $helperSpec.Machine $helperSpec.Exports
    $manifestHash = Get-Sha256 -Path $manifestFull
    return [pscustomobject]@{
        Runtime = $runtimeFull
        Helper = $helperFull
        Manifest = $manifestFull
        ManifestSha256 = $manifestHash
        ManifestObject = $manifestObject
        SourceIdentity = $sourceIdentity
        Records = @($records | ForEach-Object { [pscustomobject]$_ })
        HelperRecord = $helperRecord
    }
}

# Validate the four all-or-none local-AI inputs against the pinned manifest and
# the staged receipt before any snapshot is created.
function Assert-AiCallerInputs($RuntimeValidation, [string]$Broker, [string]$StagedRoot, [string]$Manifest, [string]$Receipt, [switch]$Fixture) {
    $manifestInfo = Assert-AiManifest -Path $Manifest -Fixture:$Fixture
    $staged = Assert-AiStagedTree -ManifestInfo $manifestInfo -Root $StagedRoot -Fixture:$Fixture
    if (-not ($staged.ReceiptFullPath -ieq $Receipt)) {
        throw 'The local AI staging receipt must be the receipt file declared by the pinned manifest inside the staged local-AI directory.'
    }
    $receiptInfo = Assert-AiReceipt -Path $Receipt -ManifestInfo $manifestInfo -Staged $staged
    $brokerInfo = Assert-AiBroker -Path $Broker -RuntimeValidation $RuntimeValidation -Staged $staged -PinnedBrokerIdentity $manifestInfo.BrokerIdentity
    $payload = New-AiPayloadPlan -ManifestInfo $manifestInfo -Staged $staged -Broker $brokerInfo
    $sanitized = New-AiSanitizedPackageManifest -ManifestInfo $manifestInfo -Staged $staged -ReceiptInfo $receiptInfo -Broker $brokerInfo -Payload $payload
    return [pscustomobject]@{
        ManifestInfo = $manifestInfo
        Staged = $staged
        ReceiptInfo = $receiptInfo
        Broker = $brokerInfo
        Payload = @($payload)
        Sanitized = $sanitized
    }
}

function Assert-SnapshotInputs($Snapshot, $CallerValidation) {
    $runtime = Join-Path $Snapshot.Root 'runtime'
    $helper = Join-Path $Snapshot.Root ('helper\' + $helperSpec.Name)
    if ((Get-Sha256 -Path (Join-Path $Snapshot.Root 'runtime-manifest.json')) -ne $CallerValidation.ManifestSha256) { throw 'Immutable runtime manifest copy changed during snapshot creation.' }
    $files = @(Get-ChildItem -LiteralPath $runtime -Force)
    if (@($files | Where-Object { $_.PSIsContainer -or (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) }).Count -gt 0) { throw 'Immutable runtime snapshot is not a flat non-reparse directory.' }
    $expectedNames = @($runtimeSpecs | ForEach-Object { $_.Name }) + $redistNames + $noticeNames
    if ($files.Count -ne $expectedNames.Count) { throw 'Immutable runtime snapshot has an unexpected file count.' }
    foreach ($name in $expectedNames) {
        $path = Join-Path $runtime $name
        $record = @($CallerValidation.Records | Where-Object { [string]$_.Name -ceq $name })
        if ($record.Count -ne 1) { throw "Caller validation did not retain a record for $name." }
        $spec = Get-ExpectedFileSpec $name
        if ($spec.Type -ne 'Notice') { [void](Assert-Pe -Path $path -Machine $spec.Machine -Type $spec.Type -Exports $spec.Exports) }
        Assert-RecordMatchesFile $record[0] $path $name $spec.Type $spec.Machine $spec.Exports
    }
    [void](Assert-Pe -Path $helper -Machine $helperSpec.Machine -Type $helperSpec.Type -Exports $helperSpec.Exports)
    Assert-RecordMatchesFile $CallerValidation.HelperRecord $helper $helperSpec.Name $helperSpec.Type $helperSpec.Machine $helperSpec.Exports
    $buildInputIdentity = Get-JsonProperty $CallerValidation.SourceIdentity 'buildInputs'
    $buildInputRecords = @(Get-JsonProperty $buildInputIdentity 'records')
    foreach ($relative in @('KanaAI.wxs', 'Setup.cs', 'Setup.manifest')) {
        $callerPath = Join-Path $packageSource $relative
        $snapshotPath = Join-Path $Snapshot.Root ('package\' + $relative)
        $identityRelative = 'platform/windows-tsf/installer/package/' + $relative
        $expected = @($buildInputRecords | Where-Object { [string]$_.path -ieq $identityRelative })
        if ($expected.Count -ne 1) { throw "Runtime manifest does not bind build input $relative." }
        if ((Get-Sha256 -Path $snapshotPath) -ine [string]$expected[0].sha256 -or
            [int64](Get-Item -LiteralPath $snapshotPath -Force).Length -ne [int64]$expected[0].bytes) {
            throw "Immutable build package input does not match the staged source identity: $relative"
        }
        if ((Get-Sha256 -Path $snapshotPath) -ine (Get-Sha256 -Path $callerPath)) { throw "Build package source changed before snapshot validation: $relative" }
    }
    $ai = $null
    if ($null -ne $Snapshot.Ai) {
        $ai = Assert-AiSnapshotInputs -Snapshot $Snapshot -CallerAi $CallerValidation.Ai
    }
    return [pscustomobject]@{
        Runtime = $runtime
        Helper = $helper
        Files = @($files | Sort-Object Name)
        HelperSha256 = Get-Sha256 -Path $helper
        Ai = $ai
    }
}

# Re-verify the immutable local-AI snapshot from its own bytes.  This runs once
# right after the copy and again after WiX/Setup, and never reads a caller path.
function Assert-AiSnapshotInputs($Snapshot, $CallerAi) {
    $ai = $Snapshot.Ai
    if ((Get-Sha256 -Path $ai.SourceManifest) -ine [string]$CallerAi.ManifestInfo.Sha256) { throw 'The immutable local AI manifest copy changed during snapshot creation.' }
    if ((Get-Sha256 -Path $ai.SourceReceipt) -ine [string]$CallerAi.ReceiptInfo.Sha256) { throw 'The immutable local AI staging receipt copy changed during snapshot creation.' }
    if ($null -ne $CallerAi.Staged.SanitizedSha256) {
        if ((Get-Sha256 -Path $ai.SourceSanitizedManifest) -ine [string]$CallerAi.Staged.SanitizedSha256) { throw 'The immutable local AI sanitized package manifest copy changed during snapshot creation.' }
    }
    $expected = @($CallerAi.Payload)
    # The broker executable is copied next to the AI payload tree rather than
    # inside it, so the payload-tree file count excludes exactly one record.
    $expectedInPayloadRoot = @($expected | Where-Object { $null -ne $_.StagedRelative })
    $stagedFiles = @(Get-ChildItem -LiteralPath $ai.Root -Force -Recurse -File)
    if ($stagedFiles.Count -ne $expectedInPayloadRoot.Count) {
        $debugNames = ($stagedFiles | ForEach-Object { $_.FullName.Substring($ai.Root.Length).TrimStart('\','/') }) -join ', '
        $debugExpected = ($expectedInPayloadRoot | ForEach-Object { [string]$_.StagedRelative }) -join ', '
        throw ("The immutable local AI snapshot has an unexpected payload file count. actual({0})={1} | expected({2})={3}" -f $stagedFiles.Count, $debugNames, $expectedInPayloadRoot.Count, $debugExpected)
    }
    foreach ($record in $expected) {
        if ($null -eq $record.StagedRelative) { $path = $ai.Broker }
        else { $path = [IO.Path]::GetFullPath((Join-Path $ai.Root ([string]$record.StagedRelative))) }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "The immutable local AI snapshot is missing a payload file: $($record.InstallRelative)" }
        $item = Get-Item -LiteralPath $path -Force
        if ([int64]$item.Length -ne [int64]$record.Bytes) { throw "The immutable local AI snapshot changed the size of a payload file: $($record.InstallRelative)" }
        if ((Get-Sha256 -Path $path) -ine [string]$record.Sha256) { throw "The immutable local AI snapshot changed the bytes of a payload file: $($record.InstallRelative)" }
        switch ([string]$record.Kind) {
            'Broker' { [void](Assert-Pe -Path $path -Machine 0x8664 -Type 'Exe' -Exports @()) }
            'RuntimeDll' { [void](Assert-Pe -Path $path -Machine 0x8664 -Type 'Dll' -Exports @()) }
            'RuntimeExe' { [void](Assert-Pe -Path $path -Machine 0x8664 -Type 'Exe' -Exports @()) }
            default { if ((Split-Path -Leaf $path) -ine (Split-Path -Leaf ([string]$record.InstallRelative))) { throw "The immutable local AI snapshot renamed a payload file: $($record.InstallRelative)" } }
        }
    }
    $stagedInfo = Assert-AiStagedTree -ManifestInfo $CallerAi.ManifestInfo -Root $ai.Root -PayloadOnly
    $snapshotBroker = Assert-AiBroker -Path $ai.Broker -RuntimeValidation ([pscustomobject]@{ Records = @(); HelperRecord = [pscustomobject]@{ Sha256 = '' } }) -Staged $stagedInfo -PinnedBrokerIdentity $CallerAi.ManifestInfo.BrokerIdentity
    $payload = New-AiPayloadPlan -ManifestInfo $CallerAi.ManifestInfo -Staged $stagedInfo -Broker $snapshotBroker
    $receiptInfo = [pscustomobject]@{ Sha256 = (Get-Sha256 -Path $ai.SourceReceipt) }
    $sanitized = New-AiSanitizedPackageManifest -ManifestInfo $CallerAi.ManifestInfo -Staged $stagedInfo -ReceiptInfo $receiptInfo -Broker $snapshotBroker -Payload $payload
    if ($sanitized.Sha256 -ne [string]$CallerAi.Sanitized.Sha256) { throw 'The immutable local AI snapshot does not reproduce the reviewed sanitized package manifest.' }
    return [pscustomobject]@{
        Root = $ai.Root
        Broker = $ai.Broker
        BrokerSha256 = $snapshotBroker.Sha256
        Payload = @($payload)
        Sanitized = $sanitized
        ManifestSha256 = [string]$CallerAi.ManifestInfo.Sha256
        ReceiptSha256 = [string]$CallerAi.ReceiptInfo.Sha256
    }
}

function New-ImmutableSnapshot($CallerValidation, [string]$Output) {
    Assert-NoReparsePath -Path $Output -AllowMissing
    if (Test-Path -LiteralPath $Output -PathType Leaf) { throw "Installer output is a file, not a directory: $Output" }
    New-Item -ItemType Directory -Path $Output -Force | Out-Null
    Assert-NoReparsePath -Path $Output
    $managedRoot = Join-Path $Output '.local'
    Assert-NoReparsePath -Path $managedRoot -AllowMissing
    New-Item -ItemType Directory -Path $managedRoot -Force | Out-Null
    Assert-NoReparsePath -Path $managedRoot
    $id = 'input-' + [Guid]::NewGuid().ToString('N')
    $root = Join-Path $managedRoot $id
    $runtime = Join-Path $root 'runtime'
    $helperDirectory = Join-Path $root 'helper'
    $package = Join-Path $root 'package'
    New-Item -ItemType Directory -Path $runtime, $helperDirectory, $package -Force | Out-Null
    Assert-NoReparsePath -Path $root
    Assert-NoReparsePath -Path $runtime
    Assert-NoReparsePath -Path $helperDirectory
    Assert-NoReparsePath -Path $package
    foreach ($file in @(Get-ChildItem -LiteralPath $CallerValidation.Runtime -Force -File)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $runtime $file.Name)
    }
    Copy-Item -LiteralPath $CallerValidation.Helper -Destination (Join-Path $helperDirectory $helperSpec.Name)
    Copy-Item -LiteralPath $CallerValidation.Manifest -Destination (Join-Path $root 'runtime-manifest.json')
    foreach ($name in @('KanaAI.wxs', 'Setup.cs', 'Setup.manifest')) {
        $source = Join-Path $packageSource $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Installer package source is missing: $source" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $package $name)
    }
    $aiSnapshot = $null
    if ($null -ne $CallerValidation.Ai) {
        $aiRoot = Join-Path $root $aiPayloadRootDirectory
        $aiBrokerDirectory = Join-Path $root 'ai-broker'
        # Build inputs only.  The raw staging receipt and the sanitized package
        # manifest are kept for post-build revalidation and are never payload.
        $aiSourceRoot = Join-Path $root 'ai-source'
        New-Item -ItemType Directory -Path $aiRoot, $aiBrokerDirectory, $aiSourceRoot -Force | Out-Null
        Assert-NoReparsePath -Path $aiRoot
        Assert-NoReparsePath -Path $aiBrokerDirectory
        Assert-NoReparsePath -Path $aiSourceRoot
        foreach ($record in @($CallerValidation.Ai.Payload)) {
            if ($null -eq $record.StagedRelative) { continue }
            $destination = [IO.Path]::GetFullPath((Join-Path $aiRoot ([string]$record.StagedRelative)))
            if (-not (Test-PathWithin $destination $aiRoot)) { throw "An immutable local AI payload path escapes the snapshot: $($record.InstallRelative)" }
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Assert-NoReparsePath -Path $parent
            Copy-Item -LiteralPath (Join-Path $CallerValidation.Ai.Staged.Root ([string]$record.StagedRelative)) -Destination $destination
        }
        $aiBrokerDestination = Join-Path $aiBrokerDirectory $aiBrokerFileName
        Copy-Item -LiteralPath $CallerValidation.Ai.Broker.Path -Destination $aiBrokerDestination
        $aiManifestDestination = Join-Path $aiSourceRoot 'ai-manifest.json'
        Copy-Item -LiteralPath $CallerValidation.Ai.ManifestInfo.Path -Destination $aiManifestDestination
        $aiReceiptDestination = Join-Path $aiSourceRoot ([string]$CallerValidation.Ai.ManifestInfo.ReceiptRelative)
        Copy-Item -LiteralPath $CallerValidation.Ai.ReceiptInfo.Path -Destination $aiReceiptDestination
        $aiSanitizedDestination = Join-Path $aiSourceRoot $aiSanitizedManifestFileName
        if ($null -ne $CallerValidation.Ai.Staged.SanitizedSha256) {
            Copy-Item -LiteralPath (Join-Path $CallerValidation.Ai.Staged.Root $aiSanitizedManifestFileName) -Destination $aiSanitizedDestination
        }
        elseif (Test-Path -LiteralPath $aiSanitizedDestination) { Remove-Item -LiteralPath $aiSanitizedDestination -Force }
        foreach ($source in @($aiManifestDestination, $aiReceiptDestination)) { Assert-NoReparsePath -Path $source }
        $aiSnapshot = [pscustomobject]@{
            Root = $aiRoot
            Broker = $aiBrokerDestination
            SourceRoot = $aiSourceRoot
            SourceManifest = $aiManifestDestination
            SourceReceipt = $aiReceiptDestination
            SourceSanitizedManifest = $aiSanitizedDestination
        }
    }
    return [pscustomobject]@{ Id = $id; Root = $root; Runtime = $runtime; Helper = (Join-Path $helperDirectory $helperSpec.Name); Package = $package; ManagedRoot = $managedRoot; Ai = $aiSnapshot }
}

function Remove-ManagedSnapshot($Snapshot) {
    if ($null -eq $Snapshot) { return }
    $root = Get-FullPath $Snapshot.Root
    $managed = Get-FullPath $Snapshot.ManagedRoot
    if (Test-PathWithin $root $managed -and (Split-Path -Leaf $root) -eq $Snapshot.Id) {
        Assert-NoReparsePath -Path $root
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Publish-BuildOutput([string]$BuildOutput, [string]$Output, [string]$ManagedRoot, [string[]]$ArtifactNames) {
    $backup = Join-Path $ManagedRoot ('previous-output-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $expectedHashes = @{}
    foreach ($name in $ArtifactNames) {
        $source = Join-Path $BuildOutput $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Built artifact is missing before publication: $source" }
        $expectedHashes[$name] = Get-Sha256 -Path $source
    }
    $backedUp = @(); $published = @(); $succeeded = $false
    try {
        foreach ($name in $ArtifactNames) {
            $destination = Join-Path $Output $name
            if (Test-Path -LiteralPath $destination) {
                Assert-NoReparsePath -Path $destination
                if ((Get-Item -LiteralPath $destination -Force).PSIsContainer) { throw "Installer output entry is a directory: $destination" }
                Move-Item -LiteralPath $destination -Destination (Join-Path $backup $name)
                $backedUp += $name
            }
        }
        # Publish the receipt last.  If any move fails, the old receipt remains
        # paired with the old artifacts, and the rollback below removes all
        # newly moved artifacts before restoring the old set.
        foreach ($name in $ArtifactNames) {
            $source = Join-Path $BuildOutput $name
            $destination = Join-Path $Output $name
            # `-Force` is required: without it PowerShell refuses to replace an
            # existing destination, which is what previously failed here once a
            # prior run had left an artifact in place.  A rename keeps
            # publication atomic within the volume, which matters for a
            # multi-gigabyte payload.
            #
            # A freshly written MSI is also held open by real-time scanners for
            # the duration of their scan, which is far longer than a scheduling
            # hiccup.  Retry with a linear backoff capped per wait so the window
            # covers a scan while still failing promptly on a real fault such as
            # a genuinely missing or permission-denied source.
            $moved = $false
            $lastPublishError = $null
            for ($attempt = 1; $attempt -le $PublishRetryCount -and -not $moved; $attempt++) {
                try {
                    Move-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
                    $moved = $true
                }
                catch {
                    $lastPublishError = $_
                    if ($attempt -eq $PublishRetryCount) { throw }
                    Start-Sleep -Milliseconds ([Math]::Min($PublishRetryDelayMilliseconds * $attempt, 5000))
                }
            }
            if ((Get-Sha256 -Path $destination) -ine [string]$expectedHashes[$name]) {
                throw "Published artifact does not match the built bytes: $name"
            }
            $published += $name
        }
        foreach ($name in $ArtifactNames) {
            $destinationHash = Get-Sha256 -Path (Join-Path $Output $name)
            if ($destinationHash -ine [string]$expectedHashes[$name]) { throw "Published artifact changed during publication: $name" }
        }
        $succeeded = $true
    }
    catch {
        foreach ($name in $published) {
            $path = Join-Path $Output $name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        foreach ($name in $backedUp) {
            $backupPath = Join-Path $backup $name
            if (Test-Path -LiteralPath $backupPath) { Move-Item -LiteralPath $backupPath -Destination (Join-Path $Output $name) }
        }
        throw
    }
    finally {
        if ($succeeded -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Generate the WiX fragment for the reviewed payload.  The AI section is
# emitted into the same referenced component group plus a DirectoryRef for the
# ai\ subtree, so KanaAI.wxs does not need to change.  Every source path is
# inside the immutable snapshot and every payload name is a reviewed file.
function New-InstallerWxsFragment($Snapshot, $SnapshotValidation) {
    $xml = [Text.StringBuilder]::new()
    $allowedLeafNames = @()
    $aiRecords = @()
    if ($null -ne $SnapshotValidation.Ai) { $aiRecords = @($SnapshotValidation.Ai.Payload) }
    foreach ($record in $aiRecords) { $allowedLeafNames += (Split-Path -Leaf ([string]$record.InstallRelative)) }
    [void]$xml.AppendLine('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs"><Fragment>')
    if ($aiRecords.Count -gt 0) {
        [void]$xml.AppendLine('<DirectoryRef Id="INSTALLFOLDER">')
        [void]$xml.AppendLine(('<Directory Id="{0}" Name="{1}">' -f $aiDirectoryIds.root, $aiPayloadRootDirectory))
        [void]$xml.AppendLine(('<Directory Id="{0}" Name="{1}" />' -f $aiDirectoryIds.model, $aiModelDirectoryName))
        [void]$xml.AppendLine(('<Directory Id="{0}" Name="{1}" />' -f $aiDirectoryIds.runtime, $aiRuntimeDirectoryName))
        [void]$xml.AppendLine(('<Directory Id="{0}" Name="{1}" />' -f $aiDirectoryIds.license, $aiLicenseDirectoryName))
        [void]$xml.AppendLine('</Directory>')
        [void]$xml.AppendLine('</DirectoryRef>')
    }
    [void]$xml.AppendLine('<ComponentGroup Id="RuntimeFiles" Directory="INSTALLFOLDER">')
    foreach ($file in @($SnapshotValidation.Files)) {
        $id = 'F_' + ($file.Name -replace '[^A-Za-z0-9_.]', '_')
        $name = [Security.SecurityElement]::Escape($file.Name)
        $path = [Security.SecurityElement]::Escape($file.FullName)
        $bitness = if ($file.Name -eq 'mozc_tip32.dll') { 'always32' } else { 'always64' }
        $allowedLeafNames += $file.Name
        [void]$xml.AppendLine("<Component Id=`"$id`" Guid=`"*`" Bitness=`"$bitness`"><File Id=`"$id`" Name=`"$name`" Source=`"$path`" KeyPath=`"yes`" /></Component>")
    }
    $aiIndex = 0
    foreach ($record in $aiRecords) {
        $aiIndex++
        if ($null -eq $record.StagedRelative) { $source = $Snapshot.Ai.Broker }
        else { $source = [IO.Path]::GetFullPath((Join-Path $Snapshot.Ai.Root ([string]$record.StagedRelative))) }
        $id = ConvertTo-AiWixIdentifier (Split-Path -Leaf ([string]$record.InstallRelative)) $aiIndex
        $name = [Security.SecurityElement]::Escape((Split-Path -Leaf ([string]$record.InstallRelative)))
        $escaped = [Security.SecurityElement]::Escape($source)
        [void]$xml.AppendLine(('<Component Id="{0}" Guid="*" Bitness="always64" Directory="{1}"><File Id="{0}" Name="{2}" Source="{3}" KeyPath="yes" /></Component>' -f $id, [string]$record.DirectoryId, $name, $escaped))
    }
    [void]$xml.AppendLine('</ComponentGroup></Fragment></Wix>')
    $text = $xml.ToString()
    Assert-FragmentIsSnapshotLocal -Text $text -SnapshotRoot $Snapshot.Root -AllowedLeafNames $allowedLeafNames
    return [pscustomobject]@{
        Text = $text
        AiPayload = @($aiRecords | ForEach-Object { [string]$_.InstallRelative })
        AiPayloadCount = $aiRecords.Count
    }
}

if (-not $RuntimeManifestPath) { $RuntimeManifestPath = Join-Path $repository '.local\tsf-runtime-manifest.json' }
Assert-NoReparsePath -Path $repository
$runtimeInput = Get-ExistingPath $RuntimeDirectory ('Container')
$helperInput = Get-ExistingPath $InstallerHelper ('Leaf')
$manifestInput = Get-ExistingPath $RuntimeManifestPath ('Leaf')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repository '.local\installer' }
$output = Get-FullPath $OutputDirectory
if ($output -ieq $runtimeInput -or $output.StartsWith($runtimeInput + '\', [StringComparison]::OrdinalIgnoreCase) -or $runtimeInput.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Installer output must not overlap the runtime payload.' }
if ($output -ieq $repository -or $repository.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Installer output must not be the repository root or one of its ancestors.' }
if (Test-PathWithin $output $packageSource -or Test-PathWithin $packageSource $output) { throw 'Installer output must not overlap installer package sources.' }
Assert-NoReparsePath -Path $output -AllowMissing
$aiBrokerInput = ''
$aiRootInput = ''
$aiManifestInput = ''
$aiReceiptInput = ''
if ($aiMode.Enabled) {
    $aiBrokerInput = Get-ExistingPath $BrokerExecutable ('Leaf')
    $aiRootInput = Get-ExistingPath $AiRuntimeDirectory ('Container')
    $aiManifestInput = Get-ExistingPath $AiManifestPath ('Leaf')
    $aiReceiptInput = Get-ExistingPath $AiReceiptPath ('Leaf')
    foreach ($pair in @(
        [pscustomobject]@{ Label = 'the staged local AI directory'; A = $aiRootInput; B = $runtimeInput },
        [pscustomobject]@{ Label = 'the staged local AI directory'; A = $aiRootInput; B = $output },
        [pscustomobject]@{ Label = 'the staged local AI directory'; A = $aiRootInput; B = $packageSource },
        [pscustomobject]@{ Label = 'the local AI broker'; A = $aiBrokerInput; B = $runtimeInput },
        [pscustomobject]@{ Label = 'the local AI broker'; A = $aiBrokerInput; B = $aiRootInput },
        [pscustomobject]@{ Label = 'the local AI broker'; A = $aiBrokerInput; B = $output },
        [pscustomobject]@{ Label = 'the pinned local AI manifest'; A = $aiManifestInput; B = $aiRootInput }
    )) {
        if (Test-PathWithin $pair.A $pair.B -or Test-PathWithin $pair.B $pair.A) {
            throw ("{0} must not overlap {1}." -f $pair.Label, $pair.B)
        }
    }
}
$runtimeManifestSha256 = Get-Sha256 -Path $manifestInput
$callerValidation = $null
$snapshot = $null
$buildOutput = $null
$buildSucceeded = $false
$aiValidation = $null
try {
    $callerValidation = Assert-CallerInputs -Runtime $runtimeInput -Helper $helperInput -Manifest $manifestInput -SkipSourceIdentity:$SkipSourceIdentity
    if ($callerValidation.ManifestSha256 -ine $runtimeManifestSha256) { throw 'Runtime manifest changed while it was being validated; retry from a fixed manifest.' }
    $runtimeManifestSha256 = $callerValidation.ManifestSha256
    if ($aiMode.Enabled) {
        $aiValidation = Assert-AiCallerInputs -RuntimeValidation $callerValidation -Broker $aiBrokerInput -StagedRoot $aiRootInput -Manifest $aiManifestInput -Receipt $aiReceiptInput -Fixture:$AiFixtureMode
    }
    Add-Member -InputObject $callerValidation -NotePropertyName 'Ai' -NotePropertyValue $aiValidation
    $snapshot = New-ImmutableSnapshot -CallerValidation $callerValidation -Output $output
    $snapshotValidation = Assert-SnapshotInputs -Snapshot $snapshot -CallerValidation $callerValidation
    $sourceBeforeBuild = Assert-SourceIdentityMatches $callerValidation.SourceIdentity 'Runtime manifest'
    $fragmentResult = New-InstallerWxsFragment -Snapshot $snapshot -SnapshotValidation $snapshotValidation
    $aiFragment = [pscustomobject]@{
        Text = [string]$fragmentResult.Text
        AiPayload = @($fragmentResult.AiPayload)
        AiPayloadCount = [int]$fragmentResult.AiPayloadCount
    }
    $aiModelInstallPath = $null
    $aiBrokerInstallPath = $null
    if ($null -ne $aiValidation) {
        $aiModelRecord = @($aiValidation.Payload | Where-Object { [string]$_.Kind -eq 'ModelWeight' })
        $aiBrokerRecord = @($aiValidation.Payload | Where-Object { [string]$_.Kind -eq 'Broker' })
        if ($aiModelRecord.Count -ne 1) { throw 'The local AI payload plan does not contain exactly one model weight.' }
        if ($aiBrokerRecord.Count -ne 1) { throw 'The local AI payload plan does not contain exactly one local AI broker.' }
        $aiModelInstallPath = [string]$aiModelRecord[0].InstallRelative
        $aiBrokerInstallPath = [string]$aiBrokerRecord[0].InstallRelative
    }

    if ($ValidateOnly) {
        return [pscustomobject]@{
            Validated = $true
            SnapshotCreated = $true
            SnapshotValidation = 'passed'
            SourceCommit = [string]$sourceBeforeBuild.repositoryHead
            SourceTreeDirty = [bool]$sourceBeforeBuild.repositoryDirty
            MozcCommit = [string]$sourceBeforeBuild.mozcCommit
            PatchCount = @($sourceBeforeBuild.patches).Count
            RuntimeManifest = $callerValidation.Manifest
            RuntimeManifestSha256 = $runtimeManifestSha256
            RuntimeManifestSelfHashEmbedded = $false
            SourceIdentityStatus = [string]$sourceBeforeBuild.status
            HostOverlayFingerprint = [string]$sourceBeforeBuild.hostOverlayFingerprint
            BuildInputFingerprint = [string]$sourceBeforeBuild.buildInputs.fingerprint
            AiMode = [bool]$aiMode.Enabled
            LocalAiIncluded = [bool]$aiMode.Enabled
            AiOperationVerified = $false
            AiStartupTested = $false
            InstalledInputVerified = $false
            Verified = $false
            AiManifestSha256 = if ($null -eq $aiValidation) { $null } else { [string]$aiValidation.ManifestInfo.Sha256 }
            AiReceiptSha256 = if ($null -eq $aiValidation) { $null } else { [string]$aiValidation.ReceiptInfo.Sha256 }
            AiPayloadCount = [int]$aiFragment.AiPayloadCount
            AiPayloadRelativePaths = @($aiFragment.AiPayload)
            AiBrokerName = if ($null -eq $aiValidation) { $null } else { [string]$aiValidation.Broker.Name }
            AiBrokerSha256 = if ($null -eq $aiValidation) { $null } else { [string]$aiValidation.Broker.Sha256 }
            AiBrokerInstallPath = $aiBrokerInstallPath
            AiModelInstallPath = $aiModelInstallPath
            AiRuntimeEntryCount = if ($null -eq $aiValidation) { 0 } else { @($aiValidation.Staged.RuntimeRecords).Count }
            AiPackageManifestSha256 = if ($null -eq $aiValidation) { $null } else { [string]$aiValidation.Sanitized.Sha256 }
            AiPackageManifestText = if ($null -eq $aiValidation) { '' } else { [string]$aiValidation.Sanitized.Text }
            AiSnapshotRoot = if ($null -eq $snapshot.Ai) { $null } else { [string]$snapshot.Ai.Root }
            SnapshotRoot = [string]$snapshot.Root
            AiFragmentText = [string]$aiFragment.Text
        }
    }

    if (-not $WixPath) { $WixPath = Join-Path $repository '.local\wix\wix.exe' }
    $wix = Get-ExistingPath $WixPath ('Leaf')
    $wixVersion = (& $wix --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $wixVersion -notlike '5.0.2*') { throw 'WiX 5.0.2 is required.' }
    $buildOutput = Join-Path $snapshot.ManagedRoot ('build-output-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $buildOutput -Force | Out-Null
    Assert-NoReparsePath -Path $buildOutput
    $fragment = Join-Path $buildOutput 'RuntimeFiles.wxs'
    Write-Utf8NoBom $fragment $aiFragment.Text
    $msi = Join-Path $buildOutput "KanaAI-$Version-x64.msi"
    $packageWxs = Join-Path $snapshot.Package 'KanaAI.wxs'
    & $wix build $packageWxs $fragment -arch x64 -d "Version=$Version" -d "HelperPath=$($snapshot.Helper)" -o $msi
    if ($LASTEXITCODE -ne 0) { throw "WiX build failed: $LASTEXITCODE" }
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $setup = Join-Path $buildOutput "KanaAI-$Version-Setup.exe"
    & $csc /nologo /target:winexe /platform:x64 /optimize+ /reference:System.Windows.Forms.dll "/out:$setup" "/resource:$msi,KanaAI.msi" "/win32manifest:$(Join-Path $snapshot.Package 'Setup.manifest')" (Join-Path $snapshot.Package 'Setup.cs')
    if ($LASTEXITCODE -ne 0) { throw "Setup launcher compilation failed: $LASTEXITCODE" }

    # Re-read and revalidate the immutable inputs after both build commands.
    # No hash below is taken from the caller paths.
    $snapshotValidation = Assert-SnapshotInputs -Snapshot $snapshot -CallerValidation $callerValidation
    $sourceAfterBuild = Assert-SourceIdentityMatches $callerValidation.SourceIdentity 'Runtime manifest'
    if ((Get-ObjectFingerprint $sourceBeforeBuild) -ne (Get-ObjectFingerprint $sourceAfterBuild)) { throw 'Source identity changed while the installer was being built; discard the candidate.' }

    $msiSha256 = Get-Sha256 -Path $msi
    $setupSha256 = Get-Sha256 -Path $setup
    if ((Get-ManifestResourceSha256 -AssemblyPath $setup -ResourceName 'KanaAI.msi') -ne $msiSha256) { throw 'Setup.exe does not embed the MSI that was just built.' }
    $msiProperties = Get-MsiPropertyMap -Path $msi
    foreach ($property in @(
        [pscustomobject]@{ Name = 'ProductName'; Value = 'KanaAI Development Preview' }
        [pscustomobject]@{ Name = 'ProductVersion'; Value = $Version }
        [pscustomobject]@{ Name = 'ALLUSERS'; Value = '1' }
    )) {
        if ([string]$msiProperties[$property.Name] -ne [string]$property.Value) { throw "MSI property $($property.Name) is not $($property.Value)." }
    }
    foreach ($property in @('ProductCode', 'UpgradeCode')) {
        if ([string]$msiProperties[$property] -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw "MSI property $property is missing or invalid." }
    }
    $msiSignature = Get-AuthenticodeStatus -Path $msi
    $setupSignature = Get-AuthenticodeStatus -Path $setup
    $declaredSigning = if ($msiSignature -eq 'Valid' -and $setupSignature -eq 'Valid') { 'signed' } elseif ($msiSignature -eq 'Valid' -or $setupSignature -eq 'Valid') { 'mixed' } else { 'unsigned' }
    $snapshotFiles = @(Get-ChildItem -LiteralPath $snapshot.Runtime -Force -File | Sort-Object Name | ForEach-Object {
        $spec = Get-ExpectedFileSpec $_.Name
        Get-FileRecord $_.FullName $_.Name $spec.Type $spec.Machine $spec.Exports
    })
    # The AI record is rebuilt from the revalidated immutable snapshot, so it
    # describes the bytes that were actually handed to WiX, and it carries no
    # absolute path, username, repository path, or raw staging receipt content.
    $aiRecord = [ordered]@{
        status = 'absent'
        included = $false
        aiOperationVerified = $false
        aiStartupTested = $false
        verified = $false
        payloadFileCount = 0
        payloadRelativePaths = @()
        packageManifest = $null
        packageManifestSha256 = $null
    }
    if ($null -ne $snapshotValidation.Ai) {
        $aiRecord = [ordered]@{
            status = 'included-reviewed-bytes-only'
            included = $true
            aiOperationVerified = $false
            aiStartupTested = $false
            verified = $false
            payloadFileCount = [int]$aiFragment.AiPayloadCount
            payloadRelativePaths = @($aiFragment.AiPayload)
            packageManifest = $snapshotValidation.Ai.Sanitized.Manifest
            packageManifestSha256 = [string]$snapshotValidation.Ai.Sanitized.Sha256
        }
    }
    $receipt = [ordered]@{
        schemaVersion = 3
        version = $Version
        status = 'unverified-installer-candidate'
        builtAtUtc = [DateTime]::UtcNow.ToString('o')
        architecture = 'x64'
        sourceIdentity = $sourceAfterBuild
        source = [ordered]@{
            commit = [string]$sourceAfterBuild.repositoryHead
            treeDirty = [bool]$sourceAfterBuild.repositoryDirty
            dirtyEntryCount = @($sourceAfterBuild.repositoryStatusLines).Count
            mozcCommit = [string]$sourceAfterBuild.mozcCommit
            patches = @($sourceAfterBuild.patches)
        }
        runtimeManifest = [ordered]@{ sha256 = $runtimeManifestSha256; stagedStatus = 'staged-unverified-runtime-payload'; selfHashEmbedded = $false }
        runtimeManifestSha256 = $runtimeManifestSha256
        runtimeManifestSelfHashEmbedded = $false
        hostOverlayFingerprint = [string]$sourceAfterBuild.hostOverlayFingerprint
        buildConfiguration = $sourceAfterBuild.buildConfiguration
        immutableInput = [ordered]@{ id = $snapshot.Id; root = $snapshot.Root; postBuildRevalidated = $true; fileCount = $snapshotFiles.Count; helperSha256 = $snapshotValidation.HelperSha256; aiFileCount = [int]$aiFragment.AiPayloadCount; aiPostBuildRevalidated = ($null -ne $snapshotValidation.Ai) }
        host = [ordered]@{ os = [Environment]::OSVersion.VersionString; is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem; is64BitProcess = [Environment]::Is64BitProcess }
        installedInputVerified = $false
        localAiIncluded = [bool]$snapshotValidation.Ai
        aiOperationVerified = $false
        aiStartupTested = $false
        ai = $aiRecord
        signing = [ordered]@{ declared = $declaredSigning; msiAuthenticode = $msiSignature; setupAuthenticode = $setupSignature }
        wixVersion = $wixVersion
        productCode = [string]$msiProperties.ProductCode
        upgradeCode = [string]$msiProperties.UpgradeCode
        files = @($snapshotFiles)
        installerHelperSha256 = $snapshotValidation.HelperSha256
        msiSha256 = $msiSha256
        setupSha256 = $setupSha256
        verified = $false
        published = $true
        publication = 'unique-build-output-then-rollback-safe-known-artifact-replacement'
    }
    $receiptPath = Join-Path $buildOutput 'build-manifest.json'
    Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
    $artifactNames = @((Split-Path -Leaf $msi), (Split-Path -Leaf $setup), 'build-manifest.json')
    Publish-BuildOutput -BuildOutput $buildOutput -Output $output -ManagedRoot $snapshot.ManagedRoot -ArtifactNames $artifactNames
    $buildSucceeded = $true
    return [pscustomobject]@{ Setup = (Join-Path $output (Split-Path -Leaf $setup)); Msi = (Join-Path $output (Split-Path -Leaf $msi)); Manifest = (Join-Path $output 'build-manifest.json'); SourceCommit = [string]$sourceAfterBuild.repositoryHead; SourceTreeDirty = [bool]$sourceAfterBuild.repositoryDirty; Verified = $false; Published = $true; SnapshotId = $snapshot.Id; LocalAiIncluded = [bool]$snapshotValidation.Ai; AiOperationVerified = $false; AiStartupTested = $false; AiPayloadFileCount = [int]$aiFragment.AiPayloadCount }
}
finally {
    if ($ValidateOnly -and $null -ne $snapshot) { Remove-ManagedSnapshot $snapshot }
    elseif (-not $buildSucceeded -and $null -ne $buildOutput -and (Test-Path -LiteralPath $buildOutput)) {
        if (Test-PathWithin (Get-FullPath $buildOutput) (Get-FullPath $snapshot.ManagedRoot)) { Remove-Item -LiteralPath $buildOutput -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($buildSucceeded -and $null -ne $buildOutput -and (Test-Path -LiteralPath $buildOutput)) { Remove-Item -LiteralPath $buildOutput -Recurse -Force -ErrorAction SilentlyContinue }
}
