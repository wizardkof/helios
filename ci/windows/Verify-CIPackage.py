"""Independently decode, roundtrip and index exact final CI setup bytes."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import zipfile

spec=importlib.util.spec_from_file_location('packaged',Path(__file__).with_name('Test-PackagedInstallState.py'))
packaged=importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaged)

def verify(root):
    root=Path(root)
    setups=list(root.glob('*/HeliosSetup.exe'))
    if len(setups)!=1:raise ValueError('Require exactly one final setup')
    setup=setups[0]
    files,digest=packaged.decode(setup.read_bytes())
    manifest=json.loads(files['manifest.json'].decode('utf-8-sig'))
    if any(n.lower().endswith(('.pdb','.map')) for n in files):raise ValueError('Symbols in runtime payload')
    staged=root/'staging'/manifest['packageId']
    expected={p.relative_to(staged).as_posix():p.read_bytes() for p in staged.rglob('*') if p.is_file()}
    if files!=expected:raise ValueError('Final setup differs from exact staging files')
    with zipfile.ZipFile(root/(manifest['packageId']+'.zip')) as z:
        if z.testzip() is not None:raise ValueError('ZIP CRC failure')
        matches=[n for n in z.namelist() if n.replace('\\','/').endswith('/HeliosSetup.exe')]
        if len(matches)!=1 or z.read(matches[0])!=setup.read_bytes():raise ValueError('ZIP/setup mismatch')
    extracted=root/'extraction-verify'
    if extracted.exists():raise ValueError('Fresh extraction required')
    extracted.mkdir()
    records=[]
    for n,data in files.items():
        p=extracted/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
        if p.read_bytes()!=data:raise ValueError('Roundtrip mismatch: '+n)
        component=('mesa' if n.startswith('payload/mesa/') else 'clvk' if n.startswith('payload/opencl/') else 'vulkanLoader' if n.startswith('payload/loaders/') and n.endswith('vulkan-1.dll') else 'openClLoader' if n=='payload/loaders/OpenCL.dll' else 'helios')
        records.append({'path':n,'size':len(data),'sha256':hashlib.sha256(data).hexdigest(),'component':component,'source':manifest['source'].get(component),'sourceFingerprint':manifest['candidate']['sourceFingerprint'],'roundtrip':'PASS'})
    (root/'provenance-matrix.json').write_text(json.dumps({'status':'PASS','basis':'Assembly source/input receipts plus exact signed final payload identity; all upstream pins retained in manifest','source':manifest['source'],'files':records},indent=2))
    (root/'extraction-roundtrip.json').write_text(json.dumps({'status':'PASS','setupSha256':hashlib.sha256(setup.read_bytes()).hexdigest(),'containerDigest':digest,'files':len(files),'version':manifest['version'],'configuration':manifest['configuration'],'sourceFingerprint':manifest['candidate']['sourceFingerprint']},indent=2))
    return manifest

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--root',required=True);a=p.parse_args();verify(a.root)
