param([Parameter(Mandatory)][string]$FrozenRoot,[Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$original=Get-Content "$FrozenRoot/ci/windows/Audit-CIPackage.ps1" -Raw
$line=($original -split "`r?`n"|Where-Object {$_ -match '^\$isDriver='})
if(@($line).Count -ne 1 -or $line -cne '$isDriver=$file.DirectoryName -eq $driver'){throw 'Frozen branch expression changed'}
$owned=Join-Path $env:RUNNER_TEMP ('helios-path-control-'+[guid]::NewGuid().ToString('N'))
$rows=@()
try {
New-Item -ItemType Directory -Force "$owned/extraction-verify/payload/driver"|Out-Null
[IO.File]::WriteAllBytes("$owned/extraction-verify/payload/driver/probe.sys",[byte[]]@(1))
$file=Get-Item "$owned/extraction-verify/payload/driver/probe.sys"
foreach($mode in @('HISTORICAL_MIXED','CANONICAL_BACKSLASH','NORMALIZED_MIXED')){
 $out=if($mode -eq 'CANONICAL_BACKSLASH'){$owned}else{($owned -replace '\\[^\\]+$','')+'/'+(Split-Path $owned -Leaf)}
 if($mode -eq 'NORMALIZED_MIXED'){$out=[IO.Path]::GetFullPath($out)}
 $extract="$out\extraction-verify"
 $driver="$extract\payload\driver"
 # Execute the actual frozen source expression, with real native FileInfo.
 Invoke-Expression $line
 $rows+=@{mode=$mode;outputDir=$out;driverString=$driver;fileDirectoryName=$file.DirectoryName;isDriver=$isDriver;driverVersionAndCatBranchReached=$isDriver;expectedStrongAuditBranch=$true}
}
$historical=$rows|Where-Object mode -eq 'HISTORICAL_MIXED'
$greens=@($rows|Where-Object mode -ne 'HISTORICAL_MIXED')
$status=if(-not $historical.isDriver -and @($greens|Where-Object {-not $_.isDriver}).Count -eq 0){'PASS_NATIVE_RED_HISTORICAL_GREEN_NORMALIZED'}else{'FAIL_CONTROL_EXPECTATION'}
[ordered]@{status=$status;classification='PATH_BRANCH_CONTROL_ONLY';auditSourceSha256=(Get-FileHash "$FrozenRoot/ci/windows/Audit-CIPackage.ps1").Hash;executedFrozenExpression=$line;cases=$rows;signatureVerification='NOT_RUN';packageQualification='NOT_RUN';durationCause='NOT_PROVEN'}|ConvertTo-Json -Depth 6|Set-Content "$ReceiptDir/path-branch-control.json"
if($status -ne 'PASS_NATIVE_RED_HISTORICAL_GREEN_NORMALIZED'){throw 'Native branch control did not establish RED and normalized GREEN'}
} finally {if(Test-Path $owned){Remove-Item $owned -Recurse -Force}}
