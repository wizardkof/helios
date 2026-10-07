param([Parameter(Mandatory)][string]$OutputDir)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:RUNNER_TEMP) { throw 'RUNNER_TEMP is required for the verifier gate test.' }
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
if (-not $OutputDir.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Verifier gate test output must remain below RUNNER_TEMP.'
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Import-VisualStudioEnvironment -Architecture x64
$source = Join-Path $PSScriptRoot 'memory-trust\result_gate_test.cpp'
$exe = Join-Path $OutputDir 'package-verifier-gate-test.exe'
& cl.exe /nologo /std:c++17 /EHsc /W4 "/I$(Join-Path $PSScriptRoot 'memory-trust')" $source "/Fe:$exe" "/Fo:$(Join-Path $OutputDir 'result-gate-test.obj')"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw 'Native package-verifier acceptance predicate did not compile.'
}
& $exe
if ($LASTEXITCODE -ne 0) { throw 'Native package-verifier acceptance predicate failed.' }
Write-Host 'PACKAGE_VERIFIER_NEGATIVE_ACCEPTANCE_PREDICATE=PASS'
