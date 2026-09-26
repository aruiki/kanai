# Shared, side-effect-free helpers for the pinned-Mozc Windows TSF smoke harness.
# The implementation intentionally targets Windows PowerShell 5.1 as well as
# PowerShell 7. Dot-sourcing this file must not load artifacts, initialize the
# developer environment, launch an application, or modify the registry.

Set-StrictMode -Version Latest

$script:TsfSmokeAmd64Machine = [uint16]0x8664
$script:TsfSmokePe32PlusMagic = [uint16]0x20b
$script:TsfSmokeDllCharacteristic = [uint16]0x2000

function Get-TsfSmokeProperty {
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

function Get-TsfSmokeArrayProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-TsfSmokeProperty -Object $Object -Name $Name
    if ($null -eq $value) {
        return @()
    }
    return @($value)
}

function Get-TsfSmokeCommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $commands = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) {
        return $null
    }
    $command = $commands[0]
    if (-not [string]::IsNullOrWhiteSpace([string]$command.Path)) {
        return [System.IO.Path]::GetFullPath([string]$command.Path)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return [System.IO.Path]::GetFullPath([string]$command.Source)
    }
    return $null
}

function ConvertFrom-TsfSmokeWslPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $windowsRoot = [string][System.Environment]::GetEnvironmentVariable('WINDIR')
    $systemWsl = if ([string]::IsNullOrWhiteSpace($windowsRoot)) { '' } else { Join-Path $windowsRoot 'System32\wsl.exe' }
    $wsl = if (-not [string]::IsNullOrWhiteSpace($systemWsl) -and (Test-Path -LiteralPath $systemWsl -PathType Leaf)) {
        [System.IO.Path]::GetFullPath($systemWsl)
    }
    else {
        Get-TsfSmokeCommandPath -Name 'wsl.exe'
    }
    if ($null -eq $wsl) {
        throw "A Linux absolute path was supplied but wsl.exe is unavailable: $Path"
    }

    $translated = @()
    $exitCode = 1
    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        Push-Location -LiteralPath 'C:\Windows'
        try {
            $translated = @(& $wsl 'wslpath' '-w' $Path 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
    }
    $value = (([string]($translated | Select-Object -First 1)).Trim())
    if ($exitCode -ne 0 -or $value.Length -eq 0) {
        throw "WSL interop could not translate '$Path' to a Windows path. Exit code: $exitCode"
    }
    return $value
}

