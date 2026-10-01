param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$OutputDir,
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ($RepoRoot -notmatch '^[Cc]:\\') { throw 'Build requires a local C: checkout.' }
if (Test-Path -LiteralPath $OutputDir) { throw 'OutputDir must be fresh; preserve prior artifacts.' }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
Start-Transcript -Path (Join-Path $OutputDir 'build-transcript.txt') | Out-Null
try {
    Import-VisualStudioEnvironment -Architecture x64
    # VS environment prepends its bundled LLVM; select the pinned installation explicitly.
    $clang = Join-Path $env:LLVM_PATH 'bin/clang-cl.exe'
    if (-not (Test-Path -LiteralPath $clang)) { throw 'Pinned LLVM executable missing.' }
    $stampInf = Find-WindowsKitTool 'stampinf.exe'
    $env:LIBCLANG_PATH = Split-Path -Parent $clang
    $env:PATH = "$(Split-Path -Parent $stampInf);$env:PATH"
    $env:CC = $clang
    $env:CXX = $clang
    $env:RUSTUP_TOOLCHAIN = 'nightly-2026-07-14'
    $env:HELIOS_WDK_INCLUDE = Find-WindowsKitInclude
    $clangVersion = (& $clang --version) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $clangVersion -notmatch '22\.1\.8') { throw "LLVM 22.1.8 is required: path=$clang; output=$clangVersion" }
    $source = (& git -C $RepoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve source identity.' }
    $mesa = (& git -C $RepoRoot rev-parse 'HEAD:icd/mesa').Trim()
    if ($LASTEXITCODE -ne 0 -or $mesa -ne 'c7c76a293460a3281b4207c21f5b0d80f8157921') { throw 'Qualified transport Mesa gitlink mismatch.' }
    $version = (Get-Content (Join-Path $RepoRoot 'kmd_render/driver-version.env') | Where-Object { $_ -match '^HELIOS_KMD_VERSION=' }) -replace '^HELIOS_KMD_VERSION=', ''
    if ($version -ne '22.22.292.0') { throw 'Unexpected diagnostic KMD version.' }
    $profile = if ($Configuration -eq 'Debug') { 'dev' } else { 'release' }
    $profileDir = if ($Configuration -eq 'Debug') { 'debug' } else { 'release' }
    # These pure crates exercise real protocol and KMD logic on Windows.
    foreach ($crate in @('protocol', 'kmd_logic')) {
        $env:CARGO_TARGET_DIR = Join-Path $RepoRoot "$crate/target"
        & cargo.exe test --manifest-path (Join-Path $RepoRoot "$crate/Cargo.toml") --profile $profile
        if ($LASTEXITCODE -ne 0) { throw "$crate tests failed." }
    }
    $kmd = Join-Path $RepoRoot 'kmd_render'
    $env:CARGO_TARGET_DIR = Join-Path $kmd 'target'
    # Match Build-Driver's short rust-script cache path, restoring it on failure.
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $oldCache = Get-ItemPropertyValue -LiteralPath $key -Name 'Local AppData'
    $oldEnvCache = $env:LOCALAPPDATA
    New-Item -ItemType Directory -Force -Path 'C:\la' | Out-Null
    Push-Location $kmd
    try {
        Set-ItemProperty -LiteralPath $key -Name 'Local AppData' -Value 'C:\la'
        $env:LOCALAPPDATA = 'C:\la'
        # Explicit build stops before package-driver-flow. Default packaging
        # reaches copy-umd-to-package and must never be used for this workflow.
        & cargo.exe make --profile $profile --makefile Cargo.make.toml build
        if ($LASTEXITCODE -ne 0) { throw 'KMD build failed.' }
        & cargo.exe make --profile $profile --makefile Cargo.make.toml verify-no-panics
        if ($LASTEXITCODE -ne 0) { throw 'KMD panic guard failed.' }
    } finally {
        Pop-Location
        Set-ItemProperty -LiteralPath $key -Name 'Local AppData' -Value $oldCache
        $env:LOCALAPPDATA = $oldEnvCache
    }
    $compiled = Join-Path $kmd "target/$profileDir"
    # Same DLL-to-SYS copy as wdk-build generate-driver-binary-file. No signing
    # here: the guest canonical installer finalizes images before its catalog.
    Copy-Item -LiteralPath (Join-Path $compiled 'helios_kmd_render.dll') -Destination (Join-Path $OutputDir 'helios_kmd_render.sys')
    Copy-Item -LiteralPath (Join-Path $compiled 'helios_kmd_render.pdb') -Destination $OutputDir
    $maps = @(foreach ($subdir in @('deps', 'build')) {
        Get-ChildItem -LiteralPath (Join-Path $compiled $subdir) -Filter 'helios_kmd_render.map' -File -Recurse
    })
    $map = $maps | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $map) { throw 'KMD linker map missing.' }
    Copy-Item -LiteralPath $map.FullName -Destination $OutputDir
    $inf = Join-Path $OutputDir 'helios_kmd_render.inf'
    Copy-Item -LiteralPath (Join-Path $kmd 'helios_kmd_render.inx') -Destination $inf
    & $stampInf -f $inf -d '*' -a amd64 -c helios_kmd_render.cat -v $version
    if ($LASTEXITCODE -ne 0) { throw 'StampInf failed.' }
    $peVersion = (Get-Item (Join-Path $OutputDir 'helios_kmd_render.sys')).VersionInfo.FileVersion
    if ($peVersion -ne $version) { throw "KMD FILEVERSION mismatch: $peVersion" }
    $dependencies = (& cargo.exe tree --manifest-path (Join-Path $kmd 'Cargo.toml')) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $dependencies -match 'bindgen v0\.(70|71)\.' -or $dependencies -notmatch 'bindgen v0\.72\.') { throw 'bindgen dependency floor failed.' }
    $dependencies | Set-Content (Join-Path $OutputDir 'dependencies.txt')
    Copy-Item -LiteralPath (Join-Path $kmd 'Cargo.lock') -Destination (Join-Path $OutputDir 'kmd-Cargo.lock')
    $files = @(Get-ChildItem -LiteralPath $OutputDir -File | Where-Object Name -ne 'build-transcript.txt' | ForEach-Object {
        [ordered]@{ name = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    [ordered]@{
        source_sha = $source; configuration = $Configuration; driver_version = $version
        preserved_mesa_gitlink = $mesa; qualification = 'WINDOWS_BUILD_AND_PURE_TESTS_ONLY'
        signed = $false; catalog = 'NOT_CREATED'; guest_activation = 'NOT_RUN'
        identity_note = 'Versioned ATTEST KMD/INF .292; reuse qualified .290 UMDs without rebuilding. Record any canonical re-signing separately. Source SHA and SYS hash identify this KMD.'
        rustc = ((& rustc.exe --version) -join "`n"); cargo = ((& cargo.exe --version) -join "`n")
        clang = $clangVersion; libclang = (Get-Item (Join-Path $env:LIBCLANG_PATH 'libclang.dll')).VersionInfo.FileVersion
        wdk_include = $env:HELIOS_WDK_INCLUDE; stampinf = $stampInf
        stampinf_sha256 = (Get-FileHash -LiteralPath $stampInf -Algorithm SHA256).Hash
        map_source = $map.FullName; files = $files
    } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutputDir 'manifest.json') -Encoding utf8
} finally {
    Stop-Transcript | Out-Null
}
Get-ChildItem -LiteralPath $OutputDir -File | Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($_.Path))" } |
    Set-Content (Join-Path $OutputDir 'SHA256SUMS') -Encoding ascii
