param([string]$ControlRoot,[string]$ReceiptDir,[string]$SignTool,[ValidateSet('CAUSAL','PREEXISTING','EXCEPTION')][string]$Mode)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. "$ControlRoot/ci/windows/PeerTrust-Common.ps1"
$f=Get-Content "$ReceiptDir/peer-trust-fixture.json" -Raw|ConvertFrom-Json
$c=[Security.Cryptography.X509Certificates.X509Certificate2]::new("$ReceiptDir/fixture/helios-ci-test.cer")
$context=$null;$seed=$null;$r=[ordered]@{mode=$Mode;status='FAIL';cleanup='NOT_PROVEN'}
try{
 if($Mode -eq 'PREEXISTING'){$seed=PeerOpen $c}
 $context=PeerOpen $c;$r.owned=$context.Owned;$r.addDurationMs=$context.AddDurationMs
 if($Mode -eq 'PREEXISTING' -and $context.Owned){throw 'Preexisting ownership violation'}
 if($Mode -eq 'EXCEPTION'){throw 'SYNTHETIC_AFTER_ADD'}
 PeerVerify $f "$Mode-GREEN" $true $SignTool $ReceiptDir
 PeerClose $context;$context=$null
 if($Mode -eq 'PREEXISTING'){PeerExact $c @(PeerFind $c TrustedPeople);$r.preexistingPreserved='PASS'}
 else{PeerVerify $f AFTER_REMOVE $false $SignTool $ReceiptDir}
 $r.status='PASS'
}catch{if($Mode -eq 'EXCEPTION' -and $_.Exception.Message -eq 'SYNTHETIC_AFTER_ADD'){$r.status='PASS_EXPECTED_EXCEPTION'}else{$r.error=$_.Exception.Message;throw}}
finally{
 try{PeerClose $context;PeerClose $seed;if(@(PeerFind $c TrustedPeople).Count){throw 'Final residue'};$r.cleanup='PASS'}finally{$r|ConvertTo-Json -Depth 8|Set-Content "$ReceiptDir/$Mode-result.json";$c.Dispose()}
}
