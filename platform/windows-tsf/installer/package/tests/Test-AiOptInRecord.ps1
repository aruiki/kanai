# Does the AI package actually hand the product the opt-in that starts the AI?
#
# The defect this pins down
# -------------------------
# Measured on 2026-09-28 (STATE.md 0-L). The local AI is not missing and not
# broken: with the opt-in supplied by hand it verified its pinned bytes, loaded
# the 1.1 GB model into a child process, bound a loopback port, refused an
# unauthenticated call with 401, and answered completions at p50 226 ms. The
# reason an installed KanaAI never did any of that is that nothing in the
# product ever recorded the opt-in:
#
#   * the text service starts the broker with CreateProcessW and a null
#     environment block, so the child inherits the text service's environment;
#   * KANAI_BROKER_ENHANCEMENT is set nowhere under platform/windows-tsf and
#     nowhere in the pinned Mozc stage tree (grep: 0 hits);
#   * policy() maps an unset setting to Disabled, which is correct;
#   * so every real install ran an AI-bundled product with the AI off.
#
# A 1.1 GB model behind a switch the package never throws is not a shipped AI.
#
# What has to stay true, and why each phase exists
# ------------------------------------------------
# Phase 1 reads both sides of the contract and compares them: the three strings
# the installer writes (build-windows-installer.ps1) against the three the
# broker reads (enhancement_optin.rs). They are in different languages and
# different files, and nothing but this comparison keeps them equal. If they
# drift, the installer records a value the broker reads as unknown, policy()
# fails closed exactly as designed, and the product silently ships an AI that
# never starts - the same failure as before, with a record that looks right.
#
# Phase 1 also checks that the emission is inside the AI branch of the fragment
# generator. A Mozc-only package must not record consent for a model it does
# not contain.
#
# Phase 2 compiles the authoring. A text check cannot say whether WiX accepts
# it: the per-user enablement work measured a text check reporting PASS on
# authoring WiX 5 rejects outright (WIX0004), so the compiled Registry rows are
# read rather than the intended ones assumed.
#
# Root values in the MSI Registry table are measured, not recalled: WiX's HKMU,
# HKCR, HKCU, HKLM, HKU compile to -1, 0, 1, 2, 3. So the machine row is Root=2
# and the user row is Root=1.
#
# Phase 3 runs only when a real candidate MSI is named with -Msi. It reads that
# package's own Registry and FeatureComponents tables, which is the only check
# that speaks about the artifact that will actually be published. With
# -ExpectNoRecord it asserts the opposite for a Mozc-only candidate.
#
# ASCII only on purpose: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.
param(
    [string]$Builder = '',
    [string]$RustModule = '',
    [string]$Wix = '',
    [string]$Msi = '',
    [switch]$ExpectNoRecord
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = $PSScriptRoot
for ($i = 0; $i -lt 12; $i++) {
    if ((Test-Path -LiteralPath (Join-Path $repo 'AGENTS.md')) -and (Test-Path -LiteralPath (Join-Path $repo 'platform\windows-tsf'))) { break }
    $parent = Split-Path -Parent $repo
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $repo) { break }
    $repo = $parent
}
if ([string]::IsNullOrWhiteSpace($Builder)) { $Builder = Join-Path $repo 'scripts\build-windows-installer.ps1' }
if ([string]::IsNullOrWhiteSpace($RustModule)) { $RustModule = Join-Path $repo 'crates\kanai-broker\src\bin\kanai-broker\enhancement_optin.rs' }
if ([string]::IsNullOrWhiteSpace($Wix)) { $Wix = Join-Path $repo '.local\wix\wix.exe' }
foreach ($required in @($Builder, $RustModule)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "required source not found: $required" }
}

function Get-Single([string]$Text, [string]$Pattern, [string]$Label) {
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) { throw ("expected exactly one {0}; found {1}" -f $Label, $matches.Count) }
    return $matches[0].Groups[1].Value
}

