[CmdletBinding()]
param(
    # A real AI-bundled MSI is the strongest supply-side evidence, so the test
    # reads its File table when one is present.  The regression itself does not
    # depend on it: the source-level contradiction below is decided without it.
    [string]$MsiPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# AI-1: the supply/demand contract for the installed local AI.
#
# The broker (demand) names the files it must find under `<exe>\ai\`.  The
# installer (supply) decides which of those names become MSI payload files.  A
# name the broker cannot start without, that the installer never installs, is a
# silent, permanent AI outage: every install validates, every conversion stays on
# the Mozc baseline, and no test notices because each side passes alone.
#
# This test is the only place the two sides meet.  It is offline, it reads
# sources and (when available) a real MSI, and it must be shown to fail on the
# code it is written against before it is trusted.

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..'))
$brokerSource = Join-Path $repository 'crates\kanai-broker\src\bin\kanai-broker\installed_ai.rs'
$localRuntimeSource = Join-Path $repository 'crates\kanai-broker\src\local_runtime.rs'
$buildScript = Join-Path $repository 'scripts\build-windows-installer.ps1'
if ([string]::IsNullOrWhiteSpace($MsiPath)) {
    # The newest AI-bundled MSI, not a hard-coded one. A pinned filename would
    # make this test keep reporting on a stale artifact after a rebuild, which is
    # how a green summary ends up describing a candidate that no longer exists.
    # Directories are ordered by name and the newest that actually holds an MSI
    # wins, so an older candidate is never silently preferred.
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $repository '.local') -Directory |
        Where-Object { $_.Name -like 'installer-ai*' } |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.msi' -File -ErrorAction SilentlyContinue } |
        Sort-Object FullName)
    if ($candidates.Count -eq 0) {
        throw "AI payload contract: no AI-bundled MSI exists under .local\installer-ai*. Pass -MsiPath explicitly, or build one with .local\ai5\build-ai-bundled.ps1. This test will not fall back to a Mozc-only candidate, because that would report a payload that was never built with the AI in it."
    }
    $MsiPath = $candidates[-1].FullName
}
foreach ($path in @($brokerSource, $localRuntimeSource, $buildScript, $PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "AI payload contract source is missing: $path" }
}
foreach ($scriptPath in @($buildScript, $PSCommandPath)) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw (($parseErrors | ForEach-Object { "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)" }) -join "`n")
    }
}

$brokerText = Get-Content -LiteralPath $brokerSource -Raw
$localRuntimeText = Get-Content -LiteralPath $localRuntimeSource -Raw
$buildText = Get-Content -LiteralPath $buildScript -Raw

# The text of a call's argument list, by balanced parentheses, so that a call
# broken over several lines is read whole and a nested call does not end it early.
function Get-BalancedArgumentText([string]$Text, [int]$OpenParenIndex) {
    $depth = 0
    for ($index = $OpenParenIndex; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($character -eq '(') { $depth++ }
        elseif ($character -eq ')') {
            $depth--
            if ($depth -eq 0) { return $Text.Substring($OpenParenIndex + 1, $index - $OpenParenIndex - 1) }
        }
    }
    throw 'AI payload contract: the AI runtime start call has an unbalanced argument list; refusing to guess where it ends.'
}

# ---------------------------------------------------------------- demand side
# The installed local AI root is the `ai` directory beside this executable, and
# the broker starts the runtime from paths derived from it.  So the requirement
# set is: every literal file name that shipped code joins onto an argument of the
# AI startup call.
#
# Anchoring on the *arguments* rather than on one guessed variable matters.  An
# earlier version of this test took the call's first argument as the root; on the
# broken code that argument is `&manifest`, not `&root`, so the extraction found
# nothing and the test passed against the very defect it was written for. Taking
# every argument removes the guess: the broken code joins `manifest-v1.json` and
# `STAGING-RECEIPT.json` onto one of them, and the fixed code joins nothing onto
# any of them.
#
# Only shipped code counts.  A test fixture that deliberately builds a directory
# without a manifest is evidence, not a requirement, and counting it would hide
# the defect rather than report it.
$testModule = $brokerText.IndexOf('#[cfg(test)]')
$productionText = if ($testModule -ge 0) { $brokerText.Substring(0, $testModule) } else { $brokerText }

if ($productionText.IndexOf('.join("ai")', [StringComparison]::Ordinal) -lt 0) {
    throw 'AI payload contract: shipped broker code no longer resolves an installed local AI root as the "ai" directory beside the executable; the demand-side extraction anchor is gone. Re-derive the required-file extraction in this test rather than letting it report an empty requirement set.'
}

$startCallMatch = [regex]::Match(
    $productionText,
    '\bstart_(?:embedded|pinned)_ai_runtime\s*\(')
if (-not $startCallMatch.Success) {
    throw 'AI payload contract: the broker no longer calls an AI runtime start function; the demand-side extraction anchor is gone. Re-derive the required-file extraction in this test rather than letting it report an empty requirement set.'
}
$argumentText = Get-BalancedArgumentText $productionText ($startCallMatch.Index + $startCallMatch.Length - 1)
$startArguments = @([regex]::Matches($argumentText, '[A-Za-z_][A-Za-z0-9_]*') | ForEach-Object { $_.Value } | Select-Object -Unique)
if ($startArguments.Count -eq 0) {
    throw 'AI payload contract: the AI runtime start call exposes no named arguments; the demand-side extraction cannot proceed.'
}

