# Source-only static tests for the pinned-Mozc Windows TSF smoke harness.
# This test does not load a real TIP, inspect the registry, or claim host proof.

[CmdletBinding()]
param(
    [Alias('RepoRoot')]
    [string]$RepositoryRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StaticRepositoryRoot {
    param([string]$Value = '')

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    $current = [System.IO.Path]::GetFullPath($PSScriptRoot)
    while ($current -and $current -ne [System.IO.Path]::GetPathRoot($current)) {
        if ((Test-Path -LiteralPath (Join-Path $current 'Cargo.toml') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $current 'platform\windows-tsf\smoke') -PathType Container)) {
            return $current
        }
        $current = Split-Path -Parent $current
    }
    throw 'Could not locate the KanaAI repository root. Pass -RepositoryRoot explicitly.'
}

function New-SyntheticPe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [uint16]$Machine = 0x8664
    )

    $bytes = New-Object byte[] 1024
    $bytes[0] = 0x4d
    $bytes[1] = 0x5a
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3c) | Out-Null
    $pe = 0x80
    $bytes[$pe] = 0x50
    $bytes[$pe + 1] = 0x45
    [BitConverter]::GetBytes($Machine).CopyTo($bytes, $pe + 4) | Out-Null
    [BitConverter]::GetBytes([uint16]1).CopyTo($bytes, $pe + 6) | Out-Null
    [BitConverter]::GetBytes([uint16]0xf0).CopyTo($bytes, $pe + 20) | Out-Null
    [BitConverter]::GetBytes([uint16]0x2102).CopyTo($bytes, $pe + 22) | Out-Null # DLL|EXECUTABLE_IMAGE
    $optional = $pe + 24
    [BitConverter]::GetBytes([uint16]0x20b).CopyTo($bytes, $optional) | Out-Null
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes, $optional + 60) | Out-Null
    $section = $optional + 0xf0
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes, $section + 8) | Out-Null
    [BitConverter]::GetBytes([uint32]0x1000).CopyTo($bytes, $section + 12) | Out-Null
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes, $section + 16) | Out-Null
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($bytes, $section + 20) | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

$repo = Get-StaticRepositoryRoot -Value $RepositoryRoot
$smokeRoot = Join-Path $repo 'platform\windows-tsf\smoke'
$commonPath = Join-Path $smokeRoot 'Smoke.Common.ps1'
$harnessPath = Join-Path $smokeRoot 'Invoke-TsfWindowsSmoke.ps1'
$contractPath = Join-Path $smokeRoot 'contract.json'
$planPath = Join-Path $smokeRoot 'host-test-plan.json'
$wrapperPath = Join-Path $repo 'scripts\test-tsf-windows.ps1'
$required = @($commonPath, $harnessPath, $contractPath, $planPath, $wrapperPath, $PSCommandPath)
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required pinned-Mozc TSF smoke file is missing: $path"
    }
}

