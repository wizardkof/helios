[CmdletBinding()]
param(
    [ValidateSet('Build', 'Run', 'Schedule')][string]$Mode = 'Build',
    [ValidateSet('D3D11Create', 'D3D12Create')][string]$Suite = 'D3D11Create',
    [ValidateSet('x86', 'x64')][string]$Arch = 'x64',
    [string]$Out,
    [string]$Adapter = 'Helios',
    [string]$AdapterLuid,
    [string]$ExpectedSourceSha,
    [int]$TimeoutSeconds = 120,
    [string]$BuildRoot = $env:HELIOS_FULLSTACK_WINDOWS_BUILD_ROOT
)

$ErrorActionPreference = 'Stop'
$SourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$ArtifactRoot = [IO.Path]::GetFullPath((Join-Path $SourceRoot '.fullstack/artifacts'))
if (-not $Out) { $Out = Join-Path $ArtifactRoot ("p02/{0}-{1}" -f $Suite, $Arch) }
$Out = [IO.Path]::GetFullPath($Out)
if (-not $Out.StartsWith($ArtifactRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Out must remain under $ArtifactRoot"
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null

$SourceFiles = @(
    'tools/fullstack/CMakeLists.txt', 'tools/fullstack/probe_common.h',
    'tools/fullstack/Run-Suite.ps1', 'tools/fullstack/Build-Windows.ps1',
    'tools/d3d11_devicecreate_probe.cpp', 'tools/d3d12_devicecreate_probe.cpp'
)
$SourceHashes = [ordered]@{}
foreach ($relative in $SourceFiles) {
    $path = Join-Path $SourceRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing source input: $relative" }
    $SourceHashes[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}
$SourceSha = ($SourceHashes.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
$shaBytes = [Text.Encoding]::UTF8.GetBytes($SourceSha)
$sha = [Security.Cryptography.SHA256]::Create()
try { $SourceFingerprint = ([BitConverter]::ToString($sha.ComputeHash($shaBytes))).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose() }
if ($ExpectedSourceSha -and $ExpectedSourceSha.ToLowerInvariant() -ne $SourceFingerprint) {
    throw "Source fingerprint mismatch: expected $ExpectedSourceSha, observed $SourceFingerprint"
}

$Target = if ($Arch -eq 'x86') { 'Win32' } else { 'x64' }
$TargetName = if ($Suite -eq 'D3D11Create') { 'd3d11_create_probe' } else { 'd3d12_create_probe' }
$ExeName = if ($Suite -eq 'D3D11Create') { 'd3d11_create_probe.exe' } else { 'd3d12_create_probe.exe' }
if (-not $BuildRoot) { $BuildRoot = Join-Path $env:LOCALAPPDATA 'Helios/FullStack/build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if ([IO.Path]::GetPathRoot($BuildRoot) -ne 'C:\') { throw "Windows build outputs must be on local C: storage: $BuildRoot" }
$BuildDir = Join-Path $BuildRoot $Arch
$Exe = Join-Path $BuildDir ("bin/{0}" -f $ExeName)
$Log = Join-Path $Out "$Suite-$Arch.log"
$receiptPath = Join-Path $Out 'receipt.json'

$receipt = [ordered]@{
    schema_version = 1
    task = 'P02'
    mode = $Mode
    suite = $Suite
    arch = $Arch
    source_root = $SourceRoot
    source_fingerprint = $SourceFingerprint
    source_hashes = $SourceHashes
    adapter_requested = $Adapter
    adapter_luid_requested = $AdapterLuid
    output_log = $Log
    result = 'NOT_RUN'
}

if ($Mode -eq 'Schedule') {
    $taskName = "Helios-FullStack-$Suite-$Arch"
    & schtasks.exe /run /tn $taskName 2>&1 | Tee-Object -FilePath $Log
    if ($LASTEXITCODE -ne 0) { $receipt.result = 'FAIL'; $receipt.exit_code = $LASTEXITCODE }
    else { $receipt.result = 'SCHEDULED'; $receipt.task_name = $taskName }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $receiptPath
    if ($receipt.result -ne 'SCHEDULED') { exit $receipt.exit_code }
    Write-Output "RECEIPT=$receiptPath"
    exit 0
}

if ($Mode -eq 'Build') {
    $configureLog = Join-Path $Out 'cmake-configure.log'
    $buildLog = Join-Path $Out 'cmake-build.log'
    & cmake -S (Join-Path $SourceRoot 'tools/fullstack') -B $BuildDir -A $Target 2>&1 | Tee-Object -FilePath $configureLog
    if ($LASTEXITCODE -ne 0) { $receipt.result = 'FAIL'; $receipt.exit_code = $LASTEXITCODE }
    else {
        & cmake --build $BuildDir --config Release --target $TargetName 2>&1 | Tee-Object -FilePath $buildLog
        if ($LASTEXITCODE -ne 0) { $receipt.result = 'FAIL'; $receipt.exit_code = $LASTEXITCODE }
        elseif (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { $receipt.result = 'FAIL'; $receipt.error = 'Expected executable missing' }
        else {
            $receipt.result = 'PASS'
            $receipt.executable = $Exe
            $receipt.executable_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Exe).Hash.ToLowerInvariant()
        }
    }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $receiptPath
    Write-Output "RECEIPT=$receiptPath"
    if ($receipt.result -ne 'PASS') { exit 1 }
    exit 0
}

if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "Probe executable not found: $Exe. Run Mode Build for $Arch first." }
$sessionId = (Get-Process -Id $PID).SessionId
$receipt.session_id = $sessionId
if ($sessionId -eq 0) { throw 'Refusing desktop/GPU validation from session 0.' }
$stderrLog = Join-Path $Out "$Suite-$Arch.stderr.log"
$arguments = @()
if ($Suite -eq 'D3D12Create') { $arguments = @('--expect', 'ok') }
$proc = Start-Process -FilePath $Exe -ArgumentList $arguments -PassThru -NoNewWindow `
    -RedirectStandardOutput $Log -RedirectStandardError $stderrLog
if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    $receipt.result = 'TIMEOUT'
    $receipt.exit_code = 124
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $receiptPath
    Write-Output "RECEIPT=$receiptPath"
    exit 124
}
$proc.Refresh()
$receipt.exit_code = $proc.ExitCode
$stdout = if (Test-Path -LiteralPath $Log) { Get-Content -Raw -LiteralPath $Log } else { '' }
$stderr = if (Test-Path -LiteralPath $stderrLog) { Get-Content -Raw -LiteralPath $stderrLog } else { '' }
if ($proc.ExitCode -ne 0) { $receipt.result = 'FAIL'; $receipt.error = 'Probe returned nonzero' }
elseif ([string]::IsNullOrWhiteSpace($stdout)) { $receipt.result = 'FAIL'; $receipt.error = 'Probe stdout is empty' }
else {
    $match = [regex]::Match($stdout, '(?m)^HELIOS_PROBE_RESULT=(\{[^\r\n]+\})\s*$')
    if (-not $match.Success) { $receipt.result = 'FAIL'; $receipt.error = 'Structured probe receipt missing or truncated' }
    else {
        try { $probe = $match.Groups[1].Value | ConvertFrom-Json }
        catch { $probe = $null }
        if (-not $probe -or $probe.schema_version -ne 1 -or $probe.api -ne $(if ($Suite -eq 'D3D11Create') { 'D3D11' } else { 'D3D12' })) {
            $receipt.result = 'FAIL'; $receipt.error = 'Structured probe receipt invalid'
        } elseif ($probe.adapter -notlike "*$Adapter*") {
            $receipt.result = 'FAIL'; $receipt.error = 'Observed adapter differs from requested adapter'
        } elseif ($AdapterLuid -and $probe.luid -ne $AdapterLuid) {
            $receipt.result = 'FAIL'; $receipt.error = 'Observed LUID differs from requested LUID'
        } elseif (-not $probe.created) {
            $receipt.result = 'FAIL'; $receipt.error = 'Direct3D device creation failed'
        } else {
            $receipt.result = 'PASS'
            $receipt.observed = $probe
            $receipt.stderr_empty = [string]::IsNullOrWhiteSpace($stderr)
            $receipt.executable_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Exe).Hash.ToLowerInvariant()
        }
    }
}
$receipt | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $receiptPath
Write-Output "RECEIPT=$receiptPath"
if ($receipt.result -ne 'PASS') { exit 1 }
exit 0
