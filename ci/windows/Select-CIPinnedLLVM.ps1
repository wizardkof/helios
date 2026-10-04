param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
$pins = Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
$bin = if ($env:HELIOS_LLVM_BIN) { [string]$env:HELIOS_LLVM_BIN } else { Join-Path $env:ProgramFiles 'LLVM\bin' }
$exe = Join-Path $bin 'clang-cl.exe'
$row = [ordered]@{ requestedName='clang-cl.exe'; commandType='ExplicitPath'; path=$exe; resolvedCommandType='ExplicitPath'; resolvedPath=$exe; expectedVersion=$pins.llvmVersion; observedVersion=$null; exitCode=$null; size=$null; sha256=$null; status='NOT_OBSERVED'; error=$null }
try {
    $item = Get-Item -LiteralPath $exe -ErrorAction Stop
    $row.size = [long]$item.Length
    $row.sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $global:LASTEXITCODE = $null
    $output = @(& $exe --version 2>&1 | ForEach-Object { $_.ToString() })
    $row.exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $row.observedVersion = $output -join "`n"
    $row.status = if ($row.exitCode -eq 0 -and $row.observedVersion -match ('(?m)^clang version ' + [regex]::Escape($pins.llvmVersion) + '(?:\s|$)')) { 'PASS' } else { 'FAIL' }
    if ($row.status -eq 'FAIL') { $row.error = 'PINNED_LLVM_VERSION_MISMATCH' }
} catch { $row.status = 'FAIL'; $row.exitCode = -1; $row.error = $_.Exception.Message }
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
$receipt = [ordered]@{ schemaVersion=1; name='pinned-llvm-selection'; generatedAtUtc=[DateTime]::UtcNow.ToString('o'); status=$row.status; check=[pscustomobject]$row }
ConvertTo-Json -InputObject $receipt -Depth 8 | Set-Content -LiteralPath (Join-Path $ReceiptDir 'pinned-llvm.json') -Encoding UTF8
Write-Host (ConvertTo-Json -InputObject $receipt -Depth 8)
if ($row.status -eq 'PASS') {
    "HELIOS_LLVM_BIN=$bin" >> $env:GITHUB_ENV
    "$bin" >> $env:GITHUB_PATH
    $env:HELIOS_LLVM_BIN = $bin
    $env:PATH = "$bin;$env:PATH"
}
