param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'Assert-CIToolchain.ps1'
$failure = $null
try { & $checker -ReceiptDir $ReceiptDir } catch { $failure = $_.Exception.Message }
$receiptPath = Join-Path $ReceiptDir 'toolchain.json'
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    Write-Host 'TOOLCHAIN_FAILURE_RECEIPT_TEST=RED'
    Write-Host "CHECKER_ERROR=$failure"
    throw 'Required toolchain failure receipt was not written before the checker refused the build.'
}
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
if ($receipt.status -ne 'FAIL' -or -not $failure) {
    throw 'Failure receipt control expected a failed receipt and a fail-closed checker result.'
}
Write-Host 'TOOLCHAIN_FAILURE_RECEIPT_TEST=PASS'
