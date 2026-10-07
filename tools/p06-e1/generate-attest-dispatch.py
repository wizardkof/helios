from pathlib import Path
r=Path(__file__).resolve().parents[2]
s=(r/'kmd_render/src/adapter/section_probe.rs').read_text(encoding='utf-8')
f=s[s.index('pub(crate) fn escape_attest_transport('):]
a=Path(__file__).parent
(r/'protocol/tests/attest_dispatch_generated.rs').write_text((a/'attest_dispatch_prefix.txt').read_text(encoding='utf-8')+f+(a/'attest_dispatch_cases.txt').read_text(encoding='utf-8'),encoding='utf-8')
