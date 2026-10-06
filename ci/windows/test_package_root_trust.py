import unittest
from pathlib import Path
class RootTrustDiagnosticTests(unittest.TestCase):
    def test_transform_preserves_every_nontrust_statement(self):
        import package_root_trust as trust
        p=Path(__file__).parent/'Audit-CIPackage.ps1'
        original=p.read_text()
        changed=trust.transform(original)
        self.assertEqual(trust.restore(changed),original)
        self.assertNotIn('Import-Certificate',changed)
        for command in ('verify /pa /v /c $cat','Get-AuthenticodeSignature','--file-headers','Driver version mismatch'):
            self.assertIn(command,changed)
    def test_unknown_source_fails_closed(self):
        import package_root_trust as trust
        with self.assertRaises(ValueError):trust.transform('Write-Host PASS')
