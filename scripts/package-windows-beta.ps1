# Packages the KanaAI Windows Workbench/CLI phase-1 beta as a portable ZIP.
#
# This is intentionally an unsigned package contract.  It does not create an
# installer, register a TSF TIP, certify a runtime, or make an executable
# trusted.  File presence is recorded separately from readiness: packaging
# never sets conversionReady or runtimeVerified merely because a file exists.
#
# -AllowIncomplete is an explicit scaffold mode.  It still requires a
# deterministic SOURCE_DATE_EPOCH and still emits an exact file manifest.

[CmdletBinding()]
param(
    [string]$PayloadRoot = '',
    [string]$OutputDirectory = '',
    [string]$Version = '',
    [string]$Target = 'x86_64-pc-windows-msvc',
    [string]$Architecture = 'x64',
    [string]$SourceRevision = '',
    [string]$SourceDateEpoch = '',
    [string]$ApiExecutable = '',
    [string]$CliExecutable = '',
    [string]$MozcBridgeExecutable = '',
    [string]$WebRoot = '',
    [string]$ShellExecutable = '',
    [switch]$AllowIncomplete,
    [switch]$Force,
    [switch]$NoArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptNames = @(
    'Install-KanaAI.ps1',
    'Uninstall-KanaAI.ps1',
    'Start-KanaAI.ps1',
    'Stop-KanaAI.ps1',
    'Run-KanaAI-Cli.ps1',
    'Verify-KanaAI.ps1'
)
$fixedPackageFiles = @(
    'BETA-NOTICE.txt',
    'THIRD-PARTY-NOTICES.txt',
    'VERSION.txt',
    'config/kanai.env.example',
    'config/bridge-contract.json'
)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd([char[]]'\/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $prefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the package root: $Path"
    }
    return $pathFull.Substring($prefix.Length).Replace('\', '/')
}

function Assert-SafeRelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.StartsWith('/') -or
        $RelativePath.StartsWith('\') -or
        $RelativePath -match '[:*?<>|]' -or
        $RelativePath -match '(^|/)\.\.(/|$)' -or
        $RelativePath -match '(^|/)\.(/|$)' -or
        $RelativePath.Contains('//')) {
        throw "Unsafe package path: $RelativePath"
    }
}

function Get-PathComparisonString {
    param([Parameter(Mandatory = $true)][string]$Path)
    return ([string]$Path).Replace('\', '/').ToLowerInvariant()
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

function Assert-NotNestedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd([char[]]'\/')
    $childFull = [System.IO.Path]::GetFullPath($Child).TrimEnd([char[]]'\/')
    $parentPrefix = $parentFull + [System.IO.Path]::DirectorySeparatorChar
    $childPrefix = $childFull + [System.IO.Path]::DirectorySeparatorChar
    if ($parentFull -ieq $childFull -or
        $childFull.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $parentFull.StartsWith($childPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must not contain or be contained by the other path: $parentFull / $childFull"
    }
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

function Assert-NoForbiddenFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $reparsePoints = @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Where-Object {
        ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    })
    if ($reparsePoints.Count -gt 0) {
        throw "Reparse points are not allowed in a portable payload: $($reparsePoints[0].FullName)"
    }
    $forbidden = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Where-Object {
        $_.Name -eq '.env' -or
        $_.Name -eq '.DS_Store' -or
        $_.Name -eq 'Thumbs.db' -or
        $_.Name -like '*.log' -or
        $_.FullName -match '[\\/]node_modules[\\/]' -or
        $_.FullName -match '[\\/]\.git[\\/]' -or
        $_.FullName -match '[\\/]target[\\/]' -or
        $_.FullName -match '[\\/]\.local[\\/]'
    })
    if ($forbidden.Count -gt 0) {
        throw "The payload contains a forbidden developer/runtime file: $($forbidden[0].FullName)"
    }
}

function Get-AllFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File)
    return @($files | Sort-Object -Property @{
        Expression = {
            (Get-RelativePath -BasePath $Root -Path $_.FullName).ToLowerInvariant()
        }
    })
}

