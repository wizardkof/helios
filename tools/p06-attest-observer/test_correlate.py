import unittest
import correlate
import decode
from test_decode import record,STATS

MANIFEST={'run_id':'r1','architecture':'x64','source_sha':'a'*40,'cases':['valid']}
RECEIPT=dict(MANIFEST,case_id='valid',pid=22,tid=33,requested_version=4,user_handle=44,carrier_id_hex='00'*16,qpc_before=100,qpc_after=110,qpc_frequency=10000000)
def observation(): return decode.analyze([record(p,p) for p in range(1,6)],STATS,1)
class CorrelationTests(unittest.TestCase):
    def test_unique(self): self.assertEqual(correlate.correlate(observation(),[RECEIPT],MANIFEST)['correlation_status'],'MATCHED')
    def test_ambiguous_calls(self):
        o=observation();o['records'] += [dict(r,call=2) for r in list(o['records'])]
        self.assertIn('ambiguous_match',correlate.correlate(o,[RECEIPT],MANIFEST)['problems'])
    def test_duplicate_receipt(self):
        self.assertIn('duplicate_case_receipt',correlate.correlate(observation(),[RECEIPT,RECEIPT],MANIFEST)['problems'])
    def test_manifest_mismatch(self):
        for key,value in [('run_id','other'),('architecture','x86'),('source_sha','b'*40)]:
            self.assertIn('receipt_manifest_mismatch',correlate.correlate(observation(),[dict(RECEIPT,**{key:value})],MANIFEST)['problems'])
    def test_window_and_identity_fail_closed(self):
        for key,value in [('pid',99),('tid',99),('requested_version',3),('user_handle',99),('carrier_id_hex','ff'*16),('qpc_before',102),('qpc_after',104),('qpc_frequency',1)]:
            self.assertIn('no_unique_match',correlate.correlate(observation(),[dict(RECEIPT,**{key:value})],MANIFEST)['problems'])
    def test_synthetic_refused(self):
        o=observation();o['diagnostic_space']='SYNTHETIC'
        self.assertIn('not_complete_real_capture',correlate.correlate(o,[RECEIPT],MANIFEST)['problems'])
    def test_missing_case(self):
        self.assertIn('missing_case_receipt',correlate.correlate(observation(),[],MANIFEST)['problems'])
if __name__=='__main__': unittest.main()
