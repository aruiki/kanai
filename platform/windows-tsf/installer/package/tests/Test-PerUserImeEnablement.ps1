# Must the installer enable the input method for the user who installs it?
#
# The defect this pins down
# -------------------------
# Measured on 2026-09-28 on the implementation host, after the AI-bundled MSI
# had been installed:
#
#   HKU\S-1-5-18   (LOCAL SERVICE)  ...\LanguageProfile\0x00000411\{...}\Enable = 1
#   HKU\.DEFAULT                                   ...\Enable = 1
#   HKU\S-1-5-21-...-1001  (the interactive user)   ...\Enable = ABSENT
#
# The MSI's EnableProfile custom action is declared Execute="commit"
# Impersonate="yes" (KanaAI.wxs), and its DLL entry calls InstallLayoutOrTip. The
# record it produced landed in another account's hive. The user who installed
# KanaAI therefore never had the input method enabled for their own session,
# which is exactly what the one-click requirement forbids: after Setup.exe the
# input method has to be available without a manual registry step.
#
# What this test asserts, in two phases
# -------------------------------------
# Phase 1 reads the authoring and checks that it names the product's text
# service, the CTF TIP path, an Enable=1 value, and a component carrying it.
#
# Phase 2 does what phase 1 provably cannot do: it compiles the authoring with
# the same WiX this product is built with, and then reads the compiled MSI's
# Registry and FeatureComponents tables.
#
# Phase 2 is not padding. The first version of this test was phase 1 only, and
# it reported PASS on an authoring that WiX 5 refuses to compile at all:
# "error WIX0004: The Component element contains an unexpected attribute
# 'Root'". A green text check said nothing about whether the package built.
#
# The Root value is asserted as 1, which is HKEY_CURRENT_USER in the MSI
# Registry table. That is measured, not remembered: a per-user MSI built with
# WiX Root="HKCU" compiles to a row with Root=1, and a real per-user install of
# it logs "RegOpenKey(Root=-2147483647)" and lands the value under HKCU with
# nothing under HKLM. WiX's own legal values are HKMU, HKCR, HKCU, HKLM, HKU
# and they compile to -1, 0, 1, 2, 3 in that order. Believing instead that
# Root=1 means HKEY_LOCAL_MACHINE would have rejected a correct fix and shipped
# the defect, so the fact is spelled out here rather than left to be recalled.
#
# Phase 2 is not optional. If WiX is missing the test fails rather than
# degrading to phase 1, because a silent degradation to the phase that has
# already been shown to be blind is the exact failure this test exists to stop.
#
# ASCII only on purpose: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI,
# and non-ASCII in a script file is decoded with this machine's code page.
param(
    [string]$Authoring = '',
    [string]$Wix = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($Authoring)) {
    # The authoring is beside this tests directory, so it is named relative to
    # it. Walking up towards a repository root and joining a path back down is
    # a way to get the wrong directory, and did, twice.
    $Authoring = Join-Path $PSScriptRoot '..\KanaAI.wxs'
}
if (-not (Test-Path -LiteralPath $Authoring -PathType Leaf)) {
    throw "installer authoring not found: $Authoring"
}
if ([string]::IsNullOrWhiteSpace($Wix)) {
    # Walk up to the repository root by its markers rather than by counting
    # levels. Counting was done twice here and got it wrong twice:
    # tests -> package -> installer -> windows-tsf -> platform -> root.
    $repo = $PSScriptRoot
    for ($i = 0; $i -lt 12; $i++) {
        if ((Test-Path -LiteralPath (Join-Path $repo 'AGENTS.md')) -and (Test-Path -LiteralPath (Join-Path $repo 'platform\windows-tsf'))) { break }
        $parent = Split-Path -Parent $repo
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $repo) { break }
        $repo = $parent
    }
    $Wix = Join-Path $repo '.local\wix\wix.exe'
}

# The identity the per-user record must be written under: the text service and
# profile the product registers, as compiled after patch 0002.
$tip = '{7E7B5C1E-6D3A-4F2C-9A0E-3F4B5D6C7E81}'
$profile = '{F3C2B7A1-6D54-4E8B-9A10-2C7D8E9F0A12}'
$componentId = 'EnableKanaAiForCurrentUser'

# ---------------------------------------------------------------------------
# Phase 1: the authoring
# ---------------------------------------------------------------------------
$text = Get-Content -LiteralPath $Authoring -Raw
$findings = @()

$hasCtfTipKey = $text -match 'Microsoft\\CTF'
if ($hasCtfTipKey) { $findings += 'a CTF TIP registry path appears in the authoring' }
else { $findings += 'NO CTF TIP registry path: the authoring never names the input method registration hive' }

