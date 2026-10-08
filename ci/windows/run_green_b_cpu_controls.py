#!/usr/bin/env python3
"""Fail-closed CPU/source controls for the production GREEN-B candidate."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def commands(root, receipt, compiler):
    jobs=[]
    for crate in ('protocol','kmd_logic'):
        jobs.append((crate,['cargo','test','--locked','--manifest-path',str(root/crate/'Cargo.toml')]))
    jobs.append(('production_wiring',[sys.executable,str(root/'tools/test_green_b_production.py')]))
    mesa=root/'icd/mesa/src/virtio/vulkan'
    for name in ('attest_transport','carrier_v2','green_b_abi','green_b_control','green_b_submit','green_b_wait'):
        exe=receipt/(name+'.exe')
        jobs.append((name+'_compile',[compiler,'-std=c11','-Wall','-Wextra','-Werror','-I',str(mesa),str(mesa/('test_helios_'+name+'.c')),'-o',str(exe)]))
        jobs.append((name+'_execute',[str(exe)]))
    for name in ('green_b_submit_production','green_b_wait_production'):
        jobs.append((name,[sys.executable,str(mesa/('test_helios_'+name+'.py')),str(receipt/(name+'.exe'))]))
    for name in ('carrier_producer','attest_flow'):
        jobs.append((name,[sys.executable,str(mesa/('test_helios_'+name+'.py')),'--cc',compiler,'--output',str(receipt/(name+'.exe'))]))
    return jobs


def run_jobs(jobs, receipt, env=None):
    receipt.mkdir(parents=True,exist_ok=True)
    rows=[]
    for name,command in jobs:
        try:
            result=subprocess.run(command,env=env,capture_output=True)
            code,out,err=result.returncode,result.stdout,result.stderr
        except OSError as error:
            code,out,err=127,b'',str(error).encode('utf-8')
        (receipt/(name+'.stdout.txt')).write_bytes(out)
        (receipt/(name+'.stderr.txt')).write_bytes(err)
        rows.append({'name':name,'command':command,'exit':code})
        (receipt/'receipts.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
        print(name,code,flush=True)
        if code:
            print(err[-4000:].decode('utf-8',errors='replace'),file=sys.stderr)
            return code if code>0 else 1
    return 0


def child_environment(root, receipt, compiler):
    env=os.environ.copy()
    env['CC']=compiler
    env['PYTHONUTF8']='1'
    # Qualification must execute the pinned production source and real CPU binaries.
    env.pop('P06_SOURCE',None)
    env.pop('P06_COMPILE_ONLY',None)
    env['CARGO_TARGET_DIR']=str(receipt/'rust-target' if os.name=='nt' else root/'target/linux')
    return env


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--receipt-dir',type=Path,required=True)
    parser.add_argument('--cc',required=True)
    args=parser.parse_args()
    root=args.root.resolve();receipt=args.receipt_dir.resolve()
    if receipt==root or root in receipt.parents:
        raise ValueError('CPU receipts must be outside product sources')
    env=child_environment(root,receipt,args.cc)
    return run_jobs(commands(root,receipt,args.cc),receipt,env)

if __name__=='__main__':sys.exit(main())
