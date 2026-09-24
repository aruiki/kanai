# Windows-side smoke harness for the pinned upstream Mozc x64 TSF TIP.
#
# This harness never registers, unregisters, enables, or modifies a TIP. It
# validates repository/artifact/registration evidence, loads the exact DLL, and
# delegates the real application interaction to an explicit host-test process.
# A missing DLL, runtime, app, or TSF host is a reported failure, never a pass.

<#
.SYNOPSIS
Runs the pinned upstream Mozc x64 TIP vertical-slice smoke test.
.DESCRIPTION
The script validates the repository gitlink, prepared source identity, x64 PE,
exports, dependencies, live Registry64 metadata, loader, TSF runtime, and an
external real-host receipt. It never changes registration. PreflightOnly can
prove static/artifact prerequisites but intentionally returns status not-run.
.PARAMETER MozcStage
A prepared Mozc source directory or its parent. It is compared with the pinned
checkout before its TIP output is considered.
.PARAMETER TipDll
The exact mozc_tip64.dll to test. An installed/copied path outside the pinned
roots requires -ExpectedTipSha256.
.PARAMETER HostTestPath
An x64 .ps1 or .exe host driver that follows host-test-plan.json and writes its
JSON receipt. No synthetic host pass is generated when this is absent.
#>

[CmdletBinding()]
param(
    [Alias('RepoRoot')]
    [string]$RepositoryRoot = '',
    [Alias('MozcWorkspace', 'PinnedMozcStage')]
    [string]$MozcStage = '',
    [Alias('ArtifactPath', 'Artifact', 'MozcTipDll', 'TipDllPath')]
    [string]$TipDll = '',
    [string]$RuntimeRoot = '',
    [Alias('OutputPath', 'SmokeResultPath', 'ReceiptPath')]
    [string]$ResultPath = '',
    [Alias('HostPath', 'TestHostPath')]
    [string]$HostTestPath = '',
    [Alias('AppPath', 'TestAppPath')]
    [string]$ApplicationPath = '',
    [string]$ExpectedTipSha256 = '',
    [Alias('StaticOnly', 'SourceOnly')]
    [switch]$PreflightOnly,
    [Alias('NoVsDevCmd')]
    [switch]$SkipVsDevCmd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'Smoke.Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "Pinned-Mozc TSF smoke helpers are missing: $commonPath"
}
. $commonPath

function Get-SmokeRepositoryRoot {
    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        return Resolve-TsfSmokePath -Path $RepositoryRoot -BasePath $PSScriptRoot
    }
    # <repo>/platform/windows-tsf/smoke -> <repo>
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
}

$repository = Get-SmokeRepositoryRoot
$contractPath = Join-Path $PSScriptRoot 'contract.json'
$planPath = Join-Path $PSScriptRoot 'host-test-plan.json'
foreach ($requiredPath in @($contractPath, $planPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required pinned-Mozc TSF smoke contract is missing: $requiredPath"
    }
}
$contract = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
$hostPlan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
# Normalize the JSON arrays explicitly so scalar and singleton contracts remain
# safe on Windows PowerShell 5.1.
$requiredTestIds = @(Get-TsfSmokeProperty -Object $contract -Name 'windowsRequiredTestIds')
$staticTestIds = @(Get-TsfSmokeProperty -Object $contract -Name 'staticTestIds')
if ($requiredTestIds.Count -eq 0 -or $staticTestIds.Count -eq 0) {
    throw 'contract.json has no smoke-test IDs.'
}

if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path ([System.IO.Path]::GetTempPath()) 'kanai-tsf-windows-smoke-result.json'
}
else {
    $ResultPath = Resolve-TsfSmokePath -Path $ResultPath -BasePath $repository
}

$startedAtUtc = [DateTime]::UtcNow
$script:SmokeFailures = @()
$script:SmokeResultStatus = 'not-run'
$script:SmokeTests = [ordered]@{}
foreach ($testId in $requiredTestIds) {
    $script:SmokeTests[[string]$testId] = [pscustomobject]@{
        id = [string]$testId
        status = 'not-run'
        evidence = 'Not run.'
    }
}

function Set-SmokeTestPassed {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Evidence
    )
    if (-not $script:SmokeTests.Contains($Id)) {
        throw "Cannot record unknown smoke-test ID: $Id"
    }
    $script:SmokeTests[$Id].status = 'passed'
    $script:SmokeTests[$Id].evidence = $Evidence
}

function Add-SmokeFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Remediation
    )

    $testId = if ([string]::IsNullOrWhiteSpace($Id)) { 'pinned-mozc-source' } else { $Id }
    if (-not $script:SmokeTests.Contains($testId)) {
        throw "Cannot fail unknown smoke-test ID: $testId"
    }
    $script:SmokeTests[$testId].status = 'failed'
    $script:SmokeTests[$testId].evidence = $Message
    $script:SmokeFailures += [pscustomobject]@{
        testId = $testId
        code = $Code
        message = $Message
        remediation = $Remediation
    }
}

function Set-SmokeTestNotRun {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    if (-not $script:SmokeTests.Contains($Id)) {
        throw "Cannot record unknown smoke-test ID: $Id"
    }
    $script:SmokeTests[$Id].status = 'not-run'
    $script:SmokeTests[$Id].evidence = $Reason
}

function Write-SmokeResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        $Details = $null
    )

    $tests = @($script:SmokeTests.Values)
    $result = [ordered]@{
        schemaVersion = 1
        status = $Status
        claim = 'phase1-smoke-evidence-only-not-a-public-beta'
        startedAtUtc = $startedAtUtc.ToString('o')
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        repositoryRoot = $repository
        contract = [ordered]@{
            id = [string](Get-TsfSmokeProperty -Object $contract -Name 'id')
            path = $contractPath
            hostPlanPath = $planPath
        }
        environment = [ordered]@{
            os = [System.Environment]::OSVersion.VersionString
            is64BitOperatingSystem = [System.Environment]::Is64BitOperatingSystem
            is64BitProcess = [System.Environment]::Is64BitProcess
            powerShell = $PSVersionTable.PSVersion.ToString()
        }
        requiredTestIds = @($requiredTestIds)
        tests = $tests
        failures = @($script:SmokeFailures)
        details = if ($null -eq $Details) { [ordered]@{} } else { $Details }
        message = $Message
    }
    Write-TsfSmokeJsonFile -Path $ResultPath -Value $result
    $script:SmokeResultStatus = $Status
    return $ResultPath
}

function Invoke-SmokeGit {
    param(
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $GitPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { [string]$_ })
        Text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }
}

function Invoke-SmokeDumpbin {
    param(
        [Parameter(Mandatory = $true)][string]$DumpbinPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        Push-Location -LiteralPath 'C:\Windows'
        try {
            $output = @(& $DumpbinPath '/nologo' @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }
}

function Resolve-SmokeTipDll {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExplicitPath
    )

    $expectedName = [string](Get-TsfSmokeProperty -Object (Get-TsfSmokeProperty -Object $contract -Name 'artifact') -Name 'fileName')
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = Resolve-TsfSmokePath -Path $ExplicitPath -BasePath $Repository
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "The pinned Mozc TIP artifact does not exist: $resolved"
        }
        if ([System.IO.Path]::GetFileName($resolved) -ine $expectedName) {
            throw "The x64 TIP filename must be '$expectedName', not '$([System.IO.Path]::GetFileName($resolved))'."
        }
        return $resolved
    }

    $roots = @(
        $Stage
        (Join-Path $Stage 'src')
        (Join-Path $Repository 'third_party\mozc')
        (Join-Path $Repository 'third_party\mozc\src')
    ) | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { return $null }
        [System.IO.Path]::GetFullPath($_)
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $candidates = @()
    foreach ($root in $roots) {
        $candidate = Join-Path $root (Join-Path 'bazel-bin\win32\tip' $expectedName)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $candidates += [System.IO.Path]::GetFullPath($candidate)
        }
    }
    $candidates = @($candidates | Select-Object -Unique)
    if ($candidates.Count -eq 0) {
        throw "No '$expectedName' was found under a pinned Mozc Bazel stage. Pass -MozcStage or -TipDll explicitly."
    }
    if ($candidates.Count -gt 1) {
        throw "More than one '$expectedName' was found; pass -TipDll explicitly: $($candidates -join ', ')"
    }
    return [string]$candidates[0]
}

