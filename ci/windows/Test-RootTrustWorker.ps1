param([string]$CertificatePath,[string]$Helper,[string]$Receipt,[ValidateSet('HISTORICAL','CONFIRM_FALSE','OWNED_ADD','PREEXISTING','FAILURE')][string]$Mode)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$c=[Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath)
. $Helper
$context=$null;$seed=$null;$result=[ordered]@{mode=$Mode;status='FAIL';thumbprint=$c.Thumbprint;subject=$c.Subject}
try {
 if($Mode -eq 'HISTORICAL'){Import-Certificate -FilePath $CertificatePath -CertStoreLocation Cert:\CurrentUser\Root|Out-Null;$result.status='UNEXPECTED_IMPORT_RETURNED'}
 elseif($Mode -eq 'CONFIRM_FALSE'){Import-Certificate -FilePath $CertificatePath -CertStoreLocation Cert:\CurrentUser\Root -Confirm:$false|Out-Null;$result.status='UNEXPECTED_IMPORT_RETURNED'}
 else {
  if($Mode -eq 'PREEXISTING'){$seed=Open-CITemporaryRootTrust $c}
  $context=Open-CITemporaryRootTrust $c
  $result.addDurationMs=$context.AddDurationMs;$result.presentAfterAdd=$true;$result.thumbprintMatch=$true;$result.subjectMatch=$true;$result.owned=$context.Owned
  if($Mode -eq 'PREEXISTING' -and $context.Owned){throw 'Preexisting certificate ownership violated'}
  if($Mode -eq 'FAILURE'){throw 'SYNTHETIC_AFTER_TRUST'}
  $result.status='PASS'
 }
}catch{if($Mode -eq 'FAILURE' -and $_.Exception.Message -eq 'SYNTHETIC_AFTER_TRUST'){$result.status='PASS_EXPECTED_EXCEPTION'}else{$result.error=$_.Exception.Message;throw}}
finally{
 try {
  Close-CITemporaryRootTrust $context
  $probe=[Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
  try {$probe.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly);$present=@($probe.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$c.Thumbprint,$false)).Count -ne 0}finally{$probe.Dispose()}
  $result.presentAfterInvocationCleanup=$present
  if($Mode -eq 'PREEXISTING'){if(-not $present){throw 'Preexisting certificate removed'};$result.preexistingPreserved='PASS'}
  elseif($Mode -in @('OWNED_ADD','FAILURE')){if($present){throw 'Owned certificate leaked'};$result.cleanup='PASS'}
 }finally{Close-CITemporaryRootTrust $seed;$c.Dispose();$result|ConvertTo-Json|Set-Content $Receipt}
}
