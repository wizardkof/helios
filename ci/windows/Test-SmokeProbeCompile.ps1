param([Parameter(Mandatory)][string]$ReceiptDir)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
New-Item -ItemType Directory -Force $ReceiptDir|Out-Null
$work=Join-Path $env:RUNNER_TEMP 'smoke-compile-inputs'
New-Item -ItemType Directory -Force $work|Out-Null
. (Join-Path $PSScriptRoot 'Initialize-HeliosBuild.ps1')
Import-VisualStudioEnvironment
$headerSource=Join-Path $work 'OpenCL-Headers'
& git clone https://github.com/KhronosGroup/OpenCL-Headers.git $headerSource
if($LASTEXITCODE -ne 0){throw 'Header clone failed'}
& git -C $headerSource checkout --detach $env:OPENCL_HEADERS_COMMIT
if($LASTEXITCODE -ne 0){throw 'Header checkout failed'}
$definition=Join-Path $work 'OpenCL.def'
$url="https://raw.githubusercontent.com/KhronosGroup/OpenCL-ICD-Loader/$env:OPENCL_LOADER_COMMIT/loader/windows/OpenCL.def"
Invoke-WebRequest $url -OutFile $definition
$importLibrary=Join-Path $work 'OpenCL.lib'
# Official export definitions create only an import library. No loader product
# is built or executed by this compile control; linking is not runtime proof.
& lib.exe /nologo /machine:x64 /name:OpenCL.dll "/def:$definition" "/out:$importLibrary"
if($LASTEXITCODE -ne 0){throw 'Official OpenCL import library creation failed'}
Push-Location $work
try {
 & (Join-Path $PSScriptRoot 'Build-SmokeTests.ps1') -RepoRoot $repo -OutputDir (Join-Path $work 'x64') -VulkanInclude (Join-Path $env:VULKAN_SDK 'Include') -VulkanLibrary (Join-Path $env:VULKAN_SDK 'Lib/vulkan-1.lib') -OpenClInclude $headerSource -OpenClLibrary $importLibrary
} finally {Pop-Location}
$full=@('vulkan-smoke.exe','vulkan-wsi-probe.exe','opengl-smoke.exe','d3d11-smoke.exe','d3d12-smoke.exe','d3d12-clear.exe','opencl-smoke.exe','opencl-gl-sharing-smoke.exe')
$files=@()
foreach($arch in @('x64')){
 $expected=$full
 foreach($name in $expected){
  $path=Join-Path (Join-Path $work $arch) $name
  if(-not(Test-Path $path -PathType Leaf)){throw "Missing $arch $name"}
  $files+=@{architecture=$arch;name=$name;size=(Get-Item $path).Length;sha256=(Get-FileHash $path).Hash.ToLowerInvariant()}
  $dest=Join-Path $ReceiptDir "$arch-$name"
  Copy-Item $path $dest
 }
}
[ordered]@{status='PASS';headSha=$env:GITHUB_SHA;headerBlob=(& git -C $repo rev-parse HEAD:tools/fullstack/probe_common.h);officialOpenClDefinition=$url;definitionSha256=(Get-FileHash $definition).Hash.ToLowerInvariant();openClHeaders=$env:OPENCL_HEADERS_COMMIT;files=$files;runtime='NOT_RUN'}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $ReceiptDir 'smoke-compile.json') -Encoding utf8
