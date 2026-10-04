import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from test_packaged_install_state import bundle

spec=importlib.util.spec_from_file_location('ci_package',Path(__file__).with_name('Verify-CIPackage.py'))
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)

class FinalPackageTests(unittest.TestCase):
 def fixture(self,root):
  manifest={'packageId':'fixture','version':'22.22.999.0','configuration':'Release','candidate':{'sourceFingerprint':'a'*64},'source':{'helios':'b'*40},'files':[]}
  entries=[('manifest.json',json.dumps(manifest).encode()),('README.md',b'fixture')]
  staged=root/'staging/fixture';staged.mkdir(parents=True)
  for name,data in entries:(staged/name).write_bytes(data)
  setup=root/'fixture/HeliosSetup.exe';setup.parent.mkdir();setup.write_bytes(bundle(entries))
  with zipfile.ZipFile(root/'fixture.zip','w') as z:z.writestr('fixture/HeliosSetup.exe',setup.read_bytes())
  return setup,staged
 def test_exact_final_setup_roundtrip(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);self.fixture(root);gate.verify(root)
   receipt=json.loads((root/'extraction-roundtrip.json').read_text())
   self.assertEqual(receipt['files'],2)
   self.assertEqual((root/'extraction-verify/README.md').read_bytes(),b'fixture')
 def test_staging_mutation_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);_,staged=self.fixture(root);(staged/'README.md').write_bytes(b'changed')
   with self.assertRaisesRegex(ValueError,'staging'):gate.verify(root)
 def test_zip_setup_identity_mismatch_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);self.fixture(root)
   with zipfile.ZipFile(root/'fixture.zip','w') as z:z.writestr('fixture/HeliosSetup.exe',b'wrong bytes')
   with self.assertRaisesRegex(ValueError,'ZIP/setup'):gate.verify(root)
 def test_ambiguous_final_setup_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);setup,_=self.fixture(root);second=root/'other/HeliosSetup.exe';second.parent.mkdir();second.write_bytes(setup.read_bytes())
   with self.assertRaisesRegex(ValueError,'exactly one'):gate.verify(root)
if __name__=='__main__':unittest.main()
