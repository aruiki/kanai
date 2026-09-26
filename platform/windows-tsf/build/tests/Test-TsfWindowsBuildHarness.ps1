# Static/source-only checks for the Windows TSF build harness.
# This test never registers a TIP and never treats a synthetic PE as runtime
# evidence. It is intentionally runnable with Windows PowerShell 5.1.

[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$SkipPeUnit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepositoryRoot {
    param([string]$Value = '')

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    $current = [System.IO.Path]::GetFullPath($PSScriptRoot)
    while ($current -and $current -ne [System.IO.Path]::GetPathRoot($current)) {
        if ((Test-Path -LiteralPath (Join-Path $current 'Cargo.toml') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $current 'platform\windows-tsf\build') -PathType Container)) {
            return $current
        }
        $current = Split-Path -Parent $current
    }
    throw 'Could not locate the KanaAI repository root. Pass -RepoRoot explicitly.'
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
    [BitConverter]::GetBytes([uint16]$Machine).CopyTo($bytes, $pe + 4) | Out-Null
    [BitConverter]::GetBytes([uint16]1).CopyTo($bytes, $pe + 6) | Out-Null
    [BitConverter]::GetBytes([uint16]0x2102).CopyTo($bytes, $pe + 22) | Out-Null # DLL|EXECUTABLE_IMAGE
    [BitConverter]::GetBytes([uint16]0xf0).CopyTo($bytes, $pe + 20) | Out-Null
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

$repo = Get-RepositoryRoot -Value $RepoRoot
$buildRoot = Join-Path $repo 'platform\windows-tsf\build'
$commonPath = Join-Path $buildRoot 'TsfBuild.Common.ps1'
$mainPath = Join-Path $repo 'scripts\build-tsf-windows.ps1'
$requiredPaths = @(
    $mainPath,
    $commonPath,
    (Join-Path $buildRoot 'CMakeLists.txt'),
    (Join-Path $buildRoot 'CMakePresets.json'),
    (Join-Path $buildRoot 'toolchain.json'),
    (Join-Path $buildRoot 'smoke-test-plan.json'),
    (Join-Path $buildRoot 'README.md'),
    (Join-Path $buildRoot 'tests\Invoke-TsfWindowsSmokeTests.ps1')
)
foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required TSF harness file is missing: $path"
    }
}

$parseFailures = @()
$powerShellPaths = @($requiredPaths | Where-Object { $_.ToLowerInvariant().EndsWith('.ps1') })
foreach ($path in $powerShellPaths) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($null -ne $errors -and $errors.Count -gt 0) {
        foreach ($parseError in $errors) {
            $parseFailures += ("{0}:{1}:{2}: {3}" -f $path, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
        }
    }
}
if ($parseFailures.Count -gt 0) {
    throw ("PowerShell syntax check failed:`n" + ($parseFailures -join "`n"))
}

$config = Get-Content -LiteralPath (Join-Path $buildRoot 'toolchain.json') -Raw | ConvertFrom-Json
if ([string]$config.platform -ne 'windows' -or [string]$config.architecture -ne 'x64' -or
    [string]$config.target -ne 'x86_64-pc-windows-msvc') {
    throw 'toolchain.json is not pinned to Windows x64 / x86_64-pc-windows-msvc.'
}
if ([string]$config.msvc.toolset -ne 'v143' -or
    [string]$config.windowsSdk.version -ne '10.0.26100.0' -or
    [string]$config.cmake.version -ne '3.31.6' -or
    [string]$config.bazel.version -ne '9.0.2' -or
    [string]$config.python.minimumVersion -ne '3.10' -or
    [string]$config.bazel.msvcToolchain -ne '@local_config_cc//:cc-toolchain-x64_windows' -or
    [string]$config.bazel.targetDefine -ne 'TARGET=oss_windows' -or
    [string]$config.firstTarget.architecture -ne 'x64' -or
    [string]$config.firstTarget.bazel -ne '//win32/tip:mozc_tip64') {
    throw 'toolchain.json has an unexpected MSVC/SDK/CMake/Bazel pin.'
}
if ([string]$config.mozc.gitlink -ne '13c98988247aa711d99db9e348ec2a597d14b5cd' -or
    [string]$config.mozc.workspace -ne 'third_party/mozc/src') {
    throw 'toolchain.json does not pin the expected third_party/mozc checkout.'
}
$requiredExports = @($config.dll.requiredExports)
if ($requiredExports.Count -ne 2 -or
    $requiredExports -notcontains 'DllGetClassObject' -or
    $requiredExports -notcontains 'DllCanUnloadNow') {
    throw 'The required TSF DLL export policy must be DllGetClassObject and DllCanUnloadNow.'
}
$registrationExports = @($config.dll.registrationExports)
if ($registrationExports -notcontains 'DllRegisterServer' -or
    $registrationExports -notcontains 'DllUnregisterServer') {
    throw 'Optional registration exports are not recorded separately from required TIP exports.'
}
$noRunfilesFlags = @($config.bazel.noRunfilesFallbackFlags)
if ($noRunfilesFlags -notcontains '--nowindows_enable_symlinks' -or
    $noRunfilesFlags -notcontains '--nobuild_runfile_links' -or
    $noRunfilesFlags -notcontains '--nobuild_runfile_manifests') {
    throw 'The pinned Bazel fallback must disable runfile links and runfile manifests.'
}

