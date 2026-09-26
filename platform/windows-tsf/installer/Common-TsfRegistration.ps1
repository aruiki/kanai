# Common, source-only helpers for the KanaAI Windows TSF registration slice.
# This file is dot-sourced by the install/uninstall scripts. It intentionally
# keeps dry-run planning separate from registry writes.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TsfCommonRoot = $PSScriptRoot
$script:TsfRegistrationRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\registration'))
$script:TsfGuidPattern = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'
$script:TsfRegistrationClassId = '{7E7B5C1E-6D3A-4F2C-9A0E-3F4B5D6C7E81}'
$script:TsfRegistrationProfileId = '{F3C2B7A1-6D54-4E8B-9A10-2C7D8E9F0A12}'
$script:TsfRegistrationLanguageSegment = '0x00000411'
$script:TsfRegistrationLanguageId = 1041
$script:TsfRegistrationDllName = 'KanaAI.TsfTip.dll'

function Get-TsfSha256 {
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

function Get-TsfRequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Object) {
        throw "$Context is null; property '$Name' cannot be read."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Context is missing required property '$Name'."
    }
    return $property.Value
}

function Get-TsfRegistrationMetadata {
    param([string]$Path = '')

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path $script:TsfRegistrationRoot 'registration.json'
    }
    $fullPath = ConvertTo-TsfPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "TSF registration metadata is missing: $fullPath"
    }

    $metadata = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
    if ([int](Get-TsfRequiredProperty -Object $metadata -Name 'schemaVersion' -Context 'registration metadata') -ne 1) {
        throw "Unsupported TSF registration metadata schema in $fullPath"
    }
    if ([string](Get-TsfRequiredProperty -Object $metadata -Name 'status' -Context 'registration metadata') -ne 'source-only' -or
        (Get-TsfRequiredProperty -Object $metadata -Name 'sourceOnly' -Context 'registration metadata') -ne $true) {
        throw "The registration metadata must remain source-only until a real TIP and Windows tests exist: $fullPath"
    }

    $readiness = Get-TsfRequiredProperty -Object $metadata -Name 'readiness' -Context 'registration metadata'
    foreach ($propertyName in @('registrationComplete', 'tipDllPresent', 'windowsTestsPassed', 'runtimeVerified')) {
        $value = Get-TsfRequiredProperty -Object $readiness -Name $propertyName -Context 'registration readiness'
        if ($value -ne $false) {
            throw "Readiness property '$propertyName' must remain false in the source-only registration metadata."
        }
    }

    $textService = Get-TsfRequiredProperty -Object $metadata -Name 'textService' -Context 'registration metadata'
    $clsid = [string](Get-TsfRequiredProperty -Object $textService -Name 'clsid' -Context 'text service metadata')
    $profileGuid = [string](Get-TsfRequiredProperty -Object $textService -Name 'profileGuid' -Context 'text service metadata')
    if ($clsid -notmatch $script:TsfGuidPattern -or $profileGuid -notmatch $script:TsfGuidPattern) {
        throw 'The TSF CLSID and profile GUID must be brace-delimited hexadecimal GUIDs.'
    }
    $script:TsfRegistrationClassId = $clsid.ToUpperInvariant()
    $script:TsfRegistrationProfileId = $profileGuid.ToUpperInvariant()

    $language = Get-TsfRequiredProperty -Object $textService -Name 'language' -Context 'text service metadata'
    $script:TsfRegistrationLanguageSegment = [string](Get-TsfRequiredProperty -Object $language -Name 'profileKeyLanguageSegment' -Context 'language metadata')
    $script:TsfRegistrationLanguageId = [int](Get-TsfRequiredProperty -Object $language -Name 'languageIdDecimal' -Context 'language metadata')
    $dllMetadata = Get-TsfRequiredProperty -Object $textService -Name 'dll' -Context 'text service metadata'
    $script:TsfRegistrationDllName = [string](Get-TsfRequiredProperty -Object $dllMetadata -Name 'fileName' -Context 'DLL metadata')
    if ([string](Get-TsfRequiredProperty -Object $dllMetadata -Name 'architecture' -Context 'DLL metadata') -ne 'x64') {
        throw 'The source-only registration metadata must describe the x64 TIP DLL.'
    }
    $artifactContract = Get-TsfRequiredProperty -Object $metadata -Name 'artifactContract' -Context 'registration metadata'
    if ([string](Get-TsfRequiredProperty -Object $artifactContract -Name 'name' -Context 'artifact contract') -ne $script:TsfRegistrationDllName) {
        throw 'The artifact contract and TIP DLL metadata must use the same DLL name.'
    }

    return $metadata
}

