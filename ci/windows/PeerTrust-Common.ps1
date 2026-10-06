function PeerEvent($Operation,$Edge) {
 $process=Get-Process -Id $PID
 $bytes=[Text.Encoding]::UTF8.GetBytes(([ordered]@{utc=[DateTime]::UtcNow.ToString('o');operation=$Operation;edge=$Edge;pid=$PID;sessionId=$process.SessionId;mainWindowHandle=$process.MainWindowHandle.ToInt64();mainWindowTitle=$process.MainWindowTitle}|ConvertTo-Json -Compress)+"`n")
 $s=[IO.File]::Open($env:PEER_EVENTS,'Append','Write','Read');try{$s.Write($bytes,0,$bytes.Length);$s.Flush($true)}finally{$s.Dispose()}
}
function PeerFind($Certificate,$StoreName) {
 $s=[Security.Cryptography.X509Certificates.X509Store]::new($StoreName,'CurrentUser')
 try{$s.Open('ReadOnly');return @($s.Certificates.Find('FindByThumbprint',$Certificate.Thumbprint,$false))}finally{$s.Dispose()}
}
function PeerExact($Certificate,$Found) {
 if(@($Found).Count -ne 1 -or [Convert]::ToBase64String($Found[0].RawData) -cne [Convert]::ToBase64String($Certificate.RawData)){throw 'Exact DER identity required'}
}
function PeerOpen($Certificate) {
 $s=[Security.Cryptography.X509Certificates.X509Store]::new('TrustedPeople','CurrentUser');$owned=$false
 try{
  PeerEvent TRUSTEDPEOPLE_OPEN BEGIN;$s.Open('ReadWrite');PeerEvent TRUSTEDPEOPLE_OPEN END
  PeerEvent TRUSTEDPEOPLE_FIND_BEFORE BEGIN;$before=@($s.Certificates.Find('FindByThumbprint',$Certificate.Thumbprint,$false));PeerEvent TRUSTEDPEOPLE_FIND_BEFORE END
  $w=[Diagnostics.Stopwatch]::StartNew()
  if($before.Count -eq 0){$owned=$true;PeerEvent TRUSTEDPEOPLE_ADD BEGIN;$s.Add($Certificate);PeerEvent TRUSTEDPEOPLE_ADD END}else{PeerExact $Certificate $before}
  $duration=$w.Elapsed.TotalMilliseconds
  PeerEvent TRUSTEDPEOPLE_FIND_AFTER BEGIN;PeerExact $Certificate @($s.Certificates.Find('FindByThumbprint',$Certificate.Thumbprint,$false));PeerEvent TRUSTEDPEOPLE_FIND_AFTER END
  return [pscustomobject]@{Store=$s;Certificate=$Certificate;Owned=$owned;AddDurationMs=$duration}
 }catch{try{if($owned){$s.Remove($Certificate)}}finally{$s.Dispose()};throw}
}
function PeerClose($Context) {
 if($null -eq $Context){return}
 try{if($Context.Owned){PeerEvent TRUSTEDPEOPLE_REMOVE BEGIN;$Context.Store.Remove($Context.Certificate);PeerEvent TRUSTEDPEOPLE_REMOVE END;if(@(PeerFind $Context.Certificate TrustedPeople).Count){throw 'Cleanup failed'}}else{PeerExact $Context.Certificate @(PeerFind $Context.Certificate TrustedPeople)}}finally{$Context.Store.Dispose()}
}
function PeerVerify($Fixture,$Phase,$ExpectGreen,$SignTool,$ReceiptDir) {
 $rows=@()
 foreach($command in $Fixture.commands){
  $target=Join-Path "$ReceiptDir/fixture" $command.file
  if((Get-FileHash $target).Hash -ne $command.sha256){throw 'Signed bytes changed'}
  $args=@('verify','/pa','/v');if($command.catalog){$args+=@('/c',"$ReceiptDir/fixture/helios_kmd_render.cat")};$args+=@($target)
  & $SignTool @args 1>"$ReceiptDir/$Phase-$($command.name)-stdout.txt" 2>"$ReceiptDir/$Phase-$($command.name)-stderr.txt"
  $exit=$LASTEXITCODE
  $row=[ordered]@{name=$command.name;arguments=$args;exit=$exit;sha256=$command.sha256};$rows+=$row
  $rows|ConvertTo-Json -Depth 8|Set-Content "$ReceiptDir/$Phase-signatures.json"
  if($ExpectGreen -and $exit -ne 0){throw "SignTool GREEN refused: $($command.name)"}
  if(-not $ExpectGreen){
   $output=(Get-Content "$ReceiptDir/$Phase-$($command.name)-stdout.txt" -Raw)+(Get-Content "$ReceiptDir/$Phase-$($command.name)-stderr.txt" -Raw)
   if($exit -eq 0 -or $output -notmatch '0x800B0109|untrusted root|not trusted'){throw "Expected untrusted-chain RED absent: $($command.name)"}
  }
 }
}
