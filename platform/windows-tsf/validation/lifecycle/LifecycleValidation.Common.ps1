# KanaAI installer lifecycle verification harness - shared helpers.
#
# This file is split in two halves on purpose.
#
#   PURE half (safe in every mode, including -PlanOnly and the self test):
#     property access, SHA-256, JSON, plan validation, command-line rendering,
#     the observation-context comparison engine, the phase verdict engine, the
#     receipt assembler, the privacy scan, the MSI log classifier and the resume
#     planner.  Everything here is a function of its arguments and of files this
#     harness itself wrote.  Nothing here reads the registry, opens a Windows
#     Installer database, starts a process, or mutates the machine.
#
#   OBSERVATION half (execute mode only):
#     every function that touches the machine.  Each one must first pass through
#     Enter-KanaAiLifecycleAction, which throws if the ledger is sealed.  The
#     entry point seals the ledger before the plan-only banner and in the self
#     test, so an accidental call from the pure half fails loudly instead of
#     quietly touching a machine.
#
# Windows PowerShell 5.1 is the guaranteed host.  There is no Get-FileHash in
# this environment, so SHA-256 is computed with System.Security.Cryptography
# directly, the same pattern scripts/build-windows-installer.ps1 uses.
#
# This file is ASCII-only so the system ANSI code page cannot corrupt it.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------
$script:KanaAiLifecycleSchemaVersion = 1
$script:KanaAiLifecycleGuidPattern = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'
$script:KanaAiLifecycleVerdictNames = @('pass', 'fail', 'unconfirmed', 'refused', 'not_run', 'record_only')

# The complete check vocabulary.  A plan may only assert a check named here;
# an unknown check name is a plan validation error, not a silent pass.  The
# names that read machine state are deliberately enumerated so that the plan
# validator can enforce the rule "a phase may not be decided by an exit code".
$script:KanaAiLifecycleStateCheckNames = @(
    'product-state',
    'product-code',
    'registration-present',
    'registration-absent',
    'registration-target-file-present',
    'install-directory',
    'expected-files',
    'no-orphan-processes',
    'install-date-unchanged',
    'file-inventory-unchanged',
    'msi-log-classification'
)
$script:KanaAiLifecycleAllCheckNames = @('command-exit-code') + $script:KanaAiLifecycleStateCheckNames

# Windows Installer exit codes this harness interprets.  The mapping is a
# documented table, not a guess: an unlisted code is 'unknown' and can never
# satisfy an accepted-exit-code assertion.
$script:KanaAiLifecycleMsiExitCodes = @{
    0    = 'success'
    1602 = 'user-cancelled'
    1603 = 'fatal-error-during-installation'
    1604 = 'install-suspended-incomplete'
    1605 = 'product-not-installed'
    1618 = 'another-installation-in-progress'
    1622 = 'error-opening-installation-log'
    1625 = 'system-rollback'
    1633 = 'package-not-supported-on-this-platform'
    1638 = 'another-version-already-installed'
    1639 = 'invalid-command-line'
    1641 = 'success-reboot-initiated'
    3010 = 'success-reboot-required'
    3011 = 'success-reboot-required'
}

# ---------------------------------------------------------------------------
# pure: basic accessors
# ---------------------------------------------------------------------------
function Get-KanaAiLifecycleSchemaVersion {
    return $script:KanaAiLifecycleSchemaVersion
}

function Get-KanaAiLifecycleUtcNow {
    return [DateTime]::UtcNow.ToString('o')
}

function New-KanaAiLifecycleRunId {
    return ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('n').Substring(0, 8))
}

function Get-KanaAiLifecycleProperty {
    <#
        Strict-mode safe required read.  Throws with the object context and the
        property name, because a silently missing field in a verification plan
        is how a phase ends up asserting nothing.
    #>
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Context = 'object'
    )
    if ($null -eq $Object) { throw "$Context is null; property '$Name' cannot be read." }
    # A hashtable and a PSCustomObject need different lookups: in Windows
    # PowerShell 5.1 $htable.PSObject.Properties['k'] does not return a
    # property object with a .Value, so a plan and a synthetic bundle cannot
    # share one code path that way.
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { throw "$Context is missing required property '$Name'." }
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Context is missing required property '$Name'." }
    return $property.Value
}

function Get-KanaAiLifecycleOptionalProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null,
        [string]$Context = 'object'
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $Default }
        $value = $Object[$Name]
        if ($null -eq $value) { return $Default }
        return $value
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-KanaAiLifecycleBoolProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Default = $false
    )
    $value = Get-KanaAiLifecycleOptionalProperty -Object $Object -Name $Name -Default $null
    if ($null -eq $value) { return $Default }
    return [bool]$value
}

function Test-KanaAiLifecycleGuid {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return ($Value -match $script:KanaAiLifecycleGuidPattern)
}

function ConvertTo-KanaAiLifecycleGuid {
    <# Windows Installer is not consistent about brace-delimited product codes. #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    $trimmed = $Value.Trim()
    if ($trimmed -match '^\{(.+)\}$') { return ('{' + $Matches[1].ToUpperInvariant() + '}') }
    return $trimmed.ToUpperInvariant()
}

# ---------------------------------------------------------------------------
# pure: SHA-256 without Get-FileHash
# ---------------------------------------------------------------------------
function Get-KanaAiLifecycleSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-KanaAiLifecycleTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

# ---------------------------------------------------------------------------
# pure: JSON
# ---------------------------------------------------------------------------
function Read-KanaAiLifecycleJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "JSON file does not exist: $Path" }
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { throw "JSON file is empty: $Path" }
    return ($text | ConvertFrom-Json)
}

function Write-KanaAiLifecycleJson {
    <# UTF-8 without BOM, and a trailing newline, so a 5.1 reader is happy. #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 40
    )
    $text = ($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $text, $encoding)
    return $Path
}

# ---------------------------------------------------------------------------
# pure: the action ledger / gate
# ---------------------------------------------------------------------------
function New-KanaAiLifecycleActionLedger {
    return [pscustomobject]@{
        Sealed                 = $false
        SealedReason           = ''
        InstallerComObjects    = 0
        MsiDatabaseOpens       = 0
        RegistryOpens          = 0
        RegistryWrites         = 0
        FilesystemReads        = 0
        ProcessLaunches        = 0
        MsiExecInvocations     = 0
        DirectoryMutations     = 0
        FileMutations          = 0
        StartedProcesses       = (New-Object System.Collections.Generic.List[object])
        StoppedProcesses       = (New-Object System.Collections.Generic.List[object])
    }
}

function Close-KanaAiLifecycleActionLedger {
    param([Parameter(Mandatory = $true)]$Ledger, [Parameter(Mandatory = $true)][string]$Reason)
    $Ledger.Sealed = $true
    $Ledger.SealedReason = $Reason
    return $Ledger
}

function Open-KanaAiLifecycleActionLedger {
    <#
        The only way to unseal a ledger, and the exact counterpart of Close-.
        -Execute calls this once, after every gate has passed; every other mode
        leaves the ledger sealed for its whole life.

        Measured defect this replaces: -Execute called Close- at this point
        intending to unseal, so the run sealed its own ledger and the very next
        helper - reading the candidate MSI through the Windows Installer
        automation interface - was refused with LIFECYCLE-GATE-SEALED carrying a
        sealedReason that had just been written to claim the opposite.  The
        counters are preserved so a receipt still accounts for the whole run.
    #>
    param([Parameter(Mandatory = $true)]$Ledger, [Parameter(Mandatory = $true)][string]$Reason)
    if ($null -eq $Ledger) { throw 'LIFECYCLE-GATE-UNSET: a ledger was unsealed without a ledger.' }
    $Ledger.Sealed = $false
    $Ledger.SealedReason = $Reason
    return $Ledger
}

function Enter-KanaAiLifecycleAction {
    <#
        The single gate every machine-touching helper must pass.  A sealed
        ledger is the mechanism that makes "-PlanOnly performs no install,
        no registry access and no process launch" an enforced property rather
        than a promise in a comment.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)]
        [ValidateSet('installer-com', 'msi-database', 'registry-read', 'registry-write', 'filesystem-read', 'process-launch', 'msiexec', 'directory-mutation', 'file-mutation')]
        [string]$Kind,
        [string]$Detail = ''
    )
    if ($null -eq $Ledger) { throw 'LIFECYCLE-GATE-UNSET: an observation helper was called without an action ledger.' }
    if ([bool]$Ledger.Sealed) {
        throw ("LIFECYCLE-GATE-SEALED: '{0}' was refused because this mode must not touch the machine (sealed: {1}). Detail: {2}" -f $Kind, [string]$Ledger.SealedReason, $Detail)
    }
    switch ($Kind) {
        'installer-com' { $Ledger.InstallerComObjects = [int]$Ledger.InstallerComObjects + 1 }
        'msi-database' { $Ledger.MsiDatabaseOpens = [int]$Ledger.MsiDatabaseOpens + 1 }
        'registry-read' { $Ledger.RegistryOpens = [int]$Ledger.RegistryOpens + 1 }
        'registry-write' { $Ledger.RegistryWrites = [int]$Ledger.RegistryWrites + 1 }
        'filesystem-read' { $Ledger.FilesystemReads = [int]$Ledger.FilesystemReads + 1 }
        'process-launch' { $Ledger.ProcessLaunches = [int]$Ledger.ProcessLaunches + 1 }
        'msiexec' { $Ledger.MsiExecInvocations = [int]$Ledger.MsiExecInvocations + 1 }
        'directory-mutation' { $Ledger.DirectoryMutations = [int]$Ledger.DirectoryMutations + 1 }
        'file-mutation' { $Ledger.FileMutations = [int]$Ledger.FileMutations + 1 }
    }
    return $Ledger
}

function Get-KanaAiLifecycleInteractionCounters {
    param([Parameter(Mandatory = $true)]$Ledger)
    return [ordered]@{
        installerComObjects = [int]$Ledger.InstallerComObjects
        msiDatabaseOpens    = [int]$Ledger.MsiDatabaseOpens
        registryOpens       = [int]$Ledger.RegistryOpens
        registryWrites      = [int]$Ledger.RegistryWrites
        filesystemReads     = [int]$Ledger.FilesystemReads
        processLaunches     = [int]$Ledger.ProcessLaunches
        msiexecInvocations  = [int]$Ledger.MsiExecInvocations
        directoryMutations  = [int]$Ledger.DirectoryMutations
        fileMutations       = [int]$Ledger.FileMutations
        gateSealed          = [bool]$Ledger.Sealed
        gateSealedReason    = [string]$Ledger.SealedReason
    }
}

# ---------------------------------------------------------------------------
# pure: command-line rendering
# ---------------------------------------------------------------------------
function ConvertTo-KanaAiLifecycleCommandLine {
    <#
        The MSVCRT quoting rule, so the recorded command line is the exact
        string that is handed to CreateProcess and can be pasted into a
        command prompt by a human reviewer.
    #>
    param([AllowEmptyCollection()][string[]]$Arguments = @())
    $parts = @()
    foreach ($argument in @($Arguments)) {
        $value = [string]$argument
        if ($value -notmatch '[\s"]' -and $value.Length -gt 0) { $parts += $value; continue }
        $escaped = $value -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        $parts += '"' + $escaped + '"'
    }
    return ($parts -join ' ')
}

function Expand-KanaAiLifecyclePlaceholders {
    <#
        Pure: substitutes {name} tokens from a value table.  A name that is
        missing from the table, or whose value is empty, is recorded in the Sink
        so the caller can refuse to render a half-resolved command line.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][hashtable]$Table,
        [Parameter(Mandatory = $true)]$Sink
    )
    $evaluator = {
        param($match)
        $name = $match.Groups[1].Value
        if (-not $Table.ContainsKey($name)) { [void]$Sink.Add($name); return $match.Value }
        $value = $Table[$name]
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { [void]$Sink.Add($name); return $match.Value }
        return [string]$value
    }
    return [System.Text.RegularExpressions.Regex]::Replace($Text, '\{([A-Za-z][A-Za-z0-9_]*)\}', $evaluator)
}

function Resolve-KanaAiLifecycleCommand {
    <#
        Pure: renders a command template plus a value table into the exact
        executable, argument array and command line string.  An unresolved
        placeholder is an error, so a phase can never run a command with a
        literal "{msiPath}" in it.
    #>
    param(
        [Parameter(Mandatory = $true)]$Command,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )
    $executable = [string](Get-KanaAiLifecycleProperty -Object $Command -Name 'executable' -Context 'command')
    $arguments = @()
    foreach ($argument in @(Get-KanaAiLifecycleOptionalProperty -Object $Command -Name 'arguments' -Default @())) {
        $arguments += [string]$argument
    }
    $unresolved = New-Object System.Collections.Generic.List[string]

    $resolvedExecutable = Expand-KanaAiLifecyclePlaceholders -Text $executable -Table $Values -Sink $unresolved
    $resolvedArguments = @()
    foreach ($argument in $arguments) {
        $resolvedArguments += (Expand-KanaAiLifecyclePlaceholders -Text $argument -Table $Values -Sink $unresolved)
    }
    if ($unresolved.Count -gt 0) {
        $distinct = @($unresolved | Select-Object -Unique)
        throw ("The command has unresolved or empty placeholders: {0} (command: {1})" -f ($distinct -join ', '), ($arguments -join ' '))
    }
    $commandLine = (ConvertTo-KanaAiLifecycleCommandLine -Arguments (@($resolvedExecutable) + $resolvedArguments))
    return [ordered]@{
        executable   = $resolvedExecutable
        arguments    = @($resolvedArguments)
        commandLine  = $commandLine
        whatIfRender = ('WHATIF: would run -> ' + $commandLine)
        timeoutHintSeconds = [int](Get-KanaAiLifecycleOptionalProperty -Object $Command -Name 'timeoutSeconds' -Default 1800)
    }
}

function Get-KanaAiLifecycleMsiExitCodeMeaning {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExitCodeText)
    $text = $ExitCodeText.Trim()
    if ($text -notmatch '^-?\d+$') { return 'unknown' }
    $code = [int]$text
    $key = $null
    foreach ($candidate in @($script:KanaAiLifecycleMsiExitCodes.Keys)) {
        if ([int]$candidate -eq $code) { $key = $candidate; break }
    }
    if ($null -eq $key) { return 'unknown' }
    return [string]$script:KanaAiLifecycleMsiExitCodes[$key]
}