function Get-StageSourceDirectory {
    param([Parameter(Mandatory = $true)][string]$Stage)

    if (Test-Path -LiteralPath (Join-Path $Stage 'MODULE.bazel') -PathType Leaf) {
        return $Stage
    }
    $nested = Join-Path $Stage 'src'
    if (Test-Path -LiteralPath (Join-Path $nested 'MODULE.bazel') -PathType Leaf) {
        return $nested
    }
    return ''
}

function Test-PinnedMozcSource {
    $pin = Get-TsfSmokeProperty -Object $contract -Name 'pinnedMozc'
    $expectedCommit = [string](Get-TsfSmokeProperty -Object $pin -Name 'commit')
    $mozcRoot = Join-Path $repository 'third_party\mozc'
    $workspace = Join-Path $mozcRoot 'src'
    $git = Get-TsfSmokeCommandPath -Name 'git.exe'
    if ($null -eq $git) {
        $git = Get-TsfSmokeCommandPath -Name 'git'
    }

    $details = [ordered]@{
        expectedCommit = $expectedCommit
        repositoryGitlink = $null
        checkedOutCommit = $null
        bazelVersion = $null
        stageSource = $null
        stageCommitMarker = $null
    }
    try {
        if ($null -eq $git) {
            throw 'Git is required to verify the repository gitlink and checked-out Mozc commit.'
        }
        if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
            throw "The pinned Mozc workspace is missing: $workspace. Initialize the submodule before testing."
        }

        $tree = Invoke-SmokeGit -GitPath $git -Arguments @(
            '-c', 'safe.directory=*', '-c', 'core.filemode=false', '-c', 'core.autocrlf=false',
            '-C', $repository, 'ls-tree', 'HEAD', '--', 'third_party/mozc'
        )
        if ($tree.ExitCode -ne 0 -or $tree.Text -notmatch ('\b' + [regex]::Escape($expectedCommit) + '\b')) {
            throw "The repository gitlink for third_party/mozc is not pinned to $expectedCommit. Git output: $($tree.Text)"
        }
        $details.repositoryGitlink = $expectedCommit

        $commit = Invoke-SmokeGit -GitPath $git -Arguments @(
            '-c', 'safe.directory=*', '-c', 'core.filemode=false', '-c', 'core.autocrlf=false',
            '-C', $mozcRoot, 'rev-parse', 'HEAD'
        )
        $actualCommit = ([string]($commit.Output | Where-Object { [string]$_ -match '^[0-9a-fA-F]{40}$' } | Select-Object -First 1)).Trim()
        if ($commit.ExitCode -ne 0 -or $actualCommit -ine $expectedCommit) {
            throw "The checked-out Mozc commit is '$actualCommit', expected '$expectedCommit'."
        }
        $details.checkedOutCommit = $actualCommit

        $status = Invoke-SmokeGit -GitPath $git -Arguments @(
            '-c', 'safe.directory=*', '-c', 'core.filemode=false', '-c', 'core.autocrlf=false',
            '-C', $mozcRoot, 'status', '--porcelain', '--untracked-files=no'
        )
        if ($status.ExitCode -ne 0) {
            throw "Unable to inspect the pinned Mozc checkout: $($status.Text)"
        }
        $trackedChanges = @($status.Output | Where-Object {
            [string]$_ -match '^[ MADRCU?!]{2}\s+'
        })
        if ($trackedChanges.Count -ne 0) {
            throw "The pinned Mozc checkout has tracked changes and is not reproducible:`n$($trackedChanges -join "`n")"
        }

        $bazelisk = Join-Path $workspace '.bazeliskrc'
        $bazelText = Get-Content -LiteralPath $bazelisk -Raw
        $bazelMatch = [regex]::Match($bazelText, '(?m)^\s*USE_BAZEL_VERSION\s*=\s*([0-9]+\.[0-9]+\.[0-9]+)')
        $expectedBazel = [string](Get-TsfSmokeProperty -Object $pin -Name 'bazelVersion')
        if (-not $bazelMatch.Success -or $bazelMatch.Groups[1].Value -ne $expectedBazel) {
            throw "The pinned Mozc .bazeliskrc does not select Bazel $expectedBazel."
        }
        $details.bazelVersion = $expectedBazel

        $tipBuild = Get-Content -LiteralPath (Join-Path $workspace 'win32\tip\BUILD.bazel') -Raw
        $target = [string](Get-TsfSmokeProperty -Object $pin -Name 'x64TipTarget')
        $targetLeaf = $target.Substring($target.LastIndexOf('/') + 1)
        $targetName = $targetLeaf.Substring($targetLeaf.IndexOf(':') + 1)
        if ($tipBuild -notmatch ('name\s*=\s*"' + [regex]::Escape($targetName) + '"') -or
            $tipBuild -notmatch 'platform\s*=\s*"//:windows-x86_64"') {
            throw "The pinned Mozc source does not expose the x64 target $target."
        }
        $definition = Get-Content -LiteralPath (Join-Path $workspace 'win32\tip\mozc_tip.def') -Raw
        foreach ($export in @(Get-TsfSmokeArrayProperty -Object (Get-TsfSmokeProperty -Object $contract -Name 'artifact') -Name 'requiredExports')) {
            if ($definition -notmatch ('(?m)^\s*' + [regex]::Escape([string]$export) + '\s+PRIVATE')) {
                throw "The pinned Mozc TIP definition does not declare required export '$export'."
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($MozcStage)) {
            $stageSource = Get-StageSourceDirectory -Stage $MozcStage
            if ([string]::IsNullOrWhiteSpace($stageSource)) {
                throw "MozcStage is not a prepared Mozc source stage (MODULE.bazel missing): $MozcStage"
            }
            $details.stageSource = $stageSource
            $stageBazelisk = Join-Path $stageSource '.bazeliskrc'
            if (Test-Path -LiteralPath $stageBazelisk -PathType Leaf) {
                $stageBazelText = Get-Content -LiteralPath $stageBazelisk -Raw
                $stageBazelMatch = [regex]::Match($stageBazelText, '(?m)^\s*USE_BAZEL_VERSION\s*=\s*([0-9]+\.[0-9]+\.[0-9]+)')
                if (-not $stageBazelMatch.Success -or $stageBazelMatch.Groups[1].Value -ne $expectedBazel) {
                    throw "The prepared Mozc stage does not select the pinned Bazel $expectedBazel."
                }
            }
            # The patch used by the TSF integration changes engine files, not
            # the TIP identity/registration files. Compare the exact source
            # inputs that determine the x64 TIP artifact, normalizing checkout
            # line endings so a native Git checkout and git archive agree.
            foreach ($relativeSourceFile in @(
                'win32\tip\BUILD.bazel',
                'win32\tip\mozc_tip.def',
                'win32\tip\mozc_tip_main.cc',
                'win32\base\tsf_profile.cc',
                'win32\base\tsf_registrar.cc'
            )) {
                $stageFile = Join-Path $stageSource $relativeSourceFile
                $referenceFile = Join-Path $workspace $relativeSourceFile
                if (-not (Test-Path -LiteralPath $stageFile -PathType Leaf) -or
                    -not (Test-Path -LiteralPath $referenceFile -PathType Leaf)) {
                    throw "The prepared Mozc stage is missing TIP identity source '$relativeSourceFile'."
                }
                $stageText = [System.IO.File]::ReadAllText($stageFile).Replace("`r`n", "`n").Replace("`r", "`n")
                $referenceText = [System.IO.File]::ReadAllText($referenceFile).Replace("`r`n", "`n").Replace("`r", "`n")
                if (-not [string]::Equals($stageText, $referenceText, [System.StringComparison]::Ordinal)) {
                    throw "The prepared Mozc stage source '$relativeSourceFile' differs from the pinned checkout."
                }
            }
            $details.stageSourceFilesVerified = @(
                'win32/tip/BUILD.bazel',
                'win32/tip/mozc_tip.def',
                'win32/tip/mozc_tip_main.cc',
                'win32/base/tsf_profile.cc',
                'win32/base/tsf_registrar.cc'
            )
            $markerCandidates = @(
                (Join-Path $MozcStage '.kanai-pinned-commit'),
                (Join-Path (Split-Path -Parent $stageSource) '.kanai-pinned-commit')
            )
            foreach ($marker in $markerCandidates) {
                if (Test-Path -LiteralPath $marker -PathType Leaf) {
                    $markerCommit = [System.IO.File]::ReadAllText($marker).Trim()
                    if ($markerCommit -ine $expectedCommit) {
                        throw "The Mozc stage marker '$markerCommit' does not match the pinned commit '$expectedCommit'."
                    }
                    $details.stageCommitMarker = $marker
                    break
                }
            }
        }

        Set-SmokeTestPassed -Id 'pinned-mozc-source' -Evidence (
            'Repository gitlink and clean checkout are {0}; Bazel is {1}; x64 target is {2}.' -f
            $expectedCommit, $expectedBazel, $target
        )
    }
    catch {
        Add-SmokeFailure -Id 'pinned-mozc-source' -Code 'PINNED_MOZC_SOURCE_MISMATCH' -Message $_.Exception.Message -Remediation 'Initialize the exact third_party/mozc gitlink, remove tracked Mozc changes, and use the pinned Bazel stage. Do not substitute a floating checkout.'
    }
    return $details
}