function Resolve-TsfSmokePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath,
        [switch]$AllowEmpty
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ($AllowEmpty) {
            return ''
        }
        throw 'A required path was empty.'
    }

    $isWslRepository = $BasePath -like '\\wsl*'
    $hasWslEnvironment = (-not [string]::IsNullOrWhiteSpace([string][System.Environment]::GetEnvironmentVariable('WSL_DISTRO_NAME')) -or
        -not [string]::IsNullOrWhiteSpace([string][System.Environment]::GetEnvironmentVariable('WSL_INTEROP')))
    if (($isWslRepository -or $hasWslEnvironment) -and $Path.StartsWith('/')) {
        $Path = ConvertFrom-TsfSmokeWslPath -Path $Path
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path $BasePath $Path
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-TsfSmokeSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Write-TsfSmokeUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-TsfSmokeJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    Write-TsfSmokeUtf8File -Path $Path -Content (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
}

function Read-TsfSmokeExact {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Count
    )

    if ($Offset -lt 0 -or $Count -lt 0 -or $Offset -gt ($Stream.Length - $Count)) {
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

function Convert-TsfSmokeRvaToOffset {
    param(
        [Parameter(Mandatory = $true)]$Image,
        [Parameter(Mandatory = $true)][uint32]$Rva
    )

    if ($Rva -lt [uint32]$Image.SizeOfHeaders) {
        return [int]$Rva
    }
    foreach ($section in @($Image.Sections)) {
        $span = [Math]::Max([uint32]$section.VirtualSize, [uint32]$section.RawSize)
        if ($Rva -ge [uint32]$section.VirtualAddress -and
            $Rva -lt ([uint32]$section.VirtualAddress + $span)) {
            $delta = $Rva - [uint32]$section.VirtualAddress
            if ($delta -ge [uint32]$section.RawSize) {
                throw ('PE RVA points into uninitialized section data: 0x{0:X8}' -f $Rva)
            }
            return [int]([uint32]$section.RawPointer + $delta)
        }
    }
    throw ('PE RVA cannot be mapped to a file offset: 0x{0:X8}' -f $Rva)
}

function Get-TsfSmokePeImage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireDll
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "PE image is missing: $Path"
    }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $mz = [byte[]](Read-TsfSmokeExact -Stream $stream -Offset 0 -Count 64)
        if ($mz[0] -ne 0x4d -or $mz[1] -ne 0x5a) {
            throw "Image is not a Windows PE (MZ signature missing): $Path"
        }
        $peOffset = [BitConverter]::ToInt32($mz, 0x3c)
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 24)) {
            throw "PE header offset is invalid: $Path"
        }
        $coff = [byte[]](Read-TsfSmokeExact -Stream $stream -Offset $peOffset -Count 24)
        if ($coff[0] -ne 0x50 -or $coff[1] -ne 0x45 -or $coff[2] -ne 0 -or $coff[3] -ne 0) {
            throw "PE signature is missing: $Path"
        }

        $machine = [BitConverter]::ToUInt16($coff, 4)
        $sectionCount = [BitConverter]::ToUInt16($coff, 6)
        $optionalSize = [BitConverter]::ToUInt16($coff, 20)
        $characteristics = [BitConverter]::ToUInt16($coff, 22)
        if ($sectionCount -eq 0 -or $sectionCount -gt 96) {
            throw "PE section count is invalid ($sectionCount): $Path"
        }
        if ($optionalSize -lt 64) {
            throw "PE optional header is truncated: $Path"
        }

        $optionalOffset = $peOffset + 24
        $optional = [byte[]](Read-TsfSmokeExact -Stream $stream -Offset $optionalOffset -Count $optionalSize)
        $optionalMagic = [BitConverter]::ToUInt16($optional, 0)
        $sizeOfHeaders = [BitConverter]::ToUInt32($optional, 60)
        $exportRva = [uint32]0
        $exportSize = [uint32]0
        $importRva = [uint32]0
        $importSize = [uint32]0
        if ($optionalMagic -eq $script:TsfSmokePe32PlusMagic) {
            if ($optionalSize -lt 144) {
                throw "PE32+ optional header has no complete data-directory table: $Path"
            }
            $exportRva = [BitConverter]::ToUInt32($optional, 112)
            $exportSize = [BitConverter]::ToUInt32($optional, 116)
            $importRva = [BitConverter]::ToUInt32($optional, 120)
            $importSize = [BitConverter]::ToUInt32($optional, 124)
        }
        else {
            if ($optionalSize -lt 128) {
                throw "PE32 optional header has no complete data-directory table: $Path"
            }
            $exportRva = [BitConverter]::ToUInt32($optional, 96)
            $exportSize = [BitConverter]::ToUInt32($optional, 100)
            $importRva = [BitConverter]::ToUInt32($optional, 104)
            $importSize = [BitConverter]::ToUInt32($optional, 108)
        }

        $sectionTableOffset = $optionalOffset + $optionalSize
        $sectionBytes = [byte[]](Read-TsfSmokeExact -Stream $stream -Offset $sectionTableOffset -Count ($sectionCount * 40))
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
            IsDll = (($characteristics -band $script:TsfSmokeDllCharacteristic) -ne 0)
            SizeOfHeaders = $sizeOfHeaders
            ExportRva = $exportRva
            ExportSize = $exportSize
            ImportRva = $importRva
            ImportSize = $importSize
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

function Assert-TsfSmokeX64Pe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireDll
    )

    $image = Get-TsfSmokePeImage -Path $Path -RequireDll:$RequireDll
    if ($image.Machine -ne $script:TsfSmokeAmd64Machine) {
        throw ("PE image is not Windows x64 (machine {0}, expected 0x8664): {1}" -f $image.MachineName, $Path)
    }
    if ($image.OptionalMagic -ne $script:TsfSmokePe32PlusMagic) {
        throw ("PE image is not PE32+ (optional magic {0}, expected 0x20b): {1}" -f $image.OptionalMagicHex, $Path)
    }
    return $image
}

