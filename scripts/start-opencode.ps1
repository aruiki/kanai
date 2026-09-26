param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'

# The Windows PowerShell/npm wrapper can emit UTF-16LE when stdout is redirected.
# Decode the byte stream explicitly instead of asking StreamReader to guess UTF-8.
function Convert-ProcessBytesToText([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0x00 -and $Bytes[1] -ne 0x00) {
        return [Text.Encoding]::Unicode.GetString($Bytes)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[1] -eq 0x00 -and $Bytes[0] -ne 0x00) {
        return [Text.Encoding]::BigEndianUnicode.GetString($Bytes)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xff -and $Bytes[1] -eq 0xfe) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xfe -and $Bytes[1] -eq 0xff) {
        return [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) {
        return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }
    return [Text.Encoding]::UTF8.GetString($Bytes)
}

$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot
try {
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) { throw 'OpenCode is not installed.' }
    $version = (& opencode --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $version -notmatch 'v?2\.') { throw "Expected OpenCode v2, found: $version" }
    $models = @(& opencode models)
    $models = @($models | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0 -or $models -notcontains 'opencode/space-bunny-free') {
        throw 'Space Bunny Free is unavailable. No automatic paid-model fallback.'
    }
    $config = Get-Content opencode.jsonc -Raw | ConvertFrom-Json
    if ($config.default_agent -ne 'coordinator' -or $config.model -ne 'opencode/space-bunny-free') {
        throw 'Unexpected project default agent or model.'
    }
    if ($CheckOnly) {
    # Force a non-terminal stdout: debug JSON may be formatted when launched in a TTY.
    $probe = New-Object System.Diagnostics.Process
    $probe.StartInfo.FileName = (Get-Process -Id $PID).Path
    $probe.StartInfo.Arguments = '-NoLogo -NoProfile -Command "opencode debug agents"'
    $probe.StartInfo.WorkingDirectory = $repoRoot
    $probe.StartInfo.UseShellExecute = $false
    $probe.StartInfo.CreateNoWindow = $true
    $probe.StartInfo.RedirectStandardOutput = $true
    $probe.StartInfo.RedirectStandardError = $true
    try {
        [void]$probe.Start()
        $stdoutMemory = New-Object System.IO.MemoryStream
        $stderrMemory = New-Object System.IO.MemoryStream
        try {
            $stdoutTask = $probe.StandardOutput.BaseStream.CopyToAsync($stdoutMemory)
            $stderrTask = $probe.StandardError.BaseStream.CopyToAsync($stderrMemory)
            $probe.WaitForExit()
            [void]$stdoutTask.GetAwaiter().GetResult()
            [void]$stderrTask.GetAwaiter().GetResult()
            if ($stdoutMemory.Length -gt 8MB -or $stderrMemory.Length -gt 8MB) {
                throw 'OpenCode debug agents output exceeded the 8 MiB sanity limit.'
            }
            $stdoutBytes = $stdoutMemory.ToArray()
            $stderrBytes = $stderrMemory.ToArray()
            $agentText = Convert-ProcessBytesToText -Bytes $stdoutBytes
            $stderrText = Convert-ProcessBytesToText -Bytes $stderrBytes
            if ($probe.ExitCode -ne 0) { throw ('OpenCode failed to load agents: ' + $stderrText) }
        } finally {
            $stdoutMemory.Dispose()
            $stderrMemory.Dispose()
        }
    } finally { $probe.Dispose() }
    $agents = $agentText | ConvertFrom-Json
    foreach ($id in @('coordinator','implementer','researcher','reviewer','tester','verifier')) {
        $agent = @($agents | Where-Object { $_.id -eq $id })
        if ($agent.Count -ne 1) { throw "Missing or duplicate agent: $id" }
        if ($agent[0].model.id -ne 'space-bunny-free' -or $agent[0].model.providerID -ne 'opencode') {
            throw "Unexpected model for $id"
        }
    }
    Write-Host "$version / Space Bunny Free / 6 project agents: OK"
    }
    if (-not $CheckOnly) {
        # Start a fresh session: existing sessions retain their agent/model selection.
        $prompt = 'Read OPENCODE_START.md and follow its instructions. Use coordinator and opencode/space-bunny-free. Continue development from the current handoff.'
        & opencode --standalone --prompt $prompt
        if ($LASTEXITCODE -ne 0) { throw "OpenCode exited with code $LASTEXITCODE" }
    }
} finally {
    Pop-Location
}