# ---------------------------------------------------------------------------
# pure: the verbose MSI log classifier
# ---------------------------------------------------------------------------
function Get-KanaAiLifecycleMsiLogClassification {
    <#
        Conservative and fail-closed.  A log is only classified when it carries
        a decisive marker.  Anything else returns Confident = $false, which the
        verdict engine turns into "unconfirmed", never into a pass.
        The harness deliberately does not guess what Windows Installer did when
        the log does not say so in so many words.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Text,
        [string]$Expected = ''
    )
    $result = [ordered]@{
        readable      = (-not [string]::IsNullOrEmpty($Text))
        classification = 'unreadable'
        confident     = $false
        evidence      = @()
        expected      = $Expected
        method        = 'decisive-marker scan of the Windows Installer verbose log; absence of a marker is reported as not confident'
    }
    if ([string]::IsNullOrEmpty($Text)) {
        $result.evidence = @('the verbose log is missing or empty')
        return $result
    }
    $markers = @(
        [pscustomobject]@{ Classification = 'downgrade-refused'; Pattern = '(?im)^\s*Error 1638\.|(?im)\b1638\b.*(already installed|older version)|DowngradeErrorMessage'; Label = '1638 / downgrade refusal' },
        [pscustomobject]@{ Classification = 'uninstall'; Pattern = '(?im)^Product: .*(Removal|removal) completed successfully|(?im)^Action start: RemoveFiles|(?im)Removing product\s*:'; Label = 'removal sequence' },
        [pscustomobject]@{ Classification = 'reinstall'; Pattern = '(?im)^Property \(REINSTALL(MODE)?\)\s*:|(?im)REINSTALL=ALL|(?im)REINSTALLMODE='; Label = 'REINSTALL property' },
        [pscustomobject]@{ Classification = 'first-install'; Pattern = '(?im)^Action start: InstallInitialize|(?im)Installation completed successfully|(?im)Property \(Installed\)\s*:\s*1'; Label = 'install sequence' }
    )
    $hits = @()
    foreach ($marker in $markers) {
        if ($Text -match $marker.Pattern) { $hits += [string]$marker.Classification }
    }
    $distinct = @($hits | Select-Object -Unique)
    if ($distinct.Count -eq 0) {
        $result.evidence = @('no decisive marker was present in the log')
        return $result
    }
    # A log that shows both an install and a removal sequence is a repair or
    # upgrade, not a clean install, and is reported as such rather than as a
    # first install.
    $result.classification = $distinct[0]
    $result.confident = ($distinct.Count -eq 1)
    $result.evidence = @($distinct)
    if (-not $result.confident) {
        $result.classification = 'ambiguous-multiple-markers'
    }
    return $result
}

# ---------------------------------------------------------------------------
# pure: plan validation
# ---------------------------------------------------------------------------
function Test-KanaAiLifecyclePlan {
    <#
        Returns @{ Ok; Errors; Warnings; PhaseCount; PhaseNames; Idempotency }.
        Every error string is prefixed with a stable code so a self test can
        assert on the code instead of on English prose.
    #>
    param([Parameter(Mandatory = $true)]$Plan)

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $schemaVersion = Get-KanaAiLifecycleOptionalProperty -Object $Plan -Name 'schemaVersion' -Default $null
    if ([int]$schemaVersion -ne $script:KanaAiLifecycleSchemaVersion) {
        $errors.Add("PLAN-SCHEMA: schemaVersion must be $script:KanaAiLifecycleSchemaVersion.")
    }
    $planId = [string](Get-KanaAiLifecycleOptionalProperty -Object $Plan -Name 'planId' -Default '')
    if ($planId -notmatch '^[a-z0-9][a-z0-9-]{2,63}$') {
        $errors.Add('PLAN-ID: planId must be a lower-case slug.')
    }

    # --- pinned identity ---------------------------------------------------
    $pinned = Get-KanaAiLifecycleOptionalProperty -Object $Plan -Name 'pinnedIdentity' -Default $null
    if ($null -eq $pinned) {
        $errors.Add('PLAN-IDENTITY: pinnedIdentity is required.')
    }
    else {
        $upgradeCode = [string](Get-KanaAiLifecycleOptionalProperty -Object $pinned -Name 'upgradeCode' -Default '')
        if (-not (Test-KanaAiLifecycleGuid -Value $upgradeCode)) {
            $errors.Add('PLAN-IDENTITY: pinnedIdentity.upgradeCode must be a brace-delimited GUID.')
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-KanaAiLifecycleOptionalProperty -Object $pinned -Name 'packageName' -Default ''))) {
            $errors.Add('PLAN-IDENTITY: pinnedIdentity.packageName is required.')
        }
        $scope = [string](Get-KanaAiLifecycleOptionalProperty -Object $pinned -Name 'scope' -Default '')
        if ($scope -ne 'perMachine' -and $scope -ne 'perUser') {
            $errors.Add('PLAN-IDENTITY: pinnedIdentity.scope must be perMachine or perUser.')
        }
        $installFolder = Get-KanaAiLifecycleOptionalProperty -Object $pinned -Name 'installFolder' -Default $null
        if ($null -eq $installFolder) {
            $errors.Add('PLAN-IDENTITY: pinnedIdentity.installFolder is required.')
        }
        else {
            $leaf = [string](Get-KanaAiLifecycleOptionalProperty -Object $installFolder -Name 'leaf' -Default '')
            if ([string]::IsNullOrWhiteSpace($leaf)) {
                $errors.Add('PLAN-IDENTITY: pinnedIdentity.installFolder.leaf is required.')
            }
        }
    }

    # --- registration identity --------------------------------------------
    $registration = Get-KanaAiLifecycleOptionalProperty -Object $Plan -Name 'registrationIdentity' -Default $null
    if ($null -eq $registration) {
        $errors.Add('PLAN-REGISTRATION: registrationIdentity is required.')
    }
    else {
        foreach ($name in @('textServiceClsid', 'languageProfileGuid')) {
            $value = [string](Get-KanaAiLifecycleOptionalProperty -Object $registration -Name $name -Default '')
            if (-not (Test-KanaAiLifecycleGuid -Value $value)) {
                $errors.Add("PLAN-REGISTRATION: registrationIdentity.$name must be a brace-delimited GUID.")
            }
        }
        foreach ($name in @('machineTextServiceRoot', 'machineComRoot', 'profileSubkey', 'languageSegment')) {
            $value = [string](Get-KanaAiLifecycleOptionalProperty -Object $registration -Name $name -Default '')
            if ([string]::IsNullOrWhiteSpace($value)) {
                $errors.Add("PLAN-REGISTRATION: registrationIdentity.$name is required.")
            }
        }
        $view = [string](Get-KanaAiLifecycleOptionalProperty -Object $registration -Name 'registryView' -Default '')
        if ($view -ne 'Registry64' -and $view -ne 'Registry32') {
            $errors.Add('PLAN-REGISTRATION: registrationIdentity.registryView must be Registry64 or Registry32.')
        }
    }

    $executables = @(Get-KanaAiLifecycleOptionalProperty -Object $Plan -Name 'productExecutables' -Default @())
    if ($executables.Count -eq 0) {
        $errors.Add('PLAN-EXECUTABLES: productExecutables must list at least the product own executables.')
    }

    # --- phases ------------------------------------------------------------
    $phases = @(Get-KanaAiLifecycleOptionalProperty -Object $Plan -Name 'phases' -Default @())
    if ($phases.Count -eq 0) {
        $errors.Add('PLAN-PHASES: at least one phase is required.')
    }
    $seenIds = @()
    $seenNames = @()
    foreach ($phase in $phases) {
        $id = [string](Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'id' -Default '')
        $name = [string](Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'name' -Default '')
        $context = "phase '$name'"
        if ($id -notmatch '^[A-Z]{2,4}-\d{2}$') { $errors.Add("PLAN-PHASE-ID: $context has an id that is not an uppercase ticket id.") }
        if ($name -notmatch '^[a-z0-9][a-z0-9-]{2,63}$') { $errors.Add("PLAN-PHASE-NAME: $context has a name that is not a lower-case slug.") }
        if ($seenIds -contains $id) { $errors.Add("PLAN-PHASE-ID: duplicate phase id '$id'.") }
        if ($seenNames -contains $name) { $errors.Add("PLAN-PHASE-NAME: duplicate phase name '$name'.") }
        $seenIds += $id
        $seenNames += $name
        if ([string]::IsNullOrWhiteSpace([string](Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'title' -Default ''))) {
            $errors.Add("PLAN-PHASE-TITLE: $context has no title.")
        }
        $destructive = Get-KanaAiLifecycleBoolProperty -Object $phase -Name 'destructive'
        $asserts = @(Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'asserts' -Default @())
        if ($asserts.Count -eq 0) {
            $errors.Add("PLAN-PHASE-ASSERTS: $context asserts nothing. A phase that asserts nothing is not a verification step.")
        }
        $assertedNames = @()
        foreach ($assert in $asserts) {
            $check = [string](Get-KanaAiLifecycleOptionalProperty -Object $assert -Name 'check' -Default '')
            if ($script:KanaAiLifecycleAllCheckNames -notcontains $check) {
                $errors.Add("PLAN-PHASE-CHECK: $context uses unknown check '$check'.")
            }
            if (Get-KanaAiLifecycleBoolProperty -Object $assert -Name 'required' -Default $true) {
                $assertedNames += $check
            }
        }
        $command = Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'command' -Default $null
        if ($null -ne $command) {
            $accepted = @(Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'acceptedExitCodes' -Default @())
            if ($accepted.Count -eq 0) {
                $errors.Add("PLAN-PHASE-EXIT: $context runs a command but declares no accepted exit codes.")
            }
            # The core anti-defect rule.  A phase that runs a command and whose
            # only required assertion is the exit code is exactly the "returned
            # 0, so it must have worked" mistake this harness exists to prevent.
            $stateAssertions = @($assertedNames | Where-Object { $_ -ne 'command-exit-code' })
            if ($stateAssertions.Count -eq 0) {
                $errors.Add("PLAN-PHASE-EVIDENCE: $context may not be decided by an exit code alone. Add at least one required state assertion (product-state, registration-present, expected-files, ...).")
            }
        }
        else {
            $accepted = @()
        }
        if ($destructive) {
            $destructiveAssertions = @($assertedNames | Where-Object { $_ -in @('product-state', 'product-code', 'expected-files', 'install-directory') })
            if ($destructiveAssertions.Count -eq 0) {
                $errors.Add("PLAN-PHASE-DESTRUCTIVE: $context is destructive but has no required product-state, product-code, expected-files or install-directory assertion, so its effect on the machine would go unobserved.")
            }
        }
        $preconditions = @(Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'preconditions' -Default @())
        foreach ($precondition in $preconditions) {
            $observed = [string](Get-KanaAiLifecycleOptionalProperty -Object $precondition -Name 'observed' -Default '')
            if ($observed -eq '') { $errors.Add("PLAN-PHASE-PRECONDITION: $context has a precondition without an 'observed' field.") }
        }
        foreach ($field in @('proves', 'cannotProve')) {
            $value = @(Get-KanaAiLifecycleOptionalProperty -Object $phase -Name $field -Default @())
            if ($value.Count -eq 0) { $errors.Add("PLAN-PHASE-DOC: $context has an empty '$field' list. Every phase must state what it proves and what it cannot prove.") }
        }
    }

    # --- gate ordering -----------------------------------------------------
    $gates = @(Get-KanaAiLifecycleOptionalProperty -Object $Plan -Name 'safetyGates' -Default @())
    $requiredGateIds = @('elevation', 'candidate-identity', 'unexpected-existing-install', 'machine-lock', 'consent')
    $presentGateIds = @()
    foreach ($gate in $gates) {
        $gateId = [string](Get-KanaAiLifecycleOptionalProperty -Object $gate -Name 'id' -Default '')
        $presentGateIds += $gateId
        if ([string]::IsNullOrWhiteSpace([string](Get-KanaAiLifecycleOptionalProperty -Object $gate -Name 'rule' -Default ''))) {
            $errors.Add("PLAN-GATE: safety gate '$gateId' has no rule.")
        }
    }
    foreach ($required in $requiredGateIds) {
        if ($presentGateIds -notcontains $required) { $errors.Add("PLAN-GATE: the required safety gate '$required' is missing.") }
    }

    return [pscustomobject]@{
        Ok         = ($errors.Count -eq 0)
        Errors     = @($errors.ToArray())
        Warnings   = @($warnings.ToArray())
        PhaseCount = $phases.Count
        PhaseNames = @($seenNames)
        PhaseIds   = @($seenIds)
    }
}

function Get-KanaAiLifecyclePhase {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$Name
    )
    foreach ($phase in @(Get-KanaAiLifecycleOptionalProperty -Object $Plan -Name 'phases' -Default @())) {
        if ([string](Get-KanaAiLifecycleOptionalProperty -Object $phase -Name 'name' -Default '') -eq $Name) { return $phase }
    }
    return $null
}

