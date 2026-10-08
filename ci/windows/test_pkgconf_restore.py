import hashlib
import os
import shutil
import sys
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location("restore", HERE / "msys_archive_restore.py")
try:
    restore = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(restore)
except FileNotFoundError:
    restore = None


HISTORIC_FIXTURE=HERE/'fixtures/msys2-archives-317.json'
HISTORIC_FIXTURE_SHA256='6f529cdd45961ff29420e0bc35dc7de0190c5fce9b28518aaf6f6370cc64a033'

def validate_historical_archives(manifest, fixture=HISTORIC_FIXTURE):
    from fixture_a_bytes import inspect_fixture_a, default_receipt
    inspect_fixture_a(HERE.parents[1],fixture,default_receipt(),manifest,expected=HISTORIC_FIXTURE_SHA256)

def assert_child_identity(case, argv, environment, root, python):
    # File identity, never textual prefixes: Windows 8.3 aliases may spell the same path differently.
    paths=environment['PATH'].split(os.pathsep)
    case.assertGreaterEqual(len(paths),2)
    case.assertTrue(pathlib.Path(paths[0]).samefile(root/'usr/bin'))
    case.assertTrue(pathlib.Path(paths[1]).samefile(python.parent))
    case.assertTrue(pathlib.Path(argv[0]).samefile(root/'usr/bin/bash.exe'))

class ManifestTests(unittest.TestCase):
    def test_both_pkgconf_pins_have_authenticated_archive_entries(self):
        m=json.loads((HERE/"ci-toolchain-pins.json").read_text())
        rows={p["name"]:p for p in m["msys2ArchivedPackages"]["packages"]}
        for name in ["mingw-w64-i686-pkgconf", "mingw-w64-ucrt-x86_64-pkgconf"]:
            self.assertIn(name,rows)
            self.assertEqual(rows[name]["version"],"1~3.0.7-1")
            self.assertEqual(len(rows[name]["sha256"]),64)
    def test_previous_seven_archives_are_preserved(self):
        validate_historical_archives(json.loads((HERE/'ci-toolchain-pins.json').read_text()))