# ---------------------------------------------------------------------------
# Phase 1: the two sides of the contract
# ---------------------------------------------------------------------------
$builderText = Get-Content -LiteralPath $Builder -Raw
$rustText = Get-Content -LiteralPath $RustModule -Raw

$builderKey = Get-Single $builderText '(?m)^\$aiOptInRegistryKey\s*=\s*''([^'']+)''' 'installer opt-in key'
$builderName = Get-Single $builderText '(?m)^\$aiOptInRegistryValue\s*=\s*''([^'']+)''' 'installer opt-in value name'
$builderData = Get-Single $builderText '(?m)^\$aiOptInEnabledValue\s*=\s*''([^'']+)''' 'installer opt-in enabled value'

$rustKey = Get-Single $rustText 'const OPT_IN_KEY:\s*&str\s*=\s*r"([^"]+)"' 'broker opt-in key'
$rustName = Get-Single $rustText 'const OPT_IN_VALUE:\s*&str\s*=\s*"([^"]+)"' 'broker opt-in value name'
$rustData = Get-Single $rustText 'const OPT_IN_ENABLED:\s*&str\s*=\s*"([^"]+)"' 'broker opt-in enabled value'

Write-Host ''
Write-Host '=== phase 1: what the installer writes vs what the broker reads ==='
Write-Host ("  installer : {0}\{1} = {2}" -f $builderKey, $builderName, $builderData)
Write-Host ("  broker    : {0}\{1} = {2}" -f $rustKey, $rustName, $rustData)

$problems = @()
if ($builderKey -cne $rustKey) { $problems += ("key mismatch: installer writes '{0}', broker reads '{1}'" -f $builderKey, $rustKey) }
if ($builderName -cne $rustName) { $problems += ("value name mismatch: installer writes '{0}', broker reads '{1}'" -f $builderName, $rustName) }
if ($builderData -cne $rustData) { $problems += ("enabled value mismatch: installer writes '{0}', broker reads '{1}'" -f $builderData, $rustData) }

# The emission has to be in the AI branch. Measured as a text fact about the
# generator: both components appear between the AI guard and the AI payload
# loop that follows it.
$hasMachine = $builderText -match '<Component Id="AiOptInMachine"'
$hasUser = $builderText -match '<Component Id="AiOptInUser"'
if (-not $hasMachine) { $problems += 'the installer never authors the machine opt-in record' }
if (-not $hasUser) { $problems += 'the installer never authors the per-user opt-in record' }

# Containment is checked by matching braces from the guard that precedes the
# emission, not by comparing offsets against a neighbouring line. An offset
# comparison says "it appears somewhere after a guard", which is also true of
# code the guard does not cover, and the whole point of this check is that a
# Mozc-only package must not carry the record.
function Test-InsideAiBranch([string]$Text, [int]$Position) {
    if ($Position -lt 0) { return $false }
    $guard = 'if ($aiRecords.Count -gt 0) {'
    $guardIndex = $Text.LastIndexOf($guard, $Position)
    if ($guardIndex -lt 0) { return $false }
    $depth = 0
    for ($i = $guardIndex + $guard.Length - 1; $i -lt $Text.Length; $i++) {
        $character = $Text[$i]
        if ($character -eq '{') { $depth++ }
        elseif ($character -eq '}') {
            $depth--
            if ($depth -eq 0) { return $Position -lt $i }
        }
    }
    return $false
}

$machineIndex = $builderText.IndexOf('<Component Id="AiOptInMachine"')
$userIndex = $builderText.IndexOf('<Component Id="AiOptInUser"')
if ((Test-InsideAiBranch $builderText $machineIndex) -and (Test-InsideAiBranch $builderText $userIndex)) {
    Write-Host '  emitted only when the AI payload is present: yes'
}
else {
    $problems += 'the opt-in records are not emitted inside the AI-payload branch; a Mozc-only package must not record consent for a model it does not ship'
}

