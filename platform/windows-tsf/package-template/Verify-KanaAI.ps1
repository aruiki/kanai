[CmdletBinding()]
param(
    [string]$PackageRoot = $PSScriptRoot
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
$fixedFiles = @(
    'BETA-NOTICE.txt',
    'THIRD-PARTY-NOTICES.txt',
    'VERSION.txt',
    'config/kanai.env.example',
    'config/bridge-contract.json'
)

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

function Join-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $current = $BasePath
    foreach ($part in ($RelativePath -split '/')) {
        if (-not [string]::IsNullOrWhiteSpace($part)) {
            $current = Join-Path $current $part
        }
    }
    return $current
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

function Assert-AllowedPackagePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    Assert-SafeRelativePath -RelativePath $RelativePath
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
    if ($RelativePath -match '^dist/.+' -or $RelativePath -match '^legal/.+') {
        return
    }
    throw "File is not in the reviewed Windows beta package file set: $RelativePath"
}

function Assert-PeExecutable {
    param([Parameter(Mandatory = $true)][string]$Path)

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
        if ([BitConverter]::ToUInt16($optionalMagic, 0) -ne 0x20b) {
            throw "Payload executable is not a PE32+ image: $Path"
        }
        if (([BitConverter]::ToUInt16($coff, 18) -band 0x2000) -ne 0) {
            throw "Payload executable is a DLL, which is not allowed in this phase-1 package: $Path"
        }
    }
    finally {
        $stream.Dispose()
    }
}

$root = [System.IO.Path]::GetFullPath($PackageRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Package root does not exist: $root"
}

$manifestPath = Join-Path $root 'manifest.json'
$checksumPath = Join-Path $root 'SHA256SUMS'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "manifest.json is missing from $root"
}
if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
    throw "SHA256SUMS is missing from $root"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.channel -ne 'windows-beta') {
    throw "Unexpected package channel: $($manifest.channel)"
}
if ($manifest.schemaVersion -ne 2) {
    throw "Unsupported package manifest schema: $($manifest.schemaVersion)"
}
if ($manifest.target -cne 'x86_64-pc-windows-msvc') {
    throw "Unexpected package target: $($manifest.target)"
}
if ($manifest.architecture -ine 'x64') {
    throw "Unexpected package architecture: $($manifest.architecture)"
}
if ($manifest.conversionReady -ne $false -or $manifest.runtimeVerified -ne $false) {
    throw 'Packaging must not claim conversion or runtime readiness from file presence.'
}
if ($null -eq $manifest.tsf -or $manifest.tsf.status -ne 'unimplemented' -or
    $manifest.tsf.registered -ne $false -or $manifest.tsf.dllIncluded -ne $false -or
    $manifest.tsf.implementation -ne 'not-built') {
    throw 'The package manifest must explicitly keep TSF unimplemented and unregistered.'
}
if ($null -eq $manifest.fileSet -or $null -eq $manifest.files) {
    throw 'The package manifest is missing its exact file-set records.'
}

$allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File)
$reparsePoints = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object {
    ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
})
if ($reparsePoints.Count -gt 0) {
    throw "Reparse points are not allowed in a portable package: $($reparsePoints[0].FullName)"
}
$forbidden = @($allFiles | Where-Object {
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
    throw "The package contains a forbidden developer/runtime file: $($forbidden[0].FullName)"
}

$actualPayloadPaths = @()
$actualFilesByPath = @{}
foreach ($file in $allFiles) {
    $relative = Get-RelativePath -BasePath $root -Path $file.FullName
    Assert-AllowedPackagePath -RelativePath $relative
    if ($relative -notin @('manifest.json', 'SHA256SUMS')) {
        $key = $relative.ToLowerInvariant()
        if ($actualFilesByPath.ContainsKey($key)) {
            throw "Package contains a case-colliding file path: $relative"
        }
        $actualFilesByPath[$key] = $file
        $actualPayloadPaths += $relative
    }
}
Assert-ExactPathSet -Expected @($manifest.files | ForEach-Object { [string]$_.path }) -Actual $actualPayloadPaths -Description 'Manifest/payload file set'

$manifestPaths = @()
$manifestPathKeys = @{}
foreach ($record in @($manifest.files)) {
    $propertyNames = @($record.PSObject.Properties.Name | Sort-Object)
    $expectedPropertyNames = @('bytes', 'path', 'sha256')
    if ($propertyNames.Count -ne $expectedPropertyNames.Count -or
        $propertyNames[0] -cne $expectedPropertyNames[0] -or
        $propertyNames[1] -cne $expectedPropertyNames[1] -or
        $propertyNames[2] -cne $expectedPropertyNames[2]) {
        throw 'A manifest file record has an unexpected property set.'
    }
    $relative = [string]$record.path
    Assert-SafeRelativePath -RelativePath $relative
    $key = $relative.ToLowerInvariant()
    if ($manifestPathKeys.ContainsKey($key)) {
        throw "Manifest contains a duplicate file path: $relative"
    }
    $manifestPathKeys[$key] = $true
    $manifestPaths += $relative
    if ([string]$record.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "Manifest has an invalid SHA-256 for $relative"
    }
    $filePath = Join-RelativePath -BasePath $root -RelativePath $relative
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Manifest file is missing: $relative"
    }
    $fileInfo = Get-Item -LiteralPath $filePath
    if ([int64]$record.bytes -ne [int64]$fileInfo.Length) {
        throw "Manifest byte count differs for ${relative}: $($record.bytes) / $($fileInfo.Length)"
    }
    $actualHash = Get-Hash -Path $filePath
    if ($actualHash -cne [string]$record.sha256) {
        throw "Manifest SHA-256 differs for ${relative}: $($record.sha256) / $actualHash"
    }
}

