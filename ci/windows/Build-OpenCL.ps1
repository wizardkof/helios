param(
    [Parameter(Mandatory)][string]$OutputDir,
    [Parameter(Mandatory)][string]$ReceiptDir,
    [string]$SourceRoot = "C:\clvk-src",
    [string]$BuildRoot = "C:\clvk-build",
    [string]$ClvkRepository = "https://github.com/winboat-org/clvk-helios.git",
    [string]$ClvkCommit = "56c626132782bf083a80a6c17f5ca763be0ff8fb",
    # Patches applied to the clspv submodule after checkout. clvk-helios carries
    # clspv as a submodule of upstream google/clspv, so Helios-local compiler
    # fixes live here as patches until there is enough divergence to justify a
    # clspv fork. Applied in file-name order; any failure fails the build rather
    # than silently shipping an unpatched compiler.
    [string]$ClspvPatchDir = (Join-Path $PSScriptRoot "..\patches\clspv")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "CI-Qualification.ps1")
Assert-CIBackend
. (Join-Path $PSScriptRoot "Initialize-HeliosBuild.ps1")
Import-VisualStudioEnvironment

# Fail before cloning LLVM or removing existing build trees when SDK setup is
# incomplete. Shader tools alone are insufficient for CLVK's system Vulkan.
if (-not $env:VULKAN_SDK) { throw "VULKAN_SDK must point to an installed Vulkan SDK." }
foreach ($relativePath in @("Include\vulkan\vulkan.h", "Lib\vulkan-1.lib")) {
    if (-not (Test-Path -LiteralPath (Join-Path $env:VULKAN_SDK $relativePath) -PathType Leaf)) {
        throw "Vulkan SDK is missing $relativePath in $env:VULKAN_SDK."
    }
}


