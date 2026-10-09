param(
    [Parameter(Mandatory)][string]$ReceiptDir,
    [Parameter(Mandatory)][string]$NativeToolchainReceipt
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts.psm1') -Force
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null

function Get-ProcessEnvironmentSnapshot {
    $snapshot = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).GetEnumerator()) {
        $snapshot[[string]$entry.Key] = [string]$entry.Value
    }
    return ,$snapshot
}
function Restore-ProcessEnvironment([Collections.Generic.Dictionary[string,string]]$Snapshot) {
    $current = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
    foreach ($name in @($current.Keys)) {
        if (-not $Snapshot.ContainsKey([string]$name)) {
            [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
        }
    }
    foreach ($name in $Snapshot.Keys) {
        [Environment]::SetEnvironmentVariable([string]$name, $Snapshot[$name], [EnvironmentVariableTarget]::Process)
    }
}
function Get-EnvironmentChanges([Collections.Generic.Dictionary[string,string]]$Before,
                                [Collections.Generic.Dictionary[string,string]]$After) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Before.Keys) { [void]$names.Add($name) }
    foreach ($name in $After.Keys) { [void]$names.Add($name) }
    @($names | Sort-Object | Where-Object {
        -not $Before.ContainsKey($_) -or -not $After.ContainsKey($_) -or
        $Before[$_] -cne $After[$_]
    })
}
function Test-EnvironmentEqual([Collections.Generic.Dictionary[string,string]]$Left,
                              [Collections.Generic.Dictionary[string,string]]$Right) {
    if ($Left.Count -ne $Right.Count) { return $false }
    foreach ($name in $Left.Keys) {
        if (-not $Right.ContainsKey($name) -or $Left[$name] -cne $Right[$name]) { return $false }
    }
    return $true
}
function Write-AtomicJson([string]$Path, $Value) {
    $temporary = "$Path.tmp"
    ConvertTo-Json -InputObject $Value -Depth 16 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Get-CheckRow($Receipt, [string]$Name) {
    @($Receipt.checks | Where-Object { $_.requestedName -ceq $Name })
}
function Assert-RealRustIdentity($Receipt, $NativeRows, [string]$Target, [string]$Phase) {
    foreach ($tool in @('rustup','rustc','cargo')) {
        $rows = @(Get-CheckRow $Receipt $tool)
        if ($rows.Count -ne 1) { throw "$Target/$Phase expected exactly one real $tool check; observed $($rows.Count)" }
        $row = $rows[0]
        $native = $NativeRows[$tool]
        if ($row.status -cne 'PASS' -or $null -ne $row.error -or [int]$row.exitCode -ne 0 -or
            $row.commandType -cne 'Application' -or $row.resolvedCommandType -cne 'Application' -or
            $row.path -cne $native.path -or $row.resolvedPath -cne $native.resolvedPath -or
            [long]$row.size -ne [long]$native.size -or $row.sha256 -cne $native.sha256 -or
            $row.observedVersion -cne $native.observedVersion) {
            throw "$Target/$Phase real $tool identity differs from the native toolchain receipt"
        }
    }
}
function Get-CurrentRustIdentities {
    param([string]$NativeToolchainReceiptPath)
    if (-not (Test-Path -LiteralPath $NativeToolchainReceiptPath -PathType Leaf)) {
        throw "Native toolchain receipt missing: $NativeToolchainReceiptPath"
    }
    $receipt = Get-Content -LiteralPath $NativeToolchainReceiptPath -Raw | ConvertFrom-Json
    if ($receipt.status -cne 'PASS') { throw 'Native toolchain receipt is not PASS' }
    $rows = @{}
    foreach ($tool in @('rustup','rustc','cargo')) {
        $matches = @(Get-CheckRow $receipt $tool)
        if ($matches.Count -ne 1) { throw "Native receipt must contain exactly one $tool identity" }
        $row = $matches[0]
        if ($row.status -cne 'PASS' -or $row.path -cne $row.resolvedPath -or
            [long]$row.size -le 0 -or $row.sha256 -notmatch '^[0-9a-f]{64}$' -or
            [int]$row.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$row.observedVersion)) {
            throw "Native receipt has incomplete $tool identity"
        }
        $rows[$tool] = $row
    }
    return @{receipt=$receipt;rows=$rows}
}