$requiredRelative = @()
$requiredRead = @()
foreach ($argument in $startArguments) {
    $pattern = '(?<![A-Za-z0-9_])' + [regex]::Escape($argument) + '\.join\("(?<file>[^"]+)"\)'
    foreach ($match in [regex]::Matches($productionText, $pattern)) {
        $file = $match.Groups['file'].Value
        if ($requiredRelative -cnotcontains $file) { $requiredRelative += $file }
    }
    # A narrower set: only a name the broker *reads* is a requirement it cannot
    # start without; a join that merely builds a directory is not.  Both sets are
    # reported, and the contract assertions judge the wider one so that a future
    # directory join is visible instead of silently accepted.
    $readPattern = '(?<![A-Za-z0-9_])(?:read_config|read_to_string|File::open)\s*\(\s*&' +
        [regex]::Escape($argument) + '\.join\("(?<file>[^"]+)"\)\s*\)'
    foreach ($match in [regex]::Matches($productionText, $readPattern)) {
        $file = $match.Groups['file'].Value
        if ($requiredRead -cnotcontains $file) { $requiredRead += $file }
    }
}

# --------------------------------------------------------------- supply side
# The installer refuses to make specific staged names into payload files.  Each
# refusal is expressed through a variable, so each variable is resolved back to
# the name it holds, and an unresolvable reference fails loudly instead of being
# skipped.
$stagingReceiptMatch = [regex]::Match(
    $localRuntimeText,
    'PINNED_STAGING_RECEIPT_FILE:\s*&str\s*=\s*"(?<name>[^"]+)"')
if (-not $stagingReceiptMatch.Success) {
    throw 'AI payload contract: PINNED_STAGING_RECEIPT_FILE is no longer a literal in local_runtime.rs; the supply-side refusal cannot be resolved.'
}
$stagingReceiptFile = $stagingReceiptMatch.Groups['name'].Value

$literalAssignments = @{}
foreach ($match in [regex]::Matches(
        $buildText,
        '(?m)^\s*\$(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*''(?<value>[^'']+)''\s*$')) {
    $literalAssignments[$match.Groups['name'].Value] = $match.Groups['value'].Value
}

$refusedRelative = @()
$refusalLines = @([regex]::Matches(
        $buildText,
        '(?m)^.*must never become an MSI payload file\..*$'))
if ($refusalLines.Count -eq 0) {
    throw 'AI payload contract: the installer no longer refuses any staged name from becoming an MSI payload file; the supply-side extraction anchor is gone. Re-derive the refusal extraction in this test rather than letting it report an empty refusal set.'
}
foreach ($line in $refusalLines) {
    $condition = $line.Value
    $rootRef = [regex]::Match($condition, [regex]::Escape('''ai''') + '\s*\+\s*''/''\s*\+\s*\$(?<var>[A-Za-z_][A-Za-z0-9_.]*)')
    if (-not $rootRef.Success) {
        $rootRef = [regex]::Match($condition, '\$aiPayloadRootDirectory\s*\+\s*''/''\s*\+\s*\$(?<var>[A-Za-z_][A-Za-z0-9_.]*)')
    }
    if (-not $rootRef.Success) {
        throw "AI payload contract: a payload refusal no longer names its file through a resolvable reference: $condition"
    }
    $reference = $rootRef.Groups['var'].Value
    $variable = $reference.Split('.')[0]
    $resolved = $null
    if ($reference -eq 'ManifestInfo.ReceiptRelative') { $resolved = $stagingReceiptFile }
    elseif ($literalAssignments.ContainsKey($variable)) { $resolved = [string]$literalAssignments[$variable] }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "AI payload contract: the payload refusal for `$$reference` cannot be resolved to a file name; refusing to skip it."
    }
    if ($refusedRelative -cnotcontains $resolved) { $refusedRelative += $resolved }
}

