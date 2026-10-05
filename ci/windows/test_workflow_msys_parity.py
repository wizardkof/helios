"""Structural parity checks for the Windows workflow's pinned MSYS2 producers."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).parents[2]
WORKFLOW = yaml.safe_load((ROOT / '.github/workflows/windows-stack.yml').read_text())
INFRA = '${{ always() && inputs.infrastructure_only }}'
PRODUCT = '${{ always() && !inputs.infrastructure_only }}'


class WorkflowMsysParityTests(unittest.TestCase):
    def setUp(self):
        self.jobs = WORKFLOW['jobs']

    def test_infrastructure_mode_provisions_and_checks_without_product(self):
        driver = self.jobs['driver']
        steps = {s.get('id'): s for s in driver['steps']}
        provision = steps['msys2_archive']
        self.assertEqual(provision.get('if'), '${{ always() }}')
        self.assertIn('Install-PinnedMSYS2Packages.py" x64 ', provision['run'])
        self.assertEqual(steps['msys2_archive_verify'].get('if'), INFRA)
        self.assertEqual(steps['msys_ninja_control'].get('if'), INFRA)
        for name in ('mesa', 'mesa_x86', 'opencl', 'loaders', 'compatibility', 'package'):
            self.assertIn('!inputs.infrastructure_only', self.jobs[name]['if'])
        self.assertEqual(steps['s19'].get('if'), '${{ !inputs.infrastructure_only }}')
        self.assertEqual(steps['s20'].get('if'), '${{ !inputs.infrastructure_only }}')

    def test_each_mesa_job_provisions_its_own_architecture_before_consumers(self):
        expected = {'mesa': ('UCRT64', 'x64'), 'mesa_x86': ('MINGW32', 'x86')}
        for job_name, (msystem, arch) in expected.items():
            job = self.jobs[job_name]
            setup = next(s for s in job['steps'] if s.get('uses', '').startswith('msys2/setup-msys2@'))
            self.assertEqual(setup['with']['msystem'], msystem)
            steps = job['steps']
            provision_index = next(i for i, s in enumerate(steps) if s.get('id') == 'msys2_archive_product')
            verify_index = next(i for i, s in enumerate(steps) if s.get('id') == 'msys_ninja_control')
            consumer_index = next(i for i, s in enumerate(steps) if s.get('id') == 's08')
            provision, verify = steps[provision_index], steps[verify_index]
            self.assertEqual(provision.get('if'), '${{ !inputs.infrastructure_only }}')
            self.assertIn('Install-PinnedMSYS2Packages.py" ' + arch + ' ', provision['run'])
            self.assertEqual(verify.get('if'), '${{ !inputs.infrastructure_only }}')
            self.assertIn('assert_msys_pins.py" ' + arch + ' ', verify['run'])
            self.assertIn('$RUNNER_TEMP/msys2-pins.json', verify['run'])
            self.assertLess(provision_index, verify_index)
            self.assertLess(verify_index, consumer_index)
            self.assertEqual(steps[consumer_index].get('if'), '${{ !inputs.infrastructure_only }}')

    def test_msys_provisioning_failure_blocks_consumer_and_evidence_still_runs(self):
        for job_name in ('mesa', 'mesa_x86'):
            steps = self.jobs[job_name]['steps']
            provision = next(i for i, s in enumerate(steps) if s.get('id') == 'msys2_archive_product')
            consumer = next(i for i, s in enumerate(steps) if s.get('id') == 's08')
            collect = next(s for s in steps if s.get('id') == 'collect_evidence')
            upload = next(s for s in steps if s.get('id') == 'upload_evidence')
            self.assertLess(provision, consumer)
            self.assertNotIn('continue-on-error', steps[provision])
            self.assertEqual(collect.get('if'), 'always()')
            self.assertIn('always()', upload.get('if', ''))
            self.assertIn('upload_evidence_seal.outcome', upload.get('if', ''))


    def test_x86_infrastructure_proof_job_isolated_from_product(self):
        job = self.jobs['msys2_x86_preflight']
        self.assertEqual(job.get('if'), '${{ always() && inputs.infrastructure_only && !inputs.python_evidence_only }}')
        setup = next(s for s in job['steps'] if s.get('id') == 'setup_msys2')
        self.assertEqual(setup['with']['msystem'], 'MINGW32')
        provision = next(s for s in job['steps'] if s.get('id') == 'msys2_archive')
        verify = next(s for s in job['steps'] if s.get('id') == 'msys_ninja_control')
        self.assertIn('Install-PinnedMSYS2Packages.py" x86 ', provision['run'])
        self.assertIn('test-msys-ninja.sh', verify['run'])
        self.assertEqual(verify.get('shell'), 'msys2 {0}')
        upload = next(s for s in job['steps'] if s.get('id') == 'upload_evidence')
        self.assertIn('always()', upload.get('if', ''))
        self.assertIn('upload_evidence_seal.outcome', upload.get('if', ''))
        for name in ('release', 'driver_build', 'product'):
            self.assertNotIn(name, job.get('steps', []))


    def test_x86_infrastructure_proof_job_isolated_from_product(self):
        job = self.jobs['msys2_x86_preflight']
        self.assertEqual(job.get('if'), '${{ always() && inputs.infrastructure_only && !inputs.python_evidence_only }}')
        setup = next(s for s in job['steps'] if s.get('id') == 'setup_msys2')
        self.assertEqual(setup['with']['msystem'], 'MINGW32')
        provision = next(s for s in job['steps'] if s.get('id') == 'msys2_archive')
        verify = next(s for s in job['steps'] if s.get('id') == 'msys_ninja_control')
        self.assertIn('Install-PinnedMSYS2Packages.py" x86 ', provision['run'])
        self.assertIn('test-msys-ninja.sh', verify['run'])
        self.assertEqual(verify.get('shell'), 'msys2 {0}')
        upload = next(s for s in job['steps'] if s.get('id') == 'upload_evidence')
        self.assertIn('always()', upload.get('if', ''))
        self.assertIn('upload_evidence_seal.outcome', upload.get('if', ''))

    def test_product_setup_packages_contain_the_archived_tools_pin(self):
        for job_name, prefix in (('mesa', 'mingw-w64-ucrt-x86_64-tools'),
                                 ('mesa_x86', 'mingw-w64-i686-tools')):
            setup = next(s for s in self.jobs[job_name]['steps']
                         if s.get('uses', '').startswith('msys2/setup-msys2@'))
            self.assertIn(prefix, setup['with']['install'])


if __name__ == '__main__':
    unittest.main()