function Get-TsfArchitectureSpec {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][ValidateSet('x64', 'x86')][string]$Architecture
    )

    $architectures = Get-TsfRequiredProperty -Object $Metadata -Name 'architectures' -Context 'registration metadata'
    $property = $architectures.PSObject.Properties[$Architecture]
    if ($null -eq $property) {
        throw "No registry/path specification exists for architecture '$Architecture'."
    }
    $spec = $property.Value
    $programFiles = Get-TsfRequiredProperty -Object $spec -Name 'programFiles' -Context "architecture '$Architecture' metadata"
    $blockedReason = ''
    $blockedReasonProperty = $spec.PSObject.Properties['blockedReason']
    if ($null -ne $blockedReasonProperty) {
        $blockedReason = [string]$blockedReasonProperty.Value
    }
    $registryViewGuidance = ''
    $registryViewGuidanceProperty = $spec.PSObject.Properties['registryViewGuidance']
    if ($null -ne $registryViewGuidanceProperty) {
        $registryViewGuidance = [string]$registryViewGuidanceProperty.Value
    }
    return [pscustomobject]@{
        Architecture = $Architecture
        Supported = [bool](Get-TsfRequiredProperty -Object $spec -Name 'supported' -Context "architecture '$Architecture' metadata")
        RegistryView = [string](Get-TsfRequiredProperty -Object $spec -Name 'registryView' -Context "architecture '$Architecture' metadata")
        RegistryViewGuidance = $registryViewGuidance
        DllPathTemplate = [string](Get-TsfRequiredProperty -Object $spec -Name 'dllPathTemplate' -Context "architecture '$Architecture' metadata")
        ProgramFilesDisplayName = [string](Get-TsfRequiredProperty -Object $programFiles -Name 'displayName' -Context "architecture '$Architecture' metadata")
        ProgramFilesPrimaryVariable = [string](Get-TsfRequiredProperty -Object $programFiles -Name 'primaryEnvironmentVariable' -Context "architecture '$Architecture' metadata")
        ProgramFilesFallbackVariable = [string](Get-TsfRequiredProperty -Object $programFiles -Name 'fallbackEnvironmentVariable' -Context "architecture '$Architecture' metadata")
        RelativeDirectory = [string](Get-TsfRequiredProperty -Object $programFiles -Name 'relativeDirectory' -Context "architecture '$Architecture' metadata")
        BlockedReason = $blockedReason
    }
}

function Get-TsfEnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    return [System.Environment]::GetEnvironmentVariable($Name)
}

function Join-TsfWindowsPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ($Root -match '^<[^>]+>(?:\\|/|$)') {
        return ($Root.TrimEnd('\') + '\' + $RelativePath.TrimStart('\'))
    }
    if ($Root -match '^[A-Za-z]:[\\/]' -or $Root -match '^\\\\') {
        return ($Root.TrimEnd('\') + '\' + $RelativePath.TrimStart('\'))
    }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $Root -ChildPath $RelativePath))
}

function ConvertTo-TsfPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -match '^[A-Za-z]:[\\/]' -or $Path -match '^\\\\') {
        return $Path.TrimEnd('\')
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Join-TsfRegistryPath {
    param(
        [Parameter(Mandatory = $true)][string[]]$Parts
    )

    $normalized = @()
    foreach ($part in $Parts) {
        if (-not [string]::IsNullOrWhiteSpace($part)) {
            $normalized += $part.Trim('\')
        }
    }
    if ($normalized.Count -eq 0) {
        throw 'Cannot build an empty TSF registry path.'
    }
    return ($normalized -join '\')
}

function Get-TsfProgramFilesRoot {
    param(
        [Parameter(Mandatory = $true)]$ArchitectureSpec,
        [string]$Override = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if ($ArchitectureSpec.Architecture -eq 'x64' -and $Override -match '(?i)Program Files \(x86\)|ProgramFiles\(x86\)') {
            throw 'The x64 TIP cannot be directed into Program Files (x86). Choose the Program Files/ProgramW6432 tree.'
        }
        if ($Override -match '^<[^>]+>$') {
            return $Override
        }
        return (ConvertTo-TsfPath -Path $Override)
    }

    $primaryValue = Get-TsfEnvironmentValue -Name $ArchitectureSpec.ProgramFilesPrimaryVariable
    $fallbackValue = ''
    if (-not [string]::IsNullOrWhiteSpace($ArchitectureSpec.ProgramFilesFallbackVariable)) {
        $fallbackValue = Get-TsfEnvironmentValue -Name $ArchitectureSpec.ProgramFilesFallbackVariable
    }

    if (-not [string]::IsNullOrWhiteSpace($primaryValue)) {
        return (ConvertTo-TsfPath -Path $primaryValue)
    }
    if (-not [string]::IsNullOrWhiteSpace($fallbackValue)) {
        # A 32-bit process sees the 32-bit ProgramFiles value. Never use that
        # as the x64 fallback, because it would put an x64 TIP in the wrong tree.
        if ($ArchitectureSpec.Architecture -eq 'x64' -and
            -not [System.Environment]::Is64BitProcess) {
            return '<ProgramW6432>'
        }
        return (ConvertTo-TsfPath -Path $fallbackValue)
    }

    if ($ArchitectureSpec.Architecture -eq 'x64') {
        return '<ProgramW6432>'
    }
    return '<ProgramFiles(x86)>'
}

function Get-TsfInstallLocation {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)]$ArchitectureSpec,
        [string]$InstallRoot = '',
        [string]$ProgramFilesRoot = ''
    )

    $rootSource = 'ProgramFiles'
    $root = $ProgramFilesRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Get-TsfProgramFilesRoot -ArchitectureSpec $ArchitectureSpec
    }
    else {
        # Route explicit roots through the same architecture guard as the
        # environment-derived path. Otherwise a caller could bypass the
        # Program Files (x86) rejection by supplying the value directly.
        $root = Get-TsfProgramFilesRoot -ArchitectureSpec $ArchitectureSpec -Override $ProgramFilesRoot
        $rootSource = 'Explicit'
    }
    $relativeDirectory = $ArchitectureSpec.RelativeDirectory
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $installDirectory = ConvertTo-TsfPath -Path $InstallRoot
        $rootSource = 'ExplicitInstallDirectory'
    }
    else {
        if ($root -notmatch '^<[^>]+>') {
            $root = ConvertTo-TsfPath -Path $root
        }
        $installDirectory = Join-TsfWindowsPath -Root $root -RelativePath $relativeDirectory
    }
    $dllPath = Join-TsfWindowsPath -Root $installDirectory -RelativePath $script:TsfRegistrationDllName
    return [pscustomobject]@{
        ProgramFilesRoot = $root
        ProgramFilesRootSource = $rootSource
        ProgramFilesDisplayName = $ArchitectureSpec.ProgramFilesDisplayName
        InstallDirectory = $installDirectory
        TipDllPath = $dllPath
        Architecture = $ArchitectureSpec.Architecture
        RegistryView = $ArchitectureSpec.RegistryView
        ExpectedRelativeDirectory = $relativeDirectory
        ExpectedDllFileName = $script:TsfRegistrationDllName
    }
}

