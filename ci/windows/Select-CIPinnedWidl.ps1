param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
$pins = Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
$expected = [string]$pins.qualifiedObservedTools.widlVersion
$commands = @()
if ($env:HELIOS_WIDL -and (Test-Path -LiteralPath $env:HELIOS_WIDL -PathType Leaf)) {
    $commands += [pscustomobject]@{ Path = $env:HELIOS_WIDL; CommandType = 'PinnedBuildOutput' }
} else {
    $commands = @(Get-Command widl.exe -All -ErrorAction SilentlyContinue | Where-Object CommandType -eq Application)
}
$paths = @($commands | ForEach-Object { [string]$_.Path })
foreach ($candidate in @('C:\mingw64\bin\widl.exe','C:\Strawberry\c\bin\widl.exe')) { if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and $candidate -notin $paths) { $paths += $candidate } }
$rows = @()
$selected = $null
foreach ($candidate in $paths) {
    $row = [ordered]@{ requestedName='widl.exe'; commandType='Application'; path=$candidate; resolvedCommandType='ExplicitPath'; resolvedPath=$candidate; expectedVersion=$expected; observedVersion=$null; exitCode=$null; size=$null; sha256=$null; status='NOT_OBSERVED'; error=$null }
    try {
        $item = Get-Item -LiteralPath $candidate -ErrorAction Stop
        $row.size = [long]$item.Length
        $row.sha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $global:LASTEXITCODE = $null
        $output = @(& $candidate -V 2>&1 | ForEach-Object { $_.ToString() })
        $row.exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $row.observedVersion = $output -join "`n"
        $row.status = if ($row.exitCode -eq 0 -and $row.observedVersion -match ('(?m)version ' + [regex]::Escape($expected) + '(?![0-9.])')) { 'PASS' } else { 'FAIL' }
        if ($row.status -eq 'PASS' -and -not $selected) { $selected = $candidate }
        if ($row.status -eq 'FAIL') { $row.error = 'PINNED_WIDL_VERSION_MISMATCH' }
    } catch { $row.status = 'FAIL'; $row.exitCode = -1; $row.error = $_.Exception.Message }
    $rows += [pscustomobject]$row
}
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
$receipt = [ordered]@{ schemaVersion=1; name='pinned-widl-selection'; generatedAtUtc=[DateTime]::UtcNow.ToString('o'); expectedVersion=$expected; selectedPath=$selected; status=if ($selected) { 'PASS' } else { 'FAIL' }; candidates=$rows }
ConvertTo-Json -InputObject $receipt -Depth 12 | Set-Content -LiteralPath (Join-Path $ReceiptDir 'pinned-widl.json') -Encoding UTF8
Write-Host (ConvertTo-Json -InputObject $receipt -Depth 12)
if ($selected) {
    "HELIOS_WIDL=$selected" >> $env:GITHUB_ENV
    (Split-Path -Parent $selected) >> $env:GITHUB_PATH
    $env:HELIOS_WIDL = $selected
    $env:PATH = "$(Split-Path -Parent $selected);$env:PATH"
}
