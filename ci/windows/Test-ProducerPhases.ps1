param([Parameter(Mandatory)][string]$ReceiptDir)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Producer-Phases.ps1')
$script:ProducerPhaseRoot=$ReceiptDir
$script:ProducerIdentities=[ordered]@{helios=$env:GITHUB_SHA;fixture='NO_PRODUCT_BUILD'}
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$phases=@('PHASE_CLONE_CLVK','PHASE_SUBMODULES','PHASE_CLSPV_PATCHES','PHASE_FETCH_LLVM','PHASE_CMAKE_CONFIGURE','PHASE_BUILD','PHASE_STAGE')
foreach($name in $phases){
 Start-ProducerPhase $name
 Invoke-OpenCLNative 'pwsh.exe' @('-NoProfile','-Command','exit 0')
 Complete-ProducerPhase 0
 $receipt=Get-Content (Join-Path $ReceiptDir "$name.json") -Raw|ConvertFrom-Json
 if($receipt.status -ne 'PASS' -or $receipt.exit -ne 0 -or -not $receipt.startUtc -or -not $receipt.endUtc -or -not $receipt.lastCommand){throw "Bad transition $name"}
}
Start-ProducerPhase 'PHASE_FAILURE_CONTROL'
$failed=$false
try{Invoke-OpenCLNative 'pwsh.exe' @('-NoProfile','-Command','exit 37')}catch{$failed=$true}
$receipt=Get-Content (Join-Path $ReceiptDir 'PHASE_FAILURE_CONTROL.json') -Raw|ConvertFrom-Json
if(-not $failed -or $receipt.status -ne 'FAIL' -or $receipt.exit -ne 37){throw 'Native phase failure was not preserved'}
foreach($file in @('Build-OpenCL.ps1','Invoke-OpenCLBudget.ps1','Producer-Phases.ps1')){
 $tokens=$null;$errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw "Parse errors in $file : $errors"}
}
@{status='PASS';phases=$phases;nativeFailureExit=37;product='NOT_RUN'}|ConvertTo-Json|Set-Content (Join-Path $ReceiptDir 'phases-control.json') -Encoding utf8
