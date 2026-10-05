param([Parameter(Mandatory)][string]$AuditDirectory,[Parameter(Mandatory)][string]$KmdRoot,[Parameter(Mandatory)][string]$RedAuditFile,[Parameter(Mandatory)][string]$RedResolutionFile)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$harness=Join-Path $PSScriptRoot 'Test-ProducerAuditControl.ps1'
function Invoke-ControlChild([string]$Name,[string]$Script,[string]$Resolution,[bool]$ExpectSuccess) {
    $caseRoot=Join-Path $AuditDirectory $Name
    New-Item -ItemType Directory $caseRoot | Out-Null
    Copy-Item (Join-Path $AuditDirectory 'producer-audit-diagnostic.executions.jsonl') $caseRoot
    $console=Join-Path $caseRoot 'console.log'
    # Match the GitHub Actions pwsh command wrapper, including its native exit propagation.
    $wrapper=Join-Path $caseRoot 'invoke.ps1'
    $quote={param($value) "'"+$value.Replace("'","''")+"'"}
    $command='& '+(& $quote $Script)+' -AuditDirectory '+(& $quote $caseRoot)+' -KmdRoot '+(& $quote $KmdRoot)+' -RedAuditFile '+(& $quote $RedAuditFile)+' -RedResolutionFile '+(& $quote $Resolution)
    [IO.File]::WriteAllText($wrapper,"`$ErrorActionPreference='Stop'`n"+$command+"`nif (Test-Path variable:LASTEXITCODE) { exit `$LASTEXITCODE }`n")
    & pwsh -NoProfile -Command "& '$($wrapper.Replace("'","''"))'" *> $console
    $actual=$LASTEXITCODE
    [ordered]@{case=$Name;exitCode=$actual;expectedSuccess=$ExpectSuccess}|ConvertTo-Json -Compress|Set-Content (Join-Path $caseRoot 'exit.json')
    if (($actual -eq 0) -ne $ExpectSuccess) { throw "CONTROL_EXIT_${Name}=FAIL exit=$actual" }
    Write-Host "CONTROL_EXIT_${Name}=PASS exit=$actual"
    return $caseRoot
}
# Real historical harness, with only its final normalization removed, must reproduce RED.
$copies=Join-Path $AuditDirectory 'script-copies'
New-Item -ItemType Directory $copies | Out-Null
foreach($name in @('Test-ProducerAuditControl.ps1','Test-ProducerExecutionAudit.ps1','Invoke-IsolatedCargoMake.ps1','adapt_wdk_recipe.py')) { Copy-Item (Join-Path $PSScriptRoot $name) $copies }
$redScript=Join-Path $copies 'Test-ProducerAuditControl.ps1'
$source=[IO.File]::ReadAllText($harness)
[IO.File]::WriteAllText($redScript,$source.Replace('$global:LASTEXITCODE = 0',''))
$redRoot=Invoke-ControlChild 'RESIDUAL_RED' $redScript $RedResolutionFile $false
if (!(Select-String -Path (Join-Path $redRoot 'console.log') -SimpleMatch 'PRODUCER_AUDIT_RED_GREEN=PASS')) { throw 'CONTROL_EXIT_RED=FAIL assertions did not complete' }
$greenRoot=Invoke-ControlChild 'EXPECTED_GREEN' $harness $RedResolutionFile $true
foreach($marker in @('PRODUCER_AUDIT_RED=PASS','PRODUCER_AUDIT_RED_GREEN=PASS','CHILD_FAILURE_PROPAGATION=PASS','AUDIT_NEGATIVE_CHILD_EXIT_17=PASS','AUDIT_NEGATIVE_INCOMPATIBLE_HELPER=PASS')) {
    if (!(Select-String -Path (Join-Path $greenRoot 'console.log') -SimpleMatch $marker)) { throw "CONTROL_EXIT_GREEN=FAIL missing $marker" }
    Write-Host $marker
}
# Break a real assertion input, rather than simulating LASTEXITCODE.
$badResolution=Join-Path $AuditDirectory 'wrong-resolution.json'
$item=Get-Content $RedResolutionFile -Raw|ConvertFrom-Json
$item.selectedExecutable='deliberately-wrong.exe'
$item|ConvertTo-Json|Set-Content $badResolution
$badRoot=Invoke-ControlChild 'BROKEN_ASSERTION' $harness $badResolution $false
if (!(Select-String -Path (Join-Path $badRoot 'console.log') -SimpleMatch 'RED_SELECTED_EXECUTABLE=FAIL')) { throw 'CONTROL_EXIT_BROKEN_ASSERTION=FAIL wrong failure' }
# Mutation control: actually compile a dispatcher that wrongly accepts 9.99.0.
# Only this child gets a copied isolation root; production dispatcher stays intact.
$mutationRoot=Join-Path $AuditDirectory 'mutation-isolation'
New-Item -ItemType Directory (Join-Path $mutationRoot 'host-dispatch') -Force | Out-Null
Copy-Item (Join-Path $env:HELIOS_ISOLATION_ROOT 'host-dispatch\cargo.exe') (Join-Path $mutationRoot 'host-dispatch\cargo.exe')
Copy-Item (Join-Path $env:HELIOS_ISOLATION_ROOT 'Invoke-WdkRustScript.ps1') $mutationRoot
$dispatchSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'host-dispatch.rs'))
$needle='text != "rust-script 0.36.0"'
if (!$dispatchSource.Contains($needle)) { throw 'Dispatcher mutation source gate missing' }
$mutant=Join-Path $mutationRoot 'accept-wrong-version.rs'
[IO.File]::WriteAllText($mutant,$dispatchSource.Replace($needle,'(text != "rust-script 0.36.0" && text != "rust-script 9.99.0")'))
& rustc $mutant -o (Join-Path $mutationRoot 'host-dispatch\rust-script.exe')
if($LASTEXITCODE -ne 0){throw 'Mutation dispatcher compile failed'}
$originalRoot=$env:HELIOS_ISOLATION_ROOT
try {
    $env:HELIOS_ISOLATION_ROOT=$mutationRoot
    $acceptedRoot=Invoke-ControlChild 'WRONG_HELPER_ACCEPTED' $harness $RedResolutionFile $false
} finally { $env:HELIOS_ISOLATION_ROOT=$originalRoot }
if (!(Select-String -Path (Join-Path $acceptedRoot 'console.log') -SimpleMatch 'runner accepted wrong helper version')) { throw 'CONTROL_EXIT_WRONG_HELPER_ACCEPTED=FAIL wrong failure' }
# Debug production uses cargo-make's real dev profile. Exercise the same recipe and verifier.
$devAudit=Join-Path $AuditDirectory 'producer-audit-dev.executions.jsonl'
Push-Location $KmdRoot
try {
    & (Join-Path $PSScriptRoot 'Invoke-IsolatedCargoMake.ps1') -KmdRoot $KmdRoot -Profile dev -Task producer-audit-diagnostic -AuditFile $devAudit
    if($LASTEXITCODE -ne 0){throw 'PRODUCER_DEV_PROFILE=FAIL diagnostic execution failed'}
} finally { Pop-Location }
& (Join-Path $PSScriptRoot 'Test-ProducerExecutionAudit.ps1') -AuditFile $devAudit -ExpectedProfile dev -ExpectedHostTask isolation-host-probe -ExpectedPrivateRoot $env:HELIOS_WDK_PRIVATE_ROOT -ExpectedHostExecutable $env:HELIOS_HOST_RUST_SCRIPT | Write-Host
Write-Host 'PRODUCER_DEV_PROFILE=PASS'
Write-Host 'CONTROL_EXIT_RED_GREEN=PASS'
$global:LASTEXITCODE=0