function Test-RegistrationMetadata {
    $registration = Get-TsfSmokeProperty -Object $contract -Name 'registration'
    $expectedCommit = [string](Get-TsfSmokeProperty -Object (Get-TsfSmokeProperty -Object $contract -Name 'pinnedMozc') -Name 'commit')
    try {
        $integrationPath = Join-Path $repository 'platform\windows-tsf\tsf\metadata\tsf-integration.json'
        $registrationPath = Join-Path $repository 'platform\windows-tsf\registration\registration.json'
        $manifestPath = Join-Path $repository 'platform\windows-tsf\registration\registry-manifest.json'
        $toolchainPath = Join-Path $repository 'platform\windows-tsf\build\toolchain.json'
        foreach ($path in @($integrationPath, $registrationPath, $manifestPath, $toolchainPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required registration metadata is missing: $path"
            }
        }
        $integration = Get-Content -LiteralPath $integrationPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $projected = Get-Content -LiteralPath $registrationPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $toolchain = Get-Content -LiteralPath $toolchainPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $integrationRegistration = $integration.registration
        $projectedReference = $projected.registrationIdentity.pinnedMozcReference
        $manifestReference = $manifest.pinnedMozcReference
        $expectedClsid = [string](Get-TsfSmokeProperty -Object $registration -Name 'textServiceClsid')
        $expectedProfile = [string](Get-TsfSmokeProperty -Object $registration -Name 'languageProfileGuid')
        $expectedLanguage = [string](Get-TsfSmokeProperty -Object $registration -Name 'languageId')
        $threadingModel = [string](Get-TsfSmokeProperty -Object $registration -Name 'threadingModel')
        $toolchainExports = @(Get-TsfSmokeArrayProperty -Object (Get-TsfSmokeProperty -Object $toolchain -Name 'dll') -Name 'requiredExports')
        $contractExports = @(Get-TsfSmokeArrayProperty -Object (Get-TsfSmokeProperty -Object $contract -Name 'artifact') -Name 'requiredExports')
        if ([string]$integration.host.commit -ine $expectedCommit -or
            [string]$toolchain.mozc.gitlink -ine $expectedCommit -or
            [string]$toolchain.target -ine 'x86_64-pc-windows-msvc' -or
            $toolchainExports.Count -ne $contractExports.Count -or
            @($contractExports | Where-Object { $toolchainExports -cnotcontains [string]$_ }).Count -ne 0) {
            throw 'The integration/toolchain metadata does not use the contract Mozc commit/x64 export policy.'
        }
        if ([string]$integrationRegistration.ossTextServiceClsid -ine $expectedClsid -or
            [string]$integrationRegistration.ossLanguageProfileGuid -ine $expectedProfile -or
            [string]$integrationRegistration.languageId -ine $expectedLanguage -or
            [string]$projectedReference.textServiceClsid -ine $expectedClsid -or
            [string]$projectedReference.languageProfileGuid -ine $expectedProfile -or
            [string]$manifestReference.textServiceClsid -ine $expectedClsid -or
            [string]$manifestReference.languageProfileGuid -ine $expectedProfile) {
            throw 'The pinned upstream Mozc CLSID/profile metadata disagrees across project files.'
        }
        if ($projectedReference.mustNotBeRegisteredAsKanaAI -ne $true -or
            $manifestReference.mustNotBeRegisteredAsKanaAI -ne $true -or
            $integrationRegistration.kanaiProductRegistrationReady -ne $false -or
            $projected.registrationIdentity.identityApproved -ne $false -or
            $manifest.identityApproved -ne $false) {
            throw 'The smoke contract must remain pinned to upstream Mozc and must not authorize a KanaAI registration identity.'
        }
        if ([string]$integrationRegistration.provisionalKanaAiTextServiceClsid -ieq $expectedClsid -or
            [string]$integrationRegistration.provisionalKanaAiProfileGuid -ieq $expectedProfile) {
            throw 'The pinned upstream and provisional KanaAI registration identities must remain distinct.'
        }
        $manifestLanguage = [string]$manifest.languageId
        if ($manifestLanguage -notin @('0x0411', '0x00000411') -or
            [int]$manifest.languageProfile.languageIdDecimal -ne [int](Get-TsfSmokeProperty -Object $registration -Name 'languageIdDecimal') -or
            [string]$manifest.registryViews.x64 -ine [string](Get-TsfSmokeProperty -Object $registration -Name 'registryView')) {
            throw 'The pinned Mozc language or Registry64 metadata is inconsistent.'
        }
        if ([int]$projected.registry.textServiceValues.EnableCompartment.value -ne 1 -or
            [int]$projected.registry.textServiceValues.LoadBehavior.value -ne 0 -or
            [string]$projected.textService.threadingModel -ine $threadingModel) {
            throw 'The pinned TSF registration value/threading contract is inconsistent.'
        }
        $profileSourcePath = Join-Path $repository 'third_party\mozc\src\win32\base\tsf_profile.cc'
        $registrarSourcePath = Join-Path $repository 'third_party\mozc\src\win32\base\tsf_registrar.cc'
        $profileSource = Get-Content -LiteralPath $profileSourcePath -Raw -Encoding UTF8
        $registrarSource = Get-Content -LiteralPath $registrarSourcePath -Raw -Encoding UTF8
        $clsidNeedle = $expectedClsid.Replace('-', '').Replace('{', '').Replace('}', '')
        $profileNeedle = $expectedProfile.Replace('-', '').Replace('{', '').Replace('}', '')
        if ($profileSource -notmatch ('(?i)0x' + $clsidNeedle.Substring(0, 8)) -or
            $profileSource -notmatch ('(?i)0x' + $profileNeedle.Substring(0, 8)) -or
            $profileSource -notmatch 'LANG_JAPANESE' -or
            $registrarSource -notmatch 'kTipTextServiceModel(?:\[\])?\s*=\s*L"Apartment"') {
            throw 'The pinned Mozc source profile/registrar constants disagree with the registration contract.'
        }

        Set-SmokeTestPassed -Id 'registration-metadata' -Evidence (
            'Pinned upstream identity is {0} / {1} at {2}; Registry64; KanaAI identity remains unapproved.' -f
            $expectedClsid, $expectedProfile, $expectedLanguage
        )
    }
    catch {
        Add-SmokeFailure -Id 'registration-metadata' -Code 'REGISTRATION_METADATA_MISMATCH' -Message $_.Exception.Message -Remediation 'Restore consistent pinned-upstream Mozc identity metadata. Do not register or relabel it as KanaAI.'
    }
}

