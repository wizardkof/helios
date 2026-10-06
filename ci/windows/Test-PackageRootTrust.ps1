param([string]$ControlRoot,[string]$ReceiptDir,[int]$BudgetSeconds=30)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$cer="$ControlRoot/ci/windows/fixtures/package-root-trust.cer"
$provenance=Get-Content "$ControlRoot/ci/windows/fixtures/package-root-trust-provenance.json" -Raw|ConvertFrom-Json
$c=[Security.Cryptography.X509Certificates.X509Certificate2]::new($cer)
$hash=(Get-FileHash $cer -Algorithm SHA256).Hash
if($hash -ne $provenance.certificateSha256 -or $c.HasPrivateKey -or $c.Subject -cne $c.Issuer){throw 'Public self-signed fixture identity mismatch'}
[ordered]@{sha256=$hash;thumbprint=$c.Thumbprint;subject=$c.Subject;issuer=$c.Issuer;notBefore=$c.NotBefore.ToUniversalTime().ToString('o');notAfter=$c.NotAfter.ToUniversalTime().ToString('o');hasPrivateKey=$c.HasPrivateKey;selfSignedIdentity=$true;selfSignedProvenance='FROZEN_NEW_SELFSIGNED_CERTIFICATE_RECIPE';historicalPackageCertificateBytes=$false;frozenSha='d03d79ebec6d857d141469d197e11c04097c4d75';controlSha=$env:GITHUB_SHA;controlRun=$env:GITHUB_RUN_ID;controlAttempt=$env:GITHUB_RUN_ATTEMPT}|ConvertTo-Json|Set-Content "$ReceiptDir/certificate-identity.json"
Copy-Item $cer "$ReceiptDir/public-certificate.cer"
Copy-Item "$ControlRoot/ci/windows/fixtures/package-root-trust-provenance.json" "$ReceiptDir/fixture-provenance.json"
function FindRoot {
 $s=[Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
 try {$s.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly);return @($s.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$c.Thumbprint,$false))}finally{$s.Dispose()}
}
$rows=@()
try {
 foreach($mode in @('HISTORICAL','CONFIRM_FALSE','OWNED_ADD','PREEXISTING','FAILURE')){
  if(@(FindRoot).Count -ne 0){throw 'Fixture Root cert preexists outside owned control; refuse mutation'}
  $child=$null;$exit=$null;$status='FAIL';$w=[Diagnostics.Stopwatch]::StartNew()
  try {
   $args=@('-NoProfile','-File',"`"$ControlRoot/ci/windows/Test-RootTrustWorker.ps1`"",'-CertificatePath',"`"$cer`"",'-Helper',"`"$ControlRoot/ci/windows/Temporary-RootTrust.ps1`"",'-Receipt',"`"$ReceiptDir/$mode-worker.json`"",'-Mode',$mode)
   $child=Start-Process (Get-Process -Id $PID).Path -ArgumentList $args -PassThru -RedirectStandardOutput "$ReceiptDir/$mode-stdout.txt" -RedirectStandardError "$ReceiptDir/$mode-stderr.txt"
   if($child.WaitForExit($BudgetSeconds*1000)){$child.Refresh();$exit=$child.ExitCode;$status=if($exit -eq 0){'RETURNED'}else{'FAIL_EXIT'}}
   else {
    $child.Refresh();[ordered]@{pid=$child.Id;sessionId=$child.SessionId;mainWindowHandle=$child.MainWindowHandle.ToInt64();mainWindowTitle=$child.MainWindowTitle}|ConvertTo-Json|Set-Content "$ReceiptDir/$mode-window.json"
    & taskkill.exe /PID $child.Id /T /F|Out-File "$ReceiptDir/$mode-taskkill.txt"
    $status='FAIL_TIMEOUT'
   }
  }finally{
   if($child -and -not $child.HasExited){& taskkill.exe /PID $child.Id /T /F|Out-File "$ReceiptDir/$mode-final-taskkill.txt"}
   # Initial absence was enforced. Remove only exact matching public bytes owned by this case.
   $s=[Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
   try {$s.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite);foreach($found in @(FindRoot)){if([Convert]::ToBase64String($found.RawData) -cne [Convert]::ToBase64String($c.RawData)){throw 'Unexpected Root identity; refuse cleanup'};$s.Remove($found)}}finally{$s.Dispose()}
   $clean=@(FindRoot).Count -eq 0
   $rows+=@{mode=$mode;status=$status;exit=$exit;durationMs=$w.Elapsed.TotalMilliseconds;budgetSeconds=$BudgetSeconds;cleanupVerified=$clean}
   [ordered]@{status='OBSERVATION_ONLY';uiCause='NOT_PROVEN';cases=$rows}|ConvertTo-Json -Depth 5|Set-Content "$ReceiptDir/root-trust-control.json"
   if(-not $clean){throw 'Control cleanup incomplete'}
  }
 }
 foreach($row in $rows){
  if($row.mode -in @('HISTORICAL','CONFIRM_FALSE')){if($row.status -ne 'FAIL_TIMEOUT'){throw "Required native nonreturning RED not reproduced: $($row.mode)"}}
  else {
   if($row.status -ne 'RETURNED' -or $row.exit -ne 0){throw "X509Store GREEN failed: $($row.mode)"}
   $worker=Get-Content "$ReceiptDir/$($row.mode)-worker.json" -Raw|ConvertFrom-Json
   if($worker.status -notin @('PASS','PASS_EXPECTED_EXCEPTION')){throw 'GREEN receipt absent'}
  }
 }
 [ordered]@{status='PASS_RED_GREEN';uiCause='NOT_PROVEN';cases=$rows}|ConvertTo-Json -Depth 5|Set-Content "$ReceiptDir/root-trust-control.json"
}finally{$c.Dispose()}
