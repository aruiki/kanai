# Build and validate the KanaAI Windows x64 TSF TIP source slices.
#
# This is intentionally a build/validation harness, not an installer or a
# registration script. It never calls regsvr32, never edits the registry, and
# never turns the existing workbench shell seam into a TSF DLL. A staged
# artifact is explicitly unverified unless the real Windows smoke-test host
# supplied by the caller has run every test in smoke-test-plan.json.
#
# The normal entry point is:
#   powershell -File scripts/build-tsf-windows.ps1 `
#       -RunWindowsSmokeTests -TestHostPath C:\path\to\tsf-host-test.ps1
#
# PlanOnly is a non-native diagnostic mode. It is useful on a non-Windows
# review machine, but it never creates an artifact and never makes a beta
# claim.

[CmdletBinding()]
param(
    [ValidateSet('CMake', 'Bazel')]
    [string]$BuildSystem = 'CMake',
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [string]$RepositoryRoot = '',
    [string]$SourceRoot = '',
    [string]$BuildRoot = '',
    [string]$OutputDirectory = '',
    [string]$BuildCacheDirectory = '',
    [string]$WindowsWorkspaceRoot = '',
    [string]$VsDevCmdPath = '',
    [string]$BazelOutputUserRoot = '',
    [string]$BazelDiskCache = '',
    [string]$BazelRepositoryCache = '',
    [string]$CMakeSource = '',
    [string]$CMakeTarget = 'KanaAI_TsfTip',
    [string]$BazelWorkspace = '',
    [string]$BazelTarget = '',
    [string]$BazelPlatform = '',
    [string]$TipDllName = 'KanaAI.TsfTip',
    [string]$ExportDefinition = '',
    [string[]]$SourceFile = @(),
    [string]$PrebuiltDll = '',
    [string]$SmokeTestCommand = '',
    [string]$TestHostPath = '',
    [switch]$SkipBuild,
    [switch]$RunWindowsSmokeTests,
    [switch]$PromoteNativeBeta,
    [switch]$AllowToolchainDrift,
    [switch]$IncludeSymbols,
    [switch]$KeepBuild,
    [switch]$ResetBuildCache,
    [switch]$RequireBazelSymlinks,
    [switch]$Force,
    [switch]$PlanOnly,
    [switch]$MozcValidationOnly,
    [switch]$SkipMozcPrepare,
    [switch]$NoWslMirror
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-TsfLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ('[tsf] ' + $Message)
}

function Get-TsfArrayProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $value = Get-TsfProperty -Object $Object -Name $Name
    if ($null -eq $value) {
        return @()
    }
    return @($value)
}

function Get-TsfBuildCacheRoot {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$Value = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    if ($RepositoryRoot -like '\\wsl*') {
        $localAppData = [string][System.Environment]::GetEnvironmentVariable('LOCALAPPDATA')
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            $localAppData = Get-TsfWindowsLocalTempRoot
        }
        return [System.IO.Path]::GetFullPath((Join-Path $localAppData 'KanaAI\tsf-build-cache'))
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'windows-beta\tsf-build-cache'))
}

function Resolve-TsfCachePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Value = '',
        [Parameter(Mandatory = $true)][string]$DefaultName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [System.IO.Path]::GetFullPath((Join-Path $Root $DefaultName))
    }
    if ([System.IO.Path]::IsPathRooted($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Value))
}

function Assert-TsfLocalBuildPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -like '\\*') {
        throw "Native Windows build/cache paths must not be WSL UNC paths: $Path"
    }
    return $Path
}

function Get-TsfWindowsActionPath {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$BazelPath
    )

    $parts = @(
        (Split-Path -Parent $PythonPath)
        (Split-Path -Parent $BazelPath)
    )
    $currentPath = [string][System.Environment]::GetEnvironmentVariable('PATH')
    if (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        $parts += @($currentPath -split ';')
    }
    $ordered = @()
    $seen = @{}
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace([string]$part)) {
            continue
        }
        $key = ([string]$part).Trim().ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $ordered += ([string]$part).Trim()
        }
    }
    return ($ordered -join ';')
}

function Assert-TsfPinnedConfiguration {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$BuildSystem,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [Parameter(Mandatory = $true)][string]$TipDllName,
        [Parameter(Mandatory = $true)][string[]]$RequiredExports,
        [string]$CMakeTarget = 'KanaAI_TsfTip',
        [switch]$AllowValidationDllName
    )

    if ([string](Get-TsfProperty -Object $Config -Name 'schemaVersion') -ne '1') {
        throw 'toolchain.json has an unsupported schemaVersion; expected schemaVersion=1.'
    }
    if ([string](Get-TsfProperty -Object $Config -Name 'platform') -ine 'windows' -or
        [string](Get-TsfProperty -Object $Config -Name 'architecture') -ine 'x64' -or
        [string](Get-TsfProperty -Object $Config -Name 'target') -ine 'x86_64-pc-windows-msvc') {
        throw 'The TSF harness is pinned to Windows x64 / x86_64-pc-windows-msvc and refuses a different target.'
    }
    $topLevelConfiguration = [string](Get-TsfProperty -Object $Config -Name 'configuration')
    if ($Configuration -ine $topLevelConfiguration) {
        throw "Only the pinned $topLevelConfiguration TSF configuration is supported; received $Configuration."
    }

    $configuredDllName = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'dll') -Name 'name')
    if (-not $AllowValidationDllName -and $TipDllName -ne $configuredDllName) {
        throw "TIP DLL name '$TipDllName' does not match the pinned name '$configuredDllName'."
    }
    $configuredExports = @(Get-TsfArrayProperty -Object (Get-TsfProperty -Object $Config -Name 'dll') -Name 'requiredExports')
    if ($configuredExports.Count -ne $RequiredExports.Count) {
        throw 'The required DLL export list differs from the pinned toolchain policy.'
    }
    for ($index = 0; $index -lt $RequiredExports.Count; $index++) {
        if ($configuredExports[$index] -cne $RequiredExports[$index]) {
            throw "The required DLL export list differs from the pinned toolchain policy at index $index."
        }
    }

    $generator = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'cmake') -Name 'generator')
    if ($BuildSystem -ieq 'CMake' -and $generator -ne 'Visual Studio 17 2022') {
        throw "The pinned CMake generator is '$generator', not '$BuildSystem'."
    }
    if ($BuildSystem -ieq 'Bazel') {
        $bazelVersion = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'bazel') -Name 'version')
        if ($bazelVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
            throw "The Bazel pin is invalid: $bazelVersion"
        }
    }
    $firstTarget = Get-TsfProperty -Object $Config -Name 'firstTarget'
    if ([string](Get-TsfProperty -Object $firstTarget -Name 'architecture') -ine 'x64' -or
        [string]::IsNullOrWhiteSpace([string](Get-TsfProperty -Object $firstTarget -Name 'bazel'))) {
        throw 'The first build target policy must be an explicit x64 Bazel TIP target.'
    }
    if ($CMakeTarget -match '(?i)(x86|arm64|installer|uia)') {
        throw "The first CMake pass is x64 TIP-only; target '$CMakeTarget' is blocked until the x64 artifact exists."
    }
    $forbiddenTargets = @(Get-TsfArrayProperty -Object $firstTarget -Name 'forbiddenTargetPatterns')
    foreach ($pattern in $forbiddenTargets) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) {
            throw 'The first build target policy contains an empty forbidden target pattern.'
        }
    }
}

function Get-TsfMsvcCompilerVersion {
    param([Parameter(Mandatory = $true)][string]$CompilerPath)

    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& $CompilerPath 2>&1 | Out-String)
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
    }
    $match = [regex]::Match($output, 'Version\s+([0-9]+\.[0-9]+\.[0-9]+)')
    if (-not $match.Success) {
        throw "Could not determine the MSVC compiler version from cl.exe: $CompilerPath"
    }
    return $match.Groups[1].Value
}

function Get-TsfCMakeVersion {
    param([Parameter(Mandatory = $true)][string]$CMakePath)

    $output = (& $CMakePath '--version' 2>&1 | Out-String)
    $match = [regex]::Match($output, 'cmake\s+version\s+([0-9]+\.[0-9]+\.[0-9]+)')
    if (-not $match.Success) {
        throw "Could not determine the CMake version: $CMakePath"
    }
    return $match.Groups[1].Value
}

function Resolve-TsfBazelCommand {
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:BAZEL)) {
        if (Test-Path -LiteralPath $env:BAZEL -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($env:BAZEL)
        }
        $command = Get-Command -Name $env:BAZEL -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [string]$command.Path
        }
        throw "BAZEL does not point to a Bazel/Bazelisk executable: $env:BAZEL"
    }
    foreach ($name in @('bazelisk.exe', 'bazelisk', 'bazel.exe', 'bazel')) {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [string]$command.Path
        }
    }
    throw 'Bazel or Bazelisk is required for -BuildSystem Bazel. No floating Bazel version is accepted.'
}

