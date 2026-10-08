import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE=Path(__file__).parent
import test_pkgconf_restore as target
import bootstrap_test_python as bootstrap

class HistoricFixtureTests(unittest.TestCase):
    def test_validator_exists(self):
        self.assertTrue(hasattr(target, 'validate_historical_archives'))
    def test_original_inventory_accepts_extension(self):
        self.assertTrue(hasattr(target, 'validate_historical_archives'))
        target.validate_historical_archives(json.loads((HERE/'ci-toolchain-pins.json').read_text()))
    def test_original_inventory_refuses_mutations(self):
        self.assertTrue(hasattr(target, 'validate_historical_archives'))
        original=json.loads((HERE/'ci-toolchain-pins.json').read_text())
        changes=[('sha256','0'*64),('version','wrong'),('architecture','wrong')]
        origin=copy.deepcopy(original);origin["msys2ArchivedPackages"]["baseUrl"]="https://invalid.example/archive"
        variants=[origin]
        removed=copy.deepcopy(original);removed['msys2ArchivedPackages']['packages'].pop(0);variants.append(removed)
        for field,value in changes:
            changed=copy.deepcopy(original);changed['msys2ArchivedPackages']['packages'][0][field]=value;variants.append(changed)
        duplicate=copy.deepcopy(original);row=copy.deepcopy(duplicate['msys2ArchivedPackages']['packages'][0]);row['sha256']='0'*64;duplicate['msys2ArchivedPackages']['packages'].append(row);variants.append(duplicate)
        for variant in variants:
            with self.subTest(variant=variant):
                with self.assertRaises(ValueError):target.validate_historical_archives(variant)
    def test_missing_or_malformed_fixture_fails(self):
        self.assertTrue(hasattr(target, 'validate_historical_archives'))
        original=json.loads((HERE/'ci-toolchain-pins.json').read_text())
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'fixture.json'
            with self.assertRaises((ValueError,OSError)):target.validate_historical_archives(original,p)
            for data in (b'not-json',b'{}',b'{"packages": []}'):
                p.write_bytes(data)
                with self.assertRaises(ValueError):target.validate_historical_archives(original,p)

class NativeWorkflowConditions(unittest.TestCase):
    def test_shallow_native_preflight_preserves_red_and_green_conditions(self):
        text=(HERE.parents[1]/'.github/workflows/windows-stack.yml').read_text()
        job=text.split('  python_evidence_preflight:',1)[1].split('  producer_audit_control:',1)[0]
        self.assertIn('native_python_recovery_control.py',job)
        self.assertIn('fetch-depth: 1',job)
        self.assertIn('Initialize-TestPython.ps1 -Control -Tests',job)
        self.assertIn('python-native-recovery-red',job)

class BootstrapCompletionTests(unittest.TestCase):
    def test_first_suite_failure_retains_second_log_and_first_exit(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);calls=[]
            def execute(cmd,stdout,stderr):
                calls.append(cmd);stdout.write('actual suite '+str(len(calls))+'\n')
                return subprocess.CompletedProcess(cmd,23 if len(calls)==1 else 0)
            with patch.object(bootstrap.subprocess,'run',side_effect=execute),patch.object(bootstrap.subprocess,'check_output',return_value=b'{"executable": "qualified-python", "version": "fixture"}'):
                with self.assertRaises(ValueError):bootstrap.run_tests('qualified-python',root)
            self.assertEqual(len(calls),2)
            self.assertTrue((root/'tests-0.log').is_file());self.assertTrue((root/'tests-1.log').is_file())
            result=json.loads((root/'test-results.json').read_text())
            self.assertEqual(result['status'],'FAIL');self.assertEqual(result['firstFailureIndex'],0)
            self.assertEqual(result['testInterpreter']['executable'],'qualified-python')
            self.assertIn('controllerIdentity',result)
            self.assertEqual([r['exitCode'] for r in result['suites']],[23,0])

if __name__=='__main__':unittest.main()
