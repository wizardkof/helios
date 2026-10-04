param([Parameter(Mandatory)][ValidateSet('driver','opencl','loaders','compatibility','package')][string]$Component,[Parameter(Mandatory)][string]$ReceiptDir,[ValidateSet('pre','post')][string]$Phase='pre')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
& (Join-Path $PSScriptRoot 'Observe-NinjaResolution.ps1') -Phase "immediately-before-component-$Component-vs-import" -ReceiptDir $ReceiptDir
Import-VisualStudioEnvironment
& (Join-Path $PSScriptRoot 'Observe-NinjaResolution.ps1') -Phase "immediately-after-component-$Component-vs-import" -ReceiptDir $ReceiptDir
$pins=Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw|ConvertFrom-Json
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRows=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json)|ConvertFrom-Json
$vs=([string]$vsRows[0].catalog.productDisplayVersion -split ' ')[0]
if($LASTEXITCODE -ne 0 -or $vs -ne $pins.visualStudio.bootstrapVersion){throw "Visual Studio pin mismatch: $vs"}
if($env:VCToolsVersion.TrimEnd('\') -ne $pins.visualStudio.msvcVersion){throw 'MSVC pin mismatch'}
& (Join-Path $PSScriptRoot 'Assert-WindowsKitPins.ps1') -ReceiptDir $ReceiptDir
if ($PSVersionTable.PSVersion.ToString() -ne $pins.powerShell7.version){throw 'PowerShell 7 producer pin mismatch'}
$checks=@(@('python','--version',('Python '+$pins.pythonVersion)),@('git','--version',('git version '+$pins.gitVersion)))
if($Component -in 'opencl','loaders') {
 $cmakeProperty=$pins.PSObject.Properties['cmakeVersion']
 if(-not $cmakeProperty -or -not $cmakeProperty.Value){throw 'CMAKE_PIN=NOT_PROVEN: qualified CMake version must be supplied before production'}
 $checks+=,@('cmake','--version',('cmake version '+$cmakeProperty.Value))
}
if($Component -eq 'opencl'){$checks+=,@('ninja','--version',$pins.ninjaVersion);$checks+=,@('sccache','--version',('sccache '+$pins.sccacheVersion))}
if($Component -in 'driver','package') {
 $checks+=,@('rustup','--version',('rustup '+$pins.rust.rustupVersion))
 $checks+=,@('rustc','--version',$pins.qualifiedObservedTools.rustc)
 $checks+=,@('cargo','--version',$pins.qualifiedObservedTools.cargo)
 $checks+=,@('clang-cl','--version',('clang version '+$pins.llvmVersion))
}
$tools=@{}
foreach($name in @('cl.exe','link.exe','dumpbin.exe')) {
 $path=(Get-Command $name -ErrorAction Stop).Source
 $tools[$name]=@{path=$path;fileVersion=(Get-Item $path).VersionInfo.FileVersion;sha256=(Get-FileHash $path).Hash}
}
$rc=Find-WindowsKitTool 'rc.exe'
$tools['rc.exe']=@{path=$rc;fileVersion=(Get-Item $rc).VersionInfo.FileVersion;sha256=(Get-FileHash $rc).Hash}
foreach($check in $checks) {
 $cmd=(Get-Command $check[0] -ErrorAction Stop).Source
 $version=(& $cmd $check[1]) -join "`n"
 $exitCode=$LASTEXITCODE
 $comparison=if($check[0] -eq 'git'){$version -replace '\.windows\.','.'}else{$version}
 if($exitCode -ne 0 -or -not [regex]::IsMatch($comparison,[regex]::Escape($check[2])+'(?![0-9.])')){throw "Producer pin mismatch: $($check[0]) expected=$($check[2]) observed=$version"}
 $tools[$check[0]]=@{path=$cmd;version=$version;sha256=(Get-FileHash $cmd).Hash}
}
if($Component -eq 'opencl' -and (Split-Path $env:VULKAN_SDK -Leaf) -ne $pins.vulkanSdkVersion){throw 'Vulkan SDK pin mismatch'}
@{component=$Component;visualStudio=$vs;msvc=$env:VCToolsVersion;tools=$tools;status='PASS'}|ConvertTo-Json -Depth 7|Set-Content (Join-Path $ReceiptDir "$Phase-producer-tools.json") -Encoding UTF8
