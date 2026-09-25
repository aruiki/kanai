# Shared, Windows-compatible helpers for the KanaAI TSF build harness.
# This file contains no build or registration side effects when dot-sourced.
# Keep the parser PS 5.1-compatible: the supported developer command prompt may
# be Windows PowerShell rather than PowerShell 7.

Set-StrictMode -Version Latest

$script:TsfPeMachineAmd64 = [uint16]0x8664
$script:TsfPe32PlusMagic = [uint16]0x20b
$script:TsfDllCharacteristic = [uint16]0x2000
$script:TsfDefaultRequiredExports = @(
    'DllGetClassObject'
    'DllCanUnloadNow'
)

function Get-TsfProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
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

function Get-TsfRepositoryRoot {
    param([string]$Value = '')

    if ([string]::IsNullOrWhiteSpace($Value)) {
        # This file lives at <repo>/platform/windows-tsf/build.
        return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    }
    return [System.IO.Path]::GetFullPath($Value)
}

function Get-TsfBuildRoot {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$Value = ''
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'platform\windows-tsf\build'))
    }
    return [System.IO.Path]::GetFullPath($Value)
}

function Get-TsfBuildCacheRoot {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$Value = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }

    # Bazel response files are resolved against a deeply nested execroot. Keeping
    # the default cache outside a long (and possibly non-ASCII) repository path
    # keeps MSVC response-file paths below the legacy Windows path limit.
    $localAppData = [string][System.Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = Get-TsfWindowsLocalTempRoot
    }
    return [System.IO.Path]::GetFullPath((Join-Path $localAppData 'KanaAI\tsf-build-cache'))
}

function Get-TsfMozcOverlayFingerprint {
    param(
        [string]$RepositoryRoot = '',
        [string]$OverlayRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $RepositoryRoot = Get-TsfRepositoryRoot
    }
    $RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($OverlayRoot)) {
        $OverlayRoot = Join-Path $repositoryRoot 'platform\windows-tsf\tsf\host_overlay'
    }
    $OverlayRoot = [System.IO.Path]::GetFullPath($OverlayRoot)
    $records = @(
        'overlay|' + (Get-TsfTreeFingerprint -Root $OverlayRoot)
    )
    $patchRoot = Join-Path $repositoryRoot 'platform\windows-tsf\tsf\patches'
    foreach ($patchName in @(
        '0001-install-kanai-supplemental-model.patch',
        '0002-kanai-tsf-identity.patch',
        '0003-session-generation-binding.patch',
        '0004-windows-python-toolchain.patch',
        '0005-windows-runtime-identity.patch'
    )) {
        $patchPath = Join-Path $patchRoot $patchName
        if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
            throw "Required KanaAI Mozc patch is missing: $patchPath"
        }
        $records += ($patchName + '|' + (Get-TsfSha256 -Path $patchPath))
    }
    return ($records -join "`n")
}

function Get-TsfCommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw "Required Windows command is not on PATH: $Name"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$command.Path)) {
        return [string]$command.Path
    }
    return [string]$command.Source
}

function Get-TsfToolVersion {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @('--version')
    )

    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0 -and $null -ne $output) {
            return (([string]($output | Select-Object -First 1)).Trim())
        }
    }
    catch {
        # Version metadata is best effort. The caller still checks the command.
    }
    return 'unavailable'
}

