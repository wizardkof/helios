"""Real filesystem negative controls; Windows directory cases use mklink /J."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import ci_evidence as evidence
import artifact_roundtrip

class ReparseTests(unittest.TestCase):
    @classmethod
    def tearDownClass(cls):
        output=Path(os.environ.get('RUNNER_TEMP',tempfile.gettempdir()))/'python-test-dependencies'
        folder=output/'reparse-controls'/str(os.getpid())
        rows=[json.loads(p.read_text()) for p in sorted(folder.glob('*.json'))] if folder.is_dir() else []
        expected={name for name in dir(cls) if name.startswith('test_')}
        observed={r['case'] for r in rows}
        platform_only={'test_swapped_file_before_open_is_not_read'} if os.name=='nt' else {'test_windows_short_path_is_not_reparse'}
        missing=sorted(expected-observed-platform_only)
        failed=[r['case'] for r in rows if r['status'] not in ('PASS','CAPABILITY_LIMIT')]
        record=dict(status='PASS' if not missing and not failed else 'FAIL',platform=sys.platform,pythonExecutable=sys.executable,total=len(expected),executed=len(rows),cases=rows,notRun=sorted(expected-observed),missingRequired=missing,failed=failed,capabilityLimits=[r for r in rows if r['status']=='CAPABILITY_LIMIT'],limitations='Ancestors are rechecked but not pinned throughout the transaction; no complete ancestor TOCTOU protection is claimed.')
        output.mkdir(parents=True,exist_ok=True);(output/'reparse-coverage.json').write_text(json.dumps(record,indent=2)+'\n')
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.base=Path(self.tmp.name)
        self.source=self.base/'source';self.source.mkdir();self.external=self.base/'external';self.external.mkdir()
        (self.external/'external.txt').write_bytes(b'EXTERNAL_MUST_NEVER_BE_COPIED')
        self.external_hash=hashlib.sha256((self.external/'external.txt').read_bytes()).hexdigest()
        self.record={'case':self._testMethodName,'status':'NOT_COMPLETED','platform':sys.platform,'links':[]}
        self.addCleanup(self.persist)
    def persist(self):
        output=Path(os.environ.get('RUNNER_TEMP',tempfile.gettempdir()))/'python-test-dependencies/reparse-controls'/str(os.getpid())
        output.mkdir(parents=True,exist_ok=True);(output/(self._testMethodName+'.json')).write_text(json.dumps(self.record,indent=2)+'\n')
    def link(self,path,target):
        if os.name=='nt':
            command=['cmd.exe','/c','mklink','/J',str(path),str(target)]
            child=subprocess.run(command,capture_output=True,text=True)
            self.record['links'].append({'command':command,'exitCode':child.returncode,'stdout':child.stdout,'stderr':child.stderr})
            self.assertEqual(child.returncode,0,child.stderr)
        else:path.symlink_to(target,target_is_directory=True)
        st=path.lstat();self.record['links'].append({'path':str(path),'target':str(target),'mode':st.st_mode,'fileAttributes':getattr(st,'st_file_attributes',None),'reparseTag':getattr(st,'st_reparse_tag',None),'isSymlink':path.is_symlink(),'isJunction':path.is_junction() if hasattr(path,'is_junction') else None})
    def entry(self,source=None,required=True,outcome='success'):
        return dict(name='selected',source=str(self.source if source is None else source),required=required,outcome=outcome)
    def refuse(self,source=None,required=True):
        report=evidence.collect([self.entry(source,required)],self.base/'collected','success');self.record['manifest']=report
        self.assertEqual(report['EVIDENCE_COLLECTION_RESULT'],'FAIL',report)
        self.assertEqual(report['files'],[],'reparse target bytes entered artifact')
        row=report['sources'][0];self.assertEqual(row['refusal']['code'],'REPARSE_POINT_REFUSED');self.assertTrue(row['refusal']['rejectedComponent'])
        self.assertEqual(hashlib.sha256((self.external/'external.txt').read_bytes()).hexdigest(),self.external_hash)
        self.record['status']='PASS'
    def test_junction_source_root_external_refused(self):
        self.source.rmdir();self.link(self.source,self.external);self.refuse()
    def test_junction_nested_source_refused_before_external_reads(self):
        self.link(self.source/'nested',self.external);self.refuse()
    def test_junction_intermediate_component_refused(self):
        self.link(self.source/'ancestor',self.external);self.refuse(self.source/'ancestor/external.txt')
    def test_junction_glob_result_refused(self):
        self.link(self.source/'matched',self.external);self.refuse(self.source/'*')
    def test_junction_glob_intermediate_refused_before_enumeration(self):
        self.link(self.source/'matched',self.external);self.refuse(self.source/'*/external.txt')
    def test_junction_literal_prefix_before_glob_refused(self):
        self.link(self.source/'ancestor',self.external);self.refuse(self.source/'ancestor/*.txt')
    def test_junction_deep_recursion_refused(self):
        nested=self.source/'normal/deep';nested.mkdir(parents=True);self.link(nested/'junction',self.external);self.refuse()
    def test_junction_target_inside_source_still_refused(self):
        inside=self.source/'inside';inside.mkdir();self.link(self.source/'junction',inside);self.refuse()
    def test_optional_selected_junction_is_failure(self):
        self.source.rmdir();self.link(self.source,self.external);self.refuse(required=False)
    def test_normal_files_and_glob_pass(self):
        for name in ('a','b'):
            p=self.source/name/'same.txt';p.parent.mkdir();p.write_bytes(name.encode())
        r=evidence.collect([self.entry(self.source/'*/same.txt')],self.base/'collected','success');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'PASS');self.assertEqual(len(r['files']),2);evidence.verify(self.base/'collected');self.record['status']='PASS'
    def test_nested_output_root_creation_preserves_normal_behavior(self):
        (self.source/'ordinary.txt').write_bytes(b'normal')
        root=self.base/'new-parent/deeper/output'
        r=evidence.collect([self.entry()],root,'success');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'PASS');evidence.verify(root);self.record['status']='PASS'
    def test_private_direct_input_still_refused(self):
        p=self.source/'synthetic.pfx';p.write_bytes(b'synthetic');r=evidence.collect([self.entry(p)],self.base/'collected','success');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'FAIL');self.assertFalse(r['files']);self.record['status']='PASS'
    def test_first_missing_source_is_not_replaced_by_later_reparse(self):
        self.link(self.source/'junction',self.external)
        missing=self.entry(self.base/'absent');missing['name']='first'
        later=self.entry(self.source/'junction');later['name']='later'
        r=evidence.collect([missing,later],self.base/'collected','failure')
        self.assertEqual(r.get('firstFailure',{}).get('status'),'MISSING_REQUIRED');self.assertEqual(r['firstFailure']['name'],'first');self.assertEqual(r['sources'][1]['refusal']['code'],'REPARSE_POINT_REFUSED');self.record['status']='PASS'
    def test_missing_required_and_skipped_primary_preserved(self):
        r=evidence.collect([self.entry(self.source/'missing'),dict(self.entry(self.source/'not_run'),outcome='skipped',name='skipped')],self.base/'collected','failure');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'FAIL');self.assertEqual(r['sources'][1]['status'],'NOT_RUN');self.assertEqual(r['PRIMARY_GATE_RESULT'],'failure');self.record['status']='PASS'
    def test_verify_output_junction_refused_even_if_empty(self):
        p=self.source/'good.txt';p.write_bytes(b'good');root=self.base/'collected';evidence.collect([self.entry()],root,'success');self.link(root/'unexpected',self.external)
        with self.assertRaisesRegex(ValueError,'reparse'):evidence.verify(root)
        self.record['status']='PASS'
    def test_verify_recorded_file_reparse_ancestor_refused(self):
        p=self.source/'good.txt';p.write_bytes(b'good');root=self.base/'collected';evidence.collect([self.entry()],root,'success')
        moved=self.base/'moved-output';(root/'selected').rename(moved);self.link(root/'selected',moved)
        with self.assertRaisesRegex(ValueError,'reparse'):evidence.verify(root)
        self.record['status']='PASS'
    def test_artifact_tree_reparse_refused_before_identity_file_read(self):
        root=self.base/'product-artifact';root.mkdir();identity=root/'ci-artifact-identity.json';identity.write_text('{}')
        self.link(root/'unexpected',self.external)
        original_read=Path.read_text;reads=[]
        def observed_read(path,*args,**kwargs):
            if path==identity:reads.append(str(path))
            return original_read(path,*args,**kwargs)
        with patch.object(Path,'read_text',observed_read):
            try:artifact_roundtrip.validate_payload(root)
            except Exception as error:
                self.assertIsInstance(error,ValueError,'wrong rejection occurred after premature identity read')
                self.assertIn('reparse',str(error))
            else:self.fail('reparse artifact tree was accepted')
        self.assertFalse(reads,'identity was read before reparse-tree refusal');self.record['status']='PASS'
    def test_sealed_file_tamper_refused(self):
        p=self.source/'good.txt';p.write_bytes(b'good');root=self.base/'collected';evidence.collect([self.entry()],root,'success');receipt=self.base/'seal.json';artifact_roundtrip.seal(root,receipt);(root/'selected/good.txt').write_bytes(b'evil')
        with self.assertRaises(ValueError):artifact_roundtrip.verify(root,receipt)
        self.record['status']='PASS'
    def test_symlink_directory_and_file_refused_or_capability_recorded(self):
        links=[(self.source/'dir-link',self.external,True),(self.source/'file-link',self.external/'external.txt',False)]
        for link,target,directory in links:
            try:link.symlink_to(target,target_is_directory=directory)
            except OSError as error:
                if os.name=='nt' and getattr(error,'winerror',None)==1314:
                    self.record.update(status='CAPABILITY_LIMIT',reason='SYMLINK_PRIVILEGE_NOT_HELD',winerror=1314);self.skipTest('Windows symlink privilege unavailable; real junction cases remain mandatory')
                raise
            st=link.lstat();self.record['links'].append({'path':str(link),'mode':st.st_mode,'fileAttributes':getattr(st,'st_file_attributes',None),'reparseTag':getattr(st,'st_reparse_tag',None)})
            r=evidence.collect([self.entry(link)],self.base/('collected-'+link.name),'success');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'FAIL');self.assertFalse(r['files']);self.assertEqual(r['sources'][0]['refusal']['code'],'REPARSE_POINT_REFUSED')
        self.record['status']='PASS'
    @unittest.skipUnless(os.name=='nt','Real Windows 8.3 path identity requires native Windows')
    def test_windows_short_path_is_not_reparse(self):
        import ctypes
        p=self.source/'a long ordinary file name.txt';p.write_bytes(b'normal')
        buffer=ctypes.create_unicode_buffer(32768);fn=ctypes.WinDLL('kernel32',use_last_error=True).GetShortPathNameW;fn.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint];fn.restype=ctypes.c_uint
        count=fn(str(p),buffer,len(buffer));self.assertGreater(count,0);short=Path(buffer.value);self.assertTrue(short.samefile(p))
        r=evidence.collect([self.entry(short)],self.base/'collected','success');self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'PASS');self.record.update(status='PASS',longPath=str(p),shortPath=str(short),distinctSpelling=str(short)!=str(p))
    @unittest.skipUnless(os.name!='nt','POSIX nofollow race control; Windows opened-handle guards qualified separately')
    def test_swapped_file_before_open_is_not_read(self):
        p=self.source/'ordinary.txt';p.write_bytes(b'ordinary');original_open=os.open;swapped=[]
        def racing_open(path,*args,**kwargs):
            if Path(path)==p and not swapped:
                p.unlink();p.symlink_to(self.external/'external.txt');swapped.append(True)
            return original_open(path,*args,**kwargs)
        with patch.object(evidence.os,'open',side_effect=racing_open):
            r=evidence.collect([self.entry()],self.base/'collected','success')
        self.assertTrue(swapped);self.assertEqual(r['EVIDENCE_COLLECTION_RESULT'],'FAIL');self.assertFalse(r['files']);self.record['status']='PASS'

if __name__=='__main__':unittest.main()
