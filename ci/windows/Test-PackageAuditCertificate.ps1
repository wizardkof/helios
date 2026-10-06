param([Parameter(Mandatory)][string]$FrozenRoot,[Parameter(Mandatory)][string]$ReceiptDir,[int]$BudgetSeconds=180)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
. "$FrozenRoot/metadata/Read-HeliosMetadata.ps1"
$metadata=Read-HeliosMetadata $FrozenRoot
$assembly=Get-Content "$FrozenRoot/ci/windows/Assemble-Package.ps1" -Raw
$creation=[regex]::Match($assembly,'(?ms)^\$certificate = New-SelfSignedCertificate.*?\-NotAfter \(\[DateTime\]::UtcNow.AddYears\(2\)\)')
if(-not $creation.Success){throw 'Frozen certificate creation expression absent'}
$shortCommit='d03d79eb';$subject="CN=$($metadata.HELIOS_PUBLISHER) $($metadata.HELIOS_PRODUCT) GitHub CI Test Signing $shortCommit"
# Actual frozen certificate constructor, not a fake or malformed certificate.
Invoke-Expression $creation.Value
$cer=Join-Path $ReceiptDir 'diagnostic-real-test-certificate.cer'
try {Export-Certificate -Cert $certificate -FilePath $cer -Type CERT|Out-Null}finally{Remove-Item "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -Force}
$thumb=$certificate.Thumbprint;$store="Cert:\CurrentUser\Root\$thumb"
# The supervisor uses direct .NET store access; suspect Cert provider commands run only in timed children.
function RootCertificates {
 $s=[Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
 try {$s.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly);return @($s.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$thumb,$false))}finally{$s.Dispose()}
}
function RemoveOwnedRoot {
 $s=[Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
 try {$s.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite);foreach($c in @($s.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$thumb,$false))){$s.Remove($c)}}finally{$s.Dispose()}
}
if(@(RootCertificates).Count -ne 0){throw 'Fresh owned certificate must not preexist'}
$audit=Get-Content "$FrozenRoot/ci/windows/Audit-CIPackage.ps1" -Raw
$block=[regex]::Match($audit,'(?ms)^\$certFile=Get-ChildItem.*?^if\(\$owned\)\{Import-Certificate.*?\}')
if(-not $block.Success){throw 'Frozen certificate setup block absent'}
$body=$block.Value
$anchors=@(
 @('$certFile=Get-ChildItem','$certFile=Get-ChildItem','ENUMERATE'),
 @('if(@($certFile).Count','if(@($certFile).Count','ENUMERATE_END'),
 @('$cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($certFile.FullName)','$cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($certFile.FullName)','CONSTRUCTOR'),
 @('$store="Cert:\CurrentUser\Root\$($cert.Thumbprint)";$owned=-not(Test-Path $store)','$store="Cert:\CurrentUser\Root\$($cert.Thumbprint)";$owned=-not(Test-Path $store)','STORE_LOOKUP'),
 @('if($owned){Import-Certificate -FilePath $certFile.FullName -CertStoreLocation Cert:\CurrentUser\Root|Out-Null}','if($owned){Import-Certificate -FilePath $certFile.FullName -CertStoreLocation Cert:\CurrentUser\Root|Out-Null}','IMPORT')
)
$changes=@()
foreach($entry in $anchors){
 $old=[string]$entry[0];$phase=[string]$entry[2]
 if($body.Split([string[]]@($old),[StringSplitOptions]::None).Count -ne 2){throw "Unexpected source anchor $phase"}
 if($phase -eq 'ENUMERATE'){$new="Event ENUMERATE BEGIN`n$old"}
 elseif($phase -eq 'ENUMERATE_END'){$new="Event ENUMERATE END`n$old"}
 else{$new="Event $phase BEGIN`n$old`nEvent $phase END"}
 $body=$body.Replace($old,$new);$changes+=@{old=$old;new=$new}
}
$restored=$body
for($i=$changes.Count-1;$i -ge 0;$i--){$restored=$restored.Replace($changes[$i].new,$changes[$i].old)}
if($restored -cne $block.Value){throw 'Certificate timing restoration failed'}
# Close the original try scope; the supervisor owns cleanup even on forced termination.
$body+="`n} finally {Event CHILD_FINALLY BEGIN}`nEvent COMPLETE END"
$prefix=@'
param([string]$Extract,[string]$Events)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$extract=$Extract
$watch=[Diagnostics.Stopwatch]::StartNew()
function Event([string]$phase,[string]$edge){
 $row=[ordered]@{utc=[DateTime]::UtcNow.ToString('o');elapsedMs=$watch.Elapsed.TotalMilliseconds;phase=$phase;edge=$edge;pid=$PID;powerShellVersion=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;apartment=[Threading.Thread]::CurrentThread.GetApartmentState().ToString()}
 $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $row -Compress)+"`n")
 $stream=[IO.File]::Open($Events,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
'@
$extract=Join-Path $ReceiptDir 'fixture/extraction-verify'
New-Item -ItemType Directory -Force "$extract/certificate"|Out-Null
Copy-Item $cer "$extract/certificate/fixture.cer"
$child=Join-Path $ReceiptDir 'certificate-child.diagnostic.ps1'
($prefix+"`n"+$body)|Set-Content $child -Encoding UTF8
[ordered]@{classification='CERTIFICATE_SUBPHASE_ONLY';historicalCertificateBytes=$false;fixtureRecipe='EXACT_FROZEN_ASSEMBLE_EXPRESSION';creationExpression=$creation.Value;auditBlock=$block.Value;changes=$changes;frozenAuditSha256=(Get-FileHash "$FrozenRoot/ci/windows/Audit-CIPackage.ps1").Hash;frozenAssemblySha256=(Get-FileHash "$FrozenRoot/ci/windows/Assemble-Package.ps1").Hash;certificateSha256=(Get-FileHash $cer).Hash;thumbprint=$thumb;subject=$certificate.Subject}|ConvertTo-Json -Depth 6|Set-Content "$ReceiptDir/fixture-provenance.json"
$rows=@()
foreach($mode in @('CORE_COMMAND_DISCOVERY','DESKTOP_NATIVE_MODULEPATH')){
 $caseChild=Join-Path $ReceiptDir "$mode-child.diagnostic.ps1"
 $module="Event SECURITY_MODULE BEGIN`nImport-Module Microsoft.PowerShell.Security -ErrorAction Stop`nEvent SECURITY_MODULE END`nEvent CERT_DRIVE BEGIN`nGet-PSDrive Cert -ErrorAction Stop|Select-Object Name,Provider|ConvertTo-Json|Set-Content `"$ReceiptDir/$mode-cert-drive.json`"`nEvent CERT_DRIVE END`n"
 if($mode -eq 'CORE_COMMAND_DISCOVERY'){
  $module+="Event COMMAND_DISCOVERY BEGIN`nGet-Command Import-Certificate -ErrorAction Stop|Select-Object Name,Source,ModuleName,CommandType,Definition|ConvertTo-Json -Depth 3|Set-Content `"$ReceiptDir/$mode-command.json`"`nEvent COMMAND_DISCOVERY END`n"
 }
 ($prefix+"`n"+$module+$body)|Set-Content $caseChild -Encoding UTF8
 $events=Join-Path $ReceiptDir "$mode-events.jsonl"
 $exe=if($mode.StartsWith('DESKTOP')){"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"}else{(Get-Process -Id $PID).Path}
 $arguments=@('-NoProfile')
 if($mode -eq 'CORE_STA'){$arguments+='-STA'}
 $arguments+=@('-File',"`"$caseChild`"",'-Extract',"`"$extract`"",'-Events',"`"$events`"")
 $w=[Diagnostics.Stopwatch]::StartNew();$p=$null;$status='FAIL';$exit=$null;$originalModulePath=$env:PSModulePath
 try {
  if(@(RootCertificates).Count -ne 0){throw 'Certificate not cleaned before case'}
  if($mode.StartsWith('DESKTOP')){$env:PSModulePath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"}
  [ordered]@{inheritedModulePath=$originalModulePath;childModulePath=$env:PSModulePath;executable=$exe}|ConvertTo-Json|Set-Content "$ReceiptDir/$mode-environment.json"
  $p=Start-Process $exe -ArgumentList $arguments -PassThru -RedirectStandardOutput "$ReceiptDir/$mode-stdout.txt" -RedirectStandardError "$ReceiptDir/$mode-stderr.txt"
  if($p.WaitForExit($BudgetSeconds*1000)){$p.Refresh();$exit=$p.ExitCode;$status=if($exit -eq 0 -and (@(RootCertificates).Count -ne 0)){'PASS_ROOT_IMPORTED'}else{'FAIL_EXIT_OR_ROOT_ABSENT'}}
  else {
   $status='FAIL_TIMEOUT'
   Get-CimInstance Win32_Process|Where-Object {$_.ProcessId -eq $p.Id -or $_.ParentProcessId -eq $p.Id}|Select-Object Name,ProcessId,ParentProcessId|ConvertTo-Json|Set-Content "$ReceiptDir/$mode-active-processes.json"
   & taskkill.exe /PID $p.Id /T /F|Out-File "$ReceiptDir/$mode-taskkill.txt"
  }
 } finally {
  $env:PSModulePath=$originalModulePath
  if($p -and -not $p.HasExited){& taskkill.exe /PID $p.Id /T /F|Out-File "$ReceiptDir/$mode-final-taskkill.txt"}
  RemoveOwnedRoot
  $rows+=@{mode=$mode;status=$status;durationMs=$w.Elapsed.TotalMilliseconds;exit=$exit;budgetSeconds=$BudgetSeconds;certificateCleanupVerified=(-not(@(RootCertificates).Count -ne 0));executable=$exe}
  [ordered]@{classification='CERTIFICATE_SUBPHASE_TIMING_ONLY';signatures='NOT_RUN';package='NOT_RUN';cases=$rows}|ConvertTo-Json -Depth 5|Set-Content "$ReceiptDir/certificate-control.json"
 }
}
