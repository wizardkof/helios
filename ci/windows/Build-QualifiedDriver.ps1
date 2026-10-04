param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$OutputDir,[ValidateSet('Release','Debug')][string]$Configuration='Release',[string]$BuildRoot='C:\hb\driver')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CI-Qualification.ps1')
Assert-CIBackend
$certDir=Join-Path $BuildRoot "trust-$Configuration"
& (Join-Path $RepoRoot 'tools\sign-helios-development.ps1') -OutputDirectory $certDir
$cer=Join-Path $certDir 'helios-dev-test.cer'
$cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($cer)
$store="Cert:\LocalMachine\Root\$($cert.Thumbprint)"
$owned=-not(Test-Path $store)
try {
 if($owned){Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root|Out-Null}
 & (Join-Path $PSScriptRoot 'Build-Driver.ps1') -RepoRoot $RepoRoot -OutputDir $OutputDir -Configuration $Configuration -BuildRoot $BuildRoot
 $sign=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
 foreach($n in @('helios_kmd_render.sys','helios_kmd_render.cat')){& $sign verify /pa /v (Join-Path $OutputDir $n);if($LASTEXITCODE -ne 0){throw "Signature validation failed $n"}}
 foreach($n in @('helios_kmd_render.sys','helios_umd.dll','helios_umd32.dll','helios_umd12.dll','helios_umd12_32.dll')){& $sign verify /pa /v /c (Join-Path $OutputDir 'helios_kmd_render.cat') (Join-Path $OutputDir $n);if($LASTEXITCODE -ne 0){throw "Catalog member validation failed $n"}}
 Write-CIHashIndex $OutputDir
 & python (Join-Path $PSScriptRoot 'ci_artifact.py') seal --directory $OutputDir --source-root $RepoRoot --component driver --configuration $Configuration --architecture x64+x86
 if($LASTEXITCODE -ne 0){throw 'Driver full artifact identity sealing failed'}
 'PASS'|Set-Content (Join-Path $BuildRoot "qualification-$Configuration\complete.txt")
} finally {if($owned){Remove-Item $store -Force -ErrorAction SilentlyContinue}}
Write-CIHashIndex (Join-Path $BuildRoot "qualification-$Configuration")
