param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CI-Qualification.ps1')
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Assert-CIBackend
Import-VisualStudioEnvironment
& (Join-Path $PSScriptRoot 'Initialize-TestPython.ps1') -ReceiptDir "$env:RUNNER_TEMP/product-python-test-dependencies" -Tests
$python=Join-Path $env:pythonLocation 'python.exe'
$receipt='C:/hb/dxvk-array-diagnostic';$build='C:/hb/dxvk-regressions';$dxvk=Join-Path $RepoRoot 'dxvk-helios'
New-Item -ItemType Directory -Force $receipt|Out-Null
$result=[ordered]@{run=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT;helios=$env:GITHUB_SHA;architecture='x64';queueTestCompile='NOT_RUN';normalCompile='NOT_RUN';cpuRegressions='NOT_RUN';executedTests=0;realGpuFaultExecutions=0}
Start-Transcript "$receipt/diagnostic.log"|Out-Null
try {
 $head=(& git -C $dxvk rev-parse HEAD).Trim()
 if($head -ne '56f462d920f9c1238e02bb1354d2de9a52cbf0d5'){throw 'Diagnostic DXVK base mismatch'}
 & git -C $dxvk diff --exit-code
 if($LASTEXITCODE -ne 0){throw 'Diagnostic source must start clean'}
 & git -C $dxvk apply (Join-Path $PSScriptRoot 'dxvk-array.patch')
 if($LASTEXITCODE -ne 0){throw 'Exact diagnostic patch failed'}
 Copy-Item "$dxvk/src/dxvk/dxvk_queue.cpp" $receipt
 Copy-Item (Join-Path $PSScriptRoot 'dxvk-array.patch') $receipt
 $identity=[ordered]@{helios=$env:GITHUB_SHA;dxvkBase=$head;patchSHA256=(Get-FileHash "$receipt/dxvk-array.patch" -Algorithm SHA256).Hash.ToLower();queueSHA256=(Get-FileHash "$receipt/dxvk_queue.cpp" -Algorithm SHA256).Hash.ToLower();run=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT}
 $identity|ConvertTo-Json|Set-Content "$receipt/source-identity.json"
 & git -C $dxvk diff -- src/dxvk/dxvk_queue.cpp |Set-Content "$receipt/source.diff"
 $env:CC=(Get-Command clang-cl.exe).Source;$env:CXX=$env:CC
 & $env:CC --version |Set-Content "$receipt/compiler-version.txt"
 if(Test-Path $build){throw 'Fresh diagnostic build required'}
 $setup=@('setup',$build,$dxvk,'--native-file',(Join-Path $PSScriptRoot 'clang-cl-native.ini'),'--buildtype','release','-Db_vscrt=mt','-Denable_cs_tests=true','-Denable_d3d8=false','-Denable_d3d9=false','-Denable_d3d10=false','-Denable_d3d11=true','-Denable_dxgi=true','-Dcpp_args=/D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH',"-Dc_args=/FI$(Join-Path $RepoRoot 'umd/build-support/dxvk_c_compat.h')")
 ($setup|ConvertTo-Json)|Set-Content "$receipt/setup-arguments.json"
 & $python $env:HELIOS_MESON_ENTRY @setup
 $result.setupExit=$LASTEXITCODE
 if($LASTEXITCODE -ne 0){throw 'Matched Meson setup failed'}
 $commands=Get-Content "$build/compile_commands.json" -Raw|ConvertFrom-Json
 $queue=@($commands|Where-Object {$_.file -match 'dxvk_queue\.cpp$'})
 if($queue.Count -ne 2){throw 'Expected real production and fixture queue commands'}
 $normal=@($queue|Where-Object {$_.command -notmatch 'DXVK_QUEUE_TEST'})
 $fixture=@($queue|Where-Object {$_.command -match 'DXVK_QUEUE_TEST'})
 if($normal.Count -ne 1 -or $fixture.Count -ne 1){throw 'Queue defines mismatch'}
 $queue|ConvertTo-Json -Depth 6|Set-Content "$receipt/queue-compile-commands.json"
 # Compile the actual normal library object first using its generated Ninja target.
 $output=$normal[0].output
 if(-not $output){throw 'Normal object target missing from compile database'}
 & $env:HELIOS_NINJA -C $build -t commands $output |Set-Content "$receipt/normal-commands.txt"
 & $env:HELIOS_NINJA -C $build -v -j $env:HELIOS_BUILD_JOBS $output
 $result.normalExit=$LASTEXITCODE
 if($LASTEXITCODE -ne 0){$result.normalCompile='FAIL';throw 'Real normal queue compile failed'}
 if(-not(Test-Path (Join-Path $build $output))){throw 'Normal object absent'}
 $result.normalCompile='PASS'
 & $env:HELIOS_NINJA -C $build -t commands tests/test_cs_failure.exe tests/test_queue_error.exe |Set-Content "$receipt/commands.txt"
 & $python $env:HELIOS_MESON_ENTRY compile --verbose -j $env:HELIOS_BUILD_JOBS -C $build test_cs_failure test_queue_error
 $result.testCompileExit=$LASTEXITCODE
 if($LASTEXITCODE -ne 0){$result.queueTestCompile='FAIL';throw 'DXVK CPU compile failed'}
 $result.queueTestCompile='PASS'
 $tests=Get-Content "$build/meson-info/intro-tests.json" -Raw|ConvertFrom-Json
 $required=@('cs_failure','queue-finish','queue-submit','queue-success','queue-lost-finish','queue-lost-submit','queue-previous','queue-pending','queue-independent')
 foreach($name in $required){if(@($tests|Where-Object {$_.name -eq $name}).Count -ne 1){throw "CPU regression missing: $name"}}
 $result.requiredTests=$required
 & $python $env:HELIOS_MESON_ENTRY test -C $build --no-rebuild --print-errorlogs --num-processes 1 @required
 $result.testsExit=$LASTEXITCODE
 if($LASTEXITCODE -ne 0){$result.cpuRegressions='FAIL';throw 'DXVK CPU regressions failed'}
 $executed=@(Get-Content "$build/meson-logs/testlog.json"|ForEach-Object {$_|ConvertFrom-Json})
 if($executed.Count -ne 9 -or @($executed|Where-Object {$_.result -ne 'OK'}).Count -ne 0){throw 'Nine real passing test results required'}
 $result.executedTests=$executed.Count;$result.cpuRegressions='PASS'
 'PASS'|Set-Content "$receipt/complete.txt"
} finally {
 $result|ConvertTo-Json -Depth 6|Set-Content "$receipt/result.json"
 foreach($relative in @('compile_commands.json','build.ninja','meson-info','meson-logs')){
  if(Test-Path "$build/$relative"){Copy-Item -Recurse "$build/$relative" $receipt}
 }
 Stop-Transcript|Out-Null
}
