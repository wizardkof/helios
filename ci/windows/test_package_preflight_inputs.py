import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

class IntakeTests(unittest.TestCase):
    def test_digest_crc_and_path_traversal_are_refused(self):
        spec=importlib.util.spec_from_file_location('intake',Path(__file__).with_name('package_preflight_inputs.py'))
        mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'input.zip'
            with zipfile.ZipFile(p,'w') as z:z.writestr('image.dll',b'PE')
            digest=hashlib.sha256(p.read_bytes()).hexdigest()
            mod.validate_archive(p,digest)
            with self.assertRaises(ValueError):mod.validate_archive(p,'0'*64)
            data=p.read_bytes().replace(b'PE',b'XX',1);p.write_bytes(data)
            with self.assertRaises((ValueError,zipfile.BadZipFile)):mod.validate_archive(p,hashlib.sha256(data).hexdigest())
            with zipfile.ZipFile(p,'w') as z:z.writestr('../escape.dll',b'PE')
            with self.assertRaises(ValueError):mod.validate_archive(p,hashlib.sha256(p.read_bytes()).hexdigest())
