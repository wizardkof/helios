"""Copy only declared job outputs to one upload root; never edit originals."""
import argparse,glob,hashlib,json,shutil,os,re
from pathlib import Path
import stat
from evidence_fs import EntryRefusal, guard, matches as guarded_matches, files as guarded_files, read as guarded_read, create_file, ensure_directory

def digest(p):return hashlib.sha256(guarded_read(p)).hexdigest()
# Explicit admitted hidden metadata from the pinned public WIDL source plus synthetic controls.
ADMITTED_HIDDEN = {'.gitignore','.gitattributes','.editorconfig','.gitlab-ci.yml','.mailmap','.evidence'}
PRIVATE_PARTS = {'credentials','.ssh','.cargo','cargo_home','.git','.aws','.azure','.npmrc','.pypirc','.netrc','auth','authentication','tokens','without-dependencies'}
PRIVATE_SUFFIXES = {'.pfx','.p12','.key','.pem','.dmp','.dump'}
def selection_reason(p, relative, data=None):
 if p.stem.lower() in {'auth','authentication','credentials','token','tokens','secrets','secret'}:return 'AUTH_CONFIGURATION'
 if p.suffix.lower() in PRIVATE_SUFFIXES or any(x.lower() in PRIVATE_PARTS for x in p.parts):return 'PRIVATE_PATH'
 if any(x.startswith('.') and x not in ADMITTED_HIDDEN for x in relative.parts):return 'UNADMITTED_HIDDEN_PATH'
 if data is None:data=guarded_read(p)
 if re.search(rb'(?i)authorization[\"\' ]*[:=][\"\' ]*bearer[ ]+[^\s\"\']+|[\"\'](?:access_token|refresh_token|client_secret|password|private_key)[\"\'][ ]*:[ ]*[\"\'][^\"\']+',data):return 'AUTH_CONTENT'
 if re.search(rb'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}',data):return 'PRIVATE_CONTENT'
 return None

def safe(p):
 guard(p,'safe')
 if p.suffix.lower() in PRIVATE_SUFFIXES or any(x.lower() in PRIVATE_PARTS for x in p.parts):raise ValueError('private material refused')
def expand_sources(entries,temp,configuration):
 return [dict(e,source=e['source'].replace('{TEMP}',temp).replace('{CONFIG}',configuration)) for e in entries]