function Test-LiveRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$TestedDll,
        [Parameter(Mandatory = $true)][string]$TestedSha256
    )

    $registration = Get-TsfSmokeProperty -Object $contract -Name 'registration'
    $clsid = [string](Get-TsfSmokeProperty -Object $registration -Name 'textServiceClsid')
    $profile = [string](Get-TsfSmokeProperty -Object $registration -Name 'languageProfileGuid')
    $language = [int](Get-TsfSmokeProperty -Object $registration -Name 'languageIdDecimal')
    $threadingModel = [string](Get-TsfSmokeProperty -Object $registration -Name 'threadingModel')
    try {
        $views = @(
            [pscustomobject]@{ Hive = 'LocalMachine'; Label = 'HKLM/Registry64' },
            [pscustomobject]@{ Hive = 'CurrentUser'; Label = 'HKCU/Registry64' }
        )
        $comRecords = @()
        $profileRecords = @()
        foreach ($view in $views) {
            $hive = [Microsoft.Win32.RegistryHive]::$($view.Hive)
            $comKey = "SOFTWARE\Classes\CLSID\$clsid\InProcServer32"
            $comPath = Get-TsfSmokeRegistryValue -Hive $hive -View ([Microsoft.Win32.RegistryView]::Registry64) -SubKey $comKey -Name ''
            if ($comPath.Found) {
                $comRecords += [pscustomobject]@{ View = $view.Label; Path = [string]$comPath.Value }
            }
            foreach ($languageSegment in @('0x0411', '0x00000411')) {
                $profileKey = "SOFTWARE\Microsoft\CTF\TIP\$clsid\LanguageProfile\$languageSegment\$profile"
                $languageValue = Get-TsfSmokeRegistryValue -Hive $hive -View ([Microsoft.Win32.RegistryView]::Registry64) -SubKey $profileKey -Name 'Language'
                if ($languageValue.Found) {
                    $profileRecords += [pscustomobject]@{
                        View = $view.Label
                        Key = $profileKey
                        Language = [int]$languageValue.Value
                    }
                    break
                }
            }
        }
        if ($comRecords.Count -eq 0) {
            throw "The pinned Mozc x64 COM/TIP metadata is not installed in HKLM or HKCU Registry64: CLSID $clsid."
        }
        if ($profileRecords.Count -eq 0) {
            throw "The pinned Mozc Japanese language profile is not installed in HKLM or HKCU Registry64: $profile."
        }
        $badLanguage = @($profileRecords | Where-Object { $_.Language -ne $language })
        if ($badLanguage.Count -gt 0) {
            throw "The live Mozc language profile reports LANGID '$($badLanguage[0].Language)', expected $language."
        }

        $selectedCom = $null
        foreach ($record in $comRecords) {
            $threading = Get-TsfSmokeRegistryValue -Hive ([Microsoft.Win32.RegistryHive]::$($record.View.Split('/')[0])) -View ([Microsoft.Win32.RegistryView]::Registry64) -SubKey "SOFTWARE\Classes\CLSID\$clsid\InProcServer32" -Name 'ThreadingModel'
            if (-not $threading.Found -or [string]$threading.Value -ine $threadingModel) {
                throw "The live Mozc COM ThreadingModel is missing or is not '$threadingModel' in $($record.View)."
            }
            $registeredPath = ([string]$record.Path).Trim().Trim('"')
            $registeredPath = [System.Environment]::ExpandEnvironmentVariables($registeredPath)
            if (-not (Test-Path -LiteralPath $registeredPath -PathType Leaf)) {
                throw "The registered Mozc TIP path does not exist: $registeredPath"
            }
            $registeredHash = Get-TsfSmokeSha256 -Path $registeredPath
            if ($registeredHash -ine $TestedSha256) {
                throw "The registered TIP bytes do not match the tested artifact. Registered=$registeredPath ($registeredHash); tested=$TestedDll ($TestedSha256)."
            }
            if ($null -eq $selectedCom) {
                $selectedCom = $record
            }
        }

        $iconRecords = @()
        foreach ($record in $profileRecords) {
            $hive = [Microsoft.Win32.RegistryHive]::$($record.View.Split('/')[0])
            $icon = Get-TsfSmokeRegistryValue -Hive $hive -View ([Microsoft.Win32.RegistryView]::Registry64) -SubKey $record.Key -Name 'IconFile'
            if (-not $icon.Found -or [string]::IsNullOrWhiteSpace([string]$icon.Value)) {
                throw "The live Mozc language profile has no IconFile metadata: $($record.Key)"
            }
            $iconRecords += [pscustomobject]@{ View = $record.View; IconFile = [string]$icon.Value }
        }

        Set-SmokeTestPassed -Id 'registration-live' -Evidence (
            'Registry64 COM and language profile are installed; ThreadingModel={0}; registered SHA-256={1}.' -f
            $threadingModel, $TestedSha256
        )
        return [ordered]@{
            comViews = @($comRecords | ForEach-Object { $_.View })
            profileKeys = @($profileRecords | ForEach-Object { $_.Key })
            iconFiles = @($iconRecords)
            selectedView = if ($null -eq $selectedCom) { '' } else { $selectedCom.View }
        }
    }
    catch {
        Add-SmokeFailure -Id 'registration-live' -Code 'MOZC_NOT_REGISTERED' -Message $_.Exception.Message -Remediation 'Install the pinned x64 Mozc runtime through its reviewed MSI/custom action, then pass the installed mozc_tip64.dll to this harness. This harness never registers it.'
        return [ordered]@{}
    }
}

function Test-ApplicationHost {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "The Windows TSF application host is unavailable: $Path"
        }
        $pe = Assert-TsfSmokeX64Pe -Path $Path
        Set-SmokeTestPassed -Id 'app-host' -Evidence ("x64 application is available: {0} ({1})." -f $Path, $pe.MachineName)
        return $pe
    }
    catch {
        Add-SmokeFailure -Id 'app-host' -Code 'APP_HOST_UNAVAILABLE' -Message $_.Exception.Message -Remediation 'Pass -ApplicationPath for an installed x64 desktop text host (Notepad is the default), or restore System32/Notepad.exe.'
        return $null
    }
}

