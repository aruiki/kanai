# Does the local AI change what the product converts?
#
# The question this answers
# -------------------------
# v0.1.0-beta.2 established that the bundled AI *starts* on the product path: a
# 1.1 GB model loaded into a child process, byte-hash verification, a completed
# inference. It did not establish that any of that reaches a candidate. Those
# are different claims, and a release that carries a model has to be able to say
# which one it is making.
#
# So this types the same romaji twice - once with the AI enabled, once with it
# disabled through the shipped switch - and compares the committed text. It
# asserts nothing about correctness. A conversion being wrong is a quality
# result and needs a corpus; a conversion being *identical with the AI on and
# off* is a wiring result and needs only this.
#
# The gate that has to come first
# -------------------------------
# An earlier run of a sibling test measured Microsoft IME and reported it as a
# product result. The keys went to whichever input method was active, which was
# not this product, and the committed kana that came back looked like success.
# The W1 harness had reported TIP-DLL-NOT-LOADED as a critical finding at the
# same time and was right.
#
# So before anything is typed, this checks that the probe host has actually
# loaded mozc_tip. If it has not, the run stops with HARNESS-BLOCKED and makes
# no claim about the product at all. A measurement that cannot name which input
# method produced it is not evidence.
#
# To make that gate passable, the user's language list is reordered so this
# product is the default input method for newly created processes, and it is
# restored in a finally block - including when the run throws.
#
# ASCII only on purpose: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.
# The measured text is Japanese and is written to a UTF-8 JSON receipt instead
# of being compared against a literal in this file.
param(
    [string]$Edit = 'rich',
    [int]$SettleMs = 1200,
    [string]$ReceiptPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = $PSScriptRoot
$desktop = Split-Path -Parent $here
$sourceDll = Join-Path $desktop 'bin\DesktopValidation.Native.dll'
$probeExe = Join-Path $desktop 'bin\KanaAIValidationProbeHost.exe'
foreach ($p in @($sourceDll, $probeExe)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "missing prerequisite: $p" }
}
$broker = Join-Path $env:ProgramFiles 'KanaAI\kanai-broker.exe'
if (-not (Test-Path -LiteralPath $broker -PathType Leaf)) { throw "the installed broker is required: $broker" }

# The native layer is loaded from an ASCII copy: this repository lives under a
# path containing Japanese characters, which Add-Type mangles on PS 5.1.
$asciiRoot = Join-Path $env:TEMP 'kanai-ai-candidate-diff'
if (-not (Test-Path -LiteralPath $asciiRoot)) { [void](New-Item -ItemType Directory -Path $asciiRoot -Force) }
$dll = Join-Path $asciiRoot 'DesktopValidation.Native.dll'
Copy-Item -LiteralPath $sourceDll -Destination $dll -Force
$sourceSha = (Get-FileHash -LiteralPath $sourceDll -Algorithm SHA256).Hash
if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne $sourceSha) { throw 'staged native copy does not match the tree' }
Add-Type -Path $dll

# The cases are the ones the operator found by hand. Each is romaji only, so it
# can be typed as virtual keys; the expected reading is a comment, never an
# assertion, because this test compares two runs rather than grading one.
$cases = @(
    @{ Id = 'bun-jitai'; Romaji = 'konobunnzitai' },                     # kono bun jitai
    @{ Id = 'ha-itai'; Romaji = 'hagaitainodekyouhaisyaniikou' },        # ha ga itai -> haisya
    @{ Id = 'onaka-itai'; Romaji = 'onakagaitainodekyouhaisyaniikou' },  # onaka ga itai -> isya
    @{ Id = 'kisya'; Romaji = 'kisyanokisyagakisyadekisyasita' },        # kisya x4
    @{ Id = 'niwa'; Romaji = 'uraniwanihaniwaniwatorigairu' }            # niwa / niwatori
)

function ConvertTo-KeyTokens([string]$Text) {
    $tokens = @()
    foreach ($character in $Text.ToCharArray()) {
        if ($character -match '[a-zA-Z]') { $tokens += ('VK_' + [string]$character).ToUpperInvariant() }
        elseif ($character -match '[0-9]') { $tokens += ('VK_' + [string]$character) }
        else { throw ("the case text must be plain romaji; '{0}' cannot be typed as a virtual key" -f $character) }
    }
    return $tokens
}