function Get-TsfSmokeAsciiZString {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$Offset,
        [int]$MaximumLength = 512
    )

    $Stream.Position = $Offset
    $bytes = New-Object byte[] $MaximumLength
    $length = 0
    while ($length -lt $MaximumLength) {
        $value = $Stream.ReadByte()
        if ($value -lt 1) {
            break
        }
        $bytes[$length] = [byte]$value
        $length++
    }
    if ($length -eq 0) {
        throw "PE contains an empty name at file offset $Offset."
    }
    return [System.Text.Encoding]::ASCII.GetString($bytes, 0, $length)
}

function Get-TsfSmokeExportNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    $image = Get-TsfSmokePeImage -Path $Path -RequireDll
    if ($image.ExportRva -eq 0 -or $image.ExportSize -eq 0) {
        return @()
    }
    $exportOffset = Convert-TsfSmokeRvaToOffset -Image $image -Rva $image.ExportRva
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $directory = [byte[]](Read-TsfSmokeExact -Stream $stream -Offset $exportOffset -Count 40)
        $nameCount = [BitConverter]::ToUInt32($directory, 24)
        $namesRva = [BitConverter]::ToUInt32($directory, 32)
        if ($nameCount -gt 65535) {
            throw "PE export name count is unreasonable ($nameCount): $Path"
        }
        $namesOffset = Convert-TsfSmokeRvaToOffset -Image $image -Rva $namesRva
        $names = @()
        for ($index = 0; $index -lt $nameCount; $index++) {
            $namePointerBytes = [byte[]](Read-TsfSmokeExact -Stream $stream -Offset ($namesOffset + ($index * 4)) -Count 4)
            $nameRva = [BitConverter]::ToUInt32($namePointerBytes, 0)
            $nameOffset = Convert-TsfSmokeRvaToOffset -Image $image -Rva $nameRva
            $names += Get-TsfSmokeAsciiZString -Stream $stream -Offset $nameOffset
        }
        return @($names)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-TsfSmokeImportNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    $image = Get-TsfSmokePeImage -Path $Path -RequireDll
    if ($image.ImportRva -eq 0 -or $image.ImportSize -eq 0) {
        return @()
    }
    $descriptorOffset = Convert-TsfSmokeRvaToOffset -Image $image -Rva $image.ImportRva
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $names = @()
        for ($index = 0; $index -lt 4096; $index++) {
            $descriptor = [byte[]](Read-TsfSmokeExact -Stream $stream -Offset ($descriptorOffset + ($index * 20)) -Count 20)
            $allZero = $true
            foreach ($value in $descriptor) {
                if ($value -ne 0) {
                    $allZero = $false
                    break
                }
            }
            if ($allZero) {
                return @($names)
            }
            $nameRva = [BitConverter]::ToUInt32($descriptor, 12)
            if ($nameRva -eq 0) {
                throw "PE import descriptor $index has no DLL name RVA: $Path"
            }
            $nameOffset = Convert-TsfSmokeRvaToOffset -Image $image -Rva $nameRva
            $names += Get-TsfSmokeAsciiZString -Stream $stream -Offset $nameOffset
        }
        throw "PE import descriptor table is unreasonable (>4096 entries): $Path"
    }
    finally {
        $stream.Dispose()
    }
}