if ($problems.Count -gt 0) {
    Write-Host ''
    foreach ($p in $problems) { Write-Host ('  PROBLEM: ' + $p) }
    Write-Host ''
    Write-Host 'Status           : FAIL (phase 1)'
    throw ('The installer and the broker do not agree on the local AI opt-in: ' + ($problems -join '; '))
}

# ---------------------------------------------------------------------------
# Phase 2: the compiled rows
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Wix -PathType Leaf)) {
    Write-Host ''
    Write-Host ("wix not found    : {0}" -f $Wix)
    Write-Host ''
    Write-Host 'Status           : FAIL (phase 2 could not run)'
    throw 'Phase 2 could not run because the WiX compiler is missing. Phase 1 alone has already been shown, on the per-user enablement work, to report PASS on authoring WiX rejects.'
}

# A package that authors no registry rows at all has no `Registry` table, and
# `OpenView` on a table that is not there throws rather than returning nothing.
# That case is not an error here: it is a package with no opt-in row, which is
# precisely what -ExpectNoRecord asserts and what a pre-fix AI candidate looks
# like. Absence is therefore answered from `_Tables` and reported as zero rows,
# while any other failure is still allowed to throw.
function Test-MsiTable([string]$Path, [string]$Table) {
    return @(Get-MsiTable $Path ('SELECT `Name` FROM `_Tables` WHERE `Name` = ''' + $Table + '''') 1).Count -gt 0
}

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

$work = Join-Path $env:LOCALAPPDATA ('KanaAI\ai-optin-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    # The authoring under test is built from the constants phase 1 just read, so
    # this phase compiles the same strings the builder emits rather than a
    # hand-copied pair that could agree with nothing.
    $authoring = @"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="KanaAI AI opt-in authoring probe" Manufacturer="KanaAI Project" Version="0.1.0"
           UpgradeCode="{9E7E4E2E-2C86-4C2A-9A47-3F0F7A2C7B55}" Language="1041" Scope="perMachine" InstallerVersion="500">
    <MediaTemplate EmbedCab="yes" />
    <StandardDirectory Id="ProgramFiles64Folder"><Directory Id="INSTALLFOLDER" Name="KanaAI" /></StandardDirectory>
    <Feature Id="Core" Title="KanaAI" Level="1">
      <ComponentRef Id="AiOptInMachine" />
      <ComponentRef Id="AiOptInUser" />
    </Feature>
    <Component Id="AiOptInMachine" Guid="{FCB097CA-F4F9-4BFC-8913-DB22F532F290}" Bitness="always64" Directory="INSTALLFOLDER">
      <RegistryKey Root="HKLM" Key="$builderKey"><RegistryValue Name="$builderName" Type="string" Value="$builderData" KeyPath="yes" /></RegistryKey>
    </Component>
    <Component Id="AiOptInUser" Guid="{7A41AEBC-03F6-4A3A-BB92-21B64D886CBD}" Directory="INSTALLFOLDER">
      <RegistryKey Root="HKCU" Key="$builderKey"><RegistryValue Name="$builderName" Type="string" Value="$builderData" KeyPath="yes" /></RegistryKey>
    </Component>
  </Package>
</Wix>
"@
    $probe = Join-Path $work 'probe.wxs'
    [System.IO.File]::WriteAllText($probe, $authoring, (New-Object System.Text.UTF8Encoding($false)))
    $probeMsi = Join-Path $work 'probe.msi'

    Write-Host ''
    Write-Host '=== phase 2: compiling the opt-in authoring with WiX ==='
    $buildOutput = & $Wix build $probe -arch x64 -o $probeMsi 2>&1
    $buildExit = $LASTEXITCODE
    $buildOutput | ForEach-Object { Write-Host ('  ' + $_) }
    Write-Host ("  wix exit {0}" -f $buildExit)
    if ($buildExit -ne 0 -or -not (Test-Path -LiteralPath $probeMsi)) {
        Write-Host ''
        Write-Host 'Status           : FAIL (opt-in authoring does not compile)'
        throw ("WiX rejected the opt-in authoring (exit {0})." -f $buildExit)
    }

    $rows = @(Get-MsiTable $probeMsi 'SELECT `Root`,`Key`,`Name`,`Value` FROM `Registry`' 4)
    $hit = @($rows | Where-Object { $_[1] -ieq $builderKey -and $_[2] -ieq $builderName })
    foreach ($row in $hit) { Write-Host ("  Root={0} Key={1} Name={2} Value={3}" -f $row[0], $row[1], $row[2], $row[3]) }

    $phase2 = @()
    # Root 2 is HKEY_LOCAL_MACHINE and Root 1 is HKEY_CURRENT_USER. See header.
    if (@($hit | Where-Object { $_[0] -eq '2' -and $_[3] -ceq $builderData }).Count -ne 1) { $phase2 += 'no single HKLM row carrying the enabled value' }
    if (@($hit | Where-Object { $_[0] -eq '1' -and $_[3] -ceq $builderData }).Count -ne 1) { $phase2 += 'no single HKCU row carrying the enabled value' }
    if ($phase2.Count -gt 0) {
        Write-Host ''
        foreach ($p in $phase2) { Write-Host ('  PROBLEM: ' + $p) }
        Write-Host ''
        Write-Host 'Status           : FAIL (phase 2)'
        throw ('The compiled opt-in rows are not what the broker reads: ' + ($phase2 -join '; '))
    }
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# Phase 3: the real candidate, when one is named
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($Msi)) {
    if (-not (Test-Path -LiteralPath $Msi -PathType Leaf)) { throw "candidate MSI not found: $Msi" }
    Write-Host ''
    Write-Host '=== phase 3: the candidate package ==='
    Write-Host ("  {0}" -f $Msi)
    $rows = @()
    if (Test-MsiTable $Msi 'Registry') { $rows = @(Get-MsiTable $Msi 'SELECT `Root`,`Key`,`Name`,`Value` FROM `Registry`' 4) }
    else { Write-Host '  the package authors no registry rows at all (no Registry table)' }
    $hit = @($rows | Where-Object { $_[1] -ieq $builderKey -and $_[2] -ieq $builderName })
    foreach ($row in $hit) { Write-Host ("  Root={0} Key={1} Name={2} Value={3}" -f $row[0], $row[1], $row[2], $row[3]) }

    $phase3 = @()
    if ($ExpectNoRecord) {
        if ($hit.Count -ne 0) { $phase3 += ("a package without an AI payload records {0} opt-in rows" -f $hit.Count) }
        else { Write-Host '  no opt-in row, which is correct for a package with no model' }
    }
    else {
        if (@($hit | Where-Object { $_[0] -eq '2' -and $_[3] -ceq $builderData }).Count -ne 1) { $phase3 += 'the candidate has no machine-default opt-in row' }
        if (@($hit | Where-Object { $_[0] -eq '1' -and $_[3] -ceq $builderData }).Count -ne 1) { $phase3 += 'the candidate has no per-user opt-in row' }
        $featRows = @(Get-MsiTable $Msi 'SELECT `Feature_`,`Component_` FROM `FeatureComponents`' 2)
        foreach ($component in @('AiOptInMachine', 'AiOptInUser')) {
            $referenced = @($featRows | Where-Object { $_[1] -eq $component }).Count
            Write-Host ("  {0} referenced by a feature: {1}" -f $component, ($referenced -gt 0))
            if ($referenced -eq 0) { $phase3 += ("{0} is in no feature, so it would never be installed" -f $component) }
        }
    }
    if ($phase3.Count -gt 0) {
        Write-Host ''
        foreach ($p in $phase3) { Write-Host ('  PROBLEM: ' + $p) }
        Write-Host ''
        Write-Host 'Status           : FAIL (phase 3)'
        throw ('The candidate package does not supply the opt-in the broker reads: ' + ($phase3 -join '; '))
    }
}

Write-Host ''
Write-Host 'Status           : PASS'
exit 0
