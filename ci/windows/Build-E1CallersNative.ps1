param([ValidateSet('x64','x86')][string]$Architecture,[Parameter(Mandatory)][string]$HeadersRoot,[Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $Output|Out-Null
@{Kind='DIAGNOSTIC_WINDOWS_CALLERS';Architecture=$Architecture;ProductBuild='NOT_RUN';GpuExecution='NOT_RUN';Utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $Output 'attempt.json')
. "$PSScriptRoot/Initialize-HeliosBuild.ps1"
Import-VisualStudioEnvironment -Architecture $Architecture
$root=(Resolve-Path "$PSScriptRoot/../..").Path
$source=Join-Path $root 'tools/p06-e1-callers'
$target=Get-Content (Join-Path $source 'target-identity.json') -Raw|ConvertFrom-Json
if($target.version -ne '22.22.316.0' -or $target.productFreeze -ne '5a25fb0006904f76e671eb1436bc9d9cb4a977b8'){throw 'Exact target source gate'}
foreach($arch in @('x64','x86')){
 $entry=$target.mesa.$arch
 if($entry.sha256 -notmatch '^[0-9a-f]{64}$'){throw 'Binding SHA256 shape gate'}
 $inputDir=Join-Path $env:RUNNER_TEMP ('mesa-caller-input-'+$arch)
 & gh run download $target.productRunId --repo wizardkof/helios --name $entry.artifactName --dir $inputDir
 if($LASTEXITCODE){throw 'Exact Mesa artifact download failed'}
 $receipt=Get-Content (Join-Path $inputDir 'ci-artifact-identity.json') -Raw|ConvertFrom-Json
 if($receipt.identity.headSha -ne $target.productFreeze -or $receipt.identity.runId -ne $target.productRunId -or $receipt.identity.version -ne $target.version -or $receipt.identity.sourceFingerprint -ne $target.sourceFingerprint -or $receipt.identity.architecture -ne $arch){throw 'Actual Mesa producer identity gate'}
 $dll=@($receipt.files|Where-Object {([IO.Path]::GetFileName($_.path)) -eq 'vulkan_virtio.dll'})
 if($dll.Count -ne 1 -or $dll[0].sha256 -ne $entry.sha256 -or (Get-FileHash (Join-Path $inputDir $dll[0].path)).Hash -ne $entry.sha256){throw 'Actual Mesa component hash gate'}
}
$compiler=Join-Path $env:LLVM_PATH 'bin/clang++.exe'
$version=& $compiler --version
@{Path=$compiler;Version=$version;SHA256=(Get-FileHash $compiler).Hash}|ConvertTo-Json -Depth 4|Set-Content (Join-Path $Output 'compiler.json')
if($version[0] -notmatch 'clang version 22\.1\.8'){throw 'Exact Clang version gate'}
$binding=Join-Path $Output 'candidate-binding.hpp'
@('#pragma once',('#define P06_EXPECT_ICD_X64_SHA256 "'+$target.mesa.x64.sha256+'"'),('#define P06_EXPECT_ICD_X86_SHA256 "'+$target.mesa.x86.sha256+'"'))|Set-Content $binding -Encoding utf8
$machine=if($Architecture -eq 'x64'){'x86_64-pc-windows-msvc'}else{'i686-pc-windows-msvc'}
$expectedMachine=if($Architecture -eq 'x64'){0x8664}else{0x14c}
$identity=@{Kind='DIAGNOSTIC_VERSIONED_ATTEST_WINDOWS_CALLERS';CallerSource=(& git -C $root rev-parse HEAD).Trim();Target=$target;Architecture=$Architecture;Msvc=$env:VCToolsVersion;Sdk=$env:WindowsSDKVersion;ProductBuild='NOT_RUN';GpuExecution='NOT_RUN';Utc=[DateTime]::UtcNow.ToString('o')}
$identity|ConvertTo-Json -Depth 8|Set-Content (Join-Path $Output 'identity.json')
$files=@()
foreach($name in @('p06-e1-vulkan-pair','p06-e1-kmd-control','p06-e1-original-regression')){
 $exe=Join-Path $Output ($name+'.exe');$log=Join-Path $Output ($name+'-build.txt')
 & $compiler "--target=$machine" -std=c++17 -Wall -Wextra '-Wno-unused-parameter' '-Wno-missing-field-initializers' "-I$HeadersRoot/include" '-include' $binding (Join-Path $source ($name+'.cpp')) '-ladvapi32' '-lversion' '-lgdi32' '-luser32' '-o' $exe *> $log
 if($LASTEXITCODE){throw "Native caller compilation failed: $name"}
 $bytes=[IO.File]::ReadAllBytes($exe);if($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a){throw 'PE DOS gate'}
 $offset=[BitConverter]::ToInt32($bytes,0x3c)
 if($offset -lt 0 -or $offset+26 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes,$offset) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes,$offset+4) -ne $expectedMachine){throw 'Native PE machine gate'}
 $files+=@{Name=($name+'.exe');SHA256=(Get-FileHash $exe).Hash;Size=$bytes.Length;Machine=$expectedMachine;SourceSHA256=(Get-FileHash (Join-Path $source ($name+'.cpp'))).Hash}
}
# No executable is launched: these are real Windows callers, not session0 GPU smokes.
@{Result='PASS_NATIVE_WINDOWS_CALLER_COMPILATION';Architecture=$Architecture;Files=$files;Target=$target;ProductBuild='NOT_RUN';GpuExecution='NOT_RUN';GreenARuntime='NOT_RUN'}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $Output 'result.json')
New-Item -ItemType Directory -Force (Join-Path $Output 'source')|Out-Null
Copy-Item (Join-Path $source '*') (Join-Path $Output 'source') -Recurse -Force
