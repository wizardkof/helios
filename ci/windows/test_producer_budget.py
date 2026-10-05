"""Exercise the real producer supervisor without building CLVK."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent

@unittest.skipUnless(os.name == "nt", "Native Windows Job Object control")
class BudgetTests(unittest.TestCase):
    def execute(self, code, budget=15):
        root = Path(tempfile.mkdtemp(prefix='helios-budget-', dir=getattr(self, 'root', None)))
        child = root / 'child.py'
        child.write_text(code, encoding='utf-8')
        command = root / 'command.json'
        command.write_text(json.dumps([sys.executable, str(child)]), encoding='utf-8')
        result = subprocess.run([sys.executable, str(HERE / 'producer_budget.py'), '--command-file', str(command), '--receipt-dir', str(root), '--budget-seconds', str(budget)], timeout=45)
        receipt = json.loads((root / 'producer-budget.json').read_text())
        self.assertTrue(receipt['processTreeTerminated'])
        self.assertEqual(receipt['activeProcessesAfterCleanup'], 0)
        self.assertIsNotNone(receipt['endUtc'])
        self.assertTrue((root / 'stdout.log').is_file())
        self.assertTrue((root / 'stderr.log').is_file())
        # This simulates an always() collection after the producer has failed.
        (root / 'collection-continued.txt').write_text('PASS\n')
        self.assertTrue((root / 'collection-continued.txt').is_file())
        return result, receipt, root

    def test_zero(self):
        result, receipt, root = self.execute("import sys\nprint('stdout preserved', flush=True)\nprint('stderr preserved', file=sys.stderr, flush=True)\n")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(receipt['status'], 'PASS')
        self.assertEqual(receipt['producerExit'], 0)
        self.assertIn('stdout preserved', (root/'stdout.log').read_text())
        self.assertIn('stderr preserved', (root/'stderr.log').read_text())

    def test_nonzero(self):
        result, receipt, _ = self.execute("raise SystemExit(37)\n")
        self.assertEqual(result.returncode, 37)
        self.assertEqual(receipt['status'], 'FAIL')
        self.assertEqual(receipt['producerExit'], 37)

    def test_timeout_with_descendant(self):
        result, receipt, root = self.execute("import subprocess, sys, time\nsubprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])\nprint('descendant started', flush=True)\ntime.sleep(120)\n", 2)
        self.assertEqual(result.returncode, 124)
        self.assertEqual(receipt['status'], 'TIMEOUT')
        self.assertGreaterEqual(receipt['activeProcessesBeforeCleanup'], 3)
        self.assertIn('descendant started', (root/'stdout.log').read_text())

    def test_successful_parent_cleans_surviving_descendant(self):
        result, receipt, _ = self.execute("import subprocess, sys\nsubprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])\n")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(receipt['status'], 'PASS')
        self.assertGreaterEqual(receipt['activeProcessesBeforeCleanup'], 1)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--root', required=True)
    args = parser.parse_args(); Path(args.root).mkdir(parents=True, exist_ok=True)
    BudgetTests.root = args.root
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(BudgetTests))
    Path(args.root, 'harness.json').write_text(json.dumps({'status': 'PASS' if result.wasSuccessful() else 'FAIL', 'tests': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors)}, indent=2)+'\n')
    sys.exit(0 if result.wasSuccessful() else 1)