function ConvertTo-TsfCmdArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value -notmatch '[\s"&|<>^%]') {
        return $Value
    }
    # The harness passes ordinary paths and flags. Quoting embedded double
    # quotes is sufficient here; backslashes are retained for cmd's parser.
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-TsfChecked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "Build working directory does not exist: $WorkingDirectory"
    }

    # Bazel and MSBuild reject a UNC working directory when launched from a
    # WSL2 process. `pushd` gives cmd a temporary mapped drive for the whole
    # child command, so the tool sees a normal local Windows path. This branch
    # is also useful for CMake when the repository is opened from \\wsl$.
    if ($WorkingDirectory -like '\\*') {
        $commandParts = @(
            'pushd'
            (ConvertTo-TsfCmdArgument -Value $WorkingDirectory)
            '&&'
            (ConvertTo-TsfCmdArgument -Value $FilePath)
        )
        foreach ($argument in @($Arguments)) {
            $commandParts += (ConvertTo-TsfCmdArgument -Value ([string]$argument))
        }
        $commandLine = $commandParts -join ' '
        & $env:ComSpec /d /s /c $commandLine | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
        }
        return
    }

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $FilePath @Arguments | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Assert-TsfSafeOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$BuildRoot
    )

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]'\/')
    $source = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]'\/')
    $build = [System.IO.Path]::GetFullPath($BuildRoot).TrimEnd([char[]]'\/')
    if ($full -ieq $root) {
        throw "Refusing to use the repository root as TSF output: $full"
    }

    # A dedicated output below the repository (the default
    # windows-beta/tsf) is valid. Source, build, third_party, and Cargo output
    # are not: reject both descendants that could be overwritten and ancestors
    # that could remove the protected tree during forced staging.
    $protected = @(
        $source,
        $build,
        ([System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'third_party')).TrimEnd([char[]]'\/')),
        ([System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'target')).TrimEnd([char[]]'\/'))
    )
    $fullPrefix = $full + [System.IO.Path]::DirectorySeparatorChar
    foreach ($item in $protected) {
        $itemPrefix = $item + [System.IO.Path]::DirectorySeparatorChar
        if ($full -ieq $item -or
            $full.StartsWith($itemPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $item.StartsWith($fullPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to use a protected source/build directory as TSF output: $full"
        }
    }
    return $full
}

function Get-TsfWindowsHost {
    param()

    $isWindows = $false
    $isWindowsVariable = Get-Variable -Name 'IsWindows' -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $isWindowsVariable) {
        $isWindows = [bool]$isWindowsVariable.Value
    }
    else {
        $isWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    }
    if (-not $isWindows) {
        throw 'This is a native Windows TSF harness and must run on Windows. A PE file inspected on Linux/WSL is not a Windows runtime test and cannot produce a native beta.'
    }
    if (-not [System.Environment]::Is64BitOperatingSystem -or
        -not [System.Environment]::Is64BitProcess) {
        throw 'The TSF harness requires a 64-bit Windows host and a 64-bit PowerShell process. Start an x64 Developer PowerShell (VsDevCmd.bat -arch=x64 -host_arch=x64).'
    }

    $targetArch = [string][System.Environment]::GetEnvironmentVariable('VSCMD_ARG_TGT_ARCH')
    if (-not [string]::IsNullOrWhiteSpace($targetArch) -and $targetArch -ine 'x64') {
        throw "The MSVC target architecture is '$targetArch', not x64. Re-open the x64 Developer PowerShell before building."
    }

    return [pscustomobject]@{
        OS = [System.Environment]::OSVersion.VersionString
        Is64BitOperatingSystem = [System.Environment]::Is64BitOperatingSystem
        Is64BitProcess = [System.Environment]::Is64BitProcess
        TargetArch = 'x64'
    }
}

