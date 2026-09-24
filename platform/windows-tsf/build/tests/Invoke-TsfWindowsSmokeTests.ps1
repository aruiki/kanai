# Runs the native portion of the Windows TSF smoke-test contract.
# This runner loads and inspects the TIP DLL, but it deliberately does not
# register it. The caller must provide a real Windows TSF host test for the
# lifecycle/candidate/secure-field/app-container checks.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DllPath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [string]$TestHostPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$buildRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$commonPath = Join-Path $buildRoot 'TsfBuild.Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "TSF smoke-test helpers are missing: $commonPath"
}
. $commonPath

$planPath = Join-Path $buildRoot 'smoke-test-plan.json'
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "TSF smoke-test plan is missing: $planPath"
}
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
$claimPolicy = Get-TsfProperty -Object $plan -Name 'claimPolicy'
$requiredIds = @(Get-TsfArrayProperty -Object $claimPolicy -Name 'requiredTestIds')
if ($requiredIds.Count -eq 0) {
    throw 'The smoke-test plan has no required test IDs.'
}

function Write-TsfSmokeResult {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)]$Tests,
        [string]$Message = ''
    )

    $result = [ordered]@{
        schemaVersion = 1
        status = $Status
        platform = 'windows'
        architecture = 'x64'
        dll = [System.IO.Path]::GetFullPath($DllPath)
        testHost = if ([string]::IsNullOrWhiteSpace($TestHostPath)) { '' } else { [System.IO.Path]::GetFullPath($TestHostPath) }
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        tests = @($Tests)
        message = $Message
    }
    Write-TsfJsonFile -Path $Path -Value $result
}

# Use the shared fallback rather than relying on PowerShell 7's $IsWindows
# automatic variable; Windows PowerShell 5.1 is a supported runner.
[void](Get-TsfWindowsHost)

$resolvedDll = [System.IO.Path]::GetFullPath($DllPath)
if (-not (Test-Path -LiteralPath $resolvedDll -PathType Leaf)) {
    throw "TIP DLL is missing: $resolvedDll"
}

$tests = @()
try {
    $image = Assert-TsfX64PeImage -Path $resolvedDll -RequireDll
    $tests += [pscustomobject]@{
        id = 'pe-x64-pe32plus'
        status = 'passed'
        evidence = ('machine={0}; optionalMagic={1}; isDll={2}' -f $image.MachineName, $image.OptionalMagicHex, $image.IsDll)
    }

    if ($null -eq ('KanaAIWindowsTsfSmokeNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class KanaAIWindowsTsfSmokeNative
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryExW(string fileName, IntPtr file, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeLibrary(IntPtr module);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, BestFitMapping = false, SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr module, string procedureName);
}
'@
    }

    $module = [KanaAIWindowsTsfSmokeNative]::LoadLibraryExW($resolvedDll, [IntPtr]::Zero, [uint32]0x00001000)
    if ($module -eq [IntPtr]::Zero) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "LoadLibraryExW failed for the TIP DLL (Win32 error $errorCode): $resolvedDll"
    }
    try {
        foreach ($export in @('DllGetClassObject', 'DllCanUnloadNow')) {
            $address = [KanaAIWindowsTsfSmokeNative]::GetProcAddress($module, $export)
            if ($address -eq [IntPtr]::Zero) {
                throw "GetProcAddress did not find required TIP export '$export'."
            }
        }
        $tests += [pscustomobject]@{
            id = 'dll-load'
            status = 'passed'
            evidence = 'LoadLibraryExW and GetProcAddress succeeded in a 64-bit Windows process.'
        }
        $tests += [pscustomobject]@{
            id = 'dll-exports'
            status = 'passed'
            evidence = 'The required DllGetClassObject and DllCanUnloadNow COM exports resolved from the loaded module.'
        }
    }
    finally {
        [void][KanaAIWindowsTsfSmokeNative]::FreeLibrary($module)
    }

    if ([string]::IsNullOrWhiteSpace($TestHostPath)) {
        Write-TsfSmokeResult -Path $ResultPath -Status 'failed' -Tests $tests -Message 'A real TSF host test is required. PE loading and export checks alone are not a native TSF runtime test, and no native beta may be claimed.'
        throw 'A real 64-bit Windows TSF host test is required for tsf-host-load, lifecycle, candidate UI, secure-field, app-container, and focus-teardown checks.'
    }

    $resolvedHost = [System.IO.Path]::GetFullPath($TestHostPath)
    if (-not (Test-Path -LiteralPath $resolvedHost -PathType Leaf)) {
        throw "Windows TSF host test does not exist: $resolvedHost"
    }
    $hostResultPath = $ResultPath + '.host.json'
    try {
        if ([System.IO.Path]::GetExtension($resolvedHost).ToLowerInvariant() -eq '.ps1') {
            $hostArguments = @{
                DllPath = $resolvedDll
                ResultPath = $hostResultPath
            }
            & $resolvedHost @hostArguments
            if (-not $?) {
                throw 'Windows TSF host PowerShell test returned a failure status.'
            }
        }
        else {
            & $resolvedHost $resolvedDll $hostResultPath
            if ($LASTEXITCODE -ne 0) {
                throw "Windows TSF host test exited with code $LASTEXITCODE."
            }
        }
    }
    catch {
        Write-TsfSmokeResult -Path $ResultPath -Status 'failed' -Tests $tests -Message $_.Exception.Message
        throw
    }

    if (-not (Test-Path -LiteralPath $hostResultPath -PathType Leaf)) {
        throw "The Windows TSF host test did not write its result contract: $hostResultPath"
    }
    $hostResult = Get-Content -LiteralPath $hostResultPath -Raw | ConvertFrom-Json
    $hostStatus = [string](Get-TsfProperty -Object $hostResult -Name 'status')
    if ($hostStatus -ine 'passed') {
        throw "The Windows TSF host result status was '$hostStatus', not 'passed'."
    }
    $hostTests = @(Get-TsfArrayProperty -Object $hostResult -Name 'tests')
    foreach ($hostTest in $hostTests) {
        $id = [string](Get-TsfProperty -Object $hostTest -Name 'id')
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $tests += $hostTest
        }
    }

    $statusById = @{}
    foreach ($test in $tests) {
        $statusById[[string](Get-TsfProperty -Object $test -Name 'id')] = [string](Get-TsfProperty -Object $test -Name 'status')
    }
    $missing = @()
    foreach ($id in $requiredIds) {
        if (-not $statusById.ContainsKey($id) -or $statusById[$id] -ine 'passed') {
            $missing += $id
        }
    }
    if ($missing.Count -gt 0) {
        Write-TsfSmokeResult -Path $ResultPath -Status 'failed' -Tests $tests -Message ('Required Windows TSF host test(s) not passed: ' + ($missing -join ', '))
        throw ('The Windows TSF host did not pass every required smoke test: ' + ($missing -join ', '))
    }

    Write-TsfSmokeResult -Path $ResultPath -Status 'passed' -Tests $tests -Message 'All required native Windows TSF smoke tests passed.'
}
catch {
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        Write-TsfSmokeResult -Path $ResultPath -Status 'failed' -Tests $tests -Message $_.Exception.Message
    }
    throw
}
