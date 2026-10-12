param([ValidateSet('GuardOnly','FetchSource','PrepareMesa','InstallWdk','Typecheck')][string]$Mode)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = 'wizardkof/helios'
$branch = 'refs/heads/p06/z-native-e1-20261012'
$wantedCommit = 'b394606f467f7ee3c4ad2b27940237e2a6b655ea'
$wantedMesa = '0d7a48b022f707fa35cf4646d106a810003f712f'
$wantedPatchSha = '4b63c515ced0f1ae01ca02f918b65423221fba230239c21cb96ac16632c8c873'
$root = Join-Path $env:RUNNER_TEMP 'p06-z-gitlab-source'
$receipts = Join-Path $env:RUNNER_TEMP 'p06-z-receipts'
$patch = Join-Path $env:GITHUB_WORKSPACE '.ci-diagnostics/mesa-W.patch'

function Test-HostedIdentity {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REPOSITORY -cne $repo -or $env:GITHUB_REF -cne $branch) {
        throw 'P06_Z_FORBIDDEN_GITHUB_CONTEXT'
    }
    # This value comes from the platform's runner.environment context, not an arbitrary source variable.
    if ($env:ATTESTED_RUNNER_ENVIRONMENT -cne 'github-hosted') {
        throw 'P06_Z_SELF_HOSTED_RUNNER_DENIED'
    }
    if ($env:RUNNER_OS -cne 'Windows') { throw 'P06_Z_WINDOWS_REQUIRED' }
    $machine = [string]$env:COMPUTERNAME
    if ($machine -eq 'WIN-AD4HV3SPPT5') { throw 'P06_Z_ORIGINAL_WINBOAT_DENIED' }
    Write-Host "Z_RUNNER_ATTESTATION=PASS runner=$env:RUNNER_NAME machine=$machine hosted=$env:ATTESTED_RUNNER_ENVIRONMENT"
}

function Assert-CleanPinnedSource {
    if (-not (Test-Path -LiteralPath $root)) { throw 'P06_Z_GITLAB_SOURCE_ABSENT' }
    $got = ((& git -C $root rev-parse HEAD) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $got -cne $wantedCommit) { throw "P06_Z_GITLAB_SHA_MISMATCH got=$got" }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'kmd_render/Cargo.lock'))) { throw 'P06_Z_LEGITIMATE_KMD_CARGO_LOCK_MISSING' }
    Write-Host "Z_SOURCE_IDENTITY=PASS sha=$got"
}

Test-HostedIdentity
if ($Mode -eq 'GuardOnly') { return }
New-Item -ItemType Directory -Force -Path $receipts | Out-Null

if ($Mode -in @('FetchSource','PrepareMesa')) {
    if (Test-Path -LiteralPath $root) { throw 'P06_Z_SOURCE_DEST_ALREADY_EXISTS' }
    & git -c core.autocrlf=false clone --depth=1 --single-branch --branch 'p06/e1-native-x-diagnostic-20261011' 'https://gitlab.com/wizardkof/helios.git' $root
    if ($LASTEXITCODE -ne 0) { throw 'P06_Z_GITLAB_CLONE_FAILED' }
    Assert-CleanPinnedSource
    if ($Mode -eq 'PrepareMesa') {
        & git -C $root -c core.autocrlf=false submodule update --init icd/mesa
        if ($LASTEXITCODE -ne 0) { throw 'P06_Z_MESA_SUBMODULE_FAILED' }
        $mesa = Join-Path $root 'icd/mesa'
        $sha = ((& git -C $mesa rev-parse HEAD) -join '').Trim()
        if ($sha -cne $wantedMesa) { throw "P06_Z_MESA_PIN_MISMATCH got=$sha" }
        if (-not (Test-Path -LiteralPath $patch)) { throw 'P06_Z_MESA_PATCH_ABSENT' }
        $patchSha = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($patchSha -cne $wantedPatchSha) { throw 'P06_Z_MESA_PATCH_SHA_MISMATCH' }
        & git -C $mesa apply --check $patch
        if ($LASTEXITCODE -ne 0) { throw 'P06_Z_MESA_PATCH_CHECK_FAILED' }
        & git -C $mesa apply $patch
        if ($LASTEXITCODE -ne 0) { throw 'P06_Z_MESA_PATCH_APPLY_FAILED' }
        & git -C $mesa diff --check
        if ($LASTEXITCODE -ne 0) { throw 'P06_Z_MESA_PATCH_DIFF_INVALID' }
        Write-Host "Z_MESA_SOURCE=PASS pin=$sha patch=$patchSha"
    }
    return
}
Assert-CleanPinnedSource
if ($Mode -eq 'InstallWdk') {
    $kitDir = Join-Path $receipts 'windows-kit'
    & (Join-Path $root 'ci/windows/Install-WindowsDriverKit.ps1') -ReceiptDir $kitDir
    Write-Host 'Z_NATIVE_WINDOWS_KIT=PASS'
    return
}
if ($Mode -eq 'Typecheck') {
    . (Join-Path $root 'ci/windows/Initialize-HeliosBuild.ps1')
    $env:HELIOS_WINDOWS_KIT_VERSION = '10.0.26100.0'
    Import-VisualStudioEnvironment -Architecture x64
    $kmd = Join-Path $root 'kmd_render'
    $lockedTarget = Join-Path $kmd "target-z-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
    # wdk-build locates the genuine Cargo.lock by walking OUT_DIR ancestors.
    if (-not $lockedTarget.StartsWith($kmd + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'P06_Z_CARGO_TARGET_OUTSIDE_KMD' }
    if (-not (Test-Path -LiteralPath (Join-Path $kmd 'Cargo.lock'))) { throw 'P06_Z_CARGO_LOCK_ABSENT' }
    $env:CARGO_TARGET_DIR = $lockedTarget
    $env:RUSTUP_TOOLCHAIN = 'nightly-2026-07-14'
    $env:RUST_BACKTRACE = '1'
    $env:CARGO_BUILD_JOBS = '4'
    $llvmCandidates = @((Join-Path $env:ProgramFiles 'LLVM\bin'))
    foreach ($name in @('LLVM_PATH','LLVM_BIN','HELIOS_LLVM_BIN')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) {
            $llvmCandidates += $value
            $llvmCandidates += (Join-Path $value 'bin')
        }
    }
    $llvmCandidates = @($llvmCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'libclang.dll') } | Select-Object -Unique)
    if (-not $llvmCandidates.Count) { throw 'P06_Z_LIBCLANG22_DLL_NOT_FOUND' }
    $env:LIBCLANG_PATH = $llvmCandidates[0]
    Write-Host "Z_CARGO_TARGET_INSIDE_KMD=$env:CARGO_TARGET_DIR"
    Write-Host "Z_LIBCLANG_PATH=$env:LIBCLANG_PATH"
    $log = Join-Path $receipts 'kmd-cargo-check.log'
    & cargo +nightly-2026-07-14 check --locked --manifest-path (Join-Path $kmd 'Cargo.toml') --target x86_64-pc-windows-msvc *>&1 | Tee-Object -FilePath $log
    $code=$LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $receipts 'kmd-exit.txt'),[string]$code)
    if ($code -ne 0) { throw "P06_Z_KMD_NATIVE_TYPECHECK_FAILED exit=$code" }
    Write-Host 'Z_KMD_NATIVE_TYPECHECK=PASS no_sys_built=1'
    return
}
