param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$pins = Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
$version = [string]$pins.llvmVersion
$upstream = $pins.llvmUpstream
$url = [string]$upstream.url
$installer = Join-Path $env:RUNNER_TEMP "LLVM-$version-win64.exe"
$receiptPath = Join-Path $ReceiptDir 'pinned-llvm-install.json'
$receipt = [ordered]@{schemaVersion=1;status='FAIL';url=$url;expectedInstallerSize=[long]$upstream.size;expectedInstallerSha256=[string]$upstream.sha256;installerPath=$installer;installerSize=$null;installerSha256=$null;installExitCode=$null;installLog=$null;error=$null}
try {
    New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
    Invoke-WebRequest -Uri $url -OutFile $installer
    $file = Get-Item -LiteralPath $installer
    $receipt.installerSize = [long]$file.Length
    $receipt.installerSha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($receipt.installerSize -ne $receipt.expectedInstallerSize -or $receipt.installerSha256 -cne $receipt.expectedInstallerSha256) { throw 'LLVM_RELEASE_ASSET_IDENTITY_MISMATCH' }
    $log = Join-Path $ReceiptDir 'llvm-install.log'
    $process = Start-Process -FilePath $installer -ArgumentList @('/S') -Wait -PassThru
    $receipt.installExitCode = $process.ExitCode
    $receipt.installLog = $log
    if ($process.ExitCode -ne 0) { throw "LLVM installer exit=$($process.ExitCode)" }
    $bin = Join-Path $env:ProgramFiles 'LLVM\bin'
    $exe = Join-Path $bin 'clang-cl.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'LLVM clang-cl.exe missing after install' }
    $env:HELIOS_LLVM_BIN = $bin
    $env:PATH = "$bin;$env:PATH"
    if ($env:GITHUB_ENV) { "HELIOS_LLVM_BIN=$bin" >> $env:GITHUB_ENV }
    if ($env:GITHUB_PATH) { $bin >> $env:GITHUB_PATH }
    $receipt.status = 'PASS'
} catch { $receipt.error = $_.Exception.Message }
ConvertTo-Json -InputObject $receipt -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-Host (ConvertTo-Json -InputObject $receipt -Depth 8)
if ($receipt.status -ne 'PASS') { throw "Pinned LLVM installation failed; receipt=$receiptPath error=$($receipt.error)" }