function Assert-TsfToolchain {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$BuildSystem,
        [Parameter(Mandatory = $true)][switch]$AllowDrift,
        [string]$WindowsWorkspaceRoot = '',
        [string]$VsDevCmdPath = '',
        [switch]$RequireBazelSymlinks
    )

    Initialize-TsfMSVCEnvironment -VsDevCmdPath $VsDevCmdPath
    $requiredCommands = @('cl.exe', 'link.exe', 'dumpbin.exe', 'rc.exe', 'cmake.exe')
    $commandPaths = [ordered]@{}
    foreach ($name in $requiredCommands) {
        $commandPaths[$name] = Get-TsfCommandPath -Name $name
    }

    $compilerPath = [string]$commandPaths['cl.exe']
    if ($compilerPath -notmatch '(?i)Hostx64[\\/]x64[\\/]cl\.exe$') {
        throw "cl.exe is not from the MSVC Hostx64/x64 target directory: $compilerPath"
    }
    $compilerVersion = Get-TsfMsvcCompilerVersion -CompilerPath $compilerPath
    $minimumCompilerVersion = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'msvc') -Name 'minimumCompilerVersion')
    if ([version]$compilerVersion -lt [version]$minimumCompilerVersion) {
        throw "MSVC $compilerVersion is older than the pinned minimum $minimumCompilerVersion. Install the v143 x64 toolset."
    }

    $expectedCMakeVersion = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'cmake') -Name 'version')
    $actualCMakeVersion = Get-TsfCMakeVersion -CMakePath ([string]$commandPaths['cmake.exe'])
    $cmakePinned = $actualCMakeVersion -eq $expectedCMakeVersion
    if (-not $cmakePinned) {
        if (-not $AllowDrift) {
            throw "CMake $actualCMakeVersion does not match the pinned $expectedCMakeVersion. Use the pinned toolchain (or explicitly use -AllowToolchainDrift for a non-release diagnostic build)."
        }
        Write-TsfLog "WARNING: CMake $actualCMakeVersion differs from the pin $expectedCMakeVersion; artifacts will remain unverified."
    }

    $sdkConfig = Get-TsfProperty -Object $Config -Name 'windowsSdk'
    $expectedSdkVersion = [string](Get-TsfProperty -Object $sdkConfig -Name 'version')
    $sdk = Get-TsfWindowsSdk -ExpectedVersion $expectedSdkVersion
    $windowsRoot = [string][System.Environment]::GetEnvironmentVariable('WINDIR')
    if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
        $windowsRoot = 'C:\Windows'
    }
    $tsfRuntime = Join-Path $windowsRoot 'System32\msctf.dll'
    if (-not (Test-Path -LiteralPath $tsfRuntime -PathType Leaf)) {
        throw "The Windows TSF runtime prerequisite is missing: $tsfRuntime. Install the Windows TSF/MSCTF components before building."
    }
    foreach ($header in @(Get-TsfArrayProperty -Object $sdkConfig -Name 'requiredHeaders')) {
        $headerPath = Get-TsfFileWithName -Root $sdk.Include -Name ([string]$header)
        if ([string]::IsNullOrWhiteSpace([string]$headerPath)) {
            throw "The pinned Windows SDK is missing TSF header '$header'. Install the Windows SDK TSF/UIA prerequisites before building."
        }
    }
    $x64LibRoot = Join-Path $sdk.Lib 'um\x64'
    foreach ($library in @(Get-TsfArrayProperty -Object $sdkConfig -Name 'requiredLibraries')) {
        $libraryPath = Join-Path $x64LibRoot ([string]$library)
        if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
            $libraryPath = Get-TsfFileWithName -Root $x64LibRoot -Name ([string]$library)
        }
        if ([string]::IsNullOrWhiteSpace([string]$libraryPath)) {
            throw "The pinned Windows SDK is missing x64 TSF import library '$library'. The TIP prerequisites are incomplete."
        }
    }

    $bazelRecord = $null
    $bazelSymlinkSupport = $null
    $pythonRecord = $null
    if ($BuildSystem -ieq 'Bazel') {
        $pythonPath = $null
        foreach ($pythonName in @('python.exe', 'python')) {
            $pythonCommands = @(Get-Command -Name $pythonName -CommandType Application -ErrorAction SilentlyContinue)
            if ($pythonCommands.Count -gt 0) {
                $pythonPath = [string]$pythonCommands[0].Path
                break
            }
        }
        if ($null -eq $pythonPath) {
            throw 'Python 3.10+ is required to prepare the pinned Mozc workspace.'
        }
        $oldPythonErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            Push-Location -LiteralPath 'C:\Windows'
            try {
                $pythonVersionOutput = (& $pythonPath '--version' 2>&1 | Out-String)
            }
            finally {
                Pop-Location
            }
        }
        finally {
            $ErrorActionPreference = $oldPythonErrorAction
        }
        $pythonMatch = [regex]::Match($pythonVersionOutput, 'Python\s+([0-9]+\.[0-9]+(?:\.[0-9]+)?)')
        $minimumPython = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'python') -Name 'minimumVersion')
        if (-not $pythonMatch.Success -or [version]$pythonMatch.Groups[1].Value -lt [version]$minimumPython) {
            throw "Python $minimumPython or newer is required; found $pythonPath."
        }
        $pythonRecord = [ordered]@{
            command = $pythonPath
            version = $pythonMatch.Groups[1].Value
            minimumVersion = $minimumPython
        }
        [void](Get-TsfCommandPath -Name 'tar.exe')
        $bazelSymlinkSupport = $false
        try {
            [void](Assert-TsfBazelSymlinkSupport -ProbeRoot $WindowsWorkspaceRoot)
            $bazelSymlinkSupport = $true
        }
        catch {
            if ($RequireBazelSymlinks) {
                throw
            }
            Write-TsfLog 'Bazel symlink probe failed; the x64 build will retry with the pinned no-runfiles fallback flags. No Windows security policy is changed.'
        }
        $bazelCommand = Resolve-TsfBazelCommand
        $expectedBazelVersion = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'bazel') -Name 'version')
        $oldBazelErrorAction = $ErrorActionPreference
        $oldUseVersion = [System.Environment]::GetEnvironmentVariable('USE_BAZEL_VERSION')
        try {
            $ErrorActionPreference = 'Continue'
            [System.Environment]::SetEnvironmentVariable('USE_BAZEL_VERSION', $expectedBazelVersion, 'Process')
            Push-Location -LiteralPath 'C:\Windows'
            try {
                $bazelVersionOutput = (& $bazelCommand 'version' 2>&1 | Out-String)
            }
            finally {
                Pop-Location
            }
        }
        finally {
            $ErrorActionPreference = $oldBazelErrorAction
            [System.Environment]::SetEnvironmentVariable('USE_BAZEL_VERSION', $oldUseVersion, 'Process')
        }
        $bazelMatch = [regex]::Match($bazelVersionOutput, 'Build label:\s*(?:labels/)?([0-9]+\.[0-9]+\.[0-9]+)')
        if (-not $bazelMatch.Success) {
            throw "Could not determine the Bazel version from $bazelCommand. Bazel 9.0.2 is required."
        }
        $bazelVersion = $bazelMatch.Groups[1].Value
        if ($bazelVersion -ne $expectedBazelVersion -and -not $AllowDrift) {
            throw "Bazel $bazelVersion does not match the pinned $expectedBazelVersion. Bazelisk must resolve the repository pin."
        }
        if ($bazelVersion -ne $expectedBazelVersion) {
            Write-TsfLog "WARNING: Bazel $bazelVersion differs from the pin $expectedBazelVersion; artifacts will remain unverified."
        }
        $bazelActionPath = Get-TsfWindowsActionPath -PythonPath $pythonPath -BazelPath $bazelCommand
        $bazelRecord = [ordered]@{
            command = $bazelCommand
            version = $bazelVersion
            pinned = ($bazelVersion -eq $expectedBazelVersion)
            actionPath = $bazelActionPath
        }
    }

    return [pscustomobject]@{
        platform = 'windows'
        architecture = 'x64'
        target = 'x86_64-pc-windows-msvc'
        msvc = [ordered]@{
            compiler = $compilerPath
            compilerVersion = $compilerVersion
            minimumCompilerVersion = $minimumCompilerVersion
            vsDevCmd = $VsDevCmdPath
            toolset = 'v143'
            pinned = $true
        }
        windowsSdk = [ordered]@{
            root = $sdk.Root
            version = $sdk.Version
            pinned = $true
            tsfRuntime = $tsfRuntime
        }
        cmake = [ordered]@{
            command = [string]$commandPaths['cmake.exe']
            version = $actualCMakeVersion
            expectedVersion = $expectedCMakeVersion
            pinned = $cmakePinned
            generator = 'Visual Studio 17 2022'
            platform = 'x64'
            toolset = 'v143'
            runtime = 'MultiThreadedDLL'
        }
        bazel = $bazelRecord
        bazelSymlinkSupport = $bazelSymlinkSupport
        python = $pythonRecord
        driftAllowed = [bool]$AllowDrift
    }
}

