param([string]$PackageOutput,[string]$ControlRoot,[string]$ReceiptDir)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force "$ReceiptDir/fixture"|Out-Null
. "$ControlRoot/ci/windows/PeerTrust-Common.ps1"
$cerFiles=@(Get-ChildItem "$PackageOutput/staging" -Filter helios-ci-test.cer -Recurse -File)
if($cerFiles.Count -ne 1){throw 'Exactly one package CER required'}
$root=Split-Path (Split-Path $cerFiles[0].FullName)
$names=@('helios_kmd_render.cat','helios_kmd_render.sys','helios_umd.dll','helios_umd12.dll','helios_umd32.dll','helios_umd12_32.dll','vulkan-1.dll')
Copy-Item $cerFiles[0].FullName "$ReceiptDir/fixture/helios-ci-test.cer"
foreach($name in $names){$source=if($name -eq "vulkan-1.dll"){"$root/payload/loaders/$name"}else{"$root/payload/driver/$name"};Copy-Item $source "$ReceiptDir/fixture/$name"}
# Driver SYS has both embedded signing and real catalog coverage in normal assembly.
$c=[Security.Cryptography.X509Certificates.X509Certificate2]::new("$ReceiptDir/fixture/helios-ci-test.cer")
# Use explicit OID predicate across PowerShell runtimes.
$bc=@($c.Extensions|Where-Object {$_.Oid.Value -eq '2.5.29.19'})
$eku=@($c.Extensions|Where-Object {$_.Oid.Value -eq '2.5.29.37'})
if($c.HasPrivateKey -or $c.Subject -cne $c.Issuer -or $eku.Count -ne 1 -or @($eku[0].EnhancedKeyUsages|Where-Object Value -eq '1.3.6.1.5.5.7.3.3').Count -ne 1){throw 'End-entity code signer identity rejected'}
if($bc.Count -and $bc[0].CertificateAuthority){throw 'CA certificate rejected'}
$signTool='C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
if(-not (Test-Path $signTool)){throw 'Pinned SignTool missing'}
$commands=@([ordered]@{name='EMBEDDED';file='vulkan-1.dll';catalog=$false;sha256=(Get-FileHash "$ReceiptDir/fixture/vulkan-1.dll").Hash},[ordered]@{name='CAT';file='helios_kmd_render.cat';catalog=$false;sha256=(Get-FileHash "$ReceiptDir/fixture/helios_kmd_render.cat").Hash})
foreach($name in $names|Where-Object {$_ -notlike '*.cat' -and $_ -ne 'vulkan-1.dll'}){$commands+=[ordered]@{name=$name;file=$name;catalog=$true;sha256=(Get-FileHash "$ReceiptDir/fixture/$name").Hash}}
$files=@();$crypto=@()
Add-Type -AssemblyName System.Security.Cryptography.Pkcs
foreach($name in $names){
 $path="$ReceiptDir/fixture/$name";$cmsPath=$path
 if($name -notlike '*.cat'){$cmsPath="$ReceiptDir/$name.pkcs7";python "$ControlRoot/ci/windows/peer_signature.py" $path $cmsPath;if($LASTEXITCODE -ne 0){throw 'Embedded signature extraction failed'}}
 $cms=[Security.Cryptography.Pkcs.SignedCms]::new();$cms.Decode([IO.File]::ReadAllBytes($cmsPath));$cms.CheckSignature($true)
 if($cms.SignerInfos.Count -ne 1 -or $cms.SignerInfos[0].Certificate.Thumbprint -ne $c.Thumbprint){throw 'Cryptographic signer differs from packaged CER'}
 $crypto+=[ordered]@{file=$name;cmsCryptographicSignature='PASS';signerThumbprint=$cms.SignerInfos[0].Certificate.Thumbprint}
 $arch='CAT';if($name -notlike '*.cat'){$b=[IO.File]::ReadAllBytes($path);$machine=[BitConverter]::ToUInt16($b,([BitConverter]::ToInt32($b,60)+4));$arch=switch($machine){34404{'x64'}332{'x86'}default{throw 'Unexpected architecture'}}}
 $files+=[ordered]@{path=$name;sha256=(Get-FileHash $path).Hash;size=(Get-Item $path).Length;architecture=$arch;signatureKind=$(if($name -like '*.cat'){'CAT_PKCS7'}elseif($name -eq 'vulkan-1.dll'){'EMBEDDED'}else{'EMBEDDED_AND_CATALOG'})}
}
$producer=Get-Content "$env:RUNNER_TEMP/timing/catalog-producer.json" -Raw|ConvertFrom-Json
if($producer.status -ne 'PASS_NORMAL_INF2CAT_AND_CATALOG_SIGN' -or $producer.thumbprint -ne $c.Thumbprint -or $producer.catSha256 -ne (Get-FileHash "$ReceiptDir/fixture/helios_kmd_render.cat").Hash){throw 'Catalog producer evidence mismatch'}
foreach($input in @(Get-Content "$env:RUNNER_TEMP/timing/inf2cat-input-bytes.json" -Raw|ConvertFrom-Json)){if((Get-FileHash "$ReceiptDir/fixture/$($input.name)").Hash -ne $input.sha256){throw 'Inf2Cat input bytes changed'}}
$crypto|ConvertTo-Json -Depth 8|Set-Content "$ReceiptDir/cryptographic-signatures.json"
$f=[ordered]@{classification='NEW_DIAGNOSTIC_PAIRED_FIXTURE';certificateDerSha256=(Get-FileHash "$ReceiptDir/fixture/helios-ci-test.cer").Hash;certificateThumbprint=$c.Thumbprint;subject=$c.Subject;issuer=$c.Issuer;notBefore=$c.NotBefore.ToUniversalTime().ToString('o');notAfter=$c.NotAfter.ToUniversalTime().ToString('o');eku=@($eku[0].EnhancedKeyUsages|ForEach-Object Value);keyUsage=@($c.Extensions|Where-Object {$_.Oid.Value -eq '2.5.29.15'}|ForEach-Object {$_.KeyUsages.ToString()});basicConstraints=$(if($bc.Count){$bc[0].CertificateAuthority}else{'ABSENT'});hasPrivateKey=$c.HasPrivateKey;catSha256=(Get-FileHash "$ReceiptDir/fixture/helios_kmd_render.cat").Hash;files=$files;commands=$commands;source314Head='d03d79ebec6d857d141469d197e11c04097c4d75';source314Fingerprint='a034c3d1660540ab717868444c8882ca7883fae485be6955d16ff366daf1babe';sourceProductRun='37417032761';historicalD533Replaced=$false;privateKeyExported=$false;controlSha=$env:HELIOS_CONTROL_SHA;controlRun=$env:HELIOS_CONTROL_RUN_ID;controlAttempt=$env:HELIOS_CONTROL_RUN_ATTEMPT;signTool=$signTool}
$f|ConvertTo-Json -Depth 10|Set-Content "$ReceiptDir/peer-trust-fixture.json"
$state=@();foreach($store in @('My','Root','TrustedPeople')){$found=@(PeerFind $c $store);$state+=[ordered]@{store=$store;count=$found.Count};if($found.Count){$state|ConvertTo-Json|Set-Content "$ReceiptDir/pre-red-stores.json";throw "Residual signer in $store; refuse mutation"}}
$state|ConvertTo-Json|Set-Content "$ReceiptDir/pre-red-stores.json"
# Native first RED is the prerequisite test; no trust mutation until it passes.
PeerVerify ([pscustomobject]$f) RED $false $signTool $ReceiptDir
foreach($mode in @('CAUSAL','PREEXISTING','EXCEPTION')){
 $env:PEER_EVENTS="$ReceiptDir/$mode-events.jsonl";$child=$null;$failure=$null;$addStart=$null;$windows=@();$seenWarning=$false
 try{
  $args=@('-NoProfile','-File',"`"$ControlRoot/ci/windows/PeerTrust-Worker.ps1`"",'-ControlRoot',"`"$ControlRoot`"",'-ReceiptDir',"`"$ReceiptDir`"",'-SignTool',"`"$signTool`"",'-Mode',$mode)
  $child=Start-Process (Get-Process -Id $PID).Path -ArgumentList $args -PassThru -RedirectStandardOutput "$ReceiptDir/$mode-stdout.txt" -RedirectStandardError "$ReceiptDir/$mode-stderr.txt"
  $total=[Diagnostics.Stopwatch]::StartNew()
  while(-not $child.HasExited){
   Start-Sleep -Milliseconds 50;$child.Refresh()
   if(Test-Path $env:PEER_EVENTS){
    $events=@(Get-Content $env:PEER_EVENTS|ForEach-Object {$_|ConvertFrom-Json})
    if(@($events|Where-Object {$_.mainWindowTitle -match 'Security Warning'}).Count){$seenWarning=$true;$failure='FAIL_SECURITY_WARNING';break}
    $begins=@($events|Where-Object {$_.operation -eq 'TRUSTEDPEOPLE_ADD' -and $_.edge -eq 'BEGIN'});$ends=@($events|Where-Object {$_.operation -eq 'TRUSTEDPEOPLE_ADD' -and $_.edge -eq 'END'})
    if($begins.Count -gt $ends.Count){
     $addStart=[DateTime]::Parse($begins[-1].utc).ToUniversalTime()
     $windows+=[ordered]@{utc=[DateTime]::UtcNow.ToString('o');pid=$child.Id;sessionId=$child.SessionId;mainWindowHandle=$child.MainWindowHandle.ToInt64();mainWindowTitle=$child.MainWindowTitle}
     if($child.MainWindowTitle -match 'Security Warning'){$seenWarning=$true;$failure='FAIL_SECURITY_WARNING';break}
     if(([DateTime]::UtcNow-$addStart).TotalSeconds -ge 15){$failure='FAIL_ADD_TIMEOUT';break}
    }
   }
   if($total.Elapsed.TotalMinutes -gt 5){$failure='FAIL_CONTROL_TIMEOUT';break}
  }
  if($failure){throw $failure}
  $child.WaitForExit();$child.Refresh();if($child.ExitCode -ne 0){throw "Worker failed ($mode): $($child.ExitCode)"}
  $finalEvents=@(Get-Content $env:PEER_EVENTS|ForEach-Object {$_|ConvertFrom-Json})
  if(@($finalEvents|Where-Object {$_.mainWindowTitle -match 'Security Warning'}).Count){$seenWarning=$true;throw 'FAIL_SECURITY_WARNING'}
  $result=Get-Content "$ReceiptDir/$mode-result.json" -Raw|ConvertFrom-Json
  if($result.status -notin @('PASS','PASS_EXPECTED_EXCEPTION') -or $result.cleanup -ne 'PASS'){throw 'Worker receipt rejected'}
 }finally{
  if($child -and -not $child.HasExited){& taskkill.exe /PID $child.Id /T /F|Out-File "$ReceiptDir/$mode-taskkill.txt"}
  $windows|ConvertTo-Json -Depth 6|Set-Content "$ReceiptDir/$mode-owned-windows.json"
  # New DER was absent before control. Only exact bytes from this owned transaction may be removed.
  $s=[Security.Cryptography.X509Certificates.X509Store]::new('TrustedPeople','CurrentUser')
  try{$s.Open('ReadWrite');foreach($found in @(PeerFind $c TrustedPeople)){PeerExact $c @($found);$s.Remove($found)}}finally{$s.Dispose()}
  if(@(PeerFind $c TrustedPeople).Count -ne 0){throw 'Supervisor cleanup left residue'}
  [ordered]@{mode=$mode;securityWarningObserved=$seenWarning;failure=$failure;finalAbsent=(@(PeerFind $c TrustedPeople).Count -eq 0)}|ConvertTo-Json|Set-Content "$ReceiptDir/$mode-supervisor.json"
 }
}
[ordered]@{status='PASS_RED_GREEN_RED_PREEXISTING_EXCEPTION';historicalD533='PRESERVED_ORPHAN_FIXTURE';signingCertificateLeftInMy='NO';privateKeyExported=$false}|ConvertTo-Json|Set-Content "$ReceiptDir/peer-trust-control.json"
$c.Dispose()
