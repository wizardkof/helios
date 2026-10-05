import tempfile
import unittest
from pathlib import Path
import artifact_roundtrip as transport

class ArtifactRoundtripTests(unittest.TestCase):
    def test_exact_set_bytes_and_private_rejection(self):
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp);root=p/'payload';root.mkdir();(root/'.editorconfig').write_text('a')
            receipt=p/'identity.json';transport.seal(root,receipt);transport.verify(root,receipt)
            (root/'.editorconfig').write_text('b')
            with self.assertRaises(ValueError):transport.verify(root,receipt)
            (root/'.editorconfig').write_text('a');(root/'extra').write_text('extra')
            with self.assertRaises(ValueError):transport.verify(root,receipt)
            (root/'extra').unlink();(root/'.editorconfig').unlink()
            with self.assertRaises(ValueError):transport.verify(root,receipt)
            (root/'secret.pfx').write_text('synthetic')
            with self.assertRaises(ValueError):transport.inventory(root)