function Get-TsfScopeName {
    param([Parameter(Mandatory = $true)][string]$Scope)

    switch -Regex ($Scope.Trim()) {
        '^(?i:per[-_ ]?user|user|current[-_ ]?user)$' { return 'PerUser' }
        '^(?i:machine|admin|administrator|system|all[-_ ]?users)$' { return 'Machine' }
        default { throw "Unsupported registration scope '$Scope'. Use PerUser or Machine." }
    }
}

function Get-TsfWindowsTestReceipt {
    param(
        [string]$Path = '',
        [string]$TipDllPath = '',
        [string]$Architecture = 'x64'
    )

    $result = [pscustomobject]@{
        Path = $Path
        Exists = $false
        WindowsTestsPassed = $false
        ArchitectureMatches = $false
        HashMatches = $false
        Error = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $result
    }
    $fullPath = ConvertTo-TsfPath -Path $Path
    $result.Path = $fullPath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $result.Error = "Windows test receipt is missing: $fullPath"
        return $result
    }
    $result.Exists = $true
    try {
        $receipt = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
        $passed = Get-TsfRequiredProperty -Object $receipt -Name 'windowsTestsPassed' -Context 'Windows test receipt'
        $result.WindowsTestsPassed = ($passed -eq $true)
        $receiptArchitecture = [string](Get-TsfRequiredProperty -Object $receipt -Name 'architecture' -Context 'Windows test receipt')
        $result.ArchitectureMatches = ($receiptArchitecture -ieq $Architecture)
        $tipRecord = Get-TsfRequiredProperty -Object $receipt -Name 'tipDll' -Context 'Windows test receipt'
        $expectedHash = [string](Get-TsfRequiredProperty -Object $tipRecord -Name 'sha256' -Context 'Windows test receipt')
        if (-not [string]::IsNullOrWhiteSpace($expectedHash) -and
            -not [string]::IsNullOrWhiteSpace($TipDllPath) -and
            (Test-Path -LiteralPath $TipDllPath -PathType Leaf)) {
            $actualHash = Get-TsfSha256 -Path $TipDllPath
            $result.HashMatches = ($actualHash -ieq $expectedHash.ToLowerInvariant())
        }
        else {
            $result.HashMatches = $false
        }
    }
    catch {
        $result.Error = "Windows test receipt is invalid: $($_.Exception.Message)"
        $result.WindowsTestsPassed = $false
    }
    return $result
}

function Get-TsfReadiness {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$TipDllPath,
        [string]$WindowsTestReceipt = '',
        [string]$Architecture = 'x64'
    )

    $dllInfo = Get-TsfPeInfo -Path $TipDllPath -Architecture $Architecture
    $receipt = Get-TsfWindowsTestReceipt -Path $WindowsTestReceipt -TipDllPath $TipDllPath -Architecture $Architecture
    $identity = Get-TsfRequiredProperty -Object $Metadata -Name 'registrationIdentity' -Context 'registration metadata'
    $identityApproved = [bool](Get-TsfRequiredProperty -Object $identity -Name 'identityApproved' -Context 'registration identity metadata')
    $reasons = @()
    if (-not $identityApproved) {
        $reasons += 'The KanaAI TSF registration identity is still provisional and has not been approved.'
    }
    if (-not $dllInfo.Exists) {
        $reasons += 'A real KanaAI.TsfTip.dll is not present at the resolved path.'
    }
    elseif (-not $dllInfo.Valid) {
        $reasons += 'The resolved TIP file is not a valid PE DLL for the selected architecture.'
    }
    if (-not $receipt.WindowsTestsPassed) {
        $reasons += 'Windows registration and application tests have not passed.'
    }
    elseif (-not $receipt.ArchitectureMatches) {
        $reasons += 'The Windows test receipt does not match the selected architecture.'
    }
    elseif (-not $receipt.HashMatches) {
        $reasons += 'The Windows test receipt does not match the TIP DLL hash.'
    }

    return [pscustomobject]@{
        TipDllExists = [bool]$dllInfo.Exists
        TipDllValid = [bool]$dllInfo.Valid
        TipDllMachine = [string]$dllInfo.Machine
        IdentityApproved = $identityApproved
        WindowsTestReceiptExists = [bool]$receipt.Exists
        WindowsTestsPassed = [bool]($receipt.WindowsTestsPassed -and $receipt.ArchitectureMatches -and $receipt.HashMatches)
        RuntimeVerified = $false
        RegistrationComplete = $false
        BlockingReasons = @($reasons)
        Receipt = $receipt
        Pe = $dllInfo
    }
}

