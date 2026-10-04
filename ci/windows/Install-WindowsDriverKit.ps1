param([string]$ReceiptDir="$env:RUNNER_TEMP/component-qualification")
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$kit=(Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw|ConvertFrom-Json).windowsKit
$checker=Join-Path $PSScriptRoot 'Assert-WindowsKitPins.ps1'
try {& $checker -ReceiptDir $ReceiptDir -Phase before;$qualified=$true}catch {$qualified=$false;Write-Host "Initial selected kit not qualified: $($_.Exception.Message)"}
Copy-Item (Join-Path $ReceiptDir 'windows-kit.json') (Join-Path $ReceiptDir 'before-windows-kit.json')
if($qualified){Write-Host 'KIT_BOOTSTRAP=REUSE_QUALIFIED';return}
$acquire=Join-Path $ReceiptDir 'acquisition';New-Item -ItemType Directory -Force $acquire|Out-Null
try {
 # Burn installers own supported upgrade/downgrade behavior. Never silently
 # accept an overlapping revision or manually remove shared Include/Lib files.
 foreach($kind in $kit.installOrder) {
  $a=$kit.acquisition.$kind;$exe=Join-Path $acquire "$kind-setup.exe"
  Invoke-WebRequest -Uri $a.url -OutFile $exe
  if((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower() -ne $a.sha256){throw "Installer hash mismatch: $kind"}
  $sig=Get-AuthenticodeSignature $exe
  if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation'){throw "Installer signature mismatch: $kind"}
  $log=Join-Path $acquire "$kind-install.log"
  $proc=Start-Process -FilePath $exe -ArgumentList @('/quiet','/norestart','/log',('"'+$log+'"')) -Wait -PassThru
  @{kind=$kind;requested=$a;exitCode=$proc.ExitCode;signature=$sig.Status.ToString()}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $acquire "$kind-install.json") -Encoding UTF8
  if($proc.ExitCode -notin @(0,3010)){throw "Pinned $kind installation refused: $($proc.ExitCode); no latest or pin change"}
 }
 & $checker -ReceiptDir $ReceiptDir -Phase after
} catch {
 $primary=$_.Exception.Message
 try {& $checker -ReceiptDir $ReceiptDir -Phase after}catch {Write-Host 'Final kit gate refused; structured receipt retained'}
 @{status='FAIL';reason=$primary;requested=$kit}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $ReceiptDir 'bootstrap-failure.json') -Encoding UTF8
 Write-Host "KIT_BOOTSTRAP=FAIL reason=$primary"
 throw $primary
}
