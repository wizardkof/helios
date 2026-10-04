param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ReceiptDir
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Import-Module (Join-Path $PSScriptRoot 'CIToolchainReceipts.psm1') -Force
$pin = (Get-Content (Join-Path $PSScriptRoot 'ci-toolchain-pins.json') -Raw | ConvertFrom-Json).ninjaUpstream
$selected = $null
New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
$root = Join-Path $env:RUNNER_TEMP 'ninja-consumer-control'
$source = Join-Path $root 'source'
$poison = Join-Path $root 'poison'
$mesonBuild = Join-Path $root 'meson-build'
$cmakeBuild = Join-Path $root 'cmake-build'
$poisonLog = Join-Path $root 'implicit-ninja-was-used.txt'
$receipt = [ordered]@{
    schemaVersion = 1
    status = 'FAIL'
    selectedNinja = $null
    selectedNinjaSha256 = $null
    selectedNinjaVersion = $null
    vsImports = @()
    childProcess = $null
    meson = [ordered]@{ setup = $null; compile = $null; reconfigure = $null; recompile = $null; logNamesSelectedNinja = $false }
    cmake = [ordered]@{ configure = $null; cacheMakeProgram = $null; initialBuild = $null; regeneratedBuild = $null }
    poisonPathUsed = $false
    error = $null
}
$oldPath = $env:PATH
$oldNinja = $env:NINJA
$oldMesonLock = $env:HELIOS_MESON_LOCK_ROOT
try {
    if (-not $env:HELIOS_NINJA) { throw 'No approved Ninja path was published to this job.' }
    $selected = [IO.Path]::GetFullPath($env:HELIOS_NINJA)
    $receipt.selectedNinja = $selected
    $selectedRoot = [IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP 'helios-tools/ninja-1.13.2')).TrimEnd('\') + '\'
    if (-not $selected.StartsWith($selectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Selected Ninja is outside the controlled tool directory.'
    }
    $receipt.selectedNinjaSha256 = (Get-FileHash -LiteralPath $selected -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($receipt.selectedNinjaSha256 -ne $pin.executableSha256) { throw 'Selected Ninja executable hash differs from the official release pin.' }
    $probe = Invoke-CIToolCheck -Name 'ninja.exe' -Arguments @('--version') -ExpectedVersion $pin.executableVersion -VersionPattern ('^' + [regex]::Escape($pin.executableVersion) + '$') -Phase 'synthetic-consumer-selection'
    $receipt.selectedNinjaVersion = $probe.observedVersion
    if ($probe.status -ne 'PASS' -or [IO.Path]::GetFullPath($probe.path) -cne $selected) { throw "PATH does not resolve the selected Ninja: $($probe | ConvertTo-Json -Compress)" }

    foreach ($architecture in @('x64', 'x86', 'x64', 'x86', 'x64')) {
        Import-VisualStudioEnvironment -Architecture $architecture
        $resolved = Get-Command ninja.exe -ErrorAction Stop
        $path = [IO.Path]::GetFullPath($resolved.Path)
        $versionText = @(& $selected --version 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
        $exit = $LASTEXITCODE
        $row = [pscustomobject]@{ architecture = $architecture; resolvedPath = $path; selectedPath = $selected; version = $versionText; exitCode = $exit; status = if ($path -ceq $selected -and $exit -eq 0 -and $versionText.Trim() -ceq $pin.executableVersion) { 'PASS' } else { 'FAIL' } }
        $receipt.vsImports += $row
        if ($row.status -ne 'PASS') { throw "VS $architecture import changed the selected Ninja identity." }
    }

    # Confirm a fresh PowerShell child inherits and executes the selected path.
    $env:NINJA = $selected
    $env:HELIOS_NINJA_TEST_EXPECTED = $selected
    $childCode = "`$exe = [IO.Path]::GetFullPath(`$env:NINJA); `$out = @(& `$exe --version 2>&1); `$exit = `$LASTEXITCODE; Write-Output (`$exe + '|' + (`$out -join ' ') + '|' + `$exit); if (`$exe -cne [IO.Path]::GetFullPath(`$env:HELIOS_NINJA_TEST_EXPECTED) -or `$exit -ne 0 -or (`$out -join '').Trim() -cne '$($pin.executableVersion)') { exit 51 }; exit 0"
    $global:LASTEXITCODE = $null
    $childOutput = @(& pwsh.exe -NoLogo -NoProfile -Command $childCode 2>&1 | ForEach-Object { $_.ToString() })
    $childExit = [int]$LASTEXITCODE
    $receipt.childProcess = [pscustomobject]@{ output = $childOutput -join "`n"; exitCode = $childExit; selectedPath = $selected; status = if ($childExit -eq 0) { 'PASS' } else { 'FAIL' } }
    if ($childExit -ne 0) { throw 'A child PowerShell did not execute the selected Ninja path.' }

    New-Item -ItemType Directory -Force -Path $source, $poison | Out-Null
    $env:HELIOS_NINJA_POISON_LOG = $poisonLog
    @('@echo NINJA_PATH_POISON_USED>>"%HELIOS_NINJA_POISON_LOG%"', '@exit /b 97') | Set-Content -LiteralPath (Join-Path $poison 'ninja.cmd') -Encoding ascii
    $env:PATH = "$poison;$env:PATH"
    $env:NINJA = $selected
    $env:HELIOS_MESON_LOCK_ROOT = Join-Path $root 'meson-locks'
    @("project('helios-ninja-preflight', 'c')", "executable('hello', 'hello.c')") | Set-Content -LiteralPath (Join-Path $source 'meson.build') -Encoding utf8
    'int main(void) { return 0; }' | Set-Content -LiteralPath (Join-Path $source 'hello.c') -Encoding ascii
    @('cmake_minimum_required(VERSION 3.20)', 'project(HeliosNinjaPreflight C)', 'add_executable(hello hello.c)') | Set-Content -LiteralPath (Join-Path $source 'CMakeLists.txt') -Encoding ascii

    $meson = Join-Path $PSScriptRoot 'meson-isolated.py'
    $global:LASTEXITCODE = $null
    & python.exe $meson setup --backend=ninja $mesonBuild $source
    $receipt.meson.setup = [int]$LASTEXITCODE
    if ($receipt.meson.setup -ne 0) { throw 'Synthetic Meson setup failed.' }
    $global:LASTEXITCODE = $null
    & python.exe $meson compile -C $mesonBuild
    $receipt.meson.compile = [int]$LASTEXITCODE
    if ($receipt.meson.compile -ne 0) { throw 'Synthetic Meson compile failed.' }
    $global:LASTEXITCODE = $null
    & python.exe $meson setup --reconfigure $mesonBuild $source
    $receipt.meson.reconfigure = [int]$LASTEXITCODE
    if ($receipt.meson.reconfigure -ne 0) { throw 'Synthetic Meson reconfiguration failed.' }
    $global:LASTEXITCODE = $null
    & python.exe $meson compile -C $mesonBuild
    $receipt.meson.recompile = [int]$LASTEXITCODE
    if ($receipt.meson.recompile -ne 0) { throw 'Synthetic Meson compile after reconfiguration failed.' }
    $mesonLog = Get-Content -LiteralPath (Join-Path $mesonBuild 'meson-logs/meson-log.txt') -Raw
    $receipt.meson.logNamesSelectedNinja = $mesonLog.Contains($selected) -or $mesonLog.Contains($selected.Replace('\', '/'))
    if (-not $receipt.meson.logNamesSelectedNinja) { throw 'Meson log does not identify the selected Ninja executable.' }

    $global:LASTEXITCODE = $null
    & cmake.exe -S $source -B $cmakeBuild -G Ninja "-DCMAKE_MAKE_PROGRAM:FILEPATH=$selected"
    $receipt.cmake.configure = [int]$LASTEXITCODE
    if ($receipt.cmake.configure -ne 0) { throw 'Synthetic CMake configure failed.' }
    $cache = Join-Path $cmakeBuild 'CMakeCache.txt'
    $cacheRow = Get-Content -LiteralPath $cache | Where-Object { $_ -match '^CMAKE_MAKE_PROGRAM:FILEPATH=' } | Select-Object -First 1
    $cacheValue = if ($cacheRow) { $cacheRow.Substring($cacheRow.IndexOf('=') + 1) } else { '' }
    $receipt.cmake.cacheMakeProgram = $cacheValue
    if (-not $cacheValue -or [IO.Path]::GetFullPath($cacheValue) -cne $selected) { throw "CMake cache does not pin selected Ninja: $cacheValue" }
    $global:LASTEXITCODE = $null
    & cmake.exe --build $cmakeBuild --parallel 1
    $receipt.cmake.initialBuild = [int]$LASTEXITCODE
    if ($receipt.cmake.initialBuild -ne 0) { throw 'Synthetic CMake build failed.' }
    Add-Content -LiteralPath (Join-Path $source 'CMakeLists.txt') -Value '# force regeneration' -Encoding ascii
    $global:LASTEXITCODE = $null
    & cmake.exe --build $cmakeBuild --parallel 1
    $receipt.cmake.regeneratedBuild = [int]$LASTEXITCODE
    if ($receipt.cmake.regeneratedBuild -ne 0) { throw 'Synthetic CMake regeneration/build failed.' }
    if (Test-Path -LiteralPath $poisonLog) { throw 'A generator resolved Ninja implicitly from PATH instead of using the pinned executable.' }
    $receipt.status = 'PASS'
} catch {
    $receipt.error = $_.Exception.Message
} finally {
    $receipt.poisonPathUsed = Test-Path -LiteralPath $poisonLog
    $env:PATH = $oldPath
    $env:NINJA = $oldNinja
    $env:HELIOS_MESON_LOCK_ROOT = $oldMesonLock
    $path = Join-Path $ReceiptDir 'ninja-consumer-tests.json'
    $temporary = "$path.tmp"
    ConvertTo-Json -InputObject $receipt -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $path -Force
}
Write-Host (ConvertTo-Json -InputObject $receipt -Depth 12)
if ($receipt.status -ne 'PASS') { throw "Ninja consumer controls failed: $($receipt.error)" }
