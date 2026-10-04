param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts.psm1') -Force
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
$failures = [Collections.Generic.List[string]]::new()

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION_FAILED: $Message" }
}

# A real executable with both a version mismatch and a nonzero result must
# retain its absolute path, complete output, exit code, size and digest.
$mismatch = Invoke-CIToolCheck -Name 'pwsh.exe' -Arguments @('-NoLogo', '-NoProfile', '-Command', "[Console]::WriteLine('1.13.2.variant'); exit 23") -ExpectedVersion '1.13.2' -VersionPattern '^1\.13\.2$' -Phase 'fixture-mismatch'
$mismatchPath = Join-Path $ReceiptDir 'mismatch.json'
$mismatchReceipt = New-CIToolReceipt -Name 'mismatch-control' -Checks @($mismatch)
Write-CIToolReceipt -Path $mismatchPath -Receipt $mismatchReceipt
$savedMismatch = Get-Content -LiteralPath $mismatchPath -Raw | ConvertFrom-Json
Assert-That ($savedMismatch.status -eq 'FAIL') 'mismatch receipt must fail'
Assert-That ($savedMismatch.checks[0].path -and [IO.Path]::IsPathRooted($savedMismatch.checks[0].path)) 'mismatch path must be absolute'
Assert-That ($savedMismatch.checks[0].size -gt 0 -and $savedMismatch.checks[0].sha256.Length -eq 64) 'mismatch file identity must be retained'
Assert-That ($savedMismatch.checks[0].exitCode -eq 23) 'nonzero exit must be retained'
Assert-That ($savedMismatch.checks[0].observedVersion -match '1\.13\.2\.variant') 'complete observed output must be retained'

# A missing command is a receipt row, not an uncaught resolution exception.
$missingName = 'helios-definitely-absent-tool-' + [guid]::NewGuid().ToString('N')
$missing = Invoke-CIToolCheck -Name $missingName -Arguments @('--version') -ExpectedVersion '1' -VersionPattern '^1$' -Phase 'fixture-missing'
$missingPath = Join-Path $ReceiptDir 'missing.json'
$missingReceipt = New-CIToolReceipt -Name 'missing-control' -Checks @($missing)
Write-CIToolReceipt -Path $missingPath -Receipt $missingReceipt
$savedMissing = Get-Content -LiteralPath $missingPath -Raw | ConvertFrom-Json
Assert-That ($savedMissing.status -eq 'FAIL' -and $savedMissing.checks[0].status -eq 'NOT_OBSERVED') 'missing command must be a failed receipt'
Assert-That ($savedMissing.checks[0].error -match '^RESOLUTION:') 'missing command must retain resolution error'

# Prefix-equivalent variants must remain rejected when returned by a concrete
# executable candidate, not merely by a simulated version string.
$variantPath = Join-Path $ReceiptDir 'ninja-variant.cmd'
@('@echo 1.13.2.git.kitware.jobserver-pipe-1', '@exit /b 0') | Set-Content -LiteralPath $variantPath -Encoding ascii
$variant = Invoke-CIToolCheck -Name 'ninja.exe' -ExecutablePath $variantPath -ExpectedResolvedPath $variantPath -Arguments @('--version') -ExpectedVersion '1.13.2' -VersionPattern '^1\.13\.2$' -Phase 'fixture-variant'
Assert-That ($variant.status -eq 'FAIL' -and $variant.observedVersion -match 'kitware') 'a suffixed Ninja version must fail an exact pin'
Assert-That ($variant.path -ceq $variantPath -and $variant.size -gt 0 -and $variant.sha256.Length -eq 64 -and $variant.exitCode -eq 0) 'variant receipt must preserve executable identity and exit'

# Parent and child must execute the exact absolute path carried by NINJA.
$realNinja = $env:HELIOS_NINJA
Assert-That ($realNinja -and (Test-Path -LiteralPath $realNinja -PathType Leaf)) 'approved NINJA executable is unavailable'
$env:NINJA = $realNinja
$env:HELIOS_NINJA_TEST_EXPECTED = $realNinja
$childCode = "`$cmd = Get-Command ninja -ErrorAction Stop; if (`$env:NINJA -ne `$env:HELIOS_NINJA_TEST_EXPECTED -or [IO.Path]::GetFullPath(`$cmd.Source) -ine [IO.Path]::GetFullPath(`$env:HELIOS_NINJA_TEST_EXPECTED)) { exit 41 }; `$out = & `$env:NINJA --version; if (`$LASTEXITCODE -ne 0) { exit 42 }; Write-Output ((Resolve-Path `$env:NINJA).Path + '|' + (`$out -join '')); exit 0"
$childOutput = @(& pwsh.exe -NoLogo -NoProfile -Command $childCode 2>&1 | ForEach-Object { $_.ToString() })
$childExit = $LASTEXITCODE
Assert-That ($childExit -eq 0) "child process failed to use explicit Ninja: exit=$childExit output=$($childOutput -join ' ')"
Assert-That (($childOutput -join "`n") -match [regex]::Escape($realNinja)) 'child did not report the selected absolute executable'

# Distribution metadata is recorded separately from the binary response.
$metadataCode = 'import importlib.metadata as m,json; d=next(iter(m.distributions(name="ninja")),None); print(json.dumps({"status":"OBSERVED" if d else "NOT_INSTALLED","metadataVersion":d.version if d else None,"files":[str(x) for x in (d.files or [])] if d else []}))'
$metadataOutput = @(& python.exe -c $metadataCode 2>&1 | ForEach-Object { $_.ToString() })
$metadataExit = $LASTEXITCODE
Assert-That ($metadataExit -eq 0) 'Python Ninja distribution metadata was not queryable'
$metadata = ($metadataOutput -join "`n") | ConvertFrom-Json
$execProbe = Invoke-CIToolCheck -Name 'ninja.exe' -Arguments @('--version') -ExpectedVersion '1.13.2' -VersionPattern '^1\.13\.2$' -Phase 'approved-executable'
$combined = [pscustomobject]@{ pythonDistributionMetadata = $metadata; executable = [pscustomobject]@{ observedVersion = $execProbe.observedVersion; path = $execProbe.path; sha256 = $execProbe.sha256; exitCode = $execProbe.exitCode } }
Write-CIToolReceipt -Path (Join-Path $ReceiptDir 'python-vs-executable.json') -Receipt (New-CIToolReceipt -Name 'python-vs-executable' -Checks @($execProbe) -Context @{ pythonDistributionMetadataVersion = $metadata.metadataVersion })
Assert-That ($combined.pythonDistributionMetadata.status -in @('OBSERVED','NOT_INSTALLED') -and $combined.executable.observedVersion) 'package metadata and executable output must be separate fields'

Write-Host 'TOOLCHAIN_RECEIPT_CONTROLS=PASS'
Write-Host "MISMATCH_RECEIPT=$mismatchPath"
Write-Host "MISSING_RECEIPT=$missingPath"