function Read-ProbeState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}
function Get-Field($State, [string]$Name, $Default = '') {
    if ($null -eq $State) { return $Default }
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

# --- the language list, saved and restored -------------------------------
$productTip = '{7E7B5C1E-6D3A-4F2C-9A0E-3F4B5D6C7E81}{F3C2B7A1-6D54-4E8B-9A10-2C7D8E9F0A12}'
$savedList = Get-WinUserLanguageList
$listChanged = $false

function Set-ProductAsDefaultInputMethod {
    $list = Get-WinUserLanguageList
    foreach ($language in $list) {
        $ours = @($language.InputMethodTips | Where-Object { $_ -like ("*" + $productTip) })
        if ($ours.Count -eq 0) { continue }
        $rest = @($language.InputMethodTips | Where-Object { $_ -notlike ("*" + $productTip) })
        $language.InputMethodTips.Clear()
        foreach ($tip in ($ours + $rest)) { [void]$language.InputMethodTips.Add($tip) }
        Set-WinUserLanguageList -LanguageList $list -Force
        return $true
    }
    return $false
}

# --- one measured arm ------------------------------------------------------
function Invoke-ConversionArm([string]$Label) {
    $runId = 'ai-diff-' + $Label + '-' + [Guid]::NewGuid().ToString('n').Substring(0, 6)
    $statePath = Join-Path $asciiRoot ($runId + '.json')
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    $process = $null
    try {
        $process = Start-Process -FilePath $probeExe -ArgumentList @('--state', $statePath, '--runid', $runId, '--edit', $Edit) -PassThru
        $deadline = (Get-Date).AddSeconds(20)
        $ready = $null
        while ((Get-Date) -lt $deadline) {
            $ready = Read-ProbeState $statePath
            if ($null -ne $ready -and [string](Get-Field $ready 'phase') -eq 'ready') { break }
            Start-Sleep -Milliseconds 200
        }
        if ($null -eq $ready -or [string](Get-Field $ready 'phase') -ne 'ready') { throw 'probe host did not become ready within 20s' }
        $hwnd = [int64](Get-Field $ready 'hwnd' 0)
        $editClass = [string](Get-Field $ready 'editClass')
        if ($editClass -notmatch 'RICHEDIT') { throw "the probe host granted '$editClass', which hosts no TSF text service" }

        [void][KanaAI.DesktopValidation.Native]::ForceForeground($hwnd, 300)
        Start-Sleep -Milliseconds $SettleMs

        # THE GATE. Without this, the keys below go to whichever input method is
        # active and the result is unattributable.
        $modules = @([KanaAI.DesktopValidation.Native]::GetLoadedModules([uint32]$process.Id))
        $tipModules = @($modules | Where-Object { $_.Name -like 'mozc_tip*' })
        if ($tipModules.Count -eq 0) {
            return [pscustomobject]@{
                Label = $Label; Blocked = $true
                Reason = ("the probe host loaded no mozc_tip module ({0} modules read), so the active input method is not this product" -f $modules.Count)
                Results = @()
            }
        }

        # Drive the input method to a known-open state; the toggle is a toggle.
        $opened = $false
        for ($i = 0; $i -lt 3; $i++) {
            $counter = [int64]0
            [void][KanaAI.DesktopValidation.Native]::RequestStateRefresh($hwnd, 2000, [ref]$counter)
            $state = Read-ProbeState $statePath
            if ([string](Get-Field $state.ime 'open') -eq 'True') { $opened = $true; break }
            [void][KanaAI.DesktopValidation.Native]::SendKeyChord(@('VK_MENU', 'VK_OEM_3'), 60, $false)
            Start-Sleep -Milliseconds 500
        }
        if (-not $opened) {
            return [pscustomobject]@{
                Label = $Label; Blocked = $true
                Reason = 'the input method could not be driven to an open state'
                Results = @()
            }
        }

        $results = @()
        foreach ($case in $cases) {
            [void][KanaAI.DesktopValidation.Native]::SendKeySequence((ConvertTo-KeyTokens $case.Romaji), 45, $false)
            Start-Sleep -Milliseconds 600
            [void][KanaAI.DesktopValidation.Native]::SendKeySequence(@('VK_SPACE'), 60, $false)
            Start-Sleep -Milliseconds 900
            [void][KanaAI.DesktopValidation.Native]::SendKeySequence(@('VK_RETURN'), 60, $false)
            Start-Sleep -Milliseconds 500
            $counter = [int64]0
            [void][KanaAI.DesktopValidation.Native]::RequestStateRefresh($hwnd, 2000, [ref]$counter)
            $state = Read-ProbeState $statePath
            $all = [string](Get-Field $state 'textAtPhase')
            $results += [pscustomobject]@{ Id = $case.Id; Romaji = $case.Romaji; CumulativeText = $all }
            # Clear the control so the next case reads on its own.
            [void][KanaAI.DesktopValidation.Native]::SendKeyChord(@('VK_CONTROL', 'VK_A'), 60, $false)
            Start-Sleep -Milliseconds 150
            [void][KanaAI.DesktopValidation.Native]::SendKeySequence(@('VK_BACK'), 60, $false)
            Start-Sleep -Milliseconds 250
        }
        return [pscustomobject]@{ Label = $Label; Blocked = $false; Reason = ''; Results = $results }
    }
    finally {
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) } } catch { }
        }
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    }
}

