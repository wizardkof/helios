param([Parameter(Mandatory)][string]$AuditDirectory,[Parameter(Mandatory)][string]$KmdRoot,[Parameter(Mandatory)][string]$RedAuditFile,[Parameter(Mandatory)][string]$RedResolutionFile)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$verifier=Join-Path $PSScriptRoot 'Test-ProducerExecutionAudit.ps1'
$redEvents=@([IO.File]::ReadAllLines($RedAuditFile)|ForEach-Object {$_|ConvertFrom-Json})
$redResolution=Get-Content -LiteralPath $RedResolutionFile -Raw|ConvertFrom-Json
if($redResolution.selectedExecutable -cne $env:HELIOS_HOST_RUST_SCRIPT){throw 'RED_SELECTED_EXECUTABLE=FAIL actual CargoMake @rust runner did not select the observed host tool'}
if($redEvents[0].profile -cne 'release' -or !($redEvents|Where-Object {$_.event -eq 'wdk-run' -and $_.task -eq 'setup-wdk-config-env-vars'}) -or ($redEvents|Where-Object event -eq 'host-run')){throw 'PRODUCER_AUDIT_RED=FAIL original @rust runner did not reproduce absent dispatcher proof'}
Write-Host "PRODUCER_AUDIT_RED=PASS selected=$($redResolution.selectedExecutable); effectiveTaskPath=$($redResolution.effectiveTaskPath); host-run event absent while diagnostic task output was observed"
$valid=Join-Path $AuditDirectory 'producer-audit-diagnostic.executions.jsonl'
& $verifier -AuditFile $valid -ExpectedProfile release -ExpectedHostTask isolation-host-probe -ExpectedPrivateRoot $env:HELIOS_WDK_PRIVATE_ROOT -ExpectedHostExecutable $env:HELIOS_HOST_RUST_SCRIPT | Write-Host

function Expect-AuditRefusal([string]$Name,[string]$Path,[string]$Profile='release',[string]$Task='isolation-host-probe') {
    try { & $verifier -AuditFile $Path -ExpectedProfile $Profile -ExpectedHostTask $Task -ExpectedPrivateRoot $env:HELIOS_WDK_PRIVATE_ROOT -ExpectedHostExecutable $env:HELIOS_HOST_RUST_SCRIPT | Out-Null }
    catch { Write-Host "AUDIT_NEGATIVE_${Name}=PASS ($($_.Exception.Message))"; return }
    throw "AUDIT_NEGATIVE_${Name}=FAIL accepted invalid producer evidence"
}

$lines=[IO.File]::ReadAllLines($valid)
$header=$lines[0] | ConvertFrom-Json
$dispatch=Join-Path $env:HELIOS_ISOLATION_ROOT 'host-dispatch\rust-script.exe'
$env:HELIOS_RUST_SCRIPT_AUDIT=$valid
$beforeVersionQuery=[IO.File]::ReadAllLines($valid).Count
$versionText=(& $dispatch --version) -join ''
if($LASTEXITCODE -ne 0 -or $versionText -ne 'rust-script 0.36.0'){throw 'Version-only host query failed'}
if([IO.File]::ReadAllLines($valid).Count -ne $beforeVersionQuery){throw 'Version-only host query emitted execution evidence'}
$versionOnly=Join-Path $AuditDirectory 'negative-version-only.jsonl'
[IO.File]::WriteAllLines($versionOnly,@($lines[0]),[Text.UTF8Encoding]::new($false))
Expect-AuditRefusal 'VERSION_ONLY' $versionOnly

# Obtain a real private Install receipt in its own invocation; it must not count as Run.
$installId=[guid]::NewGuid().ToString('N')
$installOnly=Join-Path $AuditDirectory 'negative-private-install-only.jsonl'
$installHeader=[ordered]@{event='invocation';invocation=$installId;profile='release';task='diagnostic-private-install-only';run=(Join-Path $AuditDirectory 'discard-install')} | ConvertTo-Json -Compress
[IO.File]::WriteAllText($installOnly,$installHeader+"`n",[Text.UTF8Encoding]::new($false))
$env:HELIOS_RUST_SCRIPT_AUDIT=$installOnly;$env:HELIOS_PRODUCER_PROFILE='release';$env:HELIOS_PRODUCER_INVOCATION=$installId
& pwsh -NoProfile -File (Join-Path $env:HELIOS_ISOLATION_ROOT 'Invoke-WdkRustScript.ps1') -Mode Install -PrivateRoot $env:HELIOS_WDK_PRIVATE_ROOT -TaskName diagnostic-private-install-only
if($LASTEXITCODE -ne 0){throw 'Private install-only control could not execute'}
Expect-AuditRefusal 'PRIVATE_INSTALL_ONLY' $installOnly

Expect-AuditRefusal 'WRONG_TASK' $valid 'release' 'some-other-task'
Expect-AuditRefusal 'WRONG_PROFILE' $valid 'debug' 'isolation-host-probe'

