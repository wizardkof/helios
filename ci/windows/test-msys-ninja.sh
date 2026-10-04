#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cygpath -m "${1:?repo root required}")"
receipt="$(cygpath -m "${2:?receipt path required}")"
arch=x64
[[ "${MSYSTEM:-}" == MINGW32 ]] && arch=x86
python "${repo_root}/ci/windows/assert_msys_pins.py" "${arch}" "${receipt}.packages.txt"
export NINJA="$(command -v ninja.exe || command -v ninja)"
python "${repo_root}/ci/windows/assert_msys_ninja.py" "${arch}" "${NINJA}" "${receipt}.identity.json"

root="$(cygpath -u "${RUNNER_TEMP:?}")/helios-msys-ninja-control"
mkdir -p "${root}/source" "${root}/poison"
cat > "${root}/source/meson.build" <<'EOF'
project('helios-msys-ninja-control', 'c')
executable('hello', 'hello.c')
EOF
printf 'int main(void) { return 0; }\n' > "${root}/source/hello.c"
printf '#!/usr/bin/env bash\necho poison >> "%s/poison/used.txt"\nexit 97\n' "${root}" > "${root}/poison/ninja"
chmod +x "${root}/poison/ninja"
export PATH="${root}/poison:${PATH}"
meson setup --backend=ninja "${root}/build" "${root}/source"
meson compile -C "${root}/build"
meson setup --reconfigure "${root}/build" "${root}/source"
meson compile -C "${root}/build"
if [[ -e "${root}/poison/used.txt" ]]; then
  echo 'Meson ignored the selected NINJA executable and resolved its implicit PATH candidate' >&2
  exit 1
fi
python - "${receipt}" "${NINJA}" "${MSYSTEM}" <<'PY'
import json, pathlib, sys
path, ninja, system = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
  'schemaVersion': 1,
  'status': 'PASS',
  'role': 'mesa-msys2-native-ninja',
  'msystem': system,
  'path': ninja,
  'selectedByMesonEnvironment': 'NINJA',
  'setup': 0,
  'compile': 0,
  'reconfigure': 0,
  'recompile': 0,
  'poisonPathUsed': False,
}, indent=2) + '\n', encoding='utf-8')
PY
echo 'MSYS2_NINJA_CONSUMER_CONTROL=PASS'