function Initialize-TsfMSVCEnvironment {
    param([string]$VsDevCmdPath = '')

    $cl = Get-Command -Name 'cl.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $cl) {
        return
    }

    $devCmd = $VsDevCmdPath
    if (-not [string]::IsNullOrWhiteSpace($devCmd)) {
        $devCmd = [System.IO.Path]::GetFullPath($devCmd)
        if (-not (Test-Path -LiteralPath $devCmd -PathType Leaf)) {
            throw "The supplied VsDevCmd.bat does not exist: $devCmd"
        }
    }

    if ([string]::IsNullOrWhiteSpace($devCmd)) {
        $vswhereCandidates = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe')
            (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }

        $vswhere = $null
        foreach ($candidate in $vswhereCandidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $vswhere = $candidate
                break
            }
        }
        if ($null -eq $vswhere) {
            throw 'Visual Studio C++ tools are not initialized. Install the x64 MSVC v143 toolset and Windows SDK, then run VsDevCmd.bat -arch=x64 -host_arch=x64 (or open the x64 Developer PowerShell).'
        }

        $vsPath = ((& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null) | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$vsPath)) {
            throw "vswhere could not locate a Visual Studio installation with the x64 C++ tools: $vswhere"
        }
        $devCmd = Join-Path ([string]$vsPath).Trim() 'Common7\Tools\VsDevCmd.bat'
    }
    if (-not (Test-Path -LiteralPath $devCmd -PathType Leaf)) {
        throw "VsDevCmd.bat is missing: $devCmd"
    }

    # VsDevCmd is a batch file. Start cmd from a local directory because a
    # process launched from a WSL UNC working directory otherwise inherits an
    # unsupported UNC current directory.
    $commandLine = 'cd /d C:\Windows && call "' + $devCmd + '" -arch=x64 -host_arch=x64 >nul && set'
    try {
        Push-Location -LiteralPath 'C:\Windows'
        try {
            $environmentLines = & $env:ComSpec /d /s /c $commandLine 2>$null
        }
        finally {
            Pop-Location
        }
    }
    catch {
        throw "Could not initialize the MSVC environment with VsDevCmd.bat: $($_.Exception.Message)"
    }
    foreach ($line in @($environmentLines)) {
        if ([string]$line -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
    if ($null -eq (Get-Command -Name 'cl.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "VsDevCmd.bat completed but cl.exe is not available. Install the x64 MSVC toolset and retry: $devCmd"
    }
}

function Get-TsfWindowsSdk {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $roots = @()
    $configuredRoot = [string][System.Environment]::GetEnvironmentVariable('WindowsSdkDir')
    if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) {
        $roots += $configuredRoot.TrimEnd('\')
    }
    $programFilesX86 = [string][System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $roots += (Join-Path $programFilesX86 'Windows Kits\10')
    }
    $programFiles = [string][System.Environment]::GetEnvironmentVariable('ProgramFiles')
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $roots += (Join-Path $programFiles 'Windows Kits\10')
    }

    foreach ($root in @($roots | Select-Object -Unique)) {
        $includeRoot = Join-Path $root (Join-Path 'Include' $ExpectedVersion)
        $libRoot = Join-Path $root (Join-Path 'Lib' $ExpectedVersion)
        if ((Test-Path -LiteralPath $includeRoot -PathType Container) -and
            (Test-Path -LiteralPath $libRoot -PathType Container)) {
            return [pscustomobject]@{
                Root = $root
                Version = $ExpectedVersion
                Include = $includeRoot
                Lib = $libRoot
            }
        }
    }
    throw "The pinned Windows SDK $ExpectedVersion is not installed. Install the exact SDK before building; no unpinned SDK fallback is allowed."
}

function Get-TsfFileWithName {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }
    $file = Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter $Name -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $file) {
        return $null
    }
    return $file.FullName
}

