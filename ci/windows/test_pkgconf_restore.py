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

class ManifestTests(unittest.TestCase):
    def test_both_pkgconf_pins_have_authenticated_archive_entries(self):
        m=json.loads((HERE/"ci-toolchain-pins.json").read_text())
        rows={p["name"]:p for p in m["msys2ArchivedPackages"]["packages"]}
        for name in ["mingw-w64-i686-pkgconf", "mingw-w64-ucrt-x86_64-pkgconf"]:
            self.assertIn(name,rows)
            self.assertEqual(rows[name]["version"],"1~3.0.7-1")
            self.assertEqual(len(rows[name]["sha256"]),64)
    def test_previous_seven_archives_are_preserved(self):
        import subprocess
        before=json.loads(subprocess.check_output(["git","show","6437badff87d903a4bab4d4f1cc7f9e682e50bea:ci/windows/ci-toolchain-pins.json"],cwd=HERE))
        after=json.loads((HERE/"ci-toolchain-pins.json").read_text())
        for row in before["msys2ArchivedPackages"]["packages"]:
            self.assertIn(row,after["msys2ArchivedPackages"]["packages"])

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
    def test_correct_metadata_accepts_any_package_architecture(self):
        restore.validate_metadata(self.package,'pkgname = mingw-w64-i686-pkgconf\npkgver = 1~3.0.7-1\narch = any\n')

if __name__=='__main__':unittest.main()
