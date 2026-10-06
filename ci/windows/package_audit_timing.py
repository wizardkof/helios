"""Add timing only to the frozen audit; prove reversible statement preservation."""
import argparse
import hashlib
import json
from pathlib import Path

PREFIX = r'''
# DIAGNOSTIC_TIMING_BEGIN
$timingWatch=[Diagnostics.Stopwatch]::StartNew()
$timingActive=@{}
function AuditEvent([string]$phase,[string]$edge,[string]$path='', [string]$command='', $exit=$null) {
 $key="$phase|$path"
 $now=$timingWatch.Elapsed.TotalMilliseconds
 if($edge -eq 'BEGIN'){$timingActive[$key]=$now}
 $duration=if($edge -eq 'END' -and $timingActive.ContainsKey($key)){$now-$timingActive[$key]}else{$null}
 $row=[ordered]@{utc=[DateTime]::UtcNow.ToString('o');elapsedMs=$now;phase=$phase;edge=$edge;path=$path;architecture=$(if($path -match '\\x86\\' -or [IO.Path]::GetFileName($path) -in @('helios_umd32.dll','helios_umd12_32.dll')){'IMAGE_FILE_MACHINE_I386'}elseif($path){'IMAGE_FILE_MACHINE_AMD64'}else{$null});kind=$(if($path){if((Split-Path $path -Parent) -eq $driver){'DRIVER'}else{'PAYLOAD'}}else{$null});command=$command;durationMs=$duration;exit=$exit}
 $line=ConvertTo-Json -InputObject $row -Compress
 $stream=[IO.File]::Open($env:HELIOS_AUDIT_EVENTS,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
 try{$bytes=[Text.Encoding]::UTF8.GetBytes($line+"`n");$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 Write-Host "AUDIT_${phase}_${edge} $path $command"
}
AuditEvent TOTAL BEGIN
# DIAGNOSTIC_TIMING_END
'''

def edits():
    result=[]
    def around(line,phase,path="''",command="''",exit='$null'):
        result.append((line, f"AuditEvent {phase} BEGIN {path} {command}\n{line}\nAuditEvent {phase} END {path} {command} {exit}"))
    result.append(('$certFile=Get-ChildItem',"AuditEvent CERTIFICATE BEGIN\n$certFile=Get-ChildItem"))
    result.append(('if($owned){Import-Certificate -FilePath $certFile.FullName -CertStoreLocation Cert:\\CurrentUser\\Root|Out-Null}', 'if($owned){Import-Certificate -FilePath $certFile.FullName -CertStoreLocation Cert:\\CurrentUser\\Root|Out-Null}\nAuditEvent CERTIFICATE END\nAuditEvent DRIVER_CAT_SIGNATURE BEGIN'))
    around('& $sign verify /pa /v "$driver\\$name" *> "$out\\extracted-signature-$name.txt"','SIGNTOOL','"$driver\\$name"',"'signtool verify /pa /v'",'$LASTEXITCODE')
    result.append(('$images=@()', 'AuditEvent DRIVER_CAT_SIGNATURE END\n$images=@()'))
    around('$h=(& $llvm --file-headers $file.FullName | Out-String)','LLVM_READOBJ','$file.FullName',"'llvm-readobj --file-headers'",'$LASTEXITCODE')
    around('& $sign verify /pa /v /c $cat $file.FullName *> "$out\\extracted-catalog-$($file.Name).txt"','SIGNTOOL','$file.FullName',"'signtool verify /pa /v /c catalog'",'$LASTEXITCODE')
    around('& $sign verify /pa /v $file.FullName *> "$out\\extracted-signature-$($file.Name)-$expected.txt"','SIGNTOOL','$file.FullName',"'signtool verify /pa /v'",'$LASTEXITCODE')
    result.append(('$images+=@{',"AuditEvent HASH BEGIN $file.FullName 'Get-FileHash SHA256'\n$images+=@{"))
    result.append(("signature=if($isDriver){'CATALOG_COVERED'}else{'EMBEDDED_PASS'}}", "signature=if($isDriver){'CATALOG_COVERED'}else{'EMBEDDED_PASS'}}\nAuditEvent HASH END $file.FullName 'Get-FileHash SHA256'"))
    for anchor,old,new in [
        ('$inf=Get-Content',None,'INF'),
        ('foreach($f in Get-ChildItem', 'INF','SCRIPT_PARSE'),
        ('$install=Get-Content','SCRIPT_PARSE','INSTALL_STATIC'),
        ('$m=Get-Content','INSTALL_STATIC','MANIFEST'),
        ('$shim=', 'MANIFEST','SHIM'),
        ('[ordered]@{status=', 'SHIM',None),
    ]:
        events=(f'AuditEvent {old} END\n' if old else '')+(f'AuditEvent {new} BEGIN\n' if new else '')
        result.append((anchor,events+anchor))
    result.append(('} finally {if($owned){Remove-Item $store -Force -ErrorAction SilentlyContinue}}', '} finally {\nAuditEvent CERTIFICATE_CLEANUP BEGIN\nif($owned){Remove-Item $store -Force -ErrorAction SilentlyContinue}\nAuditEvent CERTIFICATE_CLEANUP END\nAuditEvent TOTAL END\n}'))
    return result

def instrument(original):
    text=original
    for old,new in edits():
        if text.count(old)!=1: raise ValueError('Frozen audit anchor mismatch: '+old)
        text=text.replace(old,new)
    anchor='$certFile=Get-ChildItem'
    # Helpers after param/strict mode, before first diagnostic event.
    text=text.replace('AuditEvent CERTIFICATE BEGIN\n'+anchor,PREFIX+'AuditEvent CERTIFICATE BEGIN\n'+anchor)
    if restore(text)!=original: raise ValueError('Timing transform does not reverse')
    return text

def restore(text):
    text=text.replace(PREFIX,'')
    for old,new in reversed(edits()):text=text.replace(new,old)
    return text

def main():
    p=argparse.ArgumentParser();p.add_argument('source');p.add_argument('destination');a=p.parse_args()
    src=Path(a.source);dst=Path(a.destination)
    original=src.read_text(encoding='utf-8-sig');instrumented=instrument(original)
    dst.parent.mkdir(parents=True,exist_ok=True);dst.write_text(instrumented,encoding='utf-8')
    receipt={'status':'PASS_REVERSIBLE_ADDITIVE_TIMING','originalPath':str(src),'originalByteSha256':hashlib.sha256(src.read_bytes()).hexdigest(),'originalTextSha256':hashlib.sha256(original.encode()).hexdigest(),'restoredTextSha256':hashlib.sha256(restore(instrumented).encode()).hexdigest(),'diagnosticSha256':hashlib.sha256(dst.read_bytes()).hexdigest(),'edits':edits()}
    dst.with_suffix('.provenance.json').write_text(json.dumps(receipt,indent=2))
if __name__=='__main__':main()