function Get-TsfSourceSliceInfo {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [string[]]$SourceFile = @(),
        [string[]]$RequiredMarkers = @(
            'msctf.h',
            'ITfThreadMgr',
            'ITfTextInputProcessor',
            'DllGetClassObject',
            'DllCanUnloadNow'
        )
    )

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "TSF source root does not exist: $SourceRoot. Provide the source slices with -SourceRoot; the existing Windows shell seam is not a TSF TIP."
    }

    $contractPath = Join-Path $SourceRoot 'shell\bridge-contract.json'
    if (Test-Path -LiteralPath $contractPath -PathType Leaf) {
        try {
            $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
            $status = [string](Get-TsfProperty -Object $contract -Name 'status')
            if ($status -ieq 'unimplemented') {
                throw 'The checked-in Windows shell contract is explicitly unimplemented (status=unimplemented). It is a console/workbench seam, not a TSF TIP source slice; no DLL or native beta will be staged.'
            }
        }
        catch {
            if ($_.Exception.Message -match 'explicitly unimplemented') {
                throw
            }
            throw "Could not validate the TSF source contract: $contractPath`: $($_.Exception.Message)"
        }
    }

    $files = @()
    if ($null -ne $SourceFile -and @($SourceFile).Count -gt 0) {
        foreach ($candidate in @($SourceFile)) {
            $fullCandidate = $candidate
            if (-not [System.IO.Path]::IsPathRooted($fullCandidate)) {
                $fullCandidate = Join-Path $SourceRoot $fullCandidate
            }
            $fullCandidate = [System.IO.Path]::GetFullPath($fullCandidate)
            if (-not (Test-Path -LiteralPath $fullCandidate -PathType Leaf)) {
                throw "TSF source file does not exist: $fullCandidate"
            }
            $files += (Get-Item -LiteralPath $fullCandidate -Force)
        }
    }
    else {
        $files = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force -File | Where-Object {
            $_.Extension.ToLowerInvariant() -in @('.c', '.cc', '.cpp', '.cxx', '.h', '.hpp', '.inl', '.def', '.rc') -and
            $_.FullName -notmatch '[\\/](build|out|cmake-build|bazel-bin|bazel-out|tests)[\\/]'
        })
    }
    if ($files.Count -eq 0) {
        throw "No TSF C/C++ source slices were found under $SourceRoot. The harness refuses to turn the existing non-TSF shell seam into a DLL."
    }

    $sourceText = ''
    foreach ($file in $files) {
        try {
            $sourceText += [System.IO.File]::ReadAllText($file.FullName) + [Environment]::NewLine
        }
        catch {
            throw "Could not read TSF source slice $($file.FullName): $($_.Exception.Message)"
        }
    }
    $missing = @()
    foreach ($marker in @($RequiredMarkers)) {
        if ($sourceText.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $missing += $marker
        }
    }
    if ($missing.Count -gt 0) {
        throw ("The supplied source slices do not look like a complete Windows TSF TIP. Missing marker(s): " + ($missing -join ', ') + ". Refusing to build a non-TSF console executable or claim a native beta.")
    }

    return [pscustomobject]@{
        Root = [System.IO.Path]::GetFullPath($SourceRoot)
        Files = @($files | ForEach-Object { $_.FullName })
        RequiredMarkers = @($RequiredMarkers)
    }
}

function Read-TsfExact {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Count
    )

    if ($Offset -lt 0 -or $Count -lt 0 -or $Offset -gt $Stream.Length - $Count) {
        throw "PE image is truncated at offset $Offset (requested $Count bytes)."
    }
    $Stream.Position = $Offset
    $buffer = New-Object byte[] $Count
    $readTotal = 0
    while ($readTotal -lt $Count) {
        $read = $Stream.Read($buffer, $readTotal, $Count - $readTotal)
        if ($read -le 0) {
            throw "PE image ended before $Count bytes could be read at offset $Offset."
        }
        $readTotal += $read
    }
    return ,$buffer
}

function Get-TsfUInt32 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset
    )
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Convert-TsfRvaToOffset {
    param(
        [Parameter(Mandatory = $true)]$Image,
        [Parameter(Mandatory = $true)][uint32]$Rva
    )

    if ($Rva -lt $Image.SizeOfHeaders) {
        return [int]$Rva
    }
    foreach ($section in @($Image.Sections)) {
        $span = [Math]::Max([uint32]$section.VirtualSize, [uint32]$section.RawSize)
        if ($Rva -ge [uint32]$section.VirtualAddress -and
            $Rva -lt ([uint32]$section.VirtualAddress + $span)) {
            $delta = $Rva - [uint32]$section.VirtualAddress
            if ($delta -ge [uint32]$section.RawSize) {
                throw "PE export RVA points into uninitialized section data: 0x{0:X8}" -f $Rva
            }
            return [int]([uint32]$section.RawPointer + $delta)
        }
    }
    throw "PE RVA cannot be mapped to a file offset: 0x{0:X8}" -f $Rva
}

