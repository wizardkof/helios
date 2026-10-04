"""Copy only declared job outputs to one upload root; never edit originals."""
import argparse,glob,hashlib,json,shutil
from pathlib import Path

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def safe(p):
 if p.is_symlink() or (getattr(p.stat(),'st_file_attributes',0)&0x400):raise ValueError('reparse/symlink refused')
 if p.suffix.lower() in {'.pfx','.p12','.key','.pem','.dmp','.dump'} or any(x.lower() in {'credentials','.ssh','.cargo','cargo_home'} for x in p.parts):raise ValueError('private material refused')
def collect(entries,root,primary):
 root=Path(root);root.mkdir(parents=True,exist_ok=False)
 report=dict(PRIMARY_GATE_RESULT=primary,EVIDENCE_COLLECTION_RESULT='PASS',EVIDENCE_UPLOAD_RESULT='PENDING',sources=[],files=[])
 for entry in entries:
  row=dict(entry,status='NOT_RUN',destination=entry['name']);report['sources'].append(row)
  if not entry['name'].replace('-','').replace('_','').isalnum():raise ValueError('unsafe logical name')
  if entry['outcome'] in {'skipped','NOT_RUN',''}:continue
  matches=sorted(Path(x) for x in glob.glob(entry['source']))
  if not matches:
   row['status']='MISSING_REQUIRED' if entry['required'] else 'NOT_PRODUCED'
   if entry['required']:report['EVIDENCE_COLLECTION_RESULT']='FAIL'
   continue
  row['status']='PRESENT';count=0
  try:
   for src in matches:
    safe(src)
    files=sorted(x for x in src.rglob('*') if x.is_file()) if src.is_dir() else [src]
    for f in files:
     safe(f);rel=Path(entry['name'])/((Path(src.name)/f.relative_to(src) if len(matches)>1 else f.relative_to(src)) if src.is_dir() else Path(f.name))
     dest=root/rel
     if dest.exists():raise ValueError('destination collision')
     before=digest(f);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(f,dest)
     if before!=digest(dest) or before!=digest(f):raise ValueError('source changed during copy')
     report['files'].append(dict(source=str(f),destination=rel.as_posix(),size=dest.stat().st_size,sha256=before));count+=1
   row['status']='COPIED'
   if entry['required'] and not count:row['status']='MISSING_REQUIRED';report['EVIDENCE_COLLECTION_RESULT']='FAIL'
  except (OSError,ValueError) as err:row['status']='READ_OR_COPY_FAILURE';row['reason']=str(err);report['EVIDENCE_COLLECTION_RESULT']='FAIL'
 (root/'collection-manifest.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
 return report

def verify(root):
 root=Path(root);r=json.loads((root/'collection-manifest.json').read_text(encoding='utf-8-sig'))
 if r['EVIDENCE_COLLECTION_RESULT']!='PASS':raise ValueError('collection failed')
 expected={'collection-manifest.json'}
 for row in r['files']:
  rel=Path(row['destination'])
  if rel.is_absolute() or '..' in rel.parts:raise ValueError('unsafe destination')
  f=root/rel;safe(f)
  if f.stat().st_size!=row['size'] or digest(f)!=row['sha256']:raise ValueError('identity mismatch')
  expected.add(rel.as_posix())
 if {f.relative_to(root).as_posix() for f in root.rglob('*') if f.is_file()}!=expected:raise ValueError('file set mismatch')
 return r
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('mode',choices=['collect','verify']);p.add_argument('--root',required=True);p.add_argument('--spec');p.add_argument('--primary',default='UNKNOWN');a=p.parse_args()
 result=collect(json.loads(Path(a.spec).read_text(encoding='utf-8-sig')),a.root,a.primary) if a.mode=='collect' else verify(a.root)
 print(json.dumps(result,indent=2))
 if result['EVIDENCE_COLLECTION_RESULT']!='PASS':raise SystemExit(1)
