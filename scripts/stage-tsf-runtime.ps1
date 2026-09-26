# Package the reviewed KanaAI Windows runtime payload from the pinned Mozc build
# cache. This script only copies, validates, and hashes artifacts. It never
# builds, registers, installs, signs, downloads, or contacts a network service.
#
# The manifest deliberately does not contain its own SHA-256.  The staging
# result returns that hash separately; the installer records it in its own
# receipt.  This keeps the manifest self-hash out of the identity it describes.
[CmdletBinding()]
param(
    [string]$BazelOutputRoot = '',
    [string]$OutputDirectory = '',
    [string]$InstallerHelperDirectory = '',
    [string]$RedistDirectory = '',
    [string]$ManifestPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

# These are the reviewed patches which are applied by the pinned TSF build
# harness.  Do not silently replace this list with a directory enumeration: a
# release candidate must name every patch and bind its exact bytes.
$requiredPatchNames = @(
    '0001-install-kanai-supplemental-model.patch'
    '0002-kanai-tsf-identity.patch'
    '0003-session-generation-binding.patch'
    '0004-windows-python-toolchain.patch'
    '0005-windows-runtime-identity.patch'
    '0006-windows-installer-runtime-path.patch'
)
$mutationPrefixes = @('platform\windows-tsf\', 'scripts\', 'patches\')

# The exact files the MSI installs.  Candidates lists every Bazel output name
# that may hold the artifact; all candidates must be byte-identical so the
# selection stays deterministic.
$runtimeFiles = @(
    @{ Name = 'mozc_tip64.dll'; Machine = 0x8664; Type = 'Dll'; Candidates = @('mozc_tip64.dll'); Exports = @('DllGetClassObject', 'DllCanUnloadNow') },
    @{ Name = 'mozc_tip32.dll'; Machine = 0x014c; Type = 'Dll'; Candidates = @('mozc_tip32.dll'); Exports = @('DllGetClassObject', 'DllCanUnloadNow') },
    @{ Name = 'mozc_server.exe'; Machine = 0x8664; Type = 'Exe'; Candidates = @('mozc_server.exe', 'mozc_server.exe.exe', 'mozc_server_win.exe'); Exports = @() },
    @{ Name = 'mozc_renderer.exe'; Machine = 0x8664; Type = 'Exe'; Candidates = @('mozc_renderer.exe', 'mozc_renderer.exe.exe'); Exports = @() },
    @{ Name = 'mozc_broker.exe'; Machine = 0x8664; Type = 'Exe'; Candidates = @('mozc_broker.exe', 'mozc_broker.exe.exe'); Exports = @() }
)
$helperFile = @{
    Name = 'mozc_installer_helper.dll'
    Machine = 0x8664
    Type = 'Dll'
    Candidates = @('mozc_installer_helper.dll', 'mozc_installer_helper.dll.dll', 'custom_action.dll')
    Exports = @('RegisterTIP', 'RegisterTIPRollback', 'UnregisterTIP', 'UnregisterTIPRollback', 'EnableTipProfile', 'RestoreUserIMEEnvironment', 'ShutdownServer')
}
# Import closure of the payload: msvcp140.dll itself imports only
# vcruntime140.dll/vcruntime140_1.dll, and the TIP DLLs use the static CRT.
$redistFiles = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$noticeFiles = @(
    @{ Name = 'LICENSE.txt'; Source = (Join-Path $repository 'LICENSE') },
    @{ Name = 'MOZC-LICENSE.txt'; Source = (Join-Path $repository 'third_party\mozc\LICENSE') },
    @{ Name = 'credits_en.html'; Source = (Join-Path $repository 'third_party\mozc\src\data\installer\credits_en.html') },
    @{ Name = 'README.txt'; Source = (Join-Path $repository 'platform\windows-tsf\installer\package\PACKAGE_README.txt') }
)

function Get-FullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is not allowed.' }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([char[]]'\/')
    }
    return $full
}

