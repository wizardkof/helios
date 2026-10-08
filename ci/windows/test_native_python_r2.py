import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import native_python_recovery_control as native
import ci_evidence as evidence

HERE=Path(__file__).parent
REL='ci/windows/fixtures/test_pkgconf_restore_318.py.txt'

class FixtureByteTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)/'repo';self.root.mkdir()
        self.source=self.root/REL;self.source.parent.mkdir(parents=True)
        self.original=(HERE/'fixtures/test_pkgconf_restore_318.py.txt').read_bytes()
        self.source.write_bytes(self.original)
        self.attributes=self.source.parent/'.gitattributes';self.attributes.write_text('test_pkgconf_restore_318.py.txt -text\n')
        self.git('init');self.git('config','core.autocrlf','true');self.git('add','.');self.git('-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-m','exact fixture')
        self.receipt=Path(self.tmp.name)/'receipt.json'
    def git(self,*args):
        return subprocess.run(['git','-C',str(self.root),*args],capture_output=True,check=True).stdout
    def inspect(self,**kwargs):
        self.assertTrue(hasattr(native,'inspect_legacy_fixture'),'byte inspection API missing')
        return native.inspect_legacy_fixture(self.root,self.source,self.receipt,**kwargs)
    def test_exact_blob_checkout_and_specific_attributes_pass(self):
        result=self.inspect();self.assertEqual(result['status'],'PASS');self.assertEqual(result['gitBlobSha256'],native.LEGACY_SHA256);self.assertEqual(result['worktreeSha256'],native.LEGACY_SHA256)
    def test_crlf_truncation_and_byte_mutation_fail_with_raw_receipt(self):
        for data in (self.original.replace(b'\n',b'\r\n'),self.original[:-1],b'X'+self.original[1:]):
            self.source.write_bytes(data)
            with self.assertRaises(ValueError):self.inspect()
            record=json.loads(self.receipt.read_text());self.assertEqual(record['status'],'FAIL');self.assertEqual(record['worktreeSha256'],hashlib.sha256(data).hexdigest())
    def test_missing_fixture_receipt_preserved(self):
        self.source.unlink()
        with self.assertRaises((ValueError,OSError)):self.inspect()
        self.assertTrue(self.receipt.is_file());self.assertEqual(json.loads(self.receipt.read_text())['status'],'FAIL')
    def test_tampered_expected_hash_refused(self):
        with self.assertRaises(ValueError):self.inspect(expected='0'*64)
    def test_similar_wrong_filename_refused(self):
        self.assertTrue(hasattr(native,'inspect_legacy_fixture'))
        other=self.source.with_name('test_pkgconf_restore_318-other.py.txt');other.write_bytes(self.original)
        with self.assertRaises(ValueError):native.inspect_legacy_fixture(self.root,other,self.receipt)
    def test_attribute_on_wrong_file_refused(self):
        self.attributes.write_text('wrong.py.txt -text\n')
        with self.assertRaises(ValueError):self.inspect()
    def test_old_checkout_policy_actually_converts_lf_to_crlf(self):
        self.attributes.unlink();self.git('add','-u');self.git('-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-m','old unspecified attributes')
        self.source.unlink();self.git('checkout-index','-f',REL)
        data=self.source.read_bytes();self.assertEqual(data,self.original.replace(b'\n',b'\r\n'))
        with self.assertRaises(ValueError):self.inspect()
        record=json.loads(self.receipt.read_text());self.assertEqual(record['byteCause'],'LF_BLOB_TO_CRLF_WORKTREE_CONFIRMED')
    def test_shallow_current_blob_without_historical_commit(self):
        self.assertTrue(hasattr(native,'inspect_legacy_fixture'))
        clone=Path(self.tmp.name)/'shallow'
        subprocess.run(['git','clone','--depth','1',self.root.as_uri(),str(clone)],check=True,capture_output=True)
        self.assertEqual(subprocess.check_output(['git','-C',str(clone),'rev-parse','--is-shallow-repository']).strip(),b'true')
        result=native.inspect_legacy_fixture(clone,clone/REL,self.receipt);self.assertEqual(result['status'],'PASS')

class RedCollectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.base=Path(self.tmp.name)
        self.spec=json.loads((HERE/'ci-evidence-sources.json').read_text())['python_evidence_preflight']
    def entries(self,red,green):
        entries=evidence.expand_sources(self.spec,str(self.base),'')
        for entry in entries:entry['outcome']=red if entry['step']=='python_native_recovery_red' else green
        return entries
    def populate(self,entry,complete):
        root=Path(entry['source']);root.mkdir(parents=True,exist_ok=True)
        names=entry['mandatoryFiles']+(entry.get('mandatoryFilesOnSuccess',[]) if complete else [])
        for name in names:
            p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('{}\n')
    def collect(self,red,green):
        entries=self.entries(red,green)
        return evidence.collect(entries,self.base/'output','failure' if 'failure' in (red,green) else 'success')
    def test_failed_red_with_skipped_green_is_preserved(self):
        entries=self.entries('failure','skipped');red=next(e for e in entries if e['step']=='python_native_recovery_red');self.populate(red,False)
        result=self.collect('failure','skipped');self.assertEqual(result['EVIDENCE_COLLECTION_RESULT'],'PASS');self.assertEqual(result['PRIMARY_GATE_RESULT'],'failure')
        rows={r['step']:r for r in result['sources']};self.assertEqual(rows['python_native_recovery_red']['status'],'COPIED');self.assertEqual(rows['python_dependencies']['status'],'NOT_RUN')
        evidence.verify(self.base/'output')
    def test_red_success_green_failure_retains_primary_failure(self):
        entries=self.entries('success','failure')
        for e in entries:self.populate(e,True)
        r=self.collect('success','failure');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'PASS');self.assertEqual(r['PRIMARY_GATE_RESULT'],'failure')
    def test_both_success_require_all_receipts(self):
        entries=self.entries('success','success')
        for e in entries:self.populate(e,True)
        r=self.collect('success','success');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'PASS');self.assertEqual(r['PRIMARY_GATE_RESULT'],'success')
    def test_failed_red_without_minimum_receipt_refuses(self):
        r=self.collect('failure','skipped');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'FAIL')
    def test_successful_red_without_third_log_fails_coverage(self):
        entries=self.entries('success','skipped');red=next(e for e in entries if e['step']=='python_native_recovery_red');self.populate(red,True);(Path(red['source'])/'red-2.log').unlink()
        r=self.collect('success','skipped');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'FAIL');self.assertIn('RED_COVERAGE_INCOMPLETE',str(r))
    def test_extra_and_tampered_files_refused_by_verifier(self):
        entries=self.entries('failure','skipped');red=next(e for e in entries if e['step']=='python_native_recovery_red');self.populate(red,False);self.collect('failure','skipped')
        output=self.base/'output';p=output/'extra.json';p.write_text('{}')
        with self.assertRaises(ValueError):evidence.verify(output)
        p.unlink();target=next(p for p in output.rglob('*.json') if p.name!='collection-manifest.json');target.write_text('changed')
        with self.assertRaises(ValueError):evidence.verify(output)

if __name__=='__main__':unittest.main()