class RestoreTests(unittest.TestCase):
    def test_installer_api_exists(self):
        self.assertIsNotNone(restore,"Authenticated restoration implementation absent")
    def setUp(self):
        if restore is None and self._testMethodName!='test_installer_api_exists':self.skipTest("implementation absent; RED inventory/API above")
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.path=pathlib.Path(self.temp.name)/'package.zst';self.path.write_bytes(b'archive')
        import hashlib
        self.package={'name':'mingw-w64-i686-pkgconf','version':'1~3.0.7-1','architecture':'x86','file':'package.zst','sha256':hashlib.sha256(b'archive').hexdigest()}
        self.calls=[];self.installed='1~3.0.7-2';self.exit=0;self.bad_final=False
    def run_command(self,argv,**kwargs):
        self.calls.append(argv)
        if argv[:2]==['pacman','-Q']:
            if self.installed is None:return subprocess.CompletedProcess(argv,1,b'',b'not installed')
            version='wrong' if self.bad_final and any('-U' in c for c in self.calls) else self.installed
            return subprocess.CompletedProcess(argv,0,(self.package['name']+' '+version+'\n').encode(),b'')
        if '-U' in argv:
            if self.exit:return subprocess.CompletedProcess(argv,self.exit,b'out',b'actual pacman error')
            self.installed=self.package['version']
        return subprocess.CompletedProcess(argv,0,b'',b'')
    def restore(self):return restore.restore_package(self.package,self.path,self.run_command)
    def test_newer_version_downgrades_explicitly(self):
        row=self.restore();self.assertEqual(row['status'],'PASS');self.assertTrue(any('-U' in c for c in self.calls));self.assertTrue(all('--needed' not in c for c in self.calls))
    def test_equal_version_does_not_install(self):
        self.installed='1~3.0.7-1';self.restore();self.assertFalse(any('-U' in c for c in self.calls))
    def test_missing_package_installs(self):
        self.installed=None;self.assertEqual(self.restore()['status'],'PASS')
    def test_older_package_installs(self):
        self.installed='1~3.0.6-1';self.assertEqual(self.restore()['status'],'PASS')
    def test_pacman_failure_preserves_exit_and_stderr(self):
        self.exit=23;row=self.restore();self.assertEqual(row['status'],'FAIL');self.assertEqual(row['pacmanExitCode'],23);self.assertIn('actual pacman error',row['commands'][-1]['stderr'])
    def test_final_query_requires_exact_version(self):
        self.bad_final=True;self.assertEqual(self.restore()['error'],'INSTALLED_PACKAGE_IDENTITY_MISMATCH')
    def test_idempotent_second_restore(self):
        self.restore();self.calls=[];self.restore();self.assertFalse(any('-U' in c for c in self.calls))
    def test_sha_mismatch_refuses_before_pacman(self):
        self.package['sha256']='0'*64
        with self.assertRaisesRegex(ValueError,'SHA256'):restore.authenticate_package(self.package,self.path,self.run_command)
        self.assertFalse(self.calls)
    def test_invalid_signature_refuses_before_pacman(self):
        def bad(argv,**kwargs):
            self.calls.append(argv);return subprocess.CompletedProcess(argv,1,b'',b'bad signature')
        with self.assertRaisesRegex(ValueError,'SIGNATURE'):restore.authenticate_package(self.package,self.path,bad)
        self.assertFalse(any(c[0]=='pacman' for c in self.calls))
    def test_wrong_name_version_or_architecture_refuses(self):
        for text in ['pkgname = wrong\npkgver = 1~3.0.7-1\narch = any\n','pkgname = mingw-w64-i686-pkgconf\npkgver = wrong\narch = any\n','pkgname = mingw-w64-i686-pkgconf\npkgver = 1~3.0.7-1\narch = x86_64\n']:
            with self.assertRaisesRegex(ValueError,'METADATA'):restore.validate_metadata(self.package,text)
    def test_native_tools_bind_to_python_msys2_root(self):
        root=pathlib.Path(self.temp.name)/'msys64';binary=root/'ucrt64/bin/python.exe';binary.parent.mkdir(parents=True);binary.touch();tool=root/'usr/bin/bash.exe';tool.parent.mkdir(parents=True);tool.touch()
        self.assertTrue(hasattr(restore,'resolve_msys_tool'),'native binding absent')
        self.assertTrue(pathlib.Path(restore.resolve_msys_tool('bash',str(binary))).samefile(tool))
    def test_unqualified_python_root_is_refused(self):
        self.assertTrue(hasattr(restore,'resolve_msys_tool'),'native binding absent')
        with self.assertRaisesRegex(ValueError,'MSYS2'):
            restore.resolve_msys_tool('bash',str(pathlib.Path(self.temp.name)/'python.exe'))
    def test_missing_native_tool_is_refused_without_path_fallback(self):
        root=pathlib.Path(self.temp.name)/'msys64';binary=root/'mingw32/bin/python.exe';binary.parent.mkdir(parents=True);binary.touch()
        self.assertTrue(hasattr(restore,'resolve_msys_tool'),'native binding absent')
        with self.assertRaisesRegex(ValueError,'MSYS2'):
            restore.resolve_msys_tool('pacman',str(binary))
    def test_trusted_keyring_initialization_precedes_signature_check(self):
        calls=[]
        def good(argv,**kwargs):
            calls.append(argv)
            text=b'pkgname = mingw-w64-i686-pkgconf\npkgver = 1~3.0.7-1\narch = any\n' if argv[0]=='bsdtar' else b''
            return subprocess.CompletedProcess(argv,0,text,b'')
        restore.authenticate_package(self.package,self.path,good)
        self.assertIn('--init',calls[0])
        self.assertEqual(calls[1][-2:],['--populate','msys2'])
        self.assertIn('lock-never',calls[2][-1])
        self.assertIn('--verify',calls[3])
    def test_native_child_path_starts_with_qualified_msys2_tools(self):
        root=pathlib.Path(self.temp.name)/'msys64';binary=root/'ucrt64/bin/python.exe';binary.parent.mkdir(parents=True);binary.touch();tool=root/'usr/bin/bash.exe';tool.parent.mkdir(parents=True);tool.touch()
        def child(argv,**kwargs):
            assert_child_identity(self,argv,kwargs['env'],root,binary)
            return subprocess.CompletedProcess(argv,0,b'',b'')
        with patch.object(restore.sys,'executable',str(binary)),patch.object(restore.subprocess,'run',side_effect=child):
            restore.run_msys(['bash','-c','true'],capture_output=True)
    def path_fixture(self):
        root=pathlib.Path(self.temp.name)/'Qualified MSYS2 root'
        binary=root/'ucrt64/bin/python.exe';binary.parent.mkdir(parents=True,exist_ok=True);binary.touch()
        tool=root/'usr/bin/bash.exe';tool.parent.mkdir(parents=True,exist_ok=True);tool.touch()
        return root,binary,tool
    def test_child_identity_refuses_wrong_root_missing_and_inverted_order(self):
        root,binary,tool=self.path_fixture()
        other=root.parent/'Qualified MSYS2 root sibling';other_tool=other/'usr/bin/bash.exe';other_tool.parent.mkdir(parents=True);other_tool.touch()
        good=[str(tool.parent),str(binary.parent),'external']
        for argv,paths in (([str(other_tool)],good),([str(tool)],[str(other_tool.parent),*good[1:]]),([str(tool)],list(reversed(good[:2]))),([str(tool)],[str(root/'missing'),good[1]])):
            with self.subTest(argv=argv,paths=paths):
                with self.assertRaises((AssertionError,OSError)):
                    assert_child_identity(self,argv,{'PATH':os.pathsep.join(paths)},root,binary)
    def test_external_path_cannot_replace_qualified_executable(self):
        root,binary,tool=self.path_fixture()
        external=root.parent/'external';external.mkdir();(external/'bash.exe').touch()
        def child(argv,**kwargs):
            assert_child_identity(self,argv,kwargs['env'],root,binary)
            self.assertEqual(kwargs['env']['PATH'].split(os.pathsep)[2],str(external))
            return subprocess.CompletedProcess(argv,0,b'',b'')
        with patch.object(restore.sys,'executable',str(binary)),patch.object(restore.subprocess,'run',side_effect=child):
            restore.run_msys(['bash','-c','true'],env={'PATH':str(external)})
    @unittest.skipUnless(os.name=='nt','Real Windows 8.3 aliases require native Windows filesystem')
    def test_real_windows_short_long_alias_and_case_identity(self):
        import ctypes
        root,binary,tool=self.path_fixture()
        get_short=ctypes.windll.kernel32.GetShortPathNameW
        get_short.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint];get_short.restype=ctypes.c_uint
        buf=ctypes.create_unicode_buffer(32768);size=get_short(str(binary),buf,len(buf))
        self.assertGreater(size,0);self.assertLess(size,len(buf))
        short=pathlib.Path(buf.value);long=binary.resolve()
        self.assertNotEqual(str(short),str(long),'Native alias fixture must expose distinct short/long spellings')
        self.assertTrue(short.samefile(long));self.assertTrue(pathlib.Path(str(tool).swapcase()).samefile(tool))
        self.assertTrue(pathlib.Path(restore.resolve_msys_tool('bash',str(short))).samefile(tool))
        def child(argv,**kwargs):
            assert_child_identity(self,argv,kwargs['env'],root,binary)
            return subprocess.CompletedProcess(argv,0,b'',b'')
        with patch.object(restore.sys,'executable',str(short)),patch.object(restore.subprocess,'run',side_effect=child):
            restore.run_msys(['bash','-c','true'])
    @unittest.skipUnless(os.name=='nt','Real child PE launch requires native Windows CPython')
    def test_real_native_child_keeps_qualified_executable_and_path_identity(self):
        root,binary,tool=self.path_fixture()
        source_python=pathlib.Path(sys.base_prefix)/"python.exe"
        shutil.copyfile(source_python,binary);shutil.copyfile(source_python,tool)
        for dll in pathlib.Path(sys.base_prefix).glob('python3*.dll'):
            shutil.copyfile(dll,binary.parent/dll.name);shutil.copyfile(dll,tool.parent/dll.name)
        environment=dict(os.environ,PYTHONHOME=sys.base_prefix)
        original=str(source_python)
        with patch.object(restore.sys,'executable',str(binary)):
            result=restore.run_msys(['bash','-c','import json,sys,os;print(json.dumps({"executable":sys.executable,"PATH":os.environ["PATH"]}))'],env=environment,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))
        observed=json.loads(result.stdout)
        assert_child_identity(self,[observed['executable']],{'PATH':observed['PATH']},root,binary)
        self.assertEqual(hashlib.sha256(tool.read_bytes()).digest(),hashlib.sha256(pathlib.Path(original).read_bytes()).digest())
    def test_correct_metadata_accepts_any_package_architecture(self):
        restore.validate_metadata(self.package,'pkgname = mingw-w64-i686-pkgconf\npkgver = 1~3.0.7-1\narch = any\n')

if __name__=='__main__':unittest.main()
