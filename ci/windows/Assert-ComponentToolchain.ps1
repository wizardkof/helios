param([Parameter(Mandatory)][ValidateSet('driver','opencl','loaders','compatibility','package')][string]$Component,[Parameter(Mandatory)][string]$ReceiptDir,[ValidateSet('pre','post')][string]$Phase='pre')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts.psm1') -Force
$pins=Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw|ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $ReceiptDir|Out-Null
$checks=[Collections.Generic.List[object]]::new();$blocked=[Collections.Generic.List[object]]::new()
$vs=$null;$vc=$null
$observer=Join-Path $PSScriptRoot 'Observe-NinjaResolution.ps1'
try{& $observer -Phase "immediately-before-component-$Component-vs-import" -ReceiptDir $ReceiptDir}catch{$blocked.Add([pscustomobject]@{name='ninja-observer-pre-vs';reason=$_.Exception.Message})}
try{Import-VisualStudioEnvironment -Architecture x64}catch{$blocked.Add([pscustomobject]@{name='visual-studio-environment-x64';reason=$_.Exception.Message})}
try{& $observer -Phase "immediately-after-component-$Component-vs-import" -ReceiptDir $ReceiptDir}catch{$blocked.Add([pscustomobject]@{name='ninja-observer-post-vs';reason=$_.Exception.Message})}

function Add-ComponentValueCheck([string]$Name,[string]$Expected,[string]$Observed,[bool]$Pass,[string]$Path=$null) {
    $row=[ordered]@{requestedName=$Name;phase=$Phase;commandType='Environment';path=$Path;resolvedCommandType='Environment';resolvedPath=$Path;expectedVersion=$Expected;observedVersion=$Observed;exitCode=0;size=$null;sha256=$null;status=if($Pass){'PASS'}else{'FAIL'};error=if($Pass){$null}else{'ENVIRONMENT_PIN_MISMATCH'};resolutionCandidates=@()}
    if($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)){try{$item=Get-Item -LiteralPath $Path;$row.size=[long]$item.Length;$row.sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}catch{$row.status='FAIL';$row.error='FILE_READ: '+$_.Exception.Message}}
    $checks.Add([pscustomobject]$row)
}
function Add-FileIdentityCheck([string]$Name,[string]$ExpectedToolset,[string]$ExpectedRoot=$null) {
    $rows=@(Get-Command -Name $Name -All -ErrorAction SilentlyContinue)
    $command=$rows|Where-Object {$_.CommandType -eq 'Application'}|Select-Object -First 1
    $path=if($command){[string]$command.Path}else{$null}
    $row=[ordered]@{requestedName=$Name;phase=$Phase;commandType=if($command){[string]$command.CommandType}else{$null};path=$path;resolvedCommandType=if($command){[string]$command.CommandType}else{$null};resolvedPath=$path;expectedVersion=$ExpectedToolset;observedVersion=$null;exitCode=$null;size=$null;sha256=$null;status='NOT_OBSERVED';error=$null;resolutionCandidates=@($rows|ForEach-Object {[ordered]@{commandType=[string]$_.CommandType;path=if($_.CommandType -eq 'Application'){[string]$_.Path}else{[string]$_.Source}}})}
    if(-not $path){$row.error='RESOLUTION: command not found'}else{try{$item=Get-Item -LiteralPath $path -ErrorAction Stop;$row.size=[long]$item.Length;$row.sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();$row.observedVersion=[string]$item.VersionInfo.FileVersion
        $pathMatches=$path -match [regex]::Escape($ExpectedToolset)
        if($ExpectedRoot){$pathMatches=$pathMatches -and $path.StartsWith($ExpectedRoot,[StringComparison]::OrdinalIgnoreCase)}
        $row.status=if($pathMatches -and $row.size -gt 0 -and $row.sha256){'PASS'}else{'FAIL'}
        if($row.status -eq 'FAIL'){$row.error='SELECTED_TOOL_PATH_OR_FILE_IDENTITY_MISMATCH'}
    }catch{$row.status='FAIL';$row.error='FILE_READ: '+$_.Exception.Message}}
    $checks.Add([pscustomobject]$row)
}

