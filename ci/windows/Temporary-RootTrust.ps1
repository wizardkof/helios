function Assert-CIRootCertificateIdentity($Expected,$Found) {
 if(@($Found).Count -ne 1){throw 'Exactly one Root certificate required'}
 if($Found.Thumbprint -ne $Expected.Thumbprint -or $Found.Subject -cne $Expected.Subject -or [Convert]::ToBase64String($Found.RawData) -cne [Convert]::ToBase64String($Expected.RawData)){throw 'Root certificate identity mismatch'}
}
function Open-CITemporaryRootTrust([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate) {
 $root=[Security.Cryptography.X509Certificates.X509Store]::new([Security.Cryptography.X509Certificates.StoreName]::Root,[Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
 $owned=$false
 try {
  $root.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  $before=@($root.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$Certificate.Thumbprint,$false))
  $watch=[Diagnostics.Stopwatch]::StartNew()
  if($before.Count -eq 0){$owned=$true;$root.Add($Certificate)}else{Assert-CIRootCertificateIdentity $Certificate $before}
  $after=@($root.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$Certificate.Thumbprint,$false))
  Assert-CIRootCertificateIdentity $Certificate $after
  return [pscustomobject]@{Store=$root;Certificate=$Certificate;Owned=$owned;AddDurationMs=$watch.Elapsed.TotalMilliseconds}
 } catch {
  try {if($owned){$root.Remove($Certificate)}}finally{$root.Dispose()}
  throw
 }
}
function Close-CITemporaryRootTrust($Context) {
 if($null -eq $Context){return}
 try {
  if($Context.Owned){
   $Context.Store.Remove($Context.Certificate)
   if(@($Context.Store.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$Context.Certificate.Thumbprint,$false)).Count -ne 0){throw 'Owned Root certificate cleanup failed'}
  }else{
   Assert-CIRootCertificateIdentity $Context.Certificate @($Context.Store.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$Context.Certificate.Thumbprint,$false))
  }
 }finally{$Context.Store.Dispose()}
}
