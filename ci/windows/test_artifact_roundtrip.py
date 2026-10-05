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

    def test_collection_manifest_identity_is_transport_authority(self):
        import ci_evidence
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp);source=p/'source';source.mkdir();(source/'one.txt').write_text('abc')
            payload=p/'payload'
            ci_evidence.collect([dict(name='source',source=str(source),outcome='success',required=True)],payload,'success')
            (payload/'source/one.txt').write_text('xyz')
            with self.assertRaises(ValueError):transport.seal(payload,p/'snapshot.json')