function Find-TsfBuiltDll {
    param(
        [Parameter(Mandatory = $true)][string]$BuildDirectory,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [Parameter(Mandatory = $true)][string]$TipDllName
    )

    $fileName = $TipDllName + '.dll'
    $preferredRoot = Join-Path $BuildDirectory $Configuration
    $candidates = @()
    if (Test-Path -LiteralPath $preferredRoot -PathType Container) {
        $candidates += @(Get-ChildItem -LiteralPath $preferredRoot -Recurse -Force -File -Filter $fileName)
    }
    if ($candidates.Count -eq 0 -and (Test-Path -LiteralPath $BuildDirectory -PathType Container)) {
        $candidates += @(Get-ChildItem -LiteralPath $BuildDirectory -Recurse -Force -File -Filter $fileName)
    }
    $candidates = @($candidates | Sort-Object -Property @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, FullName -Unique)
    if ($candidates.Count -eq 0) {
        throw "The $Configuration TIP build completed without producing $fileName. A console seam is not an acceptable substitute."
    }
    return [string]$candidates[0].FullName
}

function Invoke-TsfCMakeBuild {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CMakeSource,
        [Parameter(Mandatory = $true)][string]$BuildDirectory,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string[]]$SourceFile,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [Parameter(Mandatory = $true)][string]$TipDllName,
        [Parameter(Mandatory = $true)][string]$CMakeTarget,
        [string]$ExportDefinition = '',
        [Parameter(Mandatory = $true)]$Config
    )

    $cmakeSourceDirectory = $CMakeSource
    $cmakeListPath = $CMakeSource
    if (Test-Path -LiteralPath $CMakeSource -PathType Leaf) {
        $cmakeSourceDirectory = Split-Path -Parent $CMakeSource
        $cmakeListPath = $CMakeSource
    }
    elseif (Test-Path -LiteralPath $CMakeSource -PathType Container) {
        $cmakeListPath = Join-Path $CMakeSource 'CMakeLists.txt'
    }
    if (-not (Test-Path -LiteralPath $cmakeListPath -PathType Leaf)) {
        throw "The pinned CMakeLists.txt is missing: $cmakeListPath"
    }
    $cmakeSourceDirectory = [System.IO.Path]::GetFullPath($cmakeSourceDirectory)
    $cmake = Get-TsfCommandPath -Name 'cmake.exe'
    $cmakeSourceRoot = ([string]$SourceRoot).Replace('\', '/')
    $sourceList = (@($SourceFile) | ForEach-Object { ([string]$_).Replace('\', '/') }) -join ';'
    if ($sourceList.Contains(';') -and @($SourceFile).Count -eq 1) {
        throw 'A TSF source path may not contain a semicolon; pass multiple -SourceFile values instead.'
    }
    $generator = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'cmake') -Name 'generator')
    $toolset = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'msvc') -Name 'toolset')
    $runtime = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'cmake') -Name 'runtime')
    $arguments = @(
        '-S', $cmakeSourceDirectory,
        '-B', $BuildDirectory,
        '-G', $generator,
        '-A', 'x64',
        '-T', $toolset,
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=$runtime",
        "-DKANAI_TSF_SOURCE_ROOT=$cmakeSourceRoot",
        "-DKANAI_TSF_SOURCE_FILES=$sourceList",
        "-DKANAI_TSF_DLL_NAME=$TipDllName",
        "-DKANAI_TSF_TARGET_NAME=$CMakeTarget",
        '-DKANAI_TSF_REFUSE_REGISTRATION=ON'
    )
    if (-not [string]::IsNullOrWhiteSpace($ExportDefinition)) {
        if (-not (Test-Path -LiteralPath $ExportDefinition -PathType Leaf)) {
            throw "The module-definition file is missing: $ExportDefinition"
        }
        $cmakeExportDefinition = ([string]$ExportDefinition).Replace('\', '/')
        $arguments += "-DKANAI_TSF_DEF_FILE=$cmakeExportDefinition"
    }
    Invoke-TsfChecked -FilePath $cmake -Arguments $arguments -WorkingDirectory $RepositoryRoot
    Invoke-TsfChecked -FilePath $cmake -Arguments @(
        '--build', $BuildDirectory,
        '--config', $Configuration,
        '--target', $CMakeTarget,
        '--', '/verbosity:minimal', '/m'
    ) -WorkingDirectory $RepositoryRoot
    return Find-TsfBuiltDll -BuildDirectory $BuildDirectory -Configuration $Configuration -TipDllName $TipDllName
}