$processBefore = Get-ProcessEnvironmentSnapshot
$retryWasPresent = $processBefore.ContainsKey('RUSTUP_MAX_RETRIES')
$retryPreviousValue = if ($retryWasPresent) { $processBefore['RUSTUP_MAX_RETRIES'] } else { $null }
$cases = [Collections.Generic.List[object]]::new()
$summaryPath = Join-Path $ReceiptDir 'control-summary.json'
$allCaseNames = @('positive/pre','positive/post','absent/pre','absent/post','divergent/pre','divergent/post')
$correlationPath = Join-Path $ReceiptDir 'toolchain-correlation.json'
$unexpected = $null
$correlation = $null
Write-AtomicJson $summaryPath ([ordered]@{schemaVersion=1;status='NOT_RUN';cases=@();notRun=$allCaseNames;initialRetryEnvironment=[pscustomobject]@{present=$retryWasPresent;value=$retryPreviousValue}})
try {
    $pins = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
    $pin = [string]$pins.rust.toolchain
    $rustToolchain = [string]$env:RUST_TOOLCHAIN
    $rustupToolchain = [string]$env:RUSTUP_TOOLCHAIN
    if ($rustToolchain -cne $pin -or $rustupToolchain -cne $pin) {
        throw "Process toolchain variables do not match the pinned toolchain $pin"
    }
    $native = Get-CurrentRustIdentities -NativeToolchainReceiptPath $NativeToolchainReceipt
    $correlation = [ordered]@{
        status='PASS';nativeReceipt=[IO.Path]::GetFullPath($NativeToolchainReceipt)
        nativeReceiptSha256=(Get-FileHash -LiteralPath $NativeToolchainReceipt -Algorithm SHA256).Hash.ToLowerInvariant()
        toolchainPin=$pin;RUST_TOOLCHAIN=$rustToolchain;RUSTUP_TOOLCHAIN=$rustupToolchain
        identities=[ordered]@{}
    }
    foreach ($tool in @('rustup','rustc','cargo')) {
        $row=$native.rows[$tool]
        $correlation.identities[$tool]=[ordered]@{
            path=$row.path;resolvedPath=$row.resolvedPath;size=[long]$row.size
            sha256=$row.sha256;version=$row.observedVersion;exitCode=[int]$row.exitCode
        }
    }
    Write-AtomicJson $correlationPath $correlation

    $targets = @(
        [pscustomobject]@{name='positive';expectedRetries='10';expectedChecker='PASS'},
        [pscustomobject]@{name='absent';expectedRetries=$null;expectedChecker='FAIL'},
        [pscustomobject]@{name='divergent';expectedRetries='9';expectedChecker='FAIL'}
    )
    foreach ($target in $targets) {
        foreach ($phase in @('pre','post')) {
            $caseDir = Join-Path (Join-Path $ReceiptDir $target.name) $phase
            New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
            $environmentBefore = Get-ProcessEnvironmentSnapshot
            $previousPresent = $environmentBefore.ContainsKey('RUSTUP_MAX_RETRIES')
            $previousValue = if ($previousPresent) { $environmentBefore['RUSTUP_MAX_RETRIES'] } else { $null }
            if ($null -eq $target.expectedRetries) {
                [Environment]::SetEnvironmentVariable('RUSTUP_MAX_RETRIES',$null,[EnvironmentVariableTarget]::Process)
            } else {
                [Environment]::SetEnvironmentVariable('RUSTUP_MAX_RETRIES',[string]$target.expectedRetries,[EnvironmentVariableTarget]::Process)
            }
            $appliedPresent = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Contains('RUSTUP_MAX_RETRIES')
            $appliedValue = [Environment]::GetEnvironmentVariable('RUSTUP_MAX_RETRIES',[EnvironmentVariableTarget]::Process)
            if ($target.name -eq 'absent' -and $appliedPresent) {
                [Environment]::SetEnvironmentVariable('RUSTUP_MAX_RETRIES',$null,[EnvironmentVariableTarget]::Process)
                $appliedPresent = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Contains('RUSTUP_MAX_RETRIES')
                $appliedValue = [Environment]::GetEnvironmentVariable('RUSTUP_MAX_RETRIES',[EnvironmentVariableTarget]::Process)
            }
            $receiptPath = Join-Path $caseDir "$phase-producer-tools.json"
            $completedNames = @($cases | ForEach-Object { "$($_.name)/$($_.phase)" })
            $pendingNames = @($allCaseNames | Where-Object { $_ -notin $completedNames })
            Write-AtomicJson $summaryPath ([ordered]@{schemaVersion=1;status='IN_PROGRESS';cases=@($cases.ToArray());notRun=$pendingNames;initialRetryEnvironment=[pscustomobject]@{present=$retryWasPresent;value=$retryPreviousValue}})
            $checkerException = $null
            $checkerEnvironmentBefore = Get-ProcessEnvironmentSnapshot
            $caseProblem = $null
            $checkerReceipt = $null
            $failedChecks = @()
            $blockers = @()
            $retryRow = $null
            try {
                if (($target.name -eq 'positive' -and $appliedValue -cne '10') -or
                    ($target.name -eq 'absent' -and $appliedPresent) -or
                    ($target.name -eq 'divergent' -and $appliedValue -cne '9')) {
                    throw "Control did not establish its requested RUSTUP_MAX_RETRIES context: $($target.name)"
                }
                $parameters = @{
                    Component = 'package'
                    Phase = $phase
                    ReceiptDir = $caseDir
                }
                try {
                    & (Join-Path $PSScriptRoot 'Assert-ComponentToolchain.ps1') @parameters
                } catch {
                    $checkerException = [pscustomobject]@{
                        type=$_.Exception.GetType().FullName
                        message=$_.Exception.Message
                    }
                }
                if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
                    throw "Canonical checker did not persist its receipt; expected $receiptPath"
                }
                $checkerReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
                $failedChecks = @($checkerReceipt.checks | Where-Object { $_.status -ne 'PASS' })
                $blockers = @($checkerReceipt.blocked)
                $retryRows = @(Get-CheckRow $checkerReceipt 'RUSTUP_MAX_RETRIES')
                if ($retryRows.Count -ne 1) { throw "Expected one RUSTUP_MAX_RETRIES row; observed $($retryRows.Count)" }
                $retryRow = $retryRows[0]
                Assert-RealRustIdentity $checkerReceipt $native.rows $target.name $phase
                if ($target.name -eq 'positive') {
                    if ($checkerReceipt.status -cne 'PASS' -or $failedChecks.Count -ne 0 -or
                        $blockers.Count -ne 0 -or $checkerException -or $retryRow.status -cne 'PASS' -or
                        $retryRow.expectedVersion -cne '10' -or $retryRow.observedVersion -cne '10' -or
                        $retryRow.error) {
                        throw 'Positive package toolchain control did not satisfy the complete PASS contract'
                    }
                } else {
                    if ($checkerReceipt.status -cne 'FAIL' -or $failedChecks.Count -ne 1 -or
                        $failedChecks[0].requestedName -cne 'RUSTUP_MAX_RETRIES' -or
                        $retryRow.status -cne 'FAIL' -or $retryRow.error -cne 'ENVIRONMENT_PIN_MISMATCH' -or
                        $retryRow.expectedVersion -cne '10' -or $blockers.Count -ne 0 -or
                        -not $checkerException -or $checkerException.type -cne 'System.Management.Automation.RuntimeException' -or
                        $checkerException.message -notmatch "package-producer-toolchain-$phase toolchain gate failed:" -or
                        $checkerException.message -notmatch 'RUSTUP_MAX_RETRIES=FAIL:ENVIRONMENT_PIN_MISMATCH') {
                        throw 'Negative package toolchain control failed for a reason other than the expected RUSTUP_MAX_RETRIES gate'
                    }
                    if ($target.name -eq 'absent' -and $null -ne $retryRow.observedVersion -and $retryRow.observedVersion -cne '') {
                        throw 'Absent RUSTUP_MAX_RETRIES was not recorded as absent/empty'
                    }
                    if ($target.name -eq 'divergent' -and $retryRow.observedVersion -cne '9') {
                        throw 'Divergent RUSTUP_MAX_RETRIES value was not recorded as 9'
                    }
                }
            } catch {
                if (-not $caseProblem) {
                    $caseProblem = [pscustomobject]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
                }
                if ($null -eq $checkerReceipt -and (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
                    try {
                        $checkerReceipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
                        $failedChecks=@($checkerReceipt.checks | Where-Object { $_.status -ne 'PASS' })
                        $blockers=@($checkerReceipt.blocked)
                        $retryRows=@(Get-CheckRow $checkerReceipt 'RUSTUP_MAX_RETRIES')
                        if ($retryRows.Count -eq 1) { $retryRow=$retryRows[0] }
                    } catch { }
                }
            } finally {
                $environmentAfterChecker = Get-ProcessEnvironmentSnapshot
                $changedNames = @(Get-EnvironmentChanges $checkerEnvironmentBefore $environmentAfterChecker)
                try {
                    Restore-ProcessEnvironment $environmentBefore
                    $restored = Test-EnvironmentEqual $environmentBefore (Get-ProcessEnvironmentSnapshot)
                } catch {
                    $restored = $false
                    if (-not $caseProblem) { $caseProblem=[pscustomobject]@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message} }
                }
            }
            $canonicalIdentity = if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
                $item=Get-Item -LiteralPath $receiptPath
                [pscustomobject]@{path=[IO.Path]::GetFullPath($receiptPath);size=[long]$item.Length;sha256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()}
            } else { $null }
            $caseResult = [pscustomobject][ordered]@{
                name=$target.name;phase=$phase;status=if ($null -eq $caseProblem -and $restored) {'PASS'} else {'FAIL'}
                parameters=[ordered]@{Component='package';Phase=$phase;ReceiptDir=[IO.Path]::GetFullPath($caseDir)}
                expectedChecker=$target.expectedChecker;observedChecker=if ($checkerReceipt) {[string]$checkerReceipt.status} else {'NO_RECEIPT'}
                environmentBefore=[ordered]@{RUSTUP_MAX_RETRIES_present=$previousPresent;RUSTUP_MAX_RETRIES_value=$previousValue;RUST_TOOLCHAIN=$rustToolchain;RUSTUP_TOOLCHAIN=$rustupToolchain}
                appliedContext=[ordered]@{RUSTUP_MAX_RETRIES_present=$appliedPresent;RUSTUP_MAX_RETRIES_value=$appliedValue}
                environmentVariablesChangedByChecker=$changedNames;environmentRestored=$restored
                retryCheck=$retryRow;failedChecks=$failedChecks;blockers=$blockers
                CHECKER_EXCEPTION=$checkerException;CONTROL_EXCEPTION=$caseProblem
                canonicalReceipt=$canonicalIdentity;result=if ($null -eq $caseProblem -and $restored) {'PASS'} else {'FAIL'}
            }
            $cases.Add($caseResult)
            $completedNames = @($cases | ForEach-Object { "$($_.name)/$($_.phase)" })
            $pendingNames = @($allCaseNames | Where-Object { $_ -notin $completedNames })
            $partialSummary=[ordered]@{schemaVersion=1;status=if ($pendingNames.Count -eq 0 -and @($cases | Where-Object {$_.status -ne 'PASS'}).Count -eq 0) {'PASS'} else {'IN_PROGRESS'};cases=@($cases.ToArray());notRun=$pendingNames}
            Write-AtomicJson $summaryPath $partialSummary
            if ($caseProblem -or -not $restored) {
                $unexpected = if ($caseProblem) {$caseProblem.message} else {'Process environment was not restored exactly'}
                throw "Package toolchain context control failed at $($target.name)/$phase: $unexpected"
            }
        }
    }
} catch {
    if (-not $unexpected) { $unexpected=$_.Exception.Message }
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
        Write-AtomicJson $summaryPath ([ordered]@{schemaVersion=1;status='FAIL';cases=@($cases.ToArray());notRun=@('all cases: prerequisite failure');unexpectedFailure=$_.Exception.Message})
    } else {
        $saved=Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $saved.status='FAIL';$saved.unexpectedFailure=$_.Exception.Message
        $saved.notRun=@(foreach ($name in $allCaseNames) {
            if ($name -notin @($cases | ForEach-Object { "$($_.name)/$($_.phase)" })) {$name}
        })
        Write-AtomicJson $summaryPath $saved
    }
} finally {
    try {
        Restore-ProcessEnvironment $processBefore
        $environmentRestoredAtExit = Test-EnvironmentEqual $processBefore (Get-ProcessEnvironmentSnapshot)
    } catch { $environmentRestoredAtExit=$false }
}
if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    Write-AtomicJson $summaryPath ([ordered]@{schemaVersion=1;status='FAIL';cases=@($cases.ToArray());notRun=@('all cases: summary unavailable');unexpectedFailure=$unexpected})
}
$summary=Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
$summary | Add-Member -NotePropertyName environmentRestoredAtExit -NotePropertyValue $environmentRestoredAtExit -Force
$summary | Add-Member -NotePropertyName initialRetryEnvironment -NotePropertyValue ([pscustomobject]@{present=$retryWasPresent;value=$retryPreviousValue}) -Force
$nativeReceiptHash = if ($correlation) {[string]$correlation.nativeReceiptSha256} else {$null}
$summary | Add-Member -NotePropertyName nativeReceiptSha256 -NotePropertyValue $nativeReceiptHash -Force
$summary | Add-Member -NotePropertyName unexpectedFailure -NotePropertyValue $unexpected -Force
$summary | Add-Member -NotePropertyName environmentRestoredAtExit -NotePropertyValue $environmentRestoredAtExit -Force
Write-AtomicJson $summaryPath $summary
if (-not $environmentRestoredAtExit) { throw 'Package toolchain control failed to restore the process environment' }
if ($unexpected -or $summary.status -cne 'PASS' -or $cases.Count -ne 6) {
    throw "Package toolchain context controls failed; inspect persisted evidence at $ReceiptDir"
}
Write-Host 'PACKAGE_TOOLCHAIN_CONTEXT_CONTROL=PASS'
