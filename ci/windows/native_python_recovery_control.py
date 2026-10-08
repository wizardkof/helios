"""Reproduce the three frozen .318 test failures in the real native shallow checkout."""
import argparse
import ctypes
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
LEGACY_SHA256="1e76b533ee2a5fb20cd089049744c6dda8ceecb2c3d3741a126d8391a55bf194"

def execute(out):
    out.mkdir(parents=True,exist_ok=True)
    record=dict(status='FAIL',python=sys.executable,version=platform.python_version(),bits=struct.calcsize('P')*8,head=os.environ.get('GITHUB_SHA'),run=os.environ.get('GITHUB_RUN_ID'))
    try:
        if sys.platform!='win32' or record['version']!='3.12.10' or record['bits']!=64 or any(x in sys.executable.lower() for x in ('msys','mingw','ucrt64')):
            raise ValueError('EXACT_NATIVE_WINDOWS_PYTHON_REQUIRED')
        root=HERE.parents[1]
        shallow=subprocess.run(['git','rev-parse','--is-shallow-repository'],cwd=root,capture_output=True,text=True)
        if shallow.returncode or shallow.stdout.strip()!='true':raise ValueError('SHALLOW_CHECKOUT_REQUIRED')
        history=subprocess.run(['git','cat-file','-e','6437badff87d903a4bab4d4f1cc7f9e682e50bea^{commit}'],cwd=root,capture_output=True,text=True)
        record['historicObjectProbe']=dict(exitCode=history.returncode,stdout=history.stdout,stderr=history.stderr)
        if not history.returncode:raise ValueError('HISTORIC_OBJECT_MUST_BE_ABSENT_IN_RED_FIXTURE')
        source=HERE/'fixtures/test_pkgconf_restore_318.py.txt'
        if hashlib.sha256(source.read_bytes()).hexdigest()!=LEGACY_SHA256:raise ValueError('LEGACY_TEST_SOURCE_IDENTITY_MISMATCH')
        loader=importlib.machinery.SourceFileLoader('legacy318',str(source));spec=importlib.util.spec_from_loader(loader.name,loader);legacy=importlib.util.module_from_spec(spec);loader.exec_module(legacy)
        import msys_archive_restore
        legacy.restore=msys_archive_restore;legacy.HERE=HERE
        long=Path(tempfile.gettempdir()).resolve();buf=ctypes.create_unicode_buffer(32768)
        short_fn=ctypes.windll.kernel32.GetShortPathNameW;short_fn.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint];short_fn.restype=ctypes.c_uint
        n=short_fn(str(long),buf,len(buf))
        if not n or n>=len(buf) or buf.value==str(long) or not Path(buf.value).samefile(long):raise ValueError('REAL_DISTINCT_WINDOWS_SHORT_LONG_ALIAS_REQUIRED')
        record['alias']=dict(short=buf.value,long=str(long),sameFile=True)
        names=['ManifestTests.test_previous_seven_archives_are_preserved','RestoreTests.test_native_tools_bind_to_python_msys2_root','RestoreTests.test_native_child_path_starts_with_qualified_msys2_tools']
        results=[]
        for i,name in enumerate(names):
            cmd=[sys.executable,str(Path(__file__).resolve()),'--legacy-case',name,'--short-temp',buf.value]
            proc=subprocess.run(cmd,capture_output=True,text=True)
            (out/f'red-{i}.log').write_text(proc.stdout+proc.stderr,encoding='utf-8')
            observed=json.loads(proc.stdout)
            if proc.returncode!=1 or observed['tests']!=1 or observed['skips']:
                raise ValueError('EXPECTED_REAL_LEGACY_RED_NOT_REPRODUCED: '+name)
            if i==0 and observed['errors']!=1:raise ValueError('RED_1_EXPECTED_GIT_ERROR')
            if i>0 and observed['failures']!=1:raise ValueError('RED_PATH_EXPECTED_TEXTUAL_ASSERTION_FAILURE')
            results.append(dict(test=name,command=cmd,exitCode=proc.returncode,**observed,log=f'red-{i}.log'))
        record.update(status='PASS_EXPECTED_THREE_NATIVE_RED_REPRODUCED',results=results)
    except Exception as error:
        record['error']=str(error)
        raise
    finally:(out/'native-red-results.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record))

def run_legacy_case(name, short_temp):
    source=HERE/'fixtures/test_pkgconf_restore_318.py.txt'
    if hashlib.sha256(source.read_bytes()).hexdigest()!=LEGACY_SHA256:raise ValueError('LEGACY_TEST_SOURCE_IDENTITY_MISMATCH')
    loader=importlib.machinery.SourceFileLoader('legacy318',str(source));spec=importlib.util.spec_from_loader(loader.name,loader);legacy=importlib.util.module_from_spec(spec);loader.exec_module(legacy)
    import msys_archive_restore
    legacy.restore=msys_archive_restore;legacy.HERE=HERE
    if not Path(short_temp).samefile(Path(tempfile.gettempdir()).resolve()):raise ValueError('TEMP_ALIAS_IDENTITY_MISMATCH')
    tempfile.tempdir=short_temp
    suite=unittest.defaultTestLoader.loadTestsFromName(name,legacy)
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    print(json.dumps(dict(tests=result.testsRun,failures=len(result.failures),errors=len(result.errors),skips=len(result.skipped))))
    raise SystemExit(0 if result.wasSuccessful() else 1)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path);p.add_argument('--legacy-case');p.add_argument('--short-temp');a=p.parse_args()
    if a.legacy_case:run_legacy_case(a.legacy_case,a.short_temp)
    elif a.output:execute(a.output)
    else:p.error('--output required')