function Prepare-TsfMozcStage {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$MozcRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [string]$WindowsWorkspaceRoot = '',
        [switch]$Force
    )

    $prepareScript = Join-Path $RepositoryRoot 'platform\windows-tsf\tsf\scripts\prepare-pinned-mozc.ps1'
    if (-not (Test-Path -LiteralPath $prepareScript -PathType Leaf)) {
        throw "The pinned-Mozc preparation script is missing: $prepareScript. The harness will not build an unpatched or floating Mozc tree."
    }
    $localRoot = Get-TsfWindowsLocalTempRoot -Value $WindowsWorkspaceRoot
    if ($localRoot -like '\\*') {
        throw "WindowsWorkspaceRoot must be a native Windows-local path for Bazel/MSVC: $localRoot"
    }
    $stage = Join-Path $localRoot ('KanaAI-tsf-stage-' + $ExpectedCommit)
    $source = Join-Path $stage 'src'
    $stageMarker = Join-Path $stage '.kanai-pinned-commit'
    $overlaySource = Join-Path $RepositoryRoot 'platform\windows-tsf\tsf\host_overlay'
    $patchPath = Join-Path $RepositoryRoot 'platform\windows-tsf\tsf\patches\0001-install-kanai-supplemental-model.patch'
    if (-not (Test-Path -LiteralPath $overlaySource -PathType Container) -or
        -not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
        throw 'The pinned KanaAI source overlay/patch is missing; refusing to reuse or create a stale Mozc stage.'
    }
    $overlayFingerprint = (Get-TsfTreeFingerprint -Root $overlaySource) + ':' + (Get-TsfSha256 -Path $patchPath)
    $fingerprintMarker = Join-Path $stage '.kanai-overlay-fingerprint'
    $overlayCandidates = @(
        (Join-Path $source 'engine\kanai_ai\BUILD.bazel')
        (Join-Path $source 'kanai_ai\BUILD.bazel')
    )
    $overlayPresent = @($overlayCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0
    if ((Test-Path -LiteralPath (Join-Path $source 'MODULE.bazel') -PathType Leaf) -and
        $overlayPresent -and
        (Test-Path -LiteralPath $stageMarker -PathType Leaf) -and
        (Test-Path -LiteralPath $fingerprintMarker -PathType Leaf) -and
        ([System.IO.File]::ReadAllText($stageMarker).Trim() -eq $ExpectedCommit) -and
        ([System.IO.File]::ReadAllText($fingerprintMarker).Trim() -eq $overlayFingerprint)) {
        $cachedEngine = Get-Content -LiteralPath (Join-Path $source 'engine\modules.cc') -Raw
        if ($cachedEngine.IndexOf('kanai::tsf::KanaAiSupplementalModel', [System.StringComparison]::Ordinal) -ge 0) {
            return [pscustomobject]@{
                Root = $stage
                Workspace = $source
                Commit = $ExpectedCommit
                Prepared = $true
                Reused = $true
            }
        }
    }
    $oldGitCount = [System.Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT')
    $oldGitKeys = @(
        [System.Environment]::GetEnvironmentVariable('GIT_CONFIG_KEY_0'),
        [System.Environment]::GetEnvironmentVariable('GIT_CONFIG_KEY_1'),
        [System.Environment]::GetEnvironmentVariable('GIT_CONFIG_KEY_2')
    )
    $oldGitValues = @(
        [System.Environment]::GetEnvironmentVariable('GIT_CONFIG_VALUE_0'),
        [System.Environment]::GetEnvironmentVariable('GIT_CONFIG_VALUE_1'),
        [System.Environment]::GetEnvironmentVariable('GIT_CONFIG_VALUE_2')
    )
    try {
        # Windows Git sees WSL files as mode-changing unless filemode is
        # disabled. These settings affect only the disposable staging command.
        [System.Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', '3', 'Process')
        [System.Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_0', 'safe.directory', 'Process')
        [System.Environment]::SetEnvironmentVariable('GIT_CONFIG_VALUE_0', '*', 'Process')
        [System.Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_1', 'core.autocrlf', 'Process')
        [System.Environment]::SetEnvironmentVariable('GIT_CONFIG_VALUE_1', 'false', 'Process')
        [System.Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_2', 'core.filemode', 'Process')
        [System.Environment]::SetEnvironmentVariable('GIT_CONFIG_VALUE_2', 'false', 'Process')
        Push-Location -LiteralPath 'C:\Windows'
        try {
            & $prepareScript -MozcRoot $MozcRoot -OutputDirectory $stage -ExpectedCommit $ExpectedCommit -Force:$Force | Out-Null
        }
        finally {
            Pop-Location
        }
    }
    finally {
        [System.Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', $oldGitCount, 'Process')
        for ($index = 0; $index -lt 3; $index++) {
            [System.Environment]::SetEnvironmentVariable(('GIT_CONFIG_KEY_' + $index), $oldGitKeys[$index], 'Process')
            [System.Environment]::SetEnvironmentVariable(('GIT_CONFIG_VALUE_' + $index), $oldGitValues[$index], 'Process')
        }
    }
    $overlayCandidates = @(
        (Join-Path $source 'engine\kanai_ai\BUILD.bazel')
        (Join-Path $source 'kanai_ai\BUILD.bazel')
    )
    $overlayPresent = @($overlayCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0
    if (-not (Test-Path -LiteralPath (Join-Path $source 'MODULE.bazel') -PathType Leaf) -or
        -not $overlayPresent) {
        throw "The prepared pinned-Mozc stage is incomplete: $stage"
    }
    $engineText = Get-Content -LiteralPath (Join-Path $source 'engine\modules.cc') -Raw
    if ($engineText.IndexOf('kanai::tsf::KanaAiSupplementalModel', [System.StringComparison]::Ordinal) -lt 0) {
        throw "The prepared pinned-Mozc stage does not contain the KanaAI supplemental-model patch: $source"
    }
    Write-TsfUtf8File -Path (Join-Path $stage '.kanai-pinned-commit') -Content ($ExpectedCommit + [Environment]::NewLine)
    Write-TsfUtf8File -Path $fingerprintMarker -Content ($overlayFingerprint + [Environment]::NewLine)
    return [pscustomobject]@{
        Root = $stage
        Workspace = $source
        Commit = $ExpectedCommit
        Prepared = $true
        Reused = $false
    }
}

function Invoke-TsfBazelBuild {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$BazelWorkspace,
        [Parameter(Mandatory = $true)][string]$BazelTarget,
        [Parameter(Mandatory = $true)][string]$TipDllName,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$BuildDirectory,
        [string]$OutputUserRoot = '',
        [string]$DiskCache = '',
        [string]$RepositoryCache = '',
        [string]$PythonPath = '',
        [string]$ActionPath = '',
        [bool]$SymlinkSupport = $true
    )

    if ([string]::IsNullOrWhiteSpace($BazelTarget)) {
        throw '-BuildSystem Bazel requires an explicit x64 -BazelTarget for the first TSF TIP DLL. The existing console seam target is not accepted.'
    }
    $targets = @($BazelTarget)
    if ($targets.Count -ne 1) {
        throw 'The accelerated first pass accepts exactly one x64 TIP target; do not batch x86, UIA, server, or installer targets.'
    }
    $firstTargetPolicy = Get-TsfProperty -Object $Config -Name 'firstTarget'
    foreach ($pattern in @(Get-TsfArrayProperty -Object $firstTargetPolicy -Name 'forbiddenTargetPatterns')) {
        if ($BazelTarget -match ('(?i)' + [regex]::Escape([string]$pattern))) {
            throw "The first build target is blocked by the x64-only policy ('$pattern'): $BazelTarget"
        }
    }
    if (-not (Test-Path -LiteralPath $BazelWorkspace -PathType Container)) {
        throw "Bazel workspace does not exist: $BazelWorkspace"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $BazelWorkspace 'MODULE.bazel') -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $BazelWorkspace 'WORKSPACE') -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $BazelWorkspace 'WORKSPACE.bazel') -PathType Leaf)) {
        throw "Bazel workspace has no MODULE.bazel/WORKSPACE: $BazelWorkspace"
    }
    $bazel = Resolve-TsfBazelCommand
    if ([string]::IsNullOrWhiteSpace($PythonPath)) {
        $pythonCommand = @(Get-Command -Name 'python.exe' -CommandType Application -ErrorAction SilentlyContinue)
        if ($pythonCommand.Count -eq 0) {
            $pythonCommand = @(Get-Command -Name 'python' -CommandType Application -ErrorAction SilentlyContinue)
        }
        if ($pythonCommand.Count -eq 0) {
            throw 'Python is required for the pinned Mozc x64 action environment.'
        }
        $PythonPath = [string]$pythonCommand[0].Path
    }
    if ([string]::IsNullOrWhiteSpace($ActionPath)) {
        $ActionPath = Get-TsfWindowsActionPath -PythonPath $PythonPath -BazelPath $bazel
    }
    $bazelConfig = Get-TsfProperty -Object $Config -Name 'bazel'
    $platform = [string](Get-TsfProperty -Object $bazelConfig -Name 'platform')
    $cpu = [string](Get-TsfProperty -Object $bazelConfig -Name 'cpu')
    $releaseConfig = [string](Get-TsfProperty -Object $bazelConfig -Name 'releaseConfig')
    $msvcConfig = [string](Get-TsfProperty -Object $bazelConfig -Name 'msvcConfig')
    $msvcToolchain = [string](Get-TsfProperty -Object $bazelConfig -Name 'msvcToolchain')
    $targetDefine = [string](Get-TsfProperty -Object $bazelConfig -Name 'targetDefine')
    $mode = if ($Configuration -ieq 'Release') { 'opt' } else { 'fastbuild' }
    $oldUseVersion = [System.Environment]::GetEnvironmentVariable('USE_BAZEL_VERSION')
    $oldPath = [System.Environment]::GetEnvironmentVariable('PATH')
    try {
        [System.Environment]::SetEnvironmentVariable('USE_BAZEL_VERSION', [string](Get-TsfProperty -Object (Get-TsfProperty -Object $Config -Name 'bazel') -Name 'version'), 'Process')
        [System.Environment]::SetEnvironmentVariable('PATH', $ActionPath, 'Process')
        $startupCacheArguments = @()
        $buildCacheArguments = @()
        if (-not [string]::IsNullOrWhiteSpace($OutputUserRoot)) {
            [void](Assert-TsfLocalBuildPath -Path $OutputUserRoot)
            New-Item -ItemType Directory -Path $OutputUserRoot -Force | Out-Null
            $startupCacheArguments += "--output_user_root=$OutputUserRoot"
        }
        if (-not [string]::IsNullOrWhiteSpace($DiskCache)) {
            [void](Assert-TsfLocalBuildPath -Path $DiskCache)
            New-Item -ItemType Directory -Path $DiskCache -Force | Out-Null
            $buildCacheArguments += "--disk_cache=$DiskCache"
        }
        if (-not [string]::IsNullOrWhiteSpace($RepositoryCache)) {
            [void](Assert-TsfLocalBuildPath -Path $RepositoryCache)
            New-Item -ItemType Directory -Path $RepositoryCache -Force | Out-Null
            $buildCacheArguments += "--repository_cache=$RepositoryCache"
        }
        $pathArguments = @(
            "--action_env=PATH=$ActionPath"
            "--repo_env=PATH=$ActionPath"
        )
        $bazelVc = [string][System.Environment]::GetEnvironmentVariable('BAZEL_VC')
        if (-not [string]::IsNullOrWhiteSpace($bazelVc)) {
            $pathArguments += @(
                "--action_env=BAZEL_VC=$bazelVc"
                "--repo_env=BAZEL_VC=$bazelVc"
            )
        }
        $bazelBuildArguments = @(
            'build', $BazelTarget,
            "--config=$releaseConfig",
            "--config=$msvcConfig",
            '--noenable_platform_specific_config',
            "--extra_toolchains=$msvcToolchain",
            "--define=$targetDefine",
            "--platforms=$platform",
            "--cpu=$cpu",
            "--compilation_mode=$mode",
            '--experimental_convenience_symlinks=ignore'
        ) + $pathArguments
        $fallbackFlags = @(Get-TsfArrayProperty -Object (Get-TsfProperty -Object $Config -Name 'bazel') -Name 'noRunfilesFallbackFlags')
        $fallbackStartup = @()
        $fallbackBuild = @()
        foreach ($fallbackFlag in $fallbackFlags) {
            if ([string]$fallbackFlag -eq '--nowindows_enable_symlinks') {
                $fallbackStartup += [string]$fallbackFlag
            }
            else {
                $fallbackBuild += [string]$fallbackFlag
            }
        }
        $normalArguments = @($startupCacheArguments + @('--batch') + $bazelBuildArguments + $buildCacheArguments)
        $fallbackArguments = @($startupCacheArguments + @('--batch') + $fallbackStartup + $bazelBuildArguments + $buildCacheArguments + $fallbackBuild)
        if (-not $SymlinkSupport) {
            Write-TsfLog 'Using the pinned x64 no-runfiles fallback flags because the Windows symlink probe was unavailable.'
            Invoke-TsfChecked -FilePath $bazel -Arguments $fallbackArguments -WorkingDirectory $BazelWorkspace
        }
        else {
            try {
                Invoke-TsfChecked -FilePath $bazel -Arguments $normalArguments -WorkingDirectory $BazelWorkspace
            }
            catch {
                Write-TsfLog 'The first Bazel x64 attempt failed; retrying once with --nowindows_enable_symlinks, --nobuild_runfile_links, and --nobuild_runfile_manifests.'
                try {
                    Invoke-TsfChecked -FilePath $bazel -Arguments $fallbackArguments -WorkingDirectory $BazelWorkspace
                }
                catch {
                    throw ('The pinned x64 Bazel target failed both the normal and no-runfiles fallback attempts. No broad Windows security changes were made; use a Windows build environment with symlink support or retain the exact failure logs: ' + $_.Exception.Message)
                }
            }
        }
    }
    finally {
        [System.Environment]::SetEnvironmentVariable('USE_BAZEL_VERSION', $oldUseVersion, 'Process')
        [System.Environment]::SetEnvironmentVariable('PATH', $oldPath, 'Process')
    }
    $bazelBin = Join-Path $BazelWorkspace 'bazel-bin'
    $bazelSearchRoot = if (Test-Path -LiteralPath $bazelBin -PathType Container) {
        $bazelBin
    }
    elseif (-not [string]::IsNullOrWhiteSpace($OutputUserRoot)) {
        $OutputUserRoot
    }
    else {
        $BazelWorkspace
    }
    return Find-TsfBuiltDll -BuildDirectory $bazelSearchRoot -Configuration $Configuration -TipDllName $TipDllName
}

function Assert-TsfFirstX64SourceSet {
    param(
        [Parameter(Mandatory = $true)]$SourceInfo,
        [Parameter(Mandatory = $true)]$Config
    )

    $forbidden = @(Get-TsfArrayProperty -Object (Get-TsfProperty -Object $Config -Name 'firstTarget') -Name 'forbiddenTargetPatterns')
    foreach ($file in @($SourceInfo.Files)) {
        foreach ($pattern in $forbidden) {
            if ([string]$file -match ('(?i)(^|[\\/])' + [regex]::Escape([string]$pattern) + '([\\/]|[^A-Za-z0-9_.-]|$)')) {
                throw ("The first x64 pass refuses source slice '{0}' because it matches blocked scope '{1}'. Build the x64 TIP artifact first; x86/UIA/installer work is a later pass." -f $file, $pattern)
            }
        }
    }
}

function Get-TsfSmokePlan {
    param([Parameter(Mandatory = $true)][string]$BuildRoot)

    $planPath = Join-Path $BuildRoot 'smoke-test-plan.json'
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        throw "The Windows smoke-test plan is missing: $planPath"
    }
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    $claimPolicy = Get-TsfProperty -Object $plan -Name 'claimPolicy'
    $required = @(Get-TsfArrayProperty -Object $claimPolicy -Name 'requiredTestIds')
    if ($required.Count -eq 0) {
        throw 'The smoke-test plan has no required test IDs; a native beta claim cannot be evaluated.'
    }
    return [pscustomobject]@{
        Path = $planPath
        Plan = $plan
        RequiredTestIds = @($required)
    }
}

function Assert-TsfSmokeResult {
    param(
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][string[]]$RequiredTestIds
    )

    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        throw "The Windows smoke-test command did not write its required result file: $ResultPath"
    }
    $result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
    $status = [string](Get-TsfProperty -Object $result -Name 'status')
    if ($status -ine 'passed') {
        throw "Windows TSF smoke tests did not pass (status=$status). No native beta claim is permitted."
    }
    $tests = @(Get-TsfArrayProperty -Object $result -Name 'tests')
    $byId = @{}
    foreach ($test in $tests) {
        $id = [string](Get-TsfProperty -Object $test -Name 'id')
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $byId[$id] = [string](Get-TsfProperty -Object $test -Name 'status')
        }
    }
    $missing = @()
    foreach ($id in $RequiredTestIds) {
        if (-not $byId.ContainsKey($id) -or $byId[$id] -ine 'passed') {
            $missing += $id
        }
    }
    if ($missing.Count -gt 0) {
        throw ('Windows smoke-test result is missing required passed test(s): ' + ($missing -join ', '))
    }
    return $result
}

