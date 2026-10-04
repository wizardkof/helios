Set-StrictMode -Version Latest

function Invoke-CIToolCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$VersionPattern,
        [string]$Phase = 'pre',
        [string]$ExecutablePath,
        [string]$ExpectedResolvedPath
    )

    $row = [ordered]@{
        requestedName = $Name
        phase = $Phase
        commandType = $null
        path = $null
        resolvedCommandType = $null
        resolvedPath = $null
        expectedVersion = $ExpectedVersion
        observedVersion = $null
        exitCode = $null
        size = $null
        sha256 = $null
        status = 'NOT_OBSERVED'
        error = $null
        resolutionCandidates = @()
    }

    try {
        $commands = if ($ExecutablePath) { @([pscustomobject]@{ CommandType='Application'; Path=$ExecutablePath; Source=$ExecutablePath }) } else { @(Get-Command -Name $Name -All -ErrorAction Stop) }
        $row.resolutionCandidates = @($commands | ForEach-Object {
            [ordered]@{
                commandType = [string]$_.CommandType
                path = if ($_.CommandType -eq 'Application') { [string]$_.Path } else { [string]$_.Source }
            }
        })
        $command = $commands | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
        if (-not $command) { $command = $commands | Select-Object -First 1 }
        $row.resolvedCommandType = [string]$command.CommandType
        $row.resolvedPath = if ($command.CommandType -eq 'Application') { [string]$command.Path } else { [string]$command.Source }
        $row.commandType = if ($ExecutablePath) { 'ExplicitPath' } else { $row.resolvedCommandType }
        $row.path = if ($ExecutablePath) { [IO.Path]::GetFullPath($ExecutablePath) } else { $row.resolvedPath }
        if (-not $row.path -or -not [IO.Path]::IsPathRooted($row.path)) {
            $row.status = 'NOT_OBSERVED'
            $row.error = 'RESOLUTION_DID_NOT_PRODUCE_ABSOLUTE_PATH'
            return [pscustomobject]$row
        }
        if ($ExpectedResolvedPath -and (-not $row.resolvedPath -or [IO.Path]::GetFullPath($row.resolvedPath) -ine [IO.Path]::GetFullPath($ExpectedResolvedPath))) {
            $row.status = 'FAIL'
            $row.error = "RESOLVED_PATH_MISMATCH: observed=$($row.resolvedPath) expected=$ExpectedResolvedPath"
        }
    } catch {
        $row.status = 'NOT_OBSERVED'
        $row.error = 'RESOLUTION: ' + $_.Exception.Message
        return [pscustomobject]$row
    }

    try {
        $file = Get-Item -LiteralPath $row.path -ErrorAction Stop
        if (-not $file.PSIsContainer) {
            $row.size = [long]$file.Length
            $row.sha256 = (Get-FileHash -LiteralPath $row.path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        }
    } catch {
        $row.error = 'FILE_READ: ' + $_.Exception.Message
    }

    try {
        $global:LASTEXITCODE = $null
        $output = @(& $row.path @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $row.exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $row.observedVersion = $output -join "`n"
        if ($row.exitCode -ne 0) {
            $row.status = 'FAIL'
            $row.error = if ($row.error) { $row.error + '; EXECUTION_EXIT_NONZERO' } else { 'EXECUTION_EXIT_NONZERO' }
        } elseif ($row.observedVersion -notmatch $VersionPattern) {
            $row.status = 'FAIL'
            $row.error = if ($row.error) { $row.error + '; VERSION_MISMATCH' } else { 'VERSION_MISMATCH' }
        } elseif ($row.error) {
            $row.status = 'FAIL'
        } else {
            $row.status = 'PASS'
        }
    } catch {
        $row.status = 'FAIL'
        $row.exitCode = -1
        $row.error = if ($row.error) { $row.error + '; EXECUTION: ' + $_.Exception.Message } else { 'EXECUTION: ' + $_.Exception.Message }
    }
    return [pscustomobject]$row
}

function New-CIToolReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Checks,
        [object[]]$Blocked = @(),
        [hashtable]$Context = @{}
    )
    $failed = @($Checks | Where-Object status -ne 'PASS')
    $status = if ($failed.Count -or @($Blocked).Count) { 'FAIL' } else { 'PASS' }
    [pscustomobject][ordered]@{
        schemaVersion = 1
        name = $Name
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        status = $status
        checks = @($Checks)
        blocked = @($Blocked)
        context = $Context
    }
}

function Write-CIToolReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Receipt)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $temporary = "$Path.tmp"
    ConvertTo-Json -InputObject $Receipt -Depth 20 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Assert-CIToolReceiptPass {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Receipt)
    if ($Receipt.status -ne 'PASS') {
        $failures = @($Receipt.checks | Where-Object status -ne 'PASS' | ForEach-Object { "$($_.requestedName)=$($_.status):$($_.error)" })
        $blockers = @($Receipt.blocked | ForEach-Object { "$($_.name)=BLOCKED:$($_.reason)" })
        throw "$($Receipt.name) toolchain gate failed: $(@($failures + $blockers) -join '; ')"
    }
}

Export-ModuleMember -Function Invoke-CIToolCheck, New-CIToolReceipt, Write-CIToolReceipt, Assert-CIToolReceiptPass
