[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    # .../platform/windows-tsf/registration/tests -> repository root
    $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') '..') '..'))
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$registrationRoot = Join-Path $RepoRoot 'platform\windows-tsf\registration'
$installerRoot = Join-Path $RepoRoot 'platform\windows-tsf\installer'
$wrapperPath = Join-Path $RepoRoot 'scripts\register-tsf-dev.ps1'

$requiredPaths = @(
    (Join-Path $registrationRoot 'registration.json'),
    (Join-Path $registrationRoot 'registry-manifest.json'),
    (Join-Path $registrationRoot 'README.md'),
    (Join-Path $registrationRoot 'REGISTRATION-NOTICE.txt'),
    (Join-Path $registrationRoot 'registry-view.md'),
    (Join-Path $registrationRoot 'templates\per-user.reg.template'),
    (Join-Path $registrationRoot 'templates\administrator-x64.reg.template'),
    (Join-Path $registrationRoot 'templates\administrator-x86.reg.template'),
    (Join-Path $registrationRoot 'templates\windows-test-receipt.example.json'),
    (Join-Path $installerRoot 'Common-TsfRegistration.ps1'),
    (Join-Path $installerRoot 'Install-TsfRegistration.ps1'),
    (Join-Path $installerRoot 'Uninstall-TsfRegistration.ps1'),
    (Join-Path $installerRoot 'README.md'),
    $wrapperPath
)
foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required TSF registration slice file is missing: $path"
    }
}
$unexpectedDlls = @(Get-ChildItem -LiteralPath $registrationRoot, $installerRoot -Recurse -Force -File -Filter '*.dll' -ErrorAction SilentlyContinue)
if ($unexpectedDlls.Count -gt 0) {
    throw "The source-only registration slice must not contain a TIP DLL: $($unexpectedDlls[0].FullName)"
}

# Parse every PowerShell file in the owned slice. This catches accidental
# syntax regressions even on a non-Windows host where registry tests cannot run.
$scriptPaths = @(
    (Join-Path $installerRoot 'Common-TsfRegistration.ps1'),
    (Join-Path $installerRoot 'Install-TsfRegistration.ps1'),
    (Join-Path $installerRoot 'Uninstall-TsfRegistration.ps1'),
    $wrapperPath
)
$scriptPaths += @(Get-ChildItem -LiteralPath (Join-Path $registrationRoot 'tests') -Recurse -Force -File -Filter '*.ps1' | ForEach-Object { $_.FullName })
$parseFailures = @()
foreach ($path in $scriptPaths) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($null -ne $errors -and $errors.Count -gt 0) {
        foreach ($parseError in $errors) {
            $parseFailures += ("{0}:{1}:{2}: {3}" -f $path, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
        }
    }
}
if ($parseFailures.Count -gt 0) {
    throw ("TSF registration PowerShell syntax check failed:`n" + ($parseFailures -join "`n"))
}

