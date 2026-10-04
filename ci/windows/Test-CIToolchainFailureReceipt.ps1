param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts.psm1') -Force
$fixtureDir = Join-Path $ReceiptDir ('fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null
$variantPath = Join-Path $fixtureDir 'ninja.cmd'
@('@echo 1.13.2.git.kitware.jobserver-pipe-1', '@exit /b 0') | Set-Content -LiteralPath $variantPath -Encoding ascii
$oldSelected = $env:HELIOS_NINJA
$oldNinja = $env:NINJA
$failure = $null
$checkerReceipt = Join-Path $fixtureDir 'toolchain.json'
try {
    $env:HELIOS_NINJA = $variantPath
    $env:NINJA = $variantPath
    try { & (Join-Path $PSScriptRoot 'Assert-CIToolchain.ps1') -ReceiptDir $fixtureDir } catch { $failure = $_.Exception.Message }
} finally {
    $env:HELIOS_NINJA = $oldSelected
    $env:NINJA = $oldNinja
}
if (-not (Test-Path -LiteralPath $checkerReceipt -PathType Leaf)) {
    Write-Host 'TOOLCHAIN_FAILURE_RECEIPT_TEST=RED'
    throw "Checker did not preserve a receipt before refusal: $failure"
}
if (-not $failure) { throw 'Checker failed to refuse a deliberately rejected Ninja variant.' }
$receipt = Get-Content -LiteralPath $checkerReceipt -Raw | ConvertFrom-Json
$ninja = $receipt.checks | Where-Object requestedName -eq 'ninja.exe' | Select-Object -First 1
if ($receipt.status -ne 'FAIL' -or -not $ninja -or $ninja.status -ne 'FAIL') { throw 'Rejected Ninja variant did not leave a failed native toolchain receipt.' }
if ($ninja.exitCode -ne 0 -or $ninja.observedVersion -cne '1.13.2.git.kitware.jobserver-pipe-1') { throw 'Rejected Ninja receipt lost its real exit or complete version.' }
if ($ninja.path -cne $variantPath -or $ninja.size -le 0 -or $ninja.sha256.Length -ne 64) { throw 'Rejected Ninja receipt lost path, size or SHA-256.' }
Write-Host 'TOOLCHAIN_FAILURE_RECEIPT_TEST=PASS'
Write-Host "NINJA_FAILURE_RECEIPT=$checkerReceipt"
