param([string]$ControlRoot='C:\hb\isolation')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -and $env:HELIOS_ALLOW_LOCAL_PRODUCT_BUILD -ne '1') { throw 'LOCAL_PRODUCT_BUILDS=DISABLED_BY_DEFAULT; explicit owner authorization required.' }
if(Test-Path $ControlRoot){throw 'Fresh isolated controls required'}
New-Item -ItemType Directory -Path $ControlRoot | Out-Null
$env:HELIOS_ISOLATION_ROOT=$ControlRoot
$env:HELIOS_HOST_RUST_SCRIPT=(Get-Command rust-script.exe).Source
$env:HELIOS_PINNED_CARGO=(Get-Command cargo.exe).Source
$env:HELIOS_ORIGINAL_CARGO=(Get-Command cargo.exe).Source
$env:HELIOS_WDK_PRIVATE_ROOT=Join-Path $ControlRoot 'wdk-private'
$env:HELIOS_RUST_SCRIPT_AUDIT=Join-Path $ControlRoot 'bootstrap.executions.log'
$version=(& $env:HELIOS_HOST_RUST_SCRIPT --version) -join ''
if($LASTEXITCODE -ne 0 -or $version -ne 'rust-script 0.36.0'){throw 'Host rust-script must be0.36.0'}
$before=(Get-FileHash $env:HELIOS_HOST_RUST_SCRIPT).Hash
Copy-Item (Join-Path $PSScriptRoot 'Invoke-WdkRustScript.ps1') $ControlRoot
& pwsh -NoProfile -File (Join-Path $ControlRoot 'Invoke-WdkRustScript.ps1') -Mode Install -PrivateRoot $env:HELIOS_WDK_PRIVATE_ROOT -TaskName ci-bootstrap
if($LASTEXITCODE -ne 0){throw 'WDK private preparation failed'}
if((Get-FileHash $env:HELIOS_HOST_RUST_SCRIPT).Hash -ne $before){throw 'WDK preparation replaced host tool'}
$dispatch=Join-Path $ControlRoot 'host-dispatch'
New-Item -ItemType Directory $dispatch | Out-Null
Copy-Item $env:HELIOS_ORIGINAL_CARGO (Join-Path $dispatch 'cargo.exe')
& rustc --edition=2021 -O (Join-Path $PSScriptRoot 'host-dispatch.rs') -o (Join-Path $dispatch 'rust-script.exe')
if($LASTEXITCODE -ne 0){throw 'Host producer dispatcher compile failed'}
# Keep Meson's locking semantics; place wrap locks outside SOURCE_ROOTS.
$env:HELIOS_MESON_LOCK_ROOT=Join-Path $ControlRoot 'meson-locks'
$env:HELIOS_MESON_ENTRY=Join-Path $PSScriptRoot 'meson-isolated.py'
$env:HELIOS_HOST_RUST_SCRIPT_INITIAL_SHA256=$before
Write-Host 'HOST_RUST_SCRIPT_PRE=0.36.0'
Write-Host 'WDK_PRIVATE_RUST_SCRIPT=0.30.0'

# GitHub steps are separate processes: persist only validated producer controls.
if ($env:GITHUB_ACTIONS -eq 'true') {
 if (-not $env:GITHUB_ENV) { throw 'GITHUB_ENV is required to preserve isolation controls' }
 foreach($name in @('HELIOS_ISOLATION_ROOT','HELIOS_HOST_RUST_SCRIPT','HELIOS_PINNED_CARGO','HELIOS_ORIGINAL_CARGO','HELIOS_WDK_PRIVATE_ROOT','HELIOS_MESON_LOCK_ROOT','HELIOS_MESON_ENTRY','HELIOS_HOST_RUST_SCRIPT_INITIAL_SHA256')) {
  $value=[Environment]::GetEnvironmentVariable($name,'Process')
  if (-not $value -or $value.Contains("`n") -or $value.Contains("`r")) { throw "Invalid persisted control: $name" }
  [IO.File]::AppendAllText($env:GITHUB_ENV,"$name=$value`n",[Text.UTF8Encoding]::new($false))
 }
}