. (Join-Path $PSScriptRoot 'Producer-Phases.ps1')
$script:ProducerPhaseRoot=$ReceiptDir
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$script:ProducerIdentities=[ordered]@{helios=$env:GITHUB_SHA;clvkExpected=$ClvkCommit;clvkRepository=$ClvkRepository;clvkActual=$null;clspvActual=$null;llvmActual=$null;patches=@()}
if(Test-Path -LiteralPath $ClspvPatchDir -PathType Container){
    $script:ProducerIdentities.patches=@(Get-ChildItem -LiteralPath $ClspvPatchDir -Filter '*.patch' -File|Sort-Object Name|ForEach-Object {@{name=$_.Name;sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
}
$script:ProducerPhase=$null
try {
if (Test-Path -LiteralPath $SourceRoot) { Remove-Item -LiteralPath $SourceRoot -Recurse -Force }
if (Test-Path -LiteralPath $BuildRoot) { Remove-Item -LiteralPath $BuildRoot -Recurse -Force }

Start-ProducerPhase 'PHASE_CLONE_CLVK'
Invoke-OpenCLNative 'git' @('clone','--filter=blob:none','--recursive',$ClvkRepository,$SourceRoot)
Complete-ProducerPhase 0
Start-ProducerPhase 'PHASE_SUBMODULES'
Push-Location $SourceRoot
try {
    Invoke-OpenCLNative 'git' @('checkout','--detach',$ClvkCommit)
    Invoke-OpenCLNative 'git' @('submodule','update','--init','--recursive')
    $script:ProducerIdentities.clvkActual=(& git rev-parse HEAD).Trim()
    $script:ProducerIdentities.clspvActual=(& git -C (Join-Path $SourceRoot 'external/clspv') rev-parse HEAD).Trim()
    Complete-ProducerPhase 0
    Start-ProducerPhase 'PHASE_CLSPV_PATCHES'

    if (Test-Path -LiteralPath $ClspvPatchDir -PathType Container) {
        $patches = @(Get-ChildItem -LiteralPath $ClspvPatchDir -Filter "*.patch" -File | Sort-Object Name)
        foreach ($patch in $patches) {
            Write-Host "Applying clspv patch $($patch.Name)"
            Push-Location (Join-Path $SourceRoot "external\clspv")
            try {
                Invoke-OpenCLNative 'git' @('apply','--verbose',$patch.FullName)
            } finally {
                Pop-Location
            }
        }
        Write-Host "Applied $($patches.Count) clspv patch(es)."
    }

    Complete-ProducerPhase 0
    Start-ProducerPhase 'PHASE_FETCH_LLVM'
    Invoke-OpenCLNative 'python.exe' @('external/clspv/utils/fetch_sources.py','--shallow','--deps','llvm')
    $llvmRoot=Join-Path $SourceRoot 'external/clspv/third_party/llvm'
    if(Test-Path (Join-Path $llvmRoot '.git')){$script:ProducerIdentities.llvmActual=(& git -C $llvmRoot rev-parse HEAD).Trim()}
    Complete-ProducerPhase 0
} finally {
    Pop-Location
}

Start-ProducerPhase 'PHASE_CMAKE_CONFIGURE'
if (-not $env:HELIOS_NINJA -or -not (Test-Path -LiteralPath $env:HELIOS_NINJA -PathType Leaf)) {
    throw "The approved upstream Ninja executable was not selected before CMake configuration."
}
Invoke-OpenCLNative 'cmake.exe' @('-S',$SourceRoot,'-B',$BuildRoot,'-G','Ninja',
    "-DCMAKE_MAKE_PROGRAM:FILEPATH=$env:HELIOS_NINJA",
    '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_C_COMPILER_LAUNCHER=sccache',
    '-DCMAKE_CXX_COMPILER_LAUNCHER=sccache',
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded',
    '-DCLVK_CLSPV_ONLINE_COMPILER=ON',
    '-DCLVK_COMPILER_AVAILABLE=ON',
    '-DCLVK_VULKAN_IMPLEMENTATION=system',
    '-DCLVK_BUILD_TESTS=OFF',
    '-DCLVK_UNIT_TESTING=OFF',
    '-DCLVK_ENABLE_ASSERTIONS=OFF')
$cachePath = Join-Path $BuildRoot "CMakeCache.txt"
$makeProgramLine = Get-Content -LiteralPath $cachePath | Where-Object { $_ -match '^CMAKE_MAKE_PROGRAM:FILEPATH=' } | Select-Object -First 1
$cachedNinja = if ($makeProgramLine) { $makeProgramLine.Substring($makeProgramLine.IndexOf('=') + 1) } else { $null }
if (-not $cachedNinja -or [IO.Path]::GetFullPath($cachedNinja) -ine [IO.Path]::GetFullPath($env:HELIOS_NINJA)) {
    throw "CMake cached a Ninja other than the approved executable: $cachedNinja"
}

Complete-ProducerPhase 0
Start-ProducerPhase 'PHASE_BUILD'
Invoke-OpenCLNative 'cmake.exe' @('--build',$BuildRoot,'--parallel',$env:HELIOS_BUILD_JOBS)
Complete-ProducerPhase 0
Start-ProducerPhase 'PHASE_STAGE'

$vendorDll = Get-ChildItem -LiteralPath $BuildRoot -Filter "OpenCL.dll" -File -Recurse |
    Where-Object { $_.FullName -match "Release" } |
    Select-Object -First 1
if (-not $vendorDll) {
    $vendorDll = Get-ChildItem -LiteralPath $BuildRoot -Filter "OpenCL.dll" -File -Recurse | Select-Object -First 1
}
if (-not $vendorDll) { throw "clvk build completed but OpenCL.dll was not found." }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Copy-Item -LiteralPath $vendorDll.FullName -Destination (Join-Path $OutputDir "clvk.dll") -Force
$vendorPdb = [IO.Path]::ChangeExtension($vendorDll.FullName, ".pdb")
if (Test-Path -LiteralPath $vendorPdb -PathType Leaf) {
    Copy-Item -LiteralPath $vendorPdb -Destination (Join-Path $OutputDir "clvk.pdb") -Force
}
Set-Content -LiteralPath (Join-Path $OutputDir "clvk-commit.txt") -Value $ClvkCommit -Encoding ascii
Set-Content -LiteralPath (Join-Path $OutputDir "clvk-repository.txt") -Value $ClvkRepository -Encoding ascii
# Record which compiler patches this artifact was built with, so a deployed
# clvk.dll can be told apart from a stock one without disassembling it.
$appliedPatches = if (Test-Path -LiteralPath $ClspvPatchDir -PathType Container) {
    @(Get-ChildItem -LiteralPath $ClspvPatchDir -Filter "*.patch" -File | Sort-Object Name | ForEach-Object { $_.Name })
} else { @() }
Set-Content -LiteralPath (Join-Path $OutputDir "clspv-patches.txt") `
    -Value ($appliedPatches -join "`n") -Encoding ascii
$licenseRoot = Join-Path $OutputDir "licenses"
$licenses = [ordered]@{
    "clvk-LICENSE" = Join-Path $SourceRoot "LICENSE"
    "clspv-LICENSE" = Join-Path $SourceRoot "external\clspv\LICENSE"
    "SPIRV-Tools-LICENSE" = Join-Path $SourceRoot "external\SPIRV-Tools\LICENSE"
    "SPIRV-Headers-LICENSE" = Join-Path $SourceRoot "external\SPIRV-Headers\LICENSE"
    "OpenCL-Headers-LICENSE" = Join-Path $SourceRoot "external\OpenCL-Headers\LICENSE"
}
New-Item -ItemType Directory -Force -Path $licenseRoot | Out-Null
foreach ($entry in $licenses.GetEnumerator()) {
    if (Test-Path -LiteralPath $entry.Value -PathType Leaf) {
        Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $licenseRoot $entry.Key) -Force
    }
}
$llvmLicense = Get-ChildItem -LiteralPath (Join-Path $SourceRoot "external\clspv") -Filter "LICENSE.TXT" -File -Recurse | Select-Object -First 1
if ($llvmLicense) { Copy-Item -LiteralPath $llvmLicense.FullName -Destination (Join-Path $licenseRoot "LLVM-LICENSE.TXT") -Force }
Write-Host "CLVK artifact staged at $OutputDir"

Complete-ProducerPhase 0
} catch {
    if($script:ProducerPhase -and $script:ProducerPhase.status -eq 'RUNNING'){
        $script:ProducerPhase.error=$_.Exception.Message
        Complete-ProducerPhase 1
    }
    throw
}