function Test-TsfRuntime {
    try {
        $windowsRoot = [string][System.Environment]::GetEnvironmentVariable('WINDIR')
        if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
            $windowsRoot = 'C:\Windows'
        }
        $msctf = Join-Path $windowsRoot 'System32\msctf.dll'
        if (-not (Test-Path -LiteralPath $msctf -PathType Leaf)) {
            throw "The Windows TSF runtime is unavailable: $msctf"
        }
        $pe = Assert-TsfSmokeX64Pe -Path $msctf -RequireDll
        Initialize-TsfSmokeNative
        $module = [KanaAI.TsfSmoke.Native]::LoadLibraryExW($msctf, [IntPtr]::Zero, [uint32]0x00000800)
        if ($module -eq [IntPtr]::Zero) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (Get-TsfSmokeWin32Error -ErrorCode $code -Operation "LoadLibraryExW($msctf)")
        }
        [void][KanaAI.TsfSmoke.Native]::FreeLibrary($module)
        Set-SmokeTestPassed -Id 'tsf-host-runtime' -Evidence "x64 msctf.dll exists and loads: $msctf."
    }
    catch {
        Add-SmokeFailure -Id 'tsf-host-runtime' -Code 'TSF_HOST_UNAVAILABLE' -Message $_.Exception.Message -Remediation 'Use a supported Windows x64 desktop with the Text Services Framework runtime available. Do not interpret a PE-only check as a host test.'
    }
}

function Test-TipDllLoad {
    param([Parameter(Mandatory = $true)][string]$Path)

    $module = [IntPtr]::Zero
    try {
        Initialize-TsfSmokeNative
        $module = [KanaAI.TsfSmoke.Native]::LoadLibraryExW($Path, [IntPtr]::Zero, [uint32]0x00001800)
        if ($module -eq [IntPtr]::Zero) {
            $firstCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            # Older loader policies reject search flags when the image is on a
            # WSL UNC path. An absolute path plus its own directory is safe.
            $module = [KanaAI.TsfSmoke.Native]::LoadLibraryExW($Path, [IntPtr]::Zero, [uint32]0x00000008)
            if ($module -eq [IntPtr]::Zero) {
                $secondCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw ((Get-TsfSmokeWin32Error -ErrorCode $secondCode -Operation "LoadLibraryExW($Path)") + " Initial search-flag error was $firstCode.")
            }
        }
        foreach ($export in @(Get-TsfSmokeArrayProperty -Object (Get-TsfSmokeProperty -Object $contract -Name 'artifact') -Name 'requiredExports')) {
            $address = [KanaAI.TsfSmoke.Native]::GetProcAddress($module, [string]$export)
            if ($address -eq [IntPtr]::Zero) {
                throw "GetProcAddress did not resolve required TIP export '$export' from the loaded module."
            }
        }
        $freed = [KanaAI.TsfSmoke.Native]::FreeLibrary($module)
        $module = [IntPtr]::Zero
        if (-not $freed) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (Get-TsfSmokeWin32Error -ErrorCode $code -Operation 'FreeLibrary(TIP)')
        }
        Set-SmokeTestPassed -Id 'dll-load' -Evidence "The exact x64 TIP loaded from a 64-bit process, both exports resolved, and FreeLibrary succeeded: $Path."
    }
    catch {
        if ($module -ne [IntPtr]::Zero) {
            [void][KanaAI.TsfSmoke.Native]::FreeLibrary($module)
        }
        Add-SmokeFailure -Id 'dll-load' -Code 'TIP_DLL_LOAD_FAILED' -Message $_.Exception.Message -Remediation 'Resolve every DLL dependency from the TIP directory or a supplied Windows-local -RuntimeRoot, then retry. Do not copy an arbitrary system DLL into the runtime.'
    }
}

function Resolve-DependencyPath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DllDirectory,
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory
    )

    $windowsRoot = [string][System.Environment]::GetEnvironmentVariable('WINDIR')
    if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
        $windowsRoot = 'C:\Windows'
    }
    $systemPath = Join-Path $windowsRoot (Join-Path 'System32' $Name)
    if (Test-Path -LiteralPath $systemPath -PathType Leaf) {
        return [pscustomobject]@{ Path = [System.IO.Path]::GetFullPath($systemPath); Source = 'System32' }
    }

    # Do not resolve arbitrary PATH entries: a smoke result must describe the
    # supplied runtime, not whichever DLL happens to be first on the machine.
    $searchRoots = @($DllDirectory, $RuntimeDirectory)
    $seen = @{}
    foreach ($root in $searchRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        $key = $root.ToLowerInvariant() + [System.IO.Path]::DirectorySeparatorChar
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        $direct = Join-Path $root $Name
        if (Test-Path -LiteralPath $direct -PathType Leaf) {
            return [pscustomobject]@{ Path = [System.IO.Path]::GetFullPath($direct); Source = $root }
        }
        if (Test-Path -LiteralPath $root -PathType Container) {
            $nested = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -Filter $Name -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($nested.Count -gt 0) {
                return [pscustomobject]@{ Path = [string]$nested[0].FullName; Source = $root }
            }
        }
    }
    return $null
}

function Test-DllDependencies {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DumpbinPath,
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory
    )

    try {
        $imports = @(Get-TsfSmokeImportNames -Path $Path | Sort-Object -Unique)
        if ($imports.Count -eq 0) {
            throw 'The TIP PE has no static import directory; dependency validation would be meaningless.'
        }
        $dumpbin = Invoke-SmokeDumpbin -DumpbinPath $DumpbinPath -Arguments @('/dependents', $Path)
        if ($dumpbin.ExitCode -ne 0) {
            throw "dumpbin /dependents failed with exit code $($dumpbin.ExitCode)."
        }
        $dumpNames = @([regex]::Matches($dumpbin.Text, '(?im)^\s+([A-Za-z0-9._+\-]+\.dll)\s*$') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique)
        $missingFromDumpbin = @($imports | Where-Object { $dumpNames -inotcontains $_ })
        if ($missingFromDumpbin.Count -gt 0) {
            throw "dumpbin omitted PE import dependency(ies): $($missingFromDumpbin -join ', ')."
        }

        Initialize-TsfSmokeNative
        $resolved = @()
        foreach ($name in $imports) {
            # API-set contracts often have no physical System32 file. Let the
            # x64 loader resolve them first; that is stronger than a name-only
            # allowlist and still prevents accidentally accepting x86 binaries.
            $systemModule = [KanaAI.TsfSmoke.Native]::LoadLibraryExW($name, [IntPtr]::Zero, [uint32]0x00000800)
            if ($systemModule -ne [IntPtr]::Zero) {
                [void][KanaAI.TsfSmoke.Native]::FreeLibrary($systemModule)
                $resolved += [pscustomobject]@{
                    name = $name
                    path = $name
                    source = 'Windows System32/API-set loader'
                }
                continue
            }

            $location = Resolve-DependencyPath -Name $name -DllDirectory (Split-Path -Parent $Path) -RuntimeDirectory $RuntimeDirectory
            if ($null -eq $location) {
                throw "Required DLL dependency '$name' was not found in System32, the TIP directory, or the supplied RuntimeRoot."
            }
            [void](Assert-TsfSmokeX64Pe -Path $location.Path -RequireDll)
            $module = [KanaAI.TsfSmoke.Native]::LoadLibraryExW($location.Path, [IntPtr]::Zero, [uint32]0x00001800)
            if ($module -eq [IntPtr]::Zero) {
                $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw ("Dependency '{0}' at {1} could not load: {2}" -f $name, $location.Path, (Get-TsfSmokeWin32Error -ErrorCode $code -Operation 'LoadLibraryExW(dependency)'))
            }
            [void][KanaAI.TsfSmoke.Native]::FreeLibrary($module)
            $resolved += [pscustomobject]@{
                name = $name
                path = $location.Path
                source = $location.Source
            }
        }
        Set-SmokeTestPassed -Id 'dll-dependencies' -Evidence (
            'dumpbin /dependents agreed with the PE import table and all {0} x64 dependencies loaded: {1}.' -f
            $resolved.Count, (($resolved | ForEach-Object { $_.name }) -join ', ')
        )
        return @($resolved)
    }
    catch {
        Add-SmokeFailure -Id 'dll-dependencies' -Code 'DLL_DEPENDENCY_FAILED' -Message $_.Exception.Message -Remediation 'Use a complete Windows-local Mozc runtime and pass it as -RuntimeRoot. Do not suppress loader failures or use a different architecture.'
        return @()
    }
}