$metadata = Get-Content -LiteralPath (Join-Path $registrationRoot 'registration.json') -Raw | ConvertFrom-Json
$manifest = Get-Content -LiteralPath (Join-Path $registrationRoot 'registry-manifest.json') -Raw | ConvertFrom-Json
$receiptExample = Get-Content -LiteralPath (Join-Path $registrationRoot 'templates\windows-test-receipt.example.json') -Raw | ConvertFrom-Json
if ($receiptExample.windowsTestsPassed -ne $false -or
    $receiptExample.architecture -ne 'x64' -or
    $receiptExample.tipDll.fileName -ne 'KanaAI.TsfTip.dll') {
    throw 'The Windows test receipt example must remain explicitly unready and x64-shaped.'
}
$notice = Get-Content -LiteralPath (Join-Path $registrationRoot 'REGISTRATION-NOTICE.txt') -Raw
if ($notice -notmatch 'source-only' -or $notice -notmatch 'Registration is not complete until a real TIP DLL exists and the Windows' -or
    $notice -notmatch 'not proof') {
    throw 'REGISTRATION-NOTICE.txt does not state the source-only/readiness boundary.'
}
$readiness = $metadata.readiness
foreach ($propertyName in @('registrationComplete', 'tipDllPresent', 'windowsTestsPassed', 'runtimeVerified')) {
    if ($readiness.$propertyName -ne $false) {
        throw "Source-only readiness property '$propertyName' must remain false."
    }
}
if ($metadata.status -ne 'source-only' -or $manifest.status -ne 'source-only' -or
    $metadata.sourceOnly -ne $true -or $manifest.sourceOnly -ne $true -or
    $metadata.registrationComplete -ne $false -or $metadata.tipDllPresent -ne $false -or
    $metadata.windowsTestsPassed -ne $false -or $metadata.runtimeVerified -ne $false -or
    $metadata.tsf.status -ne 'unimplemented' -or $metadata.tsf.registered -ne $false -or
    $metadata.tsf.dllIncluded -ne $false -or
    $manifest.registrationComplete -ne $false -or $manifest.tipDllPresent -ne $false -or
    $manifest.windowsTestsPassed -ne $false -or $manifest.runtimeVerified -ne $false -or
    $manifest.tsf.status -ne 'unimplemented' -or $manifest.tsf.registered -ne $false -or
    $manifest.tsf.dllIncluded -ne $false -or
    $manifest.readiness.registrationComplete -ne $false -or
    $manifest.readiness.tipDllPresent -ne $false -or
    $manifest.readiness.windowsTestsPassed -ne $false -or
    $manifest.readiness.runtimeVerified -ne $false) {
    throw 'The registration metadata and manifest must remain source-only and unready.'
}
if ($metadata.textService.clsid -notmatch '^\{[0-9A-Fa-f-]{36}\}$' -or
    $metadata.textService.profileGuid -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
    throw 'The TSF CLSID and profile GUID must be valid brace-delimited GUIDs.'
}
if ($metadata.textService.language.languageId -ne '0x0411' -or
    $metadata.textService.language.profileKeyLanguageSegment -ne '0x00000411' -or
    $metadata.textService.language.languageIdDecimal -ne 1041) {
    throw 'The Japanese TSF language metadata is inconsistent.'
}
if ($metadata.target.architecture -ne 'x64' -or
    $metadata.target.targetTriple -ne 'x86_64-pc-windows-msvc' -or
    $metadata.target.peMachine -ne '0x8664') {
    throw 'The registration slice must target the x64 TIP explicitly.'
}
if ($metadata.artifactContract.name -ne 'KanaAI.TsfTip.dll' -or
    $metadata.artifactContract.windowsSmokePlan -ne 'platform/windows-tsf/build/smoke-test-plan.json' -or
    $metadata.artifactContract.buildGuard -ne 'KANAI_TSF_REFUSE_REGISTRATION=ON' -or
    $metadata.artifactContract.productRegistrationReady -ne $false -or
    $metadata.registrationIdentity.status -ne 'provisional-until-implementation-approval' -or
    $metadata.registrationIdentity.identityApproved -ne $false -or
    $metadata.registrationIdentity.kanaiTextServiceClsid -ne $metadata.textService.clsid -or
    $metadata.registrationIdentity.kanaiLanguageProfileGuid -ne $metadata.textService.profileGuid -or
    $metadata.registrationIdentity.pinnedMozcReference.mustNotBeRegisteredAsKanaAI -ne $true) {
    throw 'The registration identity/artifact contract is not aligned with the source-only TSF harness.'
}
if ($metadata.categories.guidSource -notmatch 'msctf\.h' -or
    @($metadata.categories.entries | Where-Object { $_.implemented -ne $false }).Count -ne 0) {
    throw 'TSF category metadata must remain compile-time/API-owned and unimplemented in this slice.'
}
if ($metadata.architectures.x64.supported -ne $true -or
    $metadata.architectures.x64.registryView -ne 'Registry64' -or
    $metadata.architectures.x64.programFiles.primaryEnvironmentVariable -ne 'ProgramW6432' -or
    $metadata.architectures.x64.programFiles.fallbackEnvironmentVariable -ne 'ProgramFiles') {
    throw 'The x64 Program Files/registry-view contract is incomplete.'
}
if ($metadata.architectures.x86.supported -ne $false -or
    $metadata.architectures.x86.registryView -ne 'Registry32' -or
    $metadata.architectures.x86.programFiles.primaryEnvironmentVariable -ne 'ProgramFiles(x86)') {
    throw 'The future x86 path must be represented but explicitly blocked.'
}
if ($manifest.classId -ne $metadata.textService.clsid -or
    $manifest.profileId -ne $metadata.textService.profileGuid -or
    $manifest.artifactName -ne 'KanaAI.TsfTip.dll' -or
    $manifest.buildGuard -ne 'KANAI_TSF_REFUSE_REGISTRATION=ON' -or
    $manifest.identityStatus -ne 'provisional-until-implementation-approval' -or
    $manifest.identityApproved -ne $false -or
    $manifest.pinnedMozcReference.mustNotBeRegisteredAsKanaAI -ne $true -or
    $manifest.supportedArchitectures.Count -ne 1 -or
    $manifest.supportedArchitectures[0] -ne 'x64' -or
    $manifest.plannedArchitectures.Count -ne 1 -or
    $manifest.plannedArchitectures[0] -ne 'x86' -or
    $manifest.registryViews.x64 -ne 'Registry64' -or
    $manifest.registryViews.x86 -ne 'Registry32' -or
    $manifest.registryViewGuidance.x64 -notmatch 'Registry64' -or
    $manifest.registryViewGuidance.x86 -notmatch 'Registry32') {
    throw 'The registry manifest and registration metadata disagree.'
}

