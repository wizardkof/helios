param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($PSVersionTable.PSVersion.ToString() -ne '7.6.6' -or $PSVersionTable.PSEdition -ne 'Core' -or -not [Environment]::Is64BitProcess){throw 'Control requires PowerShell 7.6.6/Core x64'}
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$source=Join-Path $PSScriptRoot 'Assert-ComponentToolchain.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Checker parse failed'}
function Get-Assignment([string]$Name) {
    $nodes=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq ('$'+$Name)},$true))
    if($nodes.Count -ne 1){throw "Expected exactly one production assignment: $Name"}
    return [scriptblock]::Create($nodes[0].Extent.Text)
}
$priorityCode=Get-Assignment priority
$vulkanCode=Get-Assignment vulkanPass
$rows=[Collections.Generic.List[object]]::new()
$root=Join-Path $env:RUNNER_TEMP 'component-input-control'
$a=Join-Path $root 'a';$b=Join-Path $root 'b';$c=Join-Path $root 'c'
New-Item -ItemType Directory -Force $a,$b,$c|Out-Null
# An absent canonical SDK bin isolates the priority cases from runner state.
$pins=[pscustomobject]@{vulkanSdkVersion='helios-control-absent'}
$cases=@(
 @{name='zero';llvm='';ninja='';widl='';expected=@()},
 @{name='one';llvm=$a;ninja='';widl='';expected=@($a)},
 @{name='multiple';llvm=$a;ninja=(Join-Path $b 'ninja.exe');widl=(Join-Path $c 'widl.exe');expected=@($a,$b,$c)},
 @{name='duplicates';llvm=$a;ninja=(Join-Path $a 'ninja.exe');widl=(Join-Path $a 'widl.exe');expected=@($a)},
 @{name='nonexistent';llvm=(Join-Path $root 'absent');ninja='';widl='';expected=@()}
)
foreach($component in @('compatibility','loaders','package')){
 foreach($case in $cases){
  $env:HELIOS_LLVM_BIN=$case.llvm;$env:HELIOS_NINJA=$case.ninja;$env:HELIOS_WIDL=$case.widl
  $priority=$null;$errorText=$null;$count=$null;$passed=$false
  try{. $priorityCode;$count=$priority.Count;$passed=$priority -is [array] -and $count -eq $case.expected.Count -and (@($priority) -join '|') -ceq ($case.expected -join '|')}catch{$errorText=$_.Exception.Message}
  $rows.Add([pscustomobject]@{family='priority';component=$component;case=$case.name;status=if($passed){'PASS'}else{'FAIL'};count=$count;error=$errorText})
 }
}
$pins.vulkanSdkVersion='1.4.350.0'
$sdk=Join-Path (Join-Path $root 'VulkanSDK') $pins.vulkanSdkVersion
$wrong=Join-Path (Join-Path $root 'VulkanSDK') '1.4.350.0-extra'
foreach($dir in @($sdk,$wrong)){New-Item -ItemType Directory -Force (Join-Path $dir 'Include/vulkan'),(Join-Path $dir 'Lib')|Out-Null;Set-Content (Join-Path $dir 'Include/vulkan/vulkan.h') 'fixture';Set-Content (Join-Path $dir 'Lib/vulkan-1.lib') 'fixture'}
$vulkanCases=@(
 @{name='backslashes';path=$sdk.Replace('/','\');expected=$true},
 @{name='slashes';path=$sdk.Replace('\','/');expected=$true},
 @{name='trailing-slash';path=($sdk+'/');expected=$true},
 @{name='trailing-backslash';path=($sdk+'\');expected=$true},
 @{name='wrong-leaf-substring';path=$wrong;expected=$false},
 @{name='missing-header';path=$sdk;expected=$false;missing='Include/vulkan/vulkan.h'},
 @{name='missing-library';path=$sdk;expected=$false;missing='Lib/vulkan-1.lib'}
)
foreach($case in $vulkanCases){
 $missing=if($case.ContainsKey('missing')){Join-Path $sdk $case.missing}else{$null}
 if($missing){Move-Item $missing ($missing+'.saved')}
 $vulkanRoot=[string]$case.path;$vulkanPass=$false;$errorText=$null;$passed=$false
 try{. $vulkanCode;$passed=[bool]$vulkanPass -eq $case.expected}catch{$errorText=$_.Exception.Message}finally{if($missing){Move-Item ($missing+'.saved') $missing}}
 $rows.Add([pscustomobject]@{family='vulkan';case=$case.name;path=$case.path;expected=$case.expected;observed=[bool]$vulkanPass;status=if($passed){'PASS'}else{'FAIL'};error=$errorText})
}
$failures=@($rows|Where-Object status -eq FAIL)
$receipt=[ordered]@{schemaVersion=1;status=if($failures.Count){'FAIL'}else{'PASS'};powerShell=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;is64Bit=[Environment]::Is64BitProcess;source=$source;sourceSha256=(Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant();productionAssignments=@($priorityCode.ToString(),$vulkanCode.ToString());cases=@($rows.ToArray())}
$receipt|ConvertTo-Json -Depth 12|Set-Content (Join-Path $ReceiptDir 'component-inputs.json') -Encoding utf8
$receipt|ConvertTo-Json -Depth 12|Write-Host
if($failures.Count){throw "COMPONENT_INPUT_CONTROLS=FAIL ($($failures.Count) cases)"}
Write-Host 'COMPONENT_INPUT_CONTROLS=PASS'