$fileSet = $manifest.fileSet
if ([int]$fileSet.count -ne $actualPayloadPaths.Count) {
    throw 'Manifest fileSet.count does not match the actual payload file count.'
}
$fileSetPaths = @($fileSet.paths | ForEach-Object { [string]$_ })
Assert-ExactPathSet -Expected $manifestPaths -Actual $fileSetPaths -Description 'Manifest fileSet.paths'
$expectedFileSetHash = Get-TextHash -Text (($fileSetPaths -join "`n") + "`n")
if ([string]$fileSet.sha256 -cne $expectedFileSetHash) {
    throw 'Manifest fileSet.sha256 does not match its exact path list.'
}

$requiredFiles = @()
if ($null -ne $manifest.runtime -and $null -ne $manifest.runtime.requiredFiles) {
    $requiredFiles += @($manifest.runtime.requiredFiles | ForEach-Object { [string]$_ })
}
if ($null -ne $manifest.packageRequiredFiles) {
    $requiredFiles += @($manifest.packageRequiredFiles | ForEach-Object { [string]$_ })
}
$seenRequired = @{}
foreach ($required in $requiredFiles) {
    Assert-SafeRelativePath -RelativePath $required
    $requiredKey = $required.ToLowerInvariant()
    if ($seenRequired.ContainsKey($requiredKey)) {
        continue
    }
    $seenRequired[$requiredKey] = $true
    $requiredPath = Join-RelativePath -BasePath $root -RelativePath $required
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required package file is missing: $required"
    }
}

$lines = @(Get-Content -LiteralPath $checksumPath)
$checksumPaths = @()
$checksumKeys = @{}
$checked = 0
foreach ($line in $lines) {
    $trimmed = [string]$line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        continue
    }
    if ($trimmed -notmatch '^([0-9a-fA-F]{64})  (.+)$') {
        throw "Malformed SHA256SUMS line: $trimmed"
    }
    $expected = $Matches[1].ToLowerInvariant()
    $relative = $Matches[2].Trim()
    Assert-SafeRelativePath -RelativePath $relative
    $key = $relative.ToLowerInvariant()
    if ($checksumKeys.ContainsKey($key)) {
        throw "Duplicate SHA256SUMS path: $relative"
    }
    $checksumKeys[$key] = $true
    $checksumPaths += $relative
    $filePath = Join-RelativePath -BasePath $root -RelativePath $relative
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Checksummed file is missing: $relative"
    }
    $actual = Get-Hash -Path $filePath
    if ($actual -cne $expected) {
        throw "SHA-256 mismatch for ${relative}: expected $expected, got $actual"
    }
    $checked++
}
if ($checked -eq 0) {
    throw 'SHA256SUMS did not contain any file entries.'
}
$expectedChecksumPaths = @($actualPayloadPaths + @('manifest.json'))
Assert-ExactPathSet -Expected $expectedChecksumPaths -Actual $checksumPaths -Description 'SHA256SUMS file set'

foreach ($binaryName in @('kanai-api.exe', 'kanai.exe', 'kanai-mozc-bridge.exe', 'kanai-windows-shell.exe')) {
    $binaryPath = Join-Path (Join-Path $root 'bin') $binaryName
    if (Test-Path -LiteralPath $binaryPath -PathType Leaf) {
        Assert-PeExecutable -Path $binaryPath
    }
}
$dlls = @($allFiles | Where-Object { $_.Name -like '*.dll' })
if ($dlls.Count -gt 0) {
    throw "The phase-1 package must not contain a TSF DLL: $($dlls[0].FullName)"
}

[pscustomobject]@{
    PackageRoot = $root
    Version = [string]$manifest.version
    Target = [string]$manifest.target
    Channel = [string]$manifest.channel
    FilesChecked = $checked
    PayloadFiles = $actualPayloadPaths.Count
    Manifest = $manifestPath
    Checksums = $checksumPath
    RuntimeVerified = $false
    TsfImplemented = $false
}