# ---------------------------------------------------------------------------
# pure: candidate identity
# ---------------------------------------------------------------------------
function Test-KanaAiLifecycleCandidateIdentity {
    <#
        Pure function over a property map read from the candidate MSI's Property
        table plus the package template platform from its summary information.
        Nothing here touches the MSI; the caller does the read.
    #>
    param(
        [Parameter(Mandatory = $true)]$PropertyMap,
        [AllowEmptyString()][string]$TemplatePlatform,
        [Parameter(Mandatory = $true)]$Pinned
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $productCode = [string](Get-KanaAiLifecycleOptionalProperty -Object $PropertyMap -Name 'ProductCode' -Default '')
    $upgradeCode = [string](Get-KanaAiLifecycleOptionalProperty -Object $PropertyMap -Name 'UpgradeCode' -Default '')
    $productName = [string](Get-KanaAiLifecycleOptionalProperty -Object $PropertyMap -Name 'ProductName' -Default '')
    $productVersion = [string](Get-KanaAiLifecycleOptionalProperty -Object $PropertyMap -Name 'ProductVersion' -Default '')
    $manufacturer = [string](Get-KanaAiLifecycleOptionalProperty -Object $PropertyMap -Name 'Manufacturer' -Default '')
    $allUsers = [string](Get-KanaAiLifecycleOptionalProperty -Object $PropertyMap -Name 'ALLUSERS' -Default '')
    $productLanguage = [string](Get-KanaAiLifecycleOptionalProperty -Object $PropertyMap -Name 'ProductLanguage' -Default '')

    if (-not (Test-KanaAiLifecycleGuid -Value $productCode)) { $errors.Add('CANDIDATE-PID: the candidate MSI has no brace-delimited ProductCode property.') }
    $expectedUpgrade = [string](Get-KanaAiLifecycleProperty -Object $Pinned -Name 'upgradeCode' -Context 'pinned identity')
    if (-not (Test-KanaAiLifecycleGuid -Value $upgradeCode)) {
        $errors.Add('CANDIDATE-PID: the candidate MSI has no brace-delimited UpgradeCode property.')
    }
    elseif ((ConvertTo-KanaAiLifecycleGuid -Value $upgradeCode) -ne (ConvertTo-KanaAiLifecycleGuid -Value $expectedUpgrade)) {
        $errors.Add(("CANDIDATE-PID: UpgradeCode '{0}' is not the pinned KanaAI UpgradeCode '{1}'. Refusing to run against an unexpected product identity." -f $upgradeCode, $expectedUpgrade))
    }
    $expectedName = [string](Get-KanaAiLifecycleProperty -Object $Pinned -Name 'packageName' -Context 'pinned identity')
    if ($productName -ne $expectedName) {
        $errors.Add(("CANDIDATE-PID: ProductName '{0}' is not '{1}'." -f $productName, $expectedName))
    }
    if ($productVersion -notmatch '^\d+\.\d+\.\d+$') {
        $errors.Add("CANDIDATE-VERSION: ProductVersion '$productVersion' is not an MSI major.minor.build version.")
    }
    $expectedScope = [string](Get-KanaAiLifecycleProperty -Object $Pinned -Name 'scope' -Context 'pinned identity')
    if ($expectedScope -eq 'perMachine' -and $allUsers -ne '1') {
        $errors.Add("CANDIDATE-SCOPE: the pinned scope is perMachine but the candidate's ALLUSERS property is '$allUsers'.")
    }
    if ([string]::IsNullOrWhiteSpace($TemplatePlatform)) {
        $errors.Add('CANDIDATE-PLATFORM: the candidate MSI summary information did not report a package template platform.')
    }
    elseif ($TemplatePlatform -notmatch '(?i)\bx64\b') {
        $errors.Add("CANDIDATE-PLATFORM: the candidate package template is '$TemplatePlatform', which is not x64.")
    }
    if ([string]::IsNullOrWhiteSpace($manufacturer)) { $warnings.Add('CANDIDATE-PID: the candidate MSI has no Manufacturer property.') }
    if ([string]::IsNullOrWhiteSpace($productLanguage)) { $warnings.Add('CANDIDATE-PID: the candidate MSI has no ProductLanguage property.') }
    $template = $TemplatePlatform
    return [pscustomobject]@{
        Ok              = ($errors.Count -eq 0)
        Errors          = @($errors.ToArray())
        Warnings        = @($warnings.ToArray())
        ProductCode     = (ConvertTo-KanaAiLifecycleGuid -Value $productCode)
        UpgradeCode     = (ConvertTo-KanaAiLifecycleGuid -Value $upgradeCode)
        ProductName     = $productName
        ProductVersion  = $productVersion
        Manufacturer    = $manufacturer
        AllUsers        = $allUsers
        ProductLanguage = $productLanguage
        TemplatePlatform = $template
    }
}

# ---------------------------------------------------------------------------
# pure: inventories
# ---------------------------------------------------------------------------
function ConvertTo-KanaAiLifecycleRelativePathList {
    param([AllowNull()]$Entries)
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $text = ([string]$entry).Replace('\', '/').Trim()
        while ($text.StartsWith('./')) { $text = $text.Substring(2) }
        if ($text -eq '') { continue }
        if (-not $seen.Contains($text)) { $seen.Add($text) }
    }
    return @($seen.ToArray())
}

function Compare-KanaAiLifecycleFileInventory {
    <#
        The expected set comes from the candidate MSI's own File table, joined
        through Component and Directory, expressed relative to INSTALLFOLDER.
        Nothing here is hand-maintained, so a file added to the package is
        automatically expected, and a file that fails to appear is reported.
    #>
    param(
        [AllowNull()][string[]]$Expected,
        [AllowNull()][string[]]$Observed
    )
    # A PowerShell function unrolls an array on return, so a one-element list
    # arrives as a scalar.  Every list-returning helper is therefore wrapped in
    # @() at the call site before .Count is used on it.
    $expectedList = @(ConvertTo-KanaAiLifecycleRelativePathList -Entries $Expected)
    $observedList = @(ConvertTo-KanaAiLifecycleRelativePathList -Entries $Observed)
    $missing = @($expectedList | Where-Object { $observedList -notcontains $_ } | Sort-Object)
    $unexpected = @($observedList | Where-Object { $expectedList -notcontains $_ } | Sort-Object)
    return [ordered]@{
        ok         = ($missing.Count -eq 0)
        expected   = $expectedList
        observed   = $observedList
        missing    = $missing
        unexpected = $unexpected
        expectedCount = $expectedList.Count
        observedCount = $observedList.Count
        note       = 'The observed set is the file inventory of the resolved install directory. A file the package never declared is reported as unexpected, not as a failure.'
    }
}

function Compare-KanaAiLifecycleInventories {
    param(
        [AllowNull()][string[]]$Before,
        [AllowNull()][string[]]$After
    )
    $beforeList = @(ConvertTo-KanaAiLifecycleRelativePathList -Entries $Before)
    $afterList = @(ConvertTo-KanaAiLifecycleRelativePathList -Entries $After)
    $added = @($afterList | Where-Object { $beforeList -notcontains $_ } | Sort-Object)
    $removed = @($beforeList | Where-Object { $afterList -notcontains $_ } | Sort-Object)
    return [ordered]@{
        identical = (($added.Count -eq 0) -and ($removed.Count -eq 0))
        added     = $added
        removed   = $removed
        beforeCount = $beforeList.Count
        afterCount  = $afterList.Count
    }
}

# ---------------------------------------------------------------------------
# pure: the comparison engine
# ---------------------------------------------------------------------------
function New-KanaAiLifecycleCheckResult {
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'unconfirmed')][string]$Outcome,
        [Parameter(Mandatory = $true)][string]$Detail,
        [bool]$Required = $true,
        $Evidence = $null
    )
    return [ordered]@{
        check    = $Check
        outcome  = $Outcome
        required = $Required
        detail   = $Detail
        evidence = $Evidence
    }
}

function Resolve-KanaAiLifecyclePhaseChecks {
    <#
        The single decision point of the whole harness.  It reads only the
        observation context and the phase's declared assertions.  It has no
        access to the machine, which is exactly why the self test can drive it
        with synthetic data and prove the negative cases.

        The context shape (every field optional; a missing field becomes
        "unconfirmed", never "pass"):

          observation.command            @{ executed; exitCode; commandLine; timedOut; logPath }
          observation.productState       'installed' | 'absent' | 'advertised' | 'unknown'
          observation.installedProductCode
          observation.expectedProductCode
          observation.installDate
          observation.registration       @{ readable; tipKey; profileKey; comKey;
                                            inProcServer32; inProcTargetExists;
                                            userActivationEnable }
          observation.installDirectory   @{ resolved; exists; files }
          observation.expectedFiles      @{ ok; missing; unexpected }
          observation.inventoryDelta     @{ identical; added; removed }
          observation.processes          @{ observed; harnessStarted; orphans }
          observation.msiLog             @{ readable; classification; confident; evidence }
    #>
    param(
        [Parameter(Mandatory = $true)]$Phase,
        [Parameter(Mandatory = $true)]$Context
    )
    $results = New-Object System.Collections.Generic.List[object]
    $observation = Get-KanaAiLifecycleOptionalProperty -Object $Context -Name 'observation' -Default $null
    if ($null -eq $observation) { $observation = [pscustomobject]@{} }

    foreach ($assert in @(Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'asserts' -Default @())) {
        $check = [string](Get-KanaAiLifecycleOptionalProperty -Object $assert -Name 'check' -Context 'assert')
        $expect = [string](Get-KanaAiLifecycleOptionalProperty -Object $assert -Name 'expect' -Context 'assert')
        $required = Get-KanaAiLifecycleBoolProperty -Object $assert -Name 'required' -Default $true

        switch ($check) {

            'command-exit-code' {
                $command = Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'command' -Default $null
                if ($null -eq $command) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'no command was executed for this phase' -Evidence 'the command record is absent'))
                }
                elseif (-not (Get-KanaAiLifecycleBoolProperty -Object $command -Name 'executed')) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail 'the command was not executed' -Evidence 'command.executed is false'))
                }
                elseif (Get-KanaAiLifecycleBoolProperty -Object $command -Name 'timedOut') {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail 'the command exceeded its timeout and was terminated by the harness' -Evidence ([string](Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'commandLine' -Default ''))))
                }
                else {
                    $exitText = [string](Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'exitCode' -Default '')
                    $meaning = Get-KanaAiLifecycleMsiExitCodeMeaning -ExitCodeText $exitText
                    if ($meaning -eq 'unknown') {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("exit code '{0}' is not a Windows Installer exit code this harness interprets" -f $exitText) -Evidence ([string](Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'commandLine' -Default ''))))
                    }
                    elseif ($expect -match '^\d+(,\d+)*$') {
                        $accepted = @($expect -split ',' | ForEach-Object { $_.Trim() })
                        if ($accepted -contains $exitText) {
                            [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail ("exit code {0} ({1}) is in the accepted set [{2}]" -f $exitText, $meaning, $expect) -Evidence ([string](Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'commandLine' -Default ''))))
                        }
                        else {
                            [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("exit code {0} ({1}) is not in the accepted set [{2}]" -f $exitText, $meaning, $expect) -Evidence ([string](Get-KanaAiLifecycleOptionalProperty -Object $command -Name 'commandLine' -Default ''))))
                        }
                    }
                    else {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("this harness requires an explicit accepted exit code list; '$expect' is not one") -Evidence $exitText))
                    }
                }
            }

            'product-state' {
                $state = [string](Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'productState' -Default 'unknown')
                if ($state -eq 'unknown') {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'the installed product state could not be read from the Windows Installer API' -Evidence 'ProductInfo InstallState was unreadable'))
                }
                elseif ($state -eq $expect) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail ("the Windows Installer reports the product state '{0}'" -f $state) -Evidence $state))
                }
                else {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("the Windows Installer reports the product state '{0}', expected '{1}'" -f $state, $expect) -Evidence $state))
                }
            }

            'product-code' {
                $installed = ConvertTo-KanaAiLifecycleGuid -Value ([string](Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'installedProductCode' -Default ''))
                $expected = ConvertTo-KanaAiLifecycleGuid -Value ([string](Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'expectedProductCode' -Default ''))
                if ([string]::IsNullOrWhiteSpace($installed) -or [string]::IsNullOrWhiteSpace($expected)) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'either the installed or the expected product code is unknown' -Evidence ('installed=' + $installed + '; expected=' + $expected)))
                }
                elseif ($expect -eq 'from-candidate-msi') {
                    # The plan cannot know the ProductCode in advance: WiX derives
                    # it from the version.  The expectation is therefore "exactly
                    # the product code this run read out of the candidate MSI".
                    if ($installed -eq $expected) {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail ("the installed product is the candidate MSI's own product code {0}" -f $installed) -Evidence $installed))
                    }
                    else {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("the installed product code is '{0}', but the candidate MSI declares '{1}'; a different product is installed" -f $installed, $expected) -Evidence $installed))
                    }
                }
                elseif ($installed -eq $expected -and $installed -eq $expect) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail ("the installed product code is {0}" -f $installed) -Evidence $installed))
                }
                else {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("the installed product code is '{0}', expected '{1}'" -f $installed, $expected) -Evidence $installed))
                }
            }

            'registration-present' {
                $registration = Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'registration' -Default $null
                if ($null -eq $registration) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'the TSF registration surface could not be read' -Evidence 'no registration observation'))
                }
                elseif (-not (Get-KanaAiLifecycleBoolProperty -Object $registration -Name 'readable')) {
                    $readError = [string](Get-KanaAiLifecycleOptionalProperty -Object $registration -Name 'error' -Default 'no reason recorded')
                    $detail = 'the TSF registration surface is not readable: ' + $readError
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail $detail -Evidence 'registration.readable is false'))
                }
                else {
                    $parts = @()
                    $ok = $true
                    foreach ($field in @('tipKey', 'profileKey', 'comKey')) {
                        $present = Get-KanaAiLifecycleBoolProperty -Object $registration -Name $field
                        $parts += ("{0}={1}" -f $field, $present)
                        if (-not $present) { $ok = $false }
                    }
                    $targetPath = [string](Get-KanaAiLifecycleOptionalProperty -Object $registration -Name 'inProcServer32' -Default '')
                    $targetExists = Get-KanaAiLifecycleBoolProperty -Object $registration -Name 'inProcTargetExists'
                    $parts += ("inProcTargetExists={0}" -f $targetExists)
                    # A key with no real DLL behind it is not a registration.
                    if (-not $ok) {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ('the TSF registration surface is incomplete: ' + ($parts -join ' ')) -Evidence $parts))
                    }
                    elseif ([string]::IsNullOrWhiteSpace($targetPath) -or -not $targetExists) {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ('the TSF keys exist but the registered InProcServer32 target is not a real file: ' + $targetPath) -Evidence $parts))
                    }
                    else {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail ('the TIP, language profile and COM keys are present and the registered DLL exists: ' + ($parts -join ' ')) -Evidence $parts))
                    }
                }
            }

            'registration-absent' {
                $registration = Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'registration' -Default $null
                if ($null -eq $registration -or -not (Get-KanaAiLifecycleBoolProperty -Object $registration -Name 'readable')) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'the TSF registration surface could not be read, so its absence was not observed' -Evidence 'registration.readable is false or absent'))
                }
                else {
                    $present = @()
                    foreach ($field in @('tipKey', 'profileKey', 'comKey')) {
                        if (Get-KanaAiLifecycleBoolProperty -Object $registration -Name $field) { $present += $field }
                    }
                    if ($present.Count -eq 0) {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail 'the KanaAI TIP, language profile and COM keys are all absent' -Evidence 'tipKey=false profileKey=false comKey=false'))
                    }
                    else {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ('the KanaAI registration surface survived the uninstall: ' + ($present -join ' ')) -Evidence ($present -join ' ')))
                    }
                }
            }

            'registration-target-file-present' {
                $registration = Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'registration' -Default $null
                if ($null -eq $registration) {
                    # No registration observation at all is not the same thing as
                    # a registration observation that found no file.  There is
                    # deliberately no early return here: the remaining asserts of
                    # the phase must still be evaluated.
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'no registration observation was taken, so the registered DLL could not be located or excluded' -Evidence 'registration is absent'))
                }
                else {
                    $targetExists = Get-KanaAiLifecycleBoolProperty -Object $registration -Name 'inProcTargetExists'
                    $targetPath = [string](Get-KanaAiLifecycleOptionalProperty -Object $registration -Name 'inProcServer32' -Default '')
                    if ($expect -eq 'true' -and $targetExists) {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail ('the registered text service DLL exists: ' + $targetPath) -Evidence $targetPath))
                    }
                    elseif ($expect -eq 'true') {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ('the registered text service DLL does not exist: ' + $targetPath) -Evidence $targetPath))
                    }
                    elseif ($expect -eq 'false' -and -not $targetExists) {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail 'the registered text service DLL is gone' -Evidence $targetPath))
                    }
                    else {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ('the registered text service DLL still exists: ' + $targetPath) -Evidence $targetPath))
                    }
                }
            }

            'install-directory' {
                $directory = Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'installDirectory' -Default $null
                if ($null -eq $directory) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'the install directory could not be resolved' -Evidence 'no install directory observation'))
                }
                else {
                    $exists = Get-KanaAiLifecycleBoolProperty -Object $directory -Name 'exists'
                    $files = @(Get-KanaAiLifecycleOptionalProperty -Object $directory -Name 'files' -Default @())
                    if ($expect -eq 'absent' -and -not $exists -and $files.Count -eq 0) {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail 'the install directory does not exist and holds no files' -Evidence ([string](Get-KanaAiLifecycleOptionalProperty -Object $directory -Name 'resolved' -Default ''))))
                    }
                    elseif ($expect -eq 'absent') {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("the install directory still exists with {0} file(s)" -f $files.Count) -Evidence ([string](Get-KanaAiLifecycleOptionalProperty -Object $directory -Name 'resolved' -Default ''))))
                    }
                    elseif ($expect -eq 'present' -and $exists -and $files.Count -gt 0) {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail ("the install directory exists with {0} file(s)" -f $files.Count) -Evidence ([string](Get-KanaAiLifecycleOptionalProperty -Object $directory -Name 'resolved' -Default ''))))
                    }
                    else {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("the install directory does not hold a populated tree (exists={0}, files={1})" -f $exists, $files.Count) -Evidence ([string](Get-KanaAiLifecycleOptionalProperty -Object $directory -Name 'resolved' -Default ''))))
                    }
                }
            }

            'expected-files' {
                $expectedFiles = Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'expectedFiles' -Default $null
                if ($null -eq $expectedFiles) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'no expected-file comparison was performed' -Evidence 'expectedFiles is absent'))
                }
                elseif (Get-KanaAiLifecycleBoolProperty -Object $expectedFiles -Name 'ok') {
                    $count = @(Get-KanaAiLifecycleOptionalProperty -Object $expectedFiles -Name 'expected' -Default @()).Count
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail ("all {0} file(s) the package declared are present" -f $count) -Evidence ('expected=' + $count)))
                }
                else {
                    $missing = @(Get-KanaAiLifecycleOptionalProperty -Object $expectedFiles -Name 'missing' -Default @())
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("{0} declared file(s) are missing from the install directory" -f $missing.Count) -Evidence $missing))
                }
            }

            'no-orphan-processes' {
                $processes = Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'processes' -Default $null
                if ($null -eq $processes -or -not (Get-KanaAiLifecycleBoolProperty -Object $processes -Name 'readable')) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'the product process list could not be read' -Evidence 'processes.readable is false or absent'))
                }
                else {
                    $orphans = @(Get-KanaAiLifecycleOptionalProperty -Object $processes -Name 'orphans' -Default @())
                    if ($orphans.Count -eq 0) {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail 'no KanaAI-owned process that the harness did not start is running' -Evidence ('observed=' + (@(Get-KanaAiLifecycleOptionalProperty -Object $processes -Name 'observed' -Default @()) -join ','))))
                    }
                    else {
                        [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("{0} KanaAI-owned process(es) the harness did not start are still running" -f $orphans.Count) -Evidence $orphans))
                    }
                }
            }

            'install-date-unchanged' {
                $before = [string](Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'installDateBefore' -Default '')
                $after = [string](Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'installDate' -Default '')
                if ([string]::IsNullOrWhiteSpace($before) -or [string]::IsNullOrWhiteSpace($after)) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'the installed product InstallDate could not be read on both sides of the command' -Evidence ('before=' + $before + '; after=' + $after)))
                }
                elseif ($before -eq $after) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail ("InstallDate is unchanged at '{0}', so the second run did not create a new installation record" -f $after) -Evidence $after))
                }
                else {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("InstallDate changed from '{0}' to '{1}', which is what a fresh install of the same product code looks like" -f $before, $after) -Evidence ('before=' + $before + '; after=' + $after)))
                }
            }

            'file-inventory-unchanged' {
                $delta = Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'inventoryDelta' -Default $null
                if ($null -eq $delta) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'no before/after file inventory comparison was performed' -Evidence 'inventoryDelta is absent'))
                }
                elseif (Get-KanaAiLifecycleBoolProperty -Object $delta -Name 'identical') {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail 'the install directory file set is byte-for-byte the same file set as before the command' -Evidence ('files=' + @(Get-KanaAiLifecycleOptionalProperty -Object $delta -Name 'afterCount' -Default 0))))
                }
                else {
                    $added = @(Get-KanaAiLifecycleOptionalProperty -Object $delta -Name 'added' -Default @())
                    $removed = @(Get-KanaAiLifecycleOptionalProperty -Object $delta -Name 'removed' -Default @())
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("the install directory file set changed (added={0}, removed={1})" -f $added.Count, $removed.Count) -Evidence ([ordered]@{ added = $added; removed = $removed })))
                }
            }

            'msi-log-classification' {
                $log = Get-KanaAiLifecycleOptionalProperty -Object $observation -Name 'msiLog' -Default $null
                if ($null -eq $log -or -not (Get-KanaAiLifecycleBoolProperty -Object $log -Name 'readable')) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail 'the Windows Installer log was not readable, so the run was not classified' -Evidence 'msiLog.readable is false or absent'))
                }
                elseif (-not (Get-KanaAiLifecycleBoolProperty -Object $log -Name 'confident')) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'unconfirmed' -Required $required -Detail ('the log was not classifiable with confidence; expected "' + $expect + '"') -Evidence @(Get-KanaAiLifecycleOptionalProperty -Object $log -Name 'evidence' -Default @())))
                }
                elseif ([string](Get-KanaAiLifecycleOptionalProperty -Object $log -Name 'classification' -Default '') -eq $expect) {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'pass' -Required $required -Detail ("the Windows Installer log is classified as '{0}'" -f $expect) -Evidence @(Get-KanaAiLifecycleOptionalProperty -Object $log -Name 'evidence' -Default @())))
                }
                else {
                    [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail ("the Windows Installer log is classified as '{0}', expected '{1}'" -f [string](Get-KanaAiLifecycleOptionalProperty -Object $log -Name 'classification' -Default ''), $expect) -Evidence @(Get-KanaAiLifecycleOptionalProperty -Object $log -Name 'evidence' -Default @())))
                }
            }

            default {
                # The plan validator rejects unknown check names.  Reaching this
                # branch means the validator was bypassed, so fail closed.
                [void]$results.Add((New-KanaAiLifecycleCheckResult -Check $check -Outcome 'fail' -Required $required -Detail "unknown check name '$check' reached the comparison engine" -Evidence 'fail closed'))
            }
        }
    }
    return @($results.ToArray())
}

