import unittest
from pathlib import Path
class SignatureBounds(unittest.TestCase):
 def test_reject_unbounded_pe_security_directory(self):
  import peer_signature
  with self.assertRaises(ValueError):peer_signature.extract(b'MZ'+b'\0'*126)
 def test_extract_exact_pkcs7_bytes(self):
  import peer_signature,struct
  b=bytearray(400);b[:2]=b'MZ';struct.pack_into('<I',b,60,64);b[64:68]=b'PE\0\0';struct.pack_into('<H',b,88,0x20b);struct.pack_into('<II',b,88+112+32,320,16);struct.pack_into('<IHH',b,320,16,0x200,2);b[328:336]=b'abcdefgh'
  self.assertEqual(peer_signature.extract(bytes(b)),b'abcdefgh')
