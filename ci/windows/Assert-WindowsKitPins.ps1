param([Parameter(Mandatory)][string]$ReceiptDir,[string]$Phase='current')
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$pinsPath=Join-Path $PSScriptRoot 'ci-toolchain-pins.json'
$kit=(Get-Content $pinsPath -Raw|ConvertFrom-Json).windowsKit
$root=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$inventory=@();$queries=@();$files=@()
foreach($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
 try {
  foreach($item in Get-ChildItem -LiteralPath $key -ErrorAction Stop) {
   $v=Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction Stop
   if($v.PSObject.Properties['DisplayName'] -and $v.DisplayName -match '(SDK|Kit|CRT|Driver Framework)') {
    $inventory+=@{DisplayName=$v.DisplayName;DisplayVersion=$v.DisplayVersion;productCode=$item.PSChildName;registryPath=$item.Name;uninstall=$(if($v.PSObject.Properties['QuietUninstallString']){$v.QuietUninstallString}elseif($v.PSObject.Properties['UninstallString']){$v.UninstallString}else{''})}
   }
  }
  $queries+=@{path=$key;status='PASS'}
 } catch {$queries+=@{path=$key;status='FAIL';reason=$_.Exception.Message}}
}
foreach($f in $kit.selectedFiles) {
 $path=Join-Path $root $f.path
 if(Test-Path -LiteralPath $path -PathType Leaf){$item=Get-Item -LiteralPath $path;$files+=@{path=$f.path;absolutePath=$path;size=$item.Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower();fileVersion=$item.VersionInfo.FileVersion}}
}
. (Join-Path $PSScriptRoot 'Get-WindowsKitOwnership.ps1')
Get-WindowsKitOwnership $kit $inventory $files
$observation=@{queryStatus=$(if(@($queries|Where-Object {$_.status -ne 'PASS'}).Count){'FAIL'}else{'PASS'});queries=$queries;family=$(if(Test-Path (Join-Path $root "Include/$($kit.family)")){$kit.family}else{'UNKNOWN'});inventory=$inventory;files=$files;root=$root}
$observationPath=Join-Path $ReceiptDir "$Phase-windows-kit-observation.json"
$observation|ConvertTo-Json -Depth 10|Set-Content $observationPath -Encoding UTF8
# The real portable checker writes the full refusal before returning nonzero.
python (Join-Path $PSScriptRoot 'windows_kit.py') --pins $pinsPath --observation $observationPath --receipt (Join-Path $ReceiptDir 'windows-kit.json')
if($LASTEXITCODE -ne 0){throw "SDK/WDK selected-component gate refused; receipt=$ReceiptDir/windows-kit.json phase=$Phase"}
