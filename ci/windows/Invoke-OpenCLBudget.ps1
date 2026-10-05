param([Parameter(Mandatory)][string]$OutputDir,[Parameter(Mandatory)][string]$ReceiptDir,[Parameter(Mandatory)][string]$ClvkRepository,[Parameter(Mandatory)][string]$ClvkCommit)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$command=@((Get-Command pwsh.exe).Source,'-NoProfile','-File',(Join-Path $PSScriptRoot 'Build-OpenCL.ps1'),'-OutputDir',$OutputDir,'-ReceiptDir',$ReceiptDir,'-ClvkRepository',$ClvkRepository,'-ClvkCommit',$ClvkCommit)
$commandPath=Join-Path $ReceiptDir 'command.json'
ConvertTo-Json -InputObject $command|Set-Content -LiteralPath $commandPath -Encoding utf8
python (Join-Path $PSScriptRoot 'producer_budget.py') --command-file $commandPath --receipt-dir $ReceiptDir --budget-seconds 19800 --deadline-utc $env:HELIOS_OPENCL_PRESERVE_DEADLINE
if($LASTEXITCODE -ne 0){throw "OpenCL producer failed; preserved supervisor exit $LASTEXITCODE"}
