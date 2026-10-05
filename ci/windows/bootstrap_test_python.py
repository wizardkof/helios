"""Exact native interpreter bootstrap, also used inside the disposable RED/GREEN control."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import urllib.request
import venv

HERE = Path(__file__).resolve().parent
PINS = json.loads((HERE/'python-test-pins.json').read_text())

def identity():
    return dict(executable=sys.executable, version=platform.python_version(), architecture=platform.machine(), bits=struct.calcsize('P')*8,
                prefix=sys.prefix, base_prefix=sys.base_prefix, importPaths=sys.path,
                environment={k:os.environ.get(k) for k in ('PATH','PYTHONPATH','PYTHONHOME','MSYSTEM','pythonLocation')})

def bootstrap(receipts):
    receipts.mkdir(parents=True, exist_ok=True)
    before=identity()
    try:before['yamlDistributionBefore']=importlib.metadata.version('PyYAML')
    except importlib.metadata.PackageNotFoundError:before['yamlDistributionBefore']='NOT_INSTALLED_IN_THIS_INTERPRETER'
    spec=importlib.util.find_spec('yaml');before['yamlImportCandidateBefore']=spec.origin if spec else None
    (receipts/'before.json').write_text(json.dumps(before,indent=2)+'\n')
    if sys.platform!='win32' or before['version']!=PINS['pythonVersion'] or before['bits']!=64 or platform.python_implementation()!='CPython':
        raise ValueError('Native CPython 3.12.10 x64 required')
    if 'msys' in sys.executable.lower() or 'ucrt64' in sys.executable.lower() or 'mingw' in sys.executable.lower():
        raise ValueError('MSYS2 interpreter cannot consume native test requirements')
    wheel=receipts/PINS['filename']
    with urllib.request.urlopen(PINS['url']) as response: data=response.read()
    if hashlib.sha256(data).hexdigest()!=PINS['sha256']: raise ValueError('PyYAML wheel hash mismatch')
    wheel.write_bytes(data)
    (receipts/'acquisition.json').write_text(json.dumps(dict(**PINS,size=len(data),observedSha256=hashlib.sha256(data).hexdigest()),indent=2)+'\n')
    # Never invoke pip/py from PATH: install into this very interpreter.
    subprocess.run([sys.executable,'-m','pip','install','--disable-pip-version-check','--no-deps','--force-reinstall','--no-index','--only-binary=:all:',
                    '--find-links',str(receipts),'--require-hashes','-r',str(HERE/'python-test-requirements.txt')],check=True)
    import yaml
    if importlib.metadata.version('PyYAML')!=PINS['version']: raise ValueError('PyYAML installed version mismatch')
    observed=yaml.safe_load('gate: PASS\nvalues: [1, 2]\n')
    if observed!={'gate':'PASS','values':[1,2]}: raise ValueError('Controlled YAML read failed')
    after=dict(**identity(),pyyamlVersion=importlib.metadata.version('PyYAML'),yamlFile=yaml.__file__,controlledRead=observed,status='PASS')
    (receipts/'after.json').write_text(json.dumps(after,indent=2)+'\n'); print(json.dumps(after))
    return after

def run_tests(python, receipts):
    commands=[[python,'-m','unittest','discover','-s',str(HERE),'-p','test_*.py'],
              [python,'-m','unittest','discover','-s',str(HERE.parents[1]/'tools'),'-p','test_candidate_version.py']]
    for i,cmd in enumerate(commands):
        with (receipts/f'tests-{i}.log').open('w',encoding='utf-8') as log:
            proc=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
        print((receipts/f'tests-{i}.log').read_text())
        if proc.returncode: raise ValueError(f'Windows Python test suite failed: {cmd}')

def control(receipts):
    receipts.mkdir(parents=True,exist_ok=True)
    (receipts/'controller-identity.json').write_text(json.dumps(identity(),indent=2)+'\n')
    isolated=receipts/'without-dependencies'; venv.EnvBuilder(with_pip=True,system_site_packages=False).create(isolated)
    python=str(isolated/'Scripts/python.exe')
    # Run the real failing .306 consumer, including its method-local import.
    cmd=[python,'-m','unittest','test_ci_contract.WorkflowInfrastructureOnlyTests.test_infrastructure_only_never_schedules_product_jobs_or_bundle']
    proc=subprocess.run(cmd,cwd=HERE,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (receipts/'red.log').write_text(proc.stdout)
    if proc.returncode==0 or "No module named 'yaml'" not in proc.stdout: raise ValueError('RED did not reproduce the real consumer failure')
    (receipts/'red-identity.json').write_text(subprocess.check_output([python,'-c',"import json,sys,struct;print(json.dumps(dict(executable=sys.executable,prefix=sys.prefix,base_prefix=sys.base_prefix,path=sys.path,bits=struct.calcsize('P')*8)))"]).decode())
    subprocess.run([python,str(Path(__file__).resolve()),'bootstrap','--receipt-dir',str(receipts/'green-bootstrap')],check=True)
    run_tests(python,receipts)
    (receipts/'control.json').write_text(json.dumps(dict(status='PASS',redExit=proc.returncode,redConsumer=cmd,greenInterpreter=python,systemSitePackages=False),indent=2)+'\n')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['bootstrap','control','tests']);parser.add_argument('--receipt-dir',type=Path,required=True);args=parser.parse_args()
    if args.mode=='bootstrap':bootstrap(args.receipt_dir)
    elif args.mode=='control':control(args.receipt_dir)
    else:args.receipt_dir.mkdir(parents=True,exist_ok=True);run_tests(sys.executable,args.receipt_dir)
