#!/usr/bin/env python3
"""Correlate immediate user receipts to complete real KMD observations."""
import argparse
import json
import re
from pathlib import Path

def correlate(observation, receipts, manifest):
    problems=set(); matches=[]; calls={}; seen=set(); used=set()
    if observation.get('capture_status')!='COMPLETE' or observation.get('diagnostic_space')!='REAL_PROVIDER': problems.add('not_complete_real_capture')
    if not isinstance(manifest.get('run_id'),str) or not manifest['run_id'] or manifest.get('architecture') not in ('x64','x86') or not re.fullmatch('[0-9a-fA-F]{40}',str(manifest.get('source_sha',''))): problems.add('invalid_manifest')
    cases=manifest.get('cases',[])
    if not isinstance(cases,list) or not cases or any(not isinstance(c,str) or not c for c in cases) or len(cases)!=len(set(cases)): problems.add('invalid_manifest');cases=[]
    for r in observation.get('records',[]): calls.setdefault((r['instance'],r['call']),[]).append(r)
    for receipt in receipts:
        case=receipt.get('case_id')
        if case in seen: problems.add('duplicate_case_receipt')
        seen.add(case)
        if case not in cases: problems.add('unexpected_case_receipt')
        if any(receipt.get(f)!=manifest.get(f) for f in ('run_id','architecture','source_sha')): problems.add('receipt_manifest_mismatch')
        fields=('pid','tid','requested_version','user_handle','qpc_before','qpc_after','qpc_frequency')
        if any(type(receipt.get(f)) is not int for f in fields) or not re.fullmatch('[0-9a-fA-F]{32}',str(receipt.get('carrier_id_hex',''))): problems.add('malformed_receipt');continue
        if receipt['qpc_before']>receipt['qpc_after'] or receipt['qpc_frequency']<=0: problems.add('malformed_receipt');continue
        candidates=[]
        for key,records in calls.items():
            if all(all(r[f]==receipt[f] for f in ('pid','tid','requested_version','user_handle','qpc_frequency')) and r['carrier_id_hex'].lower()==receipt['carrier_id_hex'].lower() and receipt['qpc_before']<=r['qpc']<=receipt['qpc_after'] for r in records): candidates.append(key)
        if len(candidates)>1: problems.add('ambiguous_match');continue
        if len(candidates)!=1: problems.add('no_unique_match');continue
        key=candidates[0]
        if key in used: problems.add('call_reused')
        used.add(key)
        records=sorted(calls[key],key=lambda r:r['phase'])
        matches.append({'case_id':case,'instance':key[0],'call':key[1], 'observed_statuses':[{'phase':r['phase'],'branch':r['branch'],'local_status':r['local_status'],'buffer_status':r['buffer_status'],'buffer_status_valid':bool(r['flags']&1),'ntstatus':r['ntstatus'],'local_buffer_divergence':bool(r['flags']&1) and r['local_status']!=r['buffer_status']} for r in records]})
    if set(cases)-seen: problems.add('missing_case_receipt')
    if set(calls)-used: problems.add('uncorrelated_call')
    return {'correlation_status':'NOT_PROVEN' if problems else 'MATCHED','problems':sorted(problems),'manifest':manifest,'matches':matches,'note':'Observed values are not compared against expected branch outcomes.'}

def main():
    p=argparse.ArgumentParser();p.add_argument('observation',type=Path);p.add_argument('receipts',type=Path);p.add_argument('manifest',type=Path);a=p.parse_args()
    try:
        result=correlate(json.loads(a.observation.read_text()),[json.loads(s) for s in a.receipts.read_text().splitlines()],json.loads(a.manifest.read_text()))
    except (OSError,ValueError,KeyError,TypeError) as e:result={'correlation_status':'NOT_PROVEN','error':str(e)}
    print(json.dumps(result,indent=2));return 0 if result['correlation_status']=='MATCHED' else 2
if __name__=='__main__':raise SystemExit(main())
