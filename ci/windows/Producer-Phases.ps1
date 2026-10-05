# Atomic transitions and last native command; only caller-supplied public identities.
function Write-ProducerPhaseReceipt {
    $json=$script:ProducerPhase|ConvertTo-Json -Depth 12
    foreach($path in @((Join-Path $script:ProducerPhaseRoot ($script:ProducerPhase.phase+'.json')), (Join-Path $script:ProducerPhaseRoot 'phase-current.json'))) {
        $temporary=$path+'.tmp'
        [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$path,$true)
    }
}
function Start-ProducerPhase([string]$Name) {
    $script:ProducerPhase=[ordered]@{schemaVersion=1;phase=$Name;status='RUNNING';startUtc=[DateTime]::UtcNow.ToString('o');endUtc=$null;exit=$null;lastCommand=$null;identities=$script:ProducerIdentities}
    Write-ProducerPhaseReceipt
    Write-Host ($Name+'=START')
}
function Complete-ProducerPhase([int]$ExitCode) {
    $script:ProducerPhase.exit=$ExitCode
    $script:ProducerPhase.endUtc=[DateTime]::UtcNow.ToString('o')
    $script:ProducerPhase.status=if($ExitCode -eq 0){'PASS'}else{'FAIL'}
    Write-ProducerPhaseReceipt
    Write-Host ($script:ProducerPhase.phase+'='+$script:ProducerPhase.status)
}
function Invoke-OpenCLNative([string]$FilePath,[string[]]$ArgumentList) {
    $script:ProducerPhase.lastCommand=@($FilePath)+$ArgumentList
    Write-ProducerPhaseReceipt
    & $FilePath @ArgumentList
    $nativeExit=$LASTEXITCODE
    if($nativeExit -ne 0){
        Complete-ProducerPhase $nativeExit
        throw "$($script:ProducerPhase.phase) native exit $nativeExit"
    }
}