$templatePaths = @(
    (Join-Path $registrationRoot 'templates\per-user.reg.template'),
    (Join-Path $registrationRoot 'templates\administrator-x64.reg.template'),
    (Join-Path $registrationRoot 'templates\administrator-x86.reg.template')
)
foreach ($templatePath in $templatePaths) {
    $template = Get-Content -LiteralPath $templatePath -Raw
    if ($template -notmatch 'LanguageProfile' -or $template -notmatch 'InProcServer32' -or
        $template -notmatch 'TIP_DLL_PATH') {
        throw "TSF registry template is missing text-service/profile metadata: $templatePath"
    }
    if ($template -notmatch '@@[^@]+@@') {
        throw "TSF registry template must retain an unresolved rendering sentinel: $templatePath"
    }
    if ($template -notmatch [regex]::Escape($metadata.textService.clsid) -or
        $template -notmatch [regex]::Escape($metadata.textService.profileGuid)) {
        throw "TSF registry template does not carry the reviewed KanaAI identity: $templatePath"
    }
}
$perUserTemplate = Get-Content -LiteralPath (Join-Path $registrationRoot 'templates\per-user.reg.template') -Raw
$adminTemplate = Get-Content -LiteralPath (Join-Path $registrationRoot 'templates\administrator-x64.reg.template') -Raw
$perUserHeaders = @([regex]::Matches($perUserTemplate, '(?m)^\[(HKEY_[^\]]+)\]') | ForEach-Object { $_.Groups[1].Value })
$adminHeaders = @([regex]::Matches($adminTemplate, '(?m)^\[(HKEY_[^\]]+)\]') | ForEach-Object { $_.Groups[1].Value })
if (@($perUserHeaders | Where-Object { $_ -like 'HKEY_LOCAL_MACHINE*' }).Count -ne 0 -or
    @($adminHeaders | Where-Object { $_ -like 'HKEY_CURRENT_USER*' }).Count -ne 0) {
    throw 'Per-user and administrator templates crossed their intended registry hives.'
}
if ($perUserTemplate -notmatch 'HKEY_CURRENT_USER' -or $perUserTemplate -notmatch '"Enable"') {
    throw 'The per-user template must contain HKCU activation metadata.'
}
if ($adminTemplate -notmatch 'HKEY_LOCAL_MACHINE' -or $adminTemplate -notmatch 'ProgramW6432' -or
    $adminTemplate -notmatch 'Registry64') {
    throw 'The administrator template must make the x64 Program Files/registry view explicit.'
}

