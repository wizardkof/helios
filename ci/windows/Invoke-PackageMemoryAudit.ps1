param([string]$FrozenRoot,[string]$ControlRoot,[string]$OutputDir,[string]$ReceiptDir,[string]$Verifier)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$OutputDir=[IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$env:HELIOS_AUDIT_EVENTS="$ReceiptDir/audit-events.jsonl"
$env:HELIOS_MEMORY_VERIFIER=$Verifier
$import=Get-Content "$(Split-Path $Verifier)/qualified-verifier-import.json" -Raw|ConvertFrom-Json
if($import.status -ne 'PASS_EXACT_NATIVE_QUALIFIED_VERIFIER' -or (Get-FileHash $Verifier).Hash -ne $import.executableSha256){throw 'Qualified verifier binary differs'}
$diag="$ReceiptDir/Audit-CIPackage.memory-diagnostic.ps1"
python "$ControlRoot/ci/windows/package_memory_audit.py" "$FrozenRoot/ci/windows/Audit-CIPackage.ps1" $diag
if($LASTEXITCODE -ne 0){throw 'Diagnostic audit source correlation failed'}
$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($diag,[ref]$t,[ref]$e);if($e.Count){throw 'Diagnostic audit syntax invalid'}
$lock=Get-Content "$FrozenRoot/metadata/candidate-reservation.json" -Raw|ConvertFrom-Json
$cer=@(Get-ChildItem "$OutputDir/extraction-verify/certificate" -File -Filter '*.cer');if($cer.Count -ne 1){throw 'Exactly one Package CER required'}
$c=[Security.Cryptography.X509Certificates.X509Certificate2]::new($cer[0].FullName)
function Snapshot {
 $rows=@();foreach($location in @('CurrentUser','LocalMachine')){foreach($name in @('Root','TrustedPeople','TrustedPublisher','My')){
  $s=[Security.Cryptography.X509Certificates.X509Store]::new($name,$location)
  try{$s.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly -bor [Security.Cryptography.X509Certificates.OpenFlags]::OpenExistingOnly);$rows+=[ordered]@{location=$location;store=$name;matches=@($s.Certificates.Find('FindByThumbprint',$c.Thumbprint,$false)|ForEach-Object {[Convert]::ToBase64String($_.RawData)}|Sort-Object)}}finally{$s.Dispose()}
 }};return $rows
}
$before=Snapshot;$before|ConvertTo-Json -Depth 8|Set-Content "$ReceiptDir/audit-stores-before.json"
$w=[Diagnostics.Stopwatch]::StartNew();$status='FAIL';$exit=$null;$process=$null
try{
 $args=@('-NoProfile','-File',"`"$diag`"",'-OutputDir',"`"$OutputDir`"",'-Version',$lock.version,'-Fingerprint',$lock.sourceFingerprint)
 $process=Start-Process (Get-Process -Id $PID).Path -ArgumentList $args -PassThru -RedirectStandardOutput "$ReceiptDir/audit-stdout.txt" -RedirectStandardError "$ReceiptDir/audit-stderr.txt"
 # Diagnostic-only finite watchdog; product timeout remains unchanged until full measurements.
 if(-not $process.WaitForExit(300000)){& taskkill.exe /PID $process.Id /T /F|Out-File "$ReceiptDir/audit-taskkill.txt";throw 'Diagnostic memory audit watchdog'}
 $process.WaitForExit();$process.Refresh();$exit=$process.ExitCode;if($exit -ne 0){throw "Diagnostic audit refused at observed phase: exit $exit"}
 $receipt=Get-Content "$OutputDir/offline-installation-signature-audit.json" -Raw|ConvertFrom-Json
 if($receipt.status -ne 'PASS'){throw 'Full audit receipt absent'}
 $drivers=@($receipt.images|Where-Object {$_.path -match '^payload[\\/]driver[\\/]'})
 if($drivers.Count -ne 5){throw 'Five catalog-covered driver images required'}
 foreach($d in $drivers){if($d.signature -ne 'CATALOG_COVERED' -or $d.fileVersion -ne $lock.version -or $d.productVersion -ne $lock.version){throw 'Strong driver catalog/version gate not reached'}}
 $events=@(Get-Content $env:HELIOS_AUDIT_EVENTS|ForEach-Object {$_|ConvertFrom-Json})
 foreach($phase in @('TRUST','DRIVER_CAT_SIGNATURE','SIGNTOOL','LLVM_READOBJ','HASH','INF','SCRIPT_PARSE','INSTALL_STATIC','MANIFEST','SHIM','TRUST_CLEANUP','TOTAL')){foreach($edge in @('BEGIN','END')){if(@($events|Where-Object {$_.phase -eq $phase -and $_.edge -eq $edge}).Count -eq 0){throw "Audit phase absent: $phase $edge"}}}
 $status='PASS'
}finally{
 if($process -and -not $process.HasExited){& taskkill.exe /PID $process.Id /T /F|Out-File "$ReceiptDir/audit-final-taskkill.txt"}
 $after=Snapshot;$after|ConvertTo-Json -Depth 8|Set-Content "$ReceiptDir/audit-stores-after.json"
 $same=($before|ConvertTo-Json -Compress -Depth 8) -ceq ($after|ConvertTo-Json -Compress -Depth 8)
 [ordered]@{status=$status;exit=$exit;durationMs=$w.Elapsed.TotalMilliseconds;diagnosticBudgetSeconds=300;productTimeoutChanged=$false;storeImmutability=$(if($same){'PASS'}else{'FAIL'});packageCertificateDerSha256=(Get-FileHash $cer[0].FullName).Hash;packageCertificateThumbprint=$c.Thumbprint;certificateSource='EXACT_DYNAMIC_CER_FROM_THIS_DIAGNOSTIC_PACKAGE';globalPinnedDer=$false;controlSha=$env:HELIOS_CONTROL_SHA;controlRun=$env:HELIOS_CONTROL_RUN_ID;frozenSha=$env:GITHUB_SHA;verifierQualification=$import}|ConvertTo-Json -Depth 12|Set-Content "$ReceiptDir/audit-duration.json"
 $c.Dispose();if(-not $same){throw 'Persistent store mutation during audit'}
}