$hasGuidInKey = $text -match ('Key="[^"]*' + [regex]::Escape($tip))
if ($hasGuidInKey) { $findings += 'the KanaAI text service GUID appears in a registry Key path' }
else { $findings += 'the KanaAI text service GUID does not appear in any registry Key path' }

$hasEnableValue = $text -match 'Name="Enable"' -and $text -match 'Value="1"'
if ($hasEnableValue) { $findings += 'an Enable=1 registry value is authored' }
else { $findings += 'NO Enable=1 registry value is authored' }

$hasHkcu = $text -match 'Root="HKCU"'
if ($hasHkcu) { $findings += 'the record is rooted at HKCU' }
else { $findings += 'NO Root="HKCU": the record is not authored for the installing user' }

$hasProfile = $text -match [regex]::Escape($profile)
if (-not $hasProfile) { $findings += 'the KanaAI profile GUID does not appear in the authoring' }

$hasComponent = $text -match ('Id="' + [regex]::Escape($componentId) + '"')
$hasComponentRef = $text -match ('<ComponentRef\s+Id="' + [regex]::Escape($componentId) + '"')
if ($hasComponent -and $hasComponentRef) { $findings += ('the component is defined and referenced by a feature') }
else { $findings += ('the component is not both defined and feature-referenced (defined={0}, referenced={1})' -f $hasComponent, $hasComponentRef) }

Write-Host ''
Write-Host '=== phase 1: what the authoring says ==='
foreach ($f in $findings) { Write-Host ('  ' + $f) }

$phase1Required = @($hasCtfTipKey, $hasGuidInKey, $hasEnableValue, $hasHkcu, $hasComponent, $hasComponentRef, $hasProfile)
$phase1Missing = @($phase1Required | Where-Object { -not $_ }).Count
Write-Host ("  required {0}, missing {1}" -f $phase1Required.Count, $phase1Missing)
if ($phase1Missing -gt 0) {
    Write-Host ''
    Write-Host 'Status           : FAIL (authoring phase 1)'
    throw ("The installer does not enable the input method for the user who installs it: {0} of {1} required authoring facts are absent. Measured on this host, the record the installer wrote landed under HKU\S-1-5-18 and HKU\.DEFAULT, and not in the interactive user's hive." -f $phase1Missing, $phase1Required.Count)
}

# ---------------------------------------------------------------------------
# Phase 2: the compiled package
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Wix -PathType Leaf)) {
    Write-Host ''
    Write-Host ("wix not found    : {0}" -f $Wix)
    Write-Host ''
    Write-Host 'Status           : FAIL (phase 2 could not run)'
    throw 'Phase 2 could not run because the WiX compiler is missing. Phase 1 alone is not sufficient: it reported PASS on an authoring that WiX 5 rejects with WIX0004. Failing loudly is better than silently testing less.'
}

