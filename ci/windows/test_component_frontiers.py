import ast
from pathlib import Path
import unittest
import yaml

ROOT=Path(__file__).resolve().parents[2]

class FrontierContracts(unittest.TestCase):
    def test_meson_import_identity_order(self):
        tree=ast.parse((ROOT/'ci/windows/meson-isolated.py').read_text())
        imports=[ast.unparse(n) for n in tree.body if isinstance(n,(ast.Import,ast.ImportFrom))]
        self.assertLess(imports.index('from mesonbuild import mesonmain'),imports.index('import mesonbuild.wrap.wrap as wrap'))
        self.assertLess(imports.index('from mesonbuild import mesonmain'),imports.index('from pathlib import Path'))

    def test_probe_resolves_single_header_authority(self):
        source=ROOT/'tools/d3d12_devicecreate_probe.cpp'
        self.assertIn('#include "fullstack/probe_common.h"',source.read_text())
        self.assertTrue((source.parent/'fullstack/probe_common.h').is_file())
        self.assertFalse((source.parent/'probe_common.h').exists())

    def test_budget_leaves_preservation_steps_and_controls_do_not_build_product(self):
        workflow=yaml.safe_load((ROOT/'.github/workflows/windows-stack.yml').read_text())
        job=workflow['jobs']['opencl']
        self.assertEqual(job['timeout-minutes'],360)
        self.assertIn('19800',(ROOT/'ci/windows/Invoke-OpenCLBudget.ps1').read_text())
        self.assertTrue(any('AddMinutes(330)' in s.get('run','') for s in job['steps']))
        self.assertIn('Invoke-OpenCLBudget.ps1',next(s for s in job['steps'] if s.get('name')=='Build CLVK')['run'])
        for name in ('collect_evidence','upload_evidence_seal','upload_evidence','upload_evidence_verify'):
            self.assertIn('always()',next(s for s in job['steps'] if s.get('id')==name)['if'])
        control=workflow['jobs']['frontier_opencl_control']
        self.assertFalse(any('Build-OpenCL.ps1 -' in s.get('run','') for s in control['steps']))
        self.assertIn('frontier_controls_only',control['if'])
        self.assertIn('!inputs.frontier_controls_only',workflow['jobs']['python_evidence_preflight']['if'])
