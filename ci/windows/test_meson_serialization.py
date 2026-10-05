"""Native Windows Meson wrap/CoreData reproduction; no product compilation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

BASE = '654391bc9c63cc770013d1508b76909604e4c663'

def run(command, log, cwd=None):
    with log.open('w', encoding='utf-8') as stream:
        result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)
    print(f'{log.name} exit={result.returncode}', flush=True)
    return result.returncode

def main():
    p = argparse.ArgumentParser()
    p.add_argument('repo'); p.add_argument('root'); p.add_argument('--production', action='store_true')
    args = p.parse_args()
    repo, root = Path(args.repo), Path(args.root)
    root.mkdir(parents=True, exist_ok=True)
    historical = subprocess.check_output(['git', '-C', str(repo), 'show', BASE + ':ci/windows/meson-isolated.py'], text=True)
    corrected = historical.replace('from pathlib import Path\nimport sys\nimport mesonbuild.wrap.wrap as wrap\nfrom mesonbuild import mesonmain', 'import sys\nfrom mesonbuild import mesonmain\nimport mesonbuild.wrap.wrap as wrap\nfrom pathlib import Path')
    assert corrected != historical
    work = root.parent / ('meson-work-' + root.name)
    work.mkdir(parents=True, exist_ok=True)
    source = work / 'source'
    package = work / 'wrap-origin'
    package.mkdir(exist_ok=True)
    (package / 'meson.build').write_text("project('wrapped', 'c')\nwrapped = static_library('wrapped', 'wrapped.c')\n", encoding='utf-8')
    (package / 'wrapped.c').write_text('int wrapped(void) { return 1; }\n', encoding='utf-8')
    for command in (['git','init',str(package)], ['git','-C',str(package),'add','.'], ['git','-C',str(package),'-c','user.name=Helios control','-c','user.email=control@localhost','commit','-m','fixture']):
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    revision = subprocess.check_output(['git','-C',str(package),'rev-parse','HEAD'], text=True).strip()
    (source / 'subprojects' / 'packagefiles').mkdir(parents=True, exist_ok=True)
    (source / 'meson.build').write_text("project('helios-wrap-serialization', 'c')\nw = subproject('wrapped')\nexecutable('hello', 'hello.c', link_with: w.get_variable('wrapped'))\n", encoding='utf-8')
    (source / 'hello.c').write_text('int wrapped(void); int main(void) { return wrapped() == 2 ? 0 : 1; }\n', encoding='utf-8')
    wrapfile = source / 'subprojects' / 'wrapped.wrap'
    wrapfile.write_text(f'[wrap-git]\ndirectory = wrapped\nurl = {package.as_posix()}\nrevision = {revision}\ndiff_files = wrapped.patch\n', encoding='utf-8')
    (source / 'subprojects' / 'packagefiles' / 'wrapped.patch').write_text('diff --git a/wrapped.c b/wrapped.c\n--- a/wrapped.c\n+++ b/wrapped.c\n@@ -1 +1 @@\n-int wrapped(void) { return 1; }\n+int wrapped(void) { return 2; }\n', encoding='utf-8')
    instrumentation = '''
    import json
    definition = wrap.PackageDefinition.from_wrap_file(os.environ['HELIOS_CONTROL_WRAP'])
    diff_file = definition.diff_files[0]
    print('DIFF_FILE_IDENTITY=' + json.dumps({'type': str(type(diff_file)), 'module': type(diff_file).__module__, 'pathlib': str(sys.modules['pathlib']), 'hasWindowsPath': hasattr(sys.modules['pathlib'], 'WindowsPath')}), flush=True)
'''
    # Only observes the actual PackageDefinition; no pickle or class mutation.
    variants = {'historical': historical, 'import-order-only': corrected}
    if args.production:
        variants['production'] = (repo / 'ci/windows/meson-isolated.py').read_text()
    os.environ['HELIOS_CONTROL_WRAP'] = str(wrapfile)
    os.environ['HELIOS_MESON_LOCK_ROOT'] = str(work / 'external-locks')
    results = {}
    for name, text in variants.items():
        entry = work / (name + '.py')
        entry.write_text(text.replace("    sys.exit(mesonmain.main())", instrumentation + "    sys.exit(mesonmain.main())"), encoding='utf-8')
        build = work / (name + '-build')
        setup = run([sys.executable, str(entry), 'setup', str(build), str(source)], root / (name + '-setup.log'))
        output = (root / (name + '-setup.log')).read_text(encoding='utf-8')
        if name == 'historical':
            assert setup != 0 and 'PicklingError' in output and 'WindowsPath' in output and 'hasWindowsPath": false' in output, output
            results[name] = {'expectedFailure': 'WINDOWS_PATH_PICKLE', 'exit': setup, 'status': 'PASS'}
        else:
            assert setup == 0 and (build / 'meson-private' / 'coredata.dat').is_file(), output
            exits = [run([sys.executable, str(entry), 'compile', '-C', str(build)], root / (name + '-compile.log')),
                     run([sys.executable, str(entry), 'setup', '--reconfigure', str(build), str(source)], root / (name + '-reconfigure.log')),
                     run([sys.executable, str(entry), 'compile', '-C', str(build)], root / (name + '-recompile.log'))]
            assert exits == [0,0,0], exits
            executable = build / 'hello.exe'
            assert subprocess.run([str(executable)]).returncode == 0
            assert 'MESON_WRAP_LOCK_REDIRECT=' in output
            assert not list(source.rglob('.wraplock')), 'Wrap lock leaked into source'
            locks = list((work / 'external-locks').rglob('.wraplock'))
            assert locks, 'External lock not observed'
            results[name] = {'setup': setup, 'compileReconfigureRecompile': exits, 'coredataSha256': hashlib.sha256((build / 'meson-private' / 'coredata.dat').read_bytes()).hexdigest(), 'externalLocks': [str(x) for x in locks], 'status': 'PASS'}
    receipt = {'status': 'PASS', 'python': sys.version, 'system': os.environ.get('MSYSTEM'), 'historicalSourceSha256': hashlib.sha256(historical.encode()).hexdigest(), 'singleVariable': 'ENTRYPOINT_IMPORT_ORDER', 'results': results}
    (root / 'serialization.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    print('MESA_IMPORT_ORDER_RED_GREEN=PASS', flush=True)

if __name__ == '__main__':
    main()
