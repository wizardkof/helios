import importlib.util
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).parent
class DiagnosticTrustBoundaries(unittest.TestCase):
 def test_content_trust_predicate_rejects_every_unqualified_half(self):
  compiler=shutil.which('g++')
  if not compiler:self.skipTest('Native host C++ compiler unavailable')
  with tempfile.TemporaryDirectory() as d:
   exe=Path(d)/'gate'
   subprocess.run([compiler,'-std=c++17',str(ROOT/'memory-trust/result_gate_test.cpp'),'-o',str(exe)],check=True,capture_output=True)
   subprocess.run([str(exe)],check=True,capture_output=True)
 def test_tamper_changes_raw_section_and_preserves_certificate_bytes(self):
  spec=importlib.util.spec_from_file_location('negative',ROOT/'Prepare-MemoryTrustNegatives.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  b=bytearray(640);b[:2]=b'MZ';struct.pack_into('<I',b,60,64);b[64:68]=b'PE\0\0';struct.pack_into('<H',b,70,1);struct.pack_into('<H',b,84,240);struct.pack_into('<II',b,328+16,8,400);b[512:]=b'A'*128
  changed,offset=module.tamper_pe(bytes(b));self.assertEqual(offset,400);self.assertEqual(changed[512:],b[512:]);self.assertEqual([i for i in range(len(b)) if b[i]!=changed[i]],[400])
