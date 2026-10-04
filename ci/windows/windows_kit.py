"""Canonical selected-component checker, shared by native bootstrap and fixtures."""
import argparse,json
from pathlib import Path

def check(k,o):
 r=dict(requested=k,observed=o,queryStatus=o.get('queryStatus','UNKNOWN'),selectedPaths=o.get('files',[]),failures=[],status='FAIL',KIT_FAMILY_COMPATIBILITY='FAIL',PINNED_COMPONENT_IDENTITY='FAIL',SELECTED_BUILD_INPUTS='FAIL')
 def fail(reason,expected,observed):r['failures'].append(dict(reason=reason,expected=expected,observed=observed))
 if o.get('family')==k['family']:r['KIT_FAMILY_COMPATIBILITY']='PASS'
 else:fail('family',k['family'],o.get('family'))
 consistent=True
 for kind in ['sdk','wdk']:
  a=k['acquisition'][kind]
  if a['packageVersion']!=k[kind+'Version'] or not a['url'].startswith('https://download.microsoft.com/') or len(a['sha256'])!=64:consistent=False;fail('acquisition contract',k[kind+'Version'],a)
  for c in [c for c in k['components'] if c['kind']==kind]:
   if c['version']!=a['componentVersion']:consistent=False;fail('bootstrap/checker contradiction',a['componentVersion'],c)
 component_ok=consistent and o.get('queryStatus')=='PASS'
 for c in k['components']:
  rows=[x for x in o.get('inventory',[]) if x.get('DisplayName')==c['name']]
  if len(rows)!=1 or rows[0].get('DisplayVersion')!=c['version'] or rows[0].get('productCode','').upper()!=c['productCode'].upper():component_ok=False;fail('selected component identity',c,rows)
 if component_ok:r['PINNED_COMPONENT_IDENTITY']='PASS'
 files_ok=True
 for f in k['selectedFiles']:
  rows=[x for x in o.get('files',[]) if x.get('path')==f['path']]
  if len(rows)!=1 or not rows[0].get('size',0) or len(rows[0].get('sha256',''))!=64:files_ok=False;fail('selected build input',f,rows)
 if files_ok:r['SELECTED_BUILD_INPUTS']='PASS'
 if r['queryStatus']!='PASS':fail('inventory query','PASS',r['queryStatus'])
 if consistent and all(r[x]=='PASS' for x in ['KIT_FAMILY_COMPATIBILITY','PINNED_COMPONENT_IDENTITY','SELECTED_BUILD_INPUTS']) and r['queryStatus']=='PASS':r['status']='PASS'
 return r
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--pins',required=True);p.add_argument('--observation',required=True);p.add_argument('--receipt',required=True);a=p.parse_args()
 r=check(json.loads(Path(a.pins).read_text(encoding='utf-8-sig'))['windowsKit'],json.loads(Path(a.observation).read_text(encoding='utf-8-sig')))
 Path(a.receipt).write_text(json.dumps(r,indent=2)+'\n',encoding='utf-8');print(json.dumps(r,indent=2));raise SystemExit(0 if r['status']=='PASS' else 1)