function Get-TsfPeImageInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireDll
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "PE image is missing: $Path"
    }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $mz = [byte[]](Read-TsfExact -Stream $stream -Offset 0 -Count 64)
        if ($mz[0] -ne 0x4d -or $mz[1] -ne 0x5a) {
            throw "Image is not a Windows PE (MZ signature missing): $Path"
        }
        $peOffset = [BitConverter]::ToInt32($mz, 0x3c)
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 24)) {
            throw "PE header offset is invalid: $Path"
        }
        $coff = [byte[]](Read-TsfExact -Stream $stream -Offset $peOffset -Count 24)
        if ($coff[0] -ne 0x50 -or $coff[1] -ne 0x45 -or $coff[2] -ne 0 -or $coff[3] -ne 0) {
            throw "PE signature is missing: $Path"
        }
        $machine = [BitConverter]::ToUInt16($coff, 4)
        $sectionCount = [BitConverter]::ToUInt16($coff, 6)
        $optionalSize = [BitConverter]::ToUInt16($coff, 20)
        # IMAGE_FILE_HEADER characteristics is at offset 22, immediately
        # after SizeOfOptionalHeader (offset 20).
        $characteristics = [BitConverter]::ToUInt16($coff, 22)
        $optionalOffset = $peOffset + 24
        if ($optionalSize -lt 2) {
            throw "PE optional header is truncated: $Path"
        }
        $optional = [byte[]](Read-TsfExact -Stream $stream -Offset $optionalOffset -Count $optionalSize)
        $optionalMagic = [BitConverter]::ToUInt16($optional, 0)
        if ($optionalSize -lt 64) {
            throw "PE optional header does not contain SizeOfHeaders: $Path"
        }
        $sizeOfHeaders = [BitConverter]::ToUInt32($optional, 60)
        $exportRva = [uint32]0
        $exportSize = [uint32]0
        if ($optionalSize -ge 120) {
            $exportRva = [BitConverter]::ToUInt32($optional, 112)
            $exportSize = [BitConverter]::ToUInt32($optional, 116)
        }

        $sectionTableOffset = $optionalOffset + $optionalSize
        $sectionBytes = [byte[]](Read-TsfExact -Stream $stream -Offset $sectionTableOffset -Count ($sectionCount * 40))
        $sections = @()
        for ($index = 0; $index -lt $sectionCount; $index++) {
            $base = $index * 40
            $sections += [pscustomobject]@{
                Name = ([System.Text.Encoding]::ASCII.GetString($sectionBytes, $base, 8)).Trim([char]0)
                VirtualSize = [BitConverter]::ToUInt32($sectionBytes, $base + 8)
                VirtualAddress = [BitConverter]::ToUInt32($sectionBytes, $base + 12)
                RawSize = [BitConverter]::ToUInt32($sectionBytes, $base + 16)
                RawPointer = [BitConverter]::ToUInt32($sectionBytes, $base + 20)
            }
        }

        $image = [pscustomobject]@{
            Path = [System.IO.Path]::GetFullPath($Path)
            MZ = $true
            PEOffset = $peOffset
            Machine = $machine
            MachineName = ('0x{0:X4}' -f $machine)
            SectionCount = $sectionCount
            OptionalHeaderOffset = $optionalOffset
            OptionalHeaderSize = $optionalSize
            OptionalMagic = $optionalMagic
            OptionalMagicHex = ('0x{0:X4}' -f $optionalMagic)
            Characteristics = $characteristics
            IsDll = (($characteristics -band $script:TsfDllCharacteristic) -ne 0)
            SizeOfHeaders = $sizeOfHeaders
            ExportRva = $exportRva
            ExportSize = $exportSize
            Sections = @($sections)
        }
        if ($RequireDll -and -not $image.IsDll) {
            throw "PE image is not marked as a DLL (IMAGE_FILE_DLL is missing): $Path"
        }
        return $image
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-TsfX64PeImage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireDll
    )

    $image = Get-TsfPeImageInfo -Path $Path -RequireDll:$RequireDll
    if ($image.Machine -ne $script:TsfPeMachineAmd64) {
        throw ("PE image is not Windows x64 (machine {0}, expected 0x8664): {1}" -f $image.MachineName, $Path)
    }
    if ($image.OptionalMagic -ne $script:TsfPe32PlusMagic) {
        throw ("PE image is not PE32+ (optional magic {0}, expected 0x20b): {1}" -f $image.OptionalMagicHex, $Path)
    }
    return $image
}