def collect(entries,root,primary):
 root=Path(root);ensure_directory(root.parent);root.mkdir(parents=False,exist_ok=False);guard(root,'collection-root')
 report=dict(PRIMARY_GATE_RESULT=primary,EVIDENCE_COLLECTION_RESULT='PASS',EVIDENCE_UPLOAD_RESULT='PENDING',sources=[],files=[],excluded=[],policyVersion=1)
 for entry in entries:
  row=dict(entry,status='NOT_RUN',destination=entry['name']);report['sources'].append(row)
  if not entry['name'].replace('-','').replace('_','').isalnum():raise ValueError('unsafe logical name')
  if entry['outcome'] in {'skipped','NOT_RUN',''}:continue
  count=0;admitted=set()
  mandatory=set(entry.get('mandatoryFiles',[]))
  if entry['outcome']=='success':mandatory.update(entry.get('mandatoryFilesOnSuccess',[]))
  try:
   matches=guarded_matches(entry['source'])
   if not matches:
    row['status']='MISSING_REQUIRED' if entry['required'] else 'NOT_PRODUCED'
    if entry['required']:
     report['EVIDENCE_COLLECTION_RESULT']='FAIL'
     if 'firstFailure' not in report:report['firstFailure']=dict(row)
    continue
   row['status']='PRESENT'
   prefix=Path(entry['source'])
   if glob.has_magic(entry['source']):
    parts=[]
    for part in prefix.parts:
     if glob.has_magic(part):break
     parts.append(part)
    prefix=Path(*parts)
   for src in matches:
    # Validate the complete tree before reading file contents, even excluded paths.
    info=guard(src,'source');is_directory=stat.S_ISDIR(info.st_mode)
    files=guarded_files(src)
    for f in files:
     relative=f.relative_to(src) if is_directory else Path(f.name)
     reason=selection_reason(f,relative,b'') # Name/path exclusion never reads content.
     data=None
     if not reason:
      safe(f);data=guarded_read(f);reason=selection_reason(f,relative,data)
     if reason:
      report['excluded'].append(dict(source=str(f),reason=reason,logicalSource=entry['name']))
      if (entry['required'] and not is_directory) or relative.as_posix() in mandatory:raise ValueError('required evidence excluded by policy')
      continue
     rel=Path(entry['name'])/((Path(src.name)/f.relative_to(src) if len(matches)>1 else f.relative_to(src)) if is_directory else Path(f.name))
     if glob.has_magic(entry['source']):rel=Path(entry['name'])/f.relative_to(prefix.absolute())
     dest=root/rel
     # Guard the existing parent before mkdir; validate all newly created components too.
     ensure_directory(dest.parent);guard(dest.parent,'destination-parent-created')
     before=hashlib.sha256(data).hexdigest();create_file(dest,data)
     if before!=digest(dest) or before!=digest(f):raise ValueError('source changed during copy')
     admitted.add(relative.as_posix())
     report['files'].append(dict(source=str(f),destination=rel.as_posix(),size=len(data),sha256=before));count+=1
   missing_mandatory=mandatory-admitted
   if missing_mandatory:raise ValueError(entry.get('missingSuccessCode','mandatory evidence absent or excluded')+': '+', '.join(sorted(missing_mandatory)))
   row['status']='COPIED'
   if entry['required'] and not count:
    row['status']='MISSING_REQUIRED';report['EVIDENCE_COLLECTION_RESULT']='FAIL'
    if 'firstFailure' not in report:report['firstFailure']=dict(row)
  except (OSError,ValueError) as err:
   row['status']='READ_OR_COPY_FAILURE';row['reason']=str(err);report['EVIDENCE_COLLECTION_RESULT']='FAIL'
   if isinstance(err,EntryRefusal):row['refusal']=dict(err.details,logicalSource=entry['name'])
   if 'firstFailure' not in report:report['firstFailure']=dict(row)
 create_file(root/'collection-manifest.json',(json.dumps(report,indent=2)+'\n').encode('utf-8'))
 return report

def verify(root,allow_failed_collection=False):
 root=Path(root);guard(root,'verify-root')
 # Enumerate without traversal before opening the manifest or a declared artifact file.
 actual={f.relative_to(root).as_posix() for f in guarded_files(root)}
 r=json.loads(guarded_read(root/'collection-manifest.json').decode('utf-8-sig'))
 if r['EVIDENCE_COLLECTION_RESULT']!='PASS' and not allow_failed_collection:raise ValueError('collection failed')
 expected={'collection-manifest.json'}
 for row in r['files']:
  rel=Path(row['destination'])
  if rel.is_absolute() or '..' in rel.parts:raise ValueError('unsafe destination')
  f=root/rel;safe(f);data=guarded_read(f)
  if len(data)!=row['size'] or hashlib.sha256(data).hexdigest()!=row['sha256']:raise ValueError('identity mismatch')
  expected.add(rel.as_posix())
 if actual!=expected:raise ValueError('file set mismatch')
 return r
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('mode',choices=['collect','verify']);p.add_argument('--root',required=True);p.add_argument('--spec');p.add_argument('--primary',default='UNKNOWN');a=p.parse_args()
 result=collect(expand_sources(json.loads(Path(a.spec).read_text(encoding='utf-8-sig')),os.environ.get('RUNNER_TEMP',''),os.environ.get('HELIOS_CI_CONFIGURATION','')),a.root,a.primary) if a.mode=='collect' else verify(a.root)
 print(json.dumps(result,indent=2))
 if result['EVIDENCE_COLLECTION_RESULT']!='PASS':raise SystemExit(1)
