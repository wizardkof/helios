from pathlib import Path
import unittest
import yaml

ROOT=Path(__file__).parents[2]
class WorkflowTests(unittest.TestCase):
    def test_native_requirements_and_every_upload_roundtrip(self):
        w=yaml.safe_load((ROOT/'.github/workflows/windows-stack.yml').read_text())
        self.assertIn('python_evidence_preflight',w['jobs'])
        for name,job in w['jobs'].items():
            steps=job.get('steps',[])
            for s in steps:
                if 'upload-artifact' not in s.get('uses',''):continue
                self.assertIs(s['with'].get('include-hidden-files'),True,(name,s.get('id')))
                sid=s['id'];ids={x.get('id') for x in steps}
                self.assertIn(sid+'_seal',ids);self.assertIn(sid+'_download',ids);self.assertIn(sid+'_verify',ids)
        run=(ROOT/'ci/windows/Run-CandidateRegressions.ps1').read_text()
        self.assertIn('Initialize-TestPython.ps1',run)
        self.assertIn('& $python -m unittest',run)

    def test_pinned_wheel_is_installed_even_if_same_version_preexists(self):
        bootstrap=(ROOT/'ci/windows/bootstrap_test_python.py').read_text()
        self.assertIn("'--force-reinstall'",bootstrap)
        self.assertIn('yamlDistributionBefore',bootstrap)

    def test_bootstrap_module_can_be_loaded_without_side_effects(self):
        import importlib.util
        spec=importlib.util.spec_from_file_location('bootstrap',ROOT/'ci/windows/bootstrap_test_python.py')
        module=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.PINS['version'],'6.0.2')