function Invoke-TsfWindowsSmokeTests {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$BuildRoot,
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [string]$SmokeTestCommand = '',
        [string]$TestHostPath = '',
        [Parameter(Mandatory = $true)][string[]]$RequiredTestIds
    )

    $runner = $SmokeTestCommand
    if ([string]::IsNullOrWhiteSpace($runner)) {
        $runner = Join-Path $BuildRoot 'tests\Invoke-TsfWindowsSmokeTests.ps1'
    }
    elseif (-not [System.IO.Path]::IsPathRooted($runner)) {
        $candidate = Join-Path $RepositoryRoot $runner
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $runner = $candidate
        }
    }
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        throw "Windows smoke-test runner does not exist: $runner"
    }

    try {
        if ([System.IO.Path]::GetExtension($runner).ToLowerInvariant() -eq '.ps1') {
            $runnerArguments = @{
                DllPath = $DllPath
                ResultPath = $ResultPath
            }
            if (-not [string]::IsNullOrWhiteSpace($TestHostPath)) {
                $runnerArguments['TestHostPath'] = $TestHostPath
            }
            & $runner @runnerArguments
        }
        else {
            $arguments = @($DllPath, $ResultPath)
            if (-not [string]::IsWhiteSpace($TestHostPath)) {
                $arguments += $TestHostPath
            }
            & $runner @arguments
        }
    }
    catch {
        throw "Windows TSF smoke-test runner failed: $($_.Exception.Message)"
    }
    return Assert-TsfSmokeResult -ResultPath $ResultPath -RequiredTestIds $RequiredTestIds
}

function Get-TsfOrdinalFileRecords {
    param([Parameter(Mandatory = $true)][string]$Root)

    $records = @()
    foreach ($file in @(Get-TsfArtifactFiles -Root $Root)) {
        $relative = Get-TsfRelativePath -BasePath $Root -Path $file.FullName
        $records += [pscustomobject]@{
            path = $relative
            size = [long]$file.Length
            sha256 = Get-TsfSha256 -Path $file.FullName
        }
    }
    $paths = @($records | ForEach-Object { [string]$_.path })
    $sortedPaths = [string[]]@($paths)
    [Array]::Sort($sortedPaths, [System.StringComparer]::Ordinal)
    $byPath = @{}
    foreach ($record in $records) {
        $byPath[[string]$record.path] = $record
    }
    $ordered = @()
    foreach ($path in $sortedPaths) {
        $ordered += $byPath[$path]
    }
    return @($ordered)
}

function Copy-TsfOptionalFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        $parent = Split-Path -Parent $Destination
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        return $true
    }
    return $false
}

