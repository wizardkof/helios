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
    New-Item -ItemType Directory -Force $ReceiptDir | Out-Null
    $records=[ordered]@{}
    foreach($name in @('host','private')){
        $path=if($name -eq 'host'){$env:HELIOS_HOST_RUST_SCRIPT}else{Join-Path $(if($env:HELIOS_WDK_PRIVATE_ROOT){$env:HELIOS_WDK_PRIVATE_ROOT}else{'C:\hb\isolation\wdk-private'}) 'bin\rust-script.exe'}
        if($name -eq 'host' -and -not $path){
            $resolved=Get-Command rust-script.exe -ErrorAction SilentlyContinue|Select-Object -First 1
            if($resolved){$path=$resolved.Source}
        }
        $expected=if($name -eq 'host'){'rust-script 0.36.0'}else{'rust-script 0.30.0'}
        $row=[ordered]@{requestedName='rust-script.exe';commandType=$null;resolvedCommandType=$null;path=$path;resolvedPath=$path;resolutionCandidates=@();expectedVersion=$expected;observedVersion=$null;exitCode=$null;size=$null;sha256=$null;expectedSha256=$(if($name -eq 'host'){$env:HELIOS_HOST_RUST_SCRIPT_INITIAL_SHA256}else{$null});status='NOT_OBSERVED';error=$null}
        try{
            if(-not $path -or -not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'EXECUTABLE_NOT_FOUND'}
            $row.commandType=if($name -eq 'host' -and $env:HELIOS_HOST_RUST_SCRIPT){'ExplicitPath'}else{'Application'}
            $row.resolvedCommandType=$row.commandType
            $item=Get-Item -LiteralPath $path -ErrorAction Stop;$row.size=[long]$item.Length
            $row.sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            $global:LASTEXITCODE=$null
            $output=@(& $path --version 2>&1|ForEach-Object {$_.ToString()})
            $row.exitCode=if($null -eq $LASTEXITCODE){0}else{[int]$LASTEXITCODE}
            $row.observedVersion=$output -join "`n"
            $row.status=if($row.exitCode -eq 0 -and $row.observedVersion -ceq $expected){'PASS'}else{'FAIL'}
            if($name -eq 'host' -and $row.expectedSha256 -and $row.sha256 -cne ([string]$row.expectedSha256).ToLowerInvariant()){$row.status='FAIL';$row.error='HOST_RUST_SCRIPT_HASH_CHANGED'}
            if($row.exitCode -ne 0){$row.error='EXECUTION_EXIT_NONZERO'}elseif($row.observedVersion -cne $expected){$row.error='VERSION_MISMATCH'}
        }catch{
            $row.status=if($path){'FAIL'}else{'NOT_OBSERVED'}
            $row.error=$_.Exception.Message
            if($null -eq $row.exitCode){$row.exitCode=-1}
        }
        $records[$name]=[pscustomobject]$row
    }
    $status=if(@($records.Values|Where-Object {$_.status -ne 'PASS'}).Count){'FAIL'}else{'PASS'}
    $records['status']=$status
    $receiptPath=Join-Path $ReceiptDir "$Phase-rust-script.json";$temporary="$receiptPath.tmp"
    ConvertTo-Json -InputObject $records -Depth 8|Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $receiptPath -Force
    if($Phase -eq 'post' -and $status -eq 'PASS'){Write-Host 'HOST_RUST_SCRIPT_POST=0.36.0'}
    if($status -ne 'PASS'){throw "Host/private rust-script contract failed; receipt=$receiptPath"}
}
function Write-CIHashIndex([string]$Directory) {
    $directory=(Resolve-Path $Directory).Path
    $rows=@(Get-ChildItem $directory -Recurse -File | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object FullName | ForEach-Object {((Get-FileHash $_.FullName).Hash.ToLowerInvariant())+'  '+$_.FullName.Substring($directory.Length+1).Replace('\','/')})
    $rows|Set-Content (Join-Path $directory 'SHA256SUMS.txt') -Encoding ascii
}
