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
 $before=Get-Content (Join-Path $ReceiptDir 'before-windows-kit.json') -Raw|ConvertFrom-Json
 foreach($bundle in @($before.observed.inventory|Where-Object {$_.DisplayName -match '^Windows Driver Kit - Windows 10\.0\.26100\.' -and $_.DisplayVersion -ne $kit.wdkVersion})) {
  if($bundle.uninstall -notmatch '^"([^"\r\n]+\\wdksetup\.exe)" /uninstall'){throw 'Unsupported WDK uninstall command; no manual shared-file cleanup'}
  $uninstaller=$Matches[1];$signature=Get-AuthenticodeSignature $uninstaller
  if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation'){throw 'Installed WDK uninstaller signature refused'}
  $remove=Start-Process $uninstaller -ArgumentList @('/uninstall','/quiet','/norestart','/log',('"'+(Join-Path $acquire 'wdk-remove.log')+'"')) -Wait -PassThru
  @{bundle=$bundle;exitCode=$remove.ExitCode;status='OBSERVED'}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $acquire 'wdk-remove.json') -Encoding UTF8
  if($remove.ExitCode -notin @(0,3010)){throw 'Overlapping WDK removal failed'}
 }
 # Burn installers own supported upgrade/downgrade behavior. Never silently
 # accept an overlapping revision or manually remove shared Include/Lib files.
 foreach($kind in $kit.installOrder) {
  $a=$kit.acquisition.$kind;$exe=Join-Path $acquire "$kind-setup.exe"
  Invoke-WebRequest -Uri $a.url -OutFile $exe
  if((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower() -ne $a.sha256){throw "Installer hash mismatch: $kind"}
  $sig=Get-AuthenticodeSignature $exe
  if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation'){throw "Installer signature mismatch: $kind"}
  if($kind -eq 'sdk') {
   try {& $checker -ReceiptDir $ReceiptDir -Phase intermediate}catch {Write-Host 'Intermediate kit receipt retained'}
   $current=Get-Content (Join-Path $ReceiptDir 'windows-kit.json') -Raw|ConvertFrom-Json
   $sdkFailures=@($current.failures|Where-Object {$_.expected.kind -eq 'sdk'})
   if(-not $sdkFailures.Count){Write-Host 'SDK_BOOTSTRAP=REUSE_SELECTED_COMPONENTS';continue}
  }
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
