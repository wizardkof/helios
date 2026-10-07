param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts.psm1') -Force
$pins = Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
$selected = $env:HELIOS_GIT
$receipt = [ordered]@{schemaVersion=1;status='FAIL';selectedGit=$selected;version=$null;resolution=@();consumers=@();missingSelection=$null;rejectedVersions=@();error=$null}
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
function Assert-GitResolution([string]$Phase) {
    $candidates = @(Get-Command git -CommandType Application -All -ErrorAction Stop)
    if ($candidates.Count -lt 1) { throw 'No Git application resolved' }
    $command = $candidates | Select-Object -First 1
    $resolved = [IO.Path]::GetFullPath([string]$command.Source)
    $output = @(& $selected --version 2>&1 | ForEach-Object {$_.ToString()}) -join "`n"
    $exit = $LASTEXITCODE
    $row = [ordered]@{phase=$Phase;resolvedPath=$resolved;selectedPath=$selected;resolutionCandidates=@($candidates | ForEach-Object { [string]$_.Source });version=$output;exitCode=$exit}
    $receipt.resolution += $row
    if (-not [string]::Equals($resolved, [IO.Path]::GetFullPath($selected), [StringComparison]::OrdinalIgnoreCase) -or $exit -ne 0 -or $output.Trim() -cne $pins.gitUpstream.executableVersion) { throw "Pinned Git resolution/version failed at $Phase." }
}
try {
    if (-not $selected -or -not (Test-Path -LiteralPath $selected -PathType Leaf)) { throw 'HELIOS_GIT is required by the native acquisition control.' }
    $receipt.version = $pins.gitUpstream.executableVersion
    Assert-GitResolution 'after-acquisition'
    Import-VisualStudioEnvironment -Architecture x64
    Assert-GitResolution 'after-first-vs-import'
    Import-VisualStudioEnvironment -Architecture x64
    Assert-GitResolution 'after-second-vs-import'
    $commands = @(
        @('-C',$RepoRoot,'rev-parse','HEAD'), @('-C',$RepoRoot,'status','--porcelain'), @('-C',$RepoRoot,'submodule','status')
    )
    foreach ($name in @('dxvk-helios','vkd3d-proton-helios','icd/mesa')) { $commands += ,@('-C',(Join-Path $RepoRoot $name),'rev-parse','HEAD') }
    foreach ($arguments in $commands) {
        $output = @(& $selected @arguments 2>&1 | ForEach-Object {$_.ToString()}) -join "`n"
        $exit = $LASTEXITCODE
        $receipt.consumers += [ordered]@{arguments=$arguments;output=$output;exitCode=$exit;status=if($exit -eq 0){'PASS'}else{'FAIL'}}
        if ($exit -ne 0) { throw "Pinned Git real consumer failed: $($arguments -join ' ')" }
    }
    foreach ($name in @('dxvk-helios','vkd3d-proton-helios')) {
        $path = Join-Path $RepoRoot $name
        $commit = (& $selected -C $path rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Cannot determine exact upstream commit for describe.' }
        $output = @(& $selected -C $path describe --tags --exact-match $commit 2>&1 | ForEach-Object {$_.ToString()}) -join "`n"
        $exit = $LASTEXITCODE
        $accepted = $exit -eq 0 -or ($exit -eq 128 -and $output -match 'no tag exactly matches|No names found, cannot describe anything')
        $receipt.consumers += [ordered]@{arguments=@('-C',$path,'describe','--tags','--exact-match',$commit);output=$output;exitCode=$exit;status=if($accepted){'PASS'}else{'FAIL'};tagObserved=($exit -eq 0)}
        if (-not $accepted) { throw 'Pinned Git describe failed outside normal no-tag semantics.' }
    }
    # Real checker must refuse absent explicit authority even with this exact Git on PATH.
    $env:HELIOS_GIT = ''
    $negativeRoot = Join-Path $ReceiptDir 'missing-selection'
    $refused = $false
    try { & (Join-Path $PSScriptRoot 'Assert-ComponentToolchain.ps1') -Component package -ReceiptDir $negativeRoot } catch { $refused = $true }
    $negative = Get-Content (Join-Path $negativeRoot 'pre-producer-tools.json') -Raw | ConvertFrom-Json
    $missing = @($negative.blocked | Where-Object {$_.name -ceq 'git' -and $_.reason -like 'HELIOS_GIT_REQUIRED*'})
    if (-not $refused -or $negative.status -cne 'FAIL' -or $missing.Count -ne 1) { throw 'Component checker did not fail closed on missing HELIOS_GIT.' }
    $receipt.missingSelection = 'PASS_EXPECTED_REFUSAL'
    $env:HELIOS_GIT = $selected
    Import-VisualStudioEnvironment -Architecture x64
    Assert-GitResolution 'after-negative-control-restore'
    # Exercise the real version checker against disallowed adjacent release identities.
    foreach ($version in @('git version 2.55.0.windows.4','git version 2.55.0.windows.6','git version 2.56.0.windows.1','git version 2.55.1.windows.5')) {
        $check = Invoke-CIToolCheck -Name git -Arguments @('--version') -ExecutablePath $selected -ExpectedResolvedPath $selected -ExpectedVersion $version -VersionPattern ('^'+[regex]::Escape($version)+'$')
        if ($check.status -cne 'FAIL' -or $check.error -notlike '*VERSION_MISMATCH*') { throw 'Exact Git version checker accepted a mismatched release identity.' }
        $receipt.rejectedVersions += $check
    }
    $receipt.status = 'PASS'
} catch { $receipt.error = $_.Exception.Message } finally {
    $env:HELIOS_GIT = $selected
    $path = Join-Path $ReceiptDir 'git-control.json'
    ConvertTo-Json -InputObject $receipt -Depth 16 | Set-Content -LiteralPath "$path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}
Write-Host (ConvertTo-Json -InputObject $receipt -Depth 16)
if ($receipt.status -cne 'PASS') { throw "Pinned Git native control failed: $($receipt.error)" }
$global:LASTEXITCODE = 0
Write-Host 'PINNED_GIT_ACQUISITION_CONTROL=PASS; GIT_POST_VS_RESOLUTION=PASS; GIT_REAL_CONSUMERS=PASS; MISSING_HELIOS_GIT=EXPECTED_FAIL'
