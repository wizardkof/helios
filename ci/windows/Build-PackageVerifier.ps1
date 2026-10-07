param(
    [Parameter(Mandatory)][string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $env:RUNNER_TEMP) { throw 'RUNNER_TEMP is required for the CI-only Package verifier.' }
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
if (-not $OutputDir.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Verifier output must remain below RUNNER_TEMP.'
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Import-VisualStudioEnvironment -Architecture x64
$pins = Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
$expectedMsvc = [string]$pins.visualStudio.msvcVersion
if (-not $env:VCToolsInstallDir -or $env:HELIOS_MSVC_VERSION -cne $expectedMsvc -or ([string]$env:VCToolsVersion).TrimEnd('\') -cne $expectedMsvc) {
    throw "Selected MSVC toolset does not match the pinned version $expectedMsvc."
}
$compilerCommand = Get-Command cl.exe -CommandType Application -ErrorAction Stop
$compiler = [IO.Path]::GetFullPath($compilerCommand.Source)
$expectedCompiler = [IO.Path]::GetFullPath((Join-Path $env:VCToolsInstallDir 'bin\Hostx64\x64\cl.exe'))
if (-not [string]::Equals($compiler, $expectedCompiler, [StringComparison]::OrdinalIgnoreCase)) { throw "Resolved cl.exe path differs from the pinned x64 toolset: $compiler" }
$source = Join-Path $PSScriptRoot 'memory-trust\package_verify.cpp'
$gate = Join-Path $PSScriptRoot 'memory-trust\result_gate.h'
$testSource = Join-Path $PSScriptRoot 'memory-trust\result_gate_test.cpp'
foreach ($path in @($source, $gate, $testSource)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required verifier source is missing: $path" }
}
$exe = Join-Path $OutputDir 'package-verify.exe'
$object = Join-Path $OutputDir 'package-verify.obj'
$arguments = @(
    '/nologo', '/std:c++17', '/EHsc', '/W4', '/DUNICODE', '/D_UNICODE',
    $source, "/Fe:$exe", "/Fo:$object", '/link', 'wintrust.lib', 'crypt32.lib', 'psapi.lib'
)
$compilerOutput = @(& $compiler /Bv @arguments 2>&1 | ForEach-Object { $_.ToString() })
$compileExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
$compilerVersion = (Get-Item -LiteralPath $compiler).VersionInfo.ProductVersion
$compilerOutput | Set-Content -LiteralPath (Join-Path $OutputDir 'compiler-build-output.txt') -Encoding UTF8
if ($compileExit -ne 0 -or -not $compilerVersion -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Pinned cl.exe failed to build package-verify.exe or report its version (exit $compileExit)."
}
$stream = [IO.File]::OpenRead($exe)
try {
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Verifier output has no PE signature.' }
        $machine = $reader.ReadUInt16()
    } finally { $reader.Dispose() }
} finally { $stream.Dispose() }
if ($machine -ne 0x8664) { throw ('Verifier PE machine is not AMD64: 0x{0:X4}' -f $machine) }

$receipt = [ordered]@{
    schemaVersion = 1
    status = 'PASS'
    sourcePath = 'ci/windows/memory-trust/package_verify.cpp'
    sourceSha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    resultGatePath = 'ci/windows/memory-trust/result_gate.h'
    resultGateSha256 = (Get-FileHash -LiteralPath $gate -Algorithm SHA256).Hash.ToLowerInvariant()
    resultGateTestSha256 = (Get-FileHash -LiteralPath $testSource -Algorithm SHA256).Hash.ToLowerInvariant()
    compilerPath = $compiler
    compilerVersion = $compilerVersion
    compilerExitCode = $compileExit
    commandContract = @('/nologo', '/std:c++17', '/EHsc', '/W4', '/DUNICODE', '/D_UNICODE', 'wintrust.lib', 'crypt32.lib', 'psapi.lib')
    outputPath = $exe
    outputSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    outputSize = [long](Get-Item -LiteralPath $exe).Length
    peMachine = 'IMAGE_FILE_MACHINE_AMD64'
    packagePayload = $false
}
$receiptPath = Join-Path $OutputDir 'package-verifier-build.json'
$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-Host "PACKAGE_VERIFIER_BUILD=PASS; SHA256=$($receipt.outputSha256); PE=$($receipt.peMachine)"
