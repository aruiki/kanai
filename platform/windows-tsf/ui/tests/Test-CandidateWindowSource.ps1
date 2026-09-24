[CmdletBinding()]
param(
    [string]$UiRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($UiRoot)) {
    $UiRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}
$UiRoot = [System.IO.Path]::GetFullPath($UiRoot)

function Get-RequiredFile {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $path = Join-Path $UiRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required candidate UI file is missing: $path"
    }
    return $path
}

function Get-SourceText {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    return [System.IO.File]::ReadAllText((Get-RequiredFile $RelativePath))
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Static candidate UI check failed ($Description); missing: $Needle"
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0) {
        throw "Static candidate UI check failed ($Description); found forbidden: $Needle"
    }
}

$required = @(
    'README.md',
    'broker_dto.h',
    'broker-contract.json',
    'candidate_window.h',
    'candidate_window.cpp',
    'candidate_window_geometry.h',
    'candidate_window_geometry.cpp',
    'candidate_window_uia.h',
    'candidate_window_uia.cpp',
    'BUILD.bazel',
    'MODULE.bazel',
    'CMakeLists.txt',
    'tests/Test-CandidateWindowSource.ps1',
    'tests/test_candidate_window_source.py'
)
foreach ($relative in $required) {
    Get-RequiredFile $relative | Out-Null
}

$windowHeader = Get-SourceText 'candidate_window.h'
$windowSource = Get-SourceText 'candidate_window.cpp'
$geometryHeader = Get-SourceText 'candidate_window_geometry.h'
$geometrySource = Get-SourceText 'candidate_window_geometry.cpp'
$dtoHeader = Get-SourceText 'broker_dto.h'
$uiaHeader = Get-SourceText 'candidate_window_uia.h'
$uiaSource = Get-SourceText 'candidate_window_uia.cpp'
$buildText = (Get-SourceText 'BUILD.bazel') + "`n" + (Get-SourceText 'CMakeLists.txt')
$readme = Get-SourceText 'README.md'

$checks = @(
    @{ Name = 'owned native popup'; Text = $windowSource; Needles = @('CreateWindowExW', 'WS_EX_TOOLWINDOW', 'WS_EX_NOACTIVATE', 'owner_') },
    @{ Name = 'non-activating presentation'; Text = $windowSource; Needles = @('SW_SHOWNOACTIVATE', 'SWP_NOACTIVATE') },
    @{ Name = 'DPI APIs'; Text = $windowSource; Needles = @('GetDpiForWindow', 'GetDpiForSystem', 'AdjustWindowRectExForDpi', 'WM_DPICHANGED', 'MonitorFromPoint', 'GetMonitorInfoW') },
    @{ Name = 'placement arithmetic'; Text = $geometrySource; Needles = @('PlaceCandidateWindow', 'work_area', 'below_caret', 'ClampWorkCoordinate') },
    @{ Name = 'keyboard navigation'; Text = $windowSource; Needles = @('WM_KEYDOWN', 'VK_UP', 'VK_DOWN', 'VK_PRIOR', 'VK_NEXT', 'VK_HOME', 'VK_END', 'VK_RETURN', 'VK_ESCAPE') },
    @{ Name = 'candidate rendering'; Text = $windowSource; Needles = @('WM_PAINT', 'CreateCompatibleDC', 'DrawTextW', 'DT_END_ELLIPSIS', 'GetSysColor(COLOR_HIGHLIGHT)') },
    @{ Name = 'light dismiss and focus loss'; Text = $windowSource; Needles = @('SetWinEventHook', 'EVENT_SYSTEM_FOREGROUND', 'EVENT_OBJECT_FOCUS', 'UnhookWinEvent', 'WM_KILLFOCUS', 'WM_ACTIVATEAPP') },
    @{ Name = 'UIA hand-off'; Text = $windowSource + "`n" + $uiaSource; Needles = @('WM_GETOBJECT', 'UiaReturnRawElementProvider', 'IRawElementProviderSimple', 'UIA_AutomationIdPropertyId') },
    @{ Name = 'UIA stub boundary'; Text = $uiaHeader + "`n" + $uiaSource; Needles = @('E_NOTIMPL', 'not a claim', 'candidate item accessibility') },
    @{ Name = 'broker DTO generation'; Text = $dtoHeader; Needles = @('kBrokerDtoVersion', 'generation', 'request_id', 'candidate_id', 'CandidateCommandDto') },
    @{ Name = 'broker DTO encoding assumptions'; Text = $dtoHeader; Needles = @('UTF-16', 'opaque', 'never be persisted', 'must not infer') },
    @{ Name = 'source-only boundary'; Text = $windowSource; Needles = @('IsCreated', 'IsVisible', 'SetOwner', 'HandleKeyDown') }
)
foreach ($check in $checks) {
    foreach ($needle in $check.Needles) {
        Assert-Contains $check.Text $needle $check.Name
    }
}

# The candidate slice must not quietly grow a transport, worker, or policy
# engine. Those belong to the TIP/broker layers.
$implementationText = $windowHeader + "`n" + $windowSource + "`n" +
    $geometryHeader + "`n" + $geometrySource + "`n" + $dtoHeader + "`n" +
    $uiaHeader + "`n" + $uiaSource
foreach ($forbidden in @('WinHttpOpen', 'InternetOpen', 'URLDownloadToFile', 'CreateThread', 'std::thread', 'CoInitialize')) {
    Assert-NotContains $implementationText $forbidden 'transport/policy boundary'
}

$contract = Get-SourceText 'broker-contract.json' | ConvertFrom-Json
if ($contract.schemaVersion -ne 1 -or $contract.status -ne 'technical-slice' -or
    $contract.scope -ne 'candidate-window-only' -or
    $contract.generation.required -ne $true -or
    $contract.candidateId.rule -notmatch 'opaque') {
    throw 'Broker contract does not preserve the generation/ID/technical-slice boundary.'
}
if ($contract.notImplementedHere -notcontains 'complete UI Automation child tree and selection events') {
    throw 'Broker contract does not explicitly defer the complete UIA surface.'
}

# Build metadata must cover all source/header units and link only the native
# UI libraries, not a broker/network library.
foreach ($source in @('candidate_window.cpp', 'candidate_window_geometry.cpp', 'candidate_window_uia.cpp')) {
    Assert-Contains $buildText $source 'build metadata source coverage'
}
foreach ($library in @('user32', 'gdi32', 'ole32', 'oleaut32', 'uuid', 'uiautomationcore')) {
    Assert-Contains $buildText $library 'Windows native library metadata'
}
$cmakeText = Get-SourceText 'CMakeLists.txt'
Assert-Contains $cmakeText 'if(NOT WIN32)' 'Windows-only CMake guard'
Assert-Contains $cmakeText 'add_library' 'source-slice library target'
Assert-NotContains $cmakeText 'add_executable' 'no executable/registration target'
Assert-NotContains $cmakeText 'install(' 'no installer action'
Assert-Contains $readme 'technical slice' 'documentation boundary'
Assert-Contains $readme 'not a completed' 'accessibility boundary'

[pscustomobject]@{
    RequiredFiles = $required.Count
    StaticChecks = $checks.Count
    BrokerContractVersion = $contract.schemaVersion
    UiaStatus = 'metadata-provider-stub'
    Status = 'passed'
}
