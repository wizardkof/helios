import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('collector', Path(__file__).with_name('ci_evidence.py'))

class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.m = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(self.m)
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def collect(self):
        return self.m.collect([dict(name='fixture', source=str(self.root/'src'), outcome='success', required=True)], self.root/'out', 'success')

    def test_admitted_hidden_and_security_exclusion_before_manifest(self):
        src = self.root/'src'; src.mkdir()
        for name in ('ordinary.txt', '.editorconfig', '.evidence/ordinary.txt', '.evidence/nested/.gitignore', 'safe/same.txt', '.evidence/same.txt', 'private.pfx', '.ssh/config'):
            p=src/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('synthetic fixture')
        r=self.collect(); self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'], 'PASS')
        self.assertEqual(len(r['excluded']), 2)
        self.assertEqual(len(r['files']), 6)
        self.m.verify(self.root/'out')

    def test_secret_content_excluded(self):
        src=self.root/'src'; src.mkdir(); (src/'good.txt').write_text('safe')
        (src/'auth.txt').write_text('-----BEGIN PRIVATE KEY-----\nsynthetic')
        r=self.collect(); self.assertEqual(len(r['files']), 1); self.assertEqual(len(r['excluded']),1)

    def test_missing_extra_same_size_and_different_size_rejected(self):
        src=self.root/'src'; src.mkdir(); (src/'one.txt').write_text('abc')
        self.collect(); out=self.root/'out'; f=out/'fixture/one.txt'
        f.unlink()
        with self.assertRaises((ValueError,FileNotFoundError)): self.m.verify(out)
        f.write_text('abc'); (out/'extra.txt').write_text('extra')
        with self.assertRaises(ValueError): self.m.verify(out)
        (out/'extra.txt').unlink(); f.write_text('xyz')
        with self.assertRaises(ValueError): self.m.verify(out)
        f.write_text('longer')
        with self.assertRaises(ValueError): self.m.verify(out)