$parseFailures = @()
foreach ($path in @($commonPath, $harnessPath, $wrapperPath, $PSCommandPath)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($parseError in @($errors)) {
        if ($null -ne $parseError) {
            $parseFailures += ("{0}:{1}:{2}: {3}" -f $path, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
        }
    }
}
if ($parseFailures.Count -gt 0) {
    throw ("Pinned-Mozc TSF smoke PowerShell syntax check failed:`n" + ($parseFailures -join "`n"))
}

$contract = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
$plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
$integration = Get-Content -LiteralPath (Join-Path $repo 'platform\windows-tsf\tsf\metadata\tsf-integration.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$registration = Get-Content -LiteralPath (Join-Path $repo 'platform\windows-tsf\registration\registration.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$toolchain = Get-Content -LiteralPath (Join-Path $repo 'platform\windows-tsf\build\toolchain.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$commit = [string]$contract.pinnedMozc.commit
$clsid = [string]$contract.registration.textServiceClsid
$profile = [string]$contract.registration.languageProfileGuid
$toolchainExports = @($toolchain.dll.requiredExports)
$contractExports = @($contract.artifact.requiredExports)
if ([string]$integration.host.commit -ne $commit -or [string]$toolchain.mozc.gitlink -ne $commit -or
    [string]$toolchain.target -ne 'x86_64-pc-windows-msvc' -or
    ($toolchainExports -join ',') -ne ($contractExports -join ',') -or
    [string]$integration.registration.ossTextServiceClsid -ne $clsid -or
    [string]$integration.registration.ossLanguageProfileGuid -ne $profile -or
    [string]$registration.registrationIdentity.pinnedMozcReference.textServiceClsid -ne $clsid -or
    [string]$registration.registrationIdentity.pinnedMozcReference.languageProfileGuid -ne $profile) {
    throw 'The smoke contract disagrees with pinned repository metadata.'
}
if ($integration.registration.kanaiProductRegistrationReady -ne $false -or
    $registration.registrationIdentity.identityApproved -ne $false -or
    $registration.registrationIdentity.pinnedMozcReference.mustNotBeRegisteredAsKanaAI -ne $true) {
    throw 'The smoke contract must not turn the upstream Mozc identity into KanaAI registration.'
}

$expectedIds = @(
    'pinned-mozc-source',
    'mozc-tip-x64-pe',
    'mozc-tip-exports',
    'registration-metadata',
    'registration-live',
    'dll-load',
    'dll-dependencies',
    'tsf-host-runtime',
    'app-host',
    'preedit-candidate-commit'
)
$actualIds = @($contract.windowsRequiredTestIds)
if ($actualIds.Count -ne $expectedIds.Count -or @($expectedIds | Where-Object { $actualIds -notcontains $_ }).Count -ne 0) {
    throw 'The Windows required smoke-test contract is incomplete or changed.'
}
$expectedObservation = $plan.hostResultContract.observations
if ($plan.profile.pinnedMozcCommit -ne $commit -or
    @($plan.hostResultContract.requiredFields) -notcontains 'pinnedMozcCommit' -or
    @($plan.hostResultContract.requiredFields) -notcontains 'tipDllPath' -or
    [string]::IsNullOrWhiteSpace([string]$expectedObservation.preedit) -or
    [string]::IsNullOrWhiteSpace([string]$expectedObservation.primaryCandidate) -or
    [string]::IsNullOrWhiteSpace([string]$expectedObservation.committedText) -or
    $expectedObservation.tsfHostLoad -ne $true -or
    $expectedObservation.profileActivated -ne $true -or
    $expectedObservation.compositionClosed -ne $true -or
    $expectedObservation.focusRetained -ne $true -or
    $expectedObservation.cleanTeardown -ne $true -or
    [string]$plan.steps[1].action -notmatch '(?i)\bkana\b') {
    throw 'The minimal host plan changed the expected preedit/candidate/commit evidence.'
}

$harnessText = Get-Content -LiteralPath $harnessPath -Raw
$commonText = Get-Content -LiteralPath $commonPath -Raw
$wrapperText = Get-Content -LiteralPath $wrapperPath -Raw
foreach ($check in @(
    @{ Name = 'VS x64 initialization'; Text = $commonText; Needle = 'VsDevCmd.bat -arch=x64 -host_arch=x64' },
    @{ Name = 'WSL UNC-safe local CWD'; Text = $commonText; Needle = "Push-Location -LiteralPath 'C:\Windows'" },
    @{ Name = 'PE parser'; Text = $commonText; Needle = 'Assert-TsfSmokeX64Pe' },
    @{ Name = 'PE export parser'; Text = $commonText; Needle = 'Get-TsfSmokeExportNames' },
    @{ Name = 'PE import parser'; Text = $commonText; Needle = 'Get-TsfSmokeImportNames' },
    @{ Name = 'dumpbin exports'; Text = $harnessText; Needle = "'/exports'" },
    @{ Name = 'dumpbin dependencies'; Text = $harnessText; Needle = "'/dependents'" },
    @{ Name = 'DLL load'; Text = $commonText; Needle = 'LoadLibraryExW' },
    @{ Name = 'Registry64 live gate'; Text = $harnessText; Needle = 'RegistryView]::Registry64' },
    @{ Name = 'msctf host gate'; Text = $harnessText; Needle = 'msctf.dll' },
    @{ Name = 'Notepad app gate'; Text = $harnessText; Needle = 'Notepad.exe' },
    @{ Name = 'host failure gate'; Text = $harnessText; Needle = 'TSF_HOST_TEST_UNAVAILABLE' },
    @{ Name = 'artifact provenance gate'; Text = $harnessText; Needle = 'ARTIFACT_PROVENANCE_UNAVAILABLE' },
    @{ Name = 'JSON failure receipt'; Text = $harnessText; Needle = "Write-SmokeResult -Status 'failed'" },
    @{ Name = 'wrapper entry point'; Text = $wrapperText; Needle = 'Invoke-TsfWindowsSmoke.ps1' }
)) {
    if ($check.Text.IndexOf($check.Needle, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Static pinned-Mozc TSF smoke check failed ($($check.Name)); missing: $($check.Needle)"
    }
}
foreach ($pattern in @(
    '(?im)^\s*(?:&|Start-Process)\s+.*\breg(?:svr32|\.exe)?\b',
    '(?im)^\s*reg(?:\.exe)?\s+add\b',
    '(?i)\bNew-ItemProperty\b',
    '(?i)\bSet-ItemProperty\b',
    '(?i)\bSetValue\s*\(',
    '(?i)\bDeleteKey(?:Value)?\s*\('
)) {
    if ($harnessText -match $pattern -or $commonText -match $pattern -or $wrapperText -match $pattern) {
        throw "The smoke harness contains a forbidden Windows mutation/registration command: $pattern"
    }
}

. $commonPath
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('kanai-tsf-smoke-static-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $x64 = Join-Path $tempRoot 'x64.dll'
    $x86 = Join-Path $tempRoot 'x86.dll'
    New-SyntheticPe -Path $x64 -Machine 0x8664
    New-SyntheticPe -Path $x86 -Machine 0x014c
    $image = Assert-TsfSmokeX64Pe -Path $x64 -RequireDll
    if ($image.Machine -ne 0x8664 -or $image.OptionalMagic -ne 0x20b -or -not $image.IsDll) {
        throw 'The synthetic x64 PE parser unit returned unexpected metadata.'
    }
    $x86Rejected = $false
    try {
        [void](Assert-TsfSmokeX64Pe -Path $x86 -RequireDll)
    }
    catch {
        $x86Rejected = $true
    }
    if (-not $x86Rejected) {
        throw 'The PE parser accepted an x86 image.'
    }
    $isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if ($isWindowsHost) {
        $windowsRoot = [string][System.Environment]::GetEnvironmentVariable('WINDIR')
        if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
            $windowsRoot = 'C:\Windows'
        }
        $systemPe = Join-Path $windowsRoot 'System32\kernel32.dll'
        if (Test-Path -LiteralPath $systemPe -PathType Leaf) {
            $systemImports = @(Get-TsfSmokeImportNames -Path $systemPe)
            if ($systemImports.Count -eq 0) {
                throw 'The PE import parser did not find kernel32 imports.'
            }
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

[pscustomobject]@{
    Status = 'passed'
    ParsedPowerShellFiles = 4
    PinnedMozcCommit = $commit
    RequiredWindowsTests = $expectedIds.Count
    RegistrationIdentity = 'pinned-upstream-mozc-only'
    PeUnit = 'passed'
    RuntimeHost = 'not-run'
}
