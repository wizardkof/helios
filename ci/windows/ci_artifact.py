"""Bind every consumed CI artifact to the frozen candidate/run and exact bytes."""
import argparse
import hashlib
import json
import os
from pathlib import Path

RECEIPT='ci-artifact-identity.json'

def inventory(root):
 root=Path(root)
 rows=[]
 for p in sorted(root.rglob('*')):
  if p.is_symlink() or (hasattr(p,'is_junction') and p.is_junction()):raise ValueError('Artifact reparse path')
  if not p.is_file():continue
  rel=p.relative_to(root).as_posix()
  if rel in (RECEIPT,'SHA256SUMS.txt'):continue
  if p.suffix.lower() in ('.pfx','.key'):raise ValueError('Private signing material in artifact')
  data=p.read_bytes();rows.append({'path':rel,'size':len(data),'sha256':hashlib.sha256(data).hexdigest()})
 if not rows:raise ValueError('Empty product artifact')
 return rows

def seal(root,identity):
 path=Path(root)/RECEIPT
 if path.exists():raise ValueError('Closed artifact identity already exists')
 if not all(identity.values()):raise ValueError('Incomplete artifact identity')
 record={'schemaVersion':1,'identity':identity,'files':inventory(root)}
 path.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
 return record

def verify(root,identity):
 record=json.loads((Path(root)/RECEIPT).read_text(encoding='utf-8-sig'))
 if record.get('schemaVersion')!=1 or record.get('identity')!=identity:raise ValueError('CI artifact identity mismatch')
 if record.get('files')!=inventory(root):raise ValueError('CI artifact bytes mismatch')
 return record

def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['seal','verify']);p.add_argument('--directory',required=True);p.add_argument('--source-root',required=True);p.add_argument('--component',required=True);p.add_argument('--configuration',required=True);p.add_argument('--architecture',required=True);a=p.parse_args()
 lock=json.loads((Path(a.source_root)/'metadata/candidate-reservation.json').read_text(encoding='utf-8-sig'))
 identity={'version':lock['version'],'sourceFingerprint':lock['sourceFingerprint'],'sourceCommits':lock['sourceCommits'],'headSha':os.environ['GITHUB_SHA'],'runId':os.environ['GITHUB_RUN_ID'],'runAttempt':os.environ['GITHUB_RUN_ATTEMPT'],'component':a.component,'configuration':a.configuration,'architecture':a.architecture}
 result=seal(a.directory,identity) if a.action=='seal' else verify(a.directory,identity)
 print('CI_ARTIFACT_'+a.action.upper()+'=PASS; files='+str(len(result['files'])))
if __name__=='__main__':main()
