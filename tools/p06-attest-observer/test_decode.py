import struct
import unittest
import decode

def record(phase, seq, call=1, instance=9, epoch=1):
    b=bytearray(128)
    struct.pack_into('<IIIIQQQQIIIIQ', b, 0, 0x314f4150,1,128,phase,instance,call,100+seq,seq,22,33,7,4,44)
    struct.pack_into('<IIIIQQQ',b,88,0,0,0,1,0,epoch,10000000)
    return {'raw_hex':b.hex(),'event_id':1,'event_version':1}

STATS={'mode':'REAL_PROVIDER','complete':True,'EventsLost':0,'LogBuffersLost':0,'RealTimeBuffersLost':0,'process_trace_status':0,'disable_status':0,'stop_status':0}
class DecodeTests(unittest.TestCase):
    def test_complete_interleaved(self):
        rows=[record(p,2*p-1,1) for p in range(1,6)]+[record(p,2*p,2) for p in range(1,6)]
        self.assertEqual(decode.analyze(rows,STATS,2)['capture_status'],'COMPLETE')
    def test_missing_is_unknown(self):
        r=decode.analyze([],STATS,1)
        self.assertEqual(r['capture_status'],'INCOMPLETE')
        self.assertEqual(r['branch_conclusion'],'NOT_PROVEN')
    def test_empty_never_complete(self):
        self.assertEqual(decode.analyze([],STATS,0)['capture_status'],'INCOMPLETE')
    def test_partial(self):
        self.assertEqual(decode.analyze([record(1,1)],STATS,1)['capture_status'],'INCOMPLETE')
    def test_duplicate(self):
        rows=[record(p,p) for p in range(1,6)]+[record(5,6)]
        self.assertIn('duplicate_phase',decode.analyze(rows,STATS,1)['problems'])
    def test_wrong_generation(self):
        rows=[record(p,p,instance=p) for p in range(1,6)]
        self.assertIn('mixed_generation',decode.analyze(rows,STATS,1)['problems'])
    def test_loss_unknown_and_nonzero(self):
        for val in [None,1]:
            stats=dict(STATS,EventsLost=val)
            self.assertEqual(decode.analyze([record(p,p) for p in range(1,6)],stats,1)['capture_status'],'INCOMPLETE')
    def test_sequence_gap(self):
        self.assertIn('sequence_gap',decode.analyze([record(p,p*2) for p in range(1,6)],STATS,1)['problems'])
    def test_malformed(self):
        for row in [{'raw_hex':'ab'}, {'raw_hex':'zz'}, dict(record(1,1),event_version=2)]:
            self.assertIn('malformed_record',decode.analyze([row],STATS,1)['problems'])
    def test_epoch_change(self):
        self.assertIn('mixed_enable_epoch',decode.analyze([record(p,p,epoch=p) for p in range(1,6)],STATS,1)['problems'])
def changed(row,offset,value,fmt='<I'):
    b=bytearray.fromhex(row['raw_hex']);struct.pack_into(fmt,b,offset,value)
    return dict(row,raw_hex=b.hex())

class HardenTests(unittest.TestCase):
    def rows(self): return [record(p,p) for p in range(1,6)]
    def test_reject_unknown_flags(self):
        rows=self.rows();rows[0]=changed(rows[0],100,3)
        self.assertIn('unknown_flags',decode.analyze(rows,STATS,1)['problems'])
    def test_zero_identity(self):
        for offset,fmt in [(16,'<Q'),(24,'<Q'),(48,'<I'),(52,'<I'),(112,'<Q'),(120,'<Q')]:
            rows=self.rows();rows[0]=changed(rows[0],offset,0,fmt)
            self.assertIn('zero_identity',decode.analyze(rows,STATS,1)['problems'])
    def test_writeback_validity(self):
        for index in [3,4]:
            rows=self.rows();rows[index]=changed(rows[index],100,0)
            self.assertIn('missing_buffer_validity',decode.analyze(rows,STATS,1)['problems'])
    def test_branch_and_status_consistency(self):
        for offset in [56,88,96]:
            rows=self.rows();rows[2]=changed(rows[2],offset,99)
            self.assertIn('branch_status_changed',decode.analyze(rows,STATS,1)['problems'])
    def test_entry_status_and_buffer_divergence_allowed(self):
        rows=self.rows();rows[0]=changed(rows[0],88,99);rows[0]=changed(rows[0],96,99)
        rows[4]=changed(rows[4],92,999)
        self.assertEqual(decode.analyze(rows,STATS,1)['capture_status'],'COMPLETE')
    def test_qpc_backwards(self):
        rows=self.rows();rows[3]=changed(rows[3],32,1,'<Q')
        self.assertIn('qpc_nonmonotonic',decode.analyze(rows,STATS,1)['problems'])
    def test_mode_required(self):
        r=decode.analyze(self.rows(),dict(STATS,mode='UNKNOWN'),1)
        self.assertEqual(r['capture_status'],'INCOMPLETE')
    def test_synthetic_never_real_observed(self):
        r=decode.analyze(self.rows(),dict(STATS,mode='SELFTEST_ONLY'),1)
        self.assertEqual(r['diagnostic_space'],'SYNTHETIC')
        self.assertEqual(r['branch_conclusion'],'NOT_PROVEN')
    def test_header_identity_kept_separate(self):
        rows=self.rows();rows[0].update(header_pid=999,header_tid=888)
        r=decode.analyze(rows,STATS,1)
        self.assertEqual(r['records'][0]['header_pid'],999)
        self.assertEqual(r['capture_status'],'COMPLETE')
if __name__=='__main__': unittest.main()
