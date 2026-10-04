param([string]$OutputDir,[string]$Configuration,[Parameter(Mandatory)][string]$Version)
$ErrorActionPreference='Stop'
$read=(Get-Command llvm-readobj.exe).Source
$pdbtool=(Get-Command llvm-pdbutil.exe).Source
$names=@('helios_kmd_render.sys','helios_umd.dll','helios_umd32.dll','helios_umd12.dll','helios_umd12_32.dll')
$records=@()
foreach($n in $names){
 $pe=Join-Path $OutputDir $n;$pdb=Join-Path $OutputDir ([IO.Path]::GetFileNameWithoutExtension($n)+'.pdb')
 if(!(Test-Path $pdb)){throw "PDB missing: $pdb"}
 $v=(Get-Item $pe).VersionInfo.FileVersion
 if($v -ne $Version){throw "Version mismatch $n : $v"}
 $cv=(& $read --coff-debug-directory --codeview $pe) -join "`n"
 if($LASTEXITCODE -ne 0){throw "PE inspection failed $n"}
 $ps=(& $pdbtool dump -summary $pdb) -join "`n"
 if($LASTEXITCODE -ne 0){throw "PDB inspection failed $n"}
 $cv | Set-Content (Join-Path $OutputDir "$n.codeview.txt")
 $ps | Set-Content (Join-Path $OutputDir "$n.pdb-summary.txt")
 $pg=[regex]::Match($ps,'GUID:\s*\{?([0-9A-Fa-f-]{36})').Groups[1].Value
 $pa=[regex]::Match($ps,'Age:\s*(\d+)').Groups[1].Value
 $eg=[regex]::Match($cv,'PDBGUID:\s*\{?([0-9A-Fa-f-]{36})').Groups[1].Value
 $ea=[regex]::Match($cv,'PDBAge:\s*(\d+)').Groups[1].Value
 if(!$pg -or !$eg -or !$pa -or !$ea -or $pg -ne $eg -or $pa -ne $ea){throw "PE/PDB identity mismatch or unparsed: $n PE=$eg/$ea PDB=$pg/$pa"}
 $records+=@{name=$n;version=$v;peSha256=(Get-FileHash $pe).Hash;pdbSha256=(Get-FileHash $pdb).Hash;guid=$pg;age=$pa}
}
$inf=Get-Content (Join-Path $OutputDir 'helios_kmd_render.inf') -Raw
if($inf -notmatch ('(?m)^DriverVer\s*=\s*[^\r\n,]+,\s*'+[regex]::Escape($Version)+'\s*$')){throw 'INF version mismatch'}
@{configuration=$Configuration;symbolsMatch='PASS';version=$Version;images=$records} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutputDir 'symbols-audit.json')
Write-Output "${Configuration}_SYMBOLS_MATCH=PASS"
