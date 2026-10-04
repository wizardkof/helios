# Verify selected bytes against the installed exact MSI's File/MsiFileHash tables.
# Directory names and the global uninstall inventory alone cannot prove QFE.
function Get-WindowsKitOwnership($Kit,$Inventory,$Files) {
 foreach($file in $Files){$file.ownership='UNKNOWN';$file.ownershipReason='No selected MSI owns this exact input'}
 try {$installer=New-Object -ComObject WindowsInstaller.Installer}catch {foreach($file in $Files){$file.ownershipReason=$_.Exception.Message};return}
 foreach($component in $Kit.components) {
  if(-not @($Inventory|Where-Object {$_.productCode -eq $component.productCode -and $_.DisplayVersion -eq $component.version}).Count){continue}
  try {
   $cache=$installer.ProductInfo($component.productCode,'LocalPackage')
   $db=$installer.OpenDatabase($cache,0)
   $view=$db.OpenView('SELECT `File`.`File`, `File`.`Component_`, `File`.`FileName`, `File`.`FileSize`, `File`.`Version`, `Component`.`ComponentId` FROM `File`, `Component` WHERE `File`.`Component_` = `Component`.`Component`')
   $view.Execute()
   while($record=$view.Fetch()) {
    $key=$installer.ComponentPath($component.productCode,$record.StringData(6))
    if(-not $key -or -not (Test-Path -LiteralPath $key -PathType Leaf)){continue}
    $name=($record.StringData(3) -split '\|')[-1]
    $path=Join-Path (Split-Path $key -Parent) $name
    foreach($file in @($Files|Where-Object {$_.absolutePath -eq $path})) {
     $file.ownerProductCode=$component.productCode;$file.ownerMsi=$cache
     $version=$record.StringData(5);$expectedSize=$record.IntegerData(4)
     if($file.size -ne $expectedSize){$file.ownership='FAIL';$file.ownershipReason='MSI FileSize mismatch';continue}
     if($version -match '^\d+\.\d+\.\d+\.\d+$') {
      $vi=(Get-Item -LiteralPath $path).VersionInfo
      $actual='{0}.{1}.{2}.{3}' -f $vi.FileMajorPart,$vi.FileMinorPart,$vi.FileBuildPart,$vi.FilePrivatePart
      if($actual -eq $version){$file.ownership='PASS';$file.ownershipReason='Exact MSI file size and version'}else{$file.ownership='FAIL';$file.ownershipReason="MSI FileVersion mismatch expected=$version observed=$actual"}
     } else {
      $id=$record.StringData(1)
      $hashView=$db.OpenView("SELECT ``HashPart1``, ``HashPart2``, ``HashPart3``, ``HashPart4`` FROM ``MsiFileHash`` WHERE ``File_`` = '$id'")
      $hashView.Execute();$hash=$hashView.Fetch()
      if(-not $hash){$file.ownership='UNKNOWN';$file.ownershipReason='MSI has no FileHash for unversioned selected input';continue}
      $expectedBytes=@();foreach($i in 1..4){$expectedBytes += [BitConverter]::GetBytes([int]$hash.IntegerData($i))}
      $expected=([BitConverter]::ToString([byte[]]$expectedBytes)).Replace('-','')
      if((Get-FileHash -LiteralPath $path -Algorithm MD5).Hash -eq $expected){$file.ownership='PASS';$file.ownershipReason='Exact MSI MsiFileHash'}else{$file.ownership='FAIL';$file.ownershipReason='MSI MsiFileHash mismatch'}
      $hashView.Close()
     }
    }
   }
   $view.Close()
  } catch {foreach($file in $Files|Where-Object {$_.ownership -ne 'PASS'}){$file.ownershipReason="MSI ownership query failed: $($_.Exception.Message)"}}
 }
}