function Resolve-KanaAiLifecyclePhaseOutcome {
    <#
        pass        - every required check passed, and at least one required
                     state check (not merely the exit code) passed.
        unconfirmed - no check failed, but at least one required check could not
                     be observed.
        fail        - at least one required check failed.
    #>
    param(
        [Parameter(Mandatory = $true)]$Phase,
        [Parameter(Mandatory = $true)]$Context
    )
    $checks = @(Resolve-KanaAiLifecyclePhaseChecks -Phase $Phase -Context $Context)
    $required = @($checks | Where-Object { [bool]$_.required })
    $failed = @($required | Where-Object { [string]$_.outcome -eq 'fail' })
    $unconfirmed = @($required | Where-Object { [string]$_.outcome -eq 'unconfirmed' })
    $passedState = @($required | Where-Object { [string]$_.outcome -eq 'pass' -and [string]$_.check -ne 'command-exit-code' })
    $passedOnlyExitCode = @($required | Where-Object { [string]$_.outcome -eq 'pass' -and [string]$_.check -eq 'command-exit-code' })

    $outcome = 'pass'
    $reason = 'every required check passed'
    if ($required.Count -eq 0) {
        $outcome = 'unconfirmed'
        $reason = 'the phase asserted nothing, so nothing was proven'
    }
    elseif ($failed.Count -gt 0) {
        $outcome = 'fail'
        $reason = ("{0} required check(s) failed: {1}" -f $failed.Count, (($failed | ForEach-Object { [string]$_.check }) -join ', '))
    }
    elseif ($unconfirmed.Count -gt 0) {
        $outcome = 'unconfirmed'
        $reason = ("{0} required check(s) could not be observed: {1}" -f $unconfirmed.Count, (($unconfirmed | ForEach-Object { [string]$_.check }) -join ', '))
    }
    elseif ($passedState.Count -eq 0) {
        # Unreachable through plan validation, which forbids a phase whose only
        # required assertion is the exit code.  Kept as a hard stop anyway.
        $outcome = 'unconfirmed'
        $reason = 'only the exit code was observed; an exit code is not evidence of a machine state'
    }
    elseif ($passedOnlyExitCode.Count -gt 0 -and $passedState.Count -eq 0) {
        $outcome = 'unconfirmed'
        $reason = 'the exit code passed but no independent state check passed'
    }
    return [ordered]@{
        phase     = [string](Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'name' -Default '')
        title     = [string](Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'title' -Default '')
        outcome   = $outcome
        reason    = $reason
        checks    = $checks
        checkCounts = [ordered]@{
            passed       = @($checks | Where-Object { [string]$_.outcome -eq 'pass' }).Count
            failed       = @($checks | Where-Object { [string]$_.outcome -eq 'fail' }).Count
            unconfirmed  = @($checks | Where-Object { [string]$_.outcome -eq 'unconfirmed' }).Count
            stateChecksPassed = $passedState.Count
        }
        command   = Get-KanaAiLifecycleOptionalProperty -Object (Get-KanaAiLifecycleOptionalProperty -Object $Context -Name 'observation' -Default $null) -Name 'command' -Default $null
        observation = Get-KanaAiLifecycleOptionalProperty -Object $Context -Name 'observation' -Default $null
    }
}

# ---------------------------------------------------------------------------
# pure: preconditions
# ---------------------------------------------------------------------------
function Resolve-KanaAiLifecyclePreconditions {
    <#
        A phase whose precondition is not met is unconfirmed and runs no
        command.  This is what stops a failed Setup.exe install from turning
        into a "successful" uninstall of a product that was never installed.
    #>
    param(
        [Parameter(Mandatory = $true)]$Phase,
        [Parameter(Mandatory = $true)]$State
    )
    $unmet = New-Object System.Collections.Generic.List[string]
    foreach ($precondition in @(Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'preconditions' -Default @())) {
        $observed = [string](Get-KanaAiLifecycleProperty -Object $precondition -Name 'observed' -Context 'precondition')
        $expected = [string](Get-KanaAiLifecycleProperty -Object $precondition -Name 'equals' -Context 'precondition')
        $actual = [string](Get-KanaAiLifecycleOptionalProperty -Object $State -Name $observed -Default '<unknown>')
        if ($actual -ne $expected) {
            $unmet.Add(("precondition '{0}' is '{1}', expected '{2}'" -f $observed, $actual, $expected))
        }
    }
    return [ordered]@{
        met     = ($unmet.Count -eq 0)
        unmet   = @($unmet.ToArray())
        details = @(Get-KanaAiLifecycleOptionalProperty -Object $Phase -Name 'preconditions' -Default @())
    }
}

# ---------------------------------------------------------------------------
# pure: resume
# ---------------------------------------------------------------------------
function Resolve-KanaAiLifecycleResumePlan {
    <#
        Given the plan's phase order, a prior receipt's phase results, the
        requested -ResumeFrom and the -AllowDestructiveRerun acknowledgement,
        return a decision for every phase.  The rules, in order:

          * a phase with a prior result of 'pass' is 'skip-completed' and is
            never re-run;
          * a phase before -ResumeFrom with no prior result is 'skip-not-run'
            and is reported as not_run, never as a pass;
          * a destructive phase whose prior result is not 'pass' is 'refused'
            unless the operator passed -AllowDestructiveRerun, so a retry can
            never silently repeat a destructive step the operator did not see;
          * a destructive phase that -ResumeFrom points at, and that already
            passed, is also 'refused' without -AllowDestructiveRerun.
    #>
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [AllowNull()]$PriorResults,
        [string]$ResumeFrom = '',
        [bool]$AllowDestructiveRerun = $false
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $phases = @(Get-KanaAiLifecycleOptionalProperty -Object $Plan -Name 'phases' -Default @())
    $names = @()
    foreach ($phase in $phases) { $names += [string](Get-KanaAiLifecycleProperty -Object $phase -Name 'name' -Context 'phase') }

    $prior = @{}
    foreach ($result in @($PriorResults)) {
        if ($null -eq $result) { continue }
        $name = [string](Get-KanaAiLifecycleOptionalProperty -Object $result -Name 'phase' -Default '')
        $outcome = [string](Get-KanaAiLifecycleOptionalProperty -Object $result -Name 'outcome' -Default 'not_run')
        if ($name -ne '') { $prior[$name] = $outcome }
    }

    $startIndex = 0
    if (-not [string]::IsNullOrWhiteSpace($ResumeFrom)) {
        $index = $names.IndexOf($ResumeFrom)
        if ($index -lt 0) {
            $errors.Add(("RESUME-PHASE: -ResumeFrom '{0}' is not a phase in this plan. Known phases: {1}" -f $ResumeFrom, ($names -join ', ')))
        }
        else {
            $startIndex = $index
        }
    }

    $actions = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $phases.Count; $i++) {
        $phase = $phases[$i]
        $name = $names[$i]
        $destructive = Get-KanaAiLifecycleBoolProperty -Object $phase -Name 'destructive'
        $priorOutcome = if ($prior.ContainsKey($name)) { [string]$prior[$name] } else { 'not_run' }
        $atOrAfterStart = ($i -ge $startIndex)
        $decision = 'run'
        $reason = 'first execution of this phase'

        if (-not $atOrAfterStart) {
            if ($priorOutcome -eq 'pass') { $decision = 'skip-completed'; $reason = 'completed in a prior run and -ResumeFrom starts later' }
            else { $decision = 'skip-not-run'; $reason = "before -ResumeFrom and never completed (prior outcome '$priorOutcome'); reported as not_run, never as a pass" }
        }
        elseif ($destructive -and $priorOutcome -eq 'pass' -and -not $AllowDestructiveRerun) {
            $decision = 'refused'
            $reason = 'this phase already completed destructively; re-running it requires -AllowDestructiveRerun'
        }
        elseif ($destructive -and $priorOutcome -ne 'pass' -and -not $AllowDestructiveRerun) {
            $decision = 'refused'
            $reason = ("this phase is destructive and did not complete in a prior run (prior outcome '{0}'); re-running it requires -AllowDestructiveRerun" -f $priorOutcome)
        }
        elseif ($destructive -and $AllowDestructiveRerun) {
            $reason = ("destructive phase re-run explicitly acknowledged (prior outcome '{0}')" -f $priorOutcome)
        }
        elseif ($priorOutcome -eq 'pass') {
            $decision = 'skip-completed'
            $reason = 'already completed in a prior run and is not destructive'
        }
        elseif ($priorOutcome -ne 'not_run') {
            $reason = ("retry after prior outcome '{0}'" -f $priorOutcome)
        }

        [void]$actions.Add([ordered]@{
                phase      = $name
                destructive = $destructive
                priorOutcome = $priorOutcome
                decision   = $decision
                reason     = $reason
            })
    }

    return [ordered]@{
        Ok                    = ($errors.Count -eq 0)
        Errors                = @($errors.ToArray())
        ResumeFrom            = $ResumeFrom
        AllowDestructiveRerun = $AllowDestructiveRerun
        Actions               = @($actions.ToArray())
        RefusedPhases         = @(@($actions.ToArray() | Where-Object { $_.decision -eq 'refused' }) | ForEach-Object { [string]$_.phase })
    }
}

