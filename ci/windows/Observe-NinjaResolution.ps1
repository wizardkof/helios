param(
    [Parameter(Mandatory)][string]$Phase,
    [Parameter(Mandatory)][string]$ReceiptDir
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
$receiptPath = Join-Path $ReceiptDir 'ninja-resolution.json'
$history = if (Test-Path -LiteralPath $receiptPath) {
    @(Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json)
} else { @() }

function Get-NinjaCandidate([string]$Path, [string]$CommandType, [string]$RequestedName) {
    $row = [ordered]@{
        requestedName = $RequestedName
        commandType = $CommandType
        path = $Path
        version = $null
        exitCode = $null
        size = $null
        sha256 = $null
        status = 'NOT_OBSERVED'
        error = $null
    }
    if (-not $Path -or -not [IO.Path]::IsPathRooted($Path)) {
        $row.error = 'RESOLUTION_DID_NOT_PRODUCE_ABSOLUTE_PATH'
        return [pscustomobject]$row
    }
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (-not $file.PSIsContainer) {
            $row.size = $file.Length
            $row.sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        }
    } catch {
        $row.error = 'FILE_READ: ' + $_.Exception.Message
    }
    try {
        $global:LASTEXITCODE = $null
        $output = @(& $Path '--version' 2>&1 | ForEach-Object { $_.ToString() })
        $row.exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $row.version = $output -join "`n"
        $row.status = if ($row.exitCode -eq 0 -and -not $row.error) { 'OBSERVED' } else { 'FAIL' }
        if ($row.exitCode -ne 0) { $row.error = 'EXECUTION_EXIT_NONZERO' }
    } catch {
        $row.status = 'FAIL'
        $row.error = 'EXECUTION: ' + $_.Exception.Message
        if ($null -eq $row.exitCode) { $row.exitCode = -1 }
    }
    return [pscustomobject]$row
}

$commands = @()
foreach ($name in @('ninja', 'ninja.exe')) {
    try {
        foreach ($command in @(Get-Command -Name $name -All -ErrorAction Stop)) {
            $path = if ($command.CommandType -eq 'Application') { $command.Path } else { $command.Source }
            $commands += [pscustomobject]@{ Name = $name; Type = [string]$command.CommandType; Path = [string]$path }
        }
    } catch {
        $commands += [pscustomobject]@{ Name = $name; Type = 'NOT_RESOLVED'; Path = ''; Error = $_.Exception.Message }
    }
}

$wherePaths = @()
foreach ($name in @('ninja.exe', 'ninja')) {
    try {
        $global:LASTEXITCODE = $null
        $lines = @(& where.exe $name 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $wherePaths += [pscustomobject]@{ requestedName = $name; exitCode = $exitCode; paths = @($lines | Where-Object { $_ -and [IO.Path]::IsPathRooted($_) }) }
    } catch {
        $wherePaths += [pscustomobject]@{ requestedName = $name; exitCode = -1; paths = @(); error = $_.Exception.Message }
    }
}

$candidateRows = @()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($command in $commands) {
    if ($command.Path -and $seen.Add($command.Path)) {
        $candidateRows += Get-NinjaCandidate $command.Path $command.Type $command.Name
    }
}
foreach ($where in $wherePaths) {
    foreach ($path in $where.paths) {
        if ($seen.Add($path)) { $candidateRows += Get-NinjaCandidate $path 'where.exe' $where.requestedName }
    }
}

$pythonDistribution = $null
try {
    $pythonCode = @'
import hashlib, importlib.metadata as m, json, os, sysconfig
try:
    d = m.distribution("ninja")
except m.PackageNotFoundError:
    print(json.dumps({"status":"NOT_INSTALLED"}))
    raise SystemExit(0)
scripts = os.path.normcase(os.path.abspath(sysconfig.get_path("scripts")))
files = []
for item in d.files or []:
    relative = str(item).replace("\\", "/")
    path = str(d.locate_file(item))
    if ".data/scripts/" in relative:
        path = os.path.join(scripts, relative.split(".data/scripts/", 1)[1].replace("/", os.sep))
    row = {"distributionPath": relative, "installedPath": path, "exists": os.path.isfile(path), "size": None, "sha256": None}
    if row["exists"]:
        row["size"] = os.path.getsize(path)
        h = hashlib.sha256()
        with open(path, "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""): h.update(block)
        row["sha256"] = h.hexdigest()
    files.append(row)
print(json.dumps({"status":"OBSERVED", "distribution":"ninja", "metadataVersion":d.version,
    "metadataName":d.metadata.get("Name"), "entryPoints":[{"name":e.name,"value":e.value} for e in d.entry_points],
    "files":files}, sort_keys=True))
'@
    $pythonOutput = @(& python.exe -c $pythonCode 2>&1 | ForEach-Object { $_.ToString() })
    $pythonExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($pythonExit -ne 0) { throw "python metadata inspection exit=$pythonExit output=$($pythonOutput -join "`n")" }
    $pythonDistribution = ($pythonOutput -join "`n") | ConvertFrom-Json
} catch {
    $pythonDistribution = [pscustomobject]@{ status = 'NOT_OBSERVED'; error = $_.Exception.Message }
}

foreach ($candidate in $candidateRows) {
    $owners = @()
    if ($candidate.path -and $pythonDistribution.files) {
        $owners = @($pythonDistribution.files | Where-Object {
            $_.installedPath -and [string]::Equals([IO.Path]::GetFullPath($_.installedPath), [IO.Path]::GetFullPath($candidate.path), [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { [pscustomobject]@{ distribution = $pythonDistribution.distribution; metadataVersion = $pythonDistribution.metadataVersion; distributionPath = $_.distributionPath; fileSha256 = $_.sha256 } })
    }
    $candidate | Add-Member -NotePropertyName pythonDistributionOwners -NotePropertyValue $owners -Force
}

$row = [ordered]@{
    phase = $Phase
    observedAtUtc = [DateTime]::UtcNow.ToString('o')
    commandResolution = $commands
    whereExe = $wherePaths
    candidates = $candidateRows
    pythonNinjaDistribution = $pythonDistribution
    pathEntries = @($env:PATH -split ';' | Where-Object { $_ })
}
$history += [pscustomobject]$row
$temporary = "$receiptPath.tmp"
ConvertTo-Json -InputObject $history -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
Move-Item -LiteralPath $temporary -Destination $receiptPath -Force
Write-Host "NINJA_OBSERVATION_PHASE=$Phase"
Write-Host (ConvertTo-Json -InputObject $row -Depth 12)
