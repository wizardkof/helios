"""Tamper only copies, in hashed PE section content rather than certificate table."""
import argparse,struct,json,hashlib
from pathlib import Path

def tamper_pe(data):
 b=bytearray(data)
 if b[:2]!=b'MZ':raise ValueError('Not PE')
 pe=struct.unpack_from('<I',b,60)[0]
 if b[pe:pe+4]!=b'PE\0\0':raise ValueError('Bad PE')
 sections=struct.unpack_from('<H',b,pe+6)[0];optional=struct.unpack_from('<H',b,pe+20)[0];start=pe+24+optional
 if start+sections*40>len(b):raise ValueError('Invalid sections')
 for i in range(sections):
  size,offset=struct.unpack_from('<II',b,start+i*40+16)
  if size and offset>=start+sections*40 and offset+size<=len(b):b[offset]^=1;return bytes(b),offset
 raise ValueError('No bounded raw section')
def main():
 p=argparse.ArgumentParser();p.add_argument('--fixture',required=True);p.add_argument('--output',required=True);a=p.parse_args();f=Path(a.fixture);o=Path(a.output);o.mkdir(parents=True,exist_ok=True);rows=[]
 for source,target in [('vulkan-1.dll','tampered-pe.dll'),('helios_kmd_render.sys','tampered-sys.sys')]:
  raw=(f/source).read_bytes();changed,offset=tamper_pe(raw);(o/target).write_bytes(changed);rows.append({'source':source,'target':target,'offset':offset,'sourceSha256':hashlib.sha256(raw).hexdigest(),'tamperedSha256':hashlib.sha256(changed).hexdigest(),'region':'PE_SECTION_RAW_DATA'})
 raw=(f/'helios_kmd_render.cat').read_bytes();b=bytearray(raw);offset=len(b)//2;b[offset]^=1;(o/'tampered.cat').write_bytes(b);rows.append({'source':'helios_kmd_render.cat','target':'tampered.cat','offset':offset,'sourceSha256':hashlib.sha256(raw).hexdigest(),'tamperedSha256':hashlib.sha256(b).hexdigest()})
 (o/'negative-provenance.json').write_text(json.dumps(rows,indent=2))
if __name__=='__main__':main()