function Get-TsfPeInfo {
    param(
        [string]$Path = '',
        [string]$Architecture = 'x64'
    )

    $info = [pscustomobject]@{
        Path = $Path
        Exists = $false
        Valid = $false
        Machine = ''
        OptionalMagic = ''
        IsDll = $false
        Error = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^<[^>]+>') {
        $info.Error = 'TIP DLL path is unresolved.'
        return $info
    }
    $fullPath = ConvertTo-TsfPath -Path $Path
    $info.Path = $fullPath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $info.Error = "TIP DLL does not exist: $fullPath"
        return $info
    }
    $info.Exists = $true

    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($fullPath)
        if ($stream.Length -lt 64) {
            throw 'file is too small to contain a PE header'
        }
        $mz = New-Object byte[] 2
        if ($stream.Read($mz, 0, 2) -ne 2 -or $mz[0] -ne 0x4d -or $mz[1] -ne 0x5a) {
            throw 'MZ header is missing'
        }
        $stream.Position = 0x3c
        $offsetBytes = New-Object byte[] 4
        if ($stream.Read($offsetBytes, 0, 4) -ne 4) {
            throw 'PE header offset is truncated'
        }
        $peOffset = [BitConverter]::ToInt32($offsetBytes, 0)
        if ($peOffset -lt 0 -or ($peOffset + 26) -gt $stream.Length) {
            throw 'PE header offset is invalid'
        }
        $stream.Position = $peOffset
        $coff = New-Object byte[] 24
        if ($stream.Read($coff, 0, 24) -ne 24 -or
            $coff[0] -ne 0x50 -or $coff[1] -ne 0x45 -or
            $coff[2] -ne 0 -or $coff[3] -ne 0) {
            throw 'PE signature is missing'
        }
        $machine = [BitConverter]::ToUInt16($coff, 4)
        $optionalSize = [BitConverter]::ToUInt16($coff, 20)
        if ($optionalSize -lt 2 -or ($peOffset + 24 + $optionalSize) -gt $stream.Length) {
            throw 'PE optional header is invalid'
        }
        $stream.Position = $peOffset + 24
        $optional = New-Object byte[] 2
        if ($stream.Read($optional, 0, 2) -ne 2) {
            throw 'PE optional magic is truncated'
        }
        $optionalMagic = [BitConverter]::ToUInt16($optional, 0)
        # COFF Characteristics is the final WORD after SizeOfOptionalHeader.
        $characteristics = [BitConverter]::ToUInt16($coff, 22)
        $info.Machine = ('0x{0:X4}' -f $machine)
        $info.OptionalMagic = ('0x{0:X4}' -f $optionalMagic)
        $info.IsDll = (($characteristics -band 0x2000) -ne 0)
        $validMachine = ($Architecture -eq 'x64' -and $machine -eq 0x8664 -and $optionalMagic -eq 0x020b)
        if (-not $validMachine -and $Architecture -eq 'x86') {
            $validMachine = ($machine -eq 0x014c -and $optionalMagic -eq 0x010b)
        }
        $info.Valid = ($validMachine -and $info.IsDll)
        if (-not $validMachine) {
            $info.Error = "PE machine/magic is $($info.Machine)/$($info.OptionalMagic), expected $Architecture."
        }
        elseif (-not $info.IsDll) {
            $info.Error = 'PE image is an executable, not a DLL.'
        }
    }
    catch {
        $info.Error = "PE validation failed: $($_.Exception.Message)"
        $info.Valid = $false
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    return $info
}

function New-TsfRegistryOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Hive,
        [Parameter(Mandatory = $true)][string]$View,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Name = '',
        [string]$Type = 'REG_SZ',
        [object]$Value = $null,
        [bool]$RequiresRealTipDll = $false,
        [string]$Note = ''
    )

    return [pscustomobject]@{
        Action = $Action
        Hive = $Hive
        View = $View
        Key = $Key
        Name = $Name
        Type = $Type
        Value = $Value
        RequiresRealTipDll = $RequiresRealTipDll
        Note = $Note
    }
}

function Get-TsfRegistryValueSpec {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $groupObject = Get-TsfRequiredProperty -Object $Registry -Name $Group -Context 'registry metadata'
    $valueObject = Get-TsfRequiredProperty -Object $groupObject -Name $Name -Context "registry metadata group '$Group'"
    return [pscustomobject]@{
        Name = $Name
        Type = [string](Get-TsfRequiredProperty -Object $valueObject -Name 'type' -Context "registry value '$Name'")
        Value = Get-TsfRequiredProperty -Object $valueObject -Name 'value' -Context "registry value '$Name'"
    }
}