function Invoke-HostTest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Application,
        [Parameter(Mandatory = $true)][string]$TipPath,
        [Parameter(Mandatory = $true)][string]$TipHash,
        [Parameter(Mandatory = $true)][string]$MozcCommit,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $registration = Get-TsfSmokeProperty -Object $contract -Name 'registration'
    try {
        if (Test-Path -LiteralPath $OutputPath) {
            Remove-Item -LiteralPath $OutputPath -Force
        }
        $hostResult = [ordered]@{}
        $arguments = @(
            '-ResultPath', $OutputPath,
            '-TestPlanPath', $planPath,
            '-ApplicationPath', $Application,
            '-TipDllPath', $TipPath,
            '-TextServiceClsid', [string](Get-TsfSmokeProperty -Object $registration -Name 'textServiceClsid'),
            '-LanguageProfileGuid', [string](Get-TsfSmokeProperty -Object $registration -Name 'languageProfileGuid'),
            '-LanguageId', [string][int](Get-TsfSmokeProperty -Object $registration -Name 'languageIdDecimal'),
            '-MozcCommit', $MozcCommit,
            '-TipDllSha256', $TipHash
        )
        $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
        $oldErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            Push-Location -LiteralPath 'C:\Windows'
            try {
                if ($extension -eq '.ps1') {
                    $shell = Join-Path $PSHOME 'powershell.exe'
                    if (-not (Test-Path -LiteralPath $shell -PathType Leaf)) {
                        $shell = Join-Path $PSHOME 'pwsh.exe'
                    }
                    if (-not (Test-Path -LiteralPath $shell -PathType Leaf)) {
                        $shell = Get-TsfSmokeCommandPath -Name 'powershell.exe'
                    }
                    if ($null -eq $shell) {
                        $shell = Get-TsfSmokeCommandPath -Name 'pwsh.exe'
                    }
                    if ($null -eq $shell) {
                        throw 'No Windows PowerShell executable is available to isolate the host test.'
                    }
                    $hostArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $arguments
                    & $shell @hostArguments
                    $hostExitCode = $LASTEXITCODE
                }
                elseif ($extension -eq '.exe') {
                    & $Path @arguments
                    $hostExitCode = $LASTEXITCODE
                }
                else {
                    throw "The TSF host test must be a .ps1 or .exe, not '$extension': $Path"
                }
            }
            finally {
                Pop-Location
            }
        }
        finally {
            $ErrorActionPreference = $oldErrorAction
        }
        if ($hostExitCode -ne 0) {
            throw "The real TSF host test exited with code $hostExitCode."
        }
        if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
            throw "The real TSF host test did not write its required receipt: $OutputPath"
        }
        $hostResult = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $observations = $hostResult.observations
        $expected = $hostPlan.hostResultContract.observations
        if ([int]$hostResult.schemaVersion -ne 1 -or [string]$hostResult.status -ine 'passed' -or
            [string]$hostResult.testId -ine [string](Get-TsfSmokeProperty -Object (Get-TsfSmokeProperty -Object $contract -Name 'runtime') -Name 'hostTestId')) {
            throw "The host receipt is not a passed schemaVersion=1 '$([string](Get-TsfSmokeProperty -Object (Get-TsfSmokeProperty -Object $contract -Name 'runtime') -Name 'hostTestId'))' result."
        }
        if ([System.IO.Path]::GetFullPath([string]$hostResult.applicationPath) -ine [System.IO.Path]::GetFullPath($Application) -or
            [System.IO.Path]::GetFullPath([string]$hostResult.tipDllPath) -ine [System.IO.Path]::GetFullPath($TipPath) -or
            [int]$hostResult.applicationProcessId -le 0) {
            throw 'The host receipt does not identify the tested x64 application process.'
        }
        if ([string]$hostResult.textServiceClsid -ine [string](Get-TsfSmokeProperty -Object $registration -Name 'textServiceClsid') -or
            [string]$hostResult.languageProfileGuid -ine [string](Get-TsfSmokeProperty -Object $registration -Name 'languageProfileGuid') -or
            [int]$hostResult.languageId -ne [int](Get-TsfSmokeProperty -Object $registration -Name 'languageIdDecimal') -or
            [string]$hostResult.mozcCommit -ine $MozcCommit -or
            [string]$hostResult.tipDllSha256 -ine $TipHash) {
            throw 'The host receipt is not tied to the tested profile, application, and TIP bytes.'
        }
        if ($observations.tsfHostLoad -ne $true -or
            $observations.profileActivated -ne $true -or
            [string]$observations.preedit -ine [string]$expected.preedit -or
            [string]$observations.primaryCandidate -ine [string]$expected.primaryCandidate -or
            [string]$observations.committedText -ine [string]$expected.committedText -or
            $observations.compositionClosed -ne $true -or
            $observations.focusRetained -ne $true -or
            $observations.cleanTeardown -ne $true) {
            throw "The host observations do not match the minimal preedit/candidate/commit plan. Observed: $($observations | ConvertTo-Json -Compress -Depth 5)"
        }
        $timestamp = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$hostResult.completedAtUtc, [ref]$timestamp)) {
            throw 'The host receipt has no valid completedAtUtc timestamp.'
        }

        Set-SmokeTestPassed -Id 'preedit-candidate-commit' -Evidence (
            'Real host observed preedit={0}, primary candidate={1}, commit={2}, and clean teardown in process {3}.' -f
            [string]$expected.preedit,
            [string]$expected.primaryCandidate,
            [string]$expected.committedText,
            [int]$hostResult.applicationProcessId
        )
        return $hostResult
    }
    catch {
        Add-SmokeFailure -Id 'preedit-candidate-commit' -Code 'TSF_HOST_TEST_UNAVAILABLE' -Message $_.Exception.Message -Remediation 'Run an automated x64 desktop TSF host test that follows host-test-plan.json and writes its receipt. PE load, registry inspection, or a missing app is not host evidence.'
        return $null
    }
}

