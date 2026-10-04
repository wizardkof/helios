import json
from pathlib import Path
import tempfile
import unittest
from ci_artifact import seal, verify

class ArtifactAdmissionTests(unittest.TestCase):
 def fixture(self, root):
  (root/'payload.dll').write_bytes(b'qualified product bytes')
  return {'version':'22.22.999.0','sourceFingerprint':'a'*64,'headSha':'b'*40,'runId':'1','runAttempt':'1','component':'mesa','configuration':'Release','architecture':'x64'}
 def test_exact_producer_bytes_admitted(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);identity=self.fixture(root);seal(root,identity);self.assertEqual(verify(root,identity)['files'][0]['path'],'payload.dll')
 def test_mutated_bytes_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);identity=self.fixture(root);seal(root,identity);(root/'payload.dll').write_bytes(b'foreign bytes')
   with self.assertRaisesRegex(ValueError,'bytes'):verify(root,identity)
 def test_cross_run_identity_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);identity=self.fixture(root);seal(root,identity)
   with self.assertRaisesRegex(ValueError,'identity'):verify(root,dict(identity,runId='2'))
 def test_undeclared_additional_output_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);identity=self.fixture(root);seal(root,identity);(root/'extra.dll').write_bytes(b'extra')
   with self.assertRaisesRegex(ValueError,'bytes'):verify(root,identity)
if __name__=='__main__':unittest.main()