function New-TsfInstallPlan {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)]$ArchitectureSpec,
        [Parameter(Mandatory = $true)][ValidateSet('PerUser', 'Machine')][string]$Scope,
        [Parameter(Mandatory = $true)]$Location,
        [string]$WindowsTestReceipt = '',
        [switch]$SkipUserActivation
    )

    $registry = Get-TsfRequiredProperty -Object $Metadata -Name 'registry' -Context 'registration metadata'
    $textService = Get-TsfRequiredProperty -Object $Metadata -Name 'textService' -Context 'registration metadata'
    $clsid = [string](Get-TsfRequiredProperty -Object $textService -Name 'clsid' -Context 'text service metadata')
    $profileId = [string](Get-TsfRequiredProperty -Object $textService -Name 'profileGuid' -Context 'text service metadata')
    $languageSegment = [string](Get-TsfRequiredProperty -Object (Get-TsfRequiredProperty -Object $textService -Name 'language' -Context 'text service metadata') -Name 'profileKeyLanguageSegment' -Context 'language metadata')
    $description = [string](Get-TsfRequiredProperty -Object $textService -Name 'description' -Context 'text service metadata')
    $profileDescription = [string](Get-TsfRequiredProperty -Object $textService -Name 'displayName' -Context 'text service metadata')
    $icon = Get-TsfRequiredProperty -Object $textService -Name 'icon' -Context 'text service metadata'
    $iconPath = Join-TsfWindowsPath -Root $Location.InstallDirectory -RelativePath ([string](Get-TsfRequiredProperty -Object $icon -Name 'fileName' -Context 'icon metadata'))

    $comRoot = if ($Scope -eq 'Machine') {
        [string](Get-TsfRequiredProperty -Object $registry -Name 'machineComRoot' -Context 'registry metadata')
    }
    else {
        [string](Get-TsfRequiredProperty -Object $registry -Name 'userComRoot' -Context 'registry metadata')
    }
    $tipRoot = if ($Scope -eq 'Machine') {
        [string](Get-TsfRequiredProperty -Object $registry -Name 'machineTextServiceRoot' -Context 'registry metadata')
    }
    else {
        [string](Get-TsfRequiredProperty -Object $registry -Name 'userTextServiceRoot' -Context 'registry metadata')
    }
    $profileSubkey = [string](Get-TsfRequiredProperty -Object $registry -Name 'profileSubkey' -Context 'registry metadata')
    $comKey = Join-TsfRegistryPath -Parts @($comRoot, $clsid)
    $inProcKey = Join-TsfRegistryPath -Parts @($comKey, 'InProcServer32')
    $tipKey = Join-TsfRegistryPath -Parts @($tipRoot, $clsid)
    $profileKey = Join-TsfRegistryPath -Parts @($tipKey, $profileSubkey, $languageSegment, $profileId)
    $hive = if ($Scope -eq 'Machine') { 'LocalMachine' } else { 'CurrentUser' }
    $view = [string]$ArchitectureSpec.RegistryView

    $operations = @()
    $operations += New-TsfRegistryOperation -Action 'set' -Hive $hive -View $view -Key $comKey -Type 'REG_SZ' -Value $description -Note 'COM class description projection'
    $operations += New-TsfRegistryOperation -Action 'set' -Hive $hive -View $view -Key $inProcKey -Type 'REG_SZ' -Value $Location.TipDllPath -RequiresRealTipDll $true -Note 'COM InProcServer32 must contain an absolute real DLL path'
    $operations += New-TsfRegistryOperation -Action 'set' -Hive $hive -View $view -Key $inProcKey -Name 'ThreadingModel' -Type 'REG_SZ' -Value ([string](Get-TsfRequiredProperty -Object $textService -Name 'threadingModel' -Context 'text service metadata')) -Note 'COM threading model'

    foreach ($name in @('Description', 'EnableCompartment', 'LoadBehavior')) {
        $value = Get-TsfRegistryValueSpec -Registry $registry -Group 'textServiceValues' -Name $name
        $value.Value = if ($name -eq 'Description') { $description } else { $value.Value }
        $operations += New-TsfRegistryOperation -Action 'set' -Hive $hive -View $view -Key $tipKey -Name $name -Type $value.Type -Value $value.Value -Note 'TSF text-service metadata projection; reconcile with ITfInputProcessorProfiles.Register'
    }

    $profileValues = @(
        @{ Name = 'Description'; Value = $profileDescription; Type = 'REG_SZ' },
        @{ Name = 'Language'; Value = $script:TsfRegistrationLanguageId; Type = 'REG_DWORD' },
        @{ Name = 'IconFile'; Value = $iconPath; Type = 'REG_SZ' },
        @{ Name = 'IconIndex'; Value = [int](Get-TsfRequiredProperty -Object $icon -Name 'index' -Context 'icon metadata'); Type = 'REG_DWORD' }
    )
    foreach ($value in $profileValues) {
        $operations += New-TsfRegistryOperation -Action 'set' -Hive $hive -View $view -Key $profileKey -Name $value.Name -Type $value.Type -Value $value.Value -RequiresRealTipDll ($value.Name -eq 'IconFile') -Note 'TSF language-profile metadata projection; reconcile with AddLanguageProfile'
    }
    if (-not $SkipUserActivation) {
        $activationKey = $profileKey
        $activationHive = if ($Scope -eq 'Machine') { 'CurrentUser' } else { 'CurrentUser' }
        $activationValue = Get-TsfRegistryValueSpec -Registry $registry -Group 'userActivationValues' -Name 'Enable'
        $operations += New-TsfRegistryOperation -Action 'set' -Hive $activationHive -View $view -Key $activationKey -Name 'Enable' -Type $activationValue.Type -Value $activationValue.Value -Note 'Per-user profile activation; do not confuse with machine registration'
    }

    $apiOperations = @()
    foreach ($api in @(Get-TsfRequiredProperty -Object $Metadata -Name 'registrationApis' -Context 'registration metadata')) {
        $apiOperations += [pscustomobject]@{
            Name = [string](Get-TsfRequiredProperty -Object $api -Name 'name' -Context 'registration API metadata')
            Required = [bool](Get-TsfRequiredProperty -Object $api -Name 'required' -Context 'registration API metadata')
            Purpose = [string](Get-TsfRequiredProperty -Object $api -Name 'purpose' -Context 'registration API metadata')
        }
    }

    $readiness = Get-TsfReadiness -Metadata $Metadata -TipDllPath $Location.TipDllPath -WindowsTestReceipt $WindowsTestReceipt -Architecture $ArchitectureSpec.Architecture
    $blockedReasons = @()
    if (-not $ArchitectureSpec.Supported) {
        $blockedReasons += $ArchitectureSpec.BlockedReason
    }
    $blockedReasons += $readiness.BlockingReasons
    return [pscustomobject]@{
        SchemaVersion = 1
        Status = 'source-only'
        Mode = 'dry-run'
        DryRun = $true
        Applied = $false
        Action = 'install'
        Scope = $Scope
        Architecture = $ArchitectureSpec.Architecture
        RegistryView = $view
        RegistryViewGuidance = [string]$ArchitectureSpec.RegistryViewGuidance
        RequiresAdministrator = ($Scope -eq 'Machine')
        ProgramFilesRoot = $Location.ProgramFilesRoot
        ProgramFilesRootSource = $Location.ProgramFilesRootSource
        ProgramFilesDisplayName = $Location.ProgramFilesDisplayName
        InstallDirectory = $Location.InstallDirectory
        TipDllPath = $Location.TipDllPath
        Clsid = $clsid
        ProfileGuid = $profileId
        LanguageSegment = $languageSegment
        RegistryKeys = [pscustomobject]@{
            Com = $comKey
            InProcServer32 = $inProcKey
            TextService = $tipKey
            Profile = $profileKey
        }
        RegistryOperations = @($operations)
        ApiOperations = @($apiOperations)
        FileChecks = @(
            [pscustomobject]@{
                Action = 'require'
                Path = $Location.TipDllPath
                Architecture = $ArchitectureSpec.Architecture
                Exists = $readiness.TipDllExists
                Valid = $readiness.TipDllValid
            }
        )
        Readiness = $readiness
        BlockingReasons = @($blockedReasons)
        CanApply = ([bool]$ArchitectureSpec.Supported -and $readiness.IdentityApproved -and $readiness.TipDllExists -and $readiness.TipDllValid -and $readiness.WindowsTestsPassed)
        TipDllPresent = $readiness.TipDllExists
        WindowsTestsPassed = $readiness.WindowsTestsPassed
        RuntimeVerified = $false
        Registered = $false
        RegistrationComplete = $false
        Template = if ($Scope -eq 'PerUser') {
            'templates/per-user.reg.template'
        }
        elseif ($ArchitectureSpec.Architecture -eq 'x64') {
            'templates/administrator-x64.reg.template'
        }
        else {
            'templates/administrator-x86.reg.template'
        }
    }
}