$crossInvocation=Join-Path $AuditDirectory 'negative-cross-invocation.jsonl'
$mixed=@($lines | ForEach-Object { $item=$_|ConvertFrom-Json; if($item.event -eq 'host-run'){$item.invocation=[guid]::NewGuid().ToString('N')}; $item|ConvertTo-Json -Compress -Depth 8 })
[IO.File]::WriteAllLines($crossInvocation,$mixed,[Text.UTF8Encoding]::new($false))
Expect-AuditRefusal 'CROSS_INVOCATION' $crossInvocation

Expect-AuditRefusal 'MISSING_FILE' (Join-Path $AuditDirectory 'absent.jsonl')
$incomplete=Join-Path $AuditDirectory 'negative-incomplete.jsonl'
[IO.File]::WriteAllLines($incomplete,@($lines[0],'{"event":"host-run"'),[Text.UTF8Encoding]::new($false))
Expect-AuditRefusal 'INCOMPLETE' $incomplete

# The real @rust child exits 17. The producer runner must fail and its real event must retain 17.
$failedAudit=Join-Path $AuditDirectory 'producer-audit-diagnostic-fail.executions.jsonl'
Push-Location $KmdRoot
try {
    try {
        & (Join-Path $PSScriptRoot 'Invoke-IsolatedCargoMake.ps1') -KmdRoot $KmdRoot -Profile release -Task 'producer-audit-diagnostic-fail' -AuditFile $failedAudit
        throw 'CHILD_FAILURE_PROPAGATION=FAIL runner accepted exit 17'
    } catch {
        if($_.Exception.Message -like '*runner accepted exit 17*'){throw}
    }
} finally { Pop-Location }
$failedEvents=@([IO.File]::ReadAllLines($failedAudit)|ForEach-Object {$_|ConvertFrom-Json})
if(!($failedEvents|Where-Object {$_.event -eq 'host-run' -and $_.exitCode -eq 17})){throw 'CHILD_FAILURE_PROPAGATION=FAIL missing actual child status 17'}
Expect-AuditRefusal 'CHILD_EXIT_17' $failedAudit
Write-Host 'CHILD_FAILURE_PROPAGATION=PASS'

# A wrong-version executable is selected explicitly; dispatcher must refuse it before invoking a child.
$stubSource=Join-Path $AuditDirectory 'incompatible-rust-script.rs'
$stubExe=Join-Path $AuditDirectory 'incompatible-rust-script.exe'
[IO.File]::WriteAllText($stubSource,'fn main(){println!("rust-script 9.99.0");}',[Text.UTF8Encoding]::new($false))
& rustc $stubSource -o $stubExe
if($LASTEXITCODE -ne 0){throw 'Could not build incompatible diagnostic helper'}
$originalHost=$env:HELIOS_HOST_RUST_SCRIPT
$env:HELIOS_HOST_RUST_SCRIPT=$stubExe
$incompatibleAudit=Join-Path $AuditDirectory 'producer-audit-incompatible-helper.executions.jsonl'
Push-Location $KmdRoot
try {
    try {
        & (Join-Path $PSScriptRoot 'Invoke-IsolatedCargoMake.ps1') -KmdRoot $KmdRoot -Profile release -Task 'producer-audit-diagnostic' -AuditFile $incompatibleAudit
        throw 'INCOMPATIBLE_HELPER=FAIL runner accepted wrong helper version'
    } catch {
        if($_.Exception.Message -like '*runner accepted wrong helper version*'){throw}
    }
} finally { Pop-Location;$env:HELIOS_HOST_RUST_SCRIPT=$originalHost }
$incompatibleEvents=@([IO.File]::ReadAllLines($incompatibleAudit)|ForEach-Object {$_|ConvertFrom-Json})
if($incompatibleEvents|Where-Object event -eq 'host-run'){throw 'INCOMPATIBLE_HELPER=FAIL host child ran with wrong version'}
if(!($incompatibleEvents|Where-Object {$_.event -eq 'host-helper-rejected' -and $_.version -eq 'rust-script 9.99.0' -and $_.exitCode -eq 92})){throw 'INCOMPATIBLE_HELPER=FAIL expected version gate was not observed'}
try { & $verifier -AuditFile $incompatibleAudit -ExpectedProfile release -ExpectedHostTask isolation-host-probe -ExpectedPrivateRoot $env:HELIOS_WDK_PRIVATE_ROOT -ExpectedHostExecutable $originalHost | Out-Null; throw 'INCOMPATIBLE_HELPER=FAIL verifier accepted wrong-version helper' } catch { if ($_.Exception.Message -like '*verifier accepted wrong-version helper*') { throw }; if ($_.Exception.Message -notlike '*PRODUCER_CHILD_EXECUTION_FAILED*') { throw "INCOMPATIBLE_HELPER=FAIL unexpected verifier refusal: $($_.Exception.Message)" }; Write-Host "AUDIT_NEGATIVE_INCOMPATIBLE_HELPER=PASS ($($_.Exception.Message)); version=9.99.0; exitCode=92" }
Write-Host 'PRODUCER_AUDIT_RED_GREEN=PASS'
