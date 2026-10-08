#!/usr/bin/env python3
"""Production wiring gate. Complemented by compiled extraction/runtime fixtures."""
from pathlib import Path
h=Path(__file__).resolve().parents[1]
def source(p): return (h/p).read_text()
assert 'green_b::CONTROL' in source('kmd_render/src/ddi/escape.rs'), '0x1b dispatcher missing'
assert 'green_b::SUBMIT' in source('kmd_render/src/ddi/escape.rs'), '0x1c dispatcher missing'
assert 'enqueue_e1_submit' in source('kmd_render/src/virtio/ctrl.rs'), 'real transport not selected'
s=source('kmd_render/src/virtio/gpu/mod.rs')
body=s[s.index('    fn enqueue_submit_inner('):s.index('    /// Set the ring-corruption latch')]
assert body.index('batch.associate(') < body.index('self.enqueue_core('), 'association after exposure'
assert 'batch.rollback_admission(' in body, 'admission rollback missing'
assert s.count('batch.outcome(')>=2, 'normal or fatal completion missing'
assert 'service(adapter)' in source('kmd_render/src/ddi/hpd.rs'), 'PASSIVE publisher not wired'
assert 'release_owner(adapter, owner)' in source('kmd_render/src/device.rs'), 'owner teardown missing'
assert 'reference_attested' in source('kmd_render/src/adapter/green_b.rs')

ctrl=source('kmd_render/src/virtio/ctrl.rs')
e1=ctrl[ctrl.index('pub(crate) fn submit_venus_async_e1('):ctrl.index('fn submit_venus_async_inner(')]
assert 'cancel_failed_present_stream' in e1, 'tagged E1 failure must discharge existing scheduler marker'

def block(text, needle):
    import re
    text=re.sub(r'\s+', '', text); needle=re.sub(r'\s+', '', needle)
    i=text.index(needle);i=text.index('{',i);j=i+1;depth=1
    while depth:
        depth+=(text[j]=='{')-(text[j]=='}');j+=1
    return text[i:j]
for needle in ['if !e1_response_valid', 'if !self.completions[completion_slot].complete(completed_identity, transport_response)']:
    branch=block(source('kmd_render/src/virtio/gpu/mod.rs'),needle)
    assert 'self.park_drained(entry)' in branch, 'removed DMA entry must be parked before fatal return'
    assert branch.index('self.park_drained(entry)') < branch.index('self.latch_failed_and_fail_inflight()')

assert "let transport_response = if e1_batch.is_some()" in source("kmd_render/src/virtio/gpu/mod.rs")

print('PRODUCTION_WIRING=PASS (source evidence, not native build or GPU runtime)')