function Get-TsfPeExportNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    $image = Get-TsfPeImageInfo -Path $Path -RequireDll
    if ($image.ExportRva -eq 0 -or $image.ExportSize -eq 0) {
        return @()
    }
    $exportOffset = Convert-TsfRvaToOffset -Image $image -Rva $image.ExportRva
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $directory = [byte[]](Read-TsfExact -Stream $stream -Offset $exportOffset -Count 40)
        $nameCount = [BitConverter]::ToUInt32($directory, 24)
        $namesRva = [BitConverter]::ToUInt32($directory, 32)
        $ordinalsRva = [BitConverter]::ToUInt32($directory, 36)
        if ($nameCount -gt 65535) {
            throw "PE export name count is unreasonable ($nameCount): $Path"
        }
        $namesOffset = Convert-TsfRvaToOffset -Image $image -Rva $namesRva
        $ordinalsOffset = Convert-TsfRvaToOffset -Image $image -Rva $ordinalsRva
        $names = @()
        for ($index = 0; $index -lt $nameCount; $index++) {
            $namePointerBytes = [byte[]](Read-TsfExact -Stream $stream -Offset ($namesOffset + ($index * 4)) -Count 4)
            $nameRva = [BitConverter]::ToUInt32($namePointerBytes, 0)
            $nameOffset = Convert-TsfRvaToOffset -Image $image -Rva $nameRva
            $nameBytes = New-Object byte[] 512
            $stream.Position = $nameOffset
            $length = 0
            while ($length -lt $nameBytes.Length) {
                $value = $stream.ReadByte()
                if ($value -lt 1) {
                    break
                }
                $nameBytes[$length] = [byte]$value
                $length++
            }
            if ($length -eq 0) {
                throw "PE export contains an empty name: $Path"
            }
            $names += [System.Text.Encoding]::ASCII.GetString($nameBytes, 0, $length)
            # Reading the ordinal table here catches a malformed table even
            # though the name table is the public export view used by callers.
            [void](Read-TsfExact -Stream $stream -Offset ($ordinalsOffset + ($index * 2)) -Count 2)
        }
        return $names
    }
    finally {
        $stream.Dispose()
    }
}

function Test-TsfDllExports {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$RequiredExports = $script:TsfDefaultRequiredExports,
        [switch]$SkipDumpbin
    )

    [void](Assert-TsfX64PeImage -Path $Path -RequireDll)
    $exportNames = @(Get-TsfPeExportNames -Path $Path)
    $missing = @($RequiredExports | Where-Object { $exportNames -cnotcontains $_ })
    if ($missing.Count -gt 0) {
        throw ("DLL is missing required TSF export(s): {0}. Found: {1}" -f ($missing -join ', '), ($exportNames -join ', '))
    }

    $dumpbinText = ''
    if (-not $SkipDumpbin) {
        $dumpbin = Get-TsfCommandPath -Name 'dumpbin.exe'
        $dumpbinOutput = & $dumpbin '/nologo' '/exports' $Path 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "dumpbin /exports failed for $Path (exit $LASTEXITCODE)."
        }
        $dumpbinText = ([string]($dumpbinOutput -join [Environment]::NewLine))
        foreach ($export in $RequiredExports) {
            if ($dumpbinText -notmatch ('(?m)\b' + [regex]::Escape($export) + '\b')) {
                throw "dumpbin did not report required DLL export '$export': $Path"
            }
        }
    }

    return [pscustomobject]@{
        Path = [System.IO.Path]::GetFullPath($Path)
        RequiredExports = @($RequiredExports)
        ExportNames = @($exportNames)
        DumpbinVerified = (-not $SkipDumpbin)
    }
}

