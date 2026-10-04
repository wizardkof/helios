Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert-CIBackend {
    if($env:GITHUB_ACTIONS -ne 'true' -and $env:HELIOS_ALLOW_LOCAL_PRODUCT_BUILD -ne '1'){throw 'LOCAL_PRODUCT_BUILDS=DISABLED_BY_DEFAULT'}
}
function Write-CIFingerprint([string]$RepoRoot,[string]$ReceiptDir,[string]$Phase) {
    New-Item -ItemType Directory -Force $ReceiptDir | Out-Null
    & (Join-Path $PSScriptRoot 'Verify-CandidateSource.ps1') -RepoRoot $RepoRoot -Configuration $(if($env:HELIOS_CI_CONFIGURATION){$env:HELIOS_CI_CONFIGURATION}else{'SharedRelease'}) -Architecture $(if($env:HELIOS_CI_ARCH){$env:HELIOS_CI_ARCH}else{'x64'}) *> (Join-Path $ReceiptDir "$Phase-fingerprint.txt")
    if($LASTEXITCODE -ne 0){throw "Candidate fingerprint failed at $Phase"}
    $lock=Get-Content (Join-Path $RepoRoot 'metadata\candidate-reservation.json') -Raw|ConvertFrom-Json
    $path=Join-Path $ReceiptDir 'source-fingerprint.txt'
    if(Test-Path $path){if((Get-Content $path -Raw).Trim() -ne $lock.sourceFingerprint){throw 'Pre/post fingerprint identity changed'}}else{$lock.sourceFingerprint|Set-Content $path}
}
function Write-CIRustScriptContract([string]$ReceiptDir,[string]$Phase) {
    $records=[ordered]@{}
    foreach($name in @('host','private')){
        $path=if($name -eq 'host'){$env:HELIOS_HOST_RUST_SCRIPT}else{Join-Path $env:HELIOS_WDK_PRIVATE_ROOT 'bin\rust-script.exe'}
        $v=(& $path --version) -join ''
        $expected=if($name -eq 'host'){'rust-script 0.36.0'}else{'rust-script 0.30.0'}
        if($LASTEXITCODE -ne 0 -or $v -ne $expected){throw "$name rust-script contract failed"}
        $h=(Get-FileHash $path).Hash
        if($name -eq 'host' -and $h -ne $env:HELIOS_HOST_RUST_SCRIPT_INITIAL_SHA256){throw 'Host rust-script changed'}
        $records[$name]=@{path=$path;version=$v;sha256=$h;size=(Get-Item $path).Length}
    }
    New-Item -ItemType Directory -Force $ReceiptDir | Out-Null
    $records|ConvertTo-Json -Depth 5|Set-Content (Join-Path $ReceiptDir "$Phase-rust-script.json") -Encoding UTF8
    if($Phase -eq 'post'){Write-Host 'HOST_RUST_SCRIPT_POST=0.36.0'}
}
function Write-CIHashIndex([string]$Directory) {
    $directory=(Resolve-Path $Directory).Path
    $rows=@(Get-ChildItem $directory -Recurse -File | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object FullName | ForEach-Object {((Get-FileHash $_.FullName).Hash.ToLowerInvariant())+'  '+$_.FullName.Substring($directory.Length+1).Replace('\','/')})
    $rows|Set-Content (Join-Path $directory 'SHA256SUMS.txt') -Encoding ascii
}