function Set-AiEnabled([bool]$Enabled) {
    $argument = if ($Enabled) { '--enable-local-ai' } else { '--disable-local-ai' }
    & $broker $argument | Out-Null
    # The text service starts the broker, so the setting applies to the *next*
    # broker. Stopping the current server and broker is what makes the next
    # probe host get one that read the new setting.
    foreach ($name in @('kanai-broker', 'llama-server', 'mozc_server')) {
        Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

$savedSetting = & $broker --ai-status
$receipt = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o')
    nativeLayerSha256 = $sourceSha
    brokerSha256 = (Get-FileHash -LiteralPath $broker -Algorithm SHA256).Hash
    settingBefore = [string]$savedSetting
    arms = @()
    verdict = ''
}

try {
    Write-Host ''
    Write-Host '=== making this product the default input method for new processes ==='
    $listChanged = Set-ProductAsDefaultInputMethod
    Write-Host ("  language list reordered: {0}" -f $listChanged)
    if (-not $listChanged) { throw 'this product is not registered as an input method for any installed language' }
    Start-Sleep -Seconds 2

    Write-Host ''
    Write-Host '=== arm 1: AI enabled ==='
    Set-AiEnabled $true
    $withAi = Invoke-ConversionArm 'ai-on'
    if ($withAi.Blocked) { Write-Host ('  BLOCKED: ' + $withAi.Reason) }
    else { foreach ($r in $withAi.Results) { Write-Host ("  {0,-12} {1}" -f $r.Id, $r.CumulativeText) } }

    Write-Host ''
    Write-Host '=== arm 2: AI disabled through the shipped switch ==='
    Set-AiEnabled $false
    $withoutAi = Invoke-ConversionArm 'ai-off'
    if ($withoutAi.Blocked) { Write-Host ('  BLOCKED: ' + $withoutAi.Reason) }
    else { foreach ($r in $withoutAi.Results) { Write-Host ("  {0,-12} {1}" -f $r.Id, $r.CumulativeText) } }

    $receipt.arms = @($withAi, $withoutAi)

    Write-Host ''
    if ($withAi.Blocked -or $withoutAi.Blocked) {
        $receipt.verdict = 'harness-blocked'
        Write-Host 'Status           : HARNESS-BLOCKED (no claim is made about the product)'
    }
    else {
        $differences = @()
        for ($i = 0; $i -lt $cases.Count; $i++) {
            $a = [string]$withAi.Results[$i].CumulativeText
            $b = [string]$withoutAi.Results[$i].CumulativeText
            if ($a -cne $b) { $differences += $cases[$i].Id }
        }
        $receipt.verdict = if ($differences.Count -gt 0) { 'ai-changes-output' } else { 'ai-does-not-change-output' }
        Write-Host '=== comparison ==='
        Write-Host ("  cases: {0}, differing: {1}" -f $cases.Count, $differences.Count)
        foreach ($d in $differences) { Write-Host ('   differs: ' + $d) }
        if ($differences.Count -eq 0) {
            Write-Host ''
            Write-Host 'Result           : the AI does not change what this product commits.'
            Write-Host '                   It starts, loads its model and answers, and the'
            Write-Host '                   committed text is identical with it switched off.'
        }
        else {
            Write-Host ''
            Write-Host 'Result           : the AI changes what this product commits.'
        }
    }
}
finally {
    if ($listChanged) {
        Set-WinUserLanguageList -LanguageList $savedList -Force
        Write-Host '  language list restored'
    }
    if ([string]$savedSetting -match 'local AI is on') { & $broker --enable-local-ai | Out-Null }
    else { & $broker --disable-local-ai | Out-Null }
    if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
        $ReceiptPath = Join-Path $desktop ('runs\ai-candidate-difference-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '.json')
    }
    $directory = Split-Path -Parent $ReceiptPath
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    ($receipt | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $ReceiptPath -Encoding utf8
    Write-Host ("  receipt: {0}" -f $ReceiptPath)
}
exit 0