function Get-TsfWindowsLocalTempRoot {
    param([string]$Value = '')

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    $temp = [string][System.Environment]::GetEnvironmentVariable('TEMP')
    if ([string]::IsNullOrWhiteSpace($temp)) {
        $temp = [string][System.Environment]::GetEnvironmentVariable('TMP')
    }
    if ([string]::IsNullOrWhiteSpace($temp)) {
        $temp = 'C:\Windows\Temp'
    }
    return $temp
}

function Mirror-TsfMozcWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Commit,
        [string]$DestinationRoot = ''
    )

    $localRoot = Get-TsfWindowsLocalTempRoot -Value $DestinationRoot
    $destination = Join-Path $localRoot ('KanaAI-tsf-mozc-' + $Commit)
    $marker = Join-Path $destination '.kanai-pinned-commit'
    if ((Test-Path -LiteralPath (Join-Path $destination 'MODULE.bazel') -PathType Leaf) -and
        (Test-Path -LiteralPath $marker -PathType Leaf) -and
        ([System.IO.File]::ReadAllText($marker).Trim() -eq $Commit)) {
        return [pscustomobject]@{
            Root = $destination
            Workspace = $destination
            Commit = $Commit
            Reused = $true
        }
    }
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    $robocopy = Get-Command -Name 'robocopy.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $robocopy) {
        throw 'WSL interop requires a Windows-local Bazel workspace, but robocopy.exe was not found. Use a native Windows checkout or pass a local -BazelWorkspace.'
    }
    $arguments = @(
        $Workspace,
        $destination,
        '/E',
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/R:1',
        '/W:1',
        '/XJ',
        '/XD', '.git', 'bazel-bin', 'bazel-out', 'bazel-src', 'bazel-testlogs',
        '/XF', '.git'
    )
    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        Push-Location -LiteralPath 'C:\Windows'
        try {
            & $robocopy.Source @arguments
            $copyExitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
    }
    if ($copyExitCode -gt 7) {
        throw "Could not mirror the pinned Mozc workspace to a Windows-local path (robocopy exit $copyExitCode): $destination"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $destination 'MODULE.bazel') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $destination '.bazeliskrc') -PathType Leaf)) {
        throw "The Windows-local Mozc mirror is incomplete: $destination"
    }
    Write-TsfUtf8File -Path $marker -Content ($Commit + [Environment]::NewLine)
    return [pscustomobject]@{
        Root = $destination
        Workspace = $destination
        Commit = $Commit
        Reused = $false
    }
}

