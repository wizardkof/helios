param([Parameter(Mandatory)][string]$FrozenRoot,[Parameter(Mandatory)][string]$ControlRoot,[Parameter(Mandatory)][string]$OutputDir,[Parameter(Mandatory)][string]$ReceiptDir,[int]$BudgetMinutes=90)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$callerOutputDir=$OutputDir
# Native path RED proves this preserves the directory and reaches frozen CAT/version checks.
$OutputDir=[IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$env:HELIOS_AUDIT_EVENTS=Join-Path $ReceiptDir 'audit-events.jsonl'
$diag=Join-Path $ReceiptDir 'Audit-CIPackage.diagnostic.ps1'
python "$ControlRoot/ci/windows/package_audit_timing.py" "$FrozenRoot/ci/windows/Audit-CIPackage.ps1" $diag
if($LASTEXITCODE -ne 0){throw 'Audit instrumentation source correlation failed'}
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($diag,[ref]$tokens,[ref]$errors)
if($errors.Count){throw "Diagnostic audit syntax invalid: $errors"}
$lock=Get-Content "$FrozenRoot/metadata/candidate-reservation.json" -Raw|ConvertFrom-Json
$certificate=Get-ChildItem "$OutputDir/extraction-verify/certificate" -Filter '*.cer' -File
if(@($certificate).Count -ne 1){throw 'Unique certificate required'}
$cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate.FullName)
$store="Cert:\CurrentUser\Root\$($cert.Thumbprint)"
$owned=-not(Test-Path $store)
$watch=[Diagnostics.Stopwatch]::StartNew()
$process=$null;$status='FAIL';$exit=$null
try {
 $args=@('-NoProfile','-File',"`"$diag`"",'-OutputDir',"`"$OutputDir`"",'-Version',$lock.version,'-Fingerprint',$lock.sourceFingerprint)
 $process=Start-Process (Get-Process -Id $PID).Path -ArgumentList $args -PassThru -RedirectStandardOutput "$ReceiptDir/audit-stdout.txt" -RedirectStandardError "$ReceiptDir/audit-stderr.txt"
 if(-not $process.WaitForExit($BudgetMinutes*60000)){
  & taskkill.exe /PID $process.Id /T /F | Out-File "$ReceiptDir/audit-timeout-taskkill.txt"
  throw 'AUDIT_INTERNAL_BUDGET_EXHAUSTED'
 }
 $process.Refresh();$exit=$process.ExitCode
 if($exit -ne 0){throw "Audit failed: exit $exit"}
 $receipt=Get-Content "$OutputDir/offline-installation-signature-audit.json" -Raw|ConvertFrom-Json
 if($receipt.status -ne 'PASS'){throw 'Audit PASS receipt absent'}
 $drivers=@($receipt.images|Where-Object {$_.path -match '^payload[\/]driver[\/]'})
 $expectedNames=@('helios_kmd_render.sys','helios_umd.dll','helios_umd32.dll','helios_umd12.dll','helios_umd12_32.dll')|Sort-Object
 $actualNames=@($drivers|ForEach-Object {[IO.Path]::GetFileName($_.path)})|Sort-Object
 if($drivers.Count -ne 5 -or (($actualNames -join '|') -cne ($expectedNames -join '|'))){throw 'Exactly five driver PEs required'}
 foreach($image in $drivers){if($image.signature -ne 'CATALOG_COVERED' -or $image.fileVersion -ne $lock.version -or $image.productVersion -ne $lock.version){throw "Strong driver CAT/version contract not reached: $($image.path)"}}
 $status='PASS'
} finally {
 if($process -and -not $process.HasExited){& taskkill.exe /PID $process.Id /T /F|Out-File "$ReceiptDir/audit-cleanup-taskkill.txt"}
 if($owned -and (Test-Path $store)){Remove-Item $store -Force}
 $watch.Stop()
 [ordered]@{status=$status;durationMs=$watch.Elapsed.TotalMilliseconds;exit=$exit;budgetMinutes=$BudgetMinutes;callerOutputDir=$callerOutputDir;canonicalOutputDir=$OutputDir;driverCatCoverageRequired=5;certificateOwned=$owned;certificateCleanup='COMPLETE';classification='DIAGNOSTIC_PACKAGE_ONLY';controlRunId=$env:HELIOS_CONTROL_RUN_ID;controlSha=$env:HELIOS_CONTROL_SHA;frozenSha=$env:GITHUB_SHA}|ConvertTo-Json|Set-Content "$ReceiptDir/audit-duration.json"
}