$work = Join-Path $env:LOCALAPPDATA ('KanaAI\per-user-enable-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    Copy-Item -LiteralPath $Authoring -Destination (Join-Path $work 'KanaAI.wxs') -Force

    # Stand in for the RuntimeFiles fragment the real builder generates from the
    # validated runtime manifest. A text check cannot tell whether the authoring
    # links; only the compiler can.
    [System.IO.File]::WriteAllBytes((Join-Path $work 'payload.bin'), [byte[]](1, 2, 3, 4))
    $fragment = @"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Fragment>
    <ComponentGroup Id="RuntimeFiles" Directory="INSTALLFOLDER">
      <Component Id="SyntheticPayload" Guid="{11111111-2222-3333-4444-555555555555}">
        <File Source="$work\payload.bin" KeyPath="yes" />
      </Component>
    </ComponentGroup>
  </Fragment>
</Wix>
"@
    [System.IO.File]::WriteAllText((Join-Path $work 'RuntimeFiles.wxs'), $fragment, (New-Object System.Text.UTF8Encoding($false)))

    # The CustomAction BinaryRef needs a real PE; its DllEntry names are never
    # called by a compile, so any 64 bit system DLL will do.
    $registrar = Join-Path $work 'Registrar.dll'
    $systemDll = Join-Path $env:SystemRoot 'System32\ole32.dll'
    if (-not (Test-Path -LiteralPath $systemDll)) { $systemDll = Join-Path $env:SystemRoot 'System32\notepad.exe' }
    Copy-Item -LiteralPath $systemDll -Destination $registrar -Force

    $msi = Join-Path $work 'test.msi'
    Write-Host ''
    Write-Host '=== phase 2: compiling the authoring with WiX ==='
    $buildOutput = & $Wix build (Join-Path $work 'KanaAI.wxs') (Join-Path $work 'RuntimeFiles.wxs') -arch x64 -d 'Version=0.1.0' -d "HelperPath=$registrar" -o $msi 2>&1
    $buildExit = $LASTEXITCODE
    $buildOutput | ForEach-Object { Write-Host ('  ' + $_) }
    Write-Host ("  wix exit {0}" -f $buildExit)
    if ($buildExit -ne 0 -or -not (Test-Path -LiteralPath $msi)) {
        Write-Host ''
        Write-Host 'Status           : FAIL (authoring does not compile)'
        throw ("WiX rejected the installer authoring (exit {0}). A package that does not build cannot enable anything." -f $buildExit)
    }

    # Windows Installer automation idiom used elsewhere in this repository
    # (build-windows-installer.ps1, Test-AiBrokerPayloadContract.ps1): these
    # objects expose no type information, so every call goes through
    # <object>.GetType().InvokeMember and View.Fetch returns the Record itself.
    function Get-MsiTable([string]$Path, [string]$Sql, [int]$FieldCount) {
        $inv = New-Object -ComObject WindowsInstaller.Installer
        $db = $null
        try {
            $db = $inv.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $inv, @($Path, 0))
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($Sql))
            try {
                $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
                $rows = New-Object System.Collections.ArrayList
                while ($null -ne ($record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null))) {
                    $fields = New-Object 'string[]' $FieldCount
                    for ($i = 1; $i -le $FieldCount; $i++) {
                        $fields[$i - 1] = [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @($i))
                    }
                    [void]$rows.Add($fields)
                }
                return $rows.ToArray()
            }
            finally { $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null }
        }
        finally {
            if ($null -ne $db) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db) }
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($inv)
        }
    }

    Write-Host ''
    Write-Host '=== phase 2: the compiled Registry table rows naming the product ==='
    $regRows = @(Get-MsiTable $msi 'SELECT `Root`,`Key`,`Name`,`Value` FROM `Registry`' 4)
    $hit = @($regRows | Where-Object { $_[1] -like ('*' + $tip.Trim('{', '}') + '*') })
    Write-Host ("  Registry rows total {0}, naming the product text service {1}" -f $regRows.Count, $hit.Count)
    foreach ($row in $hit) { Write-Host ("  Root={0} Key={1} Name={2} Value={3}" -f $row[0], $row[1], $row[2], $row[3]) }

    $problems = @()
    if ($hit.Count -eq 0) { $problems += 'the per-user record is not in the compiled MSI' }
    else {
        # Root 1 is HKEY_CURRENT_USER, measured: see the header of this file.
        if ($hit[0][0] -ne '1') { $problems += ("the record compiles to Root={0}; Root=1 is HKEY_CURRENT_USER" -f $hit[0][0]) }
        if ($hit[0][1] -notlike ('*' + $tip + '*')) { $problems += 'the compiled record is not under the KanaAI text service key' }
        if ($hit[0][1] -notlike ('*' + $profile + '*')) { $problems += 'the compiled record is not under the KanaAI profile key' }
        if ($hit[0][2] -ne 'Enable') { $problems += ("the compiled value is named {0}, not Enable" -f $hit[0][2]) }
    }

    $compRows = @(Get-MsiTable $msi 'SELECT `Component` FROM `Component`' 1)
    $compFound = @($compRows | Where-Object { $_[0] -eq $componentId }).Count
    Write-Host ("  component {0} in compiled MSI: {1}" -f $componentId, ($compFound -gt 0))
    if ($compFound -eq 0) { $problems += 'the component is not in the compiled MSI' }

    $featRows = @(Get-MsiTable $msi 'SELECT `Feature_`,`Component_` FROM `FeatureComponents`' 2)
    $inFeature = @($featRows | Where-Object { $_[1] -eq $componentId }).Count
    Write-Host ("  component referenced by a feature: {0}" -f ($inFeature -gt 0))
    if ($inFeature -eq 0) { $problems += 'the component is not referenced by any feature, so it would never be installed' }

    if ($problems.Count -gt 0) {
        Write-Host ''
        foreach ($p in $problems) { Write-Host ('  PROBLEM: ' + $p) }
        Write-Host ''
        Write-Host 'Status           : FAIL (compiled package phase 2)'
        throw ('The compiled package does not enable the input method for the installing user: ' + ($problems -join '; '))
    }
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host 'Status           : PASS'
exit 0
