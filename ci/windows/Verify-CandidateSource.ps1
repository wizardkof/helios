param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Configuration,
    [Parameter(Mandatory)][string]$Architecture,
    [string]$ReservationRemote = "origin"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$python = Get-Command python -ErrorAction Stop
& $python.Source (Join-Path $RepoRoot "tools\candidate_version.py") verify `
    --portable --root $RepoRoot --remote $ReservationRemote --require-remote
if ($LASTEXITCODE -ne 0) { throw "Candidate source/reservation verification failed." }

$lock = Get-Content -LiteralPath (Join-Path $RepoRoot "metadata\candidate-reservation.json") -Raw | ConvertFrom-Json
$versionLine = Get-Content -LiteralPath (Join-Path $RepoRoot "kmd_render\driver-version.env") |
    Where-Object { $_ -match '^HELIOS_KMD_VERSION=' }
if (@($versionLine).Count -ne 1) { throw "Candidate must have exactly one HELIOS_KMD_VERSION." }
$version = ($versionLine -replace '^HELIOS_KMD_VERSION=', '').Trim()
if ($version -ne [string]$lock.version) { throw "Resolved version differs from the immutable candidate lock." }
$head = (& git -C $RepoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "Cannot resolve the effective Helios source commit." }
if ($env:GITHUB_SHA -and $head -ne $env:GITHUB_SHA) { throw "Checkout HEAD differs from GITHUB_SHA." }

$effective = [ordered]@{
    candidateVersion = $version
    sourceFingerprint = [string]$lock.sourceFingerprint
    reservationRef = [string]$lock.reservationRef
    reservationDigest = [string]$lock.reservationDigest
    heliosSourceCommit = $head
    reservedHeliosBaseCommit = [string]$lock.sourceCommits.helios
    mesa = (& git -C (Join-Path $RepoRoot "icd\mesa") rev-parse HEAD).Trim()
    dxvk = (& git -C (Join-Path $RepoRoot "dxvk-helios") rev-parse HEAD).Trim()
    vkd3d = (& git -C (Join-Path $RepoRoot "vkd3d-proton-helios") rev-parse HEAD).Trim()
    configuration = $Configuration
    architecture = $Architecture
    externalPins = [ordered]@{
        clvk = $env:CLVK_COMMIT
        vulkanLoader = $env:VULKAN_LOADER_COMMIT
        vulkanHeaders = $env:VULKAN_HEADERS_COMMIT
        openClLoader = $env:OPENCL_LOADER_COMMIT
        openClHeaders = $env:OPENCL_HEADERS_COMMIT
    }
}
foreach ($name in @("mesa", "dxvk", "vkd3d")) {
    $locked = [string]$lock.sourceCommits.PSObject.Properties[$name].Value
    if ($effective[$name] -ne $locked) { throw "Effective $name source differs from the candidate reservation." }
}
$effective | ConvertTo-Json -Depth 6
