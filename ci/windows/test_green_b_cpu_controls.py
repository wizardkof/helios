import importlib.util
import pathlib
import tempfile
import unittest
import sys

class Controls(unittest.TestCase):
    def runner(self):
        spec=importlib.util.spec_from_file_location('runner', pathlib.Path(__file__).with_name('run_green_b_cpu_controls.py'))
        module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module

    def test_required_production_commands_are_present(self):
        runner=self.runner(); jobs=runner.commands(pathlib.Path('/source'),pathlib.Path('/receipts'),'clang')
        names={name for name,_ in jobs}
        self.assertTrue({'protocol','kmd_logic','production_wiring','green_b_submit_production','green_b_wait_production','carrier_producer','attest_flow'} <= names)
        self.assertEqual(6,len([n for n in names if n.endswith('_execute')]))
        for name,cmd in jobs:
            if name in ('protocol','kmd_logic'): self.assertIn('--locked',cmd)

    def test_first_failure_is_preserved_and_later_job_not_run(self):
        runner=self.runner()
        with tempfile.TemporaryDirectory() as folder:
            p=pathlib.Path(folder)
            jobs=[('first',[sys.executable,'-c',"import sys;print('out');print('err',file=sys.stderr);sys.exit(7)"]),('later',[sys.executable,'-c',"raise AssertionError('must not run')"])]
            result=runner.run_jobs(jobs,p)
            self.assertEqual(7,result)
            self.assertEqual('out\n',(p/'first.stdout.txt').read_text())
            self.assertEqual('err\n',(p/'first.stderr.txt').read_text())
            self.assertFalse((p/'later.stdout.txt').exists())

    def test_child_uses_utf8_and_cannot_skip_or_substitute_source(self):
        runner=self.runner()
        import os
        from unittest.mock import patch
        with patch.dict(os.environ, {'PYTHONUTF8':'0','P06_SOURCE':'foreign.c','P06_COMPILE_ONLY':'1'}):
            env=runner.child_environment(pathlib.Path('/source'),pathlib.Path('/receipts'),'clang')
        self.assertEqual('1',env['PYTHONUTF8'])
        self.assertNotIn('P06_SOURCE',env)
        self.assertNotIn('P06_COMPILE_ONLY',env)
        result=__import__('subprocess').run([sys.executable,'-c','import sys;assert sys.flags.utf8_mode == 1'],env=env)
        self.assertEqual(0,result.returncode)

    def test_undecodable_native_output_is_preserved_before_failure(self):
        runner=self.runner()
        with tempfile.TemporaryDirectory() as folder:
            p=pathlib.Path(folder)
            result=runner.run_jobs([('native',[sys.executable,'-c',"import sys;sys.stdout.buffer.write(bytes([144]));sys.stderr.buffer.write(bytes([165]));sys.exit(9)"])],p)
            self.assertEqual(9,result)
            self.assertEqual(bytes([144]),(p/'native.stdout.txt').read_bytes())
            self.assertEqual(bytes([165]),(p/'native.stderr.txt').read_bytes())

    def test_driver_invokes_controls_before_dxvk_build(self):
        self.runner()
        text=pathlib.Path(__file__).with_name('Run-CandidateRegressions.ps1').read_text()
        self.assertLess(text.index('run_green_b_cpu_controls.py'),text.index('$dxvk=Join-Path'))

if __name__=='__main__': unittest.main()