function Get-PayloadFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $files = @(Get-AllFiles -Root $Root | Where-Object {
        $_.Name -notin @('manifest.json', 'SHA256SUMS')
    })
    return $files
}

function Get-ChecksumFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $files = @(Get-AllFiles -Root $Root | Where-Object {
        $_.Name -ine 'SHA256SUMS'
    })
    return $files
}

function Get-Hash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextHash {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-NormalizedPathSet {
    param([string[]]$Paths)

    return @($Paths | ForEach-Object { ([string]$_).Replace('\', '/').ToLowerInvariant() } | Sort-Object)
}

function Assert-ExactPathSet {
    param(
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $expectedNormalized = Get-NormalizedPathSet -Paths $Expected
    $actualNormalized = Get-NormalizedPathSet -Paths $Actual
    if ($expectedNormalized.Count -ne $actualNormalized.Count) {
        throw "$Description count differs (expected $($expectedNormalized.Count), found $($actualNormalized.Count))."
    }
    for ($index = 0; $index -lt $expectedNormalized.Count; $index++) {
        if ($expectedNormalized[$index] -cne $actualNormalized[$index]) {
            throw "$Description differs at sorted path $index (expected $($expectedNormalized[$index]), found $($actualNormalized[$index]))."
        }
    }
}

function Assert-AllowedPayloadPath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [switch]$PackageRoot
    )

    Assert-SafeRelativePath -RelativePath $RelativePath
    if ($PackageRoot) {
        if ($RelativePath -in @('manifest.json', 'SHA256SUMS', 'VERSION.txt', 'BETA-NOTICE.txt', 'THIRD-PARTY-NOTICES.txt', '.build-inputs.json')) {
            return
        }
        foreach ($name in $scriptNames) {
            if ($RelativePath -ieq $name) {
                return
            }
        }
        if ($RelativePath -match '^bin/(kanai-api\.exe|kanai\.exe|kanai-mozc-bridge\.exe|kanai-windows-shell\.exe)$') {
            return
        }
        if ($RelativePath -match '^config/(kanai\.env\.example|bridge-contract\.json)$') {
            return
        }
        if ($RelativePath -match '^dist/.+') {
            return
        }
        if ($RelativePath -match '^legal/.+') {
            return
        }
        throw "File is not in the reviewed Windows beta package file set: $RelativePath"
    }

    if ($RelativePath -ieq '.build-inputs.json' -or
        $RelativePath -match '^bin/(kanai-api\.exe|kanai\.exe|kanai-mozc-bridge\.exe|kanai-windows-shell\.exe)$' -or
        $RelativePath -match '^config/(kanai\.env\.example|bridge-contract\.json)$' -or
        $RelativePath -match '^dist/.+' -or
        $RelativePath -match '^legal/.+') {
        return
    }
    throw "File is not in the reviewed staged payload file set: $RelativePath"
}

function Assert-AllowedPayloadFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$PackageRoot
    )

    foreach ($file in Get-AllFiles -Root $Root) {
        $relative = Get-RelativePath -BasePath $Root -Path $file.FullName
        if ($PackageRoot) {
            Assert-AllowedPayloadPath -RelativePath $relative -PackageRoot
        }
        else {
            Assert-AllowedPayloadPath -RelativePath $relative
        }
    }
}

function Assert-PeExecutable {
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

function Get-FileRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File
    )

    $relative = Get-RelativePath -BasePath $Root -Path $File.FullName
    Assert-SafeRelativePath -RelativePath $relative
    return [ordered]@{
        path = $relative
        bytes = [int64]$File.Length
        sha256 = Get-Hash -Path $File.FullName
    }
}

function Get-GeneratedAtUtc {
    param([Parameter(Mandatory = $true)][string]$Epoch)

    if ($Epoch -notmatch '^(0|[1-9][0-9]*)$') {
        throw "SOURCE_DATE_EPOCH must be an integer number of seconds: $Epoch"
    }
    try {
        $seconds = [long]$Epoch
        return ([DateTime]::SpecifyKind([DateTime]'1970-01-01', [DateTimeKind]::Utc).AddSeconds($seconds).ToString('o'))
    }
    catch {
        throw "SOURCE_DATE_EPOCH is outside the supported timestamp range: $Epoch"
    }
}

