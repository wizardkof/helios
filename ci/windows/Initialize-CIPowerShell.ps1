$ErrorActionPreference='Stop'
$pins=Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw|ConvertFrom-Json
$receipt=Join-Path $env:RUNNER_TEMP 'runner-qualification'
New-Item -ItemType Directory -Force $receipt|Out-Null
$target=$pins.powerShell7.installPath
$version=if(Test-Path $target){(& $target -NoProfile -Command '$PSVersionTable.PSVersion.ToString()') -join ''}else{''}
if($version -ne $pins.powerShell7.version){
 $msi=Join-Path $env:RUNNER_TEMP 'pinned-powershell.msi'
 Invoke-WebRequest $pins.powerShell7.installerUrl -OutFile $msi -UseBasicParsing
 if((Get-FileHash $msi).Hash.ToLowerInvariant() -ne $pins.powerShell7.installerSha256){throw 'PowerShell installer digest mismatch'}
 $process=Start-Process msiexec.exe -ArgumentList @('/i',$msi,'/qn','/norestart') -Wait -PassThru
 if($process.ExitCode -notin @(0,3010)){throw 'Pinned PowerShell install failed'}
}
$version=(& $target -NoProfile -Command '$PSVersionTable.PSVersion.ToString()') -join ''
if($LASTEXITCODE -ne 0 -or $version -ne $pins.powerShell7.version){throw 'Pinned PowerShell initialization failed'}
Split-Path $target -Parent|Out-File $env:GITHUB_PATH -Append -Encoding utf8
@{path=$target;version=$version;sha256=(Get-FileHash $target).Hash;status='PASS'}|ConvertTo-Json|Set-Content (Join-Path $receipt 'powershell-producer.json') -Encoding UTF8