# Initialize the machine-readable result before preflight so every expected
# failure still has a current, non-stale receipt.
[void](Write-SmokeResult -Status 'not-run' -Message 'Windows TSF smoke preflight is in progress.')
$details = [ordered]@{}
try {
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw 'This harness must execute in native Windows PowerShell through WSL interop (for example powershell.exe -File ...); Linux pwsh is not a Windows TSF host test.'
    }
    if (-not [System.Environment]::Is64BitOperatingSystem -or -not [System.Environment]::Is64BitProcess) {
        throw 'This harness requires 64-bit Windows and a 64-bit PowerShell process. Initialize VsDevCmd.bat -arch=x64 -host_arch=x64.'
    }

    if ([string]::IsNullOrWhiteSpace($MozcStage)) {
        $MozcStage = Join-Path $repository 'third_party\mozc'
    }
    else {
        $MozcStage = Resolve-TsfSmokePath -Path $MozcStage -BasePath $repository
    }

    # Validate source and registration policy before looking for build output so
    # a missing artifact does not hide a pin/metadata failure.
    $sourceDetails = Test-PinnedMozcSource
    $details.pinnedMozc = $sourceDetails
    Test-RegistrationMetadata

    $tipPathWasExplicit = -not [string]::IsNullOrWhiteSpace($TipDll)
    try {
        if (-not $tipPathWasExplicit) {
            $TipDll = Resolve-SmokeTipDll -Repository $repository -Stage $MozcStage -ExplicitPath ''
        }
        else {
            $TipDll = Resolve-SmokeTipDll -Repository $repository -Stage $MozcStage -ExplicitPath $TipDll
        }
    }
    catch {
        Add-SmokeFailure -Id 'mozc-tip-x64-pe' -Code 'TIP_ARTIFACT_UNAVAILABLE' -Message $_.Exception.Message -Remediation 'Build //win32/tip:mozc_tip64 from the pinned Windows-local Mozc stage, then pass -MozcStage or the exact -TipDll path. Do not use the x86 TIP or a renamed arbitrary DLL.'
        throw
    }
    if ($tipPathWasExplicit) {
        $artifactFullPath = [System.IO.Path]::GetFullPath($TipDll)
        $pinnedArtifactRoots = @(
            $MozcStage,
            (Join-Path $MozcStage 'src'),
            (Join-Path $repository 'third_party\mozc'),
            (Join-Path $repository 'third_party\mozc\src')
        ) | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') }
        $underPinnedRoot = $false
        foreach ($root in $pinnedArtifactRoots) {
            if ($artifactFullPath.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                $underPinnedRoot = $true
                break
            }
        }
        if (-not $underPinnedRoot -and [string]::IsNullOrWhiteSpace($ExpectedTipSha256)) {
            Add-SmokeFailure -Id 'mozc-tip-x64-pe' -Code 'ARTIFACT_PROVENANCE_UNAVAILABLE' -Message "The explicit TIP path is outside the pinned source/Bazel roots and no reviewed -ExpectedTipSha256 was supplied: $artifactFullPath" -Remediation 'Use an artifact under the pinned Mozc stage, or pass the reviewed SHA-256 for the installed/copied artifact so the exact bytes are pinned.'
            throw 'The explicit TIP artifact has no source/stage or reviewed SHA-256 provenance.'
        }
    }
    $runtimeRootWasExplicit = -not [string]::IsNullOrWhiteSpace($RuntimeRoot)
    if (-not $runtimeRootWasExplicit) {
        $RuntimeRoot = Split-Path -Parent $TipDll
    }
    else {
        $RuntimeRoot = Resolve-TsfSmokePath -Path $RuntimeRoot -BasePath $repository
        if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
            Add-SmokeFailure -Id 'dll-dependencies' -Code 'RUNTIME_ROOT_UNAVAILABLE' -Message "The supplied runtime root is not a directory: $RuntimeRoot" -Remediation 'Pass the Windows-local directory containing the complete Mozc runtime, or omit -RuntimeRoot to use the TIP directory.'
            throw "The supplied runtime root is not a directory: $RuntimeRoot"
        }
    }
    if ([string]::IsNullOrWhiteSpace($ApplicationPath)) {
        $windowsRoot = [string][System.Environment]::GetEnvironmentVariable('WINDIR')
        if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
            $windowsRoot = 'C:\Windows'
        }
        $ApplicationPath = Join-Path $windowsRoot 'System32\Notepad.exe'
    }
    else {
        $ApplicationPath = Resolve-TsfSmokePath -Path $ApplicationPath -BasePath $repository
    }
    if (-not [string]::IsNullOrWhiteSpace($HostTestPath)) {
        $HostTestPath = Resolve-TsfSmokePath -Path $HostTestPath -BasePath $repository
    }

    try {
        $dumpbinPath = Initialize-TsfSmokeMSVCEnvironment -Skip:$SkipVsDevCmd
    }
    catch {
        $message = $_.Exception.Message
        Add-SmokeFailure -Id 'mozc-tip-exports' -Code 'MSVC_DEVELOPER_ENVIRONMENT_UNAVAILABLE' -Message $message -Remediation 'Open a 64-bit Visual Studio developer environment or allow VsDevCmd.bat -arch=x64 -host_arch=x64 initialization.'
        Add-SmokeFailure -Id 'dll-dependencies' -Code 'MSVC_DEVELOPER_ENVIRONMENT_UNAVAILABLE' -Message $message -Remediation 'Open a 64-bit Visual Studio developer environment or allow VsDevCmd.bat -arch=x64 -host_arch=x64 initialization.'
        throw
    }
    $details.dumpbin = [ordered]@{
        path = $dumpbinPath
        vsDevCmd = 'VsDevCmd.bat -arch=x64 -host_arch=x64'
    }

    $artifact = Get-Item -LiteralPath $TipDll -Force
    $tipSha256 = Get-TsfSmokeSha256 -Path $TipDll
    $details.artifact = [ordered]@{
        path = $artifact.FullName
        size = [long]$artifact.Length
        sha256 = $tipSha256
        expectedSha256 = if ([string]::IsNullOrWhiteSpace($ExpectedTipSha256)) { '' } else { $ExpectedTipSha256.ToLowerInvariant() }
        explicitPath = [bool]$tipPathWasExplicit
        provenance = if ($tipPathWasExplicit -and -not [string]::IsNullOrWhiteSpace($ExpectedTipSha256)) {
            'explicit-path-plus-reviewed-sha256'
        }
        elseif (-not $tipPathWasExplicit) {
            'pinned-stage-auto-discovery'
        }
        else {
            'pinned-stage-root'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedTipSha256) -and $ExpectedTipSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        Add-SmokeFailure -Id 'mozc-tip-x64-pe' -Code 'TIP_HASH_RECEIPT_INVALID' -Message '-ExpectedTipSha256 must be exactly 64 hexadecimal characters.' -Remediation 'Correct the reviewed artifact hash receipt and rerun.'
        throw '-ExpectedTipSha256 must be exactly 64 hexadecimal characters.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedTipSha256) -and $ExpectedTipSha256.ToLowerInvariant() -cne $tipSha256) {
        Add-SmokeFailure -Id 'mozc-tip-x64-pe' -Code 'TIP_HASH_MISMATCH' -Message "The tested TIP SHA-256 '$tipSha256' does not match the expected receipt value '$ExpectedTipSha256'." -Remediation 'Test the reviewed artifact bytes or supply the correct -ExpectedTipSha256.'
        throw "The tested TIP SHA-256 does not match the expected receipt value."
    }

    try {
        $pe = Assert-TsfSmokeX64Pe -Path $TipDll -RequireDll
    }
    catch {
        Add-SmokeFailure -Id 'mozc-tip-x64-pe' -Code 'TIP_PE_REJECTED' -Message $_.Exception.Message -Remediation 'Use the actual x64 PE32+ DLL produced by //win32/tip:mozc_tip64. A renamed x86 DLL or non-DLL is not acceptable.'
        throw
    }
    Set-SmokeTestPassed -Id 'mozc-tip-x64-pe' -Evidence (
        'Filename={0}; machine={1}; optionalMagic={2}; IMAGE_FILE_DLL={3}; SHA-256={4}.' -f
        $artifact.Name, $pe.MachineName, $pe.OptionalMagicHex, $pe.IsDll, $tipSha256
    )

    $requiredExports = @(Get-TsfSmokeArrayProperty -Object (Get-TsfSmokeProperty -Object $contract -Name 'artifact') -Name 'requiredExports')
    try {
        $peExports = @(Get-TsfSmokeExportNames -Path $TipDll)
        $missingExports = @($requiredExports | Where-Object { $peExports -cnotcontains [string]$_ })
        if ($missingExports.Count -gt 0) {
            throw "The PE export table is missing: $($missingExports -join ', ')."
        }
        $dumpExports = Invoke-SmokeDumpbin -DumpbinPath $dumpbinPath -Arguments @('/exports', $TipDll)
        if ($dumpExports.ExitCode -ne 0) {
            throw "dumpbin /exports failed with exit code $($dumpExports.ExitCode)."
        }
        foreach ($export in $requiredExports) {
            if ($dumpExports.Text -notmatch ('(?im)\b' + [regex]::Escape([string]$export) + '\b')) {
                throw "dumpbin /exports did not report '$export'."
            }
        }
        Set-SmokeTestPassed -Id 'mozc-tip-exports' -Evidence (
            'PE export table and dumpbin /exports contain {0}; named exports: {1}.' -f
            (($requiredExports) -join ', '), (($peExports | Sort-Object -Unique) -join ', ')
        )
    }
    catch {
        Add-SmokeFailure -Id 'mozc-tip-exports' -Code 'TIP_EXPORT_FAILED' -Message $_.Exception.Message -Remediation 'Build //win32/tip:mozc_tip64 from the pinned Mozc source and inspect the exact DLL; do not rely on a filename or a synthetic PE.'
    }

    $dependencies = @(Test-DllDependencies -Path $TipDll -DumpbinPath $dumpbinPath -RuntimeDirectory $RuntimeRoot)
    $details.artifact['dependencies'] = @($dependencies | ForEach-Object {
        [ordered]@{ name = $_.name; path = $_.path; source = $_.source }
    })

    if ($PreflightOnly) {
        foreach ($testId in @('registration-live', 'dll-load', 'tsf-host-runtime', 'app-host', 'preedit-candidate-commit')) {
            Set-SmokeTestNotRun -Id $testId -Reason 'PreflightOnly was explicit; no registration, loader, app, or TSF-host pass is claimed.'
        }
        $staticFailures = @($staticTestIds | Where-Object {
            $id = [string]$_
            [string]$script:SmokeTests[$id].status -ne 'passed'
        })
        if ($staticFailures.Count -gt 0) {
            $path = Write-SmokeResult -Status 'failed' -Message ('Pinned Mozc artifact preflight failed: ' + ($staticFailures -join ', ')) -Details $details
            throw ("Pinned Mozc artifact preflight failed. Result: $path")
        }
        $path = Write-SmokeResult -Status 'not-run' -Message 'Artifact preflight completed, but the real Windows TSF vertical slice was not run. This is not a passing smoke result.' -Details $details
        Write-Host "Pinned Mozc TSF preflight only (not a smoke pass): $path"
        return
    }

    $details.registration = Test-LiveRegistration -TestedDll $TipDll -TestedSha256 $tipSha256
    Test-TipDllLoad -Path $TipDll
    Test-TsfRuntime
    [void](Test-ApplicationHost -Path $ApplicationPath)

    $hostPrerequisiteIds = @('registration-live', 'dll-load', 'dll-dependencies', 'tsf-host-runtime', 'app-host')
    $missingHostPrerequisites = @($hostPrerequisiteIds | Where-Object {
        [string]$script:SmokeTests[[string]$_].status -ne 'passed'
    })
    if ($missingHostPrerequisites.Count -gt 0) {
        Add-SmokeFailure -Id 'preedit-candidate-commit' -Code 'TSF_HOST_PREREQUISITE_FAILED' -Message ('The real host test was not launched because required prerequisite(s) failed: ' + ($missingHostPrerequisites -join ', ')) -Remediation 'Resolve the reported registration, loader/dependency, TSF runtime, or application-host failures before rerunning the host interaction.'
    }
    elseif ([string]::IsNullOrWhiteSpace($HostTestPath)) {
        Add-SmokeFailure -Id 'preedit-candidate-commit' -Code 'TSF_HOST_TEST_UNAVAILABLE' -Message 'No real TSF host test was supplied. DLL load and registry checks cannot prove preedit, candidates, or commit.' -Remediation 'Pass -HostTestPath pointing to an x64 desktop host test that follows host-test-plan.json and writes the documented JSON receipt.'
    }
    elseif (-not (Test-Path -LiteralPath $HostTestPath -PathType Leaf)) {
        Add-SmokeFailure -Id 'preedit-candidate-commit' -Code 'TSF_HOST_TEST_UNAVAILABLE' -Message "The requested TSF host test does not exist: $HostTestPath" -Remediation 'Install or restore the host test executable/script; the harness will not synthesize a pass.'
    }
    else {
        $hostReceiptPath = $ResultPath + '.host.json'
        $expectedCommit = [string](Get-TsfSmokeProperty -Object (Get-TsfSmokeProperty -Object $contract -Name 'pinnedMozc') -Name 'commit')
        $hostReceipt = Invoke-HostTest -Path $HostTestPath -Application $ApplicationPath -TipPath $TipDll -TipHash $tipSha256 -MozcCommit $expectedCommit -OutputPath $hostReceiptPath
        if ($null -ne $hostReceipt) {
            $details.hostReceiptPath = $hostReceiptPath
        }
    }

    $failed = @($requiredTestIds | Where-Object {
        $id = [string]$_
        [string]$script:SmokeTests[$id].status -ne 'passed'
    })
    if ($failed.Count -gt 0) {
        $path = Write-SmokeResult -Status 'failed' -Message ('Pinned Mozc Windows TSF smoke failed; required test(s) not passed: ' + ($failed -join ', ')) -Details $details
        throw ("Pinned Mozc Windows TSF smoke failed. Result: $path")
    }

    $path = Write-SmokeResult -Status 'passed' -Message 'Pinned upstream Mozc x64 TIP passed the Phase 1 preedit/candidate/commit vertical slice. This is not a KanaAI registration or public-beta claim.' -Details $details
    Write-Host "Pinned Mozc Windows TSF smoke passed: $path"
}
catch {
    $hasFailure = @($script:SmokeTests.Values | Where-Object { $_.status -eq 'failed' }).Count -gt 0
    if (-not $hasFailure -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
        $fallbackTest = @($requiredTestIds | Where-Object {
            [string]$script:SmokeTests[[string]$_].status -ne 'passed'
        } | Select-Object -First 1)
        $fallbackId = if ($fallbackTest.Count -gt 0) { [string]$fallbackTest[0] } else { 'pinned-mozc-source' }
        if ($script:SmokeTests.Contains($fallbackId)) {
            $script:SmokeTests[$fallbackId].status = 'failed'
            $script:SmokeTests[$fallbackId].evidence = $_.Exception.Message
        }
        $script:SmokeFailures += [pscustomobject]@{
            testId = $fallbackId
            code = 'HARNESS_ERROR'
            message = $_.Exception.Message
            remediation = 'Fix the reported harness/environment error and rerun. No static file result was treated as a Windows host pass.'
        }
    }
    if ($script:SmokeResultStatus -ne 'failed') {
        [void](Write-SmokeResult -Status 'failed' -Message $_.Exception.Message -Details $details)
    }
    throw ("Pinned Mozc Windows TSF smoke failed. Result: $ResultPath")
}
