param([string]$Root='C:/he-control')
$ErrorActionPreference='Stop'
foreach($test in @('test_ci_evidence.py','test_windows_kit.py')) {
 python -m unittest discover -s $PSScriptRoot -p $test
 if($LASTEXITCODE -ne 0){throw "Native infrastructure regression failed: $test"}
}
$fixture='C:/he-fixture' ;New-Item -ItemType Directory -Force $fixture|Out-Null
$kit=(Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw|ConvertFrom-Json).windowsKit
# Expected rejection exists only in this test. The real gate never catches PASS.
$observation=@{family=$kit.family;queryStatus='PASS';inventory=@();files=@()}
$observation|ConvertTo-Json -Depth 5|Set-Content "$fixture/refused-observation.json" -Encoding UTF8
python (Join-Path $PSScriptRoot 'windows_kit.py') --pins (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') --observation "$fixture/refused-observation.json" --receipt "$fixture/windows-kit.json"
if($LASTEXITCODE -ne 1){throw 'Fixture must be rejected by the real checker'}
$r=Get-Content "$fixture/windows-kit.json" -Raw|ConvertFrom-Json
if($r.status -ne 'FAIL' -or -not $r.failures.Count){throw 'Expected failure receipt missing'}
$other=Join-Path $env:RUNNER_TEMP 'evidence-fixture';New-Item -ItemType Directory -Force $other|Out-Null
Copy-Item "$fixture/windows-kit.json" "$other/windows-kit.json"
# Synthetic policy fixtures only; never use host credentials.
foreach($relative in @('ordinary.txt','.editorconfig','.evidence/ordinary.txt','.evidence/nested/.gitignore')) {
 $file=Join-Path $fixture $relative
 New-Item -ItemType Directory -Force (Split-Path -Parent $file)|Out-Null
 [IO.File]::WriteAllText($file,"synthetic: $relative")
}
[IO.File]::WriteAllText((Join-Path $fixture 'synthetic-private.pfx'),'synthetic private input; deliberately excluded')
$spec=@(@{name='component-qualification';source=$fixture;outcome='failure';required=$true},@{name='other-volume';source=$other;outcome='success';required=$true},@{name='not-started-build';source='C:/not-produced';outcome='skipped';required=$true})
$spec|ConvertTo-Json -Depth 5|Set-Content "$fixture/sources.json" -Encoding UTF8
python (Join-Path $PSScriptRoot 'ci_evidence.py') collect --spec "$fixture/sources.json" --root $Root --primary EXPECTED_FIXTURE_REJECTION
if($LASTEXITCODE -ne 0){throw 'Fixture collection failed'}
python (Join-Path $PSScriptRoot 'ci_evidence.py') verify --root $Root
if($LASTEXITCODE -ne 0){throw 'Fixture pre-upload identity failed'}

$manifest=Get-Content "$Root/collection-manifest.json" -Raw|ConvertFrom-Json
if(@($manifest.excluded | Where-Object {$_.reason -eq 'PRIVATE_PATH'}).Count -ne 1){throw 'Synthetic private exclusion missing'}
