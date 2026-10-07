param([ValidateSet('x64','x86')][string]$Architecture,[Parameter(Mandatory)][string]$MesaRoot,[Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Initialize-HeliosBuild.ps1"
Import-VisualStudioEnvironment -Architecture $Architecture
New-Item -ItemType Directory -Force $Output|Out-Null
$env:CARGO_TARGET_DIR="C:\helios-diag-target\$Architecture\$env:GITHUB_RUN_ID"
$target=if($Architecture -eq 'x64'){'x86_64-pc-windows-msvc'}else{'i686-pc-windows-msvc'}
$root=Resolve-Path "$PSScriptRoot/../.."
if(!$env:LLVM_PATH){throw 'Pinned LLVM_PATH absent'}
$clang=Join-Path $env:LLVM_PATH 'bin/clang.exe'
if(!(Test-Path $clang)){throw 'Pinned clang absent'}
$version=& $clang --version
@{Path=$clang;Version=$version;SHA256=(Get-FileHash $clang).Hash;Expected='22.1.8'}|ConvertTo-Json -Depth 4|Set-Content (Join-Path $Output 'clang-before-gate.json')
if($version[0] -notmatch 'clang version 22\.1\.8'){throw 'Clang identity mismatch'}
$identity=@{Kind='DIAGNOSTIC_ATTEST_PORT_ONLY';Helios=(& git -C $root rev-parse HEAD).Trim();Mesa=(& git -C $MesaRoot rev-parse HEAD).Trim();Architecture=$Architecture;Clang=$version;ClangSHA256=(Get-FileHash $clang).Hash;Msvc=$env:VCToolsVersion;Sdk=$env:WindowsSDKVersion;Utc=[DateTime]::UtcNow.ToString('o');ProductBuild='NOT_RUN';GpuExecution='NOT_RUN'}
$identity|ConvertTo-Json -Depth 5|Set-Content (Join-Path $Output 'identity.json')
& python "$root/tools/p06-e1/generate-attest-dispatch.py"
if($LASTEXITCODE){throw 'Wrapper extraction failed'}
foreach($crate in @('protocol','kmd_logic')){
 & cargo test --manifest-path "$root/$crate/Cargo.toml" --target $target *> (Join-Path $Output ($crate+'.txt'))
 if($LASTEXITCODE){throw "$crate native controls failed"}
}
$src=Join-Path $MesaRoot 'src/virtio/vulkan'
$flow=Join-Path $Output 'flow.exe'
# Generate using exact production bodies; -fsyntax-only avoids a wrong-architecture link.
$generator=@'
from pathlib import Path
import sys
r=Path(sys.argv[1]); out=Path(sys.argv[2]);s=(r/'vn_renderer_helios.c').read_text(encoding='utf-8')
def body(n):
 start=s.index(n+'(');brace=s.index('{',start);end=brace+1;depth=1
 while depth:
  depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return 'static bool\n'+s[start:end]
f='\n'.join(body(n) for n in ['helios_attest_exchange','helios_carrier_attest_negotiated'])
t=(r/'test_helios_attest_flow_mock.c').read_text(encoding='utf-8').replace('/* FUNCTIONS */',f+'\n'+f.replace('helios_attest_exchange','second_exchange').replace('helios_carrier_attest_negotiated','second_negotiated'))
out.write_text(t,encoding='utf-8')
'@
$gen=Join-Path $Output 'generate-flow.py';$generator|Set-Content $gen
& python $gen $src (Join-Path $Output 'flow.c')
if($LASTEXITCODE){throw 'Flow extraction failed'}
$machine=if($Architecture -eq 'x64'){'x86_64-pc-windows-msvc'}else{'i686-pc-windows-msvc'}
foreach($test in @('flow','transport')){
 $testSource=if($test -eq 'flow'){Join-Path $Output 'flow.c'}else{Join-Path $src 'test_helios_attest_transport.c'}
 $exe=Join-Path $Output ($test+'.exe')
 & $clang "--target=$machine" -std=c11 -Wall -Wextra -Werror -Wno-unused-function "-I$src" $testSource -o $exe *> (Join-Path $Output ($test+'-build.txt'))
 if($LASTEXITCODE){throw "$test native compile failed"}
 & $exe *> (Join-Path $Output ($test+'-run.txt'))
 if($LASTEXITCODE){throw "$test native execution failed"}
}
@{Result='PASS_NATIVE_CPU_CONTROLS';GpuExecution='NOT_RUN';KmdWdkBuild='NOT_RUN';ProductBuild='NOT_RUN';Architecture=$Architecture}|ConvertTo-Json|Set-Content (Join-Path $Output 'result.json')
