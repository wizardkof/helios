"""Portable checks for the focal controls and the shared native path authority."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import yaml

ROOT = Path(__file__).parents[2]
CI = ROOT / 'ci/windows'

class ComponentControls(unittest.TestCase):
    def test_controls_dispatch_without_product_and_use_real_checker(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/windows-stack.yml').read_text())
        for name in ('component_inputs_control', 'component_msys_control', 'component_checker_control'):
            condition = workflow['jobs'][name]['if']
            for flag in ('infrastructure_only', 'python_evidence_only', 'component_controls_only'):
                self.assertIn('inputs.' + flag, condition)
        job = workflow['jobs']['component_checker_control']
        self.assertEqual(set(job['strategy']['matrix']['component']), {'compatibility', 'loaders', 'opencl', 'package'})
        checker = next(step for step in job['steps'] if step.get('id') == 'checker')
        self.assertIn('Assert-ComponentToolchain.ps1', checker['run'])
        self.assertIn('priorityCount -ne 0', checker['run'])
        self.assertIn('priorityCount -ne 1', checker['run'])
        self.assertFalse(any('Build-' in step.get('run', '') for step in job['steps']))

    @unittest.skipIf(os.name == 'nt', 'Bash fixture is a portable Linux control')
    def test_shared_selector_converts_tool_and_disables_conversion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ninja = root / 'ninja.exe'
            ninja.write_text('fixture')
            converter = root / 'cygpath'
            converter.write_text('#!/bin/sh\n[ "$1" = -m ] || exit 7\nprintf "X:/mounted/ninja.exe\\n"\n')
            converter.chmod(0o755)
            result = subprocess.run(['/bin/bash', '-c', 'source "$1"; helios_select_msys_ninja || exit; printf "%s|%s" "$NINJA" "$MSYS2_ARG_CONV_EXCL"', 'control', str(CI / 'select-msys-ninja.sh')], env={'PATH': str(root)}, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'X:/mounted/ninja.exe|*')
            ninja.unlink()
            missing = subprocess.run(['/bin/bash', '-c', 'source "$1"; helios_select_msys_ninja', 'control', str(CI / 'select-msys-ninja.sh')], env={'PATH': str(root)}, text=True, capture_output=True)
            self.assertNotEqual(missing.returncode, 0)
        for file in ('build-mesa.sh', 'test-msys-ninja.sh'):
            source = (CI / file).read_text()
            self.assertIn('select-msys-ninja.sh', source)
            self.assertIn('helios_select_msys_ninja', source)
            self.assertNotIn('command -v ninja', source)
            self.assertIn("MSYS2_ARG_CONV_EXCL='*'", source)

    def test_consumer_requires_exact_observed_backend_identity(self):
        code = (CI / 'test-msys-ninja.sh').read_text().rsplit("<<'PY'\n", 1)[1].split('\nPY', 1)[0]
        with tempfile.TemporaryDirectory(prefix='helios consumer ') as directory:
            root = Path(directory)
            ninja = root / 'ninja.exe'
            ninja.write_bytes(b'fixture')
            receipt = root / 'receipt.json'
            Path(str(receipt) + '.identity.json').write_text(json.dumps({'path': str(ninja)}))
            def run(backend, poison='false'):
                output = [f'Found ninja.exe-1.13.2 at "{ninja}"', f'INFO: calculating backend command to run: "{backend}" -C "{root}"']
                return subprocess.run([sys.executable, '-c', code, str(receipt), str(ninja), 'UCRT64', '0', '0', '0', '0', poison, '0', '0', *output, output[-1]], capture_output=True, text=True)
            self.assertEqual(run(ninja).returncode, 0)
            self.assertEqual(json.loads(receipt.read_text())['status'], 'PASS')
            self.assertNotEqual(run(str(ninja) + '-other').returncode, 0)
            self.assertEqual(json.loads(receipt.read_text())['status'], 'FAIL')
            self.assertNotEqual(run(ninja, 'true').returncode, 0)
