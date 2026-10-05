param([Parameter(Mandatory)][string]$ReceiptDir)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Import-VisualStudioEnvironment
$headers=@(& git -C $repo ls-files '*probe_common.h')
if($headers.Count -ne 1 -or $headers[0] -ne 'tools/fullstack/probe_common.h'){throw 'Header authority is not unique'}
$blob=(& git -C $repo rev-parse HEAD:tools/fullstack/probe_common.h).Trim()
$actual=(& git -C $repo hash-object tools/fullstack/probe_common.h).Trim()
if($actual -ne $blob){throw 'Header Git blob mismatch'}
Push-Location $ReceiptDir
try {
 & cl.exe /nologo /O2 /W4 /MT /EHsc (Join-Path $repo 'tools/d3d12_devicecreate_probe.cpp') "/Fe:$(Join-Path $ReceiptDir 'd3d12-smoke.exe')" /link d3d12.lib dxgi.lib dxguid.lib 2>&1|Tee-Object -FilePath (Join-Path $ReceiptDir 'red.log')
 $code=$LASTEXITCODE
 $output=Get-Content (Join-Path $ReceiptDir 'red.log') -Raw
 if($code -eq 0 -or $output -notmatch 'C1083.*probe_common.h'){throw 'Historical C1083 not reproduced'}
 [ordered]@{status='PASS';expectedFailure='C1083_PROBE_COMMON_HEADER';exit=$code;header=$headers[0];gitBlob=$blob;fileBlob=$actual;headSha=$env:GITHUB_SHA}|ConvertTo-Json|Set-Content (Join-Path $ReceiptDir 'header-red.json') -Encoding utf8
} finally {Pop-Location}