# Visual Studio and Windows kit are independent of the subsequent command checks.
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
try{
    $global:LASTEXITCODE=$null
    $vsOutput=@(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json 2>&1|ForEach-Object {$_.ToString()})
    $vsExit=if($null -eq $LASTEXITCODE){0}else{[int]$LASTEXITCODE}
    $vsRows=($vsOutput -join "`n")|ConvertFrom-Json
    $vs=([string]$vsRows[0].catalog.productDisplayVersion -split ' ')[0]
    $vc=$vsRows[0].installationPath
    $vsHash=(Get-FileHash -LiteralPath $vswhere -Algorithm SHA256).Hash.ToLowerInvariant();$vsSize=(Get-Item -LiteralPath $vswhere).Length
    $checks.Add([pscustomobject][ordered]@{requestedName='vswhere.exe';phase=$Phase;commandType='ExplicitPath';path=$vswhere;resolvedCommandType='ExplicitPath';resolvedPath=$vswhere;expectedVersion=$pins.visualStudio.bootstrapVersion;observedVersion=$vs;exitCode=$vsExit;size=$vsSize;sha256=$vsHash;status=if($vsExit -eq 0 -and $vs -ceq $pins.visualStudio.bootstrapVersion){'PASS'}else{'FAIL'};error=if($vsExit -eq 0 -and $vs -ceq $pins.visualStudio.bootstrapVersion){$null}else{'VISUAL_STUDIO_VERSION_MISMATCH'};resolutionCandidates=@()})
}catch{$blocked.Add([pscustomobject]@{name='visual-studio-version';reason=$_.Exception.Message})}
$observedMsvc=([string]$env:VCToolsVersion).TrimEnd('\')
Add-ComponentValueCheck 'VCToolsVersion' $pins.visualStudio.msvcVersion $observedMsvc ($observedMsvc -ceq $pins.visualStudio.msvcVersion)
try{& (Join-Path $PSScriptRoot 'Assert-WindowsKitPins.ps1') -ReceiptDir $ReceiptDir}catch{$blocked.Add([pscustomobject]@{name='windows-kit-pins';reason=$_.Exception.Message})}

$checksToRun=@(@{name='python';args=@('--version');expected=('Python '+$pins.pythonVersion);pattern=('^Python '+[regex]::Escape($pins.pythonVersion)+'$')},@{name='git';args=@('--version');expected=('git version '+$pins.gitVersion);pattern=('^git version '+[regex]::Escape(($pins.gitVersion -replace '\.\d+$',''))+'(?:\.windows\.\d+)?$')})
if($Component -in 'opencl','loaders'){
    $checksToRun+=,@{name='cmake';args=@('--version');expected=('cmake version '+$pins.cmakeVersion);pattern=('(?m)^cmake version '+[regex]::Escape($pins.cmakeVersion)+'$')}
}
if($Component -eq 'opencl'){
    $checksToRun+=,@{name='ninja.exe';args=@('--version');expected=$pins.ninjaUpstream.executableVersion;pattern=('^'+[regex]::Escape($pins.ninjaUpstream.executableVersion)+'$')}
    $checksToRun+=,@{name='sccache';args=@('--version');expected=('sccache '+$pins.sccacheVersion);pattern=('^sccache '+[regex]::Escape($pins.sccacheVersion)+'$')}
}
if($Component -eq 'driver'){
    $checksToRun+=,@{name='rustup';args=@('--version');expected=('rustup '+$pins.rust.rustupVersion);pattern=('^rustup '+[regex]::Escape($pins.rust.rustupVersion)+'(?:\s|$)')}
    $checksToRun+=,@{name='rustc';args=@('--version');expected=$pins.qualifiedObservedTools.rustc;pattern=('^'+[regex]::Escape($pins.qualifiedObservedTools.rustc)+'$')}
    $checksToRun+=,@{name='cargo';args=@('--version');expected=$pins.qualifiedObservedTools.cargo;pattern=('^'+[regex]::Escape($pins.qualifiedObservedTools.cargo)+'$')}
    $checksToRun+=,@{name='clang-cl';args=@('--version');expected=('clang version '+$pins.llvmVersion);pattern=('(?m)^clang version '+[regex]::Escape($pins.llvmVersion)+'(?:\s|$)')}
}
foreach($check in $checksToRun){
    $options=@{Name=$check.name;Arguments=$check.args;ExpectedVersion=$check.expected;VersionPattern=$check.pattern;Phase=$Phase}
    if($check.name -eq 'ninja.exe' -and $env:HELIOS_NINJA){$options.ExecutablePath=[string]$env:HELIOS_NINJA;$options.ExpectedResolvedPath=[string]$env:HELIOS_NINJA}
    $checks.Add((Invoke-CIToolCheck @options))
}

foreach($name in @('cl.exe','link.exe','dumpbin.exe')){Add-FileIdentityCheck $name $pins.visualStudio.msvcVersion $vc}
$rcPath=$null
try{$rcPath=Find-WindowsKitTool 'rc.exe'}catch{$blocked.Add([pscustomobject]@{name='rc.exe-selected-kit';reason=$_.Exception.Message})}
if($rcPath){
    try{$item=Get-Item -LiteralPath $rcPath;$checks.Add([pscustomobject][ordered]@{requestedName='rc.exe';phase=$Phase;commandType='ExplicitPath';path=$rcPath;resolvedCommandType='ExplicitPath';resolvedPath=$rcPath;expectedVersion=$pins.windowsKit.family;observedVersion=$item.VersionInfo.FileVersion;exitCode=0;size=[long]$item.Length;sha256=(Get-FileHash -LiteralPath $rcPath -Algorithm SHA256).Hash.ToLowerInvariant();status='PASS';error=$null;resolutionCandidates=@()})}catch{$blocked.Add([pscustomobject]@{name='rc.exe-file-identity';reason=$_.Exception.Message})}
}
$psPath=[string]$pins.powerShell7.installPath
$checks.Add((Invoke-CIToolCheck -Name 'pwsh.exe' -Arguments @('-NoProfile','-Command','$PSVersionTable.PSVersion.ToString()') -ExpectedVersion $pins.powerShell7.version -VersionPattern ('^'+[regex]::Escape($pins.powerShell7.version)+'$') -Phase $Phase -ExpectedResolvedPath $psPath))
if($Component -eq 'opencl'){
    $vulkanRoot=[string]$env:VULKAN_SDK;$vulkanPass=$vulkanRoot -and (Split-Path $vulkanRoot -Leaf) -ceq $pins.vulkanSdkVersion -and (Test-Path -LiteralPath (Join-Path $vulkanRoot 'Include/vulkan/vulkan.h') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $vulkanRoot 'Lib/vulkan-1.lib') -PathType Leaf)
    Add-ComponentValueCheck 'VULKAN_SDK' $pins.vulkanSdkVersion $vulkanRoot ([bool]$vulkanPass) $vulkanRoot
}
if($Component -in 'driver','package'){
    try{. (Join-Path $PSScriptRoot 'CI-Qualification.ps1');Write-CIRustScriptContract $ReceiptDir $Phase}catch{$blocked.Add([pscustomobject]@{name='rust-script-host-private';reason=$_.Exception.Message})}
}
$receipt=New-CIToolReceipt -Name "$Component-producer-toolchain-$Phase" -Checks @($checks.ToArray()) -Blocked @($blocked.ToArray()) -Context @{component=$Component;phase=$Phase;visualStudio=$vs;msvc=$observedMsvc;vulkanSdk=$env:VULKAN_SDK;selectedNinja=$env:HELIOS_NINJA}
Write-CIToolReceipt -Path (Join-Path $ReceiptDir "$Phase-producer-tools.json") -Receipt $receipt
Write-Host (ConvertTo-Json -InputObject $receipt -Depth 16)
Assert-CIToolReceiptPass -Receipt $receipt
