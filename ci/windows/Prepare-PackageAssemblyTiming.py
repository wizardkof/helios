import argparse
import hashlib
import json
from pathlib import Path
import shutil

def main():
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--output',required=True);p.add_argument('--receipt',required=True);a=p.parse_args()
    src=Path(a.source)/'ci/windows';dst=Path(a.output);shutil.copytree(src,dst)
    script=dst/'Assemble-Package.ps1';original=script.read_text(encoding='utf-8-sig')
    begin='& python (Join-Path $RepoRoot "ci\\windows\\Test-PackagedInstallState.py")'
    end='if ($LASTEXITCODE -ne 0) { throw "Packaged native schema failed; no qualified ZIP permitted." }'
    if original.count(begin)!=1 or original.count(end)!=1:raise ValueError('Frozen schema anchors mismatch')
    b='$schemaWatch=[Diagnostics.Stopwatch]::StartNew()\nWrite-Host "SCHEMA_START"\n'+begin
    e=end+'\n[ordered]@{status="PASS";durationMs=$schemaWatch.Elapsed.TotalMilliseconds}|ConvertTo-Json|Set-Content "$env:RUNNER_TEMP/timing/schema-duration.json"\nWrite-Host "SCHEMA_END"'
    changed=original.replace(begin,b).replace(end,e)
    if changed.replace(e,end).replace(b,begin)!=original:raise ValueError('Assembly restoration mismatch')
    script.write_text(changed,encoding='utf-8')
    files=[]
    for f in sorted(src.iterdir()):
        if f.is_file():files.append({'path':f.name,'originalSha256':hashlib.sha256(f.read_bytes()).hexdigest(),'copySha256':hashlib.sha256((dst/f.name).read_bytes()).hexdigest()})
    Path(a.receipt).write_text(json.dumps({'status':'PASS_REVERSIBLE_SCHEMA_TIMING_ONLY','originalSha256':hashlib.sha256((src/script.name).read_bytes()).hexdigest(),'diagnosticSha256':hashlib.sha256(script.read_bytes()).hexdigest(),'files':files},indent=2))
if __name__=='__main__':main()