# ------------------------------------------------------- real MSI File table
$msiEvidence = 'unavailable'
$msiSupplied = @()
$msiPathText = ''
$msiFileRows = 0
if (Test-Path -LiteralPath $MsiPath -PathType Leaf) {
    $msiPathText = [IO.Path]::GetFullPath($MsiPath)
    $msiEvidence = 'read'
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($msiPathText, 0))
    function Invoke-MsiQuery($Database, [string]$Sql) {
        $view = $Database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $Database, @($Sql))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $records = @()
        while ($true) {
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($null -eq $record) { break }
            $fields = @()
            for ($index = 1; $index -le 4; $index++) {
                $fields += [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, $index)
            }
            $records += ,$fields
        }
        return ,$records
    }
    $componentDirectory = @{}
    foreach ($row in (Invoke-MsiQuery $database 'SELECT `Component`,`Directory_` FROM `Component`')) {
        if (-not [string]::IsNullOrWhiteSpace($row[0])) { $componentDirectory[[string]$row[0]] = [string]$row[1] }
    }
    $directoryParent = @{}
    foreach ($row in (Invoke-MsiQuery $database 'SELECT `Directory`,`Directory_Parent` FROM `Directory`')) {
        if (-not [string]::IsNullOrWhiteSpace($row[0])) { $directoryParent[[string]$row[0]] = [string]$row[1] }
    }
    # `Component` is a reserved word in MSI SQL, so the File table's foreign key
    # to the Component table is read as `Component_`.  Measured on this host:
    # selecting `Component` from `File` raises a COM exception, `Component_`
    # returns all 68 rows.
    $fileRows = Invoke-MsiQuery $database 'SELECT `FileName`,`Component_` FROM `File`'
    $msiFileRows = $fileRows.Count
    foreach ($row in $fileRows) {
        # `FileName` is `short|long`; the long form is the installed leaf name.
        $leaf = ([string]$row[0]).Split('|')[-1]
        $directoryId = [string]$componentDirectory[[string]$row[1]]
        $segments = @()
        $cursor = $directoryId
        while (-not [string]::IsNullOrWhiteSpace($cursor)) {
            $segments = @($cursor) + $segments
            if ($cursor -cne 'TARGETDIR') { $cursor = [string]$directoryParent[$cursor] } else { break }
        }
        $relative = (@($segments | Where-Object { $_ -ne 'TARGETDIR' }) + $leaf) -join '/'
        if ($relative -notin $msiSupplied) { $msiSupplied += $relative }
    }
}

# ------------------------------------------------------------- the contract
# Every violation is collected and reported together, so one run of this test
# produces the whole picture instead of the first failure it happens to reach.
$aiRootPrefix = 'ai/'
$requiredAiRelative = @($requiredRelative | ForEach-Object { $aiRootPrefix + $_ })
$requiredReadAiRelative = @($requiredRead | ForEach-Object { $aiRootPrefix + $_ })
$violations = @()

# 1. A name the broker cannot start without must never be on the installer's
#    refusal list.  This is the contradiction that is present in the code today.
$refusedAndRequired = @($requiredRelative | Where-Object { $refusedRelative -ccontains $_ })
if ($refusedAndRequired.Count -gt 0) {
    $violations += ('the broker requires ' + ($refusedAndRequired -join ', ') +
        ' under <exe>\ai\, and the installer refuses to install exactly those names, so the local AI can never start on a real install')
}

# 2. Every name the broker requires must be present in the installed payload.
#    Checked against a real MSI File table when one is available.
$payloadGaps = @()
if ($msiEvidence -eq 'read') {
    foreach ($relative in $requiredAiRelative) {
        $leaf = $relative.Substring($relative.LastIndexOf('/') + 1)
        $supplied = @($msiSupplied | Where-Object { $_ -ceq $relative -or $_.EndsWith('/' + $leaf, [StringComparison]::Ordinal) })
        if ($supplied.Count -eq 0) { $payloadGaps += $relative }
    }
    if ($payloadGaps.Count -gt 0) {
        $violations += ('the broker requires ' + ($payloadGaps -join ', ') +
            " under <exe>\ai\, and the MSI File table ($msiFileRows rows, read from $msiPathText) installs none of them")
    }
}

# 3. An empty requirement set is only acceptable as a decision, not as an
#    accident.  Accepting it without the embedded launch plan present is exactly
#    the vacuous pass this test exists to prevent, so it is refused.
$embeddedSeam = $localRuntimeText -match 'pub fn build_embedded_runtime_launch_plan'
if ($requiredRelative.Count -eq 0 -and -not $embeddedSeam) {
    $violations += ('the broker requires no file under <exe>\ai\, but local_runtime.rs exposes no ' +
        '`build_embedded_runtime_launch_plan`; an empty requirement set is only a valid outcome when the launch plan is ' +
        'embedded at build time, otherwise this test is reporting a broken extraction as a pass')
}

$evidence = [pscustomobject]@{
    Status = $(if ($violations.Count -eq 0) { 'PASS' } else { 'FAIL' })
    StartCallArguments = $startArguments
    RequiredRelative = $requiredAiRelative
    RequiredReadRelative = $requiredReadAiRelative
    RequiredLeafCount = $requiredRelative.Count
    JoinedRelativeCount = $requiredRelative.Count
    RefusedRelative = @($refusedRelative | ForEach-Object { $aiRootPrefix + $_ })
    RefusedAndRequired = $refusedAndRequired
    MsiPayloadEvidence = $msiEvidence
    MsiFileRows = $msiFileRows
    MsiSuppliedSample = @($msiSupplied | Select-Object -First 6)
    MsiPayloadGaps = $payloadGaps
    EmbeddedLaunchPlanSeam = $embeddedSeam
    SupplyRefusalsInspected = $refusalLines.Count
    Violations = $violations
}
# The evidence object is the script's return value, so a caller can format or
# assert on it, and the failure below restates every violation in full.
$evidence

if ($violations.Count -gt 0) {
    throw ('AI payload contract violated: ' + ($violations -join '; ') +
        '. Either the MSI payload must supply every name the broker requires, or the broker must stop requiring them.')
}
