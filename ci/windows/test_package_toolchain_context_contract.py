import json
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).parents[2]
PS = ROOT / 'ci/windows/Test-PackageToolchainContext.ps1'
WORKFLOW = ROOT / '.github/workflows/windows-stack.yml'
CATALOG = ROOT / 'ci/windows/ci-evidence-sources.json'


class PackageToolchainContextContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = PS.read_text() if PS.exists() else ''
        workflow = yaml.safe_load(WORKFLOW.read_text())
        cls.workflow = workflow.get('on', workflow.get(True))
        cls.jobs = workflow['jobs']
        cls.driver = cls.jobs['driver']
        cls.sources = json.loads(CATALOG.read_text())

    def test_control_exercises_all_six_context_phase_cases(self):
        for token in (
            "name='positive'", "name='absent'", "name='divergent'",
            "@('pre','post')", "RUSTUP_MAX_RETRIES",
            'Assert-ComponentToolchain.ps1', '@parameters',
            'Get-ProcessEnvironmentSnapshot', 'Restore-ProcessEnvironment',
            'control-summary.json', 'Write-Host', 'CHECKER_EXCEPTION',
        ):
            with self.subTest(token=token):
                self.assertIn(token, self.script)

    def test_control_correlates_real_tools_to_native_receipt(self):
        for token in ('NativeToolchainReceipt', 'rustup', 'rustc', 'cargo',
                      'resolvedPath', 'sha256', 'observedVersion', 'exitCode',
                      'RUST_TOOLCHAIN', 'RUSTUP_TOOLCHAIN', '10'):
            with self.subTest(token=token):
                self.assertIn(token, self.script)
        self.assertNotIn('fixture', self.script.lower())

    def test_workflow_runs_scoped_step_after_r3_and_real_pins(self):
        steps = self.driver['steps']
        by_id = {step.get('id'): i for i, step in enumerate(steps) if step.get('id')}
        target = next((i for i, s in enumerate(steps)
                       if s.get('id') == 'package_toolchain_context'), None)
        self.assertIsNotNone(target)
        self.assertGreater(target, by_id['rustup_identity_tests'])
        self.assertGreater(target, by_id['s17'])
        self.assertGreater(target, by_id['s18'])
        step = steps[target]
        self.assertEqual(step['shell'], 'pwsh')
        self.assertIn('inputs.infrastructure_only', step['if'])
        self.assertIn('rustup_identity_tests.outcome == \'success\'', step['if'])
        self.assertIn('s17.outcome == \'success\'', step['if'])
        self.assertIn('s18.outcome == \'success\'', step['if'])
        self.assertNotIn('RUSTUP_MAX_RETRIES', step.get('env', {}))
        self.assertNotIn('component_controls_only', step['if'])
        self.assertNotIn('package_production_integration_preflight', step['if'])
        self.assertNotIn('RUSTUP_MAX_RETRIES', step.get('env', {}))
        for job_name in ('mesa', 'mesa_x86', 'opencl', 'loaders', 'compatibility', 'package'):
            self.assertIn('!inputs.infrastructure_only', self.jobs[job_name]['if'])
        self.assertNotIn('RUSTUP_MAX_RETRIES', self.driver.get('env', {}))
        self.assertNotIn('inputs.infrastructure_only', self.jobs['package_production_integration_preflight']['if'])
        self.assertEqual(self.jobs['package']['env']['RUSTUP_MAX_RETRIES'], '10')
        self.assertIn("environment.get('RUSTUP_MAX_RETRIES') != '10'",
                      (ROOT / 'ci/windows/acquire_package_rust.py').read_text())

    def test_catalog_requires_every_context_receipt_on_success(self):
        entry = next((e for e in self.sources['driver']
                      if e['name'] == 'package-toolchain-context'), None)
        self.assertIsNotNone(entry)
        self.assertEqual(entry['step'], 'package_toolchain_context')
        self.assertTrue(entry['required'])
        self.assertCountEqual(entry['mandatoryFilesOnSuccess'], [
            'control-summary.json',
            'positive/pre/pre-producer-tools.json', 'positive/post/post-producer-tools.json',
            'absent/pre/pre-producer-tools.json', 'absent/post/post-producer-tools.json',
            'divergent/pre/pre-producer-tools.json', 'divergent/post/post-producer-tools.json',
            'toolchain-correlation.json',
        ])

    def test_canonical_checker_and_acquisition_contract_stay_exact(self):
        checker = (ROOT / 'ci/windows/Assert-ComponentToolchain.ps1').read_text()
        acquisition = (ROOT / 'ci/windows/acquire_package_rust.py').read_text()
        self.assertIn("Add-ComponentValueCheck 'RUSTUP_MAX_RETRIES' '10'", checker)
        self.assertIn("environment.get('RUSTUP_MAX_RETRIES') != '10'", acquisition)
        self.assertIn("env=environment", acquisition)


if __name__ == '__main__':
    unittest.main()
