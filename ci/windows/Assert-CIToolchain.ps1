param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Import-VisualStudioEnvironment
& (Join-Path $PSScriptRoot 'Assert-WindowsKitPins.ps1') -ReceiptDir $ReceiptDir
$tools=[ordered]@{}
foreach($test in @(
 @('python','--version','Python 3.12.10'),
 @('meson','--version','1.11.2'),
 @('ninja','--version','1.13.2'),
 @('cargo-make','--version','cargo-make 0.37.24'),
 @('clang-cl','--version','clang version 22.1.8'),
 @('rustc','--version','rustc 1.99.0-nightly (daf2e5e18 2026-07-13)'),
 @('cargo','--version','cargo 1.99.0-nightly (59800466c 2026-07-07)'),
 @('widl','-V','11.12')
)){
 $cmd=(Get-Command $test[0]).Source
 $value=(& $cmd $test[1]) -join "`n"
 if($LASTEXITCODE -ne 0 -or -not ([regex]::IsMatch($value,[regex]::Escape($test[2])+'(?![0-9.])'))){throw "Toolchain pin mismatch: $($test[0]) expected=$($test[2]) observed=$value"}
 $tools[$test[0]]=@{path=$cmd;version=$value;sha256=(Get-FileHash $cmd).Hash}
}
if($env:WindowsSDKVersion.TrimEnd('\') -ne '10.0.26100.0'){throw 'SDK selection mismatch'}
if($env:VCToolsVersion.TrimEnd('\') -ne '14.44.35207'){throw 'MSVC pin mismatch'}
if(-not $env:VULKAN_SDK -or (Split-Path $env:VULKAN_SDK -Leaf) -ne '1.4.350.0'){throw 'Vulkan SDK pin mismatch'}
$kit=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
foreach($f in @('Include\10.0.26100.0\km\ntddk.h','Include\10.0.26100.0\um\windows.h','bin\10.0.26100.0\x64\Inf2Cat.exe','bin\10.0.26100.0\x64\stampinf.exe','bin\10.0.26100.0\x64\signtool.exe')){if(-not(Test-Path (Join-Path $kit $f))){throw "Pinned kit component missing: $f"}}
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
@{tools=$tools;msvc=$env:VCToolsVersion;sdk=$env:WindowsSDKVersion;wdkInclude=(Join-Path $kit 'Include\10.0.26100.0\km');vulkanSdk=$env:VULKAN_SDK;status='PASS'}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $ReceiptDir 'toolchain.json') -Encoding UTF8
