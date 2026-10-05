param(
    [Parameter(Mandatory)][string]$AuditFile,
    [Parameter(Mandatory)][ValidateSet('release','dev')][string]$ExpectedProfile,
    [Parameter(Mandatory)][string]$ExpectedHostTask,
    [Parameter(Mandatory)][string]$ExpectedPrivateRoot,
    [Parameter(Mandatory)][string]$ExpectedHostExecutable
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert-ProducerExecutionAudit {
    param([string]$Path,[string]$Profile,[string]$HostTask,[string]$PrivateRoot,[string]$HostExecutable)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'PRODUCER_AUDIT_MISSING' }
    $lines=[IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path))
    if ($lines.Count -lt 2) { throw 'PRODUCER_AUDIT_INCOMPLETE' }
    try { $events=@($lines | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop }) }
    catch { throw 'PRODUCER_AUDIT_FORMAT_INVALID' }
    $headers=@($events | Where-Object event -eq 'invocation')
    if ($headers.Count -ne 1) { throw 'PRODUCER_AUDIT_INVOCATION_CARDINALITY_INVALID' }
    $header=$headers[0]
    if ($header.profile -cne $Profile) { throw 'PRODUCER_AUDIT_PROFILE_MISMATCH' }
    if ([string]::IsNullOrWhiteSpace([string]$header.invocation)) { throw 'PRODUCER_AUDIT_INVOCATION_ID_MISSING' }
    $records=@($events | Where-Object event -ne 'invocation')
    foreach($record in $records) {
        if ($record.event -notin @('wdk-install','wdk-run','host-run','host-helper-rejected')) { throw 'PRODUCER_AUDIT_EVENT_TYPE_INVALID' }
        if ($record.invocation -cne $header.invocation) { throw 'PRODUCER_AUDIT_INVOCATION_MISMATCH' }
        if ($record.profile -cne $Profile) { throw 'PRODUCER_AUDIT_EVENT_PROFILE_MISMATCH' }
        if ($null -eq $record.exitCode -or "$($record.exitCode)" -notmatch '^-?\d+$' -or [long]$record.exitCode -ne 0) { throw 'PRODUCER_CHILD_EXECUTION_FAILED' }
    }
    $privatePrefix=$PrivateRoot.TrimEnd([char[]]@('\','/'))+'\'
    $private=@($records | Where-Object { $_.event -eq 'wdk-run' -and $_.version -ceq 'rust-script 0.30.0' -and $_.task -ceq 'setup-wdk-config-env-vars' -and $_.executable -and $_.executable.StartsWith($privatePrefix,[StringComparison]::OrdinalIgnoreCase) -and $_.sha256 -match '^[A-Fa-f0-9]{64}$' })
    if ($private.Count -lt 1) { throw 'PRODUCER_PRIVATE_RUN_PROOF_MISSING' }
    $hostProofs=@($records | Where-Object { $_.event -eq 'host-run' -and $_.version -ceq 'rust-script 0.36.0' -and $_.task -ceq $HostTask -and $_.executable -ceq $HostExecutable -and $_.dispatcher -and @($_.args).Count -gt 0 })
    if ($hostProofs.Count -lt 1) { throw 'PRODUCER_HOST_TASK_PROOF_MISSING' }
    [pscustomobject]@{result='PASS';invocation=$header.invocation;profile=$Profile;hostTask=$HostTask;privateRunCount=$private.Count;hostRunCount=$hostProofs.Count;privateExecutable=$private[0].executable;hostExecutable=$hostProofs[0].executable;dispatcher=$hostProofs[0].dispatcher}
}
Assert-ProducerExecutionAudit -Path $AuditFile -Profile $ExpectedProfile -HostTask $ExpectedHostTask -PrivateRoot $ExpectedPrivateRoot -HostExecutable $ExpectedHostExecutable | ConvertTo-Json -Compress
