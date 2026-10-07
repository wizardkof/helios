import unittest
from pathlib import Path
import package_memory_audit
class DiagnosticAuditPreservation(unittest.TestCase):
 def test_only_reviewed_trust_operations_change_and_reverse(self):
  original=Path(__file__).with_name('Audit-CIPackage.ps1').read_text(encoding='utf-8-sig')
  changed=package_memory_audit.transform(original)
  self.assertNotIn('Import-Certificate',changed)
  self.assertNotIn('Cert:\\CurrentUser\\Root',changed)
  self.assertIn('Invoke-MemoryAuditVerification',changed)
  self.assertNotIn('signtool verify',changed)
  self.assertIn('qualified package-verify catalog-member',changed)
  self.assertEqual(package_memory_audit.restore(changed),original)
 def test_changed_source_anchor_is_refused(self):
  original=Path(__file__).with_name('Audit-CIPackage.ps1').read_text(encoding='utf-8-sig')
  with self.assertRaises(ValueError):package_memory_audit.transform(original.replace('& $sign verify /pa /v /c $cat $file.FullName','changed verification'))