function New-TsfUninstallPlan {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)]$ArchitectureSpec,
        [Parameter(Mandatory = $true)][ValidateSet('PerUser', 'Machine')][string]$Scope,
        [Parameter(Mandatory = $true)]$Location,
        [switch]$RemoveUserActivation
    )

    $registry = Get-TsfRequiredProperty -Object $Metadata -Name 'registry' -Context 'registration metadata'
    $textService = Get-TsfRequiredProperty -Object $Metadata -Name 'textService' -Context 'registration metadata'
    $clsid = [string](Get-TsfRequiredProperty -Object $textService -Name 'clsid' -Context 'text service metadata')
    $profileId = [string](Get-TsfRequiredProperty -Object $textService -Name 'profileGuid' -Context 'text service metadata')
    $languageSegment = [string](Get-TsfRequiredProperty -Object (Get-TsfRequiredProperty -Object $textService -Name 'language' -Context 'text service metadata') -Name 'profileKeyLanguageSegment' -Context 'language metadata')
    $profileSubkey = [string](Get-TsfRequiredProperty -Object $registry -Name 'profileSubkey' -Context 'registry metadata')
    $comRoot = if ($Scope -eq 'Machine') { [string](Get-TsfRequiredProperty -Object $registry -Name 'machineComRoot' -Context 'registry metadata') } else { [string](Get-TsfRequiredProperty -Object $registry -Name 'userComRoot' -Context 'registry metadata') }
    $tipRoot = if ($Scope -eq 'Machine') { [string](Get-TsfRequiredProperty -Object $registry -Name 'machineTextServiceRoot' -Context 'registry metadata') } else { [string](Get-TsfRequiredProperty -Object $registry -Name 'userTextServiceRoot' -Context 'registry metadata') }
    $comKey = Join-TsfRegistryPath -Parts @($comRoot, $clsid)
    $tipKey = Join-TsfRegistryPath -Parts @($tipRoot, $clsid)
    $profileKey = Join-TsfRegistryPath -Parts @($tipKey, $profileSubkey, $languageSegment, $profileId)
    $hive = if ($Scope -eq 'Machine') { 'LocalMachine' } else { 'CurrentUser' }
    $view = [string]$ArchitectureSpec.RegistryView
    $operations = @(
        (New-TsfRegistryOperation -Action 'delete' -Hive $hive -View $view -Key $profileKey -Note 'Delete only the KanaAI language-profile key'),
        (New-TsfRegistryOperation -Action 'delete' -Hive $hive -View $view -Key $tipKey -Note 'Delete only the KanaAI TIP key after profile removal'),
        (New-TsfRegistryOperation -Action 'delete' -Hive $hive -View $view -Key $comKey -Note 'Delete only the KanaAI COM class key')
    )
    if ($Scope -eq 'Machine' -and $RemoveUserActivation) {
        $userTipRoot = [string](Get-TsfRequiredProperty -Object $registry -Name 'userTextServiceRoot' -Context 'registry metadata')
        $userProfileKey = Join-TsfRegistryPath -Parts @($userTipRoot, $clsid, $profileSubkey, $languageSegment, $profileId)
        $operations += New-TsfRegistryOperation -Action 'delete' -Hive 'CurrentUser' -View $view -Key $userProfileKey -Note 'Delete the current user activation overlay when explicitly requested'
    }

    $uninstallBlockedReasons = @()
    if (-not $ArchitectureSpec.Supported -and
        -not [string]::IsNullOrWhiteSpace($ArchitectureSpec.BlockedReason)) {
        $uninstallBlockedReasons += $ArchitectureSpec.BlockedReason
    }
    $unregistrationApiOperations = @()
    foreach ($api in @(Get-TsfRequiredProperty -Object $Metadata -Name 'unregistrationApis' -Context 'registration metadata')) {
        $unregistrationApiOperations += [pscustomobject]@{
            Name = [string](Get-TsfRequiredProperty -Object $api -Name 'name' -Context 'unregistration API metadata')
            Required = [bool](Get-TsfRequiredProperty -Object $api -Name 'required' -Context 'unregistration API metadata')
            Purpose = [string](Get-TsfRequiredProperty -Object $api -Name 'purpose' -Context 'unregistration API metadata')
        }
    }

    return [pscustomobject]@{
        SchemaVersion = 1
        Status = 'source-only'
        Mode = 'dry-run'
        DryRun = $true
        Applied = $false
        Action = 'uninstall'
        Scope = $Scope
        Architecture = $ArchitectureSpec.Architecture
        RegistryView = $view
        RegistryViewGuidance = [string]$ArchitectureSpec.RegistryViewGuidance
        RequiresAdministrator = ($Scope -eq 'Machine')
        ProgramFilesRoot = $Location.ProgramFilesRoot
        ProgramFilesRootSource = $Location.ProgramFilesRootSource
        ProgramFilesDisplayName = $Location.ProgramFilesDisplayName
        InstallDirectory = $Location.InstallDirectory
        TipDllPath = $Location.TipDllPath
        Clsid = $clsid
        ProfileGuid = $profileId
        LanguageSegment = $languageSegment
        RegistryKeys = [pscustomobject]@{
            Com = $comKey
            TextService = $tipKey
            Profile = $profileKey
        }
        RegistryOperations = @($operations)
        ApiOperations = @($unregistrationApiOperations)
        BlockingReasons = @($uninstallBlockedReasons)
        CanApply = [bool]$ArchitectureSpec.Supported
        TipDllPresent = $false
        WindowsTestsPassed = $false
        RuntimeVerified = $false
        Registered = $false
        RegistrationComplete = $false
    }
}

