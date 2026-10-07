param([string]$ControlRoot,[string]$FixtureRoot,[string]$ReceiptDir)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force "$ReceiptDir/fixture","$ReceiptDir/negative"|Out-Null
Copy-Item "$FixtureRoot/producer/fixture/*" "$ReceiptDir/fixture"
Copy-Item "$FixtureRoot/producer/peer-trust-fixture.json","$FixtureRoot/fixture-import.json" $ReceiptDir
Copy-Item "$ControlRoot/ci/windows/fixtures/package-root-trust.cer" "$ReceiptDir/negative/wrong.cer"
$cer="$ReceiptDir/fixture/helios-ci-test.cer";$cat="$ReceiptDir/fixture/helios_kmd_render.cat";$pe="$ReceiptDir/fixture/vulkan-1.dll"
$c=[Security.Cryptography.X509Certificates.X509Certificate2]::new($cer)
function Snapshot {
 $rows=@()
 foreach($location in @('CurrentUser','LocalMachine')){foreach($name in @('Root','TrustedPeople','TrustedPublisher','My')){
  $store=[Security.Cryptography.X509Certificates.X509Store]::new($name,$location)
  try{$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly -bor [Security.Cryptography.X509Certificates.OpenFlags]::OpenExistingOnly);$found=@($store.Certificates.Find('FindByThumbprint',$c.Thumbprint,$false));$rows+=[ordered]@{location=$location;store=$name;thumbprint=$c.Thumbprint;matches=@($found|ForEach-Object {[Convert]::ToBase64String($_.RawData)}|Sort-Object)}}finally{$store.Dispose()}
 }}
 return $rows
}
$before=Snapshot;$before|ConvertTo-Json -Depth 8|Set-Content "$ReceiptDir/stores-before.json"
$helper="$ReceiptDir/package-verify.exe";$cases=@()
try{
 . "$ControlRoot/ci/windows/Initialize-HeliosBuild.ps1"
 Import-VisualStudioEnvironment x64
 & cl.exe /nologo /std:c++17 /EHsc /W4 /DUNICODE /D_UNICODE "$ControlRoot/ci/windows/memory-trust/package_verify.cpp" "/Fe:$helper" "/Fo:$ReceiptDir/package-verify.obj" /link wintrust.lib crypt32.lib psapi.lib
 if($LASTEXITCODE -ne 0){throw 'Native diagnostic helper compile failed'}
 function InvokeCase($Name,$Kind,$File,$Cert,$Catalog,$ExpectPass,[int]$Repeat=1) {
  $args=@($Kind,$File,$Cert,"$ReceiptDir/$Name.json")
  if($Kind -eq 'catalog'){$args+=@($Catalog)}
  if($Repeat -ne 1){if($Kind -eq 'embedded'){$args+=@('UNUSED')};$args+=@($Repeat.ToString())}
  $p=Start-Process $helper -ArgumentList @($args|ForEach-Object {'"'+$_+'"'}) -PassThru -NoNewWindow -RedirectStandardOutput "$ReceiptDir/$Name-stdout.txt" -RedirectStandardError "$ReceiptDir/$Name-stderr.txt"
  if(-not $p.WaitForExit(30000)){& taskkill.exe /PID $p.Id /T /F|Out-File "$ReceiptDir/$Name-taskkill.txt";throw 'Verifier watchdog'}
  $p.WaitForExit();$p.Refresh();$exit=$p.ExitCode;$p.Dispose()
  if(-not(Test-Path "$ReceiptDir/$Name.json")){throw "Missing native receipt $Name"}
  $r=Get-Content "$ReceiptDir/$Name.json" -Raw|ConvertFrom-Json
  $row=[ordered]@{case=$Name;expectedPass=$ExpectPass;exit=$exit;finalStatus=$r.finalStatus;stateVerifyCount=$r.stateVerifyCount;stateCloseCount=$r.stateCloseCount}
  $script:cases+=@($row);$script:cases|ConvertTo-Json -Depth 8|Set-Content "$ReceiptDir/matrix-progress.json"
  if($r.stateVerifyCount -ne $r.stateCloseCount -or $r.stateVerifyCount -ne $Repeat){throw "WinTrust CLOSE not proven $Name"}
  if($ExpectPass){if($exit -ne 0 -or $r.finalStatus -ne 'PASS'){throw "Original exclusive peer verifier failed: $Name"}}
  else{if($exit -ne 1 -or $r.finalStatus -ne 'FAIL'){throw "Negative accepted or invalid execution: $Name"}}
  return $r
 }
 # First native qualification; stop immediately on original exclusive trust failure.
 $embedded=InvokeCase EMBEDDED_ORIGINAL embedded $pe $cer '' $true
 python "$ControlRoot/ci/windows/Prepare-MemoryTrustNegatives.py" --fixture "$ReceiptDir/fixture" --output "$ReceiptDir/negative"
 if($LASTEXITCODE -ne 0){throw 'Negative fixture construction failed'}
 $tamper=InvokeCase EMBEDDED_TAMPER embedded "$ReceiptDir/negative/tampered-pe.dll" $cer '' $false
 if($tamper.results[0].winTrustHRESULT -eq '0x800B0109' -or $tamper.results[0].customChainBuilt){throw 'Tamper entered trust-only path'}
 $wrong=InvokeCase EMBEDDED_WRONG_CERT embedded $pe "$ReceiptDir/negative/wrong.cer" '' $false
 if($wrong.results[0].winTrustHRESULT -ne '0x800B0109' -or $wrong.results[0].signerDerMatch -or $wrong.results[0].customChainBuilt){throw 'Wrong certificate negative invalid'}
 $sys="$ReceiptDir/fixture/helios_kmd_render.sys"
 $catalog=InvokeCase CATALOG_ORIGINAL catalog $sys $cer $cat $true
 foreach($member in @('helios_umd.dll','helios_umd12.dll','helios_umd32.dll','helios_umd12_32.dll')){InvokeCase "CATALOG_$member" catalog "$ReceiptDir/fixture/$member" $cer $cat $true|Out-Null}
 InvokeCase CATALOG_MEMBER_TAMPER catalog "$ReceiptDir/negative/tampered-sys.sys" $cer $cat $false|Out-Null
 InvokeCase CATALOG_TAMPER catalog $sys $cer "$ReceiptDir/negative/tampered.cat" $false|Out-Null
 InvokeCase CATALOG_WRONG_MEMBER catalog $pe $cer $cat $false|Out-Null
 $wrongCat=InvokeCase CATALOG_WRONG_CERT catalog $sys "$ReceiptDir/negative/wrong.cer" $cat $false
 if($wrongCat.results[0].signerDerMatch -or $wrongCat.results[0].customChainBuilt){throw 'Wrong catalog certificate accepted'}
 $repeat=InvokeCase EMBEDDED_REPEAT embedded $pe $cer '' $true 100
 if($repeat.handlesAfter -gt $repeat.handlesAfterWarmup){throw 'Handle growth after warmup'}
 $repeat=InvokeCase CATALOG_REPEAT catalog $sys $cer $cat $true 100
 if($repeat.handlesAfter -gt $repeat.handlesAfterWarmup){throw 'Catalog handle growth after warmup'}
 [ordered]@{status='PASS_NATIVE_NEGATIVE_MATRIX_AND_CLOSE_CONTROLS';cases=$script:cases}|ConvertTo-Json -Depth 8|Set-Content "$ReceiptDir/memory-trust-control.json"
}finally{
 $after=Snapshot;$after|ConvertTo-Json -Depth 8|Set-Content "$ReceiptDir/stores-after.json"
 $same=($before|ConvertTo-Json -Depth 8 -Compress) -ceq ($after|ConvertTo-Json -Depth 8 -Compress)
 [ordered]@{status=$(if($same){'PASS'}else{'FAIL'});scope='CurrentUser_AND_LocalMachine_Root_TrustedPeople_TrustedPublisher_My_exact_fixture_thumbprint_and_rawdata';mutationAPIs='MEMORY_STORE_ONLY'}|ConvertTo-Json|Set-Content "$ReceiptDir/store-immutability.json"
 $c.Dispose();if(-not $same){throw 'Persistent stores changed'}
}