function Read-JsonIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Property = ''
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $object = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($Property)) {
        return $object
    }
    $objectProperty = $object.PSObject.Properties[$Property]
    if ($null -eq $objectProperty) {
        return $null
    }
    return $objectProperty.Value
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
        # Source archives do not necessarily include git metadata.
    }
    return 'unknown'
}

function Copy-LegalInput {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if ((Test-Path -LiteralPath $Source -PathType Leaf) -and
        -not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

function New-ThirdPartyInventory {
    param(
        [Parameter(Mandatory = $true)][string]$LegalRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$SourceDateEpoch
    )

    $records = @()
    foreach ($file in Get-AllFiles -Root $LegalRoot) {
        $relative = Get-RelativePath -BasePath $LegalRoot -Path $file.FullName
        $records += [ordered]@{
            path = 'legal/' + $relative
            bytes = [int64]$file.Length
            sha256 = Get-Hash -Path $file.FullName
        }
    }
    $records = @($records | Sort-Object -Property @{
        Expression = { ([string]$_.path).ToLowerInvariant() }
    })
    $inventory = [ordered]@{
        schemaVersion = 1
        product = 'KanaAI'
        channel = 'windows-beta'
        version = $Version
        sourceDateEpoch = $SourceDateEpoch
        note = 'Deterministic inventory of notices copied into this package. It is not legal advice or a substitute for dependency-license review.'
        files = $records
    }
    $json = $inventory | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -Path (Join-Path $LegalRoot 'THIRD-PARTY-INVENTORY.json') -Content ($json + [Environment]::NewLine)
}

function New-ZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TopLevelName
    )

    if (Test-Path -LiteralPath $ArchivePath) {
        throw "Archive already exists: $ArchivePath (use -Force to replace it)"
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($ArchivePath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $files = @(Get-AllFiles -Root $SourceRoot)
        $fixedTime = [DateTimeOffset]::Parse('2000-01-01T00:00:00Z')
        foreach ($file in $files) {
            $relative = Get-RelativePath -BasePath $SourceRoot -Path $file.FullName
            Assert-SafeRelativePath -RelativePath $relative
            $entryName = ($TopLevelName + '/' + $relative).Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTime
            $input = [System.IO.File]::OpenRead($file.FullName)
            $output = $entry.Open()
            try {
                $input.CopyTo($output)
            }
            finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-ZipFileSet {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TopLevelName
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $actual = @()
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.Name)) {
                continue
            }
            $prefix = $TopLevelName + '/'
            if (-not $entry.FullName.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
                throw "Archive entry is outside the top-level package directory: $($entry.FullName)"
            }
            $relative = $entry.FullName.Substring($prefix.Length)
            Assert-SafeRelativePath -RelativePath $relative
            $actual += $relative
        }
        $expected = @(Get-AllFiles -Root $SourceRoot | ForEach-Object {
            Get-RelativePath -BasePath $SourceRoot -Path $_.FullName
        })
        Assert-ExactPathSet -Expected $expected -Actual $actual -Description 'ZIP file set'
    }
    finally {
        $archive.Dispose()
    }
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$templateRoot = Join-Path $repositoryRoot 'platform\windows-tsf\package-template'
$bridgeContractSource = Join-Path $repositoryRoot 'platform\windows-tsf\shell\bridge-contract.json'
$targetTriple = 'x86_64-pc-windows-msvc'
if ($Target -cne $targetTriple) {
    throw "This beta supports only $targetTriple, not: $Target"
}
if (-not (Test-Path -LiteralPath $templateRoot -PathType Container)) {
    throw "Package template directory is missing: $templateRoot"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'windows-beta\dist'
}
$outputFull = Assert-SafeOutputDirectory -Path $OutputDirectory -RepositoryRoot $repositoryRoot
New-Item -ItemType Directory -Path $outputFull -Force | Out-Null

$architecture = $Architecture.ToLowerInvariant()
if ($architecture -eq 'amd64') {
    $architecture = 'x64'
}
if ($architecture -ne 'x64') {
    throw 'This beta supports only x64 Windows payloads and the x86_64-pc-windows-msvc target.'
}

$temporaryPayload = $null
$packageRoot = $null
$packageRootCreated = $false
try {
    if ([string]::IsNullOrWhiteSpace($PayloadRoot)) {
        if ([string]::IsNullOrWhiteSpace($ApiExecutable) -or [string]::IsNullOrWhiteSpace($CliExecutable)) {
            throw 'Provide -PayloadRoot, or provide both -ApiExecutable and -CliExecutable.'
        }
        $temporaryPayload = Join-Path ([System.IO.Path]::GetTempPath()) ('kanai-beta-payload-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $temporaryPayload 'bin') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $temporaryPayload 'dist') -Force | Out-Null
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ApiExecutable).Path -Destination (Join-Path $temporaryPayload 'bin\kanai-api.exe') -Force
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $CliExecutable).Path -Destination (Join-Path $temporaryPayload 'bin\kanai.exe') -Force
        if (-not [string]::IsNullOrWhiteSpace($MozcBridgeExecutable)) {
            Copy-Item -LiteralPath (Resolve-Path -LiteralPath $MozcBridgeExecutable).Path -Destination (Join-Path $temporaryPayload 'bin\kanai-mozc-bridge.exe') -Force
        }
        if (-not [string]::IsNullOrWhiteSpace($ShellExecutable)) {
            Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ShellExecutable).Path -Destination (Join-Path $temporaryPayload 'bin\kanai-windows-shell.exe') -Force
        }
        if (-not [string]::IsNullOrWhiteSpace($WebRoot)) {
            Copy-Tree -Source (Resolve-Path -LiteralPath $WebRoot).Path -Destination (Join-Path $temporaryPayload 'dist')
        }
        $PayloadRoot = $temporaryPayload
    }

    $payloadFull = [System.IO.Path]::GetFullPath($PayloadRoot)
    if (-not (Test-Path -LiteralPath $payloadFull -PathType Container)) {
        throw "Payload directory does not exist: $payloadFull"
    }
    Assert-NoForbiddenFiles -Root $payloadFull
    Assert-AllowedPayloadFiles -Root $payloadFull
    Assert-NotNestedPath -Parent $payloadFull -Child $outputFull -Description 'The package output directory and payload directory'

    $buildInputsPath = Join-Path $payloadFull '.build-inputs.json'
    $buildInputs = Read-JsonIfPresent -Path $buildInputsPath
    $buildInputsVersion = Get-JsonProperty -Object $buildInputs -Name 'version'
    $buildInputsRevision = Get-JsonProperty -Object $buildInputs -Name 'sourceRevision'
    $buildInputsEpoch = Get-JsonProperty -Object $buildInputs -Name 'sourceDateEpoch'
    $buildInputsTarget = Get-JsonProperty -Object $buildInputs -Name 'target'
    $buildInputsArchitecture = Get-JsonProperty -Object $buildInputs -Name 'architecture'
    if ($null -ne $buildInputsTarget -and [string]$buildInputsTarget -cne $targetTriple) {
        throw "The staged payload target does not match $targetTriple`: $($buildInputsTarget)"
    }
    if ($null -ne $buildInputsArchitecture -and [string]$buildInputsArchitecture -ine 'x64') {
        throw "The staged payload architecture is not x64: $($buildInputsArchitecture)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Version) -and $null -ne $buildInputsVersion -and [string]$Version -cne [string]$buildInputsVersion) {
        throw "The requested version does not match the staged build metadata: $Version / $($buildInputsVersion)"
    }
    if ([string]::IsNullOrWhiteSpace($Version) -and $null -ne $buildInputsVersion) {
        $Version = [string]$buildInputsVersion
    }
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $cargoManifest = Join-Path $repositoryRoot 'Cargo.toml'
        $cargoContent = Get-Content -LiteralPath $cargoManifest -Raw
        $versionMatch = [regex]::Match($cargoContent, '(?m)^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)')
        if (-not $versionMatch.Success) {
            throw 'Could not determine package version; pass -Version explicitly.'
        }
        $Version = $versionMatch.Groups[1].Value
    }
    if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$') {
        throw "Version must look like 0.1.0: $Version"
    }

    if ([string]::IsNullOrWhiteSpace($SourceRevision)) {
        if ($null -ne $buildInputsRevision -and [string]$buildInputsRevision -ne 'unknown') {
            $SourceRevision = [string]$buildInputsRevision
        }
        else {
            $SourceRevision = Get-GitRevision -RepositoryRoot $repositoryRoot
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($SourceDateEpoch) -and
        $null -ne $buildInputsEpoch -and
        [string]$SourceDateEpoch -cne [string]$buildInputsEpoch) {
        throw "SOURCE_DATE_EPOCH does not match the staged build metadata: $SourceDateEpoch / $($buildInputsEpoch)"
    }
    if ([string]::IsNullOrWhiteSpace($SourceDateEpoch) -and $null -ne $buildInputsEpoch) {
        $SourceDateEpoch = [string]$buildInputsEpoch
    }
    if ([string]::IsNullOrWhiteSpace($SourceDateEpoch) -and -not [string]::IsNullOrWhiteSpace($env:SOURCE_DATE_EPOCH)) {
        $SourceDateEpoch = [string]$env:SOURCE_DATE_EPOCH
    }
    if ([string]::IsNullOrWhiteSpace($SourceDateEpoch)) {
        throw 'SOURCE_DATE_EPOCH is required for a deterministic package. Pass it explicitly, set the environment variable, or provide a staged build with a validated epoch.'
    }
    if ($SourceDateEpoch -notmatch '^(0|[1-9][0-9]*)$') {
        throw "SOURCE_DATE_EPOCH must be a non-negative integer number of seconds: $SourceDateEpoch"
    }
    $generatedAtUtc = Get-GeneratedAtUtc -Epoch $SourceDateEpoch

    $packageName = "kanai-$Version-windows-$architecture-portable"
    $packageRoot = Join-Path $outputFull $packageName
    if (Test-Path -LiteralPath $packageRoot) {
        if (-not $Force) {
            throw "Package directory already exists: $packageRoot (use -Force to replace it)"
        }
        Remove-Item -LiteralPath $packageRoot -Recurse -Force
    }
    Assert-NotNestedPath -Parent $payloadFull -Child $packageRoot -Description 'The package directory and payload directory'
    Copy-Tree -Source $payloadFull -Destination $packageRoot
    $packageRootCreated = $true

    # The scripts and the explicit beta notice are part of every package,
    # including one assembled from a prebuilt payload.
    Copy-Tree -Source $templateRoot -Destination $packageRoot
    if (Test-Path -LiteralPath $bridgeContractSource -PathType Leaf) {
        $bridgeContractDestination = Join-Path $packageRoot 'config\bridge-contract.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $bridgeContractDestination) -Force | Out-Null
        Copy-Item -LiteralPath $bridgeContractSource -Destination $bridgeContractDestination -Force
    }

    $apiPath = Join-Path $packageRoot 'bin\kanai-api.exe'
    $cliPath = Join-Path $packageRoot 'bin\kanai.exe'
    $bridgePath = Join-Path $packageRoot 'bin\kanai-mozc-bridge.exe'
    $shellPath = Join-Path $packageRoot 'bin\kanai-windows-shell.exe'
    $webIndexPath = Join-Path $packageRoot 'dist\index.html'
    $apiPresent = Test-Path -LiteralPath $apiPath -PathType Leaf
    $cliPresent = Test-Path -LiteralPath $cliPath -PathType Leaf
    $bridgePresent = Test-Path -LiteralPath $bridgePath -PathType Leaf
    $shellPresent = Test-Path -LiteralPath $shellPath -PathType Leaf
    $webPresent = Test-Path -LiteralPath $webIndexPath -PathType Leaf
    if (-not $apiPresent -or -not $cliPresent) {
        if (-not $AllowIncomplete) {
            throw 'The package needs bin\kanai-api.exe and bin\kanai.exe. Use -AllowIncomplete only for a clearly labeled scaffold.'
        }
    }
    if (-not $bridgePresent -and -not $AllowIncomplete) {
        throw 'The package needs bin\kanai-mozc-bridge.exe. Use -AllowIncomplete only for a non-converting scaffold.'
    }
    if (-not $webPresent -and -not $AllowIncomplete) {
        throw 'The package needs dist\index.html. Use -AllowIncomplete only for a CLI/API scaffold.'
    }
    foreach ($requiredBinary in @($apiPath, $cliPath, $bridgePath, $shellPath)) {
        if (Test-Path -LiteralPath $requiredBinary -PathType Leaf) {
            $binaryInfo = Get-Item -LiteralPath $requiredBinary
            if ($binaryInfo.Length -le 0) {
                throw "Payload binary is empty: $requiredBinary"
            }
            Assert-PeExecutable -Path $requiredBinary
        }
    }

    $unexpectedDlls = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -Force -File -Filter '*.dll')
    if ($unexpectedDlls.Count -gt 0) {
        throw "This phase-1 package does not accept TSF DLLs: $($unexpectedDlls[0].FullName)"
    }

    $legalRoot = Join-Path $packageRoot 'legal'
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
        $destination = Join-Path $legalRoot $legalInput.Destination
        Copy-LegalInput -Source $legalInput.Source -Destination $destination
    }
    $noticeTemplate = Join-Path $templateRoot 'THIRD-PARTY-NOTICES.txt'
    if (Test-Path -LiteralPath $noticeTemplate -PathType Leaf) {
        Copy-Item -LiteralPath $noticeTemplate -Destination (Join-Path $legalRoot 'THIRD-PARTY-NOTICES.txt') -Force
    }
    if (-not $AllowIncomplete) {
        $requiredLegal = @(
            'LICENSE', 'LICENSE-MIT', 'LICENSE-APACHE', 'Mozc-LICENSE.txt', 'Mozc-AUTHORS.txt',
            'Mozc-CONTRIBUTORS.txt', 'Mozc-README.md', 'Mozc-VOCABULARY-POLICY.md',
            'Mozc-dictionary-README.txt', 'mozc-kanai-bridge.patch', 'Cargo.lock', 'package-lock.json',
            'THIRD-PARTY-NOTICES.txt'
        )
        foreach ($legalName in $requiredLegal) {
            if (-not (Test-Path -LiteralPath (Join-Path $legalRoot $legalName) -PathType Leaf)) {
                throw "Required third-party/project notice is missing: legal/$legalName"
            }
        }
    }
    New-ThirdPartyInventory -LegalRoot $legalRoot -RepositoryRoot $repositoryRoot -Version $Version -SourceDateEpoch $SourceDateEpoch

    $versionText = @(
        'product=KanaAI',
        'channel=windows-beta',
        "version=$Version",
        "target=$targetTriple",
        "architecture=$architecture",
        'phase=workbench-cli-phase-1',
        'tsf_status=unimplemented',
        'tsf_registered=false',
        'tsf_dll_included=false',
        'conversion_ready=false',
        'runtime_verified=false',
        'model_bundled=false'
    ) -join [Environment]::NewLine
    Write-Utf8NoBom -Path (Join-Path $packageRoot 'VERSION.txt') -Content ($versionText + [Environment]::NewLine)

    $payloadFilesPresent = $apiPresent -and $cliPresent -and $bridgePresent -and $webPresent
    $workbenchFilesPresent = $apiPresent -and $webPresent
    $cliFilesPresent = $cliPresent
    $conversionFilesPresent = $apiPresent -and $bridgePresent
    $runtimeVerified = $false
    $conversionReady = $false
    $status = if ($payloadFilesPresent) { 'beta-workbench-unverified' } else { 'scaffold' }

    $runtimeRequiredFiles = @('BETA-NOTICE.txt', 'VERSION.txt') + $scriptNames + @(
        'config/kanai.env.example',
        'config/bridge-contract.json'
    )
    if ($apiPresent) { $runtimeRequiredFiles += 'bin/kanai-api.exe' }
    if ($cliPresent) { $runtimeRequiredFiles += 'bin/kanai.exe' }
    if ($bridgePresent) { $runtimeRequiredFiles += 'bin/kanai-mozc-bridge.exe' }
    if ($webPresent) { $runtimeRequiredFiles += 'dist/index.html' }
    if ($shellPresent) { $runtimeRequiredFiles += 'bin/kanai-windows-shell.exe' }
    $packageRequiredFiles = @($fixedPackageFiles + $runtimeRequiredFiles + @(
        'legal/LICENSE',
        'legal/LICENSE-MIT',
        'legal/LICENSE-APACHE',
        'legal/THIRD-PARTY-INVENTORY.json'
    ) | Select-Object -Unique)

    $manifest = [ordered]@{
        schemaVersion = 2
        product = 'KanaAI'
        channel = 'windows-beta'
        version = $Version
        target = $targetTriple
        architecture = $architecture
        packageType = 'portable-zip'
        generatedAtUtc = $generatedAtUtc
        sourceRevision = $SourceRevision
        sourceDateEpoch = $SourceDateEpoch
        status = $status
        payloadFilesPresent = $payloadFilesPresent
        payloadPresent = $payloadFilesPresent
        workbenchFilesPresent = $workbenchFilesPresent
        cliFilesPresent = $cliFilesPresent
        conversionFilesPresent = $conversionFilesPresent
        conversionReady = $conversionReady
        runtimeVerified = $runtimeVerified
        readiness = 'not-verified-by-packager'
        modelBundled = $false
        tsf = [ordered]@{
            status = 'unimplemented'
            registered = $false
            dllIncluded = $false
            implementation = 'not-built'
            secureFields = $false
        }
        shell = [ordered]@{
            nativeConsoleSeamIncluded = $shellPresent
            isTextService = $false
        }
        runtime = [ordered]@{
            bindAddress = '127.0.0.1'
            defaultPort = 8787
            requiredFiles = @($runtimeRequiredFiles | Select-Object -Unique)
            optionalModelServer = $true
        }
        packageRequiredFiles = @($packageRequiredFiles | Select-Object -Unique)
        buildInputs = if ($null -ne $buildInputs) { $buildInputs } else { [ordered]@{} }
        fileSet = [ordered]@{
            excludes = @('manifest.json', 'SHA256SUMS')
            count = 0
            paths = @()
        }
        files = @()
    }

    $fileRecords = @()
    foreach ($file in Get-PayloadFiles -Root $packageRoot) {
        $fileRecords += Get-FileRecord -Root $packageRoot -File $file
    }
    $manifest.files = @($fileRecords | Sort-Object -Property @{
        Expression = { ([string]$_.path).ToLowerInvariant() }
    })
    $manifest.fileSet.count = @($manifest.files).Count
    $manifest.fileSet.paths = @($manifest.files | ForEach-Object { [string]$_.path })
    $manifest.fileSet.sha256 = Get-TextHash -Text (($manifest.fileSet.paths -join "`n") + "`n")
    $manifestJson = $manifest | ConvertTo-Json -Depth 20
    Write-Utf8NoBom -Path (Join-Path $packageRoot 'manifest.json') -Content ($manifestJson + [Environment]::NewLine)

    $checksumEntries = @()
    foreach ($file in Get-ChecksumFiles -Root $packageRoot) {
        $relative = Get-RelativePath -BasePath $packageRoot -Path $file.FullName
        Assert-SafeRelativePath -RelativePath $relative
        $checksumEntries += [pscustomobject]@{
            path = $relative
            line = ((Get-Hash -Path $file.FullName) + '  ' + $relative)
        }
    }
    $checksumEntries = @($checksumEntries | Sort-Object -Property @{
        Expression = { ([string]$_.path).ToLowerInvariant() }
    })
    $checksumLines = @($checksumEntries | ForEach-Object { [string]$_.line })
    Write-Utf8NoBom -Path (Join-Path $packageRoot 'SHA256SUMS') -Content (($checksumLines -join "`n") + "`n")

    Assert-NoForbiddenFiles -Root $packageRoot
    Assert-AllowedPayloadFiles -Root $packageRoot -PackageRoot
    $verifyScript = Join-Path $packageRoot 'Verify-KanaAI.ps1'
    if (-not (Test-Path -LiteralPath $verifyScript -PathType Leaf)) {
        throw "The package verification script is missing: $verifyScript"
    }
    & $verifyScript -PackageRoot $packageRoot | Out-Null

    $archivePath = Join-Path $outputFull ($packageName + '.zip')
    $externalManifestPath = Join-Path $outputFull ($packageName + '.manifest.json')
    $archiveShaPath = Join-Path $outputFull ($packageName + '.zip.sha256')
    $releaseSumsPath = Join-Path $outputFull 'SHA256SUMS'

    if (-not $NoArchive) {
        if (Test-Path -LiteralPath $archivePath) {
            if (-not $Force) {
                throw "Archive already exists: $archivePath (use -Force to replace it)"
            }
            Remove-Item -LiteralPath $archivePath -Force
        }
        New-ZipArchive -ArchivePath $archivePath -SourceRoot $packageRoot -TopLevelName $packageName
        Assert-ZipFileSet -ArchivePath $archivePath -SourceRoot $packageRoot -TopLevelName $packageName
    }
    $packageManifestHash = Get-Hash -Path (Join-Path $packageRoot 'manifest.json')
    $archiveHash = $null
    $archiveBytes = $null
    if (-not $NoArchive) {
        $archiveHash = Get-Hash -Path $archivePath
        $archiveBytes = (Get-Item -LiteralPath $archivePath).Length
    }
    $externalManifest = [ordered]@{
        schemaVersion = 2
        product = 'KanaAI'
        channel = 'windows-beta'
        version = $Version
        target = $targetTriple
        architecture = $architecture
        status = $status
        payloadFilesPresent = $payloadFilesPresent
        conversionReady = $false
        runtimeVerified = $false
        sourceRevision = $SourceRevision
        sourceDateEpoch = $SourceDateEpoch
        generatedAtUtc = $generatedAtUtc
        packageDirectory = $packageName + '/'
        packageManifestSha256 = $packageManifestHash
        artifact = if ($NoArchive) { $null } else { [ordered]@{ file = (Split-Path -Leaf $archivePath); bytes = $archiveBytes; sha256 = $archiveHash } }
        trust = [ordered]@{
            authenticode = 'unsigned'
            checksum = 'SHA-256 is generated beside the artifact; obtain it through a trusted channel'
            tsfRegistered = $false
            runtimeVerified = $false
        }
    }
    Write-Utf8NoBom -Path $externalManifestPath -Content (($externalManifest | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

    $releaseSums = @()
    if (-not $NoArchive) {
        $releaseSums += ((Get-Hash -Path $archivePath) + '  ' + (Split-Path -Leaf $archivePath))
    }
    $releaseSums += ((Get-Hash -Path $externalManifestPath) + '  ' + (Split-Path -Leaf $externalManifestPath))
    $releaseSums = @($releaseSums | Sort-Object)
    Write-Utf8NoBom -Path $releaseSumsPath -Content (($releaseSums -join "`n") + "`n")
    if (-not $NoArchive) {
        Write-Utf8NoBom -Path $archiveShaPath -Content ((Get-Hash -Path $archivePath) + '  ' + (Split-Path -Leaf $archivePath) + "`n")
    }

    [pscustomobject]@{
        PackageDirectory = $packageRoot
        Archive = if ($NoArchive) { $null } else { $archivePath }
        ArchiveSha256 = $archiveHash
        ExternalManifest = $externalManifestPath
        ReleaseChecksums = $releaseSumsPath
        PerArchiveChecksum = if ($NoArchive) { $null } else { $archiveShaPath }
        Status = $status
        PayloadFilesPresent = $payloadFilesPresent
        ConversionReady = $false
        RuntimeVerified = $false
    }
}
catch {
    if ($packageRootCreated -and $null -ne $packageRoot -and (Test-Path -LiteralPath $packageRoot)) {
        Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
finally {
    if ($null -ne $temporaryPayload -and (Test-Path -LiteralPath $temporaryPayload)) {
        Remove-Item -LiteralPath $temporaryPayload -Recurse -Force -ErrorAction SilentlyContinue
    }
}
