[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
    [Parameter(Mandatory = $true)][string]$InstallerHelper,
    [string]$Version = '0.1.0',
    [string]$OutputDirectory = '',
    [string]$WixPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repository 'platform\windows-tsf\installer\package'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be an MSI major.minor.build version.' }
$runtime = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$helper = (Resolve-Path -LiteralPath $InstallerHelper).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repository '.local\installer' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($output -eq $runtime -or $output.StartsWith($runtime + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installer output must be outside the runtime payload.'
}
if (-not $WixPath) { $WixPath = Join-Path $repository '.local\wix\wix.exe' }
$wix = (Resolve-Path -LiteralPath $WixPath).Path
$wixVersion = (& $wix --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $wixVersion -notlike '5.0.2*') { throw 'WiX 5.0.2 is required.' }

function Assert-PeMachine([string]$Path, [int]$Machine) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0x5a4d) { throw "Invalid PE: $Path" }
    $offset = [BitConverter]::ToInt32($bytes, 60)
    if ($offset -lt 64 -or $offset -gt $bytes.Length - 24 -or
        [BitConverter]::ToUInt32($bytes, $offset) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes, $offset + 4) -ne $Machine) { throw "PE architecture mismatch: $Path" }
}

$required = @{
    'mozc_tip64.dll' = 0x8664; 'mozc_tip32.dll' = 0x014c;
    'mozc_server.exe' = 0x8664; 'mozc_renderer.exe' = 0x8664;
    'mozc_broker.exe' = 0x8664; 'msvcp140.dll' = 0x8664;
    'vcruntime140.dll' = 0x8664; 'vcruntime140_1.dll' = 0x8664
}
foreach ($entry in $required.GetEnumerator()) {
    Assert-PeMachine -Path (Join-Path $runtime $entry.Key) -Machine $entry.Value
}
Assert-PeMachine -Path $helper -Machine 0x8664
foreach ($name in @('LICENSE.txt', 'MOZC-LICENSE.txt', 'credits_en.html', 'README.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $runtime $name) -PathType Leaf)) { throw "Missing package notice: $name" }
}
New-Item -ItemType Directory -Path $output -Force | Out-Null
$files = @(Get-ChildItem -LiteralPath $runtime -File | Sort-Object Name)
if (@(Get-ChildItem -LiteralPath $runtime -Directory).Count) { throw 'Only a flat, reviewed runtime payload is accepted.' }
$xml = [Text.StringBuilder]::new()
[void]$xml.AppendLine('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs"><Fragment><ComponentGroup Id="RuntimeFiles" Directory="INSTALLFOLDER">')
foreach ($file in $files) {
    $id = 'F_' + ($file.Name -replace '[^A-Za-z0-9_.]', '_')
    $name = [Security.SecurityElement]::Escape($file.Name)
    $path = [Security.SecurityElement]::Escape($file.FullName)
    $bitness = if ($file.Name -eq 'mozc_tip32.dll') { 'always32' } else { 'always64' }
    [void]$xml.AppendLine("<Component Id=`"$id`" Guid=`"*`" Bitness=`"$bitness`"><File Id=`"$id`" Name=`"$name`" Source=`"$path`" KeyPath=`"yes`" /></Component>")
}
[void]$xml.AppendLine('</ComponentGroup></Fragment></Wix>')
$fragment = Join-Path $output 'RuntimeFiles.wxs'
[IO.File]::WriteAllText($fragment, $xml.ToString(), [Text.UTF8Encoding]::new($false))
$msi = Join-Path $output "KanaAI-$Version-x64.msi"
& $wix build (Join-Path $source 'KanaAI.wxs') $fragment -arch x64 -d "Version=$Version" -d "HelperPath=$helper" -o $msi
if ($LASTEXITCODE -ne 0) { throw "WiX build failed: $LASTEXITCODE" }
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$setup = Join-Path $output "KanaAI-$Version-Setup.exe"
& $csc /nologo /target:winexe /platform:x64 /optimize+ /reference:System.Windows.Forms.dll "/out:$setup" "/resource:$msi,KanaAI.msi" "/win32manifest:$(Join-Path $source 'Setup.manifest')" (Join-Path $source 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "Setup launcher compilation failed: $LASTEXITCODE" }
$manifest = [ordered]@{
    schemaVersion = 1; version = $Version; status = 'unverified-installer-candidate';
    installedInputVerified = $false; localAiIncluded = $false; signing = 'unsigned';
    wixVersion = $wixVersion;
    files = @($files | ForEach-Object { @{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash; bytes = $_.Length } });
    installerHelperSha256 = (Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash;
    msiSha256 = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash;
    setupSha256 = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'build-manifest.json') -Encoding UTF8
[pscustomobject]@{ Setup = $setup; Msi = $msi; Verified = $false; Published = $false }
