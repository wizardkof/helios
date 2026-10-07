param([Parameter(Mandatory)][string]$ReceiptDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:RUNNER_TEMP) { throw 'RUNNER_TEMP is required for pinned Git acquisition.' }
$receiptPath = Join-Path $ReceiptDir 'git-install.json'
$receipt = [ordered]@{
    schemaVersion=1; status='FAIL'; releaseTag=$null; assetName=$null; acquisitionUrl=$null
    expectedArchiveSha256=$null; observedArchiveSha256=$null
    gitPath=$null; gitSize=$null; gitSha256=$null
    runnerGitCandidates=@(); runnerGitPath=$null; runnerGitVersion=$null
    expectedVersion=$null; observedVersion=$null; exitCode=$null; error=$null
}
try {
    New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
    $runnerGitCandidates = @(Get-Command git -CommandType Application -All -ErrorAction SilentlyContinue)
    $receipt.runnerGitCandidates = @($runnerGitCandidates | ForEach-Object { [string]$_.Source })
    $runnerGit = $runnerGitCandidates | Select-Object -First 1
    if ($runnerGit) {
        $receipt.runnerGitPath = [string]$runnerGit.Source
        $receipt.runnerGitVersion = (@(& $runnerGit.Source --version 2>&1 | ForEach-Object {$_.ToString()}) -join "`n").Trim()
    }
    $pins = Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
    $pin = $pins.gitUpstream
    if ($pins.gitVersion -cne '2.55.0.5' -or $pin.releaseTag -cne 'v2.55.0.windows.5' -or $pin.assetName -cne 'MinGit-2.55.0.5-64-bit.zip' -or $pin.executableRelativePath -cne 'cmd/git.exe') {
        throw 'Pinned native MinGit acquisition identity is inconsistent.'
    }
    $receipt.releaseTag = $pin.releaseTag
    $receipt.assetName = $pin.assetName
    $receipt.acquisitionUrl = "https://github.com/git-for-windows/git/releases/download/$($pin.releaseTag)/$($pin.assetName)"
    $receipt.expectedArchiveSha256 = $pin.archiveSha256
    $receipt.expectedVersion = $pin.executableVersion
    $root = Join-Path $env:RUNNER_TEMP "helios-tools/git-$($pins.gitVersion)"
    $archive = Join-Path $env:RUNNER_TEMP $pin.assetName
    $receipt.gitPath = [IO.Path]::GetFullPath((Join-Path $root $pin.executableRelativePath))
    if (Test-Path -LiteralPath $root) { throw 'Pinned Git extraction directory already exists; refusing ambiguous stale bytes.' }
    Invoke-WebRequest -Uri $receipt.acquisitionUrl -OutFile $archive
    $receipt.observedArchiveSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($receipt.observedArchiveSha256 -cne $receipt.expectedArchiveSha256) { throw 'Official MinGit archive SHA-256 mismatch.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $root
    if (-not (Test-Path -LiteralPath $receipt.gitPath -PathType Leaf)) { throw 'Pinned MinGit archive did not contain cmd/git.exe.' }
    $receipt.gitSize = [long](Get-Item -LiteralPath $receipt.gitPath).Length
    $receipt.gitSha256 = (Get-FileHash -LiteralPath $receipt.gitPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $global:LASTEXITCODE = $null
    $output = @(& $receipt.gitPath --version 2>&1 | ForEach-Object { $_.ToString() })
    $receipt.exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $receipt.observedVersion = $output -join "`n"
    if ($receipt.exitCode -ne 0 -or $receipt.observedVersion.Trim() -cne $receipt.expectedVersion -or $receipt.gitSize -le 0) { throw 'Pinned MinGit executable version or identity failed.' }
    if (-not $env:GITHUB_ENV -or -not $env:GITHUB_PATH) { throw 'GitHub environment files are required to publish qualified Git selection.' }
    [IO.File]::AppendAllText($env:GITHUB_ENV, "HELIOS_GIT=$($receipt.gitPath)`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::AppendAllText($env:GITHUB_PATH, "$(Split-Path -Parent $receipt.gitPath)`n", [Text.UTF8Encoding]::new($false))
    $receipt.status = 'PASS'
} catch {
    $receipt.error = $_.Exception.Message
} finally {
    $temporary = "$receiptPath.tmp"
    ConvertTo-Json -InputObject $receipt -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $receiptPath -Force
}
Write-Host (ConvertTo-Json -InputObject $receipt -Depth 8)
if ($receipt.status -cne 'PASS') { throw "Pinned official Git acquisition failed: $($receipt.error)" }
