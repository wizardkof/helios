import importlib.util,json,tempfile,unittest,hashlib
from pathlib import Path
SPEC=importlib.util.spec_from_file_location('ci_evidence',Path(__file__).with_name('ci_evidence.py'))
class EvidenceTests(unittest.TestCase):
 def setUp(self):
  self.assertTrue(Path(SPEC.origin).exists(),'real collector missing')
  self.m=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(self.m)
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.p=Path(self.tmp.name)
 def entry(self,name,source,step='success',required=True):return dict(name=name,source=str(source),outcome=step,required=required)
 def test_distinct_volumes_and_duplicate_names(self):
  rows=[]
  for drive in ['C','D']:
   f=self.p/drive/'same.json';f.parent.mkdir();f.write_text(drive);rows.append(self.entry(drive,f))
  r=self.m.collect(rows,self.p/'out','failure');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'PASS');self.assertEqual([x['destination'] for x in r['files']],['C/same.json','D/same.json'])
 def test_component_qualification_and_identity(self):
  f=self.p/'component-qualification'/'windows-kit.json';f.parent.mkdir();f.write_bytes(b'{"status":"FAIL"}')
  r=self.m.collect([self.entry('kit',f.parent)],self.p/'out','failure');self.m.verify(self.p/'out');self.assertEqual(f.read_bytes(),(self.p/'out/kit/windows-kit.json').read_bytes());self.assertEqual(r['files'][0]['sha256'],hashlib.sha256(f.read_bytes()).hexdigest())
 def test_failure_before_build_is_not_run(self):
  r=self.m.collect([self.entry('build',self.p/'missing','skipped')],self.p/'out','failure');self.assertEqual(r['sources'][0]['status'],'NOT_RUN');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'PASS')
 def test_mandatory_receipt_missing_is_failure(self):
  r=self.m.collect([self.entry('kit',self.p/'missing','failure')],self.p/'out','failure');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'FAIL');self.assertEqual(r['sources'][0]['status'],'MISSING_REQUIRED')
 def test_tamper_rejected(self):
  f=self.p/'a.json';f.write_text('a');self.m.collect([self.entry('a',f)],self.p/'out','failure');(self.p/'out/a/a.json').write_text('b')
  with self.assertRaises(ValueError):self.m.verify(self.p/'out')
 def test_glob_same_filename_preserves_parents(self):
  for component in ['vulkan','opencl']:
   f=self.p/'build'/component/'CMakeCache.txt';f.parent.mkdir(parents=True);f.write_text(component)
  r=self.m.collect([self.entry('cmake',self.p/'build/*/CMakeCache.txt')],self.p/'out','failure')
  self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'PASS');self.assertEqual(len(r['files']),2);self.m.verify(self.p/'out')
 def test_glob_meson_directories_preserve_configuration(self):
  for config in ['Release','Debug']:
   f=self.p/'driver'/config/'dxvk'/'meson-logs'/'meson-log.txt';f.parent.mkdir(parents=True);f.write_text(config)
  r=self.m.collect([self.entry('meson',self.p/'driver/*/*/meson-logs')],self.p/'out','failure')
  self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'PASS');self.assertEqual(len(r['files']),2);self.m.verify(self.p/'out')
 def test_real_configuration_expansion_release_debug(self):
  self.assertTrue(hasattr(self.m,'expand_sources'),'shared native source expansion missing')
  for config in ['Release','Debug']:
   entries=[self.entry('package',Path('{TEMP}')/('installer-{CONFIG}-producer.log'))]
   self.assertEqual(self.m.expand_sources(entries,str(self.p),config)[0]['source'],str(self.p/('installer-'+config+'-producer.log')))
 def test_private_material_refused(self):
  f=self.p/'secret.pfx';f.write_text('secret');r=self.m.collect([self.entry('bad',f)],self.p/'out','failure');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'FAIL');self.assertFalse((self.p/'out/bad/secret.pfx').exists())
if __name__=='__main__':unittest.main()
