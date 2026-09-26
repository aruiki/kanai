[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..'))
$fetchScript = Join-Path $repository 'scripts\fetch-stage-pinned-ai-runtime.ps1'
$manifestPath = Join-Path $repository 'platform\windows-tsf\ai-runtime\manifest-v1.json'
$modelLicensePath = Join-Path $repository 'platform\windows-tsf\ai-runtime\licenses\Qwen-Apache-2.0.txt'
$runtimeLicensePath = Join-Path $repository 'platform\windows-tsf\ai-runtime\licenses\llama.cpp-MIT.txt'
$noticePath = Join-Path $repository 'platform\windows-tsf\ai-runtime\THIRD-PARTY-NOTICES.txt'
$testScript = $MyInvocation.MyCommand.Path
$localRoot = [IO.Path]::GetFullPath((Join-Path $repository '.local'))
$testResultsRoot = Join-Path $localRoot 'test-results'
$testRoot = Join-Path $testResultsRoot ('airuntime-staging-' + [Guid]::NewGuid().ToString('N'))

function Get-Sha256 {
    param([string]$Path)
    $stream = $null
    $sha = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sha = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
    param(
        [scriptblock]$Action,
        [string]$Pattern
    )
    $rejected = $false
    $message = ''
    try { & $Action | Out-Null } catch {
        $rejected = $true
        $message = [string]$_.Exception.Message
    }
    if (-not $rejected) { throw "Expected rejection matching '$Pattern'." }
    if ($message -notmatch $Pattern) { throw "Rejection message did not match '$Pattern': $message" }
}

function Write-Utf8Json {
    param(
        [string]$Path,
        [object]$Value
    )
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine), $utf8)
}

function New-FixtureZip {
    param(
        [string]$Path,
        [object[]]$Entries
    )
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($spec in $Entries) {
            $entry = $zip.CreateEntry([string]$spec.Name)
            if ($spec.PSObject.Properties['ExternalAttributes']) {
                $entry.ExternalAttributes = [int32]$spec.ExternalAttributes
            }
            $entryStream = $entry.Open()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$spec.Text)
                $entryStream.Write($bytes, 0, $bytes.Length)
            } finally {
                $entryStream.Dispose()
            }
        }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

