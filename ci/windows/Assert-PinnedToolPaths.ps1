param([Parameter(Mandatory)][string]$ReceiptDir)
$ErrorActionPreference = 'Stop'
$pins = Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json
$checks = [Collections.Generic.List[object]]::new()
function Test-Exact([string]$Name, [AllowEmptyString()][string]$Path, [string[]]$Arguments, [string]$Pattern) {
    $row = [ordered]@{name=$Name;path=$Path;expectedPattern=$Pattern;observed=$null;exitCode=$null;size=$null;sha256=$null;status='NOT_OBSERVED';error=$null}
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw 'PINNED_PATH_NOT_SELECTED' }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'PINNED_FILE_MISSING' }
        $file = Get-Item -LiteralPath $Path
        $row.size = [long]$file.Length
        $row.sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        $global:LASTEXITCODE = $null
        $out = @(& $Path @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $row.exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $row.observed = $out -join "`n"
        $row.status = if ($row.exitCode -eq 0 -and $row.observed -match $Pattern) { 'PASS' } else { 'FAIL' }
        if ($row.status -eq 'FAIL') { $row.error = 'VERSION_OR_EXIT_MISMATCH' }
    } catch { $row.status='FAIL'; $row.error=$_.Exception.Message; if ($null -eq $row.exitCode) { $row.exitCode=-1 } }
    $checks.Add([pscustomobject]$row)
}
Test-Exact 'Ninja' $(if ($env:HELIOS_NINJA) { [string]$env:HELIOS_NINJA } else { 'NOT_SELECTED' }) @('--version') ('^' + [regex]::Escape($pins.ninjaUpstream.executableVersion) + '$')
$llvmExe = if ($env:HELIOS_LLVM_BIN) { Join-Path $env:HELIOS_LLVM_BIN 'clang-cl.exe' } else { 'NOT_SELECTED' }
Test-Exact 'LLVM clang-cl' $llvmExe @('--version') ('(?m)^clang version ' + [regex]::Escape($pins.llvmVersion) + '(?:\s|$)')
Test-Exact 'WIDL' $(if ($env:HELIOS_WIDL) { [string]$env:HELIOS_WIDL } else { 'NOT_SELECTED' }) @('-V') ('(?m)^Wine IDL Compiler version ' + [regex]::Escape($pins.qualifiedObservedTools.widlVersion) + '(?![0-9.])')
$vulkanRoot = [string]$env:VULKAN_SDK
$vulkanHeader = if ($vulkanRoot) { Join-Path $vulkanRoot 'Include/vulkan/vulkan.h' } else { $null }
$vulkanLib = if ($vulkanRoot) { Join-Path $vulkanRoot 'Lib/vulkan-1.lib' } else { $null }
$vulkanPass = $false
if ($vulkanRoot) { $vulkanPass = (Split-Path $vulkanRoot -Leaf) -ceq $pins.vulkanSdkVersion -and (Test-Path -LiteralPath $vulkanHeader -PathType Leaf) -and (Test-Path -LiteralPath $vulkanLib -PathType Leaf) }
$checks.Add([pscustomobject]@{name='Vulkan SDK';path=$vulkanRoot;header=$vulkanHeader;library=$vulkanLib;expectedVersion=$pins.vulkanSdkVersion;status=if($vulkanPass){'PASS'}else{'FAIL'};error=if($vulkanPass){$null}else{'SDK_ROOT_OR_FILES_MISMATCH'}})
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
$receipt=[ordered]@{schemaVersion=1;generatedAtUtc=[DateTime]::UtcNow.ToString('o');status=if(@($checks|Where-Object status -ne 'PASS').Count -eq 0){'PASS'}else{'FAIL'};checks=@($checks.ToArray())}
$path=Join-Path $ReceiptDir 'pinned-tool-paths.json'
ConvertTo-Json -InputObject $receipt -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host (ConvertTo-Json -InputObject $receipt -Depth 10)
if($receipt.status -ne 'PASS'){throw "Pinned tool path gate failed; receipt=$path"}
