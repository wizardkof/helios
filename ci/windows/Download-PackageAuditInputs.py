"""Download original archive bytes, verify API pin/digest, then frozen identity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile

SOURCE='d03d79ebec6d857d141469d197e11c04097c4d75'
RUN='37417032761'
REPO='wizardkof/helios'

def main():
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--output',required=True);p.add_argument('--configuration',choices=['Release','Debug'],required=True);a=p.parse_args()
    root=Path(a.output);root.mkdir(parents=True,exist_ok=True)
    pins=json.loads(Path(__file__).with_name('package-audit-original-inputs.json').read_text())['artifacts']
    specs=[('driver',a.configuration,'x64+x86'),('mesa','Release','x64'),('mesa-x86','Release','x86'),('opencl','Release','x64'),('loaders','Release','x64+x86'),('compatibility','Release','x64')]
    lock=json.loads((Path(a.source)/'metadata/candidate-reservation.json').read_text())
    env=dict(os.environ,GITHUB_SHA=SOURCE,GITHUB_RUN_ID=RUN,GITHUB_RUN_ATTEMPT='1')
    for component,config,arch in specs:
        name='helios-'+component+('-'+config if component=='driver' else '')
        pin=next(x for x in pins if x['name']==name)
        live=json.loads(subprocess.check_output(['gh','api',f'repos/{REPO}/actions/artifacts/{pin["id"]}']))
        for key in ['id','name','digest','size_in_bytes','created_at']:
            if live[key]!=pin[key]:raise ValueError('Original API identity changed: '+key)
        if live['expired'] or str(live['workflow_run']['id'])!=RUN or live['workflow_run']['head_sha']!=SOURCE:raise ValueError('Invalid original run authority')
        archive=root/(name+'.zip')
        with archive.open('wb') as out:subprocess.run(['gh','api',f'repos/{REPO}/actions/artifacts/{pin["id"]}/zip'],stdout=out,check=True)
        digest='sha256:'+hashlib.file_digest(archive.open('rb'),'sha256').hexdigest()
        if digest!=pin['digest']:raise ValueError('Original archive SHA256 mismatch')
        dest=root/component
        with zipfile.ZipFile(archive) as z:
            if z.testzip() is not None:raise ValueError('Original ZIP CRC mismatch')
            for f in z.infolist():
                path=f.filename.replace('\\','/')
                if path.startswith('/') or '..' in path.split('/') or ':' in path:raise ValueError('Unsafe archive path')
            z.extractall(dest)
        subprocess.run(['python',str(Path(a.source)/'ci/windows/ci_artifact.py'),'verify','--directory',str(dest),'--source-root',a.source,'--component',component,'--configuration',config,'--architecture',arch],env=env,check=True)
        (root/(name+'.api-provenance.json')).write_text(json.dumps({'status':'PASS','classification':'ORIGINAL_314_INPUT','api':live,'sha256':digest,'version':lock['version'],'sourceFingerprint':lock['sourceFingerprint'],'sourceCommits':lock['sourceCommits']},indent=2))
if __name__=='__main__':main()