try {
    foreach ($path in @($fetchScript, $manifestPath, $modelLicensePath, $runtimeLicensePath, $noticePath, $testScript)) {
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Required offline test input is missing: $path"
    }

    foreach ($path in @($fetchScript, $testScript)) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
            throw (($parseErrors | ForEach-Object { "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)" }) -join "`n")
        }
    }

    $fetchText = [IO.File]::ReadAllText($fetchScript, [Text.Encoding]::UTF8)
    foreach ($forbidden in @('Invoke-WebRequest', 'Invoke-RestMethod', 'WebClient', 'HttpClient', 'Start-BitsTransfer', 'curl.exe', 'wget ')) {
        if ($fetchText.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "The fetch/stage script contains a forbidden network primitive: $forbidden"
        }
    }
    if ($fetchText.IndexOf('[switch]$Fetch', [StringComparison]::Ordinal) -lt 0 -or
        $fetchText.IndexOf('Network fetch is intentionally not implemented', [StringComparison]::Ordinal) -lt 0) {
        throw 'The fetch/stage script must explicitly refuse the unimplemented -Fetch path.'
    }

    $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-True ($manifest.schemaVersion -eq 1 -and $manifest.manifestVersion -eq 1) 'Manifest versions are not explicit.'
    Assert-True ($manifest.status -eq 'pinned-assets-verified-not-staged') 'Manifest status does not distinguish verified inputs from product staging.'
    Assert-True ($manifest.model.revision -eq '91cad51170dc346986eccefdc2dd33a9da36ead9') 'Model revision is not pinned.'
    Assert-True ($manifest.model.weight.bytes -eq 1117320736) 'Model byte size is not pinned.'
    Assert-True ($manifest.model.weight.sha256 -eq '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e') 'Model digest is not pinned.'
    Assert-True ($manifest.runtime.revision -eq '7fe450e19305b828c199d602c23a8337aaa1f03b') 'Runtime commit is not pinned.'
    Assert-True ($manifest.runtime.asset.bytes -eq 18560055) 'Runtime archive byte size is not pinned.'
    Assert-True ($manifest.runtime.asset.sha256 -eq '14cf1303ca9ac3abd94816850532f9f9a69ac66fbaca3776fc6f9061c2fac1d1') 'Runtime archive digest is not pinned.'
    Assert-True ($manifest.broker.fileName -eq 'kanai-broker.exe' -and
        $manifest.broker.architecture -eq 'x64' -and $manifest.broker.kind -eq 'Exe' -and
        $manifest.broker.bytes -gt 0 -and
        $manifest.broker.sha256 -match '^[0-9a-f]{64}$' -and
        $manifest.broker.optionalHeaderMagic -match '^0x[0-9a-f]{4}$') 'The broker identity is not pinned by the manifest.'
    Assert-True ($manifest.fetchPolicy.defaultMode -eq 'plan' -and $manifest.fetchPolicy.networkImplemented -eq $false) 'Manifest fetch policy is not offline by default.'
    Assert-True ($manifest.runtime.archive.entryPolicy.entryCount -eq 51 -and
        $manifest.runtime.archive.entryPolicy.entryNamesSha256 -eq '68da91a595ea841f87c7f7f34aff23bdf0a9910f129cf0fd3a06264205b61f0c') 'Pinned runtime archive layout is not recorded.'
    Assert-True (@($manifest.runtime.archive.entryPolicy.requiredEntries) -contains 'llama-server.exe' -and
        @($manifest.runtime.archive.entryPolicy.requiredEntries) -contains 'LICENSE-LLVM-OpenMP') 'Required runtime closure entries are missing.'
    Assert-True ($manifest.verification.conversionReproducibility -eq 'unverified') 'Conversion reproducibility was incorrectly marked verified.'
    $brokerNode = $manifest.PSObject.Properties['broker']
    Assert-True ($null -ne $brokerNode -and $null -ne $brokerNode.Value) 'The pinned manifest does not declare a broker identity.'
    Assert-True ([string]$brokerNode.Value.sha256 -match '^[0-9a-f]{64}$') 'The pinned broker SHA-256 is malformed.'
    Assert-True ($manifest.verification.artifactDigests.model -eq 'local-weight-verified' -and
        $manifest.verification.artifactDigests.runtime -eq 'local-archive-verified' -and
        $manifest.verification.localDownload.model -eq 'performed-and-verified' -and
        $manifest.verification.localDownload.runtime -eq 'performed-and-verified') 'Local/upstream digest status is not explicit.'

    $modelLicenseText = [IO.File]::ReadAllText($modelLicensePath, [Text.Encoding]::UTF8)
    $runtimeLicenseText = [IO.File]::ReadAllText($runtimeLicensePath, [Text.Encoding]::UTF8)
    $noticeText = [IO.File]::ReadAllText($noticePath, [Text.Encoding]::UTF8)
    Assert-True ($modelLicenseText.Contains('Apache License') -and $modelLicenseText.Contains('Version 2.0') -and $modelLicenseText.Contains('END OF TERMS AND CONDITIONS')) 'Apache license text is incomplete.'
    Assert-True ($runtimeLicenseText.Contains('MIT License') -and $runtimeLicenseText.Contains('Copyright (c) 2023-2026 The ggml authors') -and $runtimeLicenseText.Contains('Permission is hereby granted')) 'MIT license text is incomplete.'
    Assert-True ($noticeText.Contains('UNVERIFIED / INCOMPLETE DEPENDENCY NOTICE INVENTORY') -and $noticeText.Contains('have not been completed') -and $noticeText.Contains('before redistribution')) 'Dependency notice status is not explicit.'

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $fixtureLicenseDirectory = Join-Path $testRoot 'licenses'
    New-Item -ItemType Directory -Path $fixtureLicenseDirectory -Force | Out-Null
    Copy-Item -LiteralPath $modelLicensePath -Destination (Join-Path $fixtureLicenseDirectory 'qwen-license.txt')
    Copy-Item -LiteralPath $runtimeLicensePath -Destination (Join-Path $fixtureLicenseDirectory 'llama-license.txt')
    Copy-Item -LiteralPath $noticePath -Destination (Join-Path $testRoot 'source-notice.txt')

    $modelFixturePath = Join-Path $testRoot 'model-fixture.bin'
    [IO.File]::WriteAllText($modelFixturePath, 'offline model fixture; not a model asset', (New-Object Text.UTF8Encoding($false)))
    $modelFixtureBytes = (Get-Item -LiteralPath $modelFixturePath -Force).Length
    $modelFixtureSha = Get-Sha256 $modelFixturePath
    $runtimeFixturePath = Join-Path $testRoot 'runtime-fixture.zip'
    New-FixtureZip $runtimeFixturePath @(
        [pscustomobject]@{ Name = 'runtime-fixture.txt'; Text = 'offline runtime fixture' }
    )
    $runtimeFixtureBytes = (Get-Item -LiteralPath $runtimeFixturePath -Force).Length
    $runtimeFixtureSha = Get-Sha256 $runtimeFixturePath

    $fixtureManifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $fixtureManifest.model.weight.fileName = 'model-fixture.bin'
    $fixtureManifest.model.weight.bytes = $modelFixtureBytes
    $fixtureManifest.model.weight.sha256 = $modelFixtureSha
    $fixtureManifest.model.weight.lfsSha256 = $modelFixtureSha
    $fixtureManifest.model.licensePath = 'licenses/qwen-license.txt'
    $fixtureManifest.model.licenseFileBytes = (Get-Item -LiteralPath (Join-Path $fixtureLicenseDirectory 'qwen-license.txt') -Force).Length
    $fixtureManifest.model.licenseFileSha256 = Get-Sha256 (Join-Path $fixtureLicenseDirectory 'qwen-license.txt')
    $fixtureManifest.runtime.asset.fileName = 'runtime-fixture.zip'
    $fixtureManifest.runtime.asset.bytes = $runtimeFixtureBytes
    $fixtureManifest.runtime.asset.sha256 = $runtimeFixtureSha
    $fixtureManifest.runtime.licensePath = 'licenses/llama-license.txt'
    $fixtureManifest.runtime.licenseFileBytes = (Get-Item -LiteralPath (Join-Path $fixtureLicenseDirectory 'llama-license.txt') -Force).Length
    $fixtureManifest.runtime.licenseFileSha256 = Get-Sha256 (Join-Path $fixtureLicenseDirectory 'llama-license.txt')
    $fixtureManifest.runtime.archive.entryPolicy.allowedExactEntries = @('runtime-fixture.txt')
    $fixtureManifest.runtime.archive.entryPolicy.allowedEntryPatterns = @('^runtime-fixture\.txt$')
    $fixtureManifest.runtime.archive.entryPolicy.requiredEntries = @('runtime-fixture.txt')
    $fixtureManifest.runtime.archive.entryPolicy.entryCount = 1
    $fixtureManifest.runtime.archive.entryPolicy.entryNamesSha256 = '6be703bcfe25a929528e331f8886a00405348c71d1efaf8d6695ef42dbb9e0db'
    $fixtureManifest.licenseNotice.path = 'source-notice.txt'
    $fixtureManifest.licenseNotice.bytes = (Get-Item -LiteralPath (Join-Path $testRoot 'source-notice.txt') -Force).Length
    $fixtureManifest.licenseNotice.sha256 = Get-Sha256 (Join-Path $testRoot 'source-notice.txt')
    $fixtureManifestPath = Join-Path $testRoot 'fixture-manifest.json'
    Write-Utf8Json $fixtureManifestPath $fixtureManifest

    $planOutput = Join-Path $testRoot 'plan-output'
    $plan = & $fetchScript -ManifestPath $fixtureManifestPath -OutputDirectory $planOutput -PlanOnly -FixtureMode
    Assert-True ($plan.Mode -eq 'plan' -and $plan.Staged -eq $false -and $plan.NetworkUsed -eq $false) 'Default plan mode did not stay offline/non-mutating.'
    Assert-True (-not (Test-Path -LiteralPath $planOutput)) 'Plan mode created the output directory.'

    Assert-Rejected { & $fetchScript -ManifestPath $fixtureManifestPath -Fetch -FixtureMode } 'not implemented'
    $outsideOutput = Join-Path $repository '..\ai-runtime-outside-test'
    Assert-Rejected { & $fetchScript -ManifestPath $fixtureManifestPath -ModelPath $modelFixturePath -RuntimeArchivePath $runtimeFixturePath -OutputDirectory $outsideOutput -Stage -FixtureMode } 'below the repository .local boundary|Path traversal'
    Assert-True (-not (Test-Path -LiteralPath $outsideOutput)) 'Unsafe output test created a caller path.'

    $unmanagedOutput = Join-Path $testRoot 'unmanaged-output'
    New-Item -ItemType Directory -Path $unmanagedOutput -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $unmanagedOutput 'caller.txt'), 'caller data')
    Assert-Rejected { & $fetchScript -ManifestPath $fixtureManifestPath -ModelPath $modelFixturePath -RuntimeArchivePath $runtimeFixturePath -OutputDirectory $unmanagedOutput -Stage -FixtureMode } 'Unmanaged staging entry'
    Remove-Item -LiteralPath (Join-Path $unmanagedOutput 'caller.txt') -Force

    $stagedOutput = Join-Path $testRoot 'staged-output'
    $staged = & $fetchScript -ManifestPath $fixtureManifestPath -ModelPath $modelFixturePath -RuntimeArchivePath $runtimeFixturePath -OutputDirectory $stagedOutput -Stage -FixtureMode
    Assert-True ($staged.Mode -eq 'stage' -and $staged.RuntimeEntries -eq 1 -and $staged.NetworkUsed -eq $false) 'Valid synthetic staging did not produce the expected receipt.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stagedOutput 'model\model-fixture.bin') -PathType Leaf) 'Staged model fixture is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stagedOutput 'runtime\runtime-fixture.txt') -PathType Leaf) 'Extracted runtime fixture is missing.'
    $receiptPath = Join-Path $stagedOutput 'STAGING-RECEIPT.json'
    Assert-True (Test-Path -LiteralPath $receiptPath -PathType Leaf) 'Staging receipt is missing.'
    $receipt = [IO.File]::ReadAllText($receiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-True ($receipt.model.sha256 -eq $modelFixtureSha -and @($receipt.runtime.entries).Count -eq 1) 'Staging receipt is incomplete.'

    # A receipt may be packaged, compared across machines, and re-parsed by the
    # launch-plan seam. It must therefore carry portable relative identities
    # only: no host absolute paths and no serialized PowerShell object graphs
    # (FileInfo/DirectoryInfo expand into PSDrive/Credential/MetadataToken keys).
    $receiptText = [IO.File]::ReadAllText($receiptPath, [Text.Encoding]::UTF8)
    Assert-True ($receiptText -notmatch '[A-Za-z]:\\\\') 'Staging receipt leaks a host absolute path.'
    Assert-True ($receiptText -notmatch '\\\\\\\\[A-Za-z0-9._-]+\\\\') 'Staging receipt leaks a UNC path.'
    foreach ($forbiddenKey in @('PSDrive', 'PSProvider', 'Credential', 'Password', 'MetadataToken', 'DirectoryName')) {
        Assert-True ($receiptText -notmatch ('"' + $forbiddenKey + '"')) "Staging receipt leaks a serialized PowerShell object graph key: $forbiddenKey"
    }
    Assert-True ($receipt.manifest.path -is [string] -and $receipt.manifest.path -notmatch '^[A-Za-z]:') 'Staging receipt manifest identity is not a portable relative string.'
    Assert-True ($receipt.model.staged -is [string] -and $receipt.model.staged -eq 'model/model-fixture.bin') 'Staging receipt model.staged is not the portable relative layout.'
    Assert-True ($receipt.runtime.stagedDirectory -is [string] -and $receipt.runtime.stagedDirectory -eq 'runtime') 'Staging receipt runtime.stagedDirectory is not the portable relative layout.'
    Assert-True ($receipt.notice.path -is [string] -and $receipt.notice.path -eq 'THIRD-PARTY-NOTICES.txt') 'Staging receipt notice identity is not the portable relative layout.'

    [IO.File]::AppendAllText($modelFixturePath, 'tamper')
    Assert-Rejected { & $fetchScript -ManifestPath $fixtureManifestPath -ModelPath $modelFixturePath -RuntimeArchivePath $runtimeFixturePath -OutputDirectory $stagedOutput -Stage -FixtureMode } 'Wrong (size|SHA-256)'
    [IO.File]::WriteAllText($modelFixturePath, 'offline model fixture; not a model asset', (New-Object Text.UTF8Encoding($false)))
    $fixtureManifest.model.weight.bytes = $modelFixtureBytes + 1
    Write-Utf8Json $fixtureManifestPath $fixtureManifest
    Assert-Rejected { & $fetchScript -ManifestPath $fixtureManifestPath -ModelPath $modelFixturePath -RuntimeArchivePath $runtimeFixturePath -OutputDirectory $stagedOutput -Stage -FixtureMode } 'Wrong size'
    $fixtureManifest.model.weight.bytes = $modelFixtureBytes
    Write-Utf8Json $fixtureManifestPath $fixtureManifest
    $runtimeOriginalBytes = [IO.File]::ReadAllBytes($runtimeFixturePath)
    [IO.File]::AppendAllText($runtimeFixturePath, 'tamper')
    Assert-Rejected { & $fetchScript -ManifestPath $fixtureManifestPath -ModelPath $modelFixturePath -RuntimeArchivePath $runtimeFixturePath -OutputDirectory $stagedOutput -Stage -FixtureMode } 'Wrong (size|SHA-256)'
    [IO.File]::WriteAllBytes($runtimeFixturePath, $runtimeOriginalBytes)

    $missingModel = Join-Path $testRoot 'missing-fixture.bin'
    Assert-Rejected { & $fetchScript -ManifestPath $fixtureManifestPath -ModelPath $missingModel -RuntimeArchivePath $runtimeFixturePath -OutputDirectory (Join-Path $testRoot 'missing-output') -Stage -FixtureMode } 'Path is missing|Missing model weight input'
    $missingRuntime = Join-Path $testRoot 'missing-runtime.zip'
    Assert-Rejected { & $fetchScript -ManifestPath $fixtureManifestPath -ModelPath $modelFixturePath -RuntimeArchivePath $missingRuntime -OutputDirectory (Join-Path $testRoot 'missing-runtime-output') -Stage -FixtureMode } 'Path is missing|Missing runtime archive input'

    $badZips = @(
        @{ Name = 'unexpected.zip'; Entries = @([pscustomobject]@{ Name = 'unexpected.txt'; Text = 'no' }); Pattern = 'Unexpected runtime archive entry' },
        @{ Name = 'traversal.zip'; Entries = @([pscustomobject]@{ Name = '../escape.txt'; Text = 'no' }); Pattern = 'Path traversal|empty path segment' },
        @{ Name = 'absolute.zip'; Entries = @([pscustomobject]@{ Name = '/absolute.txt'; Text = 'no' }); Pattern = 'Absolute paths' },
        @{ Name = 'duplicate.zip'; Entries = @([pscustomobject]@{ Name = 'runtime-fixture.txt'; Text = 'one' }, [pscustomobject]@{ Name = 'runtime-fixture.txt'; Text = 'two' }); Pattern = 'Duplicate runtime archive entry' }
    )
    foreach ($case in $badZips) {
        $badPath = Join-Path $testRoot $case.Name
        New-FixtureZip $badPath $case.Entries
        $fixtureManifest.runtime.asset.fileName = $case.Name
        $fixtureManifest.runtime.asset.bytes = (Get-Item -LiteralPath $badPath -Force).Length
        $fixtureManifest.runtime.asset.sha256 = Get-Sha256 $badPath
        Write-Utf8Json $fixtureManifestPath $fixtureManifest
        Assert-Rejected { & $fetchScript -ManifestPath $fixtureManifestPath -ModelPath $modelFixturePath -RuntimeArchivePath $badPath -OutputDirectory (Join-Path $testRoot ('bad-' + $case.Name)) -Stage -FixtureMode } $case.Pattern
    }

    # A symlink-mode ZIP entry is rejected when the .NET runtime exposes the
    # ExternalAttributes setter.  The traversal/absolute tests above remain
    # mandatory on every supported PowerShell version.
    $symlinkPath = Join-Path $testRoot 'symlink.zip'
    $symlinkCreated = $false
    try {
        New-FixtureZip $symlinkPath @([pscustomobject]@{ Name = 'runtime-fixture.txt'; Text = 'link'; ExternalAttributes = [int32]0xA0000000 })
        $symlinkCreated = $true
    } catch {
        $symlinkCreated = $false
    }
    if ($symlinkCreated) {
        $fixtureManifest.runtime.asset.fileName = 'symlink.zip'
        $fixtureManifest.runtime.asset.bytes = (Get-Item -LiteralPath $symlinkPath -Force).Length
        $fixtureManifest.runtime.asset.sha256 = Get-Sha256 $symlinkPath
        Write-Utf8Json $fixtureManifestPath $fixtureManifest
        Assert-Rejected { & $fetchScript -ManifestPath $fixtureManifestPath -ModelPath $modelFixturePath -RuntimeArchivePath $symlinkPath -OutputDirectory (Join-Path $testRoot 'bad-symlink') -Stage -FixtureMode } 'symlink|reparse'
    }

    [pscustomobject]@{
        Status = 'PASS'
        SyntheticModelBytes = $modelFixtureBytes
        SyntheticArchiveBytes = $runtimeFixtureBytes
        PlanMode = $true
        ValidStage = $true
        HashRejection = $true
        PathRejection = $true
        UnmanagedEntryRejection = $true
        NetworkUsed = $false
        SymlinkEntryTested = $symlinkCreated
    } | Format-List
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $allowedPrefix = [IO.Path]::GetFullPath((Join-Path $testResultsRoot 'airuntime-staging-'))
    if ($resolvedTestRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot) -like 'airuntime-staging-*') {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
