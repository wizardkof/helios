import hashlib
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]

QUALIFIED = {
    'ci/windows/memory-trust/package_verify.cpp': ('046b360c1648bd00068c743afc983aede1bc5b03', 'd8ccc0571583f056e1494c731862e89d27b23151efe0963104b28fc575c7bdb3'),
    'ci/windows/memory-trust/result_gate.h': ('69f14c8d8fa13fedb8e2048e2ccbe04548a3ae91', '6dc0fb254ebec768ea2de881ef9c790730775654cab39161df33d9457af35a61'),
    'ci/windows/memory-trust/result_gate_test.cpp': ('ffc01f8be9111ed4541718da48e72473252eb95e', None),
}

class MemoryTrustEolTests(unittest.TestCase):
    def git(self, *args):
        return subprocess.run(['git', *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout

    def test_all_three_memory_trust_sources_are_checkout_lf(self):
        paths = list(QUALIFIED)
        output = self.git('check-attr', 'text', 'eol', '--', *paths)
        observed = {}
        for line in output.splitlines():
            path, name, value = line.split(': ', 2)
            observed.setdefault(path, {})[name] = value
        self.assertEqual(set(observed), set(paths))
        for path in paths:
            with self.subTest(path=path):
                self.assertEqual(observed[path], {'text': 'set', 'eol': 'lf'})

    def test_worktree_and_git_blobs_remain_native_qualified(self):
        for path, (expected_blob, expected_raw_sha) in QUALIFIED.items():
            with self.subTest(path=path):
                blob = self.git('rev-parse', f'HEAD:{path}').strip()
                self.assertEqual(blob, expected_blob)
                committed = subprocess.run(['git', 'show', f'HEAD:{path}'], cwd=ROOT, check=True, capture_output=True).stdout
                worktree = (ROOT/path).read_bytes()
                self.assertEqual(worktree, committed)
                self.assertNotIn(b'\r\n', worktree)
                if expected_raw_sha:
                    self.assertEqual(hashlib.sha256(worktree).hexdigest(), expected_raw_sha)

    def test_crlf_materialization_fails_the_qualified_raw_sha_gate(self):
        for path, (_, expected_raw_sha) in QUALIFIED.items():
            with self.subTest(path=path):
                source = subprocess.run(['git', 'show', f'HEAD:{path}'], cwd=ROOT, check=True, capture_output=True).stdout
                crlf_copy = source.replace(b'\n', b'\r\n')
                self.assertNotEqual(hashlib.sha256(crlf_copy).hexdigest(), hashlib.sha256(source).hexdigest())
                if expected_raw_sha:
                    self.assertEqual(hashlib.sha256(source).hexdigest(), expected_raw_sha)
                    self.assertNotEqual(hashlib.sha256(crlf_copy).hexdigest(), expected_raw_sha)

    def test_raw_worktree_sha_gate_remains_in_build(self):
        build = (ROOT/'ci/windows/Build-PackageVerifier.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('Get-FileHash -LiteralPath $source -Algorithm SHA256', build)
        self.assertIn('Get-FileHash -LiteralPath $gate -Algorithm SHA256', build)
        self.assertFalse((ROOT/'.gitattributes').exists())

if __name__ == '__main__':
    unittest.main()