$commonText = Get-Content -LiteralPath (Join-Path $installerRoot 'Common-TsfRegistration.ps1') -Raw
if ($commonText -notmatch 'ToUInt16\(\$coff, 22\)') {
    throw 'PE Characteristics must be read from COFF offset 22; otherwise real DLLs are misclassified as executables.'
}
$registryViewText = Get-Content -LiteralPath (Join-Path $registrationRoot 'registry-view.md') -Raw
if ($registryViewText -notmatch 'ProgramW6432' -or $registryViewText -notmatch 'ProgramFiles\(x86\)' -or
    $registryViewText -notmatch 'Registry64' -or $registryViewText -notmatch 'Registry32' -or
    $registryViewText -notmatch 'Wow6432Node' -or $registryViewText -notmatch '/reg:64' -or
    $registryViewText -notmatch '/reg:32') {
    throw 'registry-view.md does not cover both Program Files roots and registry views.'
}
$installText = Get-Content -LiteralPath (Join-Path $installerRoot 'Install-TsfRegistration.ps1') -Raw
$uninstallText = Get-Content -LiteralPath (Join-Path $installerRoot 'Uninstall-TsfRegistration.ps1') -Raw
$wrapperText = Get-Content -LiteralPath $wrapperPath -Raw
foreach ($check in @(
    @{ Name = 'metadata source-only gate'; Text = $commonText; Needle = 'registrationComplete' },
    @{ Name = 'x64 ProgramW6432'; Text = $commonText; Needle = 'ProgramW6432' },
    @{ Name = 'x86 ProgramFiles(x86)'; Text = $commonText; Needle = 'ProgramFiles(x86)' },
    @{ Name = 'Registry64'; Text = $commonText; Needle = 'Registry64' },
    @{ Name = 'Registry32'; Text = $commonText; Needle = 'Registry32' },
    @{ Name = 'real DLL gate'; Text = $commonText; Needle = 'a real, architecture-correct TIP DLL is required' },
    @{ Name = 'Windows test gate'; Text = $commonText; Needle = 'Windows registration/application test receipt passes' },
    @{ Name = 'install dry-run'; Text = $installText; Needle = '-DryRun' },
    @{ Name = 'install apply'; Text = $installText; Needle = '-Apply' },
    @{ Name = 'uninstall dry-run'; Text = $uninstallText; Needle = '-DryRun' },
    @{ Name = 'uninstall apply'; Text = $uninstallText; Needle = '-Apply' },
    @{ Name = 'development wrapper default'; Text = $wrapperText; Needle = 'source-only by default' }
)) {
    if ($check.Text.IndexOf($check.Needle, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Static TSF registration check failed ($($check.Name)); missing: $($check.Needle)"
    }
}

# Exercise the pure planning helpers without touching the registry. This is
# intentionally a dry-run test on every host, including Linux CI.
. (Join-Path $installerRoot 'Common-TsfRegistration.ps1')
$planMetadata = Get-TsfRegistrationMetadata -Path (Join-Path $registrationRoot 'registration.json')
$x64Spec = Get-TsfArchitectureSpec -Metadata $planMetadata -Architecture 'x64'
$x86Spec = Get-TsfArchitectureSpec -Metadata $planMetadata -Architecture 'x86'
$x64Location = Get-TsfInstallLocation -Metadata $planMetadata -ArchitectureSpec $x64Spec
$x64Plan = New-TsfInstallPlan -Metadata $planMetadata -ArchitectureSpec $x64Spec -Scope 'PerUser' -Location $x64Location
$exampleReceiptCheck = Get-TsfWindowsTestReceipt -Path (Join-Path $registrationRoot 'templates\windows-test-receipt.example.json') -Architecture 'x64'
if ($exampleReceiptCheck.WindowsTestsPassed -ne $false) {
    throw 'The example Windows test receipt must never authorize registration.'
}
$x86Plan = New-TsfInstallPlan -Metadata $planMetadata -ArchitectureSpec $x86Spec -Scope 'Machine' -Location (Get-TsfInstallLocation -Metadata $planMetadata -ArchitectureSpec $x86Spec)
$uninstallPlan = New-TsfUninstallPlan -Metadata $planMetadata -ArchitectureSpec $x64Spec -Scope 'Machine' -Location $x64Location -RemoveUserActivation
if ($x64Plan.RegistrationComplete -ne $false -or $x64Plan.Registered -ne $false -or
    $x64Plan.Readiness.IdentityApproved -ne $false -or
    $x64Plan.Readiness.TipDllExists -ne $false -or $x64Plan.CanApply -ne $false) {
    throw 'The source-only x64 plan must not claim an applicable or complete registration.'
}
if (@($x64Plan.ApiOperations | Where-Object { $_.Name -match 'Unregister|Remove' }).Count -ne 0 -or
    @($uninstallPlan.ApiOperations | Where-Object { $_.Name -match 'Unregister|Remove' }).Count -eq 0) {
    throw 'Install and uninstall TSF API plans are not separated correctly.'
}
if ($x64Plan.RegistryView -ne 'Registry64' -or $x64Location.ProgramFilesRoot -notmatch 'ProgramW6432|program|windows') {
    throw 'The x64 plan did not retain ProgramW6432/Registry64 path semantics.'
}
$explicitX64Location = Get-TsfInstallLocation -Metadata $planMetadata -ArchitectureSpec $x64Spec -ProgramFilesRoot '/tmp/Program Files'
$explicitX86Location = Get-TsfInstallLocation -Metadata $planMetadata -ArchitectureSpec $x86Spec -ProgramFilesRoot '/tmp/Program Files (x86)'
$explicitX64Path = ([string]$explicitX64Location.TipDllPath).Replace('\', '/')
$explicitX86Path = ([string]$explicitX86Location.TipDllPath).Replace('\', '/')
if ($explicitX64Path -notmatch '/Program Files/KanaAI/TSF/KanaAI\.TsfTip\.dll$' -or
    $explicitX86Path -notmatch '/Program Files \(x86\)/KanaAI/TSF/KanaAI\.TsfTip\.dll$') {
    throw 'Program Files and Program Files (x86) path resolution is not separated correctly.'
}
$badX64RootRejected = $false
try {
    Get-TsfInstallLocation -Metadata $planMetadata -ArchitectureSpec $x64Spec -ProgramFilesRoot '/tmp/Program Files (x86)' | Out-Null
}
catch {
    if ($_.Exception.Message -notmatch 'x64 TIP cannot be directed into Program Files \(x86\)') {
        throw
    }
    $badX64RootRejected = $true
}
if (-not $badX64RootRejected) {
    throw 'An explicit Program Files (x86) root must be rejected for the x64 TIP.'
}
$oldProgramW6432 = [System.Environment]::GetEnvironmentVariable('ProgramW6432')
$oldProgramFiles = [System.Environment]::GetEnvironmentVariable('ProgramFiles')
$oldProgramFilesX86 = [System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
try {
    [System.Environment]::SetEnvironmentVariable('ProgramW6432', $null)
    [System.Environment]::SetEnvironmentVariable('ProgramFiles', 'C:\Program Files')
    [System.Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\Program Files (x86)')
    $resolvedX64Root = Get-TsfProgramFilesRoot -ArchitectureSpec $x64Spec
    $resolvedX86Root = Get-TsfProgramFilesRoot -ArchitectureSpec $x86Spec
    $expectedX64Root = if ([System.Environment]::Is64BitProcess) { 'C:\Program Files' } else { '<ProgramW6432>' }
    if ($resolvedX64Root -ne $expectedX64Root -or $resolvedX86Root -ne 'C:\Program Files (x86)') {
        throw 'ProgramW6432/ProgramFiles fallback or ProgramFiles(x86) resolution is incorrect.'
    }
}
finally {
    [System.Environment]::SetEnvironmentVariable('ProgramW6432', $oldProgramW6432)
    [System.Environment]::SetEnvironmentVariable('ProgramFiles', $oldProgramFiles)
    [System.Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $oldProgramFilesX86)
}
if ($x86Plan.CanApply -ne $false -or $x86Plan.BlockingReasons.Count -eq 0 -or
    $x86Plan.RegistryView -ne 'Registry32' -or
    $x86Plan.ProgramFilesRoot -notmatch 'ProgramFiles\(x86\)' -or
    $x86Plan.Template -ne 'templates/administrator-x86.reg.template') {
    throw 'The x86 plan must remain blocked and use the future Registry32 contract.'
}
if ($uninstallPlan.RegistryOperations.Count -lt 3 -or
    @($uninstallPlan.RegistryOperations | Where-Object { $_.Action -ne 'delete' }).Count -ne 0) {
    throw 'The uninstall plan must contain only explicit KanaAI registry deletions.'
}
foreach ($operation in @($uninstallPlan.RegistryOperations)) {
    Assert-TsfRegistryKey -Key $operation.Key -Clsid $planMetadata.textService.clsid -ProfileGuid $planMetadata.textService.profileGuid
}

[pscustomobject]@{
    Metadata = 'valid'
    Manifest = 'valid'
    ParsedPowerShellFiles = $scriptPaths.Count
    RequiredFiles = $requiredPaths.Count
    StaticChecks = 12
    X64RegistryView = $x64Plan.RegistryView
    X86Blocked = ($x86Plan.CanApply -eq $false)
    RegistrationComplete = $false
    TipDllPresent = $false
    WindowsTestsPassed = $false
}
