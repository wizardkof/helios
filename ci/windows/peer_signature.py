"""Bounded extraction of embedded WIN_CERTIFICATE PKCS7 for native CMS verification."""
import struct
from pathlib import Path
import sys

def extract(data):
    def read(fmt,offset):
        if offset<0 or offset+struct.calcsize(fmt)>len(data):raise ValueError('Truncated PE')
        return struct.unpack_from(fmt,data,offset)
    if data[:2]!=b'MZ':raise ValueError('Not PE')
    pe=read('<I',60)[0]
    if data[pe:pe+4]!=b'PE\0\0':raise ValueError('Bad PE signature')
    opt=pe+24;magic=read('<H',opt)[0]
    if magic not in (0x10b,0x20b):raise ValueError('Unsupported PE')
    offset,size=read('<II',opt+(96 if magic==0x10b else 112)+32)
    length,revision,kind=read('<IHH',offset)
    if not offset or size<8 or length<8 or length>size or offset+size>len(data) or kind!=2 or revision!=0x200:raise ValueError('Invalid security directory')
    return data[offset+8:offset+length]
if __name__=='__main__':Path(sys.argv[2]).write_bytes(extract(Path(sys.argv[1]).read_bytes()))