function Stage-TsfArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][string]$BuildRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$TipDllName,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Toolchain,
        [Parameter(Mandatory = $true)]$MozcInfo,
        [Parameter(Mandatory = $true)]$SourceInfo,
        [Parameter(Mandatory = $true)]$SmokeResult,
        [Parameter(Mandatory = $true)][string]$BuildDirectory,
        [string]$CacheRoot = '',
        [string]$BazelTarget = '',
        [string]$BazelWorkspace = '',
        [string]$ExportDefinition = '',
        [switch]$IncludeSymbols,
        [switch]$Promote,
        [switch]$Force
    )

    $parent = Split-Path -Parent $OutputDirectory
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "Could not determine the artifact parent directory: $OutputDirectory"
    }
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (Test-Path -LiteralPath $OutputDirectory) {
        if (-not $Force) {
            throw "Artifact output already exists: $OutputDirectory (use -Force to replace it)"
        }
        Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
    }

    $stage = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($OutputDirectory) + '.stage-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        $bin = Join-Path $stage 'bin'
        $lib = Join-Path $stage 'lib'
        $pdb = Join-Path $stage 'pdb'
        $legal = Join-Path $stage 'metadata'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        New-Item -ItemType Directory -Path $lib -Force | Out-Null
        New-Item -ItemType Directory -Path $pdb -Force | Out-Null
        New-Item -ItemType Directory -Path $legal -Force | Out-Null

        $dllDestination = Join-Path $bin ($TipDllName + '.dll')
        Copy-Item -LiteralPath $DllPath -Destination $dllDestination -Force

        $importLibrary = Join-Path -Path $BuildDirectory -ChildPath ('lib\' + $TipDllName + '.lib')
        [void](Copy-TsfOptionalFile -Source $importLibrary -Destination (Join-Path $lib ($TipDllName + '.lib')))
        if ($IncludeSymbols) {
            $pdbSource = [System.IO.Path]::ChangeExtension($DllPath, '.pdb')
            if (-not (Test-Path -LiteralPath $pdbSource -PathType Leaf)) {
                $pdbSource = Get-TsfFileWithName -Root $BuildDirectory -Name ($TipDllName + '.pdb')
            }
            [void](Copy-TsfOptionalFile -Source $pdbSource -Destination (Join-Path $pdb ($TipDllName + '.pdb')))
        }
        if (-not [string]::IsNullOrWhiteSpace($ExportDefinition)) {
            [void](Copy-TsfOptionalFile -Source $ExportDefinition -Destination (Join-Path $legal ($TipDllName + '.def')))
        }

        Copy-Item -LiteralPath (Join-Path $BuildRoot 'toolchain.json') -Destination (Join-Path $legal 'toolchain.json') -Force
        Copy-Item -LiteralPath (Join-Path $BuildRoot 'smoke-test-plan.json') -Destination (Join-Path $legal 'smoke-test-plan.json') -Force

        $smokeStatus = [string](Get-TsfProperty -Object $SmokeResult -Name 'status')
        $nativeBeta = [bool]$Promote -and $smokeStatus -ieq 'passed'
        if ($Promote -and -not $nativeBeta) {
            throw 'A native beta label was requested, but the complete Windows smoke-test result is not passed.'
        }
        $artifactStatus = if ($nativeBeta) {
            'native-beta-validated'
        }
        elseif ($smokeStatus -ieq 'passed') {
            'windows-smoke-passed-not-promoted'
        }
        else {
            'unverified-tsf-tip'
        }
        $claim = if ($nativeBeta) { 'native-beta-only-after-Windows-smoke-tests' } else { 'not-a-native-beta' }

        $sourceRevision = Get-TsfGitRevision -RepositoryRoot $RepositoryRoot
        $buildMetadata = [ordered]@{
            schemaVersion = 1
            repositoryRoot = $RepositoryRoot
            sourceRevision = $sourceRevision
            sourceSliceFiles = @($SourceInfo.Files)
            buildDirectory = $BuildDirectory
            buildCacheDirectory = $CacheRoot
            bazelTarget = $BazelTarget
            bazelWorkspace = $BazelWorkspace
            configuration = [string](Get-TsfProperty -Object $Config -Name 'configuration')
            target = 'x86_64-pc-windows-msvc'
            architecture = 'x64'
            tipDll = $TipDllName + '.dll'
            toolchain = $Toolchain
            mozc = [ordered]@{
                commit = $MozcInfo.Commit
                workspace = $MozcInfo.Workspace
                bazelVersion = $MozcInfo.BazelVersion
            }
            smokeStatus = $smokeStatus
        }
        Write-TsfJsonFile -Path (Join-Path $legal 'build-metadata.json') -Value $buildMetadata

        $notice = @(
            'KanaAI Windows TSF TIP artifact',
            '',
            ('Status: ' + $artifactStatus),
            ('Claim: ' + $claim),
            '',
            'This harness does not register, sign, or certify a TSF TIP.',
            'The existing Windows shell seam is not a TSF TIP.',
            'A native beta claim is permitted only when windowsSmokeTests.status=passed and every required test in smoke-test-plan.json passed on Windows.',
            'File presence, PE headers, exports, or packaging alone are not runtime verification.'
        ) -join [Environment]::NewLine
        Write-TsfUtf8File -Path (Join-Path $stage 'NOTICE.txt') -Content ($notice + [Environment]::NewLine)

        $manifest = [ordered]@{
            schemaVersion = 1
            product = 'KanaAI Windows TSF TIP'
            status = $artifactStatus
            claim = $claim
            nativeBeta = $nativeBeta
            windowsSmokeTests = [ordered]@{
                status = $smokeStatus
                requiredTestIds = @((Get-TsfSmokePlan -BuildRoot $BuildRoot).RequiredTestIds)
                result = $SmokeResult
            }
            target = [ordered]@{
                platform = 'windows'
                architecture = 'x64'
                triple = 'x86_64-pc-windows-msvc'
            }
            dll = [ordered]@{
                name = $TipDllName + '.dll'
                requiredExports = @((Get-TsfArrayProperty -Object (Get-TsfProperty -Object $Config -Name 'dll') -Name 'requiredExports'))
            }
            files = @()
        }
        $manifestPath = Join-Path $stage 'artifact-manifest.json'
        Write-TsfJsonFile -Path $manifestPath -Value $manifest
        # The manifest cannot contain its own final hash. Record the exact
        # payload/metadata set, then hash the manifest in SHA256SUMS below.
        $records = @(Get-TsfOrdinalFileRecords -Root $stage | Where-Object {
            $_.path -notin @('artifact-manifest.json', 'SHA256SUMS')
        })
        $manifest['files'] = @($records)
        Write-TsfJsonFile -Path $manifestPath -Value $manifest

        $checksumRecords = @(Get-TsfOrdinalFileRecords -Root $stage | Where-Object {
            $_.path -ne 'SHA256SUMS'
        })
        $sumLines = @($checksumRecords | ForEach-Object { ([string]$_.sha256) + '  ' + ([string]$_.path) })
        Write-TsfUtf8File -Path (Join-Path $stage 'SHA256SUMS') -Content (($sumLines -join [Environment]::NewLine) + [Environment]::NewLine)

        Move-Item -LiteralPath $stage -Destination $OutputDirectory
        $stage = $null
        return [pscustomobject]@{
            OutputDirectory = $OutputDirectory
            Dll = (Join-Path -Path $OutputDirectory -ChildPath ('bin\' + ($TipDllName + '.dll')))
            Manifest = (Join-Path $OutputDirectory 'artifact-manifest.json')
            Status = $artifactStatus
            NativeBeta = $nativeBeta
            WindowsSmokeStatus = $smokeStatus
        }
    }
    finally {
        if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    # Resolve this before dot-sourcing the helper script; the entry point must
    # be able to find the helper when launched from a WSL UNC path.
    $RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}
$repository = [System.IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    $BuildRoot = Join-Path $repository 'platform\windows-tsf\build'
}
$build = [System.IO.Path]::GetFullPath($BuildRoot)
$commonPath = Join-Path $build 'TsfBuild.Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "TSF harness helpers are missing: $commonPath"
}
. $commonPath

$sourceRootWasDefault = [string]::IsNullOrWhiteSpace($SourceRoot)
$bazelWorkspaceWasDefault = [string]::IsNullOrWhiteSpace($BazelWorkspace)
if ($sourceRootWasDefault) {
    $SourceRoot = Join-Path $repository 'platform\windows-tsf'
}
$SourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    # Bazel/MSBuild reject UNC working directories. When this script is
    # launched through WSL interop, default staging to a Windows-local temp
    # directory; callers can still provide an explicit path.
    if ($repository -like '\\wsl*') {
        $localTemp = [string][System.Environment]::GetEnvironmentVariable('TEMP')
        if ([string]::IsNullOrWhiteSpace($localTemp)) {
            $localTemp = [string][System.Environment]::GetEnvironmentVariable('TMP')
        }
        if ([string]::IsNullOrWhiteSpace($localTemp)) {
            $localTemp = 'C:\Windows\Temp'
        }
        $OutputDirectory = Join-Path $localTemp 'KanaAI-tsf'
    }
    else {
        $OutputDirectory = Join-Path $repository 'windows-beta\tsf'
    }
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if ([string]::IsNullOrWhiteSpace($CMakeSource)) {
    $CMakeSource = Join-Path $build 'CMakeLists.txt'
}
$CMakeSource = [System.IO.Path]::GetFullPath($CMakeSource)
if ($bazelWorkspaceWasDefault) {
    # The pinned Mozc workspace is selected below, once its gitlink has been
    # verified. Keeping this assignment explicit prevents a floating external
    # Bazel workspace from being used accidentally.
    $BazelWorkspace = $SourceRoot
}
$BazelWorkspace = [System.IO.Path]::GetFullPath($BazelWorkspace)
if (-not [string]::IsNullOrWhiteSpace($BazelPlatform)) {
    # An explicit platform is still checked against the pin before it is used.
    $pinnedBazelPlatform = [string](Get-TsfProperty -Object (Get-TsfProperty -Object (Get-Content -LiteralPath (Join-Path $build 'toolchain.json') -Raw | ConvertFrom-Json) -Name 'bazel') -Name 'platform')
    if ($BazelPlatform -ne $pinnedBazelPlatform) {
        throw "Bazel platform '$BazelPlatform' differs from the pinned platform '$pinnedBazelPlatform'."
    }
}
if ($TipDllName.EndsWith('.dll', [System.StringComparison]::OrdinalIgnoreCase)) {
    $TipDllName = $TipDllName.Substring(0, $TipDllName.Length - 4)
}
if ($TipDllName -notmatch '^[A-Za-z0-9_.-]+$') {
    throw "Unsafe TIP DLL basename: $TipDllName"
}
if ($PromoteNativeBeta -and -not $RunWindowsSmokeTests) {
    throw 'A native beta claim requires -RunWindowsSmokeTests. No PE/static validation shortcut can promote an artifact.'
}

$configPath = Join-Path $build 'toolchain.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Pinned TSF toolchain configuration is missing: $configPath"
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$dllConfig = Get-TsfProperty -Object $config -Name 'dll'
$requiredExports = @(Get-TsfArrayProperty -Object $dllConfig -Name 'requiredExports')
if ($requiredExports.Count -eq 0) {
    throw 'toolchain.json does not define required DLL exports.'
}
Assert-TsfPinnedConfiguration -Config $config -BuildSystem $BuildSystem -Configuration $Configuration -TipDllName $TipDllName -RequiredExports $requiredExports -CMakeTarget $CMakeTarget -AllowValidationDllName:$MozcValidationOnly

$mozcConfig = Get-TsfProperty -Object $config -Name 'mozc'
$mozcInfo = Get-TsfPinnedMozcInfo -RepositoryRoot $repository -ExpectedCommit ([string](Get-TsfProperty -Object $mozcConfig -Name 'gitlink')) -ExpectedBazelVersion ([string](Get-TsfProperty -Object $mozcConfig -Name 'bazelVersion'))
$originalMozcWorkspace = $mozcInfo.Workspace
$cacheRoot = Get-TsfBuildCacheRoot -RepositoryRoot $repository -Value $BuildCacheDirectory
$cacheRoot = [System.IO.Path]::GetFullPath($cacheRoot).TrimEnd([char[]]'\/')
$cachePathRoot = [System.IO.Path]::GetPathRoot($cacheRoot).TrimEnd([char[]]'\/')
$repositoryForCache = [System.IO.Path]::GetFullPath($repository).TrimEnd([char[]]'\/')
$sourceForCache = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]'\/')
$buildForCache = [System.IO.Path]::GetFullPath($build).TrimEnd([char[]]'\/')
if ($cacheRoot -ieq $cachePathRoot -or $cacheRoot -ieq $repositoryForCache -or
    $cacheRoot -ieq $sourceForCache -or $cacheRoot -ieq $buildForCache) {
    throw "Build cache directory must be a dedicated child, not a filesystem/source root: $cacheRoot"
}
if (-not $PlanOnly -and $ResetBuildCache -and (Test-Path -LiteralPath $cacheRoot)) {
    Remove-Item -LiteralPath $cacheRoot -Recurse -Force
}
if ([string]::IsNullOrWhiteSpace($WindowsWorkspaceRoot)) {
    $WindowsWorkspaceRoot = $cacheRoot
}
if (-not $PlanOnly -and $CMakeSource -like '\\wsl*') {
    $cmakeSourceList = $CMakeSource
    if (Test-Path -LiteralPath $CMakeSource -PathType Container) {
        $cmakeSourceList = Join-Path $CMakeSource 'CMakeLists.txt'
    }
    if (-not (Test-Path -LiteralPath $cmakeSourceList -PathType Leaf)) {
        throw "The pinned CMakeLists.txt is missing: $cmakeSourceList"
    }
    $cmakeProjectCache = Join-Path $cacheRoot 'cmake-project'
    New-Item -ItemType Directory -Path $cmakeProjectCache -Force | Out-Null
    $cachedCMakeList = Join-Path $cmakeProjectCache 'CMakeLists.txt'
    if (-not (Test-Path -LiteralPath $cachedCMakeList -PathType Leaf) -or
        (Get-TsfSha256 -Path $cachedCMakeList) -ne (Get-TsfSha256 -Path $cmakeSourceList)) {
        Copy-Item -LiteralPath $cmakeSourceList -Destination $cachedCMakeList -Force
    }
    $CMakeSource = $cachedCMakeList
}
$mozcMirror = $null
if ($BuildSystem -ieq 'Bazel' -and $bazelWorkspaceWasDefault) {
    $BazelWorkspace = $mozcInfo.Workspace
    $BazelWorkspace = [System.IO.Path]::GetFullPath($BazelWorkspace)
}
if (-not $PlanOnly -and $BuildSystem -ieq 'Bazel') {
    $preparedMarkers = @(
        (Join-Path $BazelWorkspace 'engine\kanai_ai\BUILD.bazel')
        (Join-Path $BazelWorkspace 'kanai_ai\BUILD.bazel')
    )
    $preparedMarkerPresent = @($preparedMarkers | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0
    $commitMarker = Join-Path (Split-Path -Parent $BazelWorkspace) '.kanai-pinned-commit'
    $isPreparedStage = (Test-Path -LiteralPath (Join-Path $BazelWorkspace 'MODULE.bazel') -PathType Leaf) -and
        $preparedMarkerPresent -and
        (Test-Path -LiteralPath $commitMarker -PathType Leaf) -and
        ([System.IO.File]::ReadAllText($commitMarker).Trim() -eq $mozcInfo.Commit)
    if ($isPreparedStage) {
        $mozcInfo = [pscustomobject]@{
            Root = (Split-Path -Parent $BazelWorkspace)
            Workspace = $BazelWorkspace
            OriginalWorkspace = $originalMozcWorkspace
            Commit = $mozcInfo.Commit
            BazelVersion = $mozcInfo.BazelVersion
            BazeliskConfig = (Join-Path $BazelWorkspace '.bazeliskrc')
            Prepared = $true
        }
    }
    elseif (-not $SkipMozcPrepare) {
        Write-TsfLog 'Preparing a disposable Windows-local copy of the exact pinned Mozc checkout and applying the KanaAI source-slice patch.'
        $prepared = Prepare-TsfMozcStage -RepositoryRoot $repository -MozcRoot $mozcInfo.Root -ExpectedCommit $mozcInfo.Commit -WindowsWorkspaceRoot $WindowsWorkspaceRoot -Force
        if ($prepared.Reused) {
            Write-TsfLog ("Reusing prepared pinned-Mozc stage: {0}" -f $prepared.Workspace)
        }
        else {
            Write-TsfLog ("Prepared pinned-Mozc stage: {0}" -f $prepared.Workspace)
        }
        $BazelWorkspace = $prepared.Workspace
        $mozcInfo = [pscustomobject]@{
            Root = $prepared.Root
            Workspace = $prepared.Workspace
            OriginalWorkspace = $originalMozcWorkspace
            Commit = $prepared.Commit
            BazelVersion = $mozcInfo.BazelVersion
            BazeliskConfig = (Join-Path $prepared.Workspace '.bazeliskrc')
            Prepared = $true
        }
    }
    elseif ($BazelWorkspace -like '\\wsl*') {
        if ($NoWslMirror) {
            throw 'Bazel cannot use a WSL UNC workspace. Remove -NoWslMirror, pass a native Windows checkout, or allow the pinned preparation script.'
        }
        Write-TsfLog 'Mirroring the unpatched pinned Mozc workspace to a Windows-local path for diagnostic validation only.'
        $mozcMirror = Mirror-TsfMozcWorkspace -Workspace $BazelWorkspace -Commit $mozcInfo.Commit -DestinationRoot $WindowsWorkspaceRoot
        $BazelWorkspace = $mozcMirror.Workspace
        $mozcInfo = [pscustomobject]@{
            Root = $mozcMirror.Root
            Workspace = $mozcMirror.Workspace
            OriginalWorkspace = $originalMozcWorkspace
            Commit = $mozcInfo.Commit
            BazelVersion = $mozcInfo.BazelVersion
            BazeliskConfig = (Join-Path $mozcMirror.Workspace '.bazeliskrc')
            Prepared = $false
            Reused = $mozcMirror.Reused
        }
    }
}
if ($BuildSystem -ieq 'Bazel' -and $sourceRootWasDefault) {
    # The upstream TIP source is part of the pinned Mozc workspace. This is
    # the source inspected when a caller selects a Windows TIP target.
    $SourceRoot = Join-Path $mozcInfo.Workspace 'win32\tip'
    $SourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)
}
if ($MozcValidationOnly) {
    if ($BuildSystem -ine 'Bazel') {
        throw '-MozcValidationOnly is a pinned-Mozc Bazel diagnostic and requires -BuildSystem Bazel; it cannot stage a KanaAI DLL.'
    }
    if ($RunWindowsSmokeTests -or $PromoteNativeBeta) {
        throw 'Mozc validation cannot be promoted or used as a KanaAI native-beta smoke test. Run the KanaAI host suite against the KanaAI TIP instead.'
    }
    if ([string]::IsNullOrWhiteSpace($BazelTarget)) {
        $BazelTarget = [string](Get-TsfProperty -Object (Get-TsfProperty -Object $config -Name 'firstTarget') -Name 'bazel')
    }
    if ($TipDllName -eq 'KanaAI.TsfTip') {
        $TipDllName = 'mozc_tip64'
    }
}