function Assert-TsfRegistryKey {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Clsid,
        [Parameter(Mandatory = $true)][string]$ProfileGuid
    )

    $normalizedKey = $Key.Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($normalizedKey) -or $normalizedKey.Contains('..') -or $normalizedKey.StartsWith('\') -or $normalizedKey.Contains(';')) {
        throw "Unsafe TSF registry subkey: $Key"
    }
    $allowed = @(
        "Software\Classes\CLSID\$Clsid",
        "SOFTWARE\Classes\CLSID\$Clsid",
        "Software\Microsoft\CTF\TIP\$Clsid",
        "SOFTWARE\Microsoft\CTF\TIP\$Clsid"
    )
    $isAllowed = $false
    foreach ($prefix in $allowed) {
        if ($normalizedKey -ieq $prefix -or $normalizedKey.StartsWith($prefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isAllowed = $true
            break
        }
    }
    if (-not $isAllowed) {
        throw "Registry key is outside the KanaAI TSF registration surface: $Key"
    }
    if ($normalizedKey -match '\\LanguageProfile\\' -and
        $normalizedKey.IndexOf($ProfileGuid, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Language-profile key does not contain the KanaAI profile GUID: $Key"
    }
    if ($normalizedKey -notmatch '\\LanguageProfile\\' -and
        $normalizedKey.IndexOf($Clsid, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Registry key does not contain the KanaAI CLSID: $Key"
    }
}

function Get-TsfRegistryHive {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        return [System.Enum]::Parse([Microsoft.Win32.RegistryHive], $Name, $true)
    }
    catch {
        throw "Unsupported registry hive '$Name'."
    }
}

function Get-TsfRegistryView {
    # The names are parsed rather than relying on the bitness of the current
    # PowerShell host. Registry64 is the x64 view; Registry32 is reserved for
    # the future x86 TIP and is equivalent to reg.exe /reg:32.
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        return [System.Enum]::Parse([Microsoft.Win32.RegistryView], $Name, $true)
    }
    catch {
        throw "Unsupported registry view '$Name'. Use Registry64 or Registry32."
    }
}

