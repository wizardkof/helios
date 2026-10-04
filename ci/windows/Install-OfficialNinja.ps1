param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
$pins = Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
$pin = $pins.ninjaUpstream
$expectedVersion = if ($pin) { [string]$pin.version } else { $null }
$root = Join-Path $env:RUNNER_TEMP 'helios-tools/ninja-1.13.2'
$archive = Join-Path $env:RUNNER_TEMP 'ninja-win-v1.13.2.zip'
$receiptPath = Join-Path $ReceiptDir 'ninja-install.json'
$receipt = [ordered]@{
    schemaVersion = 1
    status = 'FAIL'
    packageVersion = $expectedVersion
    packageId = if ($pin) { $pin.packageId } else { $null }
    acquisitionUrl = if ($pin) { $pin.url } else { $null }
    expectedArchiveSha256 = if ($pin) { $pin.archiveSha256 } else { $null }
    archivePath = $archive
    archiveSha256 = $null
    executablePath = Join-Path $root 'ninja.exe'
    executableVersionExpected = if ($pin) { $pin.executableVersion } else { $null }
    executableVersionObserved = $null
    executableExitCode = $null
    executableSize = $null
    executableSha256Expected = if ($pin) { $pin.executableSha256 } else { $null }
    executableSha256 = $null
    error = $null
}

try {
    New-Item -ItemType Directory -Force -Path $ReceiptDir, $root | Out-Null
    if (-not $pin) { throw 'Pinned official Ninja acquisition identity is missing.' }
    if ($env:NINJA_VERSION -ne $pin.version) { throw "NINJA_VERSION disagrees with the pinned release: $env:NINJA_VERSION" }
    Invoke-WebRequest -Uri $pin.url -OutFile $archive
    $receipt.archiveSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($receipt.archiveSha256 -ne $pin.archiveSha256) { throw "Ninja release archive SHA-256 mismatch: $($receipt.archiveSha256)" }
    Expand-Archive -LiteralPath $archive -DestinationPath $root -Force
    if (-not (Test-Path -LiteralPath $receipt.executablePath -PathType Leaf)) { throw 'Official Ninja archive did not contain ninja.exe.' }
    $exe = Get-Item -LiteralPath $receipt.executablePath
    $receipt.executableSize = [long]$exe.Length
    $receipt.executableSha256 = (Get-FileHash -LiteralPath $receipt.executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($receipt.executableSha256 -ne $pin.executableSha256) { throw "Ninja executable SHA-256 mismatch: $($receipt.executableSha256)" }
    $global:LASTEXITCODE = $null
    $versionOutput = @(& $receipt.executablePath --version 2>&1 | ForEach-Object { $_.ToString() })
    $receipt.executableExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $receipt.executableVersionObserved = $versionOutput -join "`n"
    if ($receipt.executableExitCode -ne 0 -or $receipt.executableVersionObserved.Trim() -cne $pin.executableVersion) {
        throw "Official Ninja version mismatch: exit=$($receipt.executableExitCode) observed=$($receipt.executableVersionObserved)"
    }
    if (-not $env:GITHUB_PATH -or -not $env:GITHUB_ENV) { throw 'GitHub environment files are required to select the pinned Ninja in later steps.' }
    [IO.File]::AppendAllText($env:GITHUB_PATH, "$(Split-Path -Parent $receipt.executablePath)`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::AppendAllText($env:GITHUB_ENV, "HELIOS_NINJA=$($receipt.executablePath)`nNINJA=$($receipt.executablePath)`n", [Text.UTF8Encoding]::new($false))
    $receipt.status = 'PASS'
} catch {
    $receipt.error = $_.Exception.Message
} finally {
    $tempReceipt = "$receiptPath.tmp"
    ConvertTo-Json -InputObject $receipt -Depth 8 | Set-Content -LiteralPath $tempReceipt -Encoding UTF8
    Move-Item -LiteralPath $tempReceipt -Destination $receiptPath -Force
}

Write-Host (ConvertTo-Json -InputObject $receipt -Depth 8)
if ($receipt.status -ne 'PASS') { throw "Pinned official Ninja provisioning failed: $($receipt.error)" }
