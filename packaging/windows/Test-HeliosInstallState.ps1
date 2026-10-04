[CmdletBinding()]
param([string]$PackageScripts='', [string]$Receipt='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess) {
    throw 'Schema regression requires native Windows PowerShell 5.1 x64.'
}
if (-not $PackageScripts) { $PackageScripts=$PSScriptRoot }
. (Join-Path $PackageScripts 'Helios-PackageCommon.ps1')
function Read-Ast([string]$Name) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageScripts $Name),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "Parse failure: $Name" }
    return $ast
}
$install=Read-Ast 'Install-Helios.ps1';$verify=Read-Ast 'Verify-Helios.ps1'
$constructors=@($install.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$state' -and $n.Right.Extent.Text.StartsWith('[ordered]@{')},$true))
if ($constructors.Count -ne 1) { throw 'Expected unique production state constructor.' }
$constructor=$constructors[0]
$previous=@($install.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PreviousStateValue'},$true))
if ($previous.Count -ne 1) { throw 'Expected production previous-state accessor.' }
. ([scriptblock]::Create($previous[0].Extent.Text))
$updates=@($verify.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$state\.(candidateVersion|preparedVersion|activeVersionObserved|observedComponentVersions|restartPending|versionState)$'},$true) | Sort-Object {$_.Extent.StartOffset})
if ($updates.Count -ne 6) { throw 'Expected all six production verifier state assignments.' }
$update=[scriptblock]::Create(($updates | ForEach-Object {$_.Extent.Text}) -join "`n")
# AST selects real production statements; each selected statement is executed,
# not replaced with a reimplementation or a property-name-only schema model.
function Invoke-Normalization($Ast,$State) {
    $commands=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Initialize-HeliosInstallState'},$true))
    if ($commands.Count -gt 1) { throw 'Ambiguous state normalization call site.' }
    $state=$State
    if ($commands.Count -eq 1) { . ([scriptblock]::Create($commands[0].Extent.Text)) }
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('helios-state-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$results=@()
try {
    foreach ($case in @('fresh','legacy-no-observations','legacy-no-digest','legacy-pre-version-fields','existing-property','upgrade-existing-observations','serialize-deserialize')) {
        try {
            # Supply synthetic inputs to the actual production constructor.
            foreach ($v in $constructor.FindAll({param($n) $n -is [Management.Automation.Language.VariableExpressionAst]},$true)) {
                if ($v.VariablePath.UserPath -notin @('true','false','null','state')) { Set-Variable -Name $v.VariablePath.UserPath -Value '' }
            }
            $manifest=[pscustomobject]@{packageId='synthetic';publisher='Synthetic Publisher';version='22.22.299.0'}
            $manifestPayloadDigest='a'*64;$previousState=$null
            if ($case -eq 'upgrade-existing-observations') { $previousState=[pscustomobject]@{observedComponentVersions=[pscustomobject]@{sentinel='preserve-until-observed'}} }
            . ([scriptblock]::Create($constructor.Extent.Text))
            Invoke-Normalization $install $state
            $state=$state | ConvertTo-Json -Depth 15 | ConvertFrom-Json
            if ($case -in @('legacy-no-observations','legacy-no-digest','legacy-pre-version-fields')) {
                $state.PSObject.Properties.Remove('observedComponentVersions')
            }
            if ($case -eq 'legacy-no-digest') { $state.PSObject.Properties.Remove('candidatePayloadDigest') }
            if ($case -eq 'legacy-pre-version-fields') {
                foreach ($p in @('candidateVersion','preparedVersion','activeVersionObserved','restartPending','versionState')) { $state.PSObject.Properties.Remove($p) }
            }
            if ($case -eq 'upgrade-existing-observations' -and
                (-not $state.PSObject.Properties['observedComponentVersions'] -or
                 -not $state.observedComponentVersions.PSObject.Properties['sentinel'] -or
                 $state.observedComponentVersions.sentinel -ne 'preserve-until-observed')) { throw 'Production upgrade constructor lost previous observations before verification.' }
            if ($case -eq 'existing-property') {
                $state | Add-Member -NotePropertyName observedComponentVersions -NotePropertyValue ([pscustomobject]@{sentinel='preserve-until-observed'}) -Force
            }
            $before=$state | ConvertTo-Json -Depth 15 -Compress
            Invoke-Normalization $verify $state
            if ($case -eq 'existing-property' -and $state.observedComponentVersions.sentinel -ne 'preserve-until-observed') { throw 'Normalization destroyed previous observation.' }
            Invoke-Normalization $verify $state
            if ($case -eq 'legacy-no-digest' -and $state.PSObject.Properties['candidatePayloadDigest']) { throw 'Normalization invented an identity digest.' }
            $observed=[ordered]@{serviceState='Running';serviceImage='22.22.299.0';pnp='22.22.299.0';sentinel='new-real-observation'}
            $candidateVersion='22.22.299.0';$versionPending=$false;$mixedVersions=$false
            . $update
            if ($state.observedComponentVersions.sentinel -ne 'new-real-observation' -or $state.versionState -ne 'ACTIVE' -or $state.restartPending) { throw 'Verifier state update did not persist its observations.' }
            $path=Join-Path $fixture "$case.json"
            Write-HeliosJson $state $path
            $read=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($read.observedComponentVersions.sentinel -ne 'new-real-observation' -or $read.candidateVersion -ne $candidateVersion) { throw 'Serialized state lost observations or candidate identity.' }
            # The same production update must remain valid after another roundtrip.
            $state=$read;. $update
            $results+=@{case=$case;status='PASS'}
        } catch {
            $results+=@{case=$case;status='FAIL';type=$_.Exception.GetType().FullName;errorId=$_.FullyQualifiedErrorId;message=$_.Exception.Message}
        }
    }
    try {
        if ((Assert-HeliosCandidateTransition '22.22.299.0' '' '22.22.300.0' ('b'*64)) -ne 1) { throw 'Legacy upgrade order incorrect.' }
        $sameRejected=$false
        try { [void](Assert-HeliosCandidateTransition '22.22.299.0' '' '22.22.299.0' ('b'*64)) } catch { $sameRejected=$true }
        if (-not $sameRejected) { throw 'Unknown legacy digest allowed same-version replacement.' }
        $results+=@{case='legacy-unknown-digest-upgrade';status='PASS'}
    } catch { $results+=@{case='legacy-unknown-digest-upgrade';status='FAIL';type=$_.Exception.GetType().FullName;errorId=$_.FullyQualifiedErrorId;message=$_.Exception.Message} }
    # Default migration must never claim an active device without observation.
    if (Get-Command Initialize-HeliosInstallState -ErrorAction SilentlyContinue) {
        $unobserved=[pscustomobject]@{version='22.22.299.0'}
        Initialize-HeliosInstallState $unobserved
        if (-not $unobserved.restartPending -or $unobserved.versionState -ne 'PREPARED' -or $unobserved.activeVersionObserved -ne '') { throw 'Migration fabricated activation.' }
        $once=$unobserved | ConvertTo-Json -Depth 15 -Compress
        Initialize-HeliosInstallState $unobserved
        if (($unobserved | ConvertTo-Json -Depth 15 -Compress) -cne $once) { throw 'Migration is not idempotent.' }
    }
    $failed=@($results | Where-Object status -eq 'FAIL')
    $record=[ordered]@{status=if($failed.Count){'FAIL'}else{'PASS'};powerShellVersion=$PSVersionTable.PSVersion.ToString();process64=[Environment]::Is64BitProcess;sourceScripts=@{};cases=$results;installedStateTouched=$false}
    foreach ($n in @('Install-Helios.ps1','Verify-Helios.ps1','Helios-PackageCommon.ps1')) { $record.sourceScripts[$n]=(Get-FileHash (Join-Path $PackageScripts $n)).Hash }
    if ($Receipt) { $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Receipt -Encoding UTF8 }
    $results | ForEach-Object { Write-Host "STATE_CASE=$($_.case) STATUS=$($_.status)" }
    if ($failed.Count) { throw "State schema regression failed ($($failed.Count) cases): $($failed[0].type): $($failed[0].message)" }
    Write-Host 'STATE_SCHEMA_REGRESSION=PASS'
} finally {
    # Only the uniquely owned synthetic fixture directory is removed.
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
