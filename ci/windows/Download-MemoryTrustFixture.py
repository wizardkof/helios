"""Fetch only the exact preserved paired producer export; never generate signing material."""
import os,json,hashlib,zipfile,urllib.request,argparse
from pathlib import Path
RUN=37547412355
SHA='8a27b6059fe4ac6bc79c12b97e23df81812065d0'
ARTIFACT=11451781562
DIGEST='f56c2fa166c7d43841fc2536cd87ed2c7d6df3101114725c0437af9222d2ee46'
def request(path):
 return urllib.request.urlopen(urllib.request.Request('https://api.github.com/repos/wizardkof/helios/'+path,headers={'Authorization':'Bearer '+os.environ['GH_TOKEN'],'Accept':'application/vnd.github+json','User-Agent':'Helios-diagnostic-fixture'})).read()
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args();out=Path(a.output);out.mkdir(parents=True,exist_ok=True)
 api=json.loads(request(f'actions/artifacts/{ARTIFACT}'));assert api['workflow_run']['id']==RUN and api['workflow_run']['head_sha']==SHA and api['digest']=='sha256:'+DIGEST and not api['expired']
 blob=request(f'actions/artifacts/{ARTIFACT}/zip');assert hashlib.sha256(blob).hexdigest()==DIGEST
 archive=out/'paired-producer.zip';archive.write_bytes(blob)
 with zipfile.ZipFile(archive) as z:
  assert z.testzip() is None
  for name in z.namelist():
   path=Path(name)
   if path.is_absolute() or '..'in path.parts:raise ValueError('Unsafe archive path')
  z.extractall(out/'producer')
 root=out/'producer';f=json.loads((root/'peer-trust-fixture.json').read_text(encoding='utf-8-sig'));assert f['controlRun']==str(RUN) and f['controlSha']==SHA and f['classification']=='NEW_DIAGNOSTIC_PAIRED_FIXTURE'
 for row in f['files']:
  b=(root/'fixture'/row['path']).read_bytes();assert len(b)==row['size'] and hashlib.sha256(b).hexdigest().upper()==row['sha256']
 assert hashlib.sha256((root/'fixture/helios-ci-test.cer').read_bytes()).hexdigest().upper()==f['certificateDerSha256']
 (out/'fixture-import.json').write_text(json.dumps({'status':'PASS_EXACT_PRODUCER_EXPORT','producerRun':RUN,'producerSha':SHA,'artifactId':ARTIFACT,'archiveSha256':DIGEST,'certificateDerSha256':f['certificateDerSha256'],'certificateThumbprint':f['certificateThumbprint'],'api':api},indent=2))
if __name__=='__main__':main()
