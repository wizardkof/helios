#!/usr/bin/env bash
set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'
export HELIOS_MESON_LOCK_ROOT="${RUNNER_TEMP:?}/helios-mesa-locks"
repo_root="$(cygpath -m "$GITHUB_WORKSPACE")"
receipt_root="$(cygpath -m "$RUNNER_TEMP/component-control/mesa-configuration")"
work_root="$(cygpath -m "$RUNNER_TEMP/mesa-configuration-control")"
mkdir -p "$receipt_root" "$work_root"
# Execute the actual production setup prefix unchanged. The boundary is before
# the compile command, so this control never compiles the Mesa product.
python - "$repo_root" "$work_root/setup-only.sh" <<'PY'
from pathlib import Path
import sys
repo, output = sys.argv[1:]
script = Path(repo, 'ci/windows/build-mesa.sh').read_text()
boundary = 'python "${repo_root}/ci/windows/meson-isolated.py" compile '
assert script.count(boundary) == 1
Path(output).write_text(script.split(boundary)[0], encoding='utf-8')
PY
bash "$work_root/setup-only.sh" "$repo_root" "$work_root/output" "$work_root/build" 2>&1 | tee "$receipt_root/setup.log"
python - "$repo_root" "$work_root" "$receipt_root" <<'PY'
from pathlib import Path
import hashlib,json,os,shutil,sys
repo, work, output = map(Path,sys.argv[1:])
core = work/'build/meson-private/coredata.dat'
assert core.is_file()
log=(output/'setup.log').read_text(encoding='utf-8')
assert 'DirectX-Headers' in log and 'MESON_WRAP_LOCK_REDIRECT=' in log
assert (repo/'icd/mesa/subprojects/DirectX-Headers/meson.build').is_file()
locks=list(Path(os.environ['HELIOS_MESON_LOCK_ROOT']).rglob('.wraplock'))
assert locks
assert not list((repo/'icd/mesa').rglob('.wraplock'))
shutil.copy2(core,output/'coredata.dat')
for path in (work/'output').glob('*.json'):shutil.copy2(path,output/path.name)
(output/'configuration.json').write_text(json.dumps({'status':'PASS','system':os.environ['MSYSTEM'],'coredataSha256':hashlib.sha256(core.read_bytes()).hexdigest(),'directXHeadersWrap':'PASS','externalLocks':[str(x) for x in locks],'compile':'NOT_RUN'},indent=2)+'\n')
PY
