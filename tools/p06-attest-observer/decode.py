#!/usr/bin/env python3
"""Strict fixed-schema ETW decoder. Completeness is not ATTEST success."""
import argparse
import json
import struct
from pathlib import Path

def unpack(row):
    b=bytes.fromhex(row['raw_hex'])
    if len(b)!=128 or struct.unpack_from('<III',b)!=(0x314f4150,1,128) or row.get('event_id')!=1 or row.get('event_version')!=1:
        raise ValueError('schema')
    names=('phase','instance','call','qpc','sequence','pid','tid','branch','requested_version','user_handle')
    r=dict(zip(names,struct.unpack_from('<IQQQQIIIIQ',b,12)))
    if r['phase'] not in range(1,6): raise ValueError('phase')
    r['carrier_id_hex']=b[72:88].hex()
    r.update(zip(('local_status','buffer_status','ntstatus','flags','failed_writes','enable_epoch','qpc_frequency'),struct.unpack_from('<IIIIQQQ',b,88)))
    for field in ('header_pid','header_tid','header_timestamp'):
        if field in row: r[field]=row[field]
    return r

def analyze(rows, stats, expected_calls):
    problems=set(); records=[]; calls={}
    for row in rows:
        try: records.append(unpack(row))
        except (KeyError,ValueError,TypeError,struct.error): problems.add('malformed_record')
    mode=stats.get('mode')
    space='REAL_PROVIDER' if mode=='REAL_PROVIDER' else 'SYNTHETIC' if mode=='SELFTEST_ONLY' else 'UNKNOWN'
    if space=='UNKNOWN': problems.add('unknown_diagnostic_space')
    if not records: problems.add('no_observation')
    if not stats.get('complete'): problems.add('collector_incomplete')
    for key in ('EventsLost','LogBuffersLost','RealTimeBuffersLost','process_trace_status','disable_status','stop_status'):
        if type(stats.get(key)) is not int or stats[key]!=0: problems.add('loss_or_unknown_'+key)
    if len({r['instance'] for r in records})>1: problems.add('mixed_generation')
    if len({r['enable_epoch'] for r in records})>1: problems.add('mixed_enable_epoch')
    seq=sorted(r['sequence'] for r in records)
    if len(seq)!=len(set(seq)): problems.add('duplicate_sequence')
    if seq and seq!=list(range(seq[0],seq[-1]+1)): problems.add('sequence_gap')
    for r in records:
        if r['flags'] & ~1: problems.add('unknown_flags')
        if any(r[f]==0 for f in ('instance','call','pid','tid','qpc_frequency','enable_epoch')): problems.add('zero_identity')
        if r['phase'] in (4,5) and not r['flags'] & 1: problems.add('missing_buffer_validity')
        if r['failed_writes']: problems.add('producer_failed_writes')
        key=(r['instance'],r['call'])
        calls.setdefault(key,[]).append(r)
    if len(calls)!=expected_calls: problems.add('unexpected_call_count')
    for rows in calls.values():
        phases=[r['phase'] for r in rows]
        if len(phases)!=len(set(phases)): problems.add('duplicate_phase')
        if sorted(phases)!=list(range(1,6)): problems.add('incomplete_call')
        ordered=sorted(rows,key=lambda r:r['sequence'])
        if [r['phase'] for r in ordered]!=list(range(1,6)): problems.add('phase_order')
        if any(a['qpc']>b['qpc'] for a,b in zip(ordered,ordered[1:])): problems.add('qpc_nonmonotonic')
        for field in ('branch','local_status','ntstatus'):
            if len({r[field] for r in rows if r['phase']>=2})>1: problems.add('branch_status_changed')
        for field in ('pid','tid','requested_version','user_handle','carrier_id_hex','qpc_frequency'):
            if len({r[field] for r in rows})!=1: problems.add('call_identity_changed')
    return {'capture_status':'INCOMPLETE' if problems else 'COMPLETE','diagnostic_space':space,'branch_conclusion':'OBSERVED' if not problems and space=='REAL_PROVIDER' else 'NOT_PROVEN','problems':sorted(problems),'calls':len(calls),'events':len(records),'records':records}

def main():
    p=argparse.ArgumentParser(); p.add_argument('run_dir',type=Path); p.add_argument('--expected-calls',type=int,required=True); a=p.parse_args()
    try:
        rows=[json.loads(s) for s in (a.run_dir/'events.jsonl').read_text().splitlines()]
        stats=json.loads((a.run_dir/'summary.json').read_text())
        result=analyze(rows,stats,a.expected_calls)
    except (OSError,ValueError) as e: result={'capture_status':'INCOMPLETE','branch_conclusion':'NOT_PROVEN','error':str(e)}
    print(json.dumps(result,indent=2)); return 0 if result['capture_status']=='COMPLETE' else 2
if __name__=='__main__': raise SystemExit(main())
