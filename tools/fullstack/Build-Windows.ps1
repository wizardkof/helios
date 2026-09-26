[CmdletBinding()]
param(
    [ValidateSet('x86', 'x64')][string]$Arch = 'x64',
    [ValidateSet('D3D11Create', 'D3D12Create')][string]$Suite = 'D3D11Create',
    [string]$Out,
    [string]$BuildRoot = $env:HELIOS_FULLSTACK_WINDOWS_BUILD_ROOT
)

$arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $PSScriptRoot 'Run-Suite.ps1'),
    '-Mode', 'Build', '-Suite', $Suite, '-Arch', $Arch
)
if ($Out) { $arguments += @('-Out', $Out) }
if ($BuildRoot) { $arguments += @('-BuildRoot', $BuildRoot) }
& powershell.exe @arguments
exit $LASTEXITCODE