function Assert-TsfBazelSymlinkSupport {
    param([string]$ProbeRoot = '')

    $root = Get-TsfWindowsLocalTempRoot -Value $ProbeRoot
    $probeDirectory = Join-Path $root ('KanaAI-tsf-symlink-probe-' + [guid]::NewGuid().ToString('N'))
    $target = Join-Path $probeDirectory 'target.txt'
    $link = Join-Path $probeDirectory 'link.txt'
    New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
    try {
        [System.IO.File]::WriteAllText($target, 'kanai')
        [void](New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop)
        if (-not (Test-Path -LiteralPath $link -PathType Leaf)) {
            throw 'The symbolic-link probe did not create a readable link.'
        }
    }
    catch {
        throw ('Bazel on this Windows host cannot create symbolic links. The harness will try the pinned no-runfiles fallback; no Windows security policy is changed. If the fallback also fails, use a build environment with symlink support: ' + $_.Exception.Message)
    }
    finally {
        Remove-Item -LiteralPath $probeDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Get-TsfPinnedMozcInfo {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedBazelVersion
    )

    $mozcRoot = Join-Path $RepositoryRoot 'third_party\mozc'
    $workspace = Join-Path $mozcRoot 'src'
    if (-not (Test-Path -LiteralPath $mozcRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $workspace -PathType Container)) {
        throw "The pinned Mozc checkout is missing: $mozcRoot. Initialize the third_party/mozc submodule before building; an unrelated or floating Mozc checkout is not accepted."
    }
    $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) {
        throw 'Git is required to verify the pinned third_party/mozc gitlink before a TSF build.'
    }
    $gitPath = [string]$git.Path
    $treeOutput = & $gitPath -c 'safe.directory=*' -C $RepositoryRoot ls-tree HEAD -- 'third_party/mozc' 2>$null
    $treeExitCode = $LASTEXITCODE
    $treeLine = @($treeOutput | Select-Object -First 1)
    if ($treeExitCode -ne 0 -or $treeLine.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$treeLine[0]) -or
        [string]$treeLine[0] -notmatch ('\b' + [regex]::Escape($ExpectedCommit) + '\b')) {
        throw "The repository gitlink for third_party/mozc is not the pinned commit $ExpectedCommit. Refusing a floating or unrelated Mozc source tree."
    }
    $commitOutput = & $gitPath -c 'safe.directory=*' -C $mozcRoot rev-parse HEAD 2>$null
    $commitExitCode = $LASTEXITCODE
    $actualCommit = @($commitOutput | Select-Object -First 1)
    $actualCommitText = if ($actualCommit.Count -gt 0) { ([string]$actualCommit[0]).Trim() } else { '' }
    if ($commitExitCode -ne 0 -or $actualCommitText -ine $ExpectedCommit) {
        throw ("The checked-out third_party/mozc commit is '{0}', expected '{1}'. Initialize the exact pinned submodule before building." -f $actualCommitText, $ExpectedCommit)
    }

    $bazeliskConfig = Join-Path $workspace '.bazeliskrc'
    if (-not (Test-Path -LiteralPath $bazeliskConfig -PathType Leaf)) {
        throw "The pinned Mozc Bazelisk configuration is missing: $bazeliskConfig"
    }
    $bazelText = Get-Content -LiteralPath $bazeliskConfig -Raw
    $bazelMatch = [regex]::Match($bazelText, '(?m)^\s*USE_BAZEL_VERSION\s*=\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$')
    if (-not $bazelMatch.Success -or $bazelMatch.Groups[1].Value -ne $ExpectedBazelVersion) {
        throw "The pinned Mozc .bazeliskrc does not select Bazel ${ExpectedBazelVersion}: $bazeliskConfig"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $workspace 'MODULE.bazel') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $workspace 'BUILD.bazel') -PathType Leaf)) {
        throw "The pinned Mozc workspace is incomplete: $workspace"
    }

    return [pscustomobject]@{
        Root = [System.IO.Path]::GetFullPath($mozcRoot)
        Workspace = [System.IO.Path]::GetFullPath($workspace)
        Commit = $ExpectedCommit
        BazelVersion = $ExpectedBazelVersion
        BazeliskConfig = $bazeliskConfig
    }
}

function Get-TsfRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd([char[]]'\/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $prefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the artifact root: $Path"
    }
    return $pathFull.Substring($prefix.Length).Replace('\', '/')
}

function Get-TsfSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TsfTreeFingerprint {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Cannot fingerprint a missing source tree: $Root"
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName)) {
        if ($file.FullName -match '[\\/](\.git|bazel-bin|bazel-out|bazel-src|bazel-testlogs|build|out)[\\/]') {
            continue
        }
        $relative = $file.FullName.Substring($rootFull.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        $records += ($relative + '|' + [string]$file.Length + '|' + (Get-TsfSha256 -Path $file.FullName))
    }
    $text = ($records -join "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Write-TsfUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-TsfJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    Write-TsfUtf8File -Path $Path -Content (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
}

function Get-TsfGitRevision {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) {
        return 'unknown'
    }
    try {
        $revisionOutput = & $git.Path -c 'safe.directory=*' -C $RepositoryRoot rev-parse HEAD 2>$null
        $revisionExitCode = $LASTEXITCODE
        $revision = @($revisionOutput | Select-Object -First 1)
        if ($revisionExitCode -eq 0 -and $revision.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$revision[0])) {
            return ([string]$revision[0]).Trim()
        }
    }
    catch {
        # Source archives may not contain Git metadata.
    }
    return 'unknown'
}

function Get-TsfArtifactFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    return @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName)
}
