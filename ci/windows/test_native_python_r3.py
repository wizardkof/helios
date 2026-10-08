import copy
import hashlib
import importlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE=Path(__file__).parent
REL='ci/windows/fixtures/msys2-archives-317.json'
EXPECTED='6f529cdd45961ff29420e0bc35dc7de0190c5fce9b28518aaf6f6370cc64a033'

class FixtureATests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)/'repo';self.root.mkdir()
        self.source=self.root/REL;self.source.parent.mkdir(parents=True)
        self.original=(HERE/'fixtures/msys2-archives-317.json').read_bytes()
        self.source.write_bytes(self.original)
        self.attrs=self.source.parent/'.gitattributes';self.attrs.write_text('msys2-archives-317.json -text\n')
        self.git('init');self.git('config','core.autocrlf','true');self.git('add','.')
        self.git('-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-m','frozen bytes')
        self.receipt=Path(self.tmp.name)/'receipt.json'
        self.manifest=json.loads((HERE/'ci-toolchain-pins.json').read_text())
    def git(self,*args):
        return subprocess.run(['git','-C',str(self.root),*args],capture_output=True,check=True).stdout
    def inspect(self,**kwargs):
        self.assertTrue((HERE/'fixture_a_bytes.py').is_file(),'fixture A diagnostic API absent')
        module=importlib.import_module('fixture_a_bytes')
        return module.inspect_fixture_a(self.root,self.source,self.receipt,kwargs.pop('manifest',self.manifest),**kwargs)
    def test_exact_blob_checkout_and_semantics(self):
        row=self.inspect();self.assertEqual(row['gitBlobIdentity'],'PASS');self.assertEqual(row['checkoutByteIdentity'],'PASS');self.assertEqual(row['historicalArchiveSemantics'],'PASS')
        self.assertEqual(row['gitBlobSha256'],EXPECTED);self.assertEqual(row['worktreeSha256'],EXPECTED)
    def test_specific_attribute_in_repository(self):
        text=(HERE/'fixtures/.gitattributes').read_text()
        self.assertIn('msys2-archives-317.json -text',text)
        self.assertIn('test_pkgconf_restore_318.py.txt -text',text)
        self.assertNotIn('*.json',text)
    def test_crlf_byte_mutation_and_truncation_are_rejected(self):
        for data in (self.original.replace(b'\n',b'\r\n'),b'X'+self.original[1:],self.original[:-10]):
            self.source.write_bytes(data)
            with self.assertRaises((ValueError,OSError)):self.inspect()
            row=json.loads(self.receipt.read_text());self.assertEqual(row['status'],'FAIL');self.assertEqual(row['gitBlobIdentity'],'PASS');self.assertEqual(row['checkoutByteIdentity'],'FAIL');self.assertEqual(row['worktreeSha256'],hashlib.sha256(data).hexdigest())
    def test_missing_file_preserves_failure_receipt(self):
        self.source.unlink()
        with self.assertRaises((ValueError,OSError)):self.inspect()
        self.assertEqual(json.loads(self.receipt.read_text())['status'],'FAIL')
    def test_adulterated_expected_hash_is_not_authority(self):
        with self.assertRaisesRegex(ValueError,'EXPECTED_HASH_UNAPPROVED'):self.inspect(expected='0'*64)
    def test_bad_current_head_blob_is_distinct_from_checkout(self):
        self.source.write_bytes(self.original+b' ');self.git('add',REL);self.git('-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-m','unauthorized blob')
        with self.assertRaisesRegex(ValueError,'GIT_BLOB_IDENTITY'):self.inspect()
        row=json.loads(self.receipt.read_text());self.assertEqual(row['gitBlobIdentity'],'FAIL');self.assertEqual(row['byteCause'],'NO_CHECKOUT_CONVERSION_BYTES_IDENTICAL')
    def test_all_seven_archive_rows_are_preserved(self):
        baseline=json.loads(self.original)
        for old in baseline['packages']:
            changed=copy.deepcopy(self.manifest)
            row=next(r for r in changed['msys2ArchivedPackages']['packages'] if r['name']==old['name']);row['sha256']='0'*64
            with self.assertRaisesRegex(ValueError,'HISTORIC_ARCHIVE_CHANGED_OR_MISSING'):self.inspect(manifest=changed)
            receipt=json.loads(self.receipt.read_text());self.assertEqual(receipt['checkoutByteIdentity'],'PASS');self.assertEqual(receipt['historicalArchiveSemantics'],'FAIL')
    def test_duplicate_removed_archive_and_baseurl_rejected(self):
        for kind in ('duplicate','removed','baseUrl'):
            changed=copy.deepcopy(self.manifest);rows=changed['msys2ArchivedPackages']['packages']
            if kind=='duplicate':rows.append(copy.deepcopy(rows[0]))
            elif kind=='removed':rows[:]=[r for r in rows if r['name']!=json.loads(self.original)['packages'][0]['name']]
            else:changed['msys2ArchivedPackages']['baseUrl']='https://example.invalid/'
            with self.assertRaises(ValueError):self.inspect(manifest=changed)
    def test_old_policy_checkout_conversion_is_measured(self):
        self.attrs.unlink();self.git('add','-u');self.git('-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-m','old policy')
        self.source.unlink();self.git('checkout-index','-f',REL)
        self.assertEqual(self.source.read_bytes(),self.original.replace(b'\n',b'\r\n'))
        with self.assertRaises(ValueError):self.inspect()
        self.assertEqual(json.loads(self.receipt.read_text())['byteCause'],'LF_BLOB_TO_CRLF_WORKTREE_CONFIRMED')
    def test_clean_shallow_clones_autocrlf_true_and_false(self):
        for policy in ('true','false'):
            clone=Path(self.tmp.name)/('clone-'+policy)
            subprocess.run(['git','-c','core.autocrlf='+policy,'clone','--depth','1',self.root.as_uri(),str(clone)],capture_output=True,check=True)
            self.assertEqual(subprocess.check_output(['git','-C',str(clone),'rev-parse','--is-shallow-repository']).strip(),b'true')
            self.assertEqual((clone/REL).read_bytes(),self.original)
            self.assertTrue((HERE/'fixture_a_bytes.py').is_file())
            result=importlib.import_module('fixture_a_bytes').inspect_fixture_a(clone,clone/REL,self.receipt,self.manifest)
            self.assertEqual(result['status'],'PASS')

class WrapperMetadataRegression(unittest.TestCase):
    def test_wrapper_forwards_both_conditional_fields(self):
        wrapper=(HERE/'Collect-CIEvidence.ps1').read_text()
        self.assertIn('$entry.mandatoryFilesOnSuccess',wrapper)
        self.assertIn('$entry.missingSuccessCode',wrapper)

if __name__=='__main__':unittest.main()
