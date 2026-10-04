param([Parameter(Mandatory)][string]$ReceiptDir,[string]$Producer='job-start')
$ErrorActionPreference='Stop'
$profile=Get-Content (Join-Path $PSScriptRoot 'ci-execution-profile.json') -Raw|ConvertFrom-Json
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$cpu=[Environment]::ProcessorCount
$os=Get-CimInstance Win32_OperatingSystem
$ramGiB=[double]$os.TotalVisibleMemorySize/1MB
$drive=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$freeGiB=[double]$drive.FreeSpace/1GB
$ok=$cpu -ge $profile.minimumResources.cpu -and $ramGiB -ge $profile.minimumResources.ramGiB -and $freeGiB -ge $profile.minimumResources.freeDiskGiB
$receipt=@{profile=$profile;observed=@{cpu=$cpu;ramGiB=$ramGiB;freeDiskGiB=$freeGiB;imageOS=$env:ImageOS;imageVersion=$env:ImageVersion;runnerOS=$env:RUNNER_OS};status=$(if($ok){'PASS'}else{'FAIL'});runId=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT;headSha=$env:GITHUB_SHA}
$receipt|ConvertTo-Json -Depth 8|Set-Content (Join-Path $ReceiptDir "$Producer-runner-resources.json") -Encoding UTF8
Write-Host ($receipt|ConvertTo-Json -Depth 8 -Compress)
if(-not $ok){throw 'CI resources below frozen execution profile; no pin/test/component fallback permitted'}
