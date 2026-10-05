param([Parameter(Mandatory)][string]$Job,[string]$Root='C:/he')
$ErrorActionPreference='Stop'
$steps=$env:HELIOS_STEPS_JSON|ConvertFrom-Json
$sources=Get-Content (Join-Path $PSScriptRoot 'ci-evidence-sources.json') -Raw|ConvertFrom-Json
$spec=@()
foreach($s in $sources.$Job) {
 $outcome='skipped'
 $p=$steps.PSObject.Properties[$s.step]
 if($p){$outcome=$p.Value.outcome}
 $source=$s.source # Shared Python expansion uses RUNNER_TEMP / HELIOS_CI_CONFIGURATION.
 $entry=@{name=$s.name;source=$source;outcome=$outcome;required=$s.required}
 if($s.PSObject.Properties['mandatoryFiles']){$entry.mandatoryFiles=@($s.mandatoryFiles)}
 $spec+=$entry
}
$specPath=Join-Path $env:RUNNER_TEMP 'evidence-sources.json'
ConvertTo-Json -InputObject $spec -Depth 5|Set-Content $specPath -Encoding UTF8
python (Join-Path $PSScriptRoot 'ci_evidence.py') collect --spec $specPath --root $Root --primary $env:HELIOS_PRIMARY_RESULT
if($LASTEXITCODE -ne 0){throw 'EVIDENCE_COLLECTION_RESULT=FAIL (manifest retained; upload must still run)'}
