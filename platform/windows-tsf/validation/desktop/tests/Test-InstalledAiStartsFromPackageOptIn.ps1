# Does the installed package, by itself, start the local AI?
#
# What this measures, and why it is not the same as earlier AI measurements
# -------------------------------------------------------------------------
# STATE.md 0-L and 0-M measured the AI starting on this machine. Both runs set
# KANAI_BROKER_ENHANCEMENT=local by hand first. That answered "can the shipped
# AI run", and it could not answer "does the shipped product run it", which is
# the question a package that advertises a bundled AI has to answer. The product
# never set that variable anywhere, so the measured answer to the second question
# was no, silently, on every real install.
#
# So this test sets no environment variable. It starts the installed broker with
# the environment it would inherit from the text service and asserts that the AI
# starts anyway - which can only happen if the package itself recorded the opt-in
# that `enhancement_optin.rs` reads.
#
# The second arm is what keeps the first honest. It turns the opt-in off through
# the shipped command, starts the same binary again, and requires the AI not to
# start and to say why. Without that arm, a first arm that passed would not
# distinguish "the package supplied the opt-in" from "this broker starts an AI
# unconditionally", and the second reading is the one that would be a defect.
#
# The user's own record is saved and restored, including the case where there was
# none.
#
# ASCII only on purpose: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.
param(
    [string]$InstallRoot = '',
    [int]$StartupTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Join-Path $env:ProgramFiles 'KanaAI' }
$broker = Join-Path $InstallRoot 'kanai-broker.exe'
if (-not (Test-Path -LiteralPath $broker -PathType Leaf)) { throw "the installed broker is not present: $broker" }