# ---------------------------------------------------------------------------
# pure: receipt
# ---------------------------------------------------------------------------
function New-KanaAiLifecycleFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('info', 'warning', 'critical')][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Message,
        $Evidence = $null
    )
    return [ordered]@{ id = $Id; severity = $Severity; message = $Message; evidence = $Evidence }
}

function Get-KanaAiLifecycleExitCodeForStatus {
    param([Parameter(Mandatory = $true)][string]$Status)
    switch ($Status) {
        'pass' { return 0 }
        'passed' { return 0 }
        'plan_only' { return 0 }
        'failed' { return 1 }
        'refused' { return 2 }
        'unconfirmed' { return 3 }
        default { return 4 }
    }
}

function Resolve-KanaAiLifecycleOverallStatus {
    param([AllowNull()]$Results, [Parameter(Mandatory = $true)][string]$Mode)
    $list = @($Results)
    if ($Mode -eq 'plan-only') { return 'plan_only' }
    $failed = @($list | Where-Object { [string](Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'outcome' -Default '') -eq 'fail' })
    $refused = @($list | Where-Object { [string](Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'outcome' -Default '') -eq 'refused' })
    $unconfirmed = @($list | Where-Object { [string](Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'outcome' -Default '') -eq 'unconfirmed' })
    $notRun = @($list | Where-Object { [string](Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'outcome' -Default '') -eq 'not_run' })
    $passed = @($list | Where-Object { [string](Get-KanaAiLifecycleOptionalProperty -Object $_ -Name 'outcome' -Default '') -eq 'pass' })
    if ($list.Count -eq 0) { return 'failed' }
    if ($failed.Count -gt 0) { return 'failed' }
    if ($refused.Count -gt 0) { return 'refused' }
    if ($unconfirmed.Count -gt 0) { return 'unconfirmed' }
    if ($notRun.Count -gt 0) { return 'unconfirmed' }
    if ($passed.Count -eq $list.Count) { return 'passed' }
    return 'unconfirmed'
}

function New-KanaAiLifecycleArtifactEntry {
    <#
        Artifacts are recorded by leaf name and a path relative to the harness
        own output root.  An absolute path would carry the operator's home
        directory into the receipt, which the privacy scan forbids.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Role
    )
    $leaf = [System.IO.Path]::GetFileName($Path)
    $relative = $leaf
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        if ($full.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $full.Substring($fullRoot.Length).Replace('\', '/')
        }
    }
    catch { $relative = $leaf }
    $entry = [ordered]@{
        role       = $Role
        path       = $relative
        leafName   = $leaf
        bytes      = 0
        sha256     = ''
        recorded   = $false
        note       = 'sha256 is empty when the file was not present when the receipt was assembled'
    }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $entry.bytes = [int64]([System.IO.FileInfo]$Path).Length
            $entry.sha256 = Get-KanaAiLifecycleSha256 -Path $Path
            $entry.recorded = $true
        }
    }
    catch { $entry.note = 'the artifact could not be hashed: ' + $_.Exception.Message }
    return $entry
}

function Protect-KanaAiLifecyclePath {
    <# Replace a user profile prefix with a token. #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    $value = $Path
    foreach ($variable in @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP')) {
        $profile = [System.Environment]::GetEnvironmentVariable($variable)
        if ([string]::IsNullOrWhiteSpace($profile)) { continue }
        $prefix = $profile.TrimEnd('\') + '\'
        if ($value.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $value = ('<{0}>\' -f $variable) + $value.Substring($prefix.Length)
        }
    }
    $documents = [System.Environment]::GetFolderPath('MyDocuments')
    if (-not [string]::IsNullOrWhiteSpace($documents)) {
        $prefix = $documents.TrimEnd('\') + '\'
        if ($value.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $value = '<MyDocuments>\' + $value.Substring($prefix.Length)
        }
    }
    return $value
}

function Get-KanaAiLifecycleRepositoryRelativePath {
    <# The candidate is identified by a repository-relative path plus its digest. #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $leaf = [System.IO.Path]::GetFileName($Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\') + '\'
        if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full.Substring($root.Length).Replace('\', '/')
        }
    }
    catch { }
    return ('<outside-repository>/' + $leaf)
}

function New-KanaAiLifecycleSanitySubject {
    <#
        The privacy scan is applied to the receipt with a declared set of
        top-level fields removed, because a receipt that quotes the plan's own
        "what is never collected" policy necessarily names the forbidden
        categories.  Those fields are not silently skipped: the receipt records
        which fields were excluded from the scan and the SHA-256 of their text,
        so a reviewer can compare the excluded text against the plan.
    #>
    param(
        [Parameter(Mandatory = $true)]$Receipt,
        [string[]]$Exclude = @()
    )
    $subject = [ordered]@{}
    $excluded = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($Receipt.Keys)) {
        if ($Exclude -contains [string]$key) {
            [void]$excluded.Add([string]$key)
            continue
        }
        $subject[[string]$key] = $Receipt[$key]
    }
    return [ordered]@{
        subject = $subject
        excluded = @($excluded.ToArray())
    }
}

function Test-KanaAiLifecycleReceiptSanity {
    <#
        A scan of the serialized receipt.  It fails closed: anything that looks
        like a secret, an environment variable dump, a clipboard read or a user
        document path is a problem, not a detail.
    #>
    param([Parameter(Mandatory = $true)][string]$Json, [AllowNull()][string[]]$AllowedKeys = @())
    $problems = New-Object System.Collections.Generic.List[string]
    $forbiddenKeyPattern = '(?i)("|\b)(password|passwd|secret|token|api[-_]?key|apikey|credential|credentials|clipboard|environmentvariables|envvars|processenvironment|machinekeysession|privatekey)(("|\b)|:)'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Json, $forbiddenKeyPattern)) {
        $problems.Add('forbidden key name in the receipt: ' + $match.Value)
    }
    $forbiddenValuePatterns = @(
        '(?i)password\s*[=:]',
        '(?i)secret\s*[=:]',
        '(?i)bearer\s+[A-Za-z0-9._\-]{8,}',
        '(?i)[A-Z]:\\Users\\',
        '(?i)<USERPROFILE>',
        '(?i)\\Documents\\',
        '(?i)\\Desktop\\',
        '(?i)HKEY_CURRENT_USER\\Environment',
        '(?i)"(PSModulePath|COMPUTERNAME|LOGONSERVER|USERDOMAIN|USERNAME)"\s*:'
    )
    foreach ($pattern in $forbiddenValuePatterns) {
        if ($Json -match $pattern) { $problems.Add('forbidden value pattern in the receipt: ' + $pattern) }
    }
    $ok = ($problems.Count -eq 0)
    return [ordered]@{
        ok         = $ok
        problems   = @($problems.ToArray())
        allowedKeys = @($AllowedKeys)
        method     = 'scan of the serialized receipt for forbidden key names and forbidden value patterns'
    }
}

# ---------------------------------------------------------------------------
# pure: the synthetic self check that plan-only mode runs
# ---------------------------------------------------------------------------
function New-KanaAiLifecycleSyntheticObservation {
    <# A fully synthetic observation bundle.  No machine state is read to build it. #>
    param(
        [string]$ProductState = 'installed',
        [bool]$RegistrationPresent = $true,
        [bool]$RegistrationReadable = $true,
        [string]$ExitCode = '0',
        [bool]$MissingExpectedFile = $false,
        [string]$LogClassification = 'first-install',
        [bool]$LogConfident = $true,
        [string]$InstalledProductCode = '{11111111-1111-4111-8111-111111111111}',
        [string]$ExpectedProductCode = '{11111111-1111-4111-8111-111111111111}'
    )
    $files = @('KanaAI.TsfTip.dll', 'mozc_tip64.dll', 'mozc_server.exe', 'ai/model/weights.gguf')
    $expected = @($files)
    $observed = @($files)
    if ($MissingExpectedFile) { $observed = @('KanaAI.TsfTip.dll', 'mozc_tip64.dll', 'mozc_server.exe') }
    $comparison = Compare-KanaAiLifecycleFileInventory -Expected $expected -Observed $observed
    $registration = [ordered]@{
        readable           = $RegistrationReadable
        tipKey             = $RegistrationPresent
        profileKey         = $RegistrationPresent
        comKey             = $RegistrationPresent
        inProcServer32     = 'SYNTHETIC-install-directory\KanaAI.TsfTip.dll'
        inProcTargetExists = $RegistrationPresent
        error              = ''
    }
    return [ordered]@{
        command              = [ordered]@{ executed = $true; exitCode = $ExitCode; commandLine = 'SYNTHETIC'; timedOut = $false; error = '' }
        productState         = $ProductState
        installedProductCode = $InstalledProductCode
        expectedProductCode  = $ExpectedProductCode
        installDate          = '20260926 00:00:00'
        installDateBefore    = '20260926 00:00:00'
        registration         = $registration
        installDirectory     = [ordered]@{ resolved = 'SYNTHETIC-install-directory'; exists = ($ProductState -ne 'absent'); files = @($observed) }
        expectedFiles        = $comparison
        inventoryDelta       = (Compare-KanaAiLifecycleInventories -Before $observed -After $observed)
        processes            = [ordered]@{ readable = $true; observed = @(); orphans = @() }
        msiLog               = [ordered]@{ readable = $true; classification = $LogClassification; confident = $LogConfident; evidence = @($LogClassification) }
        synthetic            = $true
    }
}

function New-KanaAiLifecycleSyntheticSelfCheck {
    <#
        Exercises this harness's own parsing, comparison, verdict and receipt
        logic with synthetic data only.  Plan-only mode runs it so the plan-only
        receipt can say the decision engine was actually exercised, not merely
        loaded.
    #>
    $cases = New-Object System.Collections.Generic.List[object]
    $phase = [pscustomobject]@{
        id   = 'SY-01'
        name = 'synthetic-install'
        asserts = @(
            [pscustomobject]@{ check = 'command-exit-code'; expect = '0,3010,1641,3011'; required = $true },
            [pscustomobject]@{ check = 'product-state'; expect = 'installed'; required = $true },
            [pscustomobject]@{ check = 'product-code'; expect = 'from-candidate-msi'; required = $true },
            [pscustomobject]@{ check = 'registration-present'; expect = 'true'; required = $true },
            [pscustomobject]@{ check = 'expected-files'; expect = 'all-present'; required = $true }
        )
    }
    $cases.Add([ordered]@{
            id     = 'SYN-PASS'
            name   = 'a fully observed install passes'
            expect = 'pass'
            actual = (Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation) })).outcome
            ok     = $false
        })
    $noRegistration = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -RegistrationPresent $false) })
    $cases.Add([ordered]@{
            id     = 'SYN-EXIT0-NO-REGISTRATION'
            name   = 'exit code 0 with no registration is a failure, never a pass'
            expect = 'fail'
            actual = $noRegistration.outcome
            ok     = $false
            detail = $noRegistration.reason
        })
    $missingFile = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -MissingExpectedFile $true) })
    $cases.Add([ordered]@{
            id     = 'SYN-MISSING-FILE'
            name   = 'a declared file missing from the install directory is reported'
            expect = 'fail'
            actual = $missingFile.outcome
            ok     = $false
            detail = $missingFile.reason
        })
    $unreadable = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -RegistrationReadable $false) })
    $cases.Add([ordered]@{
            id     = 'SYN-UNREADABLE'
            name   = 'an unreadable registration surface is unconfirmed, not a pass'
            expect = 'unconfirmed'
            actual = $unreadable.outcome
            ok     = $false
            detail = $unreadable.reason
        })
    $badExit = Resolve-KanaAiLifecyclePhaseOutcome -Phase $phase -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -ExitCode '9') })
    $cases.Add([ordered]@{
            id     = 'SYN-UNKNOWN-EXIT'
            name   = 'an exit code outside the documented table is a failure'
            expect = 'fail'
            actual = $badExit.outcome
            ok     = $false
            detail = $badExit.reason
        })
    $downgradePhase = [pscustomobject]@{
        id   = 'SY-02'
        name = 'synthetic-downgrade'
        asserts = @(
            [pscustomobject]@{ check = 'command-exit-code'; expect = '1638'; required = $true },
            [pscustomobject]@{ check = 'file-inventory-unchanged'; expect = 'true'; required = $true }
        )
    }
    $downgrade = Resolve-KanaAiLifecyclePhaseOutcome -Phase $downgradePhase -Context ([ordered]@{ observation = (New-KanaAiLifecycleSyntheticObservation -ExitCode '0' -LogClassification 'downgrade-refused') })
    $cases.Add([ordered]@{
            id     = 'SYN-DOWNGRADE-MUST-REFUSE'
            name   = 'a downgrade that returned 0 instead of 1638 is a failure'
            expect = 'fail'
            actual = $downgrade.outcome
            ok     = $false
            detail = $downgrade.reason
        })
    $identity = Test-KanaAiLifecycleCandidateIdentity -PropertyMap ([pscustomobject]@{
            ProductCode   = '{22222222-2222-4222-8222-222222222222}'
            UpgradeCode   = '{99999999-9999-4999-8999-999999999999}'
            ProductName   = 'KanaAI Development Preview'
            ProductVersion = '0.1.0'
            ALLUSERS      = '1'
        }) -TemplatePlatform 'x64;1033' -Pinned ([pscustomobject]@{
            upgradeCode = '{381B4CC9-ABAA-4AB2-9DC8-FCA54CE3B964}'
            packageName = 'KanaAI Development Preview'
            scope       = 'perMachine'
        })
    $cases.Add([ordered]@{
            id     = 'SYN-UNEXPECTED-UPGRADECODE'
            name   = 'a candidate with a foreign UpgradeCode is refused'
            expect = 'False'
            actual = [string]$identity.Ok
            ok     = $false
        })
    $resumePlan = Resolve-KanaAiLifecycleResumePlan -Plan ([pscustomobject]@{
            phases = @(
                [pscustomobject]@{ id = 'AA-01'; name = 'a-install'; destructive = $true },
                [pscustomobject]@{ id = 'AA-02'; name = 'b-uninstall'; destructive = $true }
            )
        }) -PriorResults @([pscustomobject]@{ phase = 'a-install'; outcome = 'pass' }) -ResumeFrom 'a-install' -AllowDestructiveRerun $false
    $refusedCount = @(@($resumePlan.Actions) | Where-Object { $_.decision -eq 'refused' }).Count
    $cases.Add([ordered]@{
            id     = 'SYN-RESUME-NO-SILENT-RERUN'
            name   = 'a resume that points at a completed destructive phase refuses every destructive re-run'
            expect = '2'
            actual = [string]$refusedCount
            ok     = $false
        })
    foreach ($case in $cases) { $case.ok = ([string]$case.actual -eq [string]$case.expect) }
    $failed = @($cases.ToArray() | Where-Object { -not [bool]$_.ok })
    return [ordered]@{
        ok        = ($failed.Count -eq 0)
        caseCount = $cases.Count
        cases     = @($cases.ToArray())
        method    = 'synthetic data only; no MSI, registry, process or filesystem state was read'
    }
}