function Set-TsfRegistryOperation {
    param([Parameter(Mandatory = $true)]$Operation)

    Assert-TsfRegistryKey -Key ([string]$Operation.Key) -Clsid $script:TsfRegistrationClassId -ProfileGuid $script:TsfRegistrationProfileId
    $hive = Get-TsfRegistryHive -Name ([string]$Operation.Hive)
    $view = Get-TsfRegistryView -Name ([string]$Operation.View)
    $base = $null
    $key = $null
    try {
        $keyPath = ([string]$Operation.Key).Replace('/', '\')
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
        $key = $base.CreateSubKey($keyPath)
        if ($null -eq $key) {
            throw "Could not create registry key: $($Operation.Key)"
        }
        $value = $Operation.Value
        switch ([string]$Operation.Type) {
            'REG_DWORD' {
                $key.SetValue([string]$Operation.Name, [int]$value, [Microsoft.Win32.RegistryValueKind]::DWord)
            }
            'REG_SZ' {
                $key.SetValue([string]$Operation.Name, [string]$value, [Microsoft.Win32.RegistryValueKind]::String)
            }
            default {
                throw "Unsupported registry value type in operation: $($Operation.Type)"
            }
        }
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Remove-TsfRegistryOperation {
    param([Parameter(Mandatory = $true)]$Operation)

    Assert-TsfRegistryKey -Key ([string]$Operation.Key) -Clsid $script:TsfRegistrationClassId -ProfileGuid $script:TsfRegistrationProfileId
    $hive = Get-TsfRegistryHive -Name ([string]$Operation.Hive)
    $view = Get-TsfRegistryView -Name ([string]$Operation.View)
    $base = $null
    $probe = $null
    try {
        $keyPath = ([string]$Operation.Key).Replace('/', '\')
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
        $probe = $base.OpenSubKey($keyPath, $false)
        if ($null -eq $probe) {
            return $false
        }
        $probe.Dispose()
        $probe = $null
        $base.DeleteSubKeyTree($keyPath)
        return $true
    }
    finally {
        if ($null -ne $probe) { $probe.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Assert-TsfApplyEnvironment {
    param(
        [Parameter(Mandatory = $true)]$ArchitectureSpec,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)]$Readiness,
        [string]$TipDllPath = '',
        [string]$InstallRoot = ''
    )

    if (-not $ArchitectureSpec.Supported) {
        throw "Architecture '$($ArchitectureSpec.Architecture)' is not implemented: $($ArchitectureSpec.BlockedReason)"
    }
    if (-not $Readiness.IdentityApproved) {
        throw 'Registration is blocked until the provisional TSF CLSID/profile identity is explicitly approved.'
    }
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw 'Applying TSF registration is Windows-only. Use the default dry-run on non-Windows hosts.'
    }
    if ($ArchitectureSpec.Architecture -eq 'x64' -and
        (-not [System.Environment]::Is64BitOperatingSystem -or -not [System.Environment]::Is64BitProcess)) {
        throw 'The x64 TIP must be applied from a 64-bit PowerShell process on 64-bit Windows. Use a 64-bit host; do not rely on WOW64 redirection.'
    }
    if (-not $Readiness.TipDllExists -or -not $Readiness.TipDllValid) {
        throw 'Registration is blocked: a real, architecture-correct TIP DLL is required. Registry metadata alone is not a TIP.'
    }
    if (-not $Readiness.WindowsTestsPassed) {
        throw 'Registration is blocked until the Windows registration/application test receipt passes. Registry templates do not establish readiness.'
    }
    if ([string]::IsNullOrWhiteSpace($TipDllPath) -or $TipDllPath -match '^<[^>]+>') {
        throw 'The TIP DLL path must be resolved before applying registration.'
    }
    if ($Scope -eq 'Machine') {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Machine-wide TSF registration requires an elevated administrator PowerShell session.'
        }
    }
}

function Write-TsfPlan {
    param([Parameter(Mandatory = $true)]$Plan)

    Write-Host 'KanaAI TSF registration plan (source-only; no runtime claim):'
    Write-Host ("  Action: {0}; Scope: {1}; Architecture: {2}; Registry view: {3}" -f $Plan.Action, $Plan.Scope, $Plan.Architecture, $Plan.RegistryView)
    if (-not [string]::IsNullOrWhiteSpace([string]$Plan.RegistryViewGuidance)) {
        Write-Host ("  Registry-view guidance: {0}" -f $Plan.RegistryViewGuidance)
    }
    Write-Host ("  Program Files root: {0} ({1}; expected {2})" -f $Plan.ProgramFilesRoot, $Plan.ProgramFilesRootSource, $Plan.ProgramFilesDisplayName)
    Write-Host ("  TIP DLL: {0}" -f $Plan.TipDllPath)
    Write-Host ("  TIP present: {0}; Windows tests passed: {1}; runtime verified: {2}" -f $Plan.TipDllPresent, $Plan.WindowsTestsPassed, $Plan.RuntimeVerified)
    Write-Host ("  Registration complete: {0}" -f $Plan.RegistrationComplete)
    if ($Plan.BlockingReasons.Count -gt 0) {
        Write-Host '  Blocking gates:'
        foreach ($reason in @($Plan.BlockingReasons)) {
            Write-Host ("    - {0}" -f $reason)
        }
    }
    Write-Host '  Registry operations (reviewed projection; TSF APIs are still required):'
    foreach ($operation in @($Plan.RegistryOperations)) {
        $valueText = if ($null -eq $operation.Value) { '' } else { [string]$operation.Value }
        Write-Host ("    {0} [{1}/{2}] {3}::{4} = {5}" -f $operation.Action, $operation.Hive, $operation.View, $operation.Key, $operation.Name, $valueText)
    }
    if (@($Plan.ApiOperations).Count -gt 0) {
        Write-Host '  Required TSF API calls:'
        foreach ($api in @($Plan.ApiOperations)) {
            Write-Host ("    - {0}" -f $api.Name)
        }
    }
}

function ConvertTo-TsfPlanJson {
    param([Parameter(Mandatory = $true)]$Plan)
    return ($Plan | ConvertTo-Json -Depth 20)
}
