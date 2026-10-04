Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$kitsBin = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
$inf2Cat = Get-ChildItem -LiteralPath $kitsBin -Filter "Inf2Cat.exe" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
$stampInf = Get-ChildItem -LiteralPath $kitsBin -Filter "stampinf.exe" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($inf2Cat -and $stampInf -and $inf2Cat.Directory.Parent.Name -eq "10.0.26100.0" -and $stampInf.Directory.Parent.Name -eq "10.0.26100.0") {
    & (Join-Path $PSScriptRoot 'Assert-WindowsKitPins.ps1') -ReceiptDir "$env:RUNNER_TEMP/component-qualification"
    Write-Host "Windows Driver Kit already available: $($inf2Cat.Directory.Parent.Name)"
    return
}

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $winget) {
    throw "The GitHub runner has no WDK and no winget. Use a current hosted Windows runner or preinstall the Windows 11 WDK on the self-hosted runner."
}

foreach ($package in @(
    @{id="Microsoft.WindowsSDK.10.0.26100";version="10.0.26100.2454"},
    @{id="Microsoft.WindowsWDK.10.0.26100";version="10.1.26100.2454"}
)) {
    & $winget.Source install --id $package.id --version $package.version --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "Pinned kit install failed ($($package.id),$($package.version)); no latest fallback." }
}

$inf2Cat = Get-ChildItem -LiteralPath $kitsBin -Filter "Inf2Cat.exe" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $inf2Cat) { throw "WDK installation completed, but Inf2Cat.exe is still missing." }

& (Join-Path $PSScriptRoot 'Assert-WindowsKitPins.ps1') -ReceiptDir "$env:RUNNER_TEMP/component-qualification"
