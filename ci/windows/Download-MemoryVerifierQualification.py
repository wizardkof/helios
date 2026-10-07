"""Import the exact native-qualified verifier executable and its closed-state matrix."""
import argparse,subprocess,json,hashlib,zipfile,shutil
from pathlib import Path
RUN=37553690513
SHA='46dec82086dc665705412262054ff19c3e34c9a2'
ID=11453537158
DIGEST='2b29a1fec967efb8f61ebee7a6d18833268653f1f0ed9c5532bf6dc609d955af'
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args();o=Path(a.output);o.mkdir(parents=True,exist_ok=True)
 api=json.loads(subprocess.check_output(['gh','api',f'repos/wizardkof/helios/actions/artifacts/{ID}']))
 if api['workflow_run']['id']!=RUN or api['workflow_run']['head_sha']!=SHA or api['digest']!='sha256:'+DIGEST or api['expired']:raise ValueError('Native verifier qualification identity mismatch')
 archive=o/'native-qualification.zip'
 with archive.open('wb') as f:subprocess.run(['gh','api',f'repos/wizardkof/helios/actions/artifacts/{ID}/zip'],stdout=f,check=True)
 if hashlib.sha256(archive.read_bytes()).hexdigest()!=DIGEST:raise ValueError('Native verifier archive digest mismatch')
 with zipfile.ZipFile(archive) as z:
  if z.testzip() is not None:raise ValueError('Native qualification CRC failed')
  def read(name):return json.loads(z.read(name).decode('utf-8-sig'))
  matrix=read('memory-trust-control.json');imm=read('store-immutability.json')
  if matrix['status']!='PASS_NATIVE_NEGATIVE_MATRIX_AND_CLOSE_CONTROLS' or len(matrix['cases'])!=14 or imm['status']!='PASS':raise ValueError('Native verifier qualification matrix absent')
  for case in matrix['cases']:
   receipt=read(case['case']+'.json')
   if receipt['stateVerifyCount']!=receipt['stateCloseCount'] or receipt['finalStatus']!=('PASS'if case['expectedPass'] else 'FAIL'):raise ValueError('Native matrix mismatch')
  exe=z.read('package-verify.exe');(o/'package-verify.exe').write_bytes(exe)
  for name in ['memory-trust-control.json','store-immutability.json']:(o/name).write_bytes(z.read(name))
 (o/'qualified-verifier-import.json').write_text(json.dumps({'status':'PASS_EXACT_NATIVE_QUALIFIED_VERIFIER','run':RUN,'sha':SHA,'archiveSha256':DIGEST,'executableSha256':hashlib.sha256(exe).hexdigest(),'matrix':matrix},indent=2))
if __name__=='__main__':main()
