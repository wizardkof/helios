param([Parameter(Mandatory)][string]$RepoRoot,[string]$ReceiptDir='C:\hb\regressions')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CI-Qualification.ps1')
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Assert-CIBackend
& (Join-Path $PSScriptRoot 'Measure-CIRunner.ps1') -ReceiptDir $ReceiptDir -Producer regressions
Write-CIFingerprint $RepoRoot $ReceiptDir pre
Start-Transcript (Join-Path $ReceiptDir 'regressions.log')|Out-Null
try {
 foreach($script in @('Test-HeliosRegistrySnapshots.ps1','Test-HeliosInstallState.ps1')){
  $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $RepoRoot "packaging\windows\$script"))
  if($script -eq 'Test-HeliosInstallState.ps1'){$args+=@('-Receipt',(Join-Path $ReceiptDir 'state-schema.json'))}
  $start=[Diagnostics.ProcessStartInfo]::new()
  $start.FileName="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $start.UseShellExecute=$false
  [void]$start.Environment.Remove('PSModulePath')
  foreach($arg in $args){$start.ArgumentList.Add($arg)}
  $process=[Diagnostics.Process]::Start($start)
  $process.WaitForExit()
  if($process.ExitCode -ne 0){throw "Native PS5.1 regression failed: $script"}
  $process.Dispose()
 }
 & (Join-Path $RepoRoot 'packaging\windows\Test-HeliosRegistrySnapshots.ps1')
 foreach($spec in @(@('tools','test_candidate_version.py'),@('ci\windows','test_packaged_install_state.py'),@('ci\windows','test_ci_contract.py'),@('ci\windows','test_ci_package.py'),@('ci\windows','test_ci_artifact.py'))){
  & python -m unittest discover -s (Join-Path $RepoRoot $spec[0]) -p $spec[1]
  if($LASTEXITCODE -ne 0){throw "Regression failed: $($spec[1])"}
 }
 Import-VisualStudioEnvironment
 $env:CC=(Get-Command clang-cl.exe).Source;$env:CXX=$env:CC
 $dxvk=Join-Path $RepoRoot 'dxvk-helios';$build='C:\hb\dxvk-regressions'
 foreach($relative in @('tests/test_cs_failure.cpp','tests/test_queue_error.cpp','tests/generate_queue_submit.py')){if(-not(Test-Path (Join-Path $dxvk $relative))){throw "Qualified DXVK regression source missing: $relative"}}
 if(Test-Path $build){throw 'Fresh CPU regression build required'}
 & python $env:HELIOS_MESON_ENTRY setup $build $dxvk --native-file (Join-Path $PSScriptRoot 'clang-cl-native.ini') --buildtype release -Db_vscrt=mt -Denable_cs_tests=true -Denable_d3d8=false -Denable_d3d9=false -Denable_d3d10=false -Denable_d3d11=true -Denable_dxgi=true '-Dcpp_args=/D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH' "-Dc_args=/FI$(Join-Path $RepoRoot 'umd\build-support\dxvk_c_compat.h')"
 if($LASTEXITCODE -ne 0){throw 'DXVK regression setup failed'}
 & python $env:HELIOS_MESON_ENTRY compile -j $env:HELIOS_BUILD_JOBS -C $build test_cs_failure test_queue_error
 if($LASTEXITCODE -ne 0){throw 'DXVK CPU regression compile failed'}
 $tests=Get-Content "$build\meson-info\intro-tests.json" -Raw|ConvertFrom-Json
 $required=@('cs_failure','queue-finish','queue-submit','queue-success','queue-lost-finish','queue-lost-submit','queue-previous','queue-pending','queue-independent')
 foreach($name in $required){if(@($tests|Where-Object {$_.name -eq $name}).Count -ne 1){throw "CPU regression missing: $name"}}
 & python $env:HELIOS_MESON_ENTRY test -C $build --no-rebuild --print-errorlogs --num-processes 1 @required
 if($LASTEXITCODE -ne 0){throw 'DXVK CPU regressions failed'}
 Copy-Item "$build\meson-logs\testlog*" $ReceiptDir
 Write-CIFingerprint $RepoRoot $ReceiptDir post
 'PASS'|Set-Content (Join-Path $ReceiptDir 'complete.txt')
} finally {Stop-Transcript|Out-Null}
Write-CIHashIndex $ReceiptDir