function Test-PathWithin([string]$Path, [string]$Root) {
    $pathFull = Get-FullPath $Path
    $rootFull = Get-FullPath $Root
    if ($pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

# Reject a reparse point at the supplied path or at any existing ancestor.  A
# normal missing leaf is allowed for caller-selected output directories, but a
# missing component cannot have a reparse descendant.
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
    $parts = @($remainder -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($part in $parts) {
        $current = Join-Path $current $part
        $item = $null
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        }
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
    if ($PathType -eq 'Leaf' -and
        -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Expected a file: $full"
    }
    if ($PathType -eq 'Container' -and
        -not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "Expected a directory: $full"
    }
    return $full
}

function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-TextSha256([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $sha256.Dispose()
    }
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
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-GitCapture([string[]]$Arguments) {
    $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) { throw 'git is required to identify the staged source.' }
    $lines = @(& $git.Path -c 'core.safecrlf=false' @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode"
    }
    return (($lines | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-RepositoryMutationFingerprint([string]$RepositoryRoot, [string[]]$StatusLines) {
    # HEAD identifies committed source.  For a dirty tree, hash the actual
    # changed/untracked file bytes as well, so a same-status content mutation
    # cannot pass unnoticed.  The path set is intentionally obtained from Git
    # rather than from the manifest supplied by a caller.
    $paths = @()
    try {
        $diffPaths = @(Invoke-GitCapture @('-C', $RepositoryRoot, 'diff', '--name-only', 'HEAD', '--') -split "`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $untrackedPaths = @(Invoke-GitCapture @('-C', $RepositoryRoot, 'ls-files', '--others', '--exclude-standard') -split "`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $relevantUntracked = @($untrackedPaths | Where-Object {
            $candidate = ([string]$_).Trim().Replace('/', '\')
            ($candidate -ieq 'LICENSE') -or @($mutationPrefixes | Where-Object { $candidate.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        })
        $paths = @($diffPaths + $relevantUntracked | ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique -CaseSensitive)
        [string[]]$orderedPaths = @($paths)
        [Array]::Sort($orderedPaths, [System.StringComparer]::Ordinal)
        $paths = @($orderedPaths)
    }
    catch {
        throw "Unable to fingerprint repository mutations: $($_.Exception.Message)"
    }

    $records = @()
    foreach ($relative in $paths) {
        $relative = $relative.Replace('/', '\')
        $isRelevant = ($relative -ieq 'LICENSE') -or @($mutationPrefixes | Where-Object { $relative.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $isRelevant) { continue }
        $full = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relative))
        if (-not (Test-PathWithin $full $RepositoryRoot)) {
            throw "Git returned a path outside the repository: $relative"
        }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            Assert-NoReparsePath -Path $full
            $item = Get-Item -LiteralPath $full -Force
            $records += ($relative + '|file|' + [string]$item.Length + '|' + (Get-Sha256 -Path $full))
        }
        elseif (Test-Path -LiteralPath $full -PathType Container) {
            $records += ($relative + '|directory')
        }
        else {
            $records += ($relative + '|missing')
        }
    }
    $text = "status`n" + (($StatusLines | ForEach-Object { [string]$_ }) -join "`n") + "`nfiles`n" + ($records -join "`n")
    return Get-TextSha256 $text
}

function Get-OverlayIdentity([string]$RepositoryRoot) {
    $overlayRoot = Join-Path $RepositoryRoot 'platform\windows-tsf\tsf\host_overlay'
    $result = [ordered]@{
        status = 'unverified'
        root = $overlayRoot
        fingerprint = $null
        fileCount = 0
        files = @()
        reason = ''
    }
    try {
        Assert-NoReparsePath -Path $overlayRoot
        if (-not (Test-Path -LiteralPath $overlayRoot -PathType Container)) {
            $result.reason = 'host overlay directory is unavailable'
            return [pscustomobject]$result
        }
        $rootFull = Get-FullPath $overlayRoot
        $stack = New-Object System.Collections.Stack
        $stack.Push($rootFull)
        $records = @()
        while ($stack.Count -gt 0) {
            $directory = [string]$stack.Pop()
            foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Reparse point in host overlay is not allowed: $($item.FullName)"
                }
                if ($item.PSIsContainer) {
                    $stack.Push($item.FullName)
                }
                else {
                    $relative = $item.FullName.Substring($rootFull.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
                    $records += [pscustomobject]@{
                        Path = $relative
                        Bytes = [int64]$item.Length
                        Sha256 = Get-Sha256 -Path $item.FullName
                    }
                }
            }
        }
        $byPath = @{}
        foreach ($record in $records) { $byPath[[string]$record.Path] = $record }
        $orderedPaths = @(Sort-OrdinalStrings ([string[]]@($records | ForEach-Object { [string]$_.Path })))
        $records = @($orderedPaths | ForEach-Object { $byPath[[string]$_] })
        if ($records.Count -eq 0) { throw 'host overlay contains no files' }
        $fingerprintText = ($records | ForEach-Object {
            ([string]$_.Path) + '|' + ([string]$_.Bytes) + '|' + ([string]$_.Sha256)
        }) -join "`n"
        $result.status = 'verified'
        $result.root = $rootFull
        $result.fingerprint = Get-TextSha256 $fingerprintText
        $result.fileCount = $records.Count
        $result.files = @($records | ForEach-Object {
            [ordered]@{ path = [string]$_.Path; bytes = [int64]$_.Bytes; sha256 = [string]$_.Sha256 }
        })
    }
    catch {
        $result.status = 'unverified'
        $result.reason = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Get-PatchIdentity([string]$RepositoryRoot) {
    $patchRoot = Join-Path $RepositoryRoot 'platform\windows-tsf\tsf\patches'
    $result = [ordered]@{
        status = 'unverified'
        root = $patchRoot
        requiredNames = @($requiredPatchNames)
        records = @()
        reason = ''
    }
    try {
        Assert-NoReparsePath -Path $patchRoot
        if (-not (Test-Path -LiteralPath $patchRoot -PathType Container)) {
            $result.reason = 'patch directory is unavailable'
            return [pscustomobject]$result
        }
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
            $records += [ordered]@{
                name = $name
                bytes = [int64]$item.Length
                sha256 = Get-Sha256 -Path $path
                required = $true
            }
        }
        $result.status = 'verified'
        $result.root = Get-FullPath $patchRoot
        $result.records = @($records | ForEach-Object { [pscustomobject]$_ })
    }
    catch {
        $result.status = 'unverified'
        $result.reason = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Get-BuildConfigurationIdentity([string]$RepositoryRoot) {
    $path = Join-Path $RepositoryRoot 'platform\windows-tsf\build\toolchain.json'
    $result = [ordered]@{
        status = 'unverified'
        path = $path
        sha256 = $null
        schemaVersion = $null
        platform = $null
        architecture = $null
        target = $null
        configuration = $null
        generator = $null
        bazelVersion = $null
        releaseConfig = $null
        msvcConfig = $null
        msvcToolchain = $null
        reason = ''
    }
    try {
        Assert-NoReparsePath -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $result.reason = 'pinned toolchain configuration is unavailable'
            return [pscustomobject]$result
        }
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
        if ($null -eq $result.schemaVersion -or [string]::IsNullOrWhiteSpace([string]$result.platform) -or
            [string]::IsNullOrWhiteSpace([string]$result.architecture) -or
            [string]::IsNullOrWhiteSpace([string]$result.target) -or
            [string]::IsNullOrWhiteSpace([string]$result.configuration) -or
            [string]::IsNullOrWhiteSpace([string]$result.bazelVersion)) {
            $result.reason = 'pinned toolchain configuration is incomplete'
            return [pscustomobject]$result
        }
        $result.status = 'verified'
    }
    catch {
        $result.status = 'unverified'
        $result.reason = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Get-BuildInputIdentity([string]$RepositoryRoot) {
    $relativePaths = @(
        'platform\windows-tsf\installer\package\KanaAI.wxs'
        'platform\windows-tsf\installer\package\Setup.cs'
        'platform\windows-tsf\installer\package\Setup.manifest'
        'platform\windows-tsf\build\toolchain.json'
        'scripts\stage-tsf-runtime.ps1'
        'scripts\build-windows-installer.ps1'
    )
    $records = @()
    $status = 'verified'
    $reason = ''
    try {
        foreach ($relative in $relativePaths) {
            $path = Join-Path $RepositoryRoot $relative
            Assert-NoReparsePath -Path $path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $status = 'unverified'
                $reason = "build input is unavailable: $relative"
                continue
            }
            $item = Get-Item -LiteralPath $path -Force
            $records += [ordered]@{ path = $relative.Replace('\', '/'); bytes = [int64]$item.Length; sha256 = Get-Sha256 -Path $path }
        }
    }
    catch {
        $status = 'unverified'
        $reason = $_.Exception.Message
    }
    $fingerprint = if ($records.Count -eq $relativePaths.Count) {
        Get-TextSha256 (($records | ForEach-Object { ([string]$_.path) + '|' + ([string]$_.bytes) + '|' + ([string]$_.sha256) }) -join "`n")
    } else { $null }
    return [pscustomobject]@{
        status = $status
        records = @($records | ForEach-Object { [pscustomobject]$_ })
        fingerprint = $fingerprint
        reason = $reason
    }
}

function Get-SourceIdentity([string]$RepositoryRoot) {
    $reasons = @()
    $head = $null
    $statusLines = @()
    $repositoryStatusAvailable = $false
    $statusFingerprint = $null
    $mutationFingerprint = $null
    $mozc = [ordered]@{ status = 'unverified'; gitlink = $null; commit = $null; clean = $null; reason = '' }
    $patchIdentity = $null
    $overlayIdentity = $null
    $buildConfiguration = $null
    $buildInputs = $null

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
    catch {
        $reasons += $_.Exception.Message
    }

    try {
        $gitlink = Invoke-GitCapture @('-C', $RepositoryRoot, 'rev-parse', 'HEAD:third_party/mozc')
        $commit = Invoke-GitCapture @('-C', (Join-Path $RepositoryRoot 'third_party\mozc'), 'rev-parse', 'HEAD')
        $subStatusText = Invoke-GitCapture @('-C', (Join-Path $RepositoryRoot 'third_party\mozc'), 'status', '--porcelain=v1', '--untracked-files=normal')
        $subStatus = [string]::IsNullOrWhiteSpace($subStatusText)
        if ($gitlink -notmatch '^[0-9a-fA-F]{40}$' -or $commit -notmatch '^[0-9a-fA-F]{40}$' -or $gitlink -ne $commit) {
            throw "Mozc gitlink/commit is not an exact pinned pair (gitlink=$gitlink commit=$commit)."
        }
        $mozc.status = 'verified'
        $mozc.gitlink = $gitlink.ToLowerInvariant()
        $mozc.commit = $commit.ToLowerInvariant()
        $mozc.clean = $subStatus
    }
    catch {
        $mozc.reason = $_.Exception.Message
        $reasons += $mozc.reason
    }

    $patchIdentity = Get-PatchIdentity -RepositoryRoot $RepositoryRoot
    if ($patchIdentity.status -ne 'verified') { $reasons += [string]$patchIdentity.reason }
    $overlayIdentity = Get-OverlayIdentity -RepositoryRoot $RepositoryRoot
    if ($overlayIdentity.status -ne 'verified') { $reasons += [string]$overlayIdentity.reason }
    $buildConfiguration = Get-BuildConfigurationIdentity -RepositoryRoot $RepositoryRoot
    if ($buildConfiguration.status -ne 'verified') { $reasons += [string]$buildConfiguration.reason }
    $buildInputs = Get-BuildInputIdentity -RepositoryRoot $RepositoryRoot
    if ($buildInputs.status -ne 'verified') { $reasons += [string]$buildInputs.reason }

    $dirty = if ($repositoryStatusAvailable) { (@($statusLines).Count -gt 0) -or ($mozc.status -eq 'verified' -and -not [bool]$mozc.clean) } else { $null }
    $overall = if ($reasons.Count -eq 0) {
        if ($dirty) { 'verified-dirty' } else { 'verified' }
    } else { 'unverified' }
    $patchRecords = if ($null -ne $patchIdentity) { @($patchIdentity.records) } else { @() }
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
        patches = @($patchRecords)
        patchSetSha256 = if ($patchIdentity.status -eq 'verified') { Get-ObjectFingerprint $patchRecords } else { $null }
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

# Read a bounded little-endian value from a byte array.  Keeping all bounds
# checks here makes malformed/truncated synthetic and real files fail closed.
function Read-ExactBytes([byte[]]$Bytes, [int]$Offset, [int]$Count, [string]$Description) {
    if ($Offset -lt 0 -or $Count -lt 0 -or $Offset -gt $Bytes.Length - $Count) {
        throw "Truncated PE $Description at offset $Offset (requested $Count bytes)."
    }
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
        $sectionStart = [uint64]$section.VirtualAddress
        $sectionEnd = $sectionStart + $span
        if ([uint64]$Rva -ge $sectionStart -and [uint64]$Rva -lt $sectionEnd) {
            $delta = [uint64]$Rva - $sectionStart
            if ($delta -ge [uint64]$section.RawSize) {
                throw "PE RVA points into uninitialized section data: 0x{0:X8}" -f $Rva
            }
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
    if ($functionCount -eq 0 -or $functionCount -gt 65535 -or $nameCount -gt 65535 -or $nameCount -gt $functionCount) {
        throw "PE export table has invalid counts: $($Image.Path)"
    }
    $functionOffset = Convert-RvaToFileOffset $Image $functionsRva
    $namesOffset = Convert-RvaToFileOffset $Image $namesRva
    $ordinalsOffset = Convert-RvaToFileOffset $Image $ordinalsRva
    [void](Read-ExactBytes $Image.Bytes $functionOffset ([int]($functionCount * 4)) 'export function table')
    [void](Read-ExactBytes $Image.Bytes $namesOffset ([int]($nameCount * 4)) 'export name table')
    [void](Read-ExactBytes $Image.Bytes $ordinalsOffset ([int]($nameCount * 2)) 'export ordinal table')
    $names = @()
    for ($index = 0; $index -lt $nameCount; $index++) {
        $ordinalBytes = Read-ExactBytes $Image.Bytes ($ordinalsOffset + ($index * 2)) 2 'export ordinal'
        $ordinal = [BitConverter]::ToUInt16($ordinalBytes, 0)
        if ($ordinal -ge $functionCount) { throw "PE export ordinal is outside the function table: $($Image.Path)" }
        $namePointerBytes = Read-ExactBytes $Image.Bytes ($namesOffset + ($index * 4)) 4 'export name pointer'
        $nameRva = [BitConverter]::ToUInt32($namePointerBytes, 0)
        $nameOffset = Convert-RvaToFileOffset $Image $nameRva
        $end = $nameOffset
        while ($end -lt $Image.Bytes.Length -and $Image.Bytes[$end] -ne 0) { $end++ }
        if ($end -ge $Image.Bytes.Length -or $end -le $nameOffset -or ($end - $nameOffset) -gt 4096) {
            throw "PE export name is truncated or empty: $($Image.Path)"
        }
        $names += [System.Text.Encoding]::ASCII.GetString($Image.Bytes, $nameOffset, $end - $nameOffset)
    }
    return @($names)
}

function Get-PeImage([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "PE image is missing: $Path" }
    Assert-NoReparsePath -Path $Path
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64) { throw "Truncated PE DOS header: $Path" }
    if ($bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "Invalid PE DOS magic (MZ signature missing): $Path" }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($peOffset -lt 64 -or $peOffset -gt $bytes.Length - 24) { throw "Truncated or invalid PE NT header offset: $Path" }
    $coff = Read-ExactBytes $bytes $peOffset 24 'COFF header'
    if ($coff[0] -ne 0x50 -or $coff[1] -ne 0x45 -or $coff[2] -ne 0 -or $coff[3] -ne 0) {
        throw "Invalid PE signature: $Path"
    }
    $machine = [BitConverter]::ToUInt16($coff, 4)
    $sectionCount = [BitConverter]::ToUInt16($coff, 6)
    $optionalSize = [BitConverter]::ToUInt16($coff, 20)
    $characteristics = [BitConverter]::ToUInt16($coff, 22)
    if ($sectionCount -eq 0 -or $sectionCount -gt 96) { throw "Invalid PE section count: $Path" }
    if ($optionalSize -lt 2) { throw "Truncated PE optional header: $Path" }
    $optionalOffset = $peOffset + 24
    $optional = Read-ExactBytes $bytes $optionalOffset $optionalSize 'optional header'
    $magic = [BitConverter]::ToUInt16($optional, 0)
    if ($magic -eq 0x20b) {
        if ($optionalSize -lt 112) { throw "Truncated PE32+ optional header: $Path" }
    }
    elseif ($magic -eq 0x10b) {
        if ($optionalSize -lt 96) { throw "Truncated PE32 optional header: $Path" }
    }
    else {
        throw ("Unsupported PE optional-header magic 0x{0:X4}: {1}" -f $magic, $Path)
    }
    $sizeOfHeaders = [BitConverter]::ToUInt32($optional, 60)
    $sectionTableOffset = $optionalOffset + $optionalSize
    $sectionTableBytes = [int64]$sectionCount * 40
    if ($sectionTableOffset -gt $bytes.Length - $sectionTableBytes) {
        throw "Truncated PE section table: $Path"
    }
    if ($sizeOfHeaders -lt [uint32]($sectionTableOffset + $sectionTableBytes) -or $sizeOfHeaders -gt [uint32]$bytes.Length) {
        throw "PE SizeOfHeaders is outside the file: $Path"
    }
    $sections = @()
    for ($index = 0; $index -lt $sectionCount; $index++) {
        $entryOffset = $sectionTableOffset + ($index * 40)
        $entry = Read-ExactBytes $bytes $entryOffset 40 'section table'
        $name = [System.Text.Encoding]::ASCII.GetString($entry, 0, 8).Trim([char]0)
        $virtualSize = [BitConverter]::ToUInt32($entry, 8)
        $virtualAddress = [BitConverter]::ToUInt32($entry, 12)
        $rawSize = [BitConverter]::ToUInt32($entry, 16)
        $rawPointer = [BitConverter]::ToUInt32($entry, 20)
        if ($rawSize -gt 0 -and ([uint64]$rawPointer + [uint64]$rawSize) -gt [uint64]$bytes.Length) {
            throw "PE section raw data is outside the file: $Path ($name)"
        }
        if ($rawSize -eq 0 -and $rawPointer -gt [uint32]$bytes.Length) {
            throw "PE zero-size section pointer is outside the file: $Path ($name)"
        }
        $sections += [pscustomobject]@{
            Name = $name
            VirtualSize = $virtualSize
            VirtualAddress = $virtualAddress
            RawSize = $rawSize
            RawPointer = $rawPointer
        }
    }
    $exportRva = [uint32]0
    $exportSize = [uint32]0
    $directoryOffsetInOptional = if ($magic -eq 0x20b) { 112 } else { 96 }
    if ($optionalSize -ge ($directoryOffsetInOptional + 8)) {
        $exportRva = [BitConverter]::ToUInt32($optional, $directoryOffsetInOptional)
        $exportSize = [BitConverter]::ToUInt32($optional, $directoryOffsetInOptional + 4)
    }
    return [pscustomobject]@{
        Path = [System.IO.Path]::GetFullPath($Path)
        Bytes = $bytes
        Machine = $machine
        MachineName = ('0x{0:X4}' -f $machine)
        Characteristics = $characteristics
        IsDll = (($characteristics -band 0x2000) -ne 0)
        IsExe = (($characteristics -band 0x0002) -ne 0 -and ($characteristics -band 0x2000) -eq 0)
        OptionalMagic = $magic
        OptionalMagicHex = ('0x{0:X4}' -f $magic)
        SizeOfHeaders = $sizeOfHeaders
        ExportRva = $exportRva
        ExportSize = $exportSize
        Sections = @($sections)
    }
}

function Assert-Pe([string]$Path, [int]$Machine, [string]$Type, [string[]]$Exports) {
    $image = Get-PeImage $Path
    if ($image.Machine -ne $Machine) {
        throw ("PE architecture mismatch: {0} is {1}, expected 0x{2:X4}" -f (Split-Path -Leaf $Path), $image.MachineName, $Machine)
    }
    $expectedMagic = if ($Machine -eq 0x8664) { 0x20b } elseif ($Machine -eq 0x014c) { 0x10b } else { 0 }
    if ($expectedMagic -ne 0 -and $image.OptionalMagic -ne $expectedMagic) {
        throw ("PE optional-header architecture mismatch: {0} is {1}, expected 0x{2:X4}" -f (Split-Path -Leaf $Path), $image.OptionalMagicHex, $expectedMagic)
    }
    if ($Type -eq 'Dll' -and -not $image.IsDll) {
        throw "PE DLL/EXE mismatch: $(Split-Path -Leaf $Path) is not marked IMAGE_FILE_DLL."
    }
    if ($Type -eq 'Exe' -and -not $image.IsExe) {
        throw "PE DLL/EXE mismatch: $(Split-Path -Leaf $Path) is not a non-DLL executable."
    }
    if ($Exports.Count -gt 0) {
        $actual = @(Get-PeExports $image)
        $missing = @($Exports | Where-Object { $actual -cnotcontains $_ })
        if ($missing.Count -gt 0) {
            throw ("Missing required export(s) {0} in {1}; found: {2}" -f ($missing -join ', '), (Split-Path -Leaf $Path), ($actual -join ', '))
        }
    }
    return $image
}

function Get-SafeFilesUnderRoot([string]$Root) {
    Assert-NoReparsePath -Path $Root
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Artifact root is missing: $Root" }
    $rootFull = Get-FullPath $Root
    $stack = New-Object System.Collections.Stack
    $stack.Push($rootFull)
    $files = @()
    while ($stack.Count -gt 0) {
        $directory = [string]$stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point in artifact root is not allowed: $($item.FullName)"
            }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) } else { $files += $item }
        }
    }
    return @($files | Sort-Object FullName)
}

function Resolve-BazelArtifact([hashtable]$Spec, [string]$Root) {
    $resolvedRoot = Get-ExistingPath $Root ('Container')
    $matches = @()
    foreach ($file in @(Get-SafeFilesUnderRoot $resolvedRoot)) {
        if ($Spec.Candidates -contains $file.Name) { $matches += $file.FullName }
    }
    $matches = @($matches | Sort-Object -Unique)
    if (-not $matches.Count) {
        throw ("Missing build artifact '{0}'. Looked for: {1} under {2}" -f $Spec.Name, ($Spec.Candidates -join ', '), $resolvedRoot)
    }
    $hashes = @($matches | ForEach-Object { Get-Sha256 -Path $_ } | Sort-Object -Unique)
    if ($hashes.Count -ne 1) {
        throw ("Ambiguous build artifact '{0}': {1} distinct contents. Rebuild cleanly instead of guessing." -f $Spec.Name, $hashes.Count)
    }
    return $matches[0]
}

function Resolve-RedistDirectory([string]$Requested) {
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        return Get-ExistingPath $Requested ('Container')
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'vswhere.exe was not found; pass -RedistDirectory explicitly.' }
    $installation = (& $vswhere -latest -products '*' -property installationPath | Out-String).Trim()
    if (-not $installation) { throw 'Visual Studio was not found; pass -RedistDirectory explicitly.' }
    $root = Join-Path $installation 'VC\Redist\MSVC'
    Assert-NoReparsePath -Path $root
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Visual C++ redistributable root was not found: $root" }
    $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Microsoft.VC*.CRT' -and $_.Parent.Name -eq 'x64' } |
        Sort-Object { [version]$_.Parent.Parent.Name } -Descending)
    if (-not $candidates.Count) { throw 'No x64 Microsoft.VC*.CRT redistributable directory was found.' }
    return Get-ExistingPath $candidates[0].FullName ('Container')
}

function Get-ManifestRecord([string]$Path, [string]$Name, [string]$Kind, [int]$Machine, [string[]]$Exports) {
    $item = Get-Item -LiteralPath $Path -Force
    return [pscustomobject]@{
        Name = $Name
        Bytes = [int64]$item.Length
        Sha256 = Get-Sha256 -Path $Path
        Machine = ('0x{0:x4}' -f $Machine)
        Type = $Kind
        Exports = @($Exports)
        Source = $item.FullName
    }
}

if (-not $BazelOutputRoot) {
    $BazelOutputRoot = Join-Path $env:LOCALAPPDATA 'KanaAI\tsf-build-cache\bazel-output-user-root\jbhltpfs\execroot\_main\bazel-out'
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repository '.local\tsf-runtime' }
if (-not $InstallerHelperDirectory) { $InstallerHelperDirectory = Join-Path $repository '.local\tsf-installer-helper' }
if (-not $ManifestPath) { $ManifestPath = Join-Path $repository '.local\tsf-runtime-manifest.json' }

$output = Get-FullPath $OutputDirectory
$helperOutput = Get-FullPath $InstallerHelperDirectory
$manifestPath = Get-FullPath $ManifestPath
Assert-NoReparsePath -Path $manifestPath -AllowMissing
$localRoot = Get-FullPath (Join-Path $repository '.local')
$localPrefix = $localRoot + [System.IO.Path]::DirectorySeparatorChar
foreach ($destinationRoot in @($output, $helperOutput)) {
    Assert-NoReparsePath -Path $destinationRoot -AllowMissing
    if (-not $destinationRoot.StartsWith($localPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Staging output must be a dedicated directory below $localRoot"
    }
}
if ($output -ieq $helperOutput -or
    $output.StartsWith($helperOutput + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
    $helperOutput.StartsWith($output + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Runtime and helper staging directories must not overlap.'
}
if (Test-PathWithin $manifestPath $output -or Test-PathWithin $manifestPath $helperOutput) {
    throw 'The manifest must be outside the staged payload and helper directories.'
}
Assert-NoReparsePath -Path $repository

# Replace only explicitly managed files; never recursively delete caller paths.
$allowedRuntime = @($runtimeFiles | ForEach-Object { $_.Name }) + $redistFiles + @($noticeFiles | ForEach-Object { $_.Name })
foreach ($destinationRoot in @($output, $helperOutput)) {
    if (Test-Path -LiteralPath $destinationRoot) {
        Assert-NoReparsePath -Path $destinationRoot
        $allowed = if ($destinationRoot -eq $output) { $allowedRuntime } else { @($helperFile.Name) }
        foreach ($existing in @(Get-ChildItem -LiteralPath $destinationRoot -Force)) {
            if ($existing.PSIsContainer -or $allowed -notcontains $existing.Name -or
                ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Unmanaged staging entry: $($existing.FullName)"
            }
        }
    }
    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    Assert-NoReparsePath -Path $destinationRoot
}

$sourceIdentityBefore = Get-SourceIdentity -RepositoryRoot $repository
$records = @()
foreach ($spec in $runtimeFiles) {
    $source = Resolve-BazelArtifact -Spec $spec -Root $BazelOutputRoot
    [void](Assert-Pe -Path $source -Machine $spec.Machine -Type $spec.Type -Exports $spec.Exports)
    $destination = Join-Path $output $spec.Name
    Copy-Item -LiteralPath $source -Destination $destination -Force
    [void](Assert-Pe -Path $destination -Machine $spec.Machine -Type $spec.Type -Exports $spec.Exports)
    $records += Get-ManifestRecord -Path $destination -Name $spec.Name -Kind $spec.Type -Machine $spec.Machine -Exports $spec.Exports
}
$helperSource = Resolve-BazelArtifact -Spec $helperFile -Root $BazelOutputRoot
[void](Assert-Pe -Path $helperSource -Machine $helperFile.Machine -Type $helperFile.Type -Exports $helperFile.Exports)
$helperDestination = Join-Path $helperOutput $helperFile.Name
Copy-Item -LiteralPath $helperSource -Destination $helperDestination -Force
[void](Assert-Pe -Path $helperDestination -Machine $helperFile.Machine -Type $helperFile.Type -Exports $helperFile.Exports)
$helperRecord = Get-ManifestRecord -Path $helperDestination -Name $helperFile.Name -Kind $helperFile.Type -Machine $helperFile.Machine -Exports $helperFile.Exports

$redist = Resolve-RedistDirectory $RedistDirectory
foreach ($name in $redistFiles) {
    $source = Join-Path $redist $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing Visual C++ redistributable file: $source" }
    [void](Assert-Pe -Path $source -Machine 0x8664 -Type 'Dll' -Exports @())
    $destination = Join-Path $output $name
    Copy-Item -LiteralPath $source -Destination $destination -Force
    [void](Assert-Pe -Path $destination -Machine 0x8664 -Type 'Dll' -Exports @())
    $records += Get-ManifestRecord -Path $destination -Name $name -Kind 'Dll' -Machine 0x8664 -Exports @()
}
foreach ($notice in $noticeFiles) {
    if (-not (Test-Path -LiteralPath $notice.Source -PathType Leaf)) { throw "Missing notice source: $($notice.Source)" }
    Assert-NoReparsePath -Path $notice.Source
    $destination = Join-Path $output $notice.Name
    Copy-Item -LiteralPath $notice.Source -Destination $destination -Force
    $records += Get-ManifestRecord -Path $destination -Name $notice.Name -Kind 'Notice' -Machine 0 -Exports @()
}

$sourceIdentityAfter = Get-SourceIdentity -RepositoryRoot $repository
if ((Get-ObjectFingerprint $sourceIdentityBefore) -ne (Get-ObjectFingerprint $sourceIdentityAfter)) {
    throw 'Repository, patch, overlay, or build configuration changed while staging; discard the staged payload.'
}

# The manifest is intentionally not stamped with its own digest.  Consumers
# hash this exact file and place that digest in a separate build receipt.
$manifest = [ordered]@{
    schemaVersion    = 2
    status           = 'staged-unverified-runtime-payload'
    payloadDirectory = $output
    helperDirectory  = $helperOutput
    helper           = $helperRecord
    redistDirectory  = $redist
    bazelOutputRoot  = (Get-ExistingPath $BazelOutputRoot ('Container'))
    sourceIdentity   = $sourceIdentityAfter
    buildInputs      = $sourceIdentityAfter.buildInputs
    files            = @($records | Sort-Object -Property Name)
}
Write-Utf8NoBom -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$manifestSha256 = Get-Sha256 -Path $manifestPath

[pscustomobject]@{
    PayloadDirectory = $output
    HelperPath       = $helperDestination
    ManifestPath     = $manifestPath
    ManifestSha256   = $manifestSha256
    SourceIdentity   = $sourceIdentityAfter
    BuildInputs      = $sourceIdentityAfter.buildInputs
    FileCount        = $records.Count
    Files            = @($records | Sort-Object -Property Name | ForEach-Object { $_.Name })
}