function Initialize-TsfSmokeMSVCEnvironment {
    param([switch]$Skip)

    $targetArch = [string][System.Environment]::GetEnvironmentVariable('VSCMD_ARG_TGT_ARCH')
    $hostArch = [string][System.Environment]::GetEnvironmentVariable('VSCMD_ARG_HOST_ARCH')
    if ((-not [string]::IsNullOrWhiteSpace($targetArch) -and $targetArch -ine 'x64') -or
        (-not [string]::IsNullOrWhiteSpace($hostArch) -and $hostArch -ine 'x64')) {
        throw "The active Visual Studio environment is not x64 (target='$targetArch', host='$hostArch'). Re-run VsDevCmd.bat -arch=x64 -host_arch=x64."
    }
    $dumpbin = Get-TsfSmokeCommandPath -Name 'dumpbin.exe'
    if ($null -ne $dumpbin) {
        return $dumpbin
    }
    if ($Skip) {
        throw 'dumpbin.exe is unavailable and VsDevCmd initialization was explicitly skipped. Open an x64 Developer PowerShell or remove -SkipVsDevCmd.'
    }
    if (-not [System.Environment]::Is64BitProcess) {
        throw 'The Windows smoke harness requires a 64-bit PowerShell process. Re-run under VsDevCmd.bat -arch=x64 -host_arch=x64.'
    }

    $vswhereCandidates = @()
    $programFilesX86 = [string][System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $programFiles = [string][System.Environment]::GetEnvironmentVariable('ProgramFiles')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $vswhereCandidates += Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
    }
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $vswhereCandidates += Join-Path $programFiles 'Microsoft Visual Studio\Installer\vswhere.exe'
    }
    $vswhere = $null
    foreach ($candidate in $vswhereCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $vswhere = [System.IO.Path]::GetFullPath($candidate)
            break
        }
    }
    if ($null -eq $vswhere) {
        throw 'Visual Studio C++ tools are unavailable: vswhere.exe was not found. Install the x64 v143 toolset and retry.'
    }

    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $vsPathOutput = @(& $vswhere '-latest' '-products' '*' '-requires' 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' '-property' 'installationPath' 2>$null)
        $vsWhereExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
    }
    $vsPath = (([string]($vsPathOutput | Select-Object -First 1)).Trim())
    if ($vsWhereExitCode -ne 0 -or $vsPath.Length -eq 0) {
        throw "vswhere could not locate a Visual Studio installation with the x64 C++ tools: $vswhere"
    }
    $devCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path -LiteralPath $devCmd -PathType Leaf)) {
        throw "Visual Studio was found, but VsDevCmd.bat is missing: $devCmd"
    }

    # WSL interop can start PowerShell with a \\wsl$ current directory. VsDevCmd
    # and cmd are invoked from C:\Windows so they never inherit that UNC CWD.
    $commandLine = 'call "' + $devCmd + '" -arch=x64 -host_arch=x64 >nul && set'
    try {
        $oldErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            Push-Location -LiteralPath 'C:\Windows'
            try {
                $environmentLines = @(& $env:ComSpec '/d' '/s' '/c' $commandLine 2>$null)
                $devCmdExitCode = $LASTEXITCODE
            }
            finally {
                Pop-Location
            }
        }
        finally {
            $ErrorActionPreference = $oldErrorAction
        }
    }
    catch {
        throw "Could not initialize the x64 MSVC environment with VsDevCmd.bat: $($_.Exception.Message)"
    }
    if ($devCmdExitCode -ne 0) {
        throw "VsDevCmd.bat -arch=x64 -host_arch=x64 failed with exit code $devCmdExitCode."
    }
    foreach ($line in $environmentLines) {
        if ([string]$line -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
    $dumpbin = Get-TsfSmokeCommandPath -Name 'dumpbin.exe'
    if ($null -eq $dumpbin) {
        throw "VsDevCmd.bat completed but dumpbin.exe is unavailable. Install the x64 v143 toolset: $devCmd"
    }
    return $dumpbin
}

function Initialize-TsfSmokeNative {
    if ($null -ne ('KanaAI.TsfSmoke.Native' -as [type])) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace KanaAI.TsfSmoke
{
    public static class Native
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibraryExW(string fileName, IntPtr file, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool FreeLibrary(IntPtr module);

        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, BestFitMapping = false, SetLastError = true)]
        public static extern IntPtr GetProcAddress(IntPtr module, string procedureName);
    }
}
'@
}

function Get-TsfSmokeWin32Error {
    param(
        [Parameter(Mandatory = $true)][int]$ErrorCode,
        [string]$Operation = 'Windows API call'
    )
    return ("{0} failed with Win32 error {1} (0x{2:X8})." -f $Operation, $ErrorCode, $ErrorCode)
}

function Get-TsfSmokeRegistryValue {
    param(
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryHive]$Hive,
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryView]$View,
        [Parameter(Mandatory = $true)][string]$SubKey,
        [AllowEmptyString()][string]$Name = ''
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
    try {
        $key = $baseKey.OpenSubKey($SubKey, $false)
        if ($null -eq $key) {
            return [pscustomobject]@{ Found = $false; Value = $null; Kind = 'missing' }
        }
        try {
            $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -eq $value) {
                return [pscustomobject]@{ Found = $false; Value = $null; Kind = 'missing-value' }
            }
            $kind = 'default'
            if (-not [string]::IsNullOrEmpty($Name)) {
                $kind = [string]$key.GetValueKind($Name)
            }
            return [pscustomobject]@{
                Found = $true
                Value = $value
                Kind = $kind
            }
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}
