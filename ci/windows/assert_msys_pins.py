import json,subprocess,sys
from pathlib import Path
pins=json.loads(Path(__file__).with_name('ci-toolchain-pins.json').read_text())['qualifiedObservedTools']['msys2Packages']
prefix='mingw-w64-i686-' if sys.argv[1]=='x86' else 'mingw-w64-ucrt-x86_64-'
rows=[]
for name,version in pins.items():
    if name.startswith(prefix) or name in ('git','bison','flex','msys2-runtime'):
        out=subprocess.check_output(['pacman','-Q',name],text=True).strip()
        if out!=name+' '+version:raise ValueError('MSYS2 pin mismatch: '+out+' expected '+version)
        rows.append(out)
Path(sys.argv[2]).write_text('\n'.join(rows)+'\n')
