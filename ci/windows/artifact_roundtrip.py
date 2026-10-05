"""Seal transport outside payload; compare actual downloaded set, sizes and SHA-256."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from ci_evidence import safe, selection_reason, verify as verify_collection

def inventory(root):
    rows=[]
    for f in sorted(root.rglob('*')):
        safe(f)
        if not f.is_file(): continue
        relative=f.relative_to(root)
        reason=selection_reason(f,relative)
        if reason: raise ValueError(f'Unadmitted artifact input: {relative}: {reason}')
        rows.append(dict(path=relative.as_posix(),size=f.stat().st_size,sha256=hashlib.sha256(f.read_bytes()).hexdigest()))
    if not rows:raise ValueError('Empty artifact')
    return rows

def validate_payload(root):
    if (root/'collection-manifest.json').exists():
        # A failed collection is still transported and verified, but cannot become collection PASS.
        record=verify_collection(root,allow_failed_collection=True)
        return record['EVIDENCE_COLLECTION_RESULT']
    if (root/'ci-artifact-identity.json').exists():
        from ci_artifact import verify
        record=json.loads((root/'ci-artifact-identity.json').read_text())
        verify(root,record['identity'])
    return 'NOT_APPLICABLE_PRODUCT_IDENTITY'

def seal(root,receipt):
    if receipt.exists():raise ValueError('Transport snapshot already exists')
    receipt.parent.mkdir(parents=True,exist_ok=True)
    record=dict(schemaVersion=1,headSha=os.environ.get('GITHUB_SHA'),runId=os.environ.get('GITHUB_RUN_ID'),attempt=os.environ.get('GITHUB_RUN_ATTEMPT'),collectionStatus=validate_payload(root),files=inventory(root))
    receipt.write_text(json.dumps(record,indent=2)+'\n');return record

def verify(root,receipt):
    expected=json.loads(receipt.read_text());collection_status=validate_payload(root);actual=inventory(root)
    if (expected['headSha'],expected['runId'],expected['attempt']) != (os.environ.get('GITHUB_SHA'),os.environ.get('GITHUB_RUN_ID'),os.environ.get('GITHUB_RUN_ATTEMPT')):raise ValueError('Transport run identity mismatch')
    if expected['files']!=actual:raise ValueError('Artifact roundtrip set/size/SHA256 mismatch')
    return dict(status='PASS',collectionStatus=collection_status,files=len(actual),headSha=expected['headSha'],runId=expected['runId'],attempt=expected['attempt'])

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('mode',choices=['seal','verify']);p.add_argument('--root',type=Path,required=True);p.add_argument('--receipt',type=Path,required=True);a=p.parse_args()
    result=seal(a.root,a.receipt) if a.mode=='seal' else verify(a.root,a.receipt)
    print(json.dumps({k:v for k,v in result.items() if k!='files'} | {'fileCount':len(result['files']) if isinstance(result.get('files'),list) else result.get('files')}))