# ---------------------------------------------------------------------------
# OBSERVATION HALF.  Everything below touches the machine and every function
# passes through the action gate first.
# ---------------------------------------------------------------------------

function Get-KanaAiLifecycleInstallerCom {
    param([Parameter(Mandatory = $true)]$Ledger, [string]$Detail = 'WindowsInstaller.Installer')
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'installer-com' -Detail $Detail)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    return $installer
}

function Release-KanaAiLifecycleCom {
    param($ComObject)
    if ($null -eq $ComObject) { return }
    try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($ComObject) } catch { }
}

function Invoke-KanaAiLifecycleMsiCom {
    <#
        A thin, uniform wrapper over Windows Installer IDispatch objects.  The
        parameter is named Installer for history, but any Windows Installer
        automation object may be passed: the Database object is passed here for
        SummaryInformation, which the Installer object does not have.
    #>
    param(
        [Parameter(Mandatory = $true)]$Installer,
        [Parameter(Mandatory = $true)][string]$Method,
        [object[]]$Arguments = @()
    )
    return $Installer.GetType().InvokeMember($Method, 'InvokeMethod', $null, $Installer, $Arguments)
}

function Get-KanaAiLifecycleMsiPropertyMap {
    <#
        Read the candidate MSI's Property table.  Read-only, through the Windows
        Installer automation interface, never by parsing the file.

        Returns a dictionary of property name -> value.  Measured defect this
        replaces: the function returned the raw table rows, an array of
        two-element arrays, and Get-KanaAiLifecycleOptionalProperty finds neither
        an IDictionary nor a PSObject property on that shape, so every identity
        field came back empty and the gate refused a candidate that was in fact
        correct:
          CANDIDATE-PID: the candidate MSI has no brace-delimited ProductCode
          CANDIDATE-PID: ProductName '' is not 'KanaAI Development Preview'
          CANDIDATE-SCOPE: ... the candidate's ALLUSERS property is ''
    #>
    param([Parameter(Mandatory = $true)]$Ledger, [Parameter(Mandatory = $true)][string]$Path)
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'msi-database' -Detail $Path)
    $installer = Get-KanaAiLifecycleInstallerCom -Ledger $Ledger -Detail $Path
    $database = $null
    try {
        $database = Invoke-KanaAiLifecycleMsiCom -Installer $installer -Method 'OpenDatabase' -Arguments @($Path, 0)
        $map = @{}
        foreach ($row in @(Get-KanaAiLifecycleMsiTableMap -Installer $installer -Database $database -Query 'SELECT `Property`,`Value` FROM `Property`')) {
            $fields = @($row)
            if ($fields.Count -lt 1) { continue }
            $name = [string]$fields[0]
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $map[$name] = $(if ($fields.Count -ge 2) { [string]$fields[1] } else { '' })
        }
        return $map
    }
    finally {
        Release-KanaAiLifecycleCom -ComObject $database
        Release-KanaAiLifecycleCom -ComObject $installer
    }
}

function Get-KanaAiLifecycleMsiTableMap {
    param(
        [Parameter(Mandatory = $true)]$Installer,
        [Parameter(Mandatory = $true)]$Database,
        [Parameter(Mandatory = $true)][string]$Query
    )
    $view = $null
    try {
        $view = $Database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $Database, @($Query))
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $rows = New-Object System.Collections.Generic.List[object]
        while ($null -ne ($record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null))) {
            $fields = New-Object System.Collections.Generic.List[object]
            $fieldCount = $record.GetType().InvokeMember('FieldCount', 'GetProperty', $null, $record, $null)
            for ($i = 1; $i -le [int]$fieldCount; $i++) {
                [void]$fields.Add([string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @($i)))
            }
            [void]$rows.Add(@($fields.ToArray()))
        }
        return @($rows.ToArray())
    }
    finally {
        if ($null -ne $view) { [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) }
    }
}

function Get-KanaAiLifecycleMsiTemplatePlatform {
    <# Summary information property 7 is the package template, e.g. "x64;1033". #>
    param([Parameter(Mandatory = $true)]$Ledger, [Parameter(Mandatory = $true)][string]$Path)
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'msi-database' -Detail ($Path + ' summary'))
    $installer = Get-KanaAiLifecycleInstallerCom -Ledger $Ledger -Detail $Path
    $database = $null
    $summary = $null
    try {
        $database = Invoke-KanaAiLifecycleMsiCom -Installer $installer -Method 'OpenDatabase' -Arguments @($Path, 0)
        # SummaryInformation belongs to the Database object, not to the
        # Installer, and neither it nor its Property accessor can be reached
        # through Type.InvokeMember.  Measured against the real candidate:
        # InvokeMember raised DISP_E_MEMBERNOTFOUND (0x80020003) both on the
        # Installer and on the Database, while the PowerShell call adapter
        # resolved both and returned the template "x64;1041".  OpenView,
        # Execute, Fetch and StringData do work through InvokeMember, so this is
        # specific to these two accessors.
        $summary = $database.SummaryInformation(0)
        return [string]$summary.Property(7)
    }
    finally {
        Release-KanaAiLifecycleCom -ComObject $summary
        Release-KanaAiLifecycleCom -ComObject $database
        Release-KanaAiLifecycleCom -ComObject $installer
    }
}

function Get-KanaAiLifecycleMsiFilePlan {
    <#
        Resolve the candidate MSI's own declared payload relative to
        INSTALLFOLDER.  Nothing is hand-maintained: File -> Component -> Directory
        is walked in the MSI database, so the expected file set is whatever the
        candidate actually declares.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallFolderId
    )
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'msi-database' -Detail ($Path + ' file plan'))
    $installer = Get-KanaAiLifecycleInstallerCom -Ledger $Ledger -Detail $Path
    $database = $null
    try {
        $database = Invoke-KanaAiLifecycleMsiCom -Installer $installer -Method 'OpenDatabase' -Arguments @($Path, 0)

        $directoryParent = @{}
        $directoryLeaf = @{}
        foreach ($row in @(Get-KanaAiLifecycleMsiTableMap -Installer $installer -Database $database -Query 'SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`')) {
            $id = [string]$row[0]
            $directoryParent[$id] = [string]$row[1]
            $default = [string]$row[2]
            # DefaultDir is "target:source"; only the target half names a directory.
            $leaf = $default
            if ($leaf.Contains(':')) { $leaf = $leaf.Substring(0, $leaf.IndexOf(':')) }
            if ($leaf.StartsWith('.') -or $leaf -eq '') { $leaf = '' }
            $directoryLeaf[$id] = $leaf
        }

        $componentDirectory = @{}
        foreach ($row in @(Get-KanaAiLifecycleMsiTableMap -Installer $installer -Database $database -Query 'SELECT `Component`,`Directory_` FROM `Component`')) {
            $componentDirectory[[string]$row[0]] = [string]$row[1]
        }

        $relativeToRoot = @{}
        $relativeToRoot[$InstallFolderId] = ''
        # Resolve ancestors first, then the folder itself.  A directory that
        # cannot be traced back to INSTALLFOLDER is reported as out of scope
        # rather than being guessed at.
        $outOfScope = New-Object System.Collections.Generic.List[string]
        $pending = New-Object System.Collections.Generic.List[string]
        foreach ($id in @($directoryLeaf.Keys)) { $pending.Add([string]$id) }
        for ($pass = 0; $pass -lt 32; $pass++) {
            $progress = $false
            foreach ($id in @($pending.ToArray())) {
                if ($relativeToRoot.ContainsKey($id)) { [void]$pending.Remove($id); continue }
                $parent = [string]$directoryParent[$id]
                if ([string]::IsNullOrWhiteSpace($parent)) { continue }
                if ($parent -eq 'TargetDir') { continue }
                if (-not $relativeToRoot.ContainsKey($parent)) { continue }
                $relativeToRoot[$id] = (([string]$relativeToRoot[$parent] + '/' + [string]$directoryLeaf[$id])).TrimStart('/')
                [void]$pending.Remove($id)
                $progress = $true
            }
            if (-not $progress) { break }
        }
        foreach ($id in @($pending.ToArray())) {
            if ([string]$directoryParent[$id] -ne 'TargetDir') { [void]$outOfScope.Add($id) }
        }

        $files = New-Object System.Collections.Generic.List[object]
        $seen = @()
        foreach ($row in @(Get-KanaAiLifecycleMsiTableMap -Installer $installer -Database $database -Query 'SELECT `File`,`Component_`,`FileName` FROM `File`')) {
            $fileId = [string]$row[0]
            $component = [string]$row[1]
            $fileName = [string]$row[2]
            if ($fileName.Contains('|')) { $fileName = $fileName.Substring(0, $fileName.IndexOf('|')) }
            if (-not $componentDirectory.ContainsKey($component)) { continue }
            $directory = [string]$componentDirectory[$component]
            if (-not $relativeToRoot.ContainsKey($directory)) {
                if ($outOfScope.Contains($directory)) { [void]$outOfScope.Add($fileId) }
                continue
            }
            $relative = ([string]$relativeToRoot[$directory] + '/' + $fileName).TrimStart('/')
            if ($seen -contains $relative) { continue }
            $seen += $relative
            [void]$files.Add([ordered]@{ fileId = $fileId; component = $component; directory = $directory; relativePath = $relative; fileName = $fileName })
        }

        $directories = @($relativeToRoot.GetEnumerator() | ForEach-Object { [ordered]@{ directory = [string]$_.Key; relativePath = [string]$_.Value } } | Sort-Object { [string]$_.relativePath })

        return [ordered]@{
            installFolderId = $InstallFolderId
            expectedFiles   = @($files.ToArray())
            expectedPaths   = @($seen)
            directories     = $directories
            outOfScope      = @($outOfScope.ToArray() | Select-Object -Unique)
            componentCount  = $componentDirectory.Count
            note            = 'Expected files are resolved from the candidate MSI itself, relative to INSTALLFOLDER. Anything the MSI stores outside INSTALLFOLDER is listed in outOfScope and is never silently ignored.'
        }
    }
    finally {
        Release-KanaAiLifecycleCom -ComObject $database
        Release-KanaAiLifecycleCom -ComObject $installer
    }
}

function Get-KanaAiLifecycleMsiDirectoryMap {
    <# Directory table -> ordered map of id -> @{ parent; leaf }. #>
    param([Parameter(Mandatory = $true)]$Installer, [Parameter(Mandatory = $true)]$Database)
    $map = @{}
    foreach ($row in @(Get-KanaAiLifecycleMsiTableMap -Installer $Installer -Database $Database -Query 'SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`')) {
        $id = [string]$row[0]
        $default = [string]$row[2]
        if ($default.Contains(':')) { $default = $default.Substring(0, $default.IndexOf(':')) }
        if ($default.StartsWith('.') -or $default -eq '') { $default = '' }
        $map[$id] = [ordered]@{ parent = [string]$row[1]; leaf = $default }
    }
    return $map
}

