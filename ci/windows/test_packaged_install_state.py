import hashlib
import importlib.util
import json
import lzma
from pathlib import Path
import struct
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('schema_gate', Path(__file__).with_name('Test-PackagedInstallState.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def bundle(entries):
    header = struct.pack('<I', len(entries))
    raw = b''
    for name, data in entries:
        encoded = name.encode()
        header += struct.pack('<H', len(encoded)) + encoded + struct.pack('<Q', len(data))
        raw += data
    container = header + lzma.compress(raw)
    return b'MZ' + b'\0' * 126 + container + struct.pack('<QQQ', 128, len(container), len(header)) + hashlib.sha256(container).digest() + b'HLIOSET2'


class PackagedStateDecoderTests(unittest.TestCase):
    def test_native_child_does_not_inherit_powershell7_modules(self):
        parent = {'PSMODULEPATH': r'C:\Program Files\PowerShell\7\Modules',
                  'PATH': 'qualified-tools', 'SYSTEMROOT': r'C:\Windows'}
        with mock.patch.dict(gate.os.environ, parent, clear=True):
            child = gate.native_powershell_environment()
            self.assertFalse(any(k.upper() == 'PSMODULEPATH' for k in child))
            self.assertEqual(child['PATH'], parent['PATH'])
            self.assertEqual(dict(gate.os.environ), parent)

    def test_native_error_is_printable_on_legacy_windows_console(self):
        output = gate.format_native_output(b'Get-FileHash n\xe3o reconhecido; \xe2\x9c\x97')
        output.encode('cp1252', errors='strict')
        self.assertIn('Get-FileHash', output)
        self.assertIn(r'\xe3', output)

    def fixture(self):
        script = b'$state.observedComponentVersions = $observed'
        manifest = {'files': [{'path': 'Verify-Helios.ps1', 'size': len(script), 'sha256': hashlib.sha256(script).hexdigest()}]}
        return [('manifest.json', json.dumps(manifest).encode()), ('Verify-Helios.ps1', script)]

    def test_preserves_exact_packaged_script_bytes(self):
        entries = self.fixture()
        files, digest = gate.decode(bundle(entries))
        self.assertEqual(files['Verify-Helios.ps1'], entries[1][1])
        self.assertEqual(len(digest), 64)

    def test_rejects_modified_container_digest(self):
        data = bytearray(bundle(self.fixture()))
        data[130] ^= 1
        with self.assertRaisesRegex(ValueError, 'digest'):
            gate.decode(data)

    def test_rejects_truncated_setup(self):
        with self.assertRaisesRegex(ValueError, 'footer'):
            gate.decode(bundle(self.fixture())[:-1])

    def test_rejects_manifest_script_hash_mismatch(self):
        entries = self.fixture()
        entries[1] = ('Verify-Helios.ps1', b'wrong verifier')
        with self.assertRaisesRegex(ValueError, 'Manifest hash/size'):
            gate.decode(bundle(entries))

    def test_rejects_duplicate_script_name(self):
        entries = self.fixture()
        entries.append(('verify-HELIOS.ps1', b'wrong verifier'))
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            gate.decode(bundle(entries))

    def test_rejects_path_escape(self):
        entries = self.fixture()
        entries.append(('../Verify-Helios.ps1', b'escape'))
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            gate.decode(bundle(entries))


if __name__ == '__main__':
    unittest.main()