$work = Join-Path $env:TEMP ('kanai-ai-optin-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$optInKey = 'HKCU:\Software\KanaAI'
$optInName = 'Enhancement'
function Get-UserOptIn {
    if (-not (Test-Path -LiteralPath $optInKey)) { return $null }
    $property = (Get-ItemProperty -LiteralPath $optInKey -ErrorAction SilentlyContinue).PSObject.Properties[$optInName]
    if ($null -eq $property) { return $null }
    return [string]$property.Value
}
$savedOptIn = Get-UserOptIn

# One arm of the measurement. The broker is a server: it is started detached, its
# streams are files, and it is killed by process id. Running it in the foreground
# is how an earlier session hung for 900 s.
function Invoke-BrokerArm([string]$Label) {
    $out = Join-Path $work ($Label + '.out.log')
    $err = Join-Path $work ($Label + '.err.log')
    $pipe = 'KanaAI.OptInProbe.' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $previousPipe = $env:KANAI_AI_TSF_PIPE
    $env:KANAI_AI_TSF_PIPE = '\\.\pipe\' + $pipe
    try {
        $process = Start-Process -FilePath $broker -WorkingDirectory $InstallRoot -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $out -RedirectStandardError $err
    }
    finally {
        if ($null -eq $previousPipe) { Remove-Item Env:\KANAI_AI_TSF_PIPE -ErrorAction SilentlyContinue }
        else { $env:KANAI_AI_TSF_PIPE = $previousPipe }
    }

    $started = [Diagnostics.Stopwatch]::StartNew()
    $verified = $null
    $refused = $null
    $child = $null
    $port = $null
    try {
        while ($started.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds) {
            Start-Sleep -Milliseconds 400
            if ($process.HasExited) { break }
            $stderr = ''
            if (Test-Path -LiteralPath $err) { $stderr = [IO.File]::ReadAllText($err) }
            if ($null -eq $verified -and $stderr -match 'pinned local AI bytes verified') {
                $verified = [math]::Round($started.Elapsed.TotalSeconds, 2)
            }
            if ($null -eq $refused -and $stderr -match 'local AI not started') {
                $refused = [math]::Round($started.Elapsed.TotalSeconds, 2)
                break
            }
            if ($null -eq $child) {
                $candidate = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($process.Id)" -ErrorAction SilentlyContinue)
                if ($candidate.Count -gt 0) { $child = $candidate[0] }
            }
            if ($null -ne $child -and $null -eq $port) {
                $listening = @(Get-NetTCPConnection -State Listen -OwningProcess $child.ProcessId -ErrorAction SilentlyContinue)
                if ($listening.Count -gt 0) {
                    $port = $listening[0]
                    break
                }
            }
        }
        $childWorkingSetMb = $null
        if ($null -ne $child) {
            $live = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
            if ($null -ne $live) { $childWorkingSetMb = [math]::Round($live.WorkingSet64 / 1MB, 0) }
        }
        return [pscustomobject]@{
            Label = $Label
            Verified = $verified
            Refused = $refused
            ChildProcessId = if ($null -ne $child) { $child.ProcessId } else { $null }
            ListenAddress = if ($null -ne $port) { ('{0}:{1}' -f $port.LocalAddress, $port.LocalPort) } else { $null }
            ChildWorkingSetMb = $childWorkingSetMb
            Stderr = $(if (Test-Path -LiteralPath $err) { [IO.File]::ReadAllText($err) } else { '' })
        }
    }
    finally {
        foreach ($id in @($(if ($null -ne $child) { $child.ProcessId }), $process.Id)) {
            if ($null -ne $id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
    }
}

$problems = @()
try {
    # Arm 1: the package's own state. Nothing here writes the opt-in; whatever is
    # recorded was recorded by the installer.
    Write-Host ''
    Write-Host '=== arm 1: the installed package, with no environment override ==='
    Write-Host ("  HKCU record as installed : {0}" -f $(if ($null -eq $savedOptIn) { '<none>' } else { $savedOptIn }))
    if ($null -ne $env:KANAI_BROKER_ENHANCEMENT) {
        throw 'KANAI_BROKER_ENHANCEMENT is set in this session. This test measures what the package supplies; clear it and run again.'
    }
    $armProduct = Invoke-BrokerArm 'product'
    Write-Host ("  pinned bytes verified at : {0}" -f $(if ($null -eq $armProduct.Verified) { 'NOT OBSERVED' } else { "$($armProduct.Verified)s" }))
    Write-Host ("  runtime child process    : {0}" -f $(if ($null -eq $armProduct.ChildProcessId) { 'NONE' } else { $armProduct.ChildProcessId }))
    Write-Host ("  loopback listener        : {0}" -f $(if ($null -eq $armProduct.ListenAddress) { 'NONE' } else { $armProduct.ListenAddress }))
    Write-Host ("  child working set        : {0}" -f $(if ($null -eq $armProduct.ChildWorkingSetMb) { 'n/a' } else { "$($armProduct.ChildWorkingSetMb) MB" }))

    if ($null -eq $armProduct.Verified) { $problems += 'the installed product did not verify the pinned AI bytes, so the AI path was never entered' }
    if ($null -eq $armProduct.ChildProcessId) { $problems += 'no runtime child process was started' }
    if ($null -eq $armProduct.ListenAddress) { $problems += 'no loopback listener was bound' }
    elseif ($armProduct.ListenAddress -notlike '127.0.0.1:*') { $problems += ("the runtime listened on {0}, which is not loopback" -f $armProduct.ListenAddress) }

    # Arm 2: the shipped off switch. This is what makes arm 1 mean "the package
    # supplied the opt-in" rather than "this build always starts an AI".
    Write-Host ''
    Write-Host '=== arm 2: the same binary after the shipped off switch ==='
    & $broker --disable-local-ai | ForEach-Object { Write-Host ('  ' + $_) }
    if ($LASTEXITCODE -ne 0) { throw '--disable-local-ai did not succeed' }
    $armOff = Invoke-BrokerArm 'disabled'
    Write-Host ("  refusal reported at      : {0}" -f $(if ($null -eq $armOff.Refused) { 'NOT OBSERVED' } else { "$($armOff.Refused)s" }))
    Write-Host ("  runtime child process    : {0}" -f $(if ($null -eq $armOff.ChildProcessId) { 'NONE' } else { $armOff.ChildProcessId }))
    if ($null -eq $armOff.Refused) { $problems += 'turning the opt-in off did not stop the AI, so arm 1 does not show that the package supplied it' }
    if ($null -ne $armOff.ChildProcessId) { $problems += 'a runtime child was started even with the opt-in off' }
}
finally {
    if ($null -eq $savedOptIn) { & $broker --reset-local-ai | Out-Null }
    else { & $broker --enable-local-ai | Out-Null }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-Host ('  PROBLEM: ' + $problem) }
    Write-Host ''
    Write-Host 'Status           : FAIL'
    throw ('The installed package does not start its bundled AI on its own: ' + ($problems -join '; '))
}
Write-Host 'Status           : PASS'
exit 0