if ($PlanOnly) {
    [pscustomobject]@{
        Mode = 'plan-only'
        Platform = 'windows'
        Architecture = 'x64'
        Target = 'x86_64-pc-windows-msvc'
        BuildSystem = $BuildSystem
        NativeBeta = $false
        WindowsSmokeTests = 'not-run'
        Claim = 'not-a-native-beta'
        SourceRoot = $SourceRoot
        BuildRoot = $build
        OutputDirectory = $OutputDirectory
        RequiredExports = @($requiredExports)
        Note = 'PlanOnly does not inspect a PE, run Windows, or create a release artifact.'
    }
    return
}

$preflightErrors = @()
$sourceInfo = $null
try {
    $sourceFilesForPreflight = @($SourceFile)
    if ($sourceFilesForPreflight.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($ExportDefinition)) {
        $sourceFilesForPreflight += $ExportDefinition
    }
    $sourceInfo = Get-TsfSourceSliceInfo -SourceRoot $SourceRoot -SourceFile $sourceFilesForPreflight -RequiredMarkers @(Get-TsfArrayProperty -Object (Get-TsfProperty -Object $config -Name 'sourceContract') -Name 'requiredMarkers')
    Assert-TsfFirstX64SourceSet -SourceInfo $sourceInfo -Config $config
}
catch {
    $preflightErrors += $_.Exception.Message
}
$windowsHost = $null
try {
    $windowsHost = Get-TsfWindowsHost
}
catch {
    $preflightErrors += $_.Exception.Message
}
if ($preflightErrors.Count -gt 0) {
    throw ("TSF preflight failed. No DLL or native beta was produced:`n - " + ($preflightErrors -join "`n - "))
}

