param([string]$ReceiptDir="$env:RUNNER_TEMP/python-test-dependencies",[switch]$Control,[switch]$Tests)
$ErrorActionPreference='Stop'
# setup-python owns pythonLocation. Resolve a literal path, never PATH/MSYS2 pip.
$python=Join-Path $env:pythonLocation 'python.exe'
if(-not(Test-Path -LiteralPath $python -PathType Leaf)){throw 'Pinned native Python path missing'}
& $python (Join-Path $PSScriptRoot 'bootstrap_test_python.py') bootstrap --receipt-dir $ReceiptDir
if($LASTEXITCODE -ne 0){throw 'Native Python dependency bootstrap failed'}
if($Control){
 & $python (Join-Path $PSScriptRoot 'bootstrap_test_python.py') control --receipt-dir (Join-Path $ReceiptDir 'control')
 if($LASTEXITCODE -ne 0){throw 'Python real-consumer RED/GREEN failed'}
}
if($Tests){
 & $python (Join-Path $PSScriptRoot 'bootstrap_test_python.py') tests --receipt-dir (Join-Path $ReceiptDir 'tests')
 if($LASTEXITCODE -ne 0){throw 'Native Python test suites failed'}
}
"HELIOS_REGRESSION_PYTHON=$python" >> $env:GITHUB_ENV