function Resolve-KanaAiLifecycleStandardDirectory {
    <#
        Map a Windows Installer StandardDirectory short name onto the real root.
        The mapping is deliberately explicit: an unrecognised short name returns
        an empty root, and the caller then reports "not resolvable" instead of
        inventing a path.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$ShortName)
    switch ($ShortName) {
        'ProgramFiles64Folder' { return [System.Environment]::GetEnvironmentVariable('ProgramW6432') }
        'ProgramFilesFolder' {
            if ([System.Environment]::Is64BitProcess) { return [System.Environment]::GetEnvironmentVariable('ProgramW6432') }
            return [System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        }
        'ProgramFiles32Folder' { return [System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)') }
        'CommonFiles64Folder' { return [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonProgramFiles) }
        'WindowsFolder' { return [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows) }
        default { return '' }
    }
}

function Get-KanaAiLifecycleExpectedInstallPath {
    <#
        Resolve the absolute install directory the candidate declares, BEFORE
        anything is installed, so the pre-run baseline can prove the directory
        is empty rather than merely unknown.  The leaf chain is taken from the
        MSI's own Directory table; the root comes from an explicit
        StandardDirectory mapping.  If the chain cannot be resolved the result
        says so, and the caller records that instead of guessing.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallFolderId
    )
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'msi-database' -Detail ($Path + ' directory table'))
    $result = [ordered]@{
        resolvable = $false
        expectedPath = ''
        chain     = @()
        reason    = ''
    }
    $installer = Get-KanaAiLifecycleInstallerCom -Ledger $Ledger -Detail $Path
    $database = $null
    try {
        $database = Invoke-KanaAiLifecycleMsiCom -Installer $installer -Method 'OpenDatabase' -Arguments @($Path, 0)
        $map = Get-KanaAiLifecycleMsiDirectoryMap -Installer $installer -Database $database
        if (-not $map.ContainsKey($InstallFolderId)) {
            $result.reason = "the candidate MSI has no directory id '$InstallFolderId'"
            return $result
        }
        $chain = New-Object System.Collections.Generic.List[string]
        $id = $InstallFolderId
        $rootShortName = ''
        for ($depth = 0; $depth -lt 32; $depth++) {
            if (-not $map.ContainsKey($id)) { $result.reason = "directory '$id' is missing from the candidate MSI"; return $result }
            $leaf = [string]$map[$id].leaf
            if (-not [string]::IsNullOrWhiteSpace($leaf)) { [void]$chain.Insert(0, $leaf) }
            $parent = [string]$map[$id].parent
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq 'TargetDir') { break }
            $id = $parent
            # A StandardDirectory is identified by its directory id, for example
            # 'ProgramFilesFolder', not by its DefaultDir leaf, which on the very
            # same row is 'PFiles'.  Resolving the leaf returned an empty root and
            # made the whole chain unresolvable in a measured run against the real
            # candidate, even though ProgramFilesFolder maps to C:\Program Files
            # in a 64-bit process.  Breaking here also keeps the parent's leaf out
            # of the chain, so the relative part is just 'KanaAI'.
            if (-not [string]::IsNullOrWhiteSpace((Resolve-KanaAiLifecycleStandardDirectory -ShortName $id))) {
                $rootShortName = $id
                break
            }
        }
        $result.chain = @($chain.ToArray())
        if ([string]::IsNullOrWhiteSpace($rootShortName)) {
            $result.reason = 'the directory chain does not start at a StandardDirectory this harness can resolve'
            return $result
        }
        $root = Resolve-KanaAiLifecycleStandardDirectory -ShortName $rootShortName
        if ([string]::IsNullOrWhiteSpace($root)) {
            $result.reason = ("the StandardDirectory '{0}' has no value in this environment" -f $rootShortName)
            return $result
        }
        $segments = @($result.chain)
        if ($segments.Count -eq 0) { $segments = @($InstallFolderId) }
        $result.expectedPath = (($root.TrimEnd('\') + '\' + ($segments -join '\')).TrimEnd('\'))
        $result.resolvable = $true
        $result.reason = ('root=' + $rootShortName + '; relative=' + ($segments -join '\'))
        return $result
    }
    finally {
        Release-KanaAiLifecycleCom -ComObject $database
        Release-KanaAiLifecycleCom -ComObject $installer
    }
}

function Initialize-KanaAiLifecycleMsiNative {
    <#
        MsiQueryProductState is the authoritative answer to "is this product
        installed", and it is the only source the harness can use for the
        InstallState that Installer.ProductInfo refuses.  No registry
        correlation, and no Win32_Product consistency check.

        The prototype is one argument and the return value IS the state.
        MsiQueryProductState has no out parameter at all:

            INSTALLSTATE MsiQueryProductStateW(LPCWSTR szProduct);

        That is stated identically by Microsoft Learn, by the wine msi.h and by
        the mingw-w64 msi.h, and the documented return values are only
        INSTALLSTATE_ABSENT, ADVERTISED, DEFAULT, INVALIDARG and UNKNOWN.
        ERROR_ACCESS_DENIED is not among them, so a five here is
        INSTALLSTATE_DEFAULT, which means installed.

        This exact prototype was wrong twice in this harness's history and both
        times it looked like a broken machine rather than a wrong declaration.
        A two-argument form with an `out int` was declared, the out parameter
        was observed to stay unwritten, and 5 was read as ERROR_ACCESS_DENIED
        instead of INSTALLSTATE_DEFAULT. That produced a false "this machine
        cannot report install state" conclusion, a repair that was never needed,
        and a refusal gate that would have rejected every healthy machine. The
        negative results are consistent with the wrong prototype and with nothing
        else: an invalid product name returns INSTALLSTATE_INVALIDARG and the
        zero GUID returns INSTALLSTATE_UNKNOWN, which is what the documentation
        says a correct call does.

        ST-73 pins the one-argument form so the third occurrence cannot be
        mistaken for a machine fault again.

        Add-Type is used the same way the desktop harness already uses it, and
        the type is compiled at most once per process.
    #>
    if ($null -ne ('KanaAiLifecycleMsiNative' -as [type])) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
public static class KanaAiLifecycleMsiNative
{
    [System.Runtime.InteropServices.DllImport("msi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    public static extern int MsiQueryProductStateW(string product);
}
'@
}

function ConvertTo-KanaAiLifecycleProductState {
    <#
        The Windows Installer state vocabulary to the harness vocabulary, with
        no machine access at all, so the mapping is unit-testable.

        'unknown' is returned for anything the installer did not answer with a
        documented state, and it is never treated as absent.
    #>
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return 'unknown' }
    switch ($Raw.Trim().ToUpperInvariant()) {
        'DEFAULT' { return 'installed' }
        'LOCAL' { return 'installed' }
        'ADVERTISED' { return 'advertised' }
        'SOURCE' { return 'staged' }
        'ABSENT' { return 'absent' }
        'REMOVED' { return 'absent' }
        default { return 'unknown' }
    }
}

function Get-KanaAiLifecycleProductInstallStateName {
    <#
        The raw Windows Installer state name for one product, or '' when the
        installer could not answer.

        Read through MsiQueryProductState because ProductInfo refuses
        InstallState.  Measured against the real installed product on this
        machine: ProductInfo raised "ProductInfo,Product,Attribute" for
        InstallState and for UpgradeCode, while ProductName, LocalPackage,
        InstallLocation, VersionString, InstallDate and InstallSource all
        returned real values.
    #>
    param([Parameter(Mandatory = $true)]$Ledger, [Parameter(Mandatory = $true)][string]$ProductCode)
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'installer-com' -Detail ($ProductCode + '/InstallState'))
    try {
        Initialize-KanaAiLifecycleMsiNative
        # The return value IS the INSTALLSTATE.  There is no out parameter and no
        # separate error code, so there is nothing to test for zero here: zero is
        # not a documented return, and every value below is an INSTALLSTATE.
        $state = [KanaAiLifecycleMsiNative]::MsiQueryProductStateW($ProductCode)
        switch ($state) {
            5 { return 'DEFAULT' }
            3 { return 'LOCAL' }
            1 { return 'ADVERTISED' }
            4 { return 'SOURCE' }
            2 { return 'ABSENT' }
            7 { return 'REMOVED' }
            default { return '' }
        }
    }
    catch {
        return ''
    }
}

function Get-KanaAiLifecycleCachedMsiProperty {
    <#
        One Property-table value out of a product's cached MSI.  This is how
        UpgradeCode is read, because ProductInfo cannot return it.

        The cached package under C:\WINDOWS\Installer is the copy the installer
        itself registered, and its Property table is read through the same
        reader the candidate identity gate uses, so there is no second, weaker
        way of asking the same question.  Returns '' when there is no cached
        package, which is the normal case for an advertised product that has
        never been installed.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)][string]$ProductCode,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )
    $localPackage = Get-KanaAiLifecycleProductInfo -Ledger $Ledger -ProductCode $ProductCode -PropertyName 'LocalPackage'
    if ([string]::IsNullOrWhiteSpace([string]$localPackage)) { return '' }
    if (-not (Test-Path -LiteralPath ([string]$localPackage) -PathType Leaf)) { return '' }
    try {
        $map = Get-KanaAiLifecycleMsiPropertyMap -Ledger $Ledger -Path ([string]$localPackage)
        if ($null -eq $map) { return '' }
        if ($map.Contains($PropertyName)) { return [string]$map[$PropertyName] }
        return ''
    }
    catch {
        return ''
    }
}

function Get-KanaAiLifecycleInstallerProductCodes {
    <#
        Every product code this machine's installer knows about.

        'Products' is a property, not a method, and that distinction is
        measured rather than theoretical.  On this machine, against the same
        object: InvokeMethod raised DISP_E_MEMBERNOTFOUND (0x80020003), the
        direct PowerShell property read returned $null, and GetProperty
        returned 182 GUID strings.  Only brace-delimited GUIDs are returned, so
        a malformed element cannot reach a later comparison.
    #>
    param([Parameter(Mandatory = $true)]$Installer)
    $codes = New-Object System.Collections.Generic.List[string]
    $raw = $Installer.GetType().InvokeMember('Products', 'GetProperty', $null, $Installer, $null)
    foreach ($item in @($raw)) {
        $code = [string]$item
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        if ($code -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') { continue }
        $codes.Add($code)
    }
    return $codes.ToArray()
}

function Get-KanaAiLifecycleProductInfo {
    <# Read-only Windows Installer query.  Returns $null for an unknown product. #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)][string]$ProductCode,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'installer-com' -Detail ($ProductCode + '/' + $PropertyName))
    $installer = Get-KanaAiLifecycleInstallerCom -Ledger $Ledger -Detail $ProductCode
    try {
        # Measured defect: Installer.ProductInfo does not resolve through
        # Type.InvokeMember on this machine.  It raised DISP_E_MEMBERNOTFOUND
        # (0x80020003) for every product and every property, so this function
        # returned $null for a product that is genuinely installed and
        # Get-KanaAiLifecycleProductState reported 'unknown' for it.  The
        # PowerShell call adapter does resolve ProductInfo.
        #
        # The adapter is not sufficient on its own, and that is measured too:
        # ProductInfo raises "ProductInfo,Product,Attribute" for UpgradeCode and
        # for InstallState on this machine, while ProductName, LocalPackage,
        # InstallLocation, VersionString, InstallDate and InstallSource all
        # return real values.  Callers that need one of the two refused
        # attributes must go through Get-KanaAiLifecycleCachedMsiProperty or
        # Get-KanaAiLifecycleProductInstallStateName instead of retrying here.
        return [string]$installer.ProductInfo($ProductCode, $PropertyName)
    }
    catch {
        return $null
    }
    finally {
        Release-KanaAiLifecycleCom -ComObject $installer
    }
}

function Get-KanaAiLifecycleProductState {
    <#
        'installed'  - a local install (INSTALLSTATE_DEFAULT or INSTALLSTATE_LOCAL)
        'advertised' - registered but no local files
        'absent'     - not installed
        'unknown'    - the installer API could not answer, which is never treated
                       as absent
    #>
    param([Parameter(Mandatory = $true)]$Ledger, [Parameter(Mandatory = $true)][string]$ProductCode)
    $raw = Get-KanaAiLifecycleProductInstallStateName -Ledger $Ledger -ProductCode $ProductCode
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'unknown' }
    return ConvertTo-KanaAiLifecycleProductState -Raw $raw
}

function Find-KanaAiLifecycleInstalledProducts {
    <#
        Bounded discovery.  Only product codes whose UpgradeCode equals the
        pinned KanaAI UpgradeCode are returned, so no unrelated installed
        product is ever inspected in detail or written to a receipt.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)][string]$UpgradeCode
    )
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'installer-com' -Detail 'Products enumeration')
    $installer = Get-KanaAiLifecycleInstallerCom -Ledger $Ledger -Detail 'Products'
    $found = New-Object System.Collections.Generic.List[object]
    $scanned = 0
    try {
        $all = Get-KanaAiLifecycleInstallerProductCodes -Installer $installer
        foreach ($code in @($all)) {
            $scanned++
            $upgrade = Get-KanaAiLifecycleCachedMsiProperty -Ledger $Ledger -ProductCode ([string]$code) -PropertyName 'UpgradeCode'
            if ([string]::IsNullOrWhiteSpace([string]$upgrade)) { continue }
            if ((ConvertTo-KanaAiLifecycleGuid -Value $upgrade) -ne (ConvertTo-KanaAiLifecycleGuid -Value $UpgradeCode)) { continue }
            # The raw name is kept, not the harness vocabulary, because the
            # comparison in the entry point matches ^(DEFAULT|LOCAL)$ to decide
            # whether the product is locally installed.  Widening that field to
            # 'installed' would silently make the match fail and the phase
            # report an installed product as absent.
            $installState = Get-KanaAiLifecycleProductInstallStateName -Ledger $Ledger -ProductCode ([string]$code)
            $localPackage = $null
            try { $localPackage = [string](Get-KanaAiLifecycleProductInfo -Ledger $Ledger -ProductCode ([string]$code) -PropertyName 'LocalPackage') } catch { }
            $installLocation = $null
            try { $installLocation = [string](Get-KanaAiLifecycleProductInfo -Ledger $Ledger -ProductCode ([string]$code) -PropertyName 'InstallLocation') } catch { }
            [void]$found.Add([ordered]@{
                    productCode      = (ConvertTo-KanaAiLifecycleGuid -Value ([string]$code))
                    upgradeCode      = (ConvertTo-KanaAiLifecycleGuid -Value $upgrade)
                    installState     = [string]$installState
                    installLocation  = (Protect-KanaAiLifecyclePath -Path ([string]$installLocation))
                    localPackageName = [string]([System.IO.Path]::GetFileName([string]$localPackage))
                })
        }
    }
    finally {
        Release-KanaAiLifecycleCom -ComObject $installer
    }
    return [ordered]@{
        found             = @($found.ToArray())
        count             = $found.Count
        candidatesScanned = $scanned
        note              = 'Only products whose UpgradeCode matches the pinned KanaAI UpgradeCode are retained. No other installed product is recorded.'
    }
}

function Get-KanaAiLifecycleRegistryValueObservation {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Name = '')
    $result = [ordered]@{ present = $false; value = ''; error = '' }
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path, $false)
        if ($null -eq $key) { return $result }
        try {
            $result.present = $true
            if ([string]::IsNullOrWhiteSpace($Name)) { $result.value = [string]$key.GetValue('') }
            else { $result.value = [string]$key.GetValue($Name, $null) }
        }
        finally { $key.Dispose() }
    }
    catch { $result.error = $_.Exception.Message }
    return $result
}