$outputSafe = Assert-TsfSafeOutputPath -Path $OutputDirectory -RepositoryRoot $repository -SourceRoot $SourceRoot -BuildRoot $build
[void](Assert-TsfLocalBuildPath -Path $cacheRoot)
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
$cacheKey = (($CMakeTarget -replace '[^A-Za-z0-9_.-]', '_') + '-' + $Configuration.ToLowerInvariant())
$cmakeBuildDirectory = Join-Path $cacheRoot ('cmake-' + $cacheKey)
$bazelOutputUserRoot = Resolve-TsfCachePath -Root $cacheRoot -Value $BazelOutputUserRoot -DefaultName 'bazel-output-user-root'
$bazelDiskCache = Resolve-TsfCachePath -Root $cacheRoot -Value $BazelDiskCache -DefaultName 'bazel-disk-cache'
$bazelRepositoryCache = Resolve-TsfCachePath -Root $cacheRoot -Value $BazelRepositoryCache -DefaultName 'bazel-repository-cache'
foreach ($cachePath in @($cmakeBuildDirectory, $bazelOutputUserRoot, $bazelDiskCache, $bazelRepositoryCache)) {
    [void](Assert-TsfLocalBuildPath -Path $cachePath)
}
if ($SkipBuild -and [string]::IsNullOrWhiteSpace($PrebuiltDll)) {
    throw '-SkipBuild requires -PrebuiltDll. The harness will not silently reuse a console seam or an arbitrary DLL.'
}
if (-not $SkipBuild -and -not [string]::IsNullOrWhiteSpace($PrebuiltDll)) {
    throw 'Use either -SkipBuild -PrebuiltDll or a normal CMake/Bazel build, not both.'
}
if ($RunWindowsSmokeTests -and [string]::IsNullOrWhiteSpace($SmokeTestCommand) -and [string]::IsNullOrWhiteSpace($TestHostPath)) {
    # The built-in runner intentionally fails without a real host. Make the
    # prerequisite visible before spending time compiling a DLL.
    throw 'Windows TSF smoke tests require -TestHostPath (a real 64-bit Windows TSF host test). PE/load/export checks alone are not a native TIP test.'
}

$workRoot = Join-Path $outputSafe ('.work-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$buildDirectory = if ($BuildSystem -ieq 'CMake') { $cmakeBuildDirectory } else { $bazelOutputUserRoot }
$smokeResultPath = Join-Path $workRoot 'windows-smoke-result.json'
$builtDll = $null
$smokeResult = [pscustomobject]@{
    status = 'not-run'
    tests = @()
    note = 'Windows smoke tests were not requested; this artifact must not be called a native beta.'
}
$toolchain = $null
try {
    Write-TsfLog 'Checking the pinned Windows x64 MSVC/TSF toolchain.'
    $toolchain = Assert-TsfToolchain -Config $config -BuildSystem $BuildSystem -AllowDrift:$AllowToolchainDrift -WindowsWorkspaceRoot $WindowsWorkspaceRoot -VsDevCmdPath $VsDevCmdPath -RequireBazelSymlinks:$RequireBazelSymlinks

    if ($SkipBuild) {
        $builtDll = [System.IO.Path]::GetFullPath($PrebuiltDll)
        if (-not (Test-Path -LiteralPath $builtDll -PathType Leaf)) {
            throw "Prebuilt TIP DLL does not exist: $builtDll"
        }
        $buildDirectory = Split-Path -Parent $builtDll
    }
    elseif ($BuildSystem -ieq 'CMake') {
        Write-TsfLog ("Configuring the pinned Visual Studio 17 2022 x64/v143 CMake target (incremental cache: {0})." -f $cmakeBuildDirectory)
        $builtDll = Invoke-TsfCMakeBuild -RepositoryRoot $repository -CMakeSource $CMakeSource -BuildDirectory $buildDirectory -SourceRoot $SourceRoot -SourceFile $sourceInfo.Files -Configuration $Configuration -TipDllName $TipDllName -CMakeTarget $CMakeTarget -ExportDefinition $ExportDefinition -Config $config
    }
    else {
        Write-TsfLog ("Building the first pinned Bazel x64 TIP target (disk/repository caches under {0})." -f $cacheRoot)
        $builtDll = Invoke-TsfBazelBuild -RepositoryRoot $repository -BazelWorkspace $BazelWorkspace -BazelTarget $BazelTarget -TipDllName $TipDllName -Configuration $Configuration -Config $config -BuildDirectory $buildDirectory -OutputUserRoot $bazelOutputUserRoot -DiskCache $bazelDiskCache -RepositoryCache $bazelRepositoryCache -PythonPath ([string]$toolchain.python.command) -ActionPath ([string]$toolchain.bazel.actionPath) -SymlinkSupport ([bool]$toolchain.bazelSymlinkSupport)
    }

    Write-TsfLog 'Validating PE32+ x64 architecture and required DLL exports.'
    [void](Assert-TsfX64PeImage -Path $builtDll -RequireDll)
    $exportCheck = Test-TsfDllExports -Path $builtDll -RequiredExports $requiredExports
    if ($MozcValidationOnly) {
        Write-TsfLog 'Pinned Mozc TIP validation passed PE/export gates; no KanaAI artifact is staged and no native beta is claimed.'
        return [pscustomobject]@{
            Status = 'mozc-tip-validation-only'
            NativeBeta = $false
            WindowsSmokeTests = 'not-run'
            Claim = 'not-a-kanaai-native-beta'
            OutputDirectory = $null
            Dll = $builtDll
            Manifest = $null
            RequiredExports = @($exportCheck.RequiredExports)
            BuildDirectory = $buildDirectory
            MozcCommit = $mozcInfo.Commit
        }
    }
    $smokePlan = Get-TsfSmokePlan -BuildRoot $build

    if ($RunWindowsSmokeTests) {
        Write-TsfLog 'Running the required Windows TSF smoke-test host; static PE checks alone are insufficient.'
        $smokeResult = Invoke-TsfWindowsSmokeTests -RepositoryRoot $repository -BuildRoot $build -DllPath $builtDll -ResultPath $smokeResultPath -SmokeTestCommand $SmokeTestCommand -TestHostPath $TestHostPath -RequiredTestIds $smokePlan.RequiredTestIds
    }
    else {
        Write-TsfLog 'Windows smoke tests were not requested; staging will be explicitly unverified.'
    }

    $artifact = Stage-TsfArtifact -OutputDirectory $outputSafe -BuildRoot $build -RepositoryRoot $repository -DllPath $builtDll -TipDllName $TipDllName -Config $config -Toolchain $toolchain -MozcInfo $mozcInfo -SourceInfo $sourceInfo -SmokeResult $smokeResult -BuildDirectory $buildDirectory -CacheRoot $cacheRoot -BazelTarget $BazelTarget -BazelWorkspace $BazelWorkspace -ExportDefinition $ExportDefinition -IncludeSymbols:$IncludeSymbols -Promote:$PromoteNativeBeta -Force:$Force
    [pscustomobject]@{
        Status = $artifact.Status
        NativeBeta = $artifact.NativeBeta
        WindowsSmokeTests = $artifact.WindowsSmokeStatus
        Claim = if ($artifact.NativeBeta) { 'native-beta-only-after-Windows-smoke-tests' } else { 'not-a-native-beta' }
        OutputDirectory = $artifact.OutputDirectory
        Dll = $artifact.Dll
        Manifest = $artifact.Manifest
        RequiredExports = @($exportCheck.RequiredExports)
        BuildDirectory = $buildDirectory
    }
}
finally {
    if ($KeepBuild) {
        Write-TsfLog "Keeping ephemeral test workspace: $workRoot"
    }
    elseif (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-TsfLog ("Retaining incremental build caches: {0}" -f $cacheRoot)
}
