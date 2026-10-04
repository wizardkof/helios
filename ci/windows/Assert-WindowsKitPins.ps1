param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference='Stop'
$pins=Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw|ConvertFrom-Json
$inventory=@(foreach($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
 Get-ItemProperty $root -ErrorAction SilentlyContinue|Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -and ($_.DisplayName -match 'Windows Software Development Kit|Windows Driver Kit|Windows SDK Desktop (Headers|Libs)') }|Select-Object DisplayName,DisplayVersion,PSPath
})
$sdk=@($inventory|Where-Object {$_.DisplayName -match 'Windows Software Development Kit'}|ForEach-Object {$_.DisplayVersion}|Sort-Object -Unique)
$wdk=@($inventory|Where-Object {$_.DisplayName -match '^Windows Driver Kit - Windows 10\.0\.26100\.'}|ForEach-Object {$_.DisplayVersion}|Sort-Object -Unique)
$expectedSdk=@($pins.qualifiedObservedTools.windowsSdkVersion.Split(',')|Sort-Object -Unique)
$expectedWdk=@($pins.windowsKit.wdkVersion)
$componentFailures=@()
foreach($kind in @('SDK','WDK')) {
 $pattern=if($kind -eq 'SDK'){'^Windows SDK Desktop (Headers|Libs) (x64|x86)$'}else{'^Windows Driver Kit (Headers and Libs|Binaries)$'}
 $components=@($inventory|Where-Object {$_.DisplayName -match $pattern})
 $expected=if($kind -eq 'SDK'){'10.1.26100.7705'}else{$pins.windowsKit.wdkVersion}
 if(-not $components.Count -or @($components|Where-Object {$_.DisplayVersion -notin @($expected,($expected -replace '^10\.1\.','10.0.'))}).Count){$componentFailures+=$kind}
}

New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$receipt=@{requested=$pins.windowsKit;observed=$inventory;qualifiedSdk=$expectedSdk;qualifiedWdk=$expectedWdk;status='FAIL'}
if ($componentFailures.Count -or ($sdk -join ',') -ne ($expectedSdk -join ',') -or ($wdk -join ',') -ne ($expectedWdk -join ',')) {
 $receipt|ConvertTo-Json -Depth 8|Set-Content (Join-Path $ReceiptDir 'windows-kit.json') -Encoding UTF8
 throw 'SDK/WDK product inventory differs from the qualified compatibility model; directory versions do not establish QFE identity'
}
$receipt.status='PASS'
$receipt|ConvertTo-Json -Depth 8|Set-Content (Join-Path $ReceiptDir 'windows-kit.json') -Encoding UTF8