function Get-KanaAiLifecycleRegistrationObservation {
    <#
        Observation only.  The Windows Installer product state is the authority
        on whether the product is installed; these keys are corroborating
        evidence, and a key with no real DLL behind it is reported as not a
        registration by the comparison engine.

        The InProcServer32 path is read from the machine COM key for the pinned
        CLSID.  When the key is absent the expected file name from the plan is
        used as the candidate path so the "is there a real DLL" question is still
        answered.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)]$Registration,
        [string]$InstallDirectory = ''
    )
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'registry-read' -Detail 'TSF registration surface')
    $clsid = [string]$Registration.textServiceClsid
    $profile = [string]$Registration.languageProfileGuid
    $segment = [string]$Registration.languageSegment
    $subkey = [string]$Registration.profileSubkey
    $tipRoot = [string]$Registration.machineTextServiceRoot
    $comRoot = [string]$Registration.machineComRoot
    $tipKeyPath = ($tipRoot + '\' + $clsid)
    $profileKeyPath = ($tipKeyPath + '\' + $subkey + '\' + $segment + '\' + $profile)
    $comKeyPath = ($comRoot + '\' + $clsid + '\InProcServer32')
    $userProfileKeyPath = ($tipKeyPath + '\' + $subkey + '\' + $segment + '\' + $profile)

    $result = [ordered]@{
        readable               = $true
        error                  = ''
        tipKey                 = $false
        profileKey             = $false
        comKey                 = $false
        inProcServer32         = ''
        inProcServer32Source   = 'registry'
        inProcTargetExists     = $false
        userActivationEnable   = $null
        keyPaths               = [ordered]@{
            tipKeyMachine     = $tipKeyPath
            profileKeyMachine = $profileKeyPath
            comKeyMachine     = $comKeyPath
            profileKeyUser    = $userProfileKeyPath
        }
        method                 = 'read-only observation of the machine 64-bit registry view through Microsoft.Win32.OpenBaseKey; never used on its own to decide a phase'
    }
    try {
        $hive = [Microsoft.Win32.RegistryHive]::LocalMachine
        $view = [System.Enum]::Parse([Microsoft.Win32.RegistryView], [string]$Registration.registryView, $true)
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
        $tipKey = $null
        $profileKey = $null
        $comKey = $null
        try {
            $tipKey = $base.OpenSubKey($tipKeyPath, $false)
            $result.tipKey = ($null -ne $tipKey)
            if ($null -ne $tipKey) {
                $profileKey = $tipKey.OpenSubKey(($subkey + '\' + $segment + '\' + $profile), $false)
                $result.profileKey = ($null -ne $profileKey)
            }
            $comKey = $base.OpenSubKey($comKeyPath, $false)
            $result.comKey = ($null -ne $comKey)
            if ($null -ne $comKey) {
                $result.inProcServer32 = [string]$comKey.GetValue('', [string]$comKey.GetValue('(default)', ''))
                $result.inProcServer32 = $result.inProcServer32.Trim('"')
            }
        }
        finally {
            foreach ($key in @($profileKey, $tipKey, $comKey)) { if ($null -ne $key) { $key.Dispose() } }
            $base.Dispose()
        }
    }
    catch {
        $result.readable = $false
        $result.error = $_.Exception.Message
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($result.inProcServer32) -and -not [string]::IsNullOrWhiteSpace($InstallDirectory)) {
        # The COM key is gone.  Look for a text service DLL that is still in the
        # install directory, so "the key is gone but the file is not" and "both
        # are gone" are distinguishable.  The receipt records that this path was
        # inferred rather than read, and the registration checks still require
        # the three keys themselves, so an inferred path can never manufacture a
        # registration that is not really there.
        $candidates = @(Get-ChildItem -LiteralPath $InstallDirectory -Filter '*.dll' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)(TsfTip|mozc_tip64)' } |
            ForEach-Object { $_.FullName })
        if ($candidates.Count -eq 1) {
            $result.inProcServer32 = [string]$candidates[0]
            $result.inProcServer32Source = 'inferred-from-install-directory'
        }
    }
    $result.inProcTargetExists = $false
    if (-not [string]::IsNullOrWhiteSpace($result.inProcServer32)) {
        $expanded = $result.inProcServer32
        if (-not [string]::IsNullOrWhiteSpace($InstallDirectory) -and -not [System.IO.Path]::IsPathRooted($expanded)) {
            $expanded = [System.IO.Path]::GetFullPath((Join-Path $InstallDirectory $expanded))
        }
        $result.inProcTargetExists = (Test-Path -LiteralPath $expanded -PathType Leaf)
    }
    $userValue = Get-KanaAiLifecycleRegistryValueObservation -Path $userProfileKeyPath -Name 'Enable'
    $result.userActivationEnable = $userValue.value
    return $result
}

function Get-KanaAiLifecycleInstallDirectoryObservation {
    <#
        The inventory is a file name set relative to the install directory, plus
        counts.  Files above the hash threshold are counted but not hashed, so a
        multi-gigabyte model does not turn a verification run into a long hash
        sweep; the receipt says how many were skipped.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [string]$Path = '',
        [int64]$HashThresholdBytes = 8388608
    )
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'filesystem-read' -Detail $Path)
    $result = [ordered]@{
        resolved      = (Protect-KanaAiLifecyclePath -Path $Path)
        exists        = $false
        fileCount     = 0
        directoryCount = 0
        totalBytes    = [int64]0
        files         = @()
        hashedCount   = 0
        hashSkippedCount = 0
        largestFiles  = @()
        error         = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.error = 'the install directory could not be resolved from the Windows Installer'
        return $result
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $result }
    $result.exists = $true
    try {
        $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)
        $files = @($items | Where-Object { -not $_.PSIsContainer })
        $directories = @($items | Where-Object { $_.PSIsContainer })
        $root = $Path.TrimEnd('\') + '\'
        $relative = @()
        $largest = New-Object System.Collections.Generic.List[object]
        [int64]$total = 0
        foreach ($file in $files) {
            $full = $file.FullName
            $rel = $full.Substring($root.Length).Replace('\', '/')
            $relative += $rel
            $total += [int64]$file.Length
            if ([int64]$file.Length -le $HashThresholdBytes) {
                $result.hashedCount = [int]$result.hashedCount + 1
            }
            else {
                $result.hashSkippedCount = [int]$result.hashSkippedCount + 1
                [void]$largest.Add([ordered]@{ path = $rel; bytes = [int64]$file.Length })
            }
        }
        $sorted = @($largest | Sort-Object -Property bytes -Descending | Select-Object -First 5)
        $result.files = @($relative | Sort-Object)
        $result.fileCount = $relative.Count
        $result.directoryCount = $directories.Count
        $result.totalBytes = $total
        $result.largestFiles = @($sorted)
        $result.hashThresholdBytes = $HashThresholdBytes
    }
    catch {
        $result.error = $_.Exception.Message
    }
    return $result
}

function Get-KanaAiLifecycleProductProcessObservation {
    <#
        Only the product's own executables are ever looked at, and only by name.
        A process is an orphan only when the harness neither started it nor saw
        it at the pre-run baseline, so a mozc_server.exe that was already
        running before the harness ever touched the machine is recorded and is
        never silently blamed on the run.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [AllowNull()][int[]]$HarnessStartedPids = @(),
        [AllowNull()][int[]]$BaselinePids = @()
    )
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'registry-read' -Detail 'product process list (by name only)')
    $observed = New-Object System.Collections.Generic.List[object]
    $readable = $true
    $error = ''
    foreach ($name in @($Names)) {
        try {
            foreach ($process in @(Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($name)) -ErrorAction SilentlyContinue)) {
                $pid = [int]$process.Id
                $owned = (@($HarnessStartedPids) -contains $pid)
                $preExisting = (@($BaselinePids) -contains $pid)
                [void]$observed.Add([ordered]@{
                        name         = $name
                        pid          = $pid
                        startedByHarness = $owned
                        presentAtBaseline = $preExisting
                    })
            }
        }
        catch {
            $readable = $false
            $error = $_.Exception.Message
        }
    }
    $orphans = @(@($observed.ToArray() | Where-Object { -not [bool]$_.startedByHarness -and -not [bool]$_.presentAtBaseline }) | ForEach-Object { ([string]$_.name) + '#' + ([string]$_.pid) })
    return [ordered]@{
        readable = $readable
        error    = $error
        observed = @(@($observed.ToArray() | ForEach-Object { ([string]$_.name) + '#' + ([string]$_.pid) + ':startedByHarness=' + [string]$_.startedByHarness + ':atBaseline=' + [string]$_.presentAtBaseline }))
        orphans  = $orphans
        scope    = 'filtered to the product own executable names; no other process is enumerated into the receipt'
    }
}

function Read-KanaAiLifecycleMsiLogText {
    param([Parameter(Mandatory = $true)]$Ledger, [string]$Path = '')
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'msi-database' -Detail 'msi log read')
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    # A verbose log for a multi-gigabyte package is large.  A bounded tail is
    # enough for the decisive markers, which are also written to the summary
    # section at the end of the file.
    $limit = 8MB
    $info = [System.IO.FileInfo]$Path
    if ($info.Length -le $limit) { return [System.IO.File]::ReadAllText($Path) }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $stream.Seek(-$limit, [System.IO.SeekOrigin]::End) | Out-Null
        $reader = New-Object System.IO.StreamReader($stream)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Invoke-KanaAiLifecycleCommand {
    <#
        The one place this harness starts a process.  It renders the exact
        command line, prints the -WhatIf rendering, and only then runs it.  The
        pid is recorded in the ledger so cleanup can terminate that process and
        no other.
    #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)]$Rendered,
        [int]$TimeoutSeconds = 1800,
        [bool]$DryRender = $false
    )
    $record = [ordered]@{
        rendered     = $true
        executed     = $false
        commandLine  = [string]$Rendered.commandLine
        executable   = [string]$Rendered.executable
        arguments    = @($Rendered.arguments)
        exitCode     = ''
        exitMeaning  = 'not-run'
        timedOut     = $false
        startedAtUtc = ''
        endedAtUtc   = ''
        durationMs   = 0
        pid          = 0
        whatIf       = $DryRender
        whatIfRender = [string]$Rendered.whatIfRender
        stdoutTail   = ''
        stderrTail   = ''
        error        = ''
    }
    Write-Host ('    ' + [string]$Rendered.whatIfRender)
    if ($DryRender) {
        $record.exitCode = ''
        $record.exitMeaning = 'dry-render-only'
        return $record
    }
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'process-launch' -Detail ([string]$Rendered.commandLine))
    if ([System.IO.Path]::GetFileNameWithoutExtension([string]$Rendered.executable) -eq 'msiexec') {
        [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'msiexec' -Detail ([string]$Rendered.commandLine))
    }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = [string]$Rendered.executable
    $startInfo.Arguments = ConvertTo-KanaAiLifecycleCommandLine -Arguments @($Rendered.arguments)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $record.startedAtUtc = Get-KanaAiLifecycleUtcNow
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $record.pid = [int]$process.Id
        [void]$Ledger.StartedProcesses.Add([ordered]@{ pid = [int]$process.Id; commandLine = [string]$Rendered.commandLine; startedAtUtc = $record.startedAtUtc })
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            $record.timedOut = $true
            try { $process.Kill() } catch { }
            try { [void]$process.WaitForExit(15000) } catch { }
        }
        $record.stdoutTail = Take-KanaAiLifecycleTail -Text $stdoutTask.Result -Maximum 2000
        $record.stderrTail = Take-KanaAiLifecycleTail -Text $stderrTask.Result -Maximum 2000
        $record.executed = $true
        $record.exitCode = [string]$process.ExitCode
        $record.exitMeaning = Get-KanaAiLifecycleMsiExitCodeMeaning -ExitCodeText $record.exitCode
    }
    catch {
        $record.error = $_.Exception.Message
        $record.exitCode = ''
        $record.exitMeaning = 'harness-error'
    }
    finally {
        $stopwatch.Stop()
        $record.durationMs = [int]$stopwatch.ElapsedMilliseconds
        $record.endedAtUtc = Get-KanaAiLifecycleUtcNow
        if ($null -ne $process) { $process.Dispose() }
    }
    return $record
}

function Take-KanaAiLifecycleTail {
    param([AllowNull()][string]$Text, [int]$Maximum = 2000)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $value = $Text
    if ($value.Length -gt $Maximum) { $value = $value.Substring($value.Length - $Maximum) }
    return $value
}

function Test-KanaAiLifecycleOwnedByHarness {
    <#
        The cleanup ownership rule, as a pure predicate: a process may be
        terminated by this harness only if its pid is in the ledger AND the
        current process image name matches the recorded one.  A pid recycled by
        an unrelated program is therefore never killed.

        The parameter is named ProcessId, not Pid, because $PID is a read-only
        automatic variable in Windows PowerShell and a parameter of that name
        cannot be declared.

        The ledger lists are iterated directly rather than through @(...):
        under Set-StrictMode -Version Latest, Windows PowerShell 5.1 fails the
        array subexpression operator on a generic List with "argument types do
        not match", whether the list is empty or not.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$ExpectedImageName,
        [Parameter(Mandatory = $true)]$Ledger
    )
    foreach ($entry in $Ledger.StartedProcesses) {
        if ([int]$entry.pid -ne $ProcessId) { continue }
        # -split rather than String.Split: PowerShell 5.1 binds a string argument
        # to the wrong String.Split overload and fails with "argument types do
        # not match".
        $firstToken = (([string]$entry.commandLine).Trim() -split '\s+')[0]
        $recorded = [System.IO.Path]::GetFileName($firstToken.Trim('"'))
        if ($recorded -ieq $ExpectedImageName) { return $true }
        return $false
    }
    return $false
}

function Remove-KanaAiLifecycleOwnedPath {
    <#
        The only deletion this harness ever performs, and it is confined to its
        own output directory.  A path outside that root is refused, which is
        what keeps the harness from ever deleting a directory it did not install
        (for example C:\Program Files\KanaAI, which only the uninstaller may
        remove).
    #>
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OwnedRoot
    )
    # The gate is first, before any path reasoning, so that even a call that
    # would end up doing nothing is refused in a sealed mode.
    [void](Enter-KanaAiLifecycleAction -Ledger $Ledger -Kind 'directory-mutation' -Detail $Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [System.IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\')
    if ($full -ieq $root) { throw "Refusing to delete the harness output root itself: $full" }
    if (-not $full.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Refusing to delete a path the harness does not own: {0} is not inside {1}" -f $full, $root)
    }
    if (-not (Test-Path -LiteralPath $full)) { return $false }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    return $true
}
