#!/usr/bin/env python3
"""Validate actual Windows synthetic ETW capture; never KMD evidence."""
import json
import sys
from pathlib import Path
import decode
p=Path(sys.argv[1])
try:
    stats=json.loads((p/'summary.json').read_text())
    rows=[json.loads(s) for s in (p/'events.jsonl').read_text().splitlines()]
    result=decode.analyze(rows,stats,1)
    assert stats['mode']=='SELFTEST_ONLY'
    assert result['capture_status']=='COMPLETE'
    assert len(rows)==5 and stats['events']==5
    for r in result['records']:
        assert r['instance']==0x1122334455667788 and r['call']==1
        assert r['branch']==7 and r['requested_version']==4
        assert r['user_handle']==0xaabbccdd and r['carrier_id_hex']==bytes(range(16)).hex()
        assert r['local_status']==r['buffer_status']==r['ntstatus']==0
        assert r['flags']==1 and r['failed_writes']==0 and r['enable_epoch']==1
        assert r['qpc_frequency']>0
    print(json.dumps({'synthetic_etw_qualification':'PASS','kmd_observation':'NOT_RUN','events':5}))
except (OSError,ValueError,KeyError,AssertionError) as e:
    print(json.dumps({'synthetic_etw_qualification':'FAIL','kmd_observation':'NOT_RUN','error':str(e)}));sys.exit(2)
