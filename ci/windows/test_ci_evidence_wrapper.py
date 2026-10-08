"""Exercise real native shells, source spec serialization and the unchanged collector."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE=Path(__file__).parent
SPEC=json.loads((HERE/'ci-evidence-sources.json').read_text())

def validate_metadata(effective,original):
    if len(effective)!=len(original):raise AssertionError('source count changed')
    for row,source in zip(effective,original):
        for key in ('name','source','required','mandatoryFiles'):
            if row.get(key)!=source.get(key):raise AssertionError('field lost or changed: '+key)
        if not isinstance(row['mandatoryFiles'],list):raise AssertionError('mandatoryFiles must be array')
        for key in ('mandatoryFilesOnSuccess','missingSuccessCode'):
            if key in source:
                if key not in row or row[key]!=source[key]:raise AssertionError('field lost or changed: '+key)
                if key=='mandatoryFilesOnSuccess' and not isinstance(row[key],list):raise AssertionError('conditional files must be array')
                if key=='missingSuccessCode' and not isinstance(row[key],str):raise AssertionError('missingSuccessCode must be string')

class MetadataValidatorTests(unittest.TestCase):
    def test_missing_conditional_array_is_detected(self):
        original=SPEC['python_evidence_preflight'];effective=json.loads(json.dumps(original));effective[0].pop('mandatoryFilesOnSuccess')
        with self.assertRaisesRegex(AssertionError,'mandatoryFilesOnSuccess'):validate_metadata(effective,original)
    def test_missing_failure_code_is_detected(self):
        original=SPEC['python_evidence_preflight'];effective=json.loads(json.dumps(original));effective[0].pop('missingSuccessCode')
        with self.assertRaisesRegex(AssertionError,'missingSuccessCode'):validate_metadata(effective,original)
    def test_scalar_array_is_detected(self):
        original=SPEC['python_evidence_preflight'];effective=json.loads(json.dumps(original));effective[0]['mandatoryFilesOnSuccess']='red-0.log'
        with self.assertRaises(AssertionError):validate_metadata(effective,original)

@unittest.skipUnless(os.name=='nt','Native Windows PowerShell wrapper required; no Linux promotion')
class NativeWrapperTests(unittest.TestCase):
    def test_actual_wrapper_spec_collector_and_manifest(self):
        output=Path(os.environ.get('RUNNER_TEMP',tempfile.gettempdir()))/'python-test-dependencies'
        archive=output/'wrapper-e2e'/str(os.getpid());archive.mkdir(parents=True,exist_ok=True)
        result=dict(status='FAIL',platform=sys.platform,pythonExecutable=sys.executable,shells=[],cases=[],firstFailure=None)
        metadata=dict(status='FAIL',shells=[],serializedSources=[])
        try:
            # The canonical job uses shell:powershell (Windows PowerShell 5.1).
            required=shutil.which('powershell.exe')
            self.assertIsNotNone(required,'canonical Windows PowerShell shell unavailable')
            shells=[required]
            optional=shutil.which('pwsh.exe')
            if optional:shells.append(optional)
            for shell in shells:
                result['shells'].append(shell);metadata['shells'].append(shell)
                for case in ('red_success','red_missing_log','red_failure','green_missing_log','green_failure','both_success','red_skipped','private_required','reparse_source','hash_tamper','missing_conditional_field','missing_code_field'):
                    row=dict(case=case,shell=shell,status='FAIL');result['cases'].append(row)
                    case_log=archive/(Path(shell).stem+'-'+case);case_log.mkdir()
                    with tempfile.TemporaryDirectory() as directory:
                        base=Path(directory);scripts=base/'scripts';scripts.mkdir()
                        for name in ('Collect-CIEvidence.ps1','ci_evidence.py','evidence_fs.py','ci-evidence-sources.json'):shutil.copyfile(HERE/name,scripts/name)
                        if case in ('missing_conditional_field','missing_code_field'):
                            key='mandatoryFilesOnSuccess' if case=='missing_conditional_field' else 'missingSuccessCode'
                            wrapper=scripts/'Collect-CIEvidence.ps1';wrapper.write_text('\n'.join(line for line in wrapper.read_text().splitlines() if '$entry.'+key not in line)+'\n')
                        red,green='success','skipped';primary='success'
                        if case=='red_failure':red='failure';primary='failure'
                        if case in ('green_missing_log','both_success','hash_tamper','red_skipped'):green='success'
                        if case=='green_failure':green='failure';primary='failure'
                        if case=='red_skipped':red='skipped';primary='failure'
                        for source in SPEC['python_evidence_preflight']:
                            outcome=red if source['step']=='python_native_recovery_red' else green
                            if outcome=='skipped':continue
                            root=Path(source['source'].replace('{TEMP}',str(base)))
                            root.mkdir(parents=True)
                            names=source['mandatoryFiles']+(source.get('mandatoryFilesOnSuccess',[]) if outcome=='success' else [])
                            if case=='green_failure' and source['step']=='python_dependencies':names=['before.json','control/tests-0.log','control/tests-1.log']
                            for name in names:
                                path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
                                path.write_text(json.dumps({'fixture':True,'firstFailure':'CONTROLLED_ORIGINAL_FAILURE' if outcome=='failure' else None})+'\n')
                        redroot=base/'python-native-recovery-red';greenroot=base/'python-test-dependencies'
                        if case in ('red_missing_log','missing_conditional_field'):(redroot/'red-2.log').unlink()
                        if case=='green_missing_log':(greenroot/'tests/tests-1.log').unlink()
                        if case=='private_required':(redroot/'native-red-results.json').write_text('-----BEGIN PRIVATE KEY-----\ncontrolled-test-fixture\n')
                        if case=='reparse_source':
                            external=base/'external';redroot.rename(external)
                            link=subprocess.run(['cmd.exe','/c','mklink','/J',str(redroot),str(external)],capture_output=True,text=True)
                            row['junctionCreation']=dict(command=['cmd.exe','/c','mklink','/J',str(redroot),str(external)],exitCode=link.returncode,stdout=link.stdout,stderr=link.stderr)
                            (case_log/'junction-creation.json').write_text(json.dumps(row['junctionCreation'],indent=2)+'\n')
                            self.assertEqual(link.returncode,0,link.stderr)
                            info=redroot.lstat()
                            row['junctionEntry']=dict(path=str(redroot),target=str(external),fileAttributes=getattr(info,'st_file_attributes',None),reparseTag=getattr(info,'st_reparse_tag',None),isJunction=redroot.is_junction() if hasattr(redroot,'is_junction') else None,isSymlink=redroot.is_symlink())
                            (case_log/'junction-entry.json').write_text(json.dumps(row['junctionEntry'],indent=2)+'\n')
                        env=dict(os.environ,RUNNER_TEMP=str(base),HELIOS_PRIMARY_RESULT=primary,HELIOS_STEPS_JSON=json.dumps({'python_native_recovery_red':{'outcome':red},'python_dependencies':{'outcome':green}}))
                        env['PATH']=str(Path(sys.executable).parent)+os.pathsep+env['PATH']
                        command=[shell,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(scripts/'Collect-CIEvidence.ps1'),'-Job','python_evidence_preflight','-Root',str(base/'collected')]
                        child=subprocess.run(command,env=env,capture_output=True,text=True,timeout=90)
                        row.update(exitCode=child.returncode,command=command)
                        (case_log/'stdout.txt').write_text(child.stdout);(case_log/'stderr.txt').write_text(child.stderr);(case_log/'exit.txt').write_text(str(child.returncode)+'\n')
                        effective=json.loads((base/'evidence-sources.json').read_text(encoding='utf-8-sig'))
                        manifest=json.loads((base/'collected/collection-manifest.json').read_text())
                        (case_log/'evidence-sources.json').write_text(json.dumps(effective,indent=2)+'\n');(case_log/'collection-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
                        if case in ('missing_conditional_field','missing_code_field'):
                            key='mandatoryFilesOnSuccess' if case=='missing_conditional_field' else 'missingSuccessCode'
                            with self.assertRaisesRegex(AssertionError,key):validate_metadata(effective,SPEC['python_evidence_preflight'])
                            row['negativeMetadataLossDetected']=key
                        else:
                            validate_metadata(effective,SPEC['python_evidence_preflight'])
                            metadata['serializedSources'].append(dict(shell=shell,case=case,sources=effective))
                        failing=case in ('red_missing_log','green_missing_log','green_failure','private_required','reparse_source')
                        self.assertEqual(manifest['EVIDENCE_COLLECTION_RESULT'],'FAIL' if failing else 'PASS',manifest)
                        self.assertEqual(child.returncode!=0,failing,child.stderr)
                        self.assertEqual(manifest['PRIMARY_GATE_RESULT'],primary)
                        rows={x['name']:x for x in manifest['sources']}
                        if case=='red_missing_log':self.assertIn('RED_COVERAGE_INCOMPLETE',rows['python-native-recovery-red']['reason'])
                        if case=='red_failure':
                            self.assertEqual(rows['python-native-recovery-red']['status'],'COPIED')
                            self.assertEqual(len(manifest['files']),2)
                            copied=base/'collected/python-native-recovery-red/native-red-results.json'
                            self.assertEqual(json.loads(copied.read_text())['firstFailure'],'CONTROLLED_ORIGINAL_FAILURE')
                            self.assertFalse(any((base/'collected').rglob('red-*.log')))
                        if case=='green_failure':self.assertTrue((base/'collected/python-test-dependencies/control/tests-1.log').is_file())
                        if case=='red_skipped':self.assertEqual(rows['python-native-recovery-red']['status'],'NOT_RUN')
                        if case=='private_required':self.assertTrue(manifest['excluded'])
                        if case=='reparse_source':
                            self.assertIn('reparse',rows['python-native-recovery-red']['reason'])
                            self.assertEqual(manifest['files'],[],'junction target bytes must not be copied')
                            self.assertTrue((external/'native-red-results.json').is_file())
                            self.assertEqual(rows['python-native-recovery-red']['refusal']['code'],'REPARSE_POINT_REFUSED')
                        if case=='hash_tamper':
                            target=base/'collected'/manifest['files'][0]['destination'];target.write_text('tampered')
                            verify=subprocess.run([sys.executable,str(scripts/'ci_evidence.py'),'verify','--root',str(base/'collected')],capture_output=True,text=True)
                            (case_log/'verify-stdout.txt').write_text(verify.stdout);(case_log/'verify-stderr.txt').write_text(verify.stderr);row['verifyExit']=verify.returncode
                            self.assertNotEqual(verify.returncode,0);self.assertIn('identity mismatch',verify.stderr)
                        row.update(status='PASS',collection=manifest['EVIDENCE_COLLECTION_RESULT'],primary=primary)
            result['status']='PASS';metadata['status']='PASS'
        except Exception as error:
            result['firstFailure']=str(error)
            raise
        finally:
            output.mkdir(parents=True,exist_ok=True)
            (output/'wrapper-end-to-end-tests.json').write_text(json.dumps(result,indent=2)+'\n')
            (output/'powerShell-metadata-forwarding.json').write_text(json.dumps(metadata,indent=2)+'\n')

if __name__=='__main__':unittest.main()
