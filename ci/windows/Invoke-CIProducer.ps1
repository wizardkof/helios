param([Parameter(Mandatory)][string]$ReceiptDir,[Parameter(Mandatory)][string]$Producer,[Parameter(Mandatory)][scriptblock]$Operation)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
& (Join-Path $PSScriptRoot 'Measure-CIRunner.ps1') -ReceiptDir $ReceiptDir -Producer $Producer
Start-Transcript (Join-Path $ReceiptDir "$Producer-producer.log")|Out-Null
try { & $Operation; if($LASTEXITCODE -and $LASTEXITCODE -ne 0){throw "Producer $Producer native exit $LASTEXITCODE"} } finally {Stop-Transcript|Out-Null}
