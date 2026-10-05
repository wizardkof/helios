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
