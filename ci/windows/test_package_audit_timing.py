import unittest
from pathlib import Path

class TimingControlTests(unittest.TestCase):
    def test_instrumentation_reverses_to_original(self):
        import package_audit_timing as timing
        original=(Path(__file__).parent/'Audit-CIPackage.ps1').read_text()
        transformed=timing.instrument(original)
        self.assertEqual(timing.restore(transformed),original)
        for name in ['CERTIFICATE','DRIVER_CAT_SIGNATURE','LLVM_READOBJ','SIGNTOOL','HASH','INF','SCRIPT_PARSE','INSTALL_STATIC','MANIFEST','SHIM','CERTIFICATE_CLEANUP']:
            self.assertIn(name, transformed)
        self.assertIn('AuditEvent INF BEGIN\n$inf=',transformed)
        self.assertNotIn('kind=$(if(Get-Variable isDriver',transformed)
        self.assertIn('verify /pa /v /c $cat',transformed)
        self.assertIn('verify /pa /v $file.FullName',transformed)
    def test_focal_job_cannot_run_product_or_lose_artifact_permission(self):
        import yaml
        w=yaml.safe_load((Path(__file__).parents[2]/'.github/workflows/windows-stack.yml').read_text())
        for name,job in w['jobs'].items():
            if name=='package_path_control':
                self.assertIn('inputs.package_path_only',job['if'])
            elif name=='package_audit_timing':
                self.assertEqual(job['permissions']['actions'],'read')
                self.assertEqual(job['timeout-minutes'],120)
            else:self.assertIn('!inputs.package_audit_timing_only',job['if'])
    def test_unknown_source_fails_closed(self):
        import package_audit_timing as timing
        with self.assertRaises(ValueError): timing.instrument('Write-Host PASS')
if __name__=='__main__': unittest.main()
