import pathlib,unittest,yaml
ROOT=pathlib.Path(__file__).resolve().parents[2]
class WorkflowTests(unittest.TestCase):
 def test_diagnostic_mode_is_registered_and_blocks_driver(self):
  w=yaml.safe_load((ROOT/'.github/workflows/windows-stack.yml').read_text())
  inputs=(w.get('on') or w.get(True))['workflow_dispatch']['inputs']
  self.assertIn('pkgconf_restore_only',inputs)
  self.assertIn('!inputs.pkgconf_restore_only',w['jobs']['driver']['if'])
  self.assertIn('!inputs.pkgconf_restore_only',w['jobs']['python_evidence_preflight']['if'])
  job=w['jobs']['pkgconf_restore_preflight']
  self.assertEqual({x['arch'] for x in job['strategy']['matrix']['include']},{'x64','x86'})
  self.assertIn('inputs.infrastructure_only',job['if'])
  self.assertIn('inputs.python_evidence_only',job['if'])
  self.assertIn('inputs.pkgconf_restore_only',job['if'])
  checkout=next(s for s in job['steps'] if s.get('id')=='checkout')
  self.assertEqual(checkout['with']['fetch-depth'],0,'baseline commit must be available for preservation test')
  for step in job['steps']:
   self.assertNotIn('Build-Windows',step.get('run',''))
   self.assertNotIn('reserve',step.get('run',''))
 def test_final_restore_is_followed_only_by_query_and_checker(self):
  text=(ROOT/'ci/windows/pkgconf_native_preflight.py').read_text()
  final=text[text.index('for iteration in (1, 2):'):]
  self.assertNotIn('["pacman", "-S"',final)
  self.assertIn('assert_msys_pins.py',final)
if __name__=='__main__':unittest.main()
