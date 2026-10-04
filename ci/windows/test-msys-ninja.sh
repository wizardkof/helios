#!/usr/bin/env bash
set -uo pipefail
repo_root="$(cygpath -m "${1:?repo root required}")"
receipt="$(cygpath -m "${2:?receipt path required}")"
arch=x64
[[ "${MSYSTEM:-}" == MINGW32 ]] && arch=x86
root="$(cygpath -u "${RUNNER_TEMP:?}")/helios-msys-ninja-control"
mkdir -p "${root}/source" "${root}/poison"
cat > "${root}/source/meson.build" <<'EOF'
project('helios-msys-ninja-control', 'c')
executable('hello', 'hello.c')
EOF
printf 'int main(void) { return 0; }\n' > "${root}/source/hello.c"
printf '#!/usr/bin/env bash\necho poison >> "%s/poison/used.txt"\nexit 97\n' "${root}" > "${root}/poison/ninja"
chmod +x "${root}/poison/ninja"
python "${repo_root}/ci/windows/assert_msys_pins.py" "${arch}" "${receipt}.packages.json"
package_rc=$?
export NINJA="$(command -v ninja.exe || command -v ninja || true)"
python "${repo_root}/ci/windows/assert_msys_ninja.py" "${arch}" "${NINJA}" "${receipt}.identity.json"
ninja_rc=$?
export PATH="${root}/poison:${PATH}"
meson_outputs=()
run_meson() {
  local label="$1"; shift
  local output rc
  output="$("$@" 2>&1)"; rc=$?
  MESON_RC=$rc
  meson_outputs+=("$label exit=$rc" "$output")
  return 0
}
run_meson setup meson setup --backend=ninja "${root}/build" "${root}/source"
setup_rc=$MESON_RC
if [[ -f "${root}/build/build.ninja" ]]; then
  run_meson compile meson compile -C "${root}/build"; compile_rc=$MESON_RC
  run_meson reconfigure meson setup --reconfigure "${root}/build" "${root}/source"; reconfigure_rc=$MESON_RC
  run_meson recompile meson compile -C "${root}/build"; recompile_rc=$MESON_RC
else
  compile_rc=NOT_RUN; reconfigure_rc=NOT_RUN; recompile_rc=NOT_RUN
fi
poison=false
[[ -e "${root}/poison/used.txt" ]] && poison=true
python - "${receipt}" "${NINJA}" "${MSYSTEM}" "${setup_rc}" "${compile_rc}" "${reconfigure_rc}" "${recompile_rc}" "${poison}" "${package_rc}" "${ninja_rc}" "${meson_outputs[@]}" <<'PY'
import json, pathlib, sys
path, ninja, system, setup, compile_, reconfigure, recompile, poison, package_rc, ninja_rc, *output = sys.argv[1:]
try:
    numeric = [int(value) for value in (setup, compile_, reconfigure, recompile)]
except ValueError:
    numeric = [1]
passed = int(package_rc) == 0 and int(ninja_rc) == 0 and len(numeric) == 4 and all(value == 0 for value in numeric) and poison == "false"
pathlib.Path(path).write_text(json.dumps({
  "schemaVersion": 1,
  "status": "PASS" if passed else "FAIL",
  "role": "mesa-msys2-native-ninja",
  "msystem": system,
  "path": ninja or None,
  "selectedByMesonEnvironment": "NINJA",
  "packagePinCheckExitCode": int(package_rc),
  "ninjaIdentityCheckExitCode": int(ninja_rc),
  "setup": setup,
  "compile": compile_,
  "reconfigure": reconfigure,
  "recompile": recompile,
  "mesonOutput": output,
  "poisonPathUsed": poison == "true",
}, indent=2) + "\n", encoding="utf-8")
PY
status_rc=$?
if [[ "$package_rc" -ne 0 || "$ninja_rc" -ne 0 || "$status_rc" -ne 0 || "$setup_rc" -ne 0 || "$compile_rc" != 0 || "$reconfigure_rc" != 0 || "$recompile_rc" != 0 || "$poison" == true ]]; then
  echo "MSYS2 Ninja infrastructure control failed; package receipt=${receipt}.packages.json consumer receipt=${receipt}" >&2
  exit 1
fi
echo 'MSYS2_NINJA_CONSUMER_CONTROL=PASS'
