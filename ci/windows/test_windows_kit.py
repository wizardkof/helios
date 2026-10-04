import importlib.util,json,copy,unittest
from pathlib import Path
class KitTests(unittest.TestCase):
 def setUp(self):
  path=Path(__file__).with_name('windows_kit.py');self.assertTrue(path.exists(),'real kit checker missing')
  spec=importlib.util.spec_from_file_location('windows_kit',path);self.m=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.m)
  self.k=json.loads(path.with_name('ci-toolchain-pins.json').read_text())['windowsKit']
  self.o={'queryStatus':'PASS','family':self.k['family'],'inventory':[dict(DisplayName=c['name'],DisplayVersion=c['version'],productCode=c['productCode']) for c in self.k['components']], 'files':[dict(path=f['path'],size=1,sha256='a'*64) for f in self.k['selectedFiles']]}
 def test_coherent(self):self.assertEqual(self.m.check(self.k,self.o)['status'],'PASS')
 def test_contradictory_bootstrap(self):
  self.k['acquisition']['sdk']['componentVersion']='10.1.26100.2454';self.assertEqual(self.m.check(self.k,self.o)['status'],'FAIL')
 def test_missing_component(self):self.o['inventory'].pop();self.assertEqual(self.m.check(self.k,self.o)['PINNED_COMPONENT_IDENTITY'],'FAIL')
 def test_wrong_revision(self):self.o['inventory'][0]['DisplayVersion']='10.1.26100.1';self.assertEqual(self.m.check(self.k,self.o)['status'],'FAIL')
 def test_unknown_qfe(self):self.o['inventory'][0]['DisplayVersion']='';self.assertEqual(self.m.check(self.k,self.o)['status'],'FAIL')
 def test_family_alone_insufficient(self):self.o['inventory']=[];self.assertEqual(self.m.check(self.k,self.o)['KIT_FAMILY_COMPATIBILITY'],'PASS');self.assertEqual(self.m.check(self.k,self.o)['status'],'FAIL')
 def test_irrelevant_global_product(self):self.o['inventory'].append(dict(DisplayName='Unselected SDK arm64',DisplayVersion='99'));self.assertEqual(self.m.check(self.k,self.o)['status'],'PASS')
 def test_overlap_same_component_not_ignored(self):self.o['inventory'].append(dict(self.o['inventory'][0],DisplayVersion='99'));self.assertEqual(self.m.check(self.k,self.o)['status'],'FAIL')
 def test_selected_input_missing(self):self.o['files'].pop();self.assertEqual(self.m.check(self.k,self.o)['SELECTED_BUILD_INPUTS'],'FAIL')
 def test_failure_receipt_complete(self):
  self.o['queryStatus']='FAIL';r=self.m.check(self.k,self.o)
  for key in ['requested','observed','failures','selectedPaths','queryStatus','KIT_FAMILY_COMPATIBILITY','PINNED_COMPONENT_IDENTITY','SELECTED_BUILD_INPUTS']:self.assertIn(key,r)
if __name__=='__main__':unittest.main()