$mainText = Get-Content -LiteralPath $mainPath -Raw
$commonText = Get-Content -LiteralPath $commonPath -Raw
$runnerText = Get-Content -LiteralPath (Join-Path $buildRoot 'tests\Invoke-TsfWindowsSmokeTests.ps1') -Raw
$cmakeText = Get-Content -LiteralPath (Join-Path $buildRoot 'CMakeLists.txt') -Raw
$staticChecks = @(
    @{ Name = 'target pin'; Text = $mainText; Needle = 'x86_64-pc-windows-msvc' },
    @{ Name = 'x64 PE machine'; Text = $commonText; Needle = '0x8664' },
    @{ Name = 'PE32+ magic'; Text = $commonText; Needle = '0x20b' },
    @{ Name = 'DLL characteristic'; Text = $commonText; Needle = 'TsfDllCharacteristic' },
    @{ Name = 'dumpbin export validation'; Text = $commonText; Needle = '/exports' },
    @{ Name = 'Windows host gate'; Text = $commonText; Needle = 'must run on Windows' },
    @{ Name = 'VS x64 initialization'; Text = $commonText; Needle = 'VsDevCmd.bat -arch=x64 -host_arch=x64' },
    @{ Name = 'WSL UNC handling'; Text = $commonText; Needle = 'pushd' },
    @{ Name = 'pinned Mozc preparation'; Text = $mainText; Needle = 'prepare-pinned-mozc.ps1' },
    @{ Name = 'overlay cache fingerprint'; Text = $commonText; Needle = 'Get-TsfMozcOverlayFingerprint' },
    @{ Name = 'all Mozc patches fingerprinted'; Text = $commonText; Needle = '0003-session-generation-binding.patch' },
    @{ Name = 'pinned Mozc check'; Text = $commonText; Needle = 'Get-TsfPinnedMozcInfo' },
    @{ Name = 'Bazel symlink fallback'; Text = $mainText; Needle = 'no-runfiles fallback' },
    @{ Name = 'no runfile links flag'; Text = $mainText; Needle = '--nobuild_runfile_links' },
    @{ Name = 'no runfile manifests flag'; Text = $mainText; Needle = '--nobuild_runfile_manifests' },
    @{ Name = 'VsDevCmd override'; Text = $mainText; Needle = 'VsDevCmdPath' },
    @{ Name = 'incremental cache root'; Text = $mainText; Needle = 'BuildCacheDirectory' },
    @{ Name = 'CMake WSL project mirror'; Text = $mainText; Needle = 'cmake-project' },
    @{ Name = 'Bazel disk cache'; Text = $mainText; Needle = '--disk_cache=' },
    @{ Name = 'Bazel repository cache'; Text = $mainText; Needle = '--repository_cache=' },
    @{ Name = 'Windows symlink fallback flag'; Text = $mainText; Needle = '--nowindows_enable_symlinks' },
    @{ Name = 'MSVC Bazel toolchain'; Text = $mainText; Needle = 'msvcToolchain' },
    @{ Name = 'MSVC Bazel config'; Text = $mainText; Needle = 'msvcConfig' },
    @{ Name = 'platform config isolation'; Text = $mainText; Needle = '--noenable_platform_specific_config' },
    @{ Name = 'Bazel batch mode'; Text = $mainText; Needle = '--batch' },
    @{ Name = 'action PATH'; Text = $mainText; Needle = "'--action_env=PATH'" },
    @{ Name = 'repository PATH'; Text = $mainText; Needle = "'--repo_env=PATH'" },
    @{ Name = 'explicit Python path'; Text = $mainText; Needle = 'Get-TsfWindowsActionPath' },
    @{ Name = 'explicit Bazel path'; Text = $mainText; Needle = 'BazelPath' },
    @{ Name = 'first x64 target guard'; Text = $mainText; Needle = 'x64 TIP-only' },
    @{ Name = 'shared CMake DLL'; Text = $cmakeText; Needle = 'add_library(${KANAI_TSF_TARGET_NAME} SHARED' },
    @{ Name = 'registration refusal'; Text = $cmakeText; Needle = 'KANAI_TSF_REFUSE_REGISTRATION' },
    @{ Name = 'smoke result gate'; Text = $mainText; Needle = 'Assert-TsfSmokeResult' },
    @{ Name = 'beta promotion gate'; Text = $mainText; Needle = 'PromoteNativeBeta' },
    @{ Name = 'unverified claim'; Text = $mainText; Needle = 'not-a-native-beta' },
    @{ Name = 'artifact staging'; Text = $mainText; Needle = 'Stage-TsfArtifact' },
    @{ Name = 'native smoke runner'; Text = $runnerText; Needle = 'LoadLibraryExW' },
    @{ Name = 'no registration command'; Text = $mainText; Needle = 'It never calls regsvr32' }
)
foreach ($check in $staticChecks) {
    if ($check.Text.IndexOf($check.Needle, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Static TSF harness check failed ($($check.Name)); missing: $($check.Needle)"
    }
}
if ($mainText -match '(?im)^\s*(?:Start-Process|&\s+|Invoke-Expression).*\b(regsvr32|reg\.exe)\b') {
    throw 'The build harness contains a registration command invocation.'
}

$plan = Get-Content -LiteralPath (Join-Path $buildRoot 'smoke-test-plan.json') -Raw | ConvertFrom-Json
$planRequired = @($plan.claimPolicy.requiredTestIds)
foreach ($id in @('pe-x64-pe32plus', 'dll-load', 'dll-exports', 'tsf-host-load', 'tsf-lifecycle', 'candidate-ui', 'secure-field', 'app-container', 'focus-teardown')) {
    if ($planRequired -notcontains $id) {
        throw "Smoke-test plan is missing required test id: $id"
    }
}
if ([string]$plan.claimPolicy.nativeBetaRequires -notmatch 'windowsSmokeTests\.status\s*==\s*passed') {
    throw 'Smoke-test plan does not gate native-beta claims on passed Windows tests.'
}

if (-not $SkipPeUnit) {
    . $commonPath
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('kanai-tsf-harness-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    try {
        $x64 = Join-Path $testRoot 'x64.dll'
        $x86 = Join-Path $testRoot 'x86.dll'
        New-SyntheticPe -Path $x64 -Machine 0x8664
        New-SyntheticPe -Path $x86 -Machine 0x014c
        $image = Get-TsfPeImageInfo -Path $x64 -RequireDll
        if ($image.Machine -ne 0x8664 -or $image.OptionalMagic -ne 0x20b -or -not $image.IsDll) {
            throw 'Synthetic x64 PE parser test returned unexpected image metadata.'
        }
        $x86Rejected = $false
        try {
            [void](Assert-TsfX64PeImage -Path $x86 -RequireDll)
        }
        catch {
            $x86Rejected = $true
        }
        if (-not $x86Rejected) {
            throw 'PE parser accepted a non-x64 image.'
        }

        $safeRepository = Join-Path $testRoot 'safe-output\repository'
        $safeSource = Join-Path $safeRepository 'platform\windows-tsf'
        $safeBuild = Join-Path $safeSource 'build'
        $safeOutputCases = @(
            @{ Path = (Join-Path $safeRepository 'windows-beta\tsf'); Allowed = $true },
            @{ Path = (Join-Path $testRoot 'external-output'); Allowed = $true },
            @{ Path = $safeRepository; Allowed = $false },
            @{ Path = $testRoot; Allowed = $false },
            @{ Path = (Join-Path $safeRepository 'platform'); Allowed = $false },
            @{ Path = (Join-Path $safeSource 'generated'); Allowed = $false },
            @{ Path = (Join-Path $safeBuild 'generated'); Allowed = $false },
            @{ Path = (Join-Path $safeRepository 'third_party\stage'); Allowed = $false },
            @{ Path = (Join-Path $safeRepository 'target\tsf'); Allowed = $false }
        )
        foreach ($case in $safeOutputCases) {
            $accepted = $true
            try {
                Assert-TsfSafeOutputPath `
                    -Path ([string]$case.Path) `
                    -RepositoryRoot $safeRepository `
                    -SourceRoot $safeSource `
                    -BuildRoot $safeBuild | Out-Null
            }
            catch {
                $accepted = $false
            }
            if ($accepted -ne [bool]$case.Allowed) {
                throw "Unexpected safe-output decision for '$($case.Path)': accepted=$accepted expected=$($case.Allowed)"
            }
        }

        $oldLocalAppData = [System.Environment]::GetEnvironmentVariable('LOCALAPPDATA')
        try {
            $testLocalAppData = Join-Path $testRoot 'LocalAppData'
            [System.Environment]::SetEnvironmentVariable('LOCALAPPDATA', $testLocalAppData, 'Process')
            $actualCacheRoot = Get-TsfBuildCacheRoot -RepositoryRoot $safeRepository
            $expectedCacheRoot = [System.IO.Path]::GetFullPath((Join-Path $testLocalAppData 'KanaAI\tsf-build-cache'))
            if ($actualCacheRoot -ine $expectedCacheRoot) {
                throw "Default TSF cache root '$actualCacheRoot' does not match '$expectedCacheRoot'."
            }
        }
        finally {
            [System.Environment]::SetEnvironmentVariable('LOCALAPPDATA', $oldLocalAppData, 'Process')
        }

        # Multiple installed copies must resolve in PATH order, never as a
        # space-joined string that cannot be invoked.
        $originalCommandPath = $env:PATH
        try {
            $firstToolDirectory = Join-Path $testRoot 'first-tool'
            $secondToolDirectory = Join-Path $testRoot 'second-tool'
            New-Item -ItemType Directory -Path $firstToolDirectory, $secondToolDirectory | Out-Null
            foreach ($directory in @($firstToolDirectory, $secondToolDirectory)) {
                [System.IO.File]::WriteAllBytes((Join-Path $directory 'kanai-path-probe.exe'), [byte[]]@(0))
            }
            $env:PATH = "$firstToolDirectory;$secondToolDirectory;$originalCommandPath"
            $resolvedCommand = Get-TsfCommandPath -Name 'kanai-path-probe.exe'
            if ($resolvedCommand -ine (Join-Path $firstToolDirectory 'kanai-path-probe.exe')) {
                throw "Multiple command resolution did not preserve PATH precedence: $resolvedCommand"
            }
        }
        finally {
            $env:PATH = $originalCommandPath
        }

        $fingerprint = Get-TsfMozcOverlayFingerprint
        $fingerprintRecords = @($fingerprint -split "`n")
        $expectedFingerprintNames = @(
            'overlay',
            '0001-install-kanai-supplemental-model.patch',
            '0002-kanai-tsf-identity.patch',
            '0003-session-generation-binding.patch',
        '0004-windows-python-toolchain.patch',
        '0005-windows-runtime-identity.patch',
        '0006-windows-installer-runtime-path.patch'
        )
        if ($fingerprintRecords.Count -ne $expectedFingerprintNames.Count) {
            throw "Mozc overlay fingerprint has $($fingerprintRecords.Count) records; expected $($expectedFingerprintNames.Count)."
        }
        for ($index = 0; $index -lt $expectedFingerprintNames.Count; $index++) {
            $parts = $fingerprintRecords[$index] -split '\|', 2
            if ($parts.Count -ne 2 -or $parts[0] -cne $expectedFingerprintNames[$index] -or
                $parts[1] -notmatch '^[0-9a-f]{64}$') {
                throw "Mozc overlay fingerprint record $index is invalid: $($fingerprintRecords[$index])"
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

[pscustomobject]@{
    ParsedPowerShell = $powerShellPaths.Count
    RequiredFiles = $requiredPaths.Count
    StaticChecks = $staticChecks.Count
    PeUnit = (-not $SkipPeUnit)
    SafeOutputCases = 9
    DefaultCacheOutsideRepository = $true
    OverlayFingerprintRecords = 7
    PinnedTarget = [string]$config.target
    PinnedMozcCommit = [string]$config.mozc.gitlink
    NativeBeta = $false
    WindowsSmokeTests = 'not-run'
}
